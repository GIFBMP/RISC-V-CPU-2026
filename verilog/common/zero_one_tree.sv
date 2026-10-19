// Balanced predicates for an arbitrary-width vector. Only the zero and one
// cases are needed by the scheduler; a full population count adds carry depth.
module zero_one_tree #(
    parameter integer WIDTH = 1
) (
    input  wire [WIDTH-1:0] bits,
    output wire none,
    output wire one
);
    localparam integer LEAVES = 1 << $clog2(WIDTH);
    wire [2*LEAVES-1:1] zeros, ones;
    generate
        for (genvar k = 0; k < LEAVES; k = k + 1) begin : leaves
            if (k < WIDTH) begin : used
                assign zeros[LEAVES+k] = !bits[k];
                assign ones[LEAVES+k] = bits[k];
            end else begin : padding
                assign zeros[LEAVES+k] = 1'b1;
                assign ones[LEAVES+k] = 1'b0;
            end
        end
        for (genvar k = 1; k < LEAVES; k = k + 1) begin : branches
            assign zeros[k] = zeros[2*k] && zeros[2*k+1];
            assign ones[k] = (ones[2*k] && zeros[2*k+1])
                          || (zeros[2*k] && ones[2*k+1]);
        end
    endgenerate
    assign none = zeros[1];
    assign one = ones[1];
endmodule
