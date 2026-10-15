`timescale 1ns/1ps
module memory_system_tb #(parameter integer CACHE_LINE_BYTES = 16);
    localparam integer LINE_WORDS = CACHE_LINE_BYTES / 4;
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
    reg [1:0] bresp = 2'b0;
    reg bvalid = 1'b0;

    memory_system #(.CACHE_LINE_BYTES(CACHE_LINE_BYTES)) dut (.*);

    reg [31:0] memory [0:16383];
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
    reg aw_saved = 1'b0, w_saved = 1'b0, write_pending = 1'b0;
    reg [31:0] pending_awaddr, pending_wdata;
    reg [3:0] pending_wstrb;
    reg [1:0] pending_bresp;
    integer write_delay = 0;
    // 0: simultaneous; 1: AW must arrive first; 2: W must arrive first.
    integer write_order = 0;
    reg read_fault = 1'b0, write_fault = 1'b0;
    reg [31:0] read_fault_address = 32'b0, write_fault_address = 32'b0;
    reg [31:0] exit_value = 32'b0;
    integer exit_count = 0;

    assign arready = !reset && read_count < 16 && (!stall_ar || cycle % 4 == 0);
    assign awready = !reset && !aw_saved && !write_pending && !bvalid &&
        (cycle % 3 == 0) && (write_order != 2 || w_saved);
    assign wready = !reset && !w_saved && !write_pending && !bvalid &&
        (cycle % 3 == 0) && (write_order != 1 || aw_saved);

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
            max_read_outstanding <= 0;
            bvalid <= 1'b0;
            write_pending <= 1'b0;
            aw_saved <= 1'b0;
            w_saved <= 1'b0;
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
            if (read_count > max_read_outstanding)
                max_read_outstanding <= read_count;
            if (bvalid && bready) begin
                bvalid <= 1'b0;
                b_count <= b_count + 1;
            end
            if (arvalid && arready) begin
                if (araddr[1:0] != 0)
                    $fatal(1, "Unaligned external read address");
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
                if (awaddr[1:0] != 0)
                    $fatal(1, "Unaligned external write address");
                pending_awaddr <= awaddr;
                aw_saved <= 1'b1;
                aw_count <= aw_count + 1;
            end
            if (wvalid && wready) begin
                pending_wdata <= wdata;
                pending_wstrb <= wstrb;
                w_saved <= 1'b1;
                w_count <= w_count + 1;
            end
            if (aw_saved && w_saved && !write_pending && !bvalid) begin
                aw_saved <= 1'b0;
                w_saved <= 1'b0;
                write_pending <= 1'b1;
                write_delay <= 4 + cycle % 4;
                pending_bresp <= 2'b00;
                if (write_fault && pending_awaddr == write_fault_address)
                    pending_bresp <= 2'b10;
                else if (pending_awaddr == 32'h80000000) begin
                    if (pending_wstrb == 4'hf) begin
                        exit_value <= pending_wdata;
                        exit_count <= exit_count + 1;
                    end else
                        pending_bresp <= 2'b10;
                end else if (pending_awaddr >= 65536)
                    pending_bresp <= 2'b11;
                else begin
                    for (lane = 0; lane < 4; lane = lane + 1)
                        if (pending_wstrb[lane])
                            memory[pending_awaddr >> 2][lane*8 +: 8] <=
                                pending_wdata[lane*8 +: 8];
                end
            end
            if (write_pending) begin
                if (write_delay == 0) begin
                    bresp <= pending_bresp;
                    bvalid <= 1'b1;
                    write_pending <= 1'b0;
                end else
                    write_delay <= write_delay - 1;
            end
        end
    end

    reg held_ar = 1'b0, held_aw = 1'b0, held_w = 1'b0;
    reg held_i_rsp = 1'b0, held_d_rsp = 1'b0;
    reg [31:0] last_araddr, last_awaddr, last_wdata, last_i_data, last_d_data;
    reg [3:0] last_wstrb;
    reg last_i_error, last_d_error;
    integer cpu_i_outstanding = 0;
    always @(posedge clock) begin
        if (reset) begin
            held_ar <= 1'b0;
            held_aw <= 1'b0;
            held_w <= 1'b0;
            held_i_rsp <= 1'b0;
            held_d_rsp <= 1'b0;
            cpu_i_outstanding <= 0;
        end else begin
            if (cpu_i_outstanding < 0 || cpu_i_outstanding > 4 ||
                (i_rsp_valid && cpu_i_outstanding == 0))
                $fatal(1, "I cache violated its four-request ordered response contract");
            case ({i_req_valid && i_req_ready, i_rsp_valid && i_rsp_ready})
                2'b10: cpu_i_outstanding <= cpu_i_outstanding + 1;
                2'b01: cpu_i_outstanding <= cpu_i_outstanding - 1;
                default: begin end
            endcase
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

    task automatic i_stream(input [31:0] base, input integer length,
                            input integer wrap_words, input bit stall_response,
                            input bit require_full_rate);
        integer sent, received, previous_accept, previous_response, ticks;
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
                            expected_address = base + 4 * (wrap_words == 0 ? received : received % wrap_words);
                            expected_error = read_fault &&
                                ((expected_address & ~32'(CACHE_LINE_BYTES-1)) ==
                                 (read_fault_address & ~32'(CACHE_LINE_BYTES-1)));
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

    task automatic d_access(input bit write_request, input [31:0] address,
                            input [31:0] data, input [3:0] strobe,
                            input [31:0] expected, input bit expected_error,
                            input integer stall);
        integer previous_b;
        begin
            previous_b = b_count;
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
            if (write_request && address[1:0] == 0 && b_count != previous_b + 1)
                $fatal(1, "Store acknowledged before its B response");
            repeat (stall) @(posedge clock);
            @(negedge clock);
            d_rsp_ready = 1'b1;
            @(posedge clock);
            @(negedge clock);
            d_rsp_ready = 1'b0;
        end
    endtask

    // Present a Store while a same-line Load is still filling. It must wait
    // until that Load response has been consumed, then update the installed row.
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
            do begin
                @(posedge clock);
                if (d_req_ready)
                    $fatal(1, "Conflicting Store accepted during refill/blocked response");
            end while (!d_rsp_valid);
            if (d_rsp_error || d_rsp_data !== memory[32'h904 >> 2])
                $fatal(1, "Load preceding conflicting Store returned wrong data");
            repeat (3) @(posedge clock);
            @(negedge clock);
            d_rsp_ready = 1'b1;
            @(posedge clock);
            @(negedge clock);
            d_rsp_ready = 1'b0;
            do @(posedge clock); while (!d_req_ready);
            @(negedge clock);
            d_req_valid = 1'b0;
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

    integer index, count_before, writes_before;
    reg [31:0] expected_word;
    initial begin
        if ($value$plusargs("READ_LATENCY=%d", read_latency)) begin end
        for (index = 0; index < 16384; index = index + 1)
            memory[index] = 32'h9e3779b9 ^ (32'(index) * 32'h01020408);
        repeat (5) @(posedge clock);
        @(negedge clock);
        reset = 1'b0;

        count_before = ar_count;
        i_read(32'h24, memory[9], 0, 4);
        if (ar_count != count_before + LINE_WORDS) $fatal(1, "I miss did not fill four words");
        count_before = ar_count;
        i_read(32'h2c, memory[11], 0, 0);
        if (ar_count != count_before) $fatal(1, "I hit accessed external memory");
        i_read(32'h824, memory[32'h824 >> 2], 0, 0);
        if (ar_count != count_before + LINE_WORDS) $fatal(1, "I conflict replacement failed");
        i_read(32'h24, memory[9], 0, 0);
        if (ar_count != count_before + 2*LINE_WORDS) $fatal(1, "Old I tag incorrectly remained valid");

        d_access(0, 32'h114, 0, 0, memory[32'h114 >> 2], 0, 3);
        count_before = ar_count;
        d_access(0, 32'h11c, 0, 0, memory[32'h11c >> 2], 0, 0);
        if (ar_count != count_before) $fatal(1, "D hit accessed external memory");
        expected_word = (memory[32'h114 >> 2] & 32'hff00ff00) | 32'h00bb00dd;
        write_order = 1;
        writes_before = aw_count;
        d_access(1, 32'h114, 32'haabbccdd, 4'b0101, 0, 0, 5);
        if (aw_count != writes_before + 1 || w_count != aw_count)
            $fatal(1, "AW-first store duplicated a channel");
        d_access(0, 32'h114, 0, 0, expected_word, 0, 0);
        if (ar_count != count_before) $fatal(1, "Write hit lost the D line");

        expected_word = (expected_word & 32'h00ff00ff) | 32'h11003300;
        write_order = 2;
        d_access(1, 32'h114, 32'h11223344, 4'b1010, 0, 0, 0);
        d_access(0, 32'h114, 0, 0, expected_word, 0, 0);
        d_access(1, 32'h114, 32'hffffffff, 4'b0000, 0, 0, 0);
        d_access(0, 32'h114, 0, 0, expected_word, 0, 0);

        write_order = 0;
        count_before = ar_count;
        d_access(1, 32'h208, 32'h12345678, 4'hf, 0, 0, 0);
        if (ar_count != count_before) $fatal(1, "Write miss unexpectedly allocated");
        d_access(0, 32'h208, 0, 0, 32'h12345678, 0, 0);
        if (ar_count != count_before + LINE_WORDS) $fatal(1, "Write miss became a cache hit");

        read_fault = 1'b1;
        read_fault_address = 32'h308;
        count_before = ar_count;
        d_access(0, 32'h304, 0, 0, 0, 1, 4);
        if (ar_count != count_before + LINE_WORDS || r_count != ar_count)
            $fatal(1, "Faulting refill did not finish draining all line responses");
        read_fault = 1'b0;
        count_before = ar_count;
        d_access(0, 32'h304, 0, 0, memory[32'h304 >> 2], 0, 0);
        if (ar_count != count_before + LINE_WORDS) $fatal(1, "Faulting D line was installed");
        read_fault = 1'b1;
        read_fault_address = 32'h408;
        i_read(32'h404, 0, 1, 2);
        read_fault = 1'b0;
        count_before = ar_count;
        i_read(32'h404, memory[32'h404 >> 2], 0, 0);
        if (ar_count != count_before + LINE_WORDS) $fatal(1, "Faulting I line was installed");

        write_fault = 1'b1;
        write_fault_address = 32'h208;
        d_access(1, 32'h208, 32'hffffffff, 4'hf, 0, 1, 4);
        write_fault = 1'b0;
        count_before = ar_count;
        d_access(0, 32'h208, 0, 0, 32'h12345678, 0, 0);
        if (ar_count != count_before + LINE_WORDS) $fatal(1, "Failed write left cache line valid");

        count_before = ar_count;
        d_access(0, 32'h80000000, 0, 0, 0, 1, 0);
        d_access(0, 32'h80000000, 0, 0, 0, 1, 0);
        i_read(32'h80000000, 0, 1, 0);
        if (ar_count != count_before + 3) $fatal(1, "MMIO read was cached or refilled");
        d_access(1, 32'h80000000, 32'h76543210, 4'hf, 0, 0, 0);
        if (exit_count != 1 || exit_value !== 32'h76543210)
            $fatal(1, "Exit MMIO data mismatch");
        d_access(1, 32'h80000000, 32'h76543210, 4'h1, 0, 1, 0);
        count_before = ar_count;
        writes_before = aw_count;
        i_read(32'h22, 0, 1, 0);
        d_access(0, 32'h225, 0, 0, 0, 1, 0);
        d_access(1, 32'h225, 32'h1234, 4'hf, 0, 1, 0);
        if (ar_count != count_before || aw_count != writes_before)
            $fatal(1, "Misaligned CPU request reached AXI");

        count_before = ar_count;
        fork
            i_read(32'h504, memory[32'h504 >> 2], 0, 30);
            d_access(0, 32'h608, 0, 0, memory[32'h608 >> 2], 0, 0);
        join
        if (ar_count != count_before + 2*LINE_WORDS) $fatal(1, "Concurrent I/D refill lost requests");
        for (index = count_before + 1; index < ar_count; index = index + 1)
            if ((read_trace[index] & ~32'(CACHE_LINE_BYTES - 1)) ==
                (read_trace[index-1] & ~32'(CACHE_LINE_BYTES - 1)))
                $fatal(1, "Read arbiter failed round-robin fairness");
        write_order = 2;
        fork
            i_read(32'h700, memory[32'h700 >> 2], 0, 0);
            d_access(1, 32'h114, 32'h87654321, 4'hf, 0, 0, 0);
        join
        d_access(0, 32'h114, 0, 0, 32'h87654321, 0, 0);

        conflicting_store();
        count_before = ar_count;
        d_access(0, 32'h904, 0, 0, 32'hcafefeed, 0, 0);
        if (ar_count != count_before) $fatal(1, "Conflict store failed to update SRAM");
        d_access(0, 32'h908, 0, 0, memory[32'h908 >> 2], 0, 0);

        // Warm two adjacent lines and prove sustained hit throughput, then hold
        // responses to exhaust credits and exercise the FIFO head/tail wrap.
        i_read(32'h1000, memory[32'h1000 >> 2], 0, 0);
        i_read(32'h1010, memory[32'h1010 >> 2], 0, 0);
        count_before = ar_count;
        i_stream(32'h1000, 48, 8, 0, 1);
        i_stream(32'h1000, 48, 8, 1, 0);
        if (ar_count != count_before) $fatal(1, "Warm I streams unexpectedly missed");
        stall_ar = 0;
        count_before = ar_count;
        i_read(32'h1800, memory[32'h1800 >> 2], 0, 0);
        for (index = count_before + 1; index < ar_count; index = index + 1)
            if (ar_cycle_trace[index] != ar_cycle_trace[index-1] + 1)
                $fatal(1, "Unblocked refill AR requests were not sent in consecutive cycles");
        i_stream(32'h1200, 24, 0, 1, 0);
        read_fault = 1;
        read_fault_address = 32'h1508;
        i_stream(32'h14f0, 12, 0, 1, 0);
        read_fault = 0;
        if (ar_count != r_count) $fatal(1, "I error stream left AXI responses outstanding");
        count_before = ar_count;
        i_read(32'h1504, memory[32'h1504 >> 2], 0, 0);
        if (ar_count != count_before + LINE_WORDS) $fatal(1, "Erroneous I line was installed");
        if (read_latency >= 4 * LINE_WORDS && max_read_outstanding < LINE_WORDS)
            $fatal(1, "Refill failed to pipeline its requests before receiving data");

        @(negedge clock);
        reset = 1'b1;
        repeat (5) @(posedge clock);
        @(negedge clock);
        reset = 1'b0;
        d_access(0, 32'h904, 0, 0, 32'hcafefeed, 0, 0);
        if (ar_count != LINE_WORDS) $fatal(1, "Reset did not invalidate cache tags");
        $display("PASS memory_system: line=%0d I-stream throughput, pipelined refill, errors, AXI/SRAM/backpressure", CACHE_LINE_BYTES);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "memory_system test timed out");
    end
endmodule
