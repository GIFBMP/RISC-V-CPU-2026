`timescale 1ns/1ps
// Reuse the full memory protocol/error test, but change the instruction address
// on every idle request cycle. These addresses must never become transactions.
module icache_preread_tb #(parameter integer FAST_INSTRUCTION_RESPONSE = 1);
    writeback_memory_tb #(.CACHE_LINE_BYTES(256), .ICACHE_LINE_BYTES(128),
        .DCACHE_BYTES(16384), .DCACHE_WAYS(4), .FAST_HIT_RESPONSE(1),
        .FAST_INSTRUCTION_RESPONSE(FAST_INSTRUCTION_RESPONSE),
        .PIPELINED_STORE_HITS(1)) test_case ();

    integer noise_count = 0;
    integer stalled_noise_count = 0;
    integer miss_noise_count = 0;
    always @(negedge test_case.clock) begin
        // Request-driving tasks also use the falling edge. Wait until they have
        // established valid before touching an address whose value is ignored.
        #1;
        if (!test_case.reset && !test_case.i_req_valid) begin
            case (noise_count % 4)
                0: test_case.i_req_addr = 32'h00002000 + 4 * 32'(noise_count % 1024);
                1: test_case.i_req_addr = 32'h10000000;
                2: test_case.i_req_addr = 32'hfffffff3;
                3: test_case.i_req_addr = 32'h00007000;
            endcase
            noise_count = noise_count + 1;
            if (test_case.i_rsp_valid && !test_case.i_rsp_ready)
                stalled_noise_count = stalled_noise_count + 1;
            if (test_case.dut.instruction_cache.miss_active)
                miss_noise_count = miss_noise_count + 1;
        end
    end

    always @(posedge test_case.clock) if (!test_case.reset) begin
        if (test_case.cpu_i_outstanding == 0 &&
            (test_case.dut.i_rd_valid || test_case.dut.instruction_cache.tag_write))
            $fatal(1, "Idle I address caused an external read or cache installation");
    end

    final begin
        if (noise_count < 100 || stalled_noise_count == 0 || miss_noise_count == 0)
            $fatal(1, "I idle-address test did not cover idle/stalled/miss contexts");
        else
            $display("PASS icache_preread: fast_i=%0d idle=%0d stalled=%0d miss=%0d",
                FAST_INSTRUCTION_RESPONSE, noise_count, stalled_noise_count, miss_noise_count);
    end
endmodule
