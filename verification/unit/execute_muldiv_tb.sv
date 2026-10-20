`timescale 1ns/1ps
module execute_muldiv_tb;
    logic clock = 0;
    logic reset = 1;
    logic flush = 0;
    logic req_valid = 0;
    logic [2:0] operation = 0;
    logic [31:0] operand_a = 0, operand_b = 0;
    logic result_ready = 0;
    wire req_ready, result_valid, req_available, result_pending;
    wire [31:0] result;
    integer checks = 0;
    integer cancellations = 0;
    integer latency_checks = 0;
    integer last_latency = 0;
    integer seed = 32'h42c0ffee;
    integer unused_random;
    integer index, op_index, ai, bi;
    logic [31:0] edges [0:8];
    logic [31:0] a, b, wanted;
    muldiv_unit dut (.*);

    task tick;
        begin #5; clock = 1; #5; clock = 0; #1; end
    endtask

    // Independent mathematical reference. Division exists only in this TB.
    function automatic [31:0] reference_result(input [2:0] operation_code,
                                              input [31:0] x, input [31:0] y);
        logic signed [63:0] sx, sy;
        logic [63:0] ux, uy, product;
        begin
            sx = {{32{x[31]}}, x}; sy = {{32{y[31]}}, y};
            ux = {32'b0, x}; uy = {32'b0, y}; product = 0;
            case (operation_code)
                0: begin product = ux * uy; reference_result = product[31:0]; end
                1: begin product = sx * sy; reference_result = product[63:32]; end
                2: begin product = sx * $signed(uy); reference_result = product[63:32]; end
                3: begin product = ux * uy; reference_result = product[63:32]; end
                4: begin
                    if (y == 0) reference_result = 32'hffffffff;
                    else if (x == 32'h80000000 && y == 32'hffffffff)
                        reference_result = 32'h80000000;
                    else reference_result = sx / sy;
                end
                5: reference_result = y == 0 ? 32'hffffffff : x / y;
                6: begin
                    if (y == 0) reference_result = x;
                    else if (x == 32'h80000000 && y == 32'hffffffff)
                        reference_result = 0;
                    else reference_result = sx % sy;
                end
                7: reference_result = y == 0 ? x : x % y;
            endcase
        end
    endfunction

    // Independent bit-length reference, including the normalization cycle.
    function automatic integer divide_latency(input [2:0] operation_code,
                                               input [31:0] x);
        logic [31:0] magnitude;
        integer bits_needed;
        begin
            magnitude = !operation_code[0] && x[31] ? -x : x;
            bits_needed = 0;
            while (magnitude != 0) begin
                magnitude = magnitude >> 1;
                bits_needed = bits_needed + 1;
            end
            divide_latency = 1 + (bits_needed == 0 ? 1 : bits_needed);
        end
    endfunction

    task automatic launch(input [2:0] operation_code, input [31:0] x, input [31:0] y);
        begin
            if (req_ready !== 1 || result_valid !== 0)
                $fatal(1, "Unit not idle before launch");
            operation = operation_code; operand_a = x; operand_b = y;
            req_valid = 1; tick(); req_valid = 0;
            // The DUT must retain accepted operands and operation independently.
            operand_a = ~x; operand_b = ~y; operation = ~operation_code;
        end
    endtask

    task automatic await_result(input [31:0] expected);
        integer elapsed;
        begin
            elapsed = 0;
            while (result_valid !== 1) begin
                if (req_ready !== 0) $fatal(1, "Accepted new request while busy");
                tick(); elapsed = elapsed + 1;
                if (elapsed > 33) $fatal(1, "M unit exceeded normalization plus 32 trials");
            end
            if (result !== expected)
                $fatal(1, "M result=%h expected=%h", result, expected);
            last_latency = elapsed;
        end
    endtask

    task automatic check_latency(input [2:0] operation_code,
                                 input [31:0] x, input [31:0] y,
                                 input integer expected_latency);
        begin
            check_operation(operation_code, x, y);
            if (last_latency != expected_latency)
                $fatal(1, "M latency op=%0d a=%h b=%h actual=%0d expected=%0d",
                       operation_code, x, y, last_latency, expected_latency);
            latency_checks = latency_checks + 1;
        end
    endtask

    task automatic check_operation(input [2:0] operation_code,
                                   input [31:0] x, input [31:0] y);
        logic [31:0] expected;
        begin
            expected = reference_result(operation_code, x, y);
            launch(operation_code, x, y);
            await_result(expected);
            // A new VALID while the completed result is stalled cannot overwrite it.
            req_valid = 1;
            repeat (3) begin
                tick();
                if (result_valid !== 1 || result !== expected || req_ready !== 0)
                    $fatal(1, "Result not held under completion backpressure");
            end
            req_valid = 0;
            result_ready = 1; tick(); result_ready = 0;
            if (result_valid !== 0 || req_ready !== 1)
                $fatal(1, "Result handshake did not release unit");
            checks = checks + 1;
        end
    endtask

    task cancel_and_check;
        begin
            flush = 1;
            // A flush wins over both a waiting request and result consumption.
            req_valid = 1; result_ready = 1;
            #1;
            if (req_ready !== 0 || result_valid !== 0)
                $fatal(1, "Flush failed to mask handshakes");
            tick(); req_valid = 0; result_ready = 0; flush = 0;
            #1;
            if (req_ready !== 1 || result_valid !== 0)
                $fatal(1, "Flush failed to return to idle");
            repeat (35) begin
                tick();
                if (result_valid !== 0) $fatal(1, "Canceled result reappeared");
            end
            cancellations = cancellations + 1;
        end
    endtask

    initial begin
        unused_random = $urandom(seed);
        edges[0] = 0; edges[1] = 1; edges[2] = 2;
        edges[3] = 32'hffffffff; edges[4] = 32'hfffffffe;
        edges[5] = 32'h80000000; edges[6] = 32'h7fffffff;
        edges[7] = 32'h80000001; edges[8] = 32'h00010000;
        repeat (3) tick();
        if (req_ready !== 0 || result_valid !== 0) $fatal(1, "Reset handshake masking");
        reset = 0; #1;
        for (op_index = 0; op_index < 8; op_index = op_index + 1) begin
            for (ai = 0; ai < 9; ai = ai + 1)
                for (bi = 0; bi < 9; bi = bi + 1)
                    check_operation(op_index[2:0], edges[ai], edges[bi]);
        end
        for (index = 0; index < 200; index = index + 1) begin
            a = $urandom; b = $urandom;
            for (op_index = 0; op_index < 8; op_index = op_index + 1)
                check_operation(op_index[2:0], a, b);
        end
        for (op_index = 0; op_index < 8; op_index = op_index + 1) begin
            launch(op_index[2:0], 32'hfedcba98, 32'h12345);
            repeat (7) tick();
            cancel_and_check();
            check_operation(op_index[2:0], 32'h80000000, 32'hffffffff);
        end
        // Also cancel a finished result while it is awaiting consumption.
        launch(3'b001, 32'h80000000, 32'hffffffff);
        await_result(reference_result(3'b001, 32'h80000000, 32'hffffffff));
        cancel_and_check();
        // Reset must cancel work as well as flush.
        launch(3'b100, 32'hfedcba98, 32'h12345);
        repeat (7) tick(); reset = 1; tick(); reset = 0; #1;
        if (result_valid !== 0 || req_ready !== 1) $fatal(1, "Reset cancellation");
        check_operation(3'b000, 6, 7);

        // Latency is checked at the public handshake, with the same operand
        // mutation and completion backpressure as the arithmetic regressions.
        check_latency(0, 32'h89abcdef, 0, 2);
        check_latency(0, 32'h89abcdef, 1, 2);
        check_latency(0, 32'h89abcdef, 2, 2);
        check_latency(0, 32'h89abcdef, 10000, 2);
        check_latency(0, 32'h89abcdef, 32'h80000000, 2);
        check_latency(1, 32'h80000000, 32'hffffffff, 2);
        check_latency(1, 32'h80000001, 32'hfffffffe, 2);
        check_latency(2, 32'h80000000, 32'hffffffff, 2);
        check_latency(3, 32'hffffffff, 1, 2);

        // Both result orders, signedness and full operand bits matter.
        check_latency(4, -7, 3, divide_latency(4, -7));
        check_latency(6, -7, 3, 1);
        check_latency(0, 6, 7, 2);
        check_latency(4, -7, 3, 1); // An intervening MUL preserves the division.
        check_latency(5, -7, 3, divide_latency(5, -7));
        check_latency(7, -7, 3, 1);
        check_latency(6, -8, 3, divide_latency(6, -8)); // Different dividend.
        check_latency(4, -8, 3, 1);
        check_latency(4, -8, 5, divide_latency(4, -8)); // Different divisor.
        check_latency(6, -8, 5, 1);
        check_latency(6, 8, 5, divide_latency(6, 8)); // Same magnitudes are not the same key.
        check_latency(4, 8, 5, 1);
        check_latency(6, 8, -5, divide_latency(6, 8));
        check_latency(4, 8, -5, 1);
        check_latency(6, 17, 5, divide_latency(6, 17));
        check_latency(4, 17, 5, 1);
        check_latency(4, 32'h80000000, 32'hffffffff, divide_latency(4, 32'h80000000));
        check_latency(6, 32'h80000000, 32'hffffffff, 1);
        check_latency(5, 32'h80000000, 32'hffffffff, divide_latency(5, 32'h80000000));
        check_latency(7, 32'h80000000, 32'hffffffff, 1);
        check_latency(4, 0, 13, divide_latency(4, 0));
        check_latency(6, 0, 13, 1);
        check_latency(4, 99, 0, 0);
        check_latency(6, 99, 0, 0);
        check_latency(5, 32'hffffffff, 0, 0);
        check_latency(7, 32'hffffffff, 0, 0);
        check_latency(4, 0, 13, 1); // Divide-by-zero did not replace the entry.
        // Unaccepted request inputs may change during IDLE without altering
        // the last completed division's key or either result.
        operation = 6; operand_a = 123; operand_b = 17;
        repeat (3) tick();
        check_latency(6, 0, 13, 1);

        // Repeated random pairs exercise both signednesses and both directions.
        for (index = 0; index < 32; index = index + 1) begin
            a = $urandom; b = $urandom | 32'd1;
            // Different modes force a miss even if the input pair repeats.
            check_latency(4, a, b, divide_latency(4, a));
            check_latency(6, a, b, 1);
            check_latency(7, a, b, divide_latency(7, a));
            check_latency(5, a, b, 1);
        end

        // Flush invalidates a previously completed pair.
        cancel_and_check();
        check_latency(4, a, b, divide_latency(4, a));
        check_latency(6, a, b, 1);
        // Cancel on the very edge that would install a division result.
        launch(4, 123456789, 97);
        repeat (divide_latency(4, 123456789) - 1) tick();
        cancel_and_check();
        check_latency(6, 123456789, 97, divide_latency(6, 123456789));
        check_latency(4, 123456789, 97, 1);
        // Cancel a cache hit before it can produce a response.
        launch(6, 123456789, 97);
        cancel_and_check();
        check_latency(4, 123456789, 97, divide_latency(4, 123456789));
        // Cancel a completed but backpressured result and its cached pair.
        launch(6, 123456789, 97);
        await_result(reference_result(6, 123456789, 97));
        cancel_and_check();
        check_latency(4, 123456789, 97, divide_latency(4, 123456789));
        // Reset wins on the completion edge just as flush does.
        launch(4, 987654321, 101);
        repeat (divide_latency(4, 987654321) - 1) tick(); reset = 1; tick(); reset = 0; #1;
        if (result_valid !== 0 || req_ready !== 1) $fatal(1, "Reset on completion edge");
        check_latency(6, 987654321, 101, divide_latency(6, 987654321));
        check_latency(4, 987654321, 101, 1);
        $display("PASS M operations=%0d latency checks=%0d flush scenarios=%0d plus reset cancellation",
                 checks, latency_checks, cancellations);
        $finish;
    end
endmodule
