`timescale 1ns/1ps
module execute_decode_alu_tb;
    logic [31:0] instruction;
    wire [4:0] op, rs1, rs2, rd;
    wire use_rs1, use_rs2, writes_rd, use_imm, illegal;
    wire [31:0] immediate;
    wire [2:0] funct3;
    logic [4:0] alu_op;
    logic [31:0] lhs, rhs;
    wire [31:0] result;
    integer decode_checks = 0;
    integer alu_checks = 0;
    integer seed = 32'h20261015;
    integer unused_random;
    integer f7, f3, code, index, expected_op;
    logic [31:0] sample, a, b;
    logic signed [31:0] offset;

    decoder dec (.*);
    alu arithmetic (.op(alu_op), .lhs(lhs), .rhs(rhs), .result(result));

    function automatic [31:0] r_instruction(input [6:0] upper,
                                            input [2:0] function_code,
                                            input [6:0] opcode);
        r_instruction = {upper, 5'd23, 5'd9, function_code, 5'd17, opcode};
    endfunction

    function automatic [31:0] i_instruction(input [31:0] imm,
                                            input [2:0] function_code,
                                            input [6:0] opcode);
        i_instruction = {imm[11:0], 5'd9, function_code, 5'd17, opcode};
    endfunction

    function automatic [31:0] s_instruction(input [31:0] imm,
                                            input [2:0] function_code);
        s_instruction = {imm[11:5], 5'd23, 5'd9, function_code, imm[4:0], 7'h23};
    endfunction

    function automatic [31:0] b_instruction(input [31:0] imm,
                                            input [2:0] function_code);
        b_instruction = {imm[12], imm[10:5], 5'd23, 5'd9, function_code,
                         imm[4:1], imm[11], 7'h63};
    endfunction

    function automatic [31:0] j_instruction(input [31:0] imm);
        j_instruction = {imm[20], imm[10:1], imm[11], imm[19:12], 5'd17, 7'h6f};
    endfunction

    task automatic check_decode(input [31:0] inst, input [4:0] wanted_op,
                                input [3:0] wanted_flags, input [31:0] wanted_imm);
        begin
            instruction = inst;
            #1;
            if (op !== wanted_op || illegal !== (wanted_op == 5'd31) ||
                {use_rs1, use_rs2, writes_rd, use_imm} !== wanted_flags ||
                immediate !== wanted_imm)
                $fatal(1, "decode inst=%h op=%0d/%0d flags=%b/%b imm=%h/%h", inst,
                       op, wanted_op, {use_rs1,use_rs2,writes_rd,use_imm},
                       wanted_flags, immediate, wanted_imm);
            if (rs1 !== inst[19:15] || rs2 !== inst[24:20] ||
                rd !== inst[11:7] || funct3 !== inst[14:12])
                $fatal(1, "decode register/function fields inst=%h", inst);
            decode_checks = decode_checks + 1;
        end
    endtask

    function automatic [31:0] alu_reference(input [4:0] operation,
                                           input [31:0] x, input [31:0] y);
        begin
            case (operation)
                0, 11: alu_reference = x + y;
                1: alu_reference = x - y;
                2: alu_reference = x << (y & 31);
                3: alu_reference = $signed(x) < $signed(y) ? 32'd1 : 32'd0;
                4: alu_reference = x < y ? 32'd1 : 32'd0;
                5: alu_reference = x ^ y;
                6: alu_reference = x >> (y & 31);
                7: alu_reference = $signed(x) >>> (y & 31);
                8: alu_reference = x | y;
                9: alu_reference = x & y;
                10: alu_reference = y;
                default: alu_reference = 32'd0;
            endcase
        end
    endfunction

    task automatic check_alu(input [4:0] operation, input [31:0] x, input [31:0] y);
        logic [31:0] expected;
        begin
            alu_op = operation; lhs = x; rhs = y;
            expected = alu_reference(operation, x, y);
            #1;
            if (result !== expected)
                $fatal(1, "ALU op=%0d lhs=%h rhs=%h result=%h expected=%h",
                       operation, x, y, result, expected);
            alu_checks = alu_checks + 1;
        end
    endtask

    initial begin
        unused_random = $urandom(seed);
        // Exhaustive funct7/funct3 legality for register arithmetic.
        for (f7 = 0; f7 < 128; f7 = f7 + 1) begin
            for (f3 = 0; f3 < 8; f3 = f3 + 1) begin
                expected_op = 31;
                if (f7 == 0) begin
                    case (f3)
                        0: expected_op = 0;
                        1: expected_op = 2;
                        2: expected_op = 3;
                        3: expected_op = 4;
                        4: expected_op = 5;
                        5: expected_op = 6;
                        6: expected_op = 8;
                        7: expected_op = 9;
                    endcase
                end else if (f7 == 1) expected_op = 17;
                else if (f7 == 32 && f3 == 0) expected_op = 1;
                else if (f7 == 32 && f3 == 5) expected_op = 7;
                check_decode(r_instruction(f7[6:0], f3[2:0], 7'h33), expected_op[4:0],
                             expected_op == 31 ? 4'b0000 : 4'b1110, 0);
            end
            // Both shift-immediate encodings have reserved upper bits.
            check_decode(r_instruction(f7[6:0], 3'b001, 7'h13),
                         f7 == 0 ? 5'd2 : 5'd31,
                         f7 == 0 ? 4'b1011 : 4'b0000, f7 == 0 ? 32'd23 : 0);
            expected_op = f7 == 0 ? 6 : (f7 == 32 ? 7 : 31);
            check_decode(r_instruction(f7[6:0], 3'b101, 7'h13), expected_op[4:0],
                         expected_op == 31 ? 4'b0000 : 4'b1011,
                         expected_op == 31 ? 0 : 32'd23);
        end
        for (f3 = 0; f3 < 8; f3 = f3 + 1) begin
            if (f3 == 0 || f3 == 1 || f3 == 2 || f3 == 4 || f3 == 5)
                check_decode(i_instruction(-2048, f3[2:0], 7'h03), 15, 4'b1011, -2048);
            else check_decode(i_instruction(-2048, f3[2:0], 7'h03), 31, 0, 0);
            if (f3 <= 2)
                check_decode(s_instruction(2047, f3[2:0]), 16, 4'b1101, 2047);
            else check_decode(s_instruction(2047, f3[2:0]), 31, 0, 0);
            if (f3 == 0 || f3 == 1 || f3 >= 4)
                check_decode(b_instruction(-4096, f3[2:0]), 14, 4'b1100, -4096);
            else check_decode(b_instruction(-4096, f3[2:0]), 31, 0, 0);
            if (f3 == 0)
                check_decode(i_instruction(-1, f3[2:0], 7'h67), 13, 4'b1011, -1);
            else check_decode(i_instruction(-1, f3[2:0], 7'h67), 31, 0, 0);
        end
        for (code = 0; code < 128; code = code + 1) begin
            if (code != 'h03 && code != 'h13 && code != 'h17 && code != 'h23 &&
                code != 'h33 && code != 'h37 && code != 'h63 && code != 'h67 && code != 'h6f)
                check_decode({25'b0, code[6:0]}, 31, 0, 0);
        end
        check_decode(j_instruction(-1048576), 12, 4'b0011, -1048576);
        check_decode(j_instruction(1048574), 12, 4'b0011, 1048574);
        check_decode(b_instruction(4094, 3'b000), 14, 4'b1100, 4094);
        // x0 destinations retain the instruction's writeback semantic flag.
        check_decode(32'h00000013, 0, 4'b1011, 0);
        for (index = 0; index < 200; index = index + 1) begin
            offset = $signed($urandom) >>> 20;
            check_decode(i_instruction(offset, 0, 7'h13), 0, 4'b1011, offset);
            check_decode(i_instruction(offset, 2, 7'h13), 3, 4'b1011, offset);
            check_decode(i_instruction(offset, 3, 7'h13), 4, 4'b1011, offset);
            check_decode(i_instruction(offset, 4, 7'h13), 5, 4'b1011, offset);
            check_decode(i_instruction(offset, 6, 7'h13), 8, 4'b1011, offset);
            check_decode(i_instruction(offset, 7, 7'h13), 9, 4'b1011, offset);
            check_decode(i_instruction(offset, 2, 7'h03), 15, 4'b1011, offset);
            check_decode(s_instruction(offset, 2), 16, 4'b1101, offset);
            check_decode(i_instruction(offset, 0, 7'h67), 13, 4'b1011, offset);
            offset = ($signed($urandom) >>> 19) & -2;
            check_decode(b_instruction(offset, 0), 14, 4'b1100, offset);
            offset = ($signed($urandom) >>> 11) & -2;
            check_decode(j_instruction(offset), 12, 4'b0011, offset);
            sample = $urandom & 32'hfffff000;
            check_decode({sample[31:12],5'd17,7'h37}, 10, 4'b0011, sample);
            check_decode({sample[31:12],5'd17,7'h17}, 11, 4'b0011, sample);
            a = $urandom; b = $urandom;
            for (code = 0; code < 32; code = code + 1)
                check_alu(code[4:0], a, b);
        end
        for (code = 0; code < 12; code = code + 1) begin
            check_alu(code[4:0], 32'h80000000, 32'hffffffff);
            check_alu(code[4:0], 32'hffffffff, 1);
            check_alu(code[4:0], 32'h7fffffff, 1);
        end
        for (index = 0; index < 64; index = index + 1) begin
            check_alu(2, 32'h80000001, index);
            check_alu(6, 32'h80000001, index);
            check_alu(7, 32'h80000001, index);
        end
        $display("PASS decoder=%0d ALU=%0d checks", decode_checks, alu_checks);
        $finish;
    end
endmodule
