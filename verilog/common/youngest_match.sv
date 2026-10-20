// Select the youngest matching ROB entry in a circular allocation order.
// Entries below head belong to the younger wrapped partition. Within either
// partition the larger physical index is younger. A balanced tournament keeps
// each late address match local instead of driving every other entry's grant.
module youngest_match #(
    parameter integer WIDTH = 32,
    parameter integer DATA_BITS = 8,
    parameter integer INDEX_BITS = WIDTH > 1 ? $clog2(WIDTH) : 1,
    parameter integer ZERO_WHEN_INVALID = 1
) (
    input wire [WIDTH-1:0] match_bits,
    input wire [WIDTH*DATA_BITS-1:0] data,
    input wire [INDEX_BITS-1:0] head,
    output wire valid,
    output wire [DATA_BITS-1:0] result
);
    localparam integer LEAVES = 1 << $clog2(WIDTH);
    wire [2*LEAVES-1:1] present, wrapped;
    wire [DATA_BITS-1:0] values [1:2*LEAVES-1];
    generate
        for (genvar k = 0; k < LEAVES; k = k + 1) begin : leaves
            if (k < WIDTH) begin : used
                assign present[LEAVES+k] = match_bits[k];
                assign wrapped[LEAVES+k] = match_bits[k] && INDEX_BITS'(k) < head;
                assign values[LEAVES+k] = data[k*DATA_BITS +: DATA_BITS];
            end else begin : padding
                assign present[LEAVES+k] = 0;
                assign wrapped[LEAVES+k] = 0;
                assign values[LEAVES+k] = 0;
            end
        end
        for (genvar k = 1; k < LEAVES; k = k + 1) begin : branches
            wire take_right = wrapped[2*k+1] || (present[2*k+1] && !wrapped[2*k]);
            assign present[k] = present[2*k] || present[2*k+1];
            assign wrapped[k] = wrapped[2*k] || wrapped[2*k+1];
            assign values[k] = take_right ? values[2*k+1] : values[2*k];
        end
    endgenerate
    assign valid = present[1];
    // Consumers that retain valid separately need no late all-match reduction
    // on the data path. The selected value is unobservable when valid is low.
    assign result = ZERO_WHEN_INVALID != 0 && !present[1]
        ? {DATA_BITS{1'b0}} : values[1];
endmodule
