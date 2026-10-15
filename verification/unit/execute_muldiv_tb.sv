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
                if (elapsed > 32) $fatal(1, "M unit exceeded 32 iterations");
            end
            if (result !== expected)
                $fatal(1, "M result=%h expected=%h", result, expected);
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
        $display("PASS M operations=%0d flush scenarios=%0d plus reset cancellation", checks, cancellations);
        $finish;
    end
endmodule
