module alu_equivalence (
    input wire [4:0] op,
    input wire [31:0] lhs, rhs,
    output wire ok
);
    wire [31:0] result;
    reg [31:0] expected;
    alu dut (.op(op), .lhs(lhs), .rhs(rhs), .result(result));
    always @* begin
        case (op)
            0, 11: expected = lhs + rhs;
            1: expected = lhs - rhs;
            2: expected = lhs << rhs[4:0];
            3: expected = {31'b0, $signed(lhs) < $signed(rhs)};
            4: expected = {31'b0, lhs < rhs};
            5: expected = lhs ^ rhs;
            6: expected = lhs >> rhs[4:0];
            7: expected = $signed(lhs) >>> rhs[4:0];
            8: expected = lhs | rhs;
            9: expected = lhs & rhs;
            10: expected = rhs;
            default: expected = 0;
        endcase
    end
    assign ok = result == expected;
endmodule
