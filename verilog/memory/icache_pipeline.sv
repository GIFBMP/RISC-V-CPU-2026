// Four total CPU request credits: queued responses, one synchronous SRAM lookup,
// and at most one miss. Hits accept and return one word per clock. A miss stops
// new requests until all refill responses drain; older hit responses remain first.
module icache_pipeline #(
    parameter integer CACHE_BYTES = 2048,
    parameter integer LINE_BYTES = 16
) (
    input wire clock, reset,
    input wire req_valid,
    output wire req_ready,
    input wire [31:0] req_addr,
    output wire rsp_valid,
    input wire rsp_ready,
    output wire [31:0] rsp_data,
    output wire rsp_error,
    output wire mem_rd_valid,
    input wire mem_rd_ready,
    output wire [31:0] mem_rd_addr,
    input wire mem_rd_rsp_valid,
    output wire mem_rd_rsp_ready,
    input wire [31:0] mem_rd_rsp_data,
    input wire mem_rd_rsp_error
);
    localparam integer WORDS = CACHE_BYTES >= 4 ? CACHE_BYTES / 4 : 1;
    localparam integer LINES = LINE_BYTES >= 4 && CACHE_BYTES >= LINE_BYTES ? CACHE_BYTES / LINE_BYTES : 1;
    localparam integer LINE_WORDS = LINE_BYTES >= 4 ? LINE_BYTES / 4 : 1;
    localparam integer WORD_BITS = WORDS > 1 ? $clog2(WORDS) : 1;
    localparam integer SET_BITS = LINES > 1 ? $clog2(LINES) : 1;
    localparam integer COUNT_BITS = $clog2(LINE_WORDS + 1);
    localparam integer LINE_OFFSET = LINE_BYTES >= 4 ? $clog2(LINE_BYTES) : 2;
    localparam integer CACHE_OFFSET = CACHE_BYTES >= 4 ? $clog2(CACHE_BYTES) : 2;
    localparam integer TAG_BITS = 32 - CACHE_OFFSET;
    generate
        if (CACHE_BYTES < 4 || CACHE_BYTES > 2097152 || LINE_BYTES < 4 ||
            LINE_BYTES > CACHE_BYTES || (CACHE_BYTES & (CACHE_BYTES - 1)) != 0 ||
            (LINE_BYTES & (LINE_BYTES - 1)) != 0) begin : invalid_parameters
            icache_requires_power_of_two_sizes invalid_configuration();
        end
    endgenerate

    reg [LINES-1:0] valid_bits;
    reg [TAG_BITS-1:0] tags [0:LINES-1];
    reg miss_active, miss_cacheable, miss_error;
    reg [31:0] miss_address, requested_data;
    reg [COUNT_BITS-1:0] issued_words, received_words;
    reg lookup_valid, lookup_error;
    reg [31:0] responses [0:3];
    reg [3:0] response_errors;
    reg [1:0] response_head, response_tail;
    reg [2:0] response_count;
    wire [SET_BITS-1:0] input_set = SET_BITS'((req_addr >> LINE_OFFSET) & (LINES - 1));
    wire input_cacheable = req_addr[31:28] == 0;
    wire input_aligned = req_addr[1:0] == 0;
    // Compare each fixed tag before selecting its set, rather than multiplexing
    // every tag bit with the request index on the fetch-to-SRAM path.
    wire [LINES-1:0] input_hits;
    genvar hit_row;
    generate
        for (hit_row = 0; hit_row < LINES; hit_row = hit_row + 1) begin : tag_match
            assign input_hits[hit_row] = valid_bits[hit_row] &&
                input_set == SET_BITS'(hit_row) &&
                tags[hit_row] == req_addr[31:CACHE_OFFSET];
        end
    endgenerate
    wire input_hit = |input_hits;
    wire [SET_BITS-1:0] miss_set = SET_BITS'((miss_address >> LINE_OFFSET) & (LINES - 1));
    wire [WORD_BITS-1:0] miss_word_index = WORD_BITS'((miss_address >> 2) & (WORDS - 1));
    wire [COUNT_BITS-1:0] requested_word = COUNT_BITS'((miss_address >> 2) & (LINE_WORDS - 1));
    wire [COUNT_BITS-1:0] needed_words = miss_cacheable ? COUNT_BITS'(LINE_WORDS) : COUNT_BITS'(1);
    wire response_pop = rsp_valid && rsp_ready;
    wire [3:0] reserved_responses = {1'b0, response_count} + {3'b0, lookup_valid};
    assign req_ready = !reset && !miss_active && (reserved_responses < 4'd4 || response_pop);
    wire request_fire = req_valid && req_ready;
    wire read_fire = mem_rd_rsp_valid && mem_rd_rsp_ready;
    wire miss_complete = read_fire && received_words + 1'b1 == needed_words;
    wire response_push = lookup_valid || miss_complete;
    wire final_error = miss_error || mem_rd_rsp_error;
    wire [31:0] final_data = !miss_cacheable || received_words == requested_word
        ? mem_rd_rsp_data : requested_data;
    // Give each tag row its own write enable so refill completion does not
    // directly drive a mux on every bit of the complete tag array.
    genvar tag_row;
    generate
        for (tag_row = 0; tag_row < LINES; tag_row = tag_row + 1) begin : tag_write
            always @(posedge clock) begin
                if (!reset && miss_complete && miss_cacheable &&
                    miss_set == SET_BITS'(tag_row))
                    tags[tag_row] <= miss_address[31:CACHE_OFFSET];
            end
        end
    endgenerate
    wire [31:0] ram_rdata;
    wire ram_read = request_fire && input_aligned && input_cacheable && input_hit;
    wire ram_write = miss_active && miss_cacheable && read_fire && !mem_rd_rsp_error;
    wire [WORD_BITS-1:0] ram_addr = ram_write
        ? ((miss_word_index & ~WORD_BITS'(LINE_WORDS - 1)) | WORD_BITS'(received_words))
        : WORD_BITS'((req_addr >> 2) & (WORDS - 1));
    sram_fakeram #(.DEPTH(WORDS), .WIDTH(32), .WRITE_GRANULARITY(8)) data_array (
        .clk(clock), .en(!reset && (ram_read || ram_write)), .we(ram_write),
        .wmask(4'hf), .addr(ram_addr), .wdata(mem_rd_rsp_data), .rdata(ram_rdata)
    );
    assign rsp_valid = !reset && response_count != 0;
    assign rsp_data = responses[response_head];
    assign rsp_error = response_errors[response_head];
    assign mem_rd_valid = !reset && miss_active && issued_words < needed_words;
    assign mem_rd_addr = miss_cacheable
        ? ((miss_address & ~32'(LINE_BYTES - 1)) | (32'(issued_words) << 2)) : miss_address;
    assign mem_rd_rsp_ready = !reset && miss_active;

    always @(posedge clock) begin
        if (reset) begin
            valid_bits <= {LINES{1'b0}};
            miss_active <= 0;
            miss_cacheable <= 0;
            miss_error <= 0;
            miss_address <= 0;
            requested_data <= 0;
            issued_words <= 0;
            received_words <= 0;
            lookup_valid <= 0;
            lookup_error <= 0;
            response_errors <= 0;
            response_head <= 0;
            response_tail <= 0;
            response_count <= 0;
        end else begin
            lookup_valid <= request_fire && (!input_aligned || (input_cacheable && input_hit));
            if (request_fire) begin
                lookup_error <= !input_aligned;
                if (input_aligned && !(input_cacheable && input_hit)) begin
                    miss_active <= 1;
                    miss_cacheable <= input_cacheable;
                    miss_address <= req_addr;
                    miss_error <= 0;
                    issued_words <= 0;
                    received_words <= 0;
                    if (input_cacheable) valid_bits[input_set] <= 0;
                end
            end
            if (mem_rd_valid && mem_rd_ready)
                issued_words <= issued_words + 1'b1;
            if (read_fire) begin
                received_words <= received_words + 1'b1;
                miss_error <= final_error;
                if (received_words == requested_word)
                    requested_data <= mem_rd_rsp_data;
                if (miss_complete) begin
                    miss_active <= 0;
                    if (miss_cacheable) begin
                        valid_bits[miss_set] <= !final_error;
                    end
                end
            end
            if (response_push) begin
                // A pending hit has completed before a miss can receive data.
                responses[response_tail] <= miss_complete ? final_data : (lookup_error ? 32'b0 : ram_rdata);
                response_errors[response_tail] <= miss_complete ? final_error : lookup_error;
                response_tail <= response_tail + 1'b1;
            end
            if (response_pop)
                response_head <= response_head + 1'b1;
            case ({response_push, response_pop})
                2'b10: response_count <= response_count + 1'b1;
                2'b01: response_count <= response_count - 1'b1;
                default: begin end
            endcase
        end
    end
endmodule
