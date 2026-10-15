module alu (
    input  logic [4:0]  op,
    input  logic [31:0] lhs,
    input  logic [31:0] rhs,
    output logic [31:0] result
);
    always_comb begin
        case (op)
            5'd0: result = lhs + rhs;
            5'd1: result = lhs - rhs;
            5'd2: result = lhs << rhs[4:0];
            5'd3: result = {31'b0, $signed(lhs) < $signed(rhs)};
            5'd4: result = {31'b0, lhs < rhs};
            5'd5: result = lhs ^ rhs;
            5'd6: result = lhs >> rhs[4:0];
            5'd7: result = $signed(lhs) >>> rhs[4:0];
            5'd8: result = lhs | rhs;
            5'd9: result = lhs & rhs;
            5'd10: result = rhs;
            5'd11: result = lhs + rhs;
            default: result = 32'b0;
        endcase
    end
endmodule
