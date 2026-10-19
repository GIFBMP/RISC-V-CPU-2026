`timescale 1ns/1ps
module writeback_memory_tb #(parameter integer CACHE_LINE_BYTES = 16,
    parameter integer ICACHE_LINE_BYTES = CACHE_LINE_BYTES,
    parameter integer DCACHE_BYTES = 256, parameter integer DCACHE_WAYS = 2,
    parameter integer FAST_HIT_RESPONSE = 0, parameter integer FAST_INSTRUCTION_RESPONSE = 0,
    parameter integer PIPELINED_STORE_HITS = 0);
    localparam integer WAY_BYTES = DCACHE_BYTES / DCACHE_WAYS;
    localparam integer LINE_WORDS = CACHE_LINE_BYTES / 4;
    localparam integer I_LINE_WORDS = ICACHE_LINE_BYTES / 4;
    localparam integer CONCURRENT_WORDS = LINE_WORDS < I_LINE_WORDS ? LINE_WORDS : I_LINE_WORDS;
    localparam integer WRITE_CREDITS = 16;
    localparam integer CACHE_LINES = DCACHE_BYTES / CACHE_LINE_BYTES;
    localparam integer FLUSH_GROUP_SIZE = CACHE_LINES >= 8 ? 8 : CACHE_LINES;
    reg clock = 1'b0;
    always #5 clock = !clock;
    reg reset = 1'b1;
    reg i_req_valid = 1'b0;
    wire i_req_ready;
    reg [31:0] i_req_addr = 32'b0;
    wire i_rsp_valid;
    reg i_rsp_ready = 1'b0;
    wire [31:0] i_rsp_data;
    wire i_rsp_error;
    reg d_req_valid = 1'b0;
    wire d_req_ready;
    reg d_req_write = 1'b0;
    reg [31:0] d_req_addr = 32'b0;
    reg [31:0] d_req_wdata = 32'b0;
    reg [3:0] d_req_wstrb = 4'b0;
    wire d_rsp_valid;
    reg d_rsp_ready = 1'b0;
    wire [31:0] d_rsp_data;
    wire d_rsp_error;
    wire [31:0] araddr, awaddr, wdata;
    wire [3:0] wstrb;
    wire arvalid, arready, rready, awvalid, awready, wvalid, wready, bready;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rvalid;
    wire [1:0] bresp;
    wire bvalid;

    memory_system #(.CACHE_LINE_BYTES(CACHE_LINE_BYTES), .ICACHE_LINE_BYTES(ICACHE_LINE_BYTES),
        .DCACHE_LINE_BYTES(CACHE_LINE_BYTES), .DCACHE_BYTES(DCACHE_BYTES),
        .DCACHE_WAYS(DCACHE_WAYS), .DCACHE_WRITE_BACK(1),
        .FAST_HIT_RESPONSE(FAST_HIT_RESPONSE), .FAST_INSTRUCTION_RESPONSE(FAST_INSTRUCTION_RESPONSE),
        .PIPELINED_STORE_HITS(PIPELINED_STORE_HITS)) dut (.*);

    reg [31:0] memory [0:16383];
    reg [31:0] expected_memory [0:16383];
    integer verify_word;
    integer cycle = 0;
    integer ar_count = 0, aw_count = 0, w_count = 0, b_count = 0;
    reg [31:0] read_trace [0:2047];
    integer ar_cycle_trace [0:2047];
    reg [31:0] queued_rdata [0:31];
    reg [1:0] queued_rresp [0:31];
    integer queued_due [0:31];
    integer read_head = 0, read_tail = 0, read_count = 0, r_count = 0;
    integer max_read_outstanding = 0;
    integer read_latency = 64;
    reg stall_ar = 1'b1;
    assign rvalid = !reset && read_count != 0 && queued_due[read_head] <= cycle;
    assign rdata = queued_rdata[read_head];
    assign rresp = queued_rresp[read_head];
    reg [31:0] write_addresses [0:31], write_payloads [0:31];
    reg [3:0] write_masks [0:31];
    reg [1:0] write_responses [0:31];
    integer write_due [0:31];
    integer paired_writes = 0, max_write_outstanding = 0;
    integer write_latency = 80;
    reg stall_write = 1'b1;
    // 0: simultaneous; 1: every AW precedes its W; 2: every W precedes AW.
    integer write_order = 0;
    reg read_fault = 1'b0, write_fault = 1'b0;
    reg [31:0] read_fault_address = 32'b0, write_fault_address = 32'b0;
    reg [31:0] exit_value = 32'b0;
    integer exit_count = 0;

    assign arready = !reset && read_count < 16 && (!stall_ar || cycle % 4 == 0);
    assign awready = !reset && aw_count - b_count < 32 && (!stall_write || cycle % 3 == 0) &&
        (write_order != 2 || w_count > aw_count);
    assign wready = !reset && w_count - b_count < 32 && (!stall_write || cycle % 3 == 0) &&
        (write_order != 1 || aw_count > w_count);
    assign bvalid = !reset && paired_writes > b_count && write_due[b_count % 32] <= cycle;
    assign bresp = write_responses[b_count % 32];
    integer lane;
    always @(posedge clock) begin
        if (reset) begin
            cycle <= 0;
            ar_count <= 0;
            aw_count <= 0;
            w_count <= 0;
            b_count <= 0;
            read_head <= 0;
            read_tail <= 0;
            read_count <= 0;
            r_count <= 0;
            paired_writes <= 0;
            max_read_outstanding <= 0;
            max_write_outstanding <= 0;
            exit_count <= 0;
        end else begin
            cycle <= cycle + 1;
            if (rvalid && rready) begin
                read_head <= (read_head + 1) % 32;
                r_count <= r_count + 1;
            end
            case ({arvalid && arready, rvalid && rready})
                2'b10: read_count <= read_count + 1;
                2'b01: read_count <= read_count - 1;
                default: begin end
            endcase
            if (read_count > max_read_outstanding) max_read_outstanding <= read_count;
            if (aw_count - b_count > max_write_outstanding)
                max_write_outstanding <= aw_count - b_count;
            if (aw_count - b_count > WRITE_CREDITS || w_count - b_count > WRITE_CREDITS)
                $fatal(1, "Bridge exceeded sixteen outstanding write credits");
            if (bvalid && bready) b_count <= b_count + 1;
            if (arvalid && arready) begin
                if (araddr[1:0] != 0) $fatal(1, "Unaligned external read address");
                read_trace[ar_count] <= araddr;
                ar_cycle_trace[ar_count] <= cycle;
                ar_count <= ar_count + 1;
                read_tail <= (read_tail + 1) % 32;
                queued_due[read_tail] <= cycle + read_latency;
                queued_rdata[read_tail] <= araddr < 65536 ? memory[araddr >> 2] : 32'b0;
                queued_rresp[read_tail] <= araddr >= 65536 ? 2'b11 :
                    ((read_fault && araddr == read_fault_address) ? 2'b10 : 2'b00);
            end
            if (awvalid && awready) begin
                if (awaddr[1:0] != 0) $fatal(1, "Unaligned external write address");
                if (awaddr == 32'h80000000) begin
                    if (aw_count != b_count)
                        $fatal(1, "Exit AW was issued before all earlier B responses completed");
                    for (verify_word = 0; verify_word < 16384; verify_word = verify_word + 1)
                        if (memory[verify_word] !== expected_memory[verify_word])
                            $fatal(1, "Exit AW preceded dirty RAM visibility: address=%h got=%h expected=%h",
                                32'(verify_word * 4), memory[verify_word], expected_memory[verify_word]);
                end
                write_addresses[aw_count % 32] <= awaddr;
                aw_count <= aw_count + 1;
            end
            if (wvalid && wready) begin
                write_payloads[w_count % 32] <= wdata;
                write_masks[w_count % 32] <= wstrb;
                w_count <= w_count + 1;
            end
            if (aw_count > paired_writes && w_count > paired_writes) begin
                paired_writes <= paired_writes + 1;
                write_due[paired_writes % 32] <= cycle + write_latency;
                write_responses[paired_writes % 32] <= 2'b00;
                if (write_fault && write_addresses[paired_writes % 32] == write_fault_address)
                    write_responses[paired_writes % 32] <= 2'b10;
                else if (write_addresses[paired_writes % 32] == 32'h80000000) begin
                    if (write_masks[paired_writes % 32] == 4'hf) begin
                        exit_value <= write_payloads[paired_writes % 32];
                        exit_count <= exit_count + 1;
                    end else write_responses[paired_writes % 32] <= 2'b10;
                end else if (write_addresses[paired_writes % 32] >= 65536)
                    write_responses[paired_writes % 32] <= 2'b11;
                else begin
                    for (lane = 0; lane < 4; lane = lane + 1)
                        if (write_masks[paired_writes % 32][lane])
                            memory[write_addresses[paired_writes % 32] >> 2][lane*8 +: 8] <=
                                write_payloads[paired_writes % 32][lane*8 +: 8];
                end
            end
        end
    end

    reg held_ar = 1'b0, held_aw = 1'b0, held_w = 1'b0;
    reg held_i_rsp = 1'b0, held_d_rsp = 1'b0;
    reg held_internal_write = 1'b0;
    reg [31:0] last_araddr, last_awaddr, last_wdata, last_i_data, last_d_data;
    reg [31:0] last_internal_addr, last_internal_data;
    reg [3:0] last_internal_mask;
    reg [3:0] last_wstrb;
    reg last_i_error, last_d_error;
    integer cpu_i_outstanding = 0;
    integer cpu_d_outstanding = 0, max_cpu_d_outstanding = 0;
    integer previous_writeback_accept = -1, writeback_streams = 0;
    integer flush_scan_cycles = 0;
    always @(posedge clock) begin
        if (reset) begin
            held_ar <= 1'b0;
            held_aw <= 1'b0;
            held_w <= 1'b0;
            held_i_rsp <= 1'b0;
            held_d_rsp <= 1'b0;
            held_internal_write <= 1'b0;
            cpu_i_outstanding <= 0;
            cpu_d_outstanding <= 0;
            max_cpu_d_outstanding <= 0;
            previous_writeback_accept <= -1;
            writeback_streams <= 0;
            flush_scan_cycles <= 0;
        end else begin
            if (dut.write_back.data_cache.state == 4'd10) flush_scan_cycles <= flush_scan_cycles + 1;
            if (held_internal_write && (!dut.d_wr_valid || dut.d_wr_addr !== last_internal_addr ||
                dut.d_wr_data !== last_internal_data || dut.d_wr_strb !== last_internal_mask))
                $fatal(1, "Cache writeback payload changed while bridge was full");
            held_internal_write <= dut.d_wr_valid && !dut.d_wr_ready;
            last_internal_addr <= dut.d_wr_addr;
            last_internal_data <= dut.d_wr_data;
            last_internal_mask <= dut.d_wr_strb;
            if (dut.d_wr_valid && dut.d_wr_ready && dut.d_wr_addr < 65536) begin
                if (dut.d_wr_data !== expected_memory[dut.d_wr_addr >> 2] || dut.d_wr_strb !== 4'hf)
                    $fatal(1, "Writeback SRAM pipeline lost a word or byte mask at %h", dut.d_wr_addr);
                // Each line starts only after all previous B responses. The
                // bridge has all sixteen credits independent of AW/W stalls.
                if ((dut.d_wr_addr & 32'(CACHE_LINE_BYTES - 1)) == 0)
                    writeback_streams <= writeback_streams + 1;
                else if ((dut.d_wr_addr & 32'(CACHE_LINE_BYTES - 1)) < 4 * WRITE_CREDITS &&
                    cycle != previous_writeback_accept + 1)
                    $fatal(1, "Initial writeback credit burst was not accepted one word per cycle");
                previous_writeback_accept <= cycle;
            end
            if (cpu_i_outstanding < 0 || cpu_i_outstanding > 4 ||
                (i_rsp_valid && cpu_i_outstanding == 0))
                $fatal(1, "I cache violated its four-request ordered response contract");
            case ({i_req_valid && i_req_ready, i_rsp_valid && i_rsp_ready})
                2'b10: cpu_i_outstanding <= cpu_i_outstanding + 1;
                2'b01: cpu_i_outstanding <= cpu_i_outstanding - 1;
                default: begin end
            endcase
            if (cpu_d_outstanding < 0 || cpu_d_outstanding > 4 ||
                (d_rsp_valid && cpu_d_outstanding == 0))
                $fatal(1, "D cache violated its four-request ordered response contract");
            case ({d_req_valid && d_req_ready, d_rsp_valid && d_rsp_ready})
                2'b10: cpu_d_outstanding <= cpu_d_outstanding + 1;
                2'b01: cpu_d_outstanding <= cpu_d_outstanding - 1;
                default: begin end
            endcase
            if (cpu_d_outstanding > max_cpu_d_outstanding)
                max_cpu_d_outstanding <= cpu_d_outstanding;
            if (held_ar && (!arvalid || araddr !== last_araddr))
                $fatal(1, "AR payload/VALID changed under backpressure");
            if (held_aw && (!awvalid || awaddr !== last_awaddr))
                $fatal(1, "AW payload/VALID changed under backpressure");
            if (held_w && (!wvalid || wdata !== last_wdata || wstrb !== last_wstrb))
                $fatal(1, "W payload/VALID changed under backpressure");
            if (held_i_rsp && (!i_rsp_valid || i_rsp_data !== last_i_data ||
                              i_rsp_error !== last_i_error))
                $fatal(1, "I response changed under backpressure");
            if (held_d_rsp && (!d_rsp_valid || d_rsp_data !== last_d_data ||
                              d_rsp_error !== last_d_error))
                $fatal(1, "D response changed under backpressure");
            held_ar <= arvalid && !arready;
            held_aw <= awvalid && !awready;
            held_w <= wvalid && !wready;
            held_i_rsp <= i_rsp_valid && !i_rsp_ready;
            held_d_rsp <= d_rsp_valid && !d_rsp_ready;
            last_araddr <= araddr;
            last_awaddr <= awaddr;
            last_wdata <= wdata;
            last_wstrb <= wstrb;
            last_i_data <= i_rsp_data;
            last_d_data <= d_rsp_data;
            last_i_error <= i_rsp_error;
            last_d_error <= d_rsp_error;
        end
    end

    task automatic i_read(input [31:0] address, input [31:0] expected,
                          input bit expected_error, input integer stall);
        begin
            @(negedge clock);
            i_req_addr = address;
            i_req_valid = 1'b1;
            i_rsp_ready = 1'b0;
            do @(posedge clock); while (!i_req_ready);
            @(negedge clock);
            i_req_valid = 1'b0;
            do @(posedge clock); while (!i_rsp_valid);
            if (i_rsp_error !== expected_error ||
                (!expected_error && i_rsp_data !== expected))
                $fatal(1, "I read %h: got %h error=%b expected %h error=%b",
                       address, i_rsp_data, i_rsp_error, expected, expected_error);
            repeat (stall) @(posedge clock);
            @(negedge clock);
            i_rsp_ready = 1'b1;
            @(posedge clock);
            @(negedge clock);
            i_rsp_ready = 1'b0;
        end
    endtask

    task automatic check_clean_flush;
        integer scan_before, aw_before;
        begin
            scan_before = flush_scan_cycles;
            aw_before = aw_count;
            d_access(0, 32'h10000000, 0, 0, 0, 1, 0);
            if (aw_count != aw_before)
                $fatal(1, "Fully clean cache unexpectedly wrote back a line");
            if (flush_scan_cycles - scan_before != CACHE_LINES / FLUSH_GROUP_SIZE)
                $fatal(1, "Clean-group flush did not skip every complete group, including final group");
        end
    endtask



    task automatic i_stream(input [31:0] base, input integer length,
                            input integer wrap_words, input bit stall_response,
                            input bit require_full_rate);
        integer sent, received, previous_accept, previous_response, ticks;
        integer accepted_cycle [0:127];
        reg [31:0] expected_address;
        reg expected_error;
        begin
            fork
                begin
                    previous_accept = -1;
                    for (sent = 0; sent < length; sent = sent + 1) begin
                        @(negedge clock);
                        i_req_valid = 1;
                        i_req_addr = base + 4 * (wrap_words == 0 ? sent : sent % wrap_words);
                        do @(posedge clock); while (!i_req_ready);
                        accepted_cycle[sent] = cycle;
                        if (require_full_rate && previous_accept >= 0 && cycle != previous_accept + 1)
                            $fatal(1, "I hit stream did not accept one request per cycle");
                        previous_accept = cycle;
                    end
                    @(negedge clock);
                    i_req_valid = 0;
                end
                begin
                    received = 0;
                    ticks = 0;
                    previous_response = -1;
                    while (received < length) begin
                        @(negedge clock);
                        i_rsp_ready = !stall_response || (ticks % 11 >= 6);
                        @(posedge clock);
                        if (i_rsp_valid && i_rsp_ready) begin
                            if (require_full_rate && cycle - accepted_cycle[received] != (FAST_INSTRUCTION_RESPONSE != 0 ? 1 : 2))
                                $fatal(1, "I hit response latency=%0d expected=%0d", cycle-accepted_cycle[received], FAST_INSTRUCTION_RESPONSE != 0 ? 1 : 2);
                            expected_address = base + 4 * (wrap_words == 0 ? received : received % wrap_words);
                            expected_error = read_fault &&
                                ((expected_address & ~32'(ICACHE_LINE_BYTES-1)) ==
                                 (read_fault_address & ~32'(ICACHE_LINE_BYTES-1)));
                            if (i_rsp_error !== expected_error ||
                                (!expected_error && i_rsp_data !== memory[expected_address >> 2]))
                                $fatal(1, "I stream response %0d at %h is wrong or out of order", received, expected_address);
                            if (require_full_rate && previous_response >= 0 && cycle != previous_response + 1)
                                $fatal(1, "I hit stream did not return one response per cycle");
                            previous_response = cycle;
                            received = received + 1;
                        end
                        ticks = ticks + 1;
                    end
                    @(negedge clock);
                    i_rsp_ready = 0;
                end
            join
        end
    endtask

    // mode 0=Loads, 1=Stores, 2=alternating Store/Load to exercise RAW ordering.
    // Expected data is snapshotted at request acceptance, never read from the
    // evolving oracle at response time; otherwise an ordering bug could hide.
    task automatic d_stream(input [31:0] base, input integer length,
                            input integer wrap_words, input integer mode,
                            input bit stall_response, input bit require_full_rate,
                            input integer stride = 4);
        integer sent, received, previous_accept, previous_response, ticks, byte_lane;
        integer accept_interval, response_interval;
        integer accepted_cycle [0:127];
        reg [31:0] expected_data [0:127];
        reg expected_error [0:127];
        reg [31:0] current_address, current_data;
        reg [3:0] current_mask;
        reg current_write;
        begin
            fork
                begin
                    previous_accept = -1;
                    for (sent = 0; sent < length; sent = sent + 1) begin
                        @(negedge clock);
                        current_address = base + 32'(stride * (wrap_words == 0 ? sent : sent % wrap_words));
                        current_write = mode == 1 || (mode == 2 && sent % 2 == 0);
                        current_data = 32'hd7012345 ^ (32'(sent) * 32'h010a3051);
                        current_mask = 4'b0001 << (sent % 4);
                        d_req_valid = 1;
                        d_req_addr = current_address;
                        d_req_write = current_write;
                        d_req_wdata = current_data;
                        d_req_wstrb = current_mask;
                        do @(posedge clock); while (!d_req_ready);
                        accepted_cycle[sent] = cycle;
                        expected_error[sent] = !current_write && read_fault &&
                            ((current_address & ~32'(CACHE_LINE_BYTES - 1)) ==
                             (read_fault_address & ~32'(CACHE_LINE_BYTES - 1)));
                        expected_data[sent] = current_write ? 32'b0 : expected_memory[current_address >> 2];
                        if (current_write)
                            for (byte_lane = 0; byte_lane < 4; byte_lane = byte_lane + 1)
                                if (current_mask[byte_lane])
                                    expected_memory[current_address >> 2][byte_lane*8 +: 8] = current_data[byte_lane*8 +: 8];
                        accept_interval = mode == 0 ? 1 : (mode == 1 ? (PIPELINED_STORE_HITS != 0 ? 1 : 2) : (sent % 2 == 1 ? 2 : 1));
                        if (require_full_rate && previous_accept >= 0 && cycle != previous_accept + accept_interval)
                            $fatal(1, "D hit stream mode=%0d accept spacing=%0d expected=%0d", mode, cycle-previous_accept, accept_interval);
                        previous_accept = cycle;
                    end
                    @(negedge clock);
                    d_req_valid = 0;
                end
                begin
                    received = 0;
                    ticks = 0;
                    previous_response = -1;
                    while (received < length) begin
                        @(negedge clock);
                        d_rsp_ready = !stall_response || ticks % 17 >= 10;
                        @(posedge clock);
                        if (d_rsp_valid && d_rsp_ready) begin
                            if (require_full_rate && cycle - accepted_cycle[received] != (FAST_HIT_RESPONSE != 0 ? 1 : 2))
                                $fatal(1, "D hit response latency=%0d expected=%0d mode=%0d", cycle-accepted_cycle[received], FAST_HIT_RESPONSE != 0 ? 1 : 2, mode);
                            if (d_rsp_error !== expected_error[received] ||
                                (!expected_error[received] && d_rsp_data !== expected_data[received]))
                                $fatal(1, "D stream response %0d wrong/out of order: data=%h expected=%h error=%b expected=%b",
                                    received, d_rsp_data, expected_data[received], d_rsp_error, expected_error[received]);
                            response_interval = mode == 0 ? 1 : (mode == 1 ? (PIPELINED_STORE_HITS != 0 ? 1 : 2) : (received % 2 == 1 ? 2 : 1));
                            if (require_full_rate && previous_response >= 0 && cycle != previous_response + response_interval)
                                $fatal(1, "D hit stream mode=%0d response spacing=%0d expected=%0d", mode, cycle-previous_response, response_interval);
                            previous_response = cycle;
                            received = received + 1;
                        end
                        ticks = ticks + 1;
                    end
                    @(negedge clock);
                    d_rsp_ready = 0;
                end
            join
        end
    endtask

    task automatic d_access(input bit write_request, input [31:0] address,
                            input [31:0] data, input [3:0] strobe,
                            input [31:0] expected, input bit expected_error,
                            input integer stall);
        begin
            @(negedge clock);
            d_req_addr = address;
            d_req_write = write_request;
            d_req_wdata = data;
            d_req_wstrb = strobe;
            d_req_valid = 1'b1;
            d_rsp_ready = 1'b0;
            do @(posedge clock); while (!d_req_ready);
            @(negedge clock);
            d_req_valid = 1'b0;
            do @(posedge clock); while (!d_rsp_valid);
            if (d_rsp_error !== expected_error ||
                (!write_request && !expected_error && d_rsp_data !== expected))
                $fatal(1, "D %s %h: got %h error=%b expected %h error=%b",
                       write_request ? "write" : "read", address,
                       d_rsp_data, d_rsp_error, expected, expected_error);
            if (aw_count != w_count || aw_count != b_count)
                $fatal(1, "D response was exposed before all writeback channels/B responses drained");
            repeat (stall) @(posedge clock);
            @(negedge clock);
            d_rsp_ready = 1'b1;
            @(posedge clock);
            @(negedge clock);
            d_rsp_ready = 1'b0;
        end
    endtask

    // A Store offered during refill waits for installation, then may execute
    // while the older Load response remains blocked in the ordered FIFO.
    task automatic conflicting_store;
        begin
            @(negedge clock);
            d_req_addr = 32'h904;
            d_req_write = 1'b0;
            d_req_valid = 1'b1;
            d_rsp_ready = 1'b0;
            do @(posedge clock); while (!d_req_ready);
            @(negedge clock);
            d_req_addr = 32'h904;
            d_req_write = 1'b1;
            d_req_wdata = 32'hcafefeed;
            d_req_wstrb = 4'hf;
            do @(posedge clock); while (!d_req_ready);
            if (d_rsp_error || d_rsp_data !== memory[32'h904 >> 2])
                $fatal(1, "Load preceding conflicting Store returned wrong data");
            @(negedge clock);
            d_req_valid = 1'b0;
            repeat (3) @(posedge clock);
            if (!d_rsp_valid || d_rsp_error || d_rsp_data !== memory[32'h904 >> 2])
                $fatal(1, "Younger Store changed the blocked older Load response");
            @(negedge clock);
            d_rsp_ready = 1'b1;
            @(posedge clock);
            @(negedge clock);
            d_rsp_ready = 1'b0;
            do @(posedge clock); while (!d_rsp_valid);
            if (d_rsp_error)
                $fatal(1, "Queued conflicting Store failed");
            @(negedge clock);
            d_rsp_ready = 1'b1;
            @(posedge clock);
            @(negedge clock);
            d_rsp_ready = 1'b0;
        end
    endtask

    task automatic store_checked(input [31:0] address, input [31:0] data,
                                 input [3:0] mask, input integer stall);
        integer byte_lane;
        begin
            d_access(1, address, data, mask, 0, 0, stall);
            for (byte_lane = 0; byte_lane < 4; byte_lane = byte_lane + 1)
                if (mask[byte_lane]) expected_memory[address >> 2][byte_lane*8 +: 8] = data[byte_lane*8 +: 8];
        end
    endtask

    task automatic verify_external;
        integer word_number;
        begin
            for (word_number = 0; word_number < 16384; word_number = word_number + 1)
                if (memory[word_number] !== expected_memory[word_number])
                    $fatal(1, "Flushed RAM mismatch at %h", 32'(word_number * 4));
        end
    endtask

    task automatic flush_and_reset;
        begin
            d_access(0, 32'h10000000, 0, 0, 0, 1, 0);
            verify_external();
            @(negedge clock);
            reset = 1;
            repeat (4) @(posedge clock);
            @(negedge clock);
            reset = 0;
        end
    endtask

    integer index, count_before, writes_before;
    reg [31:0] a, b, c, failed_word_before;
    initial begin
        if ($value$plusargs("READ_LATENCY=%d", read_latency)) begin end
        if ($test$plusargs("FAST_WRITE")) begin
            stall_write = 0;
            write_latency = 1;
        end
        for (index = 0; index < 16384; index = index + 1) begin
            memory[index] = 32'h9e3779b9 ^ (32'(index) * 32'h01020408);
            expected_memory[index] = memory[index];
        end
        repeat (5) @(posedge clock);
        @(negedge clock);
        reset = 0;
        check_clean_flush();
        a = 32'h1000;
        b = a + 32'(WAY_BYTES);
        c = a + 32'(DCACHE_WAYS * WAY_BYTES);

        // Write allocate, partial-byte merge, no external write on a Store hit.
        count_before = ar_count;
        store_checked(a + 4, 32'haabbccdd, 4'b0101, 5);
        if (ar_count != count_before + LINE_WORDS || aw_count != 0)
            $fatal(1, "WB Store miss did not allocate without writing through");
        count_before = ar_count;
        store_checked(a + 4, 32'h11223344, 4'b1010, 0);
        store_checked(a + 4, 32'hffffffff, 0, 0);
        d_access(0, a + 4, 0, 0, expected_memory[(a + 4) >> 2], 0, 4);
        if (ar_count != count_before || aw_count != 0)
            $fatal(1, "WB hit unexpectedly used AXI");
        write_order = 1;
        if (DCACHE_WAYS > 1) begin
            for (index = 1; index < DCACHE_WAYS; index = index + 1)
                d_access(0, a + 32'(index * WAY_BYTES), 0, 0,
                    expected_memory[(a + 32'(index * WAY_BYTES)) >> 2], 0, 0);
            count_before = ar_count;
            d_access(0, a + 4, 0, 0, expected_memory[(a + 4) >> 2], 0, 0);
            d_access(0, b, 0, 0, expected_memory[b >> 2], 0, 0);
            if (ar_count != count_before || aw_count != 0)
                $fatal(1, "Conflicting lines did not coexist in associative cache");
            d_access(0, c, 0, 0, expected_memory[c >> 2], 0, 0);
        end else d_access(0, b, 0, 0, expected_memory[b >> 2], 0, 0);
        if (aw_count != LINE_WORDS || b_count != aw_count || w_count != aw_count)
            $fatal(1, "Dirty eviction did not write each word exactly once (AW first)");
        if (memory[(a + 4) >> 2] !== expected_memory[(a + 4) >> 2])
            $fatal(1, "Dirty eviction lost partial byte updates");
        if (stall_write && max_write_outstanding < (LINE_WORDS < WRITE_CREDITS ? LINE_WORDS : WRITE_CREDITS))
            $fatal(1, "Writeback did not use every line/bridge credit before B responses");
        if (writeback_streams < 1) $fatal(1, "Writeback streaming coverage was not exercised");
        flush_and_reset();

        // Fail the second writeback word after the first has become visible.
        // The complete original dirty line must remain readable and retryable.
        write_order = 0;
        for (index = 0; index < LINE_WORDS; index = index + 1)
            store_checked(a + 32'(4 * index), 32'hcafe0000 + 32'(index), 4'hf, 0);
        for (index = 1; index < DCACHE_WAYS; index = index + 1)
            d_access(0, a + 32'(index * WAY_BYTES), 0, 0,
                expected_memory[(a + 32'(index * WAY_BYTES)) >> 2], 0, 0);
        failed_word_before = memory[(a + 4) >> 2];
        write_fault = 1;
        write_fault_address = a + 4;
        count_before = ar_count;
        writes_before = aw_count;
        d_access(0, c, 0, 0, 0, 1, 7);
        if (aw_count != writes_before + LINE_WORDS || ar_count != count_before)
            $fatal(1, "Failed dirty victim was overwritten or replacement refill started");
        if (memory[a >> 2] !== expected_memory[a >> 2] || memory[(a + 4) >> 2] !== failed_word_before)
            $fatal(1, "Error injection did not produce a partially visible writeback");
        for (index = 0; index < LINE_WORDS; index = index + 1)
            d_access(0, a + 32'(4 * index), 0, 0, expected_memory[(a >> 2) + index], 0, 0);
        if (ar_count != count_before) $fatal(1, "Failed eviction did not retain its complete dirty line");
        write_fault = 0;
        if (DCACHE_WAYS > 1) d_access(0, b, 0, 0, expected_memory[b >> 2], 0, 0);
        writes_before = aw_count;
        d_access(0, c, 0, 0, expected_memory[c >> 2], 0, 0);
        if (aw_count != writes_before + LINE_WORDS || ar_count != count_before + LINE_WORDS)
            $fatal(1, "Retry did not rewrite the complete dirty victim before refill");
        verify_external();
        flush_and_reset();

        // A failed flush must not send exit MMIO. A later retry flushes every
        // dirty row and only then issues exit AW; the bus monitor checks RAM
        // contents and completion of all preceding B responses at that instant.
        a = 32'h2000;
        b = a + 32'(CACHE_LINE_BYTES);
        store_checked(a, 32'h12345678, 4'hf, 0);
        store_checked(a + 4, 32'habcdef01, 4'hf, 0);
        store_checked(b, 32'h87654321, 4'hf, 0);
        write_fault = 1;
        write_fault_address = a + 4;
        writes_before = aw_count;
        d_access(1, 32'h80000000, 32'hfeedface, 4'hf, 0, 1, 8);
        if (exit_count != 0 || aw_count != writes_before + LINE_WORDS)
            $fatal(1, "Failed flush issued MMIO or lost failure position");
        count_before = ar_count;
        d_access(0, a + 4, 0, 0, expected_memory[(a + 4) >> 2], 0, 0);
        if (ar_count != count_before) $fatal(1, "Failed flush lost cached data");
        write_fault = 0;
        write_order = 2;
        writes_before = aw_count;
        d_access(1, 32'h80000000, 32'hfeedface, 4'hf, 0, 0, 3);
        if (exit_count != 1 || exit_value !== 32'hfeedface || aw_count != writes_before + 2 * LINE_WORDS + 1)
            $fatal(1, "Flush retry did not write every dirty word before exit (W first)");
        verify_external();
        writes_before = aw_count;
        d_access(1, 32'h80000000, 32'h01020304, 4'hf, 0, 0, 0);
        if (aw_count != writes_before + 1) $fatal(1, "Clean flush wrote cache lines again");
        d_access(1, 32'h80000000, 0, 4'h1, 0, 1, 0);
        store_checked(b + 4, 32'hc001cafe, 4'hf, 0);
        count_before = ar_count;
        d_access(0, 32'h80000000, 0, 0, 0, 1, 0);
        d_access(0, 32'h80000000, 0, 0, 0, 1, 0);
        if (ar_count != count_before + 2) $fatal(1, "Uncached read was cached/refilled");
        verify_external();

        // A failed read allocate drains all in-flight words and never installs.
        read_fault = 1;
        read_fault_address = 32'h3008;
        count_before = ar_count;
        d_access(1, 32'h3004, 32'hdeadbeef, 4'hf, 0, 1, 5);
        if (ar_count != count_before + LINE_WORDS || ar_count != r_count)
            $fatal(1, "Faulting write-allocate did not drain the whole refill");
        read_fault_address = 32'h3000 + 32'(CACHE_LINE_BYTES - 4);
        count_before = ar_count;
        d_access(0, 32'h3004, 0, 0, 0, 1, 4);
        if (ar_count != count_before + LINE_WORDS || ar_count != r_count)
            $fatal(1, "Last-word refill error was lost or not fully drained");
        read_fault = 0;
        count_before = ar_count;
        d_access(0, 32'h3004, 0, 0, expected_memory[32'h3004 >> 2], 0, 0);
        if (ar_count != count_before + LINE_WORDS)
            $fatal(1, "Failed write allocate became valid or applied the Store");
        store_checked(32'h3004, 32'hffffffff, 0, 0);
        writes_before = aw_count;
        d_access(0, 32'h10000000, 0, 0, 0, 1, 0);
        if (aw_count != writes_before) $fatal(1, "Zero-mask Store made a clean line dirty");

        flush_and_reset();
        // Dirty every way of both the first and final set. In particular, the
        // final scan row and its final B response must not be skipped by flush.
        a = 32'h4000;
        for (index = 0; index < DCACHE_WAYS; index = index + 1) begin
            store_checked(a + 32'(index * WAY_BYTES), 32'h11110000 + 32'(index), 4'hf, 0);
            store_checked(a + 32'((index + 1) * WAY_BYTES - 4), 32'h22220000 + 32'(index), 4'hf, 0);
        end
        write_fault = 1;
        write_fault_address = a + 32'(DCACHE_BYTES - 4);
        writes_before = aw_count;
        d_access(1, 32'h80000000, 32'habcdabcd, 4'hf, 0, 1, 6);
        if (exit_count != 0 || aw_count != writes_before +
            (WAY_BYTES == CACHE_LINE_BYTES ? 1 : 2) * DCACHE_WAYS * LINE_WORDS)
            $fatal(1, "Flush failed to visit every way/last set or lost final-word B error");
        write_fault = 0;
        writes_before = aw_count;
        d_access(1, 32'h80000000, 32'habcdabcd, 4'hf, 0, 0, 0);
        if (exit_count != 1 || aw_count != writes_before + LINE_WORDS + 1)
            $fatal(1, "Last-row retry did not preserve exactly the failed dirty line");
        verify_external();
        check_clean_flush();

        count_before = ar_count;
        writes_before = aw_count;
        d_access(0, 32'h305, 0, 0, 0, 1, 0);
        d_access(1, 32'h305, 1, 4'hf, 0, 1, 0);
        if (ar_count != count_before || aw_count != writes_before)
            $fatal(1, "Misaligned request reached AXI");
        flush_and_reset();

        count_before = ar_count;
        fork
            i_read(32'h5004, memory[32'h5004 >> 2], 0, 30);
            d_access(0, 32'h6008, 0, 0, expected_memory[32'h6008 >> 2], 0, 0);
        join
        if (ar_count != count_before + LINE_WORDS + I_LINE_WORDS)
            $fatal(1, "Concurrent I/D misses lost refill words");
        // Different I/D line sizes legitimately leave one source alone at the
        // tail. Demand alternation while both sources still have words to issue.
        for (index = count_before + 1; index < count_before + 2 * CONCURRENT_WORDS; index = index + 1)
            if (read_trace[index][31:12] == read_trace[index-1][31:12])
                $fatal(1, "I/D read arbitration was not fair");
        conflicting_store();
        expected_memory[32'h904 >> 2] = 32'hcafefeed;
        d_access(0, 32'h904, 0, 0, 32'hcafefeed, 0, 2);
        d_access(0, 32'h8000, 0, 0, expected_memory[32'h8000 >> 2], 0, 0);
        d_access(0, 32'h8010, 0, 0, expected_memory[32'h8010 >> 2], 0, 0);
        count_before = ar_count;
        writes_before = aw_count;
        d_stream(32'h8000, 64, 8, 0, 0, 1);
        d_stream(32'h8000, 64, 8, 0, 1, 0);
        if (max_cpu_d_outstanding != 4) $fatal(1, "D response backpressure failed to exercise all four credits");
        d_stream(32'h8004, 32, 1, 1, 0, 1);
        d_stream(32'h8000, 64, 8, 1, 0, 1);
        d_stream(32'h8000, 64, 8, 0, 0, 1);
        d_stream(32'h8004, 64, 1, 2, 0, 1);
        d_stream(32'h8004, 64, 1, 2, 1, 0);
        if (ar_count != count_before || aw_count != writes_before)
            $fatal(1, "Warm D Load/Store stream unexpectedly used AXI");
        d_access(0, 32'h8004, 0, 0, expected_memory[32'h8004 >> 2], 0, 0);
        // Consecutive tag-only Store lookups must choose the correct way even
        // while the previous Store updates another way's single-port data SRAM.
        for (index = 0; index < DCACHE_WAYS; index = index + 1)
            d_access(0, 32'hc000 + 32'(index * WAY_BYTES), 0, 0,
                expected_memory[(32'hc000 + 32'(index * WAY_BYTES)) >> 2], 0, 0);
        count_before = ar_count;
        writes_before = aw_count;
        d_stream(32'hc000, 64, DCACHE_WAYS, 1, 0, 1, WAY_BYTES);
        d_stream(32'hc000, 64, DCACHE_WAYS, 1, 1, 0, WAY_BYTES);
        d_stream(32'hc000, 64, DCACHE_WAYS, 0, 0, 1, WAY_BYTES);
        if (ar_count != count_before || aw_count != writes_before)
            $fatal(1, "Warm multi-way Store stream unexpectedly used AXI");
        // A tag-only Store miss must not update bytes if the very last refill
        // response fails; the following Load must re-fetch the original line.
        read_fault = 1;
        read_fault_address = 32'hb000 + 32'(CACHE_LINE_BYTES - 4);
        d_access(1, 32'hb004, 32'hdeadabcd, 4'hf, 0, 1, 7);
        read_fault = 0;
        count_before = ar_count;
        d_access(0, 32'hb004, 0, 0, expected_memory[32'hb004 >> 2], 0, 0);
        if (ar_count != count_before + LINE_WORDS)
            $fatal(1, "Faulting tag-only Store miss installed or modified its line");
        // A Store miss after accepted hit responses must block and later resume
        // the stream without losing either the older response or its byte writes.
        d_stream(32'hdff0, 12, 0, 1, 1, 0);
        d_stream(32'hdff0, 12, 0, 0, 1, 0);
        // Cross-line misses and a faulting line must not lose/reorder already
        // accepted old hits, even while responses repeatedly fill the FIFO.
        d_stream(32'h9000, 32, 0, 0, 1, 0);
        read_fault = 1;
        read_fault_address = 32'ha008;
        d_stream(32'h9ff0, 12, 0, 0, 1, 0);
        read_fault = 0;
        count_before = ar_count;
        d_access(0, 32'ha004, 0, 0, expected_memory[32'ha004 >> 2], 0, 0);
        if (ar_count != count_before + LINE_WORDS) $fatal(1, "Faulting D stream line was installed");
        i_read(32'h7000, memory[32'h7000 >> 2], 0, 0);
        i_read(32'h7010, memory[32'h7010 >> 2], 0, 0);
        count_before = ar_count;
        i_stream(32'h7000, 48, 8, 0, 1);
        i_stream(32'h7000, 48, 8, 1, 0);
        if (ar_count != count_before) $fatal(1, "SRAM I tags lost full-rate hit stream");
        i_stream(32'h7400, 24, 0, 1, 0);
        read_fault = 1;
        read_fault_address = 32'h7808;
        i_stream(32'h77f0, 12, 0, 1, 0);
        read_fault = 0;
        count_before = ar_count;
        i_read(32'h7804, memory[32'h7804 >> 2], 0, 0);
        if (ar_count != count_before + I_LINE_WORDS) $fatal(1, "Erroneous I line was installed");
        flush_and_reset();
        d_access(0, 32'h904, 0, 0, expected_memory[32'h904 >> 2], 0, 0);
        if (ar_count != LINE_WORDS) $fatal(1, "Reset did not invalidate SRAM tags");
        $display("PASS writeback_memory: ways=%0d bytes=%0d line=%0d i_line=%0d fast_d=%0d fast_i=%0d pipeline_store=%0d D Load=1/cycle Store=1/%0dcycles WB=1word/cycle, ordered four-credit streams, dirty retry/MMIO/SRAM/AXI", DCACHE_WAYS, DCACHE_BYTES, CACHE_LINE_BYTES, ICACHE_LINE_BYTES, FAST_HIT_RESPONSE, FAST_INSTRUCTION_RESPONSE, PIPELINED_STORE_HITS, PIPELINED_STORE_HITS != 0 ? 1 : 2);
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "writeback_memory test timed out");
    end
endmodule
