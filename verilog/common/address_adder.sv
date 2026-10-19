// Parallel prefix addition expressed as bit logic, so word-level resource
// sharing cannot insert late execution/admission muxes into this datapath.
module address_adder (
    input wire [31:0] a, b,
    input wire carry_in,
    output wire [31:0] sum
);
    wire [31:0] g [0:5];
    wire [31:0] p [0:5];
    assign g[0] = a & b;
    assign p[0] = a | b;
    generate
        for (genvar level = 0; level < 5; level = level + 1) begin : prefix
            for (genvar k = 0; k < 32; k = k + 1) begin : bits
                if (k >= (1 << level)) begin : merge
                    assign g[level+1][k] = g[level][k] | (p[level][k] & g[level][k-(1 << level)]);
                    assign p[level+1][k] = p[level][k] & p[level][k-(1 << level)];
                end else begin : pass
                    assign g[level+1][k] = g[level][k];
                    assign p[level+1][k] = p[level][k];
                end
            end
        end
        for (genvar k = 0; k < 32; k = k + 1) begin : result_bits
            if (k == 0) assign sum[k] = a[k] ^ b[k] ^ carry_in;
            else assign sum[k] = a[k] ^ b[k] ^ (g[5][k-1] | (p[5][k-1] & carry_in));
        end
    endgenerate
endmodule
