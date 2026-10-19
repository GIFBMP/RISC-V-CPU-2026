// Check the early-Load immediate specialization against the production
// decoder and full-width modular addition for every instruction/base pair.
module load_immediate_equivalence (
    input wire [31:0] instruction, base,
    output wire ok
);
    wire [4:0] op;
    wire [31:0] immediate, address;
    wire illegal;
    decoder decode (.instruction(instruction), .op(op), .immediate(immediate), .illegal(illegal));
    wire [31:0] load_immediate = {{20{immediate[11]}}, immediate[11:0]};
    address_adder add (.a(base), .b(load_immediate), .carry_in(1'b0), .sum(address));
    assign ok = illegal || op != 5'd15
        || (immediate == {{20{instruction[31]}}, instruction[31:20]}
            && address == base + immediate);
endmodule
