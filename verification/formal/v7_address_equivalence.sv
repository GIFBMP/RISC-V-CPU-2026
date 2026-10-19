module address_equivalence(input wire [31:0] a,b, input wire carry_in, output wire ok);
wire [31:0] result;
address_adder dut (.a(a), .b(b), .carry_in(carry_in), .sum(result));
assign ok = result == (a + b + carry_in);
endmodule
