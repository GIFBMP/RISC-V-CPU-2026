// Four-credit, ordered write-back/write-allocate D cache. Load hits accept one
// request per cycle; a Store hit reserves the next single-port data-array cycle.
// A miss blocks new requests while older queued responses continue draining.
// Tag and data arrays are genuine synchronous 1RW SRAMs. Only committed CPU
// Stores may reach this interface.
// Every uncached D access flushes all dirty lines before its AXI transaction.
// A writeback error preserves the entire dirty victim and faults the triggering
// request; retrying a later eviction/flush writes the complete line again.
module dcache_writeback #(
    parameter integer CACHE_BYTES = 4096,
    parameter integer LINE_BYTES = 16,
    parameter integer WAYS = 2,
    parameter integer FAST_HIT_RESPONSE = 0,
    parameter integer PIPELINED_STORE_HITS = 0
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
    localparam integer FLUSH_GROUP_SIZE = LINES >= 8 ? 8 : LINES;
    localparam integer FLUSH_GROUP_SHIFT = $clog2(FLUSH_GROUP_SIZE);
    localparam integer FLUSH_GROUPS = LINES / FLUSH_GROUP_SIZE;
    generate
        if ((WAYS != 1 && WAYS != 2 && WAYS != 4) || CACHE_BYTES < WAYS * 4 ||
            CACHE_BYTES > 2097152 || LINE_BYTES < 4 || LINE_BYTES > WAY_BYTES ||
            (CACHE_BYTES & (CACHE_BYTES - 1)) != 0 ||
            (LINE_BYTES & (LINE_BYTES - 1)) != 0 ||
            (FAST_HIT_RESPONSE != 0 && FAST_HIT_RESPONSE != 1) ||
            (PIPELINED_STORE_HITS != 0 && PIPELINED_STORE_HITS != 1)) begin : invalid_parameters
            dcache_writeback_requires_one_two_or_four_ways_and_power_of_two_sizes invalid_configuration();
        end
    endgenerate

    localparam [3:0] IDLE = 0, STORE_HIT = 2, REFILL = 3,
        REFILL_FINISH = 4, INSTALL = 5, WB_READ = 6,
        WB_WAIT = 9, FLUSH_SCAN = 10, FLUSH_TAG = 11,
        FLUSH_ADVANCE = 12, BYPASS_REQUEST = 13, BYPASS_RESPONSE = 14,
        RESPONSE = 15;
    reg [3:0] state;
    reg [31:0] address, store_data, response_data;
    // Tag comparison follows the pre-read address every ready cycle. The
    // installation payload belongs only to an accepted transaction; keeping
    // its distinct enable avoids loading the hit-comparison register with all
    // tag SRAM write-data pins.
    reg [TAG_BITS-1:0] install_tag;
    reg [3:0] store_strobe;
    reg request_write, response_error, refill_error;
    reg lookup_valid;
    reg [2:0] cpu_count, response_count;
    reg [1:0] response_head, response_tail;
    reg [31:0] responses [0:3];
    reg [3:0] response_errors;
    reg [WAY_BITS-1:0] selected_way;
    reg wb_for_flush, wb_error;
    reg [SET_BITS-1:0] victim_set;
    reg [31:0] wb_base;
    reg [31:0] wb_queue [0:3];
    reg [1:0] wb_head, wb_tail;
    reg [2:0] wb_count;
    reg wb_read_pending;
    reg [COUNT_BITS-1:0] wb_read_word;
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
    // A ready lookup slot may pre-read an unaccepted address. Only the actual
    // handshake sets lookup_valid; idle payloads cannot write or start AXI work.
    // req_ready also preserves the old Store's exclusive data-array write edge.
    wire initial_lookup = req_ready && req_addr[1:0] == 0 && req_addr[31:28] == 0;
    // Stores need a tag lookup but never consume the initial data read. Their
    // next edge may update the data SRAM while another Store reads the tags.
    wire initial_data_lookup = initial_lookup && (PIPELINED_STORE_HITS == 0 || !req_write);
    wire rd_fire = mem_rd_rsp_valid && mem_rd_rsp_ready;
    wire wr_fire = mem_wr_rsp_valid && mem_wr_rsp_ready;
    wire wb_active = state == WB_READ || state == WB_WAIT;
    wire wb_read_issue = state == WB_READ && wb_read_word < COUNT_BITS'(LINE_WORDS) &&
        (wb_count + 3'(wb_read_pending)) < 3'd4;
    wire wb_send = state == WB_READ && mem_wr_valid && mem_wr_ready;
    wire wb_complete = state == WB_WAIT && wb_received == COUNT_BITS'(LINE_WORDS);
    wire refill_last = received_words == COUNT_BITS'(LINE_WORDS - 1);
    wire [SAFE_WAYS-1:0] hits;
    wire hit = |hits;
    reg [WAY_BITS-1:0] hit_way, replacement_way;
    wire lookup_aligned = address[1:0] == 0;
    wire lookup_cacheable = address[31:28] == 0;
    wire lookup_hit = state == IDLE && lookup_valid && lookup_aligned && lookup_cacheable && hit;
    wire lookup_miss = state == IDLE && lookup_valid && lookup_aligned && lookup_cacheable && !hit;
    wire lookup_fault = state == IDLE && lookup_valid && !lookup_aligned;
    wire lookup_store = lookup_hit && request_write;
    wire lookup_blocks = lookup_valid && !(lookup_aligned && lookup_cacheable && hit &&
        (!request_write || (PIPELINED_STORE_HITS != 0 && req_write)));
    wire response_pop = rsp_valid && rsp_ready;
    wire queue_pop = response_pop && response_count != 0;
    wire response_produce = lookup_hit || lookup_fault || state == RESPONSE;
    wire fast_response = FAST_HIT_RESPONSE != 0 && response_count == 0 && (lookup_hit || lookup_fault);
    wire response_push = response_produce && !(fast_response && rsp_ready);
    reg [31:0] hit_data;
    always @* begin
        hit_data = 0;
        for (integer w = 0; w < SAFE_WAYS; w = w + 1)
            hit_data = hit_data | (data_rdata[w] & {32{hits[w]}});
    end
    wire [31:0] response_push_data = state == RESPONSE ? response_data :
        ((lookup_fault || request_write) ? 32'b0 : hit_data);
    wire response_push_error = state == RESPONSE ? response_error : lookup_fault;
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
    wire [LINE_BITS-1:0] hit_line = LINE_BITS'(hit_way) * LINE_BITS'(SETS) + LINE_BITS'(request_set);
    wire [FLUSH_GROUPS-1:0] dirty_groups;
    reg scan_group_dirty;
    always @* begin
        scan_group_dirty = 0;
        for (integer group_index = 0; group_index < FLUSH_GROUPS; group_index = group_index + 1)
            scan_group_dirty = scan_group_dirty | (dirty_groups[group_index] &&
                (scan_line >> FLUSH_GROUP_SHIFT) == LINE_BITS'(group_index));
    end
    wire skip_clean_group = (scan_line & LINE_BITS'(FLUSH_GROUP_SIZE - 1)) == 0 && !scan_group_dirty;
    generate
        for (genvar group_index = 0; group_index < FLUSH_GROUPS; group_index = group_index + 1) begin : flush_groups
            // Local eight-bit reductions add only one extra load per dirty bit;
            // no full-cache priority chain is required to skip clean regions.
            assign dirty_groups[group_index] = |dirty_bits[group_index * FLUSH_GROUP_SIZE +: FLUSH_GROUP_SIZE];
        end
    endgenerate

    genvar way;
    generate
        for (way = 0; way < SAFE_WAYS; way = way + 1) begin : arrays
            // Read validity on the same edge as the synchronous tag SRAM.
            // Installation/eviction never overlaps req_ready; Store hits only
            // change dirty state. Thus this removes the set-index mux from
            // hit -> wakeup without changing any accepted lookup's latency.
            reg lookup_line_valid;
            always @(posedge clock) begin
                if (reset) lookup_line_valid <= 0;
                else if (req_ready) lookup_line_valid <= valid_bits[way * SETS + int'(input_set)];
            end
            assign hits[way] = lookup_line_valid &&
                tag_rdata[way] == address[31:TAG_SHIFT];
`ifndef SYNTHESIS
            always @(posedge clock) if (!reset && state == IDLE && lookup_valid)
                assert (lookup_line_valid == valid_bits[way * SETS + int'(request_set)]);
`endif
            wire tag_write = state == INSTALL && selected_way == WAY_BITS'(way);
            wire tag_read = initial_lookup || state == FLUSH_SCAN;
            wire [SET_BITS-1:0] tag_addr = tag_write ? request_set :
                (state == FLUSH_SCAN ? scan_set : input_set);
            sram_fakeram #(.DEPTH(SETS), .WIDTH(TAG_BITS)) tags (
                .clk(clock), .en(!reset && (tag_read || tag_write)), .we(tag_write),
                .wmask(1'b1), .addr(tag_addr), .wdata(install_tag),
                .rdata(tag_rdata[way])
            );
            wire selected = selected_way == WAY_BITS'(way);
            wire refill_write = state == REFILL && selected && rd_fire && !mem_rd_rsp_error;
            wire store_write = (state == STORE_HIT && selected) ||
                (lookup_store && hit_way == WAY_BITS'(way));
            wire victim_read = wb_read_issue && selected;
            wire data_write = refill_write || store_write;
            // Prepare each port's address from its registered operation. A
            // pending Store can put its address on every way before the tag
            // comparison settles; only the actual hit authorizes a write.
            // Such a Store lookup cannot overlap an incoming data read.
            wire refill_address = state == REFILL && selected;
            wire store_address = (state == STORE_HIT && selected)
                || (state == IDLE && lookup_valid && request_write);
            wire victim_address = state == WB_READ && selected;
            wire input_address = !(refill_address || store_address || victim_address);
            wire [WORD_BITS-1:0] refill_word =
                (request_word & ~WORD_BITS'(LINE_WORDS - 1)) | WORD_BITS'(received_words);
            wire [WORD_BITS-1:0] victim_word =
                WORD_BITS'(victim_set) * WORD_BITS'(LINE_WORDS) + WORD_BITS'(wb_read_word);
            wire [WORD_BITS-1:0] data_addr =
                (refill_word & {WORD_BITS{refill_address}})
                | (request_word & {WORD_BITS{store_address}})
                | (victim_word & {WORD_BITS{victim_address}})
                | (WORD_BITS'((req_addr >> 2) & (WORDS - 1)) & {WORD_BITS{input_address}});
            sram_fakeram #(.DEPTH(WORDS), .WIDTH(32), .WRITE_GRANULARITY(8)) data (
                .clk(clock), .en(!reset && (initial_data_lookup || victim_read || data_write)),
                .we(data_write), .wmask(store_write ? store_strobe : 4'hf), .addr(data_addr),
                .wdata(store_write ? store_data : mem_rd_rsp_data), .rdata(data_rdata[way])
            );
`ifndef SYNTHESIS
            wire [WORD_BITS-1:0] previous_address = refill_write ? refill_word
                : store_write ? request_word : victim_read ? victim_word
                : WORD_BITS'((req_addr >> 2) & (WORDS - 1));
            always @(posedge clock) if (!reset && (initial_data_lookup || victim_read || data_write)) begin
                assert (data_addr == previous_address);
                assert ($onehot({refill_address,store_address,victim_address,input_address}));
            end
`endif
        end
    endgenerate

    // A synchronous SRAM read reserves one FIFO slot before it starts. Its
    // output is captured on the immediately following edge, even if AXI stalls
    // and the disabled SRAM drives X. Read, capture and send overlap at 1/cycle.
    reg [31:0] wb_selected_data;
    always @* begin
        wb_selected_data = 0;
        for (integer slot = 0; slot < 4; slot = slot + 1)
            wb_selected_data = wb_selected_data | (wb_queue[slot] & {32{wb_head == 2'(slot)}});
    end
    generate
        for (genvar slot = 0; slot < 4; slot = slot + 1) begin : writeback_slots
            always @(posedge clock) begin
                if (!reset && wb_read_pending && wb_tail == 2'(slot))
                    wb_queue[slot] <= data_rdata[selected_way];
            end
        end
    endgenerate

    // Each metadata row owns its local updates. Avoid a wide vector's shared
    // hold mux, whose control would otherwise fan out across every cache row.
    genvar row;
    generate
        for (row = 0; row < LINES; row = row + 1) begin : metadata
            wire install_here = state == INSTALL && request_line == LINE_BITS'(row);
            wire store_here = store_strobe != 0 &&
                ((state == STORE_HIT && request_line == LINE_BITS'(row)) ||
                 (lookup_store && hit_line == LINE_BITS'(row)));
            wire evict_clean_here = lookup_miss && replacement_line == LINE_BITS'(row) &&
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

    // Registered credit accounting keeps rsp_ready out of the request path.
    // The executing lookup/miss already owns its eventual response FIFO slot.
    assign req_ready = !reset && state == IDLE && !lookup_blocks && cpu_count < 3'd4;
    // An empty FIFO may expose the completed synchronous lookup directly. A
    // stalled direct response is captured at this edge before the SRAM output
    // changes, so the following queued response holds identical data and error.
    // Miss/WB responses keep their existing fully validated, registered path.
    assign rsp_valid = !reset && (response_count != 0 || fast_response);
    reg [31:0] response_selected_data;
    reg response_selected_error;
    always @* begin
        response_selected_data = 0;
        response_selected_error = 0;
        for (integer slot = 0; slot < 4; slot = slot + 1) begin
            response_selected_data = response_selected_data | (responses[slot] & {32{response_head == 2'(slot)}});
            response_selected_error = response_selected_error | (response_errors[slot] && response_head == 2'(slot));
        end
    end
    // FIFO ownership is available before the tag comparison. With an empty
    // FIFO, prepare the direct lookup payload even before it is authorized;
    // rsp_valid/response_push retain the original hit and response protocol.
    wire direct_response_payload = FAST_HIT_RESPONSE != 0 && response_count == 0;
    assign rsp_data = direct_response_payload ? response_push_data : response_selected_data;
    assign rsp_error = direct_response_payload ? response_push_error : response_selected_error;
`ifndef SYNTHESIS
    always @(posedge clock) if (!reset && rsp_valid) begin
        assert (rsp_data == (fast_response ? response_push_data : response_selected_data));
        assert (rsp_error == (fast_response ? response_push_error : response_selected_error));
    end
`endif
    generate
        for (genvar slot = 0; slot < 4; slot = slot + 1) begin : response_slots
            always @(posedge clock) begin
                if (!reset && response_push && response_tail == 2'(slot)) begin
                    responses[slot] <= response_push_data;
                    response_errors[slot] <= response_push_error;
                end
            end
        end
    endgenerate
    assign mem_rd_valid = !reset && ((state == REFILL && issued_words < COUNT_BITS'(LINE_WORDS)) ||
        (state == BYPASS_REQUEST && !request_write));
    assign mem_rd_addr = state == REFILL ?
        ((address & ~32'(LINE_BYTES - 1)) | (32'(issued_words) << 2)) : address;
    assign mem_rd_rsp_ready = !reset && (state == REFILL || (state == BYPASS_RESPONSE && !request_write));
    assign mem_wr_valid = !reset && ((state == WB_READ && wb_count != 0) ||
        (state == BYPASS_REQUEST && request_write));
    assign mem_wr_addr = state == WB_READ ? wb_base + (32'(wb_word) << 2) : address;
    assign mem_wr_data = state == WB_READ ? wb_selected_data : store_data;
    assign mem_wr_strb = state == WB_READ ? 4'hf : store_strobe;
    assign mem_wr_rsp_ready = !reset && (wb_active || (state == BYPASS_RESPONSE && request_write));

    always @(posedge clock) begin
        if (reset) begin
            state <= IDLE;
            address <= 0;
            install_tag <= 0;
            store_data <= 0;
            store_strobe <= 0;
            request_write <= 0;
            response_data <= 0;
            response_error <= 0;
            refill_error <= 0;
            lookup_valid <= 0;
            cpu_count <= 0;
            response_count <= 0;
            response_head <= 0;
            response_tail <= 0;
            selected_way <= 0;
            victim_set <= 0;
            wb_for_flush <= 0;
            wb_error <= 0;
            wb_base <= 0;
            wb_head <= 0;
            wb_tail <= 0;
            wb_count <= 0;
            wb_read_pending <= 0;
            wb_read_word <= 0;
            wb_word <= 0;
            wb_received <= 0;
            issued_words <= 0;
            received_words <= 0;
            scan_line <= 0;
        end else begin
            wb_read_pending <= wb_read_issue;
            if (wb_read_issue) wb_read_word <= wb_read_word + 1'b1;
            if (wb_read_pending) wb_tail <= wb_tail + 1'b1;
            if (wb_send) wb_head <= wb_head + 1'b1;
            case ({wb_read_pending, wb_send})
                2'b10: wb_count <= wb_count + 1'b1;
                2'b01: wb_count <= wb_count - 1'b1;
                default: ;
            endcase
            lookup_valid <= request_fire;
            if (request_fire) install_tag <= req_addr[31:TAG_SHIFT];
            if (req_ready) begin
                address <= req_addr;
                store_data <= req_wdata;
                store_strobe <= req_wstrb;
                request_write <= req_write;
                response_data <= 0;
                response_error <= 0;
            end
            if (response_push) response_tail <= response_tail + 1'b1;
            if (queue_pop) response_head <= response_head + 1'b1;
            case ({request_fire, response_pop})
                2'b10: cpu_count <= cpu_count + 1'b1;
                2'b01: cpu_count <= cpu_count - 1'b1;
                default: ;
            endcase
            case ({response_push, queue_pop})
                2'b10: response_count <= response_count + 1'b1;
                2'b01: response_count <= response_count - 1'b1;
                default: ;
            endcase
            if (wb_active && wr_fire) begin
                wb_received <= wb_received + 1'b1;
                wb_error <= wb_error || mem_wr_rsp_error;
            end
            case (state)
                IDLE: if (lookup_valid && lookup_aligned) begin
                    if (!lookup_cacheable) begin
                        scan_line <= 0;
                        state <= FLUSH_SCAN;
                    end else if (!hit) begin
                        selected_way <= replacement_way;
                        victim_set <= request_set;
                        wb_for_flush <= 0;
                        wb_error <= 0;
                        wb_word <= 0;
                        wb_received <= 0;
                        wb_read_word <= 0;
                        wb_head <= 0;
                        wb_tail <= 0;
                        wb_count <= 0;
                        wb_base <= (32'(tag_rdata[replacement_way]) << TAG_SHIFT) |
                            (32'(request_set) << LINE_OFFSET);
                        issued_words <= 0;
                        received_words <= 0;
                        refill_error <= 0;
                        if (valid_bits[replacement_line] && dirty_bits[replacement_line]) state <= WB_READ;
                        else state <= REFILL;
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
                WB_READ: if (wb_send) begin
                    if (wb_word == COUNT_BITS'(LINE_WORDS - 1)) state <= WB_WAIT;
                    wb_word <= wb_word + 1'b1;
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
                    if (skip_clean_group) begin
                        if (scan_line == LINE_BITS'(LINES - FLUSH_GROUP_SIZE)) state <= BYPASS_REQUEST;
                        else scan_line <= scan_line + LINE_BITS'(FLUSH_GROUP_SIZE);
                    end else if (valid_bits[scan_line] && dirty_bits[scan_line]) begin
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
                    wb_read_word <= 0;
                    wb_head <= 0;
                    wb_tail <= 0;
                    wb_count <= 0;
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
                RESPONSE: state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
`ifndef SYNTHESIS
    always @(posedge clock) if (!reset) begin
        assert (cpu_count <= 4 && response_count <= cpu_count);
        assert (cpu_count == response_count + 3'((state != IDLE) || lookup_valid));
        assert (!response_push || response_count < 4 || queue_pop);
        assert (!request_fire || state == IDLE);
        assert (!(lookup_store && initial_data_lookup));
        if (state == INSTALL) assert (install_tag == address[31:TAG_SHIFT]);
        if (state == IDLE && lookup_valid && lookup_aligned && lookup_cacheable)
            assert ($onehot0(hits));
        assert (wb_count + 3'(wb_read_pending) <= 4);
        assert (!wb_read_pending || wb_active);
        assert (!wb_active || wb_word <= wb_read_word);
        assert (state != WB_WAIT || (wb_count == 0 && !wb_read_pending));
    end
`endif
endmodule
