module forward_equivalence #(
    parameter integer WIDTH = 32,
    parameter integer INDEX_BITS = WIDTH > 1 ? $clog2(WIDTH) : 1
) (
    input wire [WIDTH-1:0] match_bits,
    input wire [WIDTH*8-1:0] data,
    input wire [INDEX_BITS-1:0] head,
    output wire ok
);
    wire valid;
    wire [7:0] result;
    wire unmasked_valid;
    wire [7:0] unmasked_result;
    reg [7:0] expected;
    reg [WIDTH-1:0] grant;
    youngest_match #(.WIDTH(WIDTH)) dut (.match_bits(match_bits), .data(data), .head(head), .valid(valid), .result(result));
    youngest_match #(.WIDTH(WIDTH), .ZERO_WHEN_INVALID(0)) unmasked_dut (
        .match_bits(match_bits), .data(data), .head(head),
        .valid(unmasked_valid), .result(unmasked_result));
    function automatic older(input [INDEX_BITS-1:0] a,b,h);
        if ((a >= h) != (b >= h)) older = a >= h;
        else older = a < b;
    endfunction
    always @* begin
        expected = 0;
        grant = match_bits;
        for (integer r = 0; r < WIDTH; r = r + 1) begin
            for (integer k = 0; k < WIDTH; k = k + 1)
                if (match_bits[k] && older(INDEX_BITS'(r), INDEX_BITS'(k), head)) grant[r] = 0;
            expected = expected | (data[8*r +: 8] & {8{grant[r]}});
        end
    end
    assign ok = result == expected && valid == (|match_bits)
        && unmasked_valid == valid && (!valid || unmasked_result == expected);
endmodule
