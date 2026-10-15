// Blocking, write-back/write-allocate D cache. Tag and data arrays are genuine
// synchronous 1RW SRAMs. Only committed CPU Stores may reach this interface.
// Every uncached D access flushes all dirty lines before its AXI transaction.
// A writeback error preserves the entire dirty victim and faults the triggering
// request; retrying a later eviction/flush writes the complete line again.
module dcache_writeback #(
    parameter integer CACHE_BYTES = 4096,
    parameter integer LINE_BYTES = 16,
    parameter integer WAYS = 2
) (
    input wire clock, reset,
    input wire req_valid,
    output wire req_ready,
    input wire req_write,
    input wire [31:0] req_addr, req_wdata,
    input wire [3:0] req_wstrb,
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
    input wire mem_rd_rsp_error,
    output wire mem_wr_valid,
    input wire mem_wr_ready,
    output wire [31:0] mem_wr_addr, mem_wr_data,
    output wire [3:0] mem_wr_strb,
    input wire mem_wr_rsp_valid,
    output wire mem_wr_rsp_ready,
    input wire mem_wr_rsp_error
);
    localparam integer SAFE_WAYS = WAYS == 4 ? 4 : (WAYS == 2 ? 2 : 1);
    localparam integer WAY_BITS = SAFE_WAYS > 1 ? $clog2(SAFE_WAYS) : 1;
    localparam integer WAY_BYTES = CACHE_BYTES >= SAFE_WAYS * 4 ? CACHE_BYTES / SAFE_WAYS : 4;
    localparam integer SETS = LINE_BYTES >= 4 && WAY_BYTES >= LINE_BYTES ? WAY_BYTES / LINE_BYTES : 1;
    localparam integer LINES = SETS * SAFE_WAYS;
    localparam integer WORDS = WAY_BYTES / 4;
    localparam integer LINE_WORDS = LINE_BYTES >= 4 ? LINE_BYTES / 4 : 1;
    localparam integer SET_BITS = SETS > 1 ? $clog2(SETS) : 1;
    localparam integer SET_SHIFT = SETS > 1 ? $clog2(SETS) : 0;
    localparam integer LINE_BITS = LINES > 1 ? $clog2(LINES) : 1;
    localparam integer WORD_BITS = WORDS > 1 ? $clog2(WORDS) : 1;
    localparam integer COUNT_BITS = $clog2(LINE_WORDS + 1);
    localparam integer LINE_OFFSET = LINE_BYTES >= 4 ? $clog2(LINE_BYTES) : 2;
    localparam integer TAG_SHIFT = $clog2(WAY_BYTES);
    localparam integer TAG_BITS = 32 - TAG_SHIFT;
    generate
        if ((WAYS != 1 && WAYS != 2 && WAYS != 4) || CACHE_BYTES < WAYS * 4 ||
            CACHE_BYTES > 2097152 || LINE_BYTES < 4 || LINE_BYTES > WAY_BYTES ||
            (CACHE_BYTES & (CACHE_BYTES - 1)) != 0 ||
            (LINE_BYTES & (LINE_BYTES - 1)) != 0) begin : invalid_parameters
            dcache_writeback_requires_one_two_or_four_ways_and_power_of_two_sizes invalid_configuration();
        end
    endgenerate

    localparam [3:0] IDLE = 0, LOOKUP = 1, STORE_HIT = 2, REFILL = 3,
        REFILL_FINISH = 4, INSTALL = 5, WB_READ = 6, WB_CAPTURE = 7,
        WB_SEND = 8, WB_WAIT = 9, FLUSH_SCAN = 10, FLUSH_TAG = 11,
        FLUSH_ADVANCE = 12, BYPASS_REQUEST = 13, BYPASS_RESPONSE = 14,
        RESPONSE = 15;
    reg [3:0] state;
    reg [31:0] address, store_data, response_data;
    reg [3:0] store_strobe;
    reg request_write, response_error, refill_error;
    reg [WAY_BITS-1:0] selected_way;
    reg wb_for_flush, wb_error;
    reg [SET_BITS-1:0] victim_set;
    reg [31:0] wb_base, wb_data;
    reg [COUNT_BITS-1:0] wb_word, wb_received, issued_words, received_words;
    reg [LINE_BITS-1:0] scan_line;
    reg [LINES-1:0] valid_bits, dirty_bits;
    reg [WAY_BITS-1:0] replacement_next [0:SETS-1];
    wire [TAG_BITS-1:0] tag_rdata [0:SAFE_WAYS-1];
    wire [31:0] data_rdata [0:SAFE_WAYS-1];
    wire [SET_BITS-1:0] input_set = SET_BITS'((req_addr >> LINE_OFFSET) & (SETS - 1));
    wire [SET_BITS-1:0] request_set = SET_BITS'((address >> LINE_OFFSET) & (SETS - 1));
    wire [WORD_BITS-1:0] request_word = WORD_BITS'((address >> 2) & (WORDS - 1));
    wire [COUNT_BITS-1:0] requested_word = COUNT_BITS'((address >> 2) & (LINE_WORDS - 1));
    wire [SET_BITS-1:0] scan_set = SET_BITS'(scan_line & LINE_BITS'(SETS - 1));
    wire [WAY_BITS-1:0] scan_way = WAY_BITS'(scan_line >> SET_SHIFT);
    wire [LINE_BITS-1:0] selected_line = LINE_BITS'(selected_way) * LINE_BITS'(SETS) + LINE_BITS'(victim_set);
    wire [LINE_BITS-1:0] request_line = LINE_BITS'(selected_way) * LINE_BITS'(SETS) + LINE_BITS'(request_set);
    wire request_fire = req_valid && req_ready;
    wire initial_lookup = request_fire && req_addr[1:0] == 0 && req_addr[31:28] == 0;
    wire rd_fire = mem_rd_rsp_valid && mem_rd_rsp_ready;
    wire wr_fire = mem_wr_rsp_valid && mem_wr_rsp_ready;
    wire wb_active = state == WB_READ || state == WB_CAPTURE || state == WB_SEND || state == WB_WAIT;
    wire wb_complete = state == WB_WAIT && wb_received == COUNT_BITS'(LINE_WORDS);
    wire refill_last = received_words == COUNT_BITS'(LINE_WORDS - 1);
    wire [SAFE_WAYS-1:0] hits;
    wire hit = |hits;
    reg [WAY_BITS-1:0] hit_way, replacement_way;
    integer select_way;
    always @* begin
        hit_way = 0;
        replacement_way = replacement_next[request_set];
        // Descending iteration makes the lowest invalid way win. Replacement
        // after all ways are valid is round-robin, advanced only on installation.
        for (select_way = SAFE_WAYS - 1; select_way >= 0; select_way = select_way - 1) begin
            if (hits[select_way]) hit_way = WAY_BITS'(select_way);
            if (!valid_bits[select_way * SETS + int'(request_set)])
                replacement_way = WAY_BITS'(select_way);
        end
    end
    wire [LINE_BITS-1:0] replacement_line = LINE_BITS'(replacement_way) * LINE_BITS'(SETS) + LINE_BITS'(request_set);

    genvar way;
    generate
        for (way = 0; way < SAFE_WAYS; way = way + 1) begin : arrays
            assign hits[way] = valid_bits[way * SETS + int'(request_set)] &&
                tag_rdata[way] == address[31:TAG_SHIFT];
            wire tag_write = state == INSTALL && selected_way == WAY_BITS'(way);
            wire tag_read = initial_lookup || state == FLUSH_SCAN;
            wire [SET_BITS-1:0] tag_addr = tag_write ? request_set :
                (state == FLUSH_SCAN ? scan_set : input_set);
            sram_fakeram #(.DEPTH(SETS), .WIDTH(TAG_BITS)) tags (
                .clk(clock), .en(!reset && (tag_read || tag_write)), .we(tag_write),
                .wmask(1'b1), .addr(tag_addr), .wdata(address[31:TAG_SHIFT]),
                .rdata(tag_rdata[way])
            );
            wire selected = selected_way == WAY_BITS'(way);
            wire refill_write = state == REFILL && selected && rd_fire && !mem_rd_rsp_error;
            wire store_write = state == STORE_HIT && selected;
            wire victim_read = state == WB_READ && selected;
            wire data_write = refill_write || store_write;
            wire [WORD_BITS-1:0] data_addr = refill_write ?
                ((request_word & ~WORD_BITS'(LINE_WORDS - 1)) | WORD_BITS'(received_words)) :
                (store_write ? request_word :
                 (victim_read ? (WORD_BITS'(victim_set) * WORD_BITS'(LINE_WORDS) + WORD_BITS'(wb_word)) :
                  WORD_BITS'((req_addr >> 2) & (WORDS - 1))));
            sram_fakeram #(.DEPTH(WORDS), .WIDTH(32), .WRITE_GRANULARITY(8)) data (
                .clk(clock), .en(!reset && (initial_lookup || victim_read || data_write)),
                .we(data_write), .wmask(store_write ? store_strobe : 4'hf), .addr(data_addr),
                .wdata(store_write ? store_data : mem_rd_rsp_data), .rdata(data_rdata[way])
            );
        end
    endgenerate

    // Each metadata row owns its local updates. Avoid a wide vector's shared
    // hold mux, whose control would otherwise fan out across every cache row.
    genvar row;
    generate
        for (row = 0; row < LINES; row = row + 1) begin : metadata
            wire install_here = state == INSTALL && request_line == LINE_BITS'(row);
            wire store_here = state == STORE_HIT && store_strobe != 0 && request_line == LINE_BITS'(row);
            wire evict_clean_here = state == LOOKUP && !hit && replacement_line == LINE_BITS'(row) &&
                !(valid_bits[row] && dirty_bits[row]);
            wire writeback_done_here = wb_complete && !wb_error && selected_line == LINE_BITS'(row);
            always @(posedge clock) begin
                if (reset) begin
                    valid_bits[row] <= 0;
                    dirty_bits[row] <= 0;
                end else begin
                    if (install_here) valid_bits[row] <= 1;
                    else if (evict_clean_here || (writeback_done_here && !wb_for_flush)) valid_bits[row] <= 0;
                    if (store_here) dirty_bits[row] <= 1;
                    else if (install_here || evict_clean_here || writeback_done_here) dirty_bits[row] <= 0;
                end
            end
        end
        for (row = 0; row < SETS; row = row + 1) begin : replacement_metadata
            always @(posedge clock) begin
                if (reset) replacement_next[row] <= 0;
                else if (state == INSTALL && request_set == SET_BITS'(row))
                    replacement_next[row] <= WAY_BITS'((int'(selected_way) + 1) % SAFE_WAYS);
            end
        end
    endgenerate

    assign req_ready = !reset && state == IDLE;
    assign rsp_valid = !reset && state == RESPONSE;
    assign rsp_data = response_data;
    assign rsp_error = response_error;
    assign mem_rd_valid = !reset && ((state == REFILL && issued_words < COUNT_BITS'(LINE_WORDS)) ||
        (state == BYPASS_REQUEST && !request_write));
    assign mem_rd_addr = state == REFILL ?
        ((address & ~32'(LINE_BYTES - 1)) | (32'(issued_words) << 2)) : address;
    assign mem_rd_rsp_ready = !reset && (state == REFILL || (state == BYPASS_RESPONSE && !request_write));
    assign mem_wr_valid = !reset && (state == WB_SEND || (state == BYPASS_REQUEST && request_write));
    assign mem_wr_addr = state == WB_SEND ? wb_base + (32'(wb_word) << 2) : address;
    assign mem_wr_data = state == WB_SEND ? wb_data : store_data;
    assign mem_wr_strb = state == WB_SEND ? 4'hf : store_strobe;
    assign mem_wr_rsp_ready = !reset && (wb_active || (state == BYPASS_RESPONSE && request_write));

    always @(posedge clock) begin
        if (reset) begin
            state <= IDLE;
            address <= 0;
            store_data <= 0;
            store_strobe <= 0;
            request_write <= 0;
            response_data <= 0;
            response_error <= 0;
            refill_error <= 0;
            selected_way <= 0;
            victim_set <= 0;
            wb_for_flush <= 0;
            wb_error <= 0;
            wb_base <= 0;
            wb_data <= 0;
            wb_word <= 0;
            wb_received <= 0;
            issued_words <= 0;
            received_words <= 0;
            scan_line <= 0;
        end else begin
            if (wb_active && wr_fire) begin
                wb_received <= wb_received + 1'b1;
                wb_error <= wb_error || mem_wr_rsp_error;
            end
            case (state)
                IDLE: if (request_fire) begin
                    address <= req_addr;
                    store_data <= req_wdata;
                    store_strobe <= req_wstrb;
                    request_write <= req_write;
                    response_data <= 0;
                    response_error <= 0;
                    if (req_addr[1:0] != 0) begin
                        response_error <= 1;
                        state <= RESPONSE;
                    end else if (req_addr[31:28] != 0) begin
                        scan_line <= 0;
                        state <= FLUSH_SCAN;
                    end else state <= LOOKUP;
                end
                LOOKUP: if (hit) begin
                    selected_way <= hit_way;
                    if (request_write) state <= STORE_HIT;
                    else begin
                        response_data <= data_rdata[hit_way];
                        state <= RESPONSE;
                    end
                end else begin
                    selected_way <= replacement_way;
                    victim_set <= request_set;
                    wb_for_flush <= 0;
                    wb_error <= 0;
                    wb_word <= 0;
                    wb_received <= 0;
                    wb_base <= (32'(tag_rdata[replacement_way]) << TAG_SHIFT) |
                        (32'(request_set) << LINE_OFFSET);
                    issued_words <= 0;
                    received_words <= 0;
                    refill_error <= 0;
                    if (valid_bits[replacement_line] && dirty_bits[replacement_line]) state <= WB_READ;
                    else begin
                        state <= REFILL;
                    end
                end
                STORE_HIT: begin
                    state <= RESPONSE;
                end
                REFILL: begin
                    if (mem_rd_valid && mem_rd_ready) issued_words <= issued_words + 1'b1;
                    if (rd_fire) begin
                        received_words <= received_words + 1'b1;
                        refill_error <= refill_error || mem_rd_rsp_error;
                        if (received_words == requested_word) response_data <= mem_rd_rsp_data;
                        if (refill_last) state <= REFILL_FINISH;
                    end
                end
                REFILL_FINISH: begin
                    if (refill_error) begin
                        response_error <= 1;
                        state <= RESPONSE;
                    end else state <= INSTALL;
                end
                INSTALL: begin
                    if (request_write) begin
                        response_data <= 0;
                        state <= STORE_HIT;
                    end else state <= RESPONSE;
                end
                WB_READ: state <= WB_CAPTURE;
                WB_CAPTURE: begin
                    wb_data <= data_rdata[selected_way];
                    state <= WB_SEND;
                end
                WB_SEND: if (mem_wr_valid && mem_wr_ready) begin
                    if (wb_word == COUNT_BITS'(LINE_WORDS - 1)) state <= WB_WAIT;
                    else begin
                        wb_word <= wb_word + 1'b1;
                        state <= WB_READ;
                    end
                end
                WB_WAIT: if (wb_complete) begin
                    if (wb_error) begin
                        // Every issued write drains even after an error. Partial
                        // external visibility cannot destroy our complete dirty copy.
                        response_error <= 1;
                        state <= RESPONSE;
                    end else begin
                        if (wb_for_flush) state <= FLUSH_ADVANCE;
                        else begin
                            state <= REFILL;
                        end
                    end
                end
                FLUSH_SCAN: begin
                    if (valid_bits[scan_line] && dirty_bits[scan_line]) begin
                        selected_way <= scan_way;
                        victim_set <= scan_set;
                        state <= FLUSH_TAG;
                    end else if (scan_line == LINE_BITS'(LINES - 1)) state <= BYPASS_REQUEST;
                    else scan_line <= scan_line + 1'b1;
                end
                FLUSH_TAG: begin
                    wb_base <= (32'(tag_rdata[selected_way]) << TAG_SHIFT) |
                        (32'(victim_set) << LINE_OFFSET);
                    wb_word <= 0;
                    wb_received <= 0;
                    wb_error <= 0;
                    wb_for_flush <= 1;
                    state <= WB_READ;
                end
                FLUSH_ADVANCE: begin
                    if (scan_line == LINE_BITS'(LINES - 1)) state <= BYPASS_REQUEST;
                    else begin
                        scan_line <= scan_line + 1'b1;
                        state <= FLUSH_SCAN;
                    end
                end
                BYPASS_REQUEST: begin
                    if ((request_write && mem_wr_valid && mem_wr_ready) ||
                        (!request_write && mem_rd_valid && mem_rd_ready)) state <= BYPASS_RESPONSE;
                end
                BYPASS_RESPONSE: begin
                    if ((request_write && wr_fire) || (!request_write && rd_fire)) begin
                        response_data <= request_write ? 32'b0 : mem_rd_rsp_data;
                        response_error <= request_write ? mem_wr_rsp_error : mem_rd_rsp_error;
                        state <= RESPONSE;
                    end
                end
                RESPONSE: if (rsp_valid && rsp_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
