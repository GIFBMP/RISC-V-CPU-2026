// RV32IM decoder. OP values are shared with alu and the core by convention.
// writes_rd describes instruction semantics; the register file ignores x0.
module decoder (
    input  logic [31:0] instruction,
    output logic [4:0]  op,
    output logic [4:0]  rs1,
    output logic [4:0]  rs2,
    output logic [4:0]  rd,
    output logic        use_rs1,
    output logic        use_rs2,
    output logic        writes_rd,
    output logic        use_imm,
    output logic [31:0] immediate,
    output logic [2:0]  funct3,
    output logic        illegal
);
    always_comb begin
        rs1 = instruction[19:15];
        rs2 = instruction[24:20];
        rd = instruction[11:7];
        funct3 = instruction[14:12];
        op = 5'd31;
        use_rs1 = 1'b0;
        use_rs2 = 1'b0;
        writes_rd = 1'b0;
        use_imm = 1'b0;
        immediate = 32'b0;

        case (instruction[6:0])
            7'b0110011: begin // Register arithmetic and M extension.
                use_rs1 = 1'b1;
                use_rs2 = 1'b1;
                writes_rd = 1'b1;
                case (instruction[31:25])
                    7'b0000000: begin
                        case (funct3)
                            3'b000: op = 5'd0;
                            3'b001: op = 5'd2;
                            3'b010: op = 5'd3;
                            3'b011: op = 5'd4;
                            3'b100: op = 5'd5;
                            3'b101: op = 5'd6;
                            3'b110: op = 5'd8;
                            3'b111: op = 5'd9;
                            default: op = 5'd31;
                        endcase
                    end
                    7'b0100000: begin
                        case (funct3)
                            3'b000: op = 5'd1;
                            3'b101: op = 5'd7;
                            default: op = 5'd31;
                        endcase
                    end
                    7'b0000001: op = 5'd17;
                    default: op = 5'd31;
                endcase
            end
            7'b0010011: begin // Immediate arithmetic.
                use_rs1 = 1'b1;
                writes_rd = 1'b1;
                use_imm = 1'b1;
                immediate = {{20{instruction[31]}}, instruction[31:20]};
                case (funct3)
                    3'b000: op = 5'd0;
                    3'b010: op = 5'd3;
                    3'b011: op = 5'd4;
                    3'b100: op = 5'd5;
                    3'b110: op = 5'd8;
                    3'b111: op = 5'd9;
                    3'b001: begin
                        immediate = {27'b0, instruction[24:20]};
                        if (instruction[31:25] == 7'b0000000)
                            op = 5'd2;
                    end
                    3'b101: begin
                        immediate = {27'b0, instruction[24:20]};
                        if (instruction[31:25] == 7'b0000000)
                            op = 5'd6;
                        else if (instruction[31:25] == 7'b0100000)
                            op = 5'd7;
                    end
                    default: op = 5'd31;
                endcase
            end
            7'b0110111: begin // LUI
                op = 5'd10;
                writes_rd = 1'b1;
                use_imm = 1'b1;
                immediate = {instruction[31:12], 12'b0};
            end
            7'b0010111: begin // AUIPC
                op = 5'd11;
                writes_rd = 1'b1;
                use_imm = 1'b1;
                immediate = {instruction[31:12], 12'b0};
            end
            7'b1101111: begin // JAL
                op = 5'd12;
                writes_rd = 1'b1;
                use_imm = 1'b1;
                immediate = {{11{instruction[31]}}, instruction[31],
                             instruction[19:12], instruction[20],
                             instruction[30:21], 1'b0};
            end
            7'b1100111: begin // JALR
                if (funct3 == 3'b000) begin
                    op = 5'd13;
                    use_rs1 = 1'b1;
                    writes_rd = 1'b1;
                    use_imm = 1'b1;
                    immediate = {{20{instruction[31]}}, instruction[31:20]};
                end
            end
            7'b1100011: begin // Conditional branches compare two registers.
                case (funct3)
                    3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111: begin
                        op = 5'd14;
                        use_rs1 = 1'b1;
                        use_rs2 = 1'b1;
                        immediate = {{19{instruction[31]}}, instruction[31],
                                     instruction[7], instruction[30:25],
                                     instruction[11:8], 1'b0};
                    end
                    default: op = 5'd31;
                endcase
            end
            7'b0000011: begin // LB, LH, LW, LBU, LHU.
                case (funct3)
                    3'b000, 3'b001, 3'b010, 3'b100, 3'b101: begin
                        op = 5'd15;
                        use_rs1 = 1'b1;
                        writes_rd = 1'b1;
                        use_imm = 1'b1;
                        immediate = {{20{instruction[31]}}, instruction[31:20]};
                    end
                    default: op = 5'd31;
                endcase
            end
            7'b0100011: begin // SB, SH, SW.
                case (funct3)
                    3'b000, 3'b001, 3'b010: begin
                        op = 5'd16;
                        use_rs1 = 1'b1;
                        use_rs2 = 1'b1;
                        use_imm = 1'b1;
                        immediate = {{20{instruction[31]}}, instruction[31:25],
                                     instruction[11:7]};
                    end
                    default: op = 5'd31;
                endcase
            end
            default: op = 5'd31; // Includes unsupported SYSTEM and FENCE.
        endcase

        illegal = op == 5'd31;
        if (illegal) begin
            use_rs1 = 1'b0;
            use_rs2 = 1'b0;
            writes_rd = 1'b0;
            use_imm = 1'b0;
            immediate = 32'b0;
        end
    end
endmodule
