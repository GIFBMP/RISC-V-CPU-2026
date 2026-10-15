// One CPU request at a time; hits issue the synchronous SRAM read on acceptance.
// A missing line sends all word reads without waiting for individual responses.
// Stores are write-through/no-write-allocate and acknowledge only after both the
// external response and any local hit update. There is deliberately no flush:
// every accepted request drains; the core owns speculative-result cancellation.
module blocking_cache #(
    parameter integer CACHE_BYTES = 2048,
    parameter integer LINE_BYTES = 16,
    parameter integer READ_ONLY = 0
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [31:0] req_addr,
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wstrb,
    output wire        rsp_valid,
    input  wire        rsp_ready,
    output wire [31:0] rsp_data,
    output wire        rsp_error,

    output wire        mem_rd_valid,
    input  wire        mem_rd_ready,
    output wire [31:0] mem_rd_addr,
    input  wire        mem_rd_rsp_valid,
    output wire        mem_rd_rsp_ready,
    input  wire [31:0] mem_rd_rsp_data,
    input  wire        mem_rd_rsp_error,
    output wire        mem_wr_valid,
    input  wire        mem_wr_ready,
    output wire [31:0] mem_wr_addr,
    output wire [31:0] mem_wr_data,
    output wire [3:0]  mem_wr_strb,
    input  wire        mem_wr_rsp_valid,
    output wire        mem_wr_rsp_ready,
    input  wire        mem_wr_rsp_error
);
    localparam integer WORDS = (CACHE_BYTES >= 4) ? CACHE_BYTES / 4 : 1;
    localparam integer LINES = (LINE_BYTES >= 4 && CACHE_BYTES >= LINE_BYTES)
        ? CACHE_BYTES / LINE_BYTES : 1;
    localparam integer LINE_WORDS = (LINE_BYTES >= 4) ? LINE_BYTES / 4 : 1;
    localparam integer WORD_BITS = (WORDS > 1) ? $clog2(WORDS) : 1;
    localparam integer SET_BITS = (LINES > 1) ? $clog2(LINES) : 1;
    localparam integer COUNT_BITS = $clog2(LINE_WORDS + 1);
    localparam integer LINE_OFFSET = (LINE_BYTES >= 4) ? $clog2(LINE_BYTES) : 2;
    localparam integer CACHE_OFFSET = (CACHE_BYTES >= 4) ? $clog2(CACHE_BYTES) : 2;
    localparam integer TAG_BITS = 32 - CACHE_OFFSET;
    generate
        if (CACHE_BYTES < 4 || CACHE_BYTES > 2097152 || LINE_BYTES < 4 ||
            LINE_BYTES > CACHE_BYTES || (CACHE_BYTES & (CACHE_BYTES - 1)) != 0 ||
            (LINE_BYTES & (LINE_BYTES - 1)) != 0 ||
            (READ_ONLY != 0 && READ_ONLY != 1)) begin : invalid_parameters
            blocking_cache_requires_power_of_two_sizes invalid_configuration();
        end
    endgenerate
    localparam [3:0] IDLE = 4'd0, RAM_CAPTURE = 4'd1, REFILL = 4'd2,
        BYPASS_REQUEST = 4'd3, BYPASS_RESPONSE = 4'd4, WRITE_REQUEST = 4'd5,
        WRITE_RESPONSE = 4'd6, STORE_WRITE = 4'd7, RESPONSE = 4'd8;
    reg [3:0] state;
    reg [31:0] address, store_data;
    reg [3:0] store_strobe;
    reg store_hit, refill_error;
    reg [COUNT_BITS-1:0] issued_words, received_words;
    reg [31:0] requested_data, response_data;
    reg response_error;
    reg [LINES-1:0] valid_bits;
    reg [TAG_BITS-1:0] tags [0:LINES-1];
    wire [SET_BITS-1:0] input_set = SET_BITS'((req_addr >> LINE_OFFSET) & (LINES - 1));
    wire input_cacheable = req_addr[31:28] == 0;
    wire input_aligned = req_addr[1:0] == 0;
    // Keep tag comparisons local to each fixed set; only the one-bit hit result
    // is selected by the request index.
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
    wire [SET_BITS-1:0] set_index = SET_BITS'((address >> LINE_OFFSET) & (LINES - 1));
    wire [WORD_BITS-1:0] word_index = WORD_BITS'((address >> 2) & (WORDS - 1));
    wire [COUNT_BITS-1:0] requested_word = COUNT_BITS'((address >> 2) & (LINE_WORDS - 1));
    wire rd_fire = mem_rd_rsp_valid && mem_rd_rsp_ready;
    wire refill_last = received_words == COUNT_BITS'(LINE_WORDS - 1);
    // Decode the refill destination locally for each tag row, avoiding one
    // global write control driving the muxes for every tag bit.
    genvar tag_row;
    generate
        for (tag_row = 0; tag_row < LINES; tag_row = tag_row + 1) begin : tag_write
            always @(posedge clock) begin
                if (!reset && state == REFILL && rd_fire && refill_last &&
                    set_index == SET_BITS'(tag_row))
                    tags[tag_row] <= address[31:CACHE_OFFSET];
            end
        end
    endgenerate
    reg ram_en, ram_we;
    reg [WORD_BITS-1:0] ram_addr;
    reg [31:0] ram_wdata;
    reg [3:0] ram_wmask;
    wire [31:0] ram_rdata;
    sram_fakeram #(.DEPTH(WORDS), .WIDTH(32), .WRITE_GRANULARITY(8)) data_array (
        .clk(clock), .en(ram_en), .we(ram_we), .wmask(ram_wmask),
        .addr(ram_addr), .wdata(ram_wdata), .rdata(ram_rdata)
    );
    assign req_ready = !reset && state == IDLE;
    assign rsp_valid = !reset && state == RESPONSE;
    assign rsp_data = response_data;
    assign rsp_error = response_error;
    assign mem_rd_valid = !reset && (state == BYPASS_REQUEST ||
        (state == REFILL && issued_words < COUNT_BITS'(LINE_WORDS)));
    assign mem_rd_addr = state == REFILL
        ? ((address & ~32'(LINE_BYTES - 1)) | (32'(issued_words) << 2)) : address;
    assign mem_rd_rsp_ready = !reset && (state == BYPASS_RESPONSE || state == REFILL);
    assign mem_wr_valid = !reset && state == WRITE_REQUEST;
    assign mem_wr_addr = address;
    assign mem_wr_data = store_data;
    assign mem_wr_strb = store_strobe;
    assign mem_wr_rsp_ready = !reset && state == WRITE_RESPONSE;
    always @* begin
        ram_en = 1'b0;
        ram_we = 1'b0;
        ram_addr = word_index;
        ram_wdata = store_data;
        ram_wmask = store_strobe;
        if (!reset) begin
            if (state == IDLE) begin
                ram_en = req_valid && req_ready && !req_write && input_aligned && input_cacheable && input_hit;
                ram_addr = WORD_BITS'((req_addr >> 2) & (WORDS - 1));
            end else if (state == REFILL) begin
                ram_en = rd_fire && !mem_rd_rsp_error;
                ram_we = 1'b1;
                ram_addr = (word_index & ~WORD_BITS'(LINE_WORDS - 1)) | WORD_BITS'(received_words);
                ram_wdata = mem_rd_rsp_data;
                ram_wmask = 4'hf;
            end else if (state == STORE_WRITE) begin
                ram_en = 1'b1;
                ram_we = 1'b1;
            end
        end
    end
    always @(posedge clock) begin
        if (reset) begin
            state <= IDLE;
            address <= 0;
            store_data <= 0;
            store_strobe <= 0;
            store_hit <= 0;
            refill_error <= 0;
            issued_words <= 0;
            received_words <= 0;
            requested_data <= 0;
            response_data <= 0;
            response_error <= 0;
            valid_bits <= {LINES{1'b0}};
        end else begin
            case (state)
                IDLE: if (req_valid && req_ready) begin
                    address <= req_addr;
                    store_data <= req_wdata;
                    store_strobe <= req_wstrb;
                    response_data <= 0;
                    response_error <= 0;
                    if (!input_aligned || (req_write && READ_ONLY != 0)) begin
                        response_error <= 1;
                        state <= RESPONSE;
                    end else if (req_write) begin
                        store_hit <= input_cacheable && input_hit;
                        state <= WRITE_REQUEST;
                    end else if (!input_cacheable) begin
                        state <= BYPASS_REQUEST;
                    end else if (input_hit) begin
                        state <= RAM_CAPTURE;
                    end else begin
                        valid_bits[input_set] <= 0;
                        refill_error <= 0;
                        issued_words <= 0;
                        received_words <= 0;
                        state <= REFILL;
                    end
                end
                RAM_CAPTURE: begin
                    response_data <= ram_rdata;
                    state <= RESPONSE;
                end
                REFILL: begin
                    if (mem_rd_valid && mem_rd_ready)
                        issued_words <= issued_words + 1'b1;
                    if (rd_fire) begin
                        received_words <= received_words + 1'b1;
                        refill_error <= refill_error || mem_rd_rsp_error;
                        if (received_words == requested_word)
                            requested_data <= mem_rd_rsp_data;
                        if (refill_last) begin
                            // All responses, including those after an error, have drained.
                            valid_bits[set_index] <= !(refill_error || mem_rd_rsp_error);
                            response_error <= refill_error || mem_rd_rsp_error;
                            response_data <= received_words == requested_word ? mem_rd_rsp_data : requested_data;
                            state <= RESPONSE;
                        end
                    end
                end
                BYPASS_REQUEST: if (mem_rd_valid && mem_rd_ready)
                    state <= BYPASS_RESPONSE;
                BYPASS_RESPONSE: if (rd_fire) begin
                    response_data <= mem_rd_rsp_data;
                    response_error <= mem_rd_rsp_error;
                    state <= RESPONSE;
                end
                WRITE_REQUEST: if (mem_wr_valid && mem_wr_ready)
                    state <= WRITE_RESPONSE;
                WRITE_RESPONSE: if (mem_wr_rsp_valid && mem_wr_rsp_ready) begin
                    if (mem_wr_rsp_error) begin
                        response_error <= 1;
                        if (store_hit) valid_bits[set_index] <= 0;
                        state <= RESPONSE;
                    end else if (store_hit)
                        state <= STORE_WRITE;
                    else
                        state <= RESPONSE;
                end
                STORE_WRITE: state <= RESPONSE;
                RESPONSE: if (rsp_valid && rsp_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
