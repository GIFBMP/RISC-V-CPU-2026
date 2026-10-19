`timescale 1ns/1ps
// Unaccepted D payloads may drive side-effect-free reads, but must never write
// arrays, allocate a line, flush dirty data, or initiate an AXI transaction.
module dcache_preread_tb #(parameter integer FAST_HIT_RESPONSE = 1,
    parameter integer PIPELINED_STORE_HITS = 1);
    writeback_memory_tb #(.CACHE_LINE_BYTES(256), .ICACHE_LINE_BYTES(128),
        .DCACHE_BYTES(16384), .DCACHE_WAYS(4), .FAST_HIT_RESPONSE(FAST_HIT_RESPONSE),
        .FAST_INSTRUCTION_RESPONSE(1),
        .PIPELINED_STORE_HITS(PIPELINED_STORE_HITS)) test_case ();

    integer noise_count = 0;
    integer stalled_noise_count = 0;
    integer miss_noise_count = 0;
    integer store_overlap_count = 0;
    always @(negedge test_case.clock) begin
        #1;
        if (!test_case.reset && !test_case.d_req_valid) begin
            case (noise_count % 4)
                0: test_case.d_req_addr = 32'h00002000 + 4 * 32'(noise_count % 1024);
                1: test_case.d_req_addr = 32'h10000000;
                2: test_case.d_req_addr = 32'hfffffff3;
                3: test_case.d_req_addr = 32'h00001000;
            endcase
            test_case.d_req_write = (noise_count % 2) != 0;
            // In pipelined mode explicitly exercise the last accepted Store's
            // data write alongside the idle next Store's tag-only preread.
            if (test_case.dut.write_back.data_cache.lookup_store) begin
                test_case.d_req_write = 1;
                test_case.d_req_addr = 32'h00002000;
                store_overlap_count = store_overlap_count + 1;
            end
            test_case.d_req_wdata = 32'hdeadbeef ^ (32'(noise_count) * 32'h03050709);
            test_case.d_req_wstrb = 4'(noise_count);
            noise_count = noise_count + 1;
            if (test_case.d_rsp_valid && !test_case.d_rsp_ready)
                stalled_noise_count = stalled_noise_count + 1;
            if (test_case.dut.write_back.data_cache.state != 0)
                miss_noise_count = miss_noise_count + 1;
        end
    end

    always @(posedge test_case.clock) if (!test_case.reset) begin
        if (test_case.cpu_d_outstanding == 0 &&
            (test_case.dut.d_rd_valid || test_case.dut.d_wr_valid ||
             test_case.dut.write_back.data_cache.lookup_store))
            $fatal(1, "Idle D payload caused an external request or Store update");
    end
    for (genvar way = 0; way < 4; way = way + 1) begin : no_idle_writes
        always @(posedge test_case.clock) if (!test_case.reset) begin
            if (test_case.cpu_d_outstanding == 0 &&
                (test_case.dut.write_back.data_cache.arrays[way].data_write ||
                 test_case.dut.write_back.data_cache.arrays[way].tag_write))
                $fatal(1, "Idle D payload caused an array write or cache installation");
        end
    end

    final begin
        if (noise_count < 100 || stalled_noise_count == 0 ||
            miss_noise_count == 0 || store_overlap_count == 0)
            $fatal(1, "D idle-payload test missed idle/stall/miss/Store-overlap coverage");
        else
            $display("PASS dcache_preread: fast_d=%0d pipeline_store=%0d idle=%0d stalled=%0d miss=%0d Store-overlap=%0d",
                FAST_HIT_RESPONSE, PIPELINED_STORE_HITS, noise_count,
                stalled_noise_count, miss_noise_count, store_overlap_count);
    end
endmodule
