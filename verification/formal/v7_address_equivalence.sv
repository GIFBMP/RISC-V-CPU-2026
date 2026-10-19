module address_equivalence(input wire [31:0] a,b, output wire ok);
wire [16:0] lo = {1'b0,a[15:0]} + {1'b0,b[15:0]};
wire [15:0] hi0 = a[31:16] + b[31:16];
wire [15:0] hi1 = a[31:16] + b[31:16] + 16'd1;
wire [31:0] result = {lo[16] ? hi1 : hi0, lo[15:0]};
assign ok = result == (a + b);
endmodule
