// Prove the production predicate tree for all candidate and age-mask inputs,
// without assuming that age bits form a total order.
module scheduler_predicates #(
    parameter integer WIDTH = 12
) (
    input wire [WIDTH-1:0] candidates,
    input wire [WIDTH-1:0] older,
    input wire branch_occupied,
    output wire ok
);
    wire none, one;
    integer count;
    zero_one_tree #(.WIDTH(WIDTH)) dut (
        .bits(candidates & older), .none(none), .one(one)
    );
    always @* begin
        count = 0;
        for (integer k = 0; k < WIDTH; k = k + 1)
            if (candidates[k] && older[k]) count = count + 1;
    end
    assign ok = (none == (count == 0)) && (one == (count == 1))
        && ((branch_occupied ? none : one) == (count == (branch_occupied ? 0 : 1)));
endmodule
