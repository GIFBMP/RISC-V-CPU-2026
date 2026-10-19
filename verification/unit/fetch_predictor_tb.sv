`timescale 1ns/1ps
// Predictor-only black-box tests. All expectations follow explicit periodic
// branch outcomes; the test never reads implementation history/counter arrays.
module fetch_predictor_tb #(
    parameter integer BTB_SIZE = 64,
    parameter integer BTB_HASH = 1,
    parameter integer HISTORY_BITS = 1
);
    logic clock = 0;
    always #5 clock = !clock;
    logic reset = 1, redirect_valid = 0;
    logic [31:0] redirect_pc = 0;
    logic instruction_valid, instruction_ready = 0;
    logic [31:0] instruction_pc, instruction_data, instruction_predicted_pc;
    logic instruction_error;
    logic i_req_valid, i_req_ready = 0;
    logic [31:0] i_req_addr;
    logic i_rsp_valid, i_rsp_ready;
    logic [31:0] i_rsp_data = 32'h00000013;
    logic i_rsp_error = 0;
    logic update_valid = 0, update_conditional = 1, update_taken = 0;
    logic [31:0] update_pc = 0, update_target = 0, update_insn = 32'h00000463;
    logic pending = 0;
    integer checks = 0;
    localparam integer BI = BTB_SIZE > 1 ? $clog2(BTB_SIZE) : 1;
    localparam [31:0] BRANCH_PC = 32'h100;
    localparam [31:0] TARGET_PC = 32'h800;
    localparam [31:0] ALIAS_PC = BRANCH_PC ^ (32'd1 << (BI+2))
                               ^ (BTB_HASH != 0 ? 32'd4 : 32'd0);

    logic instruction2_valid, instruction2_error;
    logic instruction2_ready = 0;
    logic [31:0] instruction2_pc, instruction2_data, instruction2_predicted_pc;
    logic [31:0] i_rsp_data2 = 0;

    fetch_frontend #(
        .BTB_ENTRIES(BTB_SIZE), .BTB_INDEX_XOR(BTB_HASH),
        .LOCAL_HISTORY_BITS(HISTORY_BITS), .RAS_DEPTH(0),
        .FETCH_QUEUE_DEPTH(1), .FETCH_OUTSTANDING(1)
    ) dut (.*);

    assign i_rsp_valid = pending;
    always @(posedge clock) begin
        if (reset) pending <= 0;
        else begin
            case ({i_req_valid && i_req_ready, i_rsp_valid && i_rsp_ready})
                2'b10: pending <= 1;
                2'b01: pending <= 0;
                default: pending <= pending;
            endcase
        end
    end

    task automatic train(input logic [31:0] pc, input logic conditional, input logic taken);
        @(negedge clock);
        update_valid = 1;
        update_pc = pc;
        update_target = TARGET_PC;
        update_conditional = conditional;
        update_taken = taken;
        @(negedge clock);
        update_valid = 0;
        repeat (2) @(negedge clock);
    endtask

    task automatic predict(input logic [31:0] pc, input logic [31:0] expected);
        @(negedge clock);
        redirect_valid = 1;
        redirect_pc = pc;
        @(negedge clock);
        redirect_valid = 0;
        #1;
        while (!i_req_valid) @(negedge clock);
        i_req_ready = 1;
        @(negedge clock);
        i_req_ready = 0;
        while (!instruction_valid) @(negedge clock);
        if (instruction_pc !== pc || instruction_predicted_pc !== expected)
            $fatal(1, "prediction pc=%h got=%h expected=%h", pc, instruction_predicted_pc, expected);
        checks = checks + 1;
        instruction_ready = 1;
        @(negedge clock);
        instruction_ready = 0;
    endtask

    // Every cycle retires a branch. This exercises the registered training
    // bundle and read-after-write behavior for the same BTB row.
    task automatic train_period(input integer period_bits, input integer count);
        for (integer i = 0; i < count; i = i + 1) begin
            @(negedge clock);
            update_valid = 1;
            update_pc = BRANCH_PC;
            update_target = TARGET_PC;
            update_conditional = 1;
            update_taken = period_bits == 1 ? i[0] : i[1];
        end
        @(negedge clock);
        update_valid = 0;
        repeat (2) @(negedge clock);
    endtask

    initial begin
        repeat (3) @(negedge clock);
        reset = 0;
        predict(BRANCH_PC, BRANCH_PC + 4);
        train(BRANCH_PC, 1, 1);
        predict(BRANCH_PC, TARGET_PC);
        train_period(1, 64);
        // Alternating N/T has just ended in T, hence N is next. Merely
        // fetching and then redirecting must not train committed history.
        predict(BRANCH_PC, BRANCH_PC + 4);
        predict(BRANCH_PC, BRANCH_PC + 4);
        for (integer i = 0; i < 32; i = i + 1) begin
            train(BRANCH_PC, 1, i[0]);
            predict(BRANCH_PC, i[0] ? BRANCH_PC + 4 : TARGET_PC);
        end
        if (HISTORY_BITS >= 2) begin
            train_period(2, 128);
            for (integer i = 0; i < 32; i = i + 1) begin
                predict(BRANCH_PC, i[1] ? TARGET_PC : BRANCH_PC + 4);
                train(BRANCH_PC, 1, i[1]);
            end
        end
        // Redirect coincident with applying a retirement cannot cancel it.
        @(negedge clock);
        update_valid = 1;
        update_pc = BRANCH_PC;
        update_target = TARGET_PC;
        update_conditional = 0;
        update_taken = 0;
        @(negedge clock);
        update_valid = 0;
        redirect_valid = 1;
        redirect_pc = 32'h400;
        @(negedge clock);
        redirect_valid = 0;
        predict(BRANCH_PC, TARGET_PC);

        // A full-tag replacement must initialize new history and chooser;
        // the overwritten branch cannot borrow the replacement's target.
        train(ALIAS_PC, 1, 1);
        predict(ALIAS_PC, TARGET_PC);
        predict(BRANCH_PC, BRANCH_PC + 4);
        train(BRANCH_PC, 1, 0);
        predict(BRANCH_PC, BRANCH_PC + 4);
        for (integer i = 0; i < 24; i = i + 1) train(BRANCH_PC, 1, 1);
        predict(BRANCH_PC, TARGET_PC);
        for (integer i = 0; i < 24; i = i + 1) train(BRANCH_PC, 1, 0);
        predict(BRANCH_PC, BRANCH_PC + 4);

        // Reset on a pending update application clears validity.
        @(negedge clock);
        update_valid = 1;
        update_taken = 1;
        @(negedge clock);
        update_valid = 0;
        reset = 1;
        repeat (2) @(negedge clock);
        reset = 0;
        predict(BRANCH_PC, BRANCH_PC + 4);
        $display("PASS fetch_predictor BTB=%0d XOR=%0d HISTORY=%0d checks=%0d",
                 BTB_SIZE, BTB_HASH, HISTORY_BITS, checks);
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "timeout");
    end
endmodule
