// A byte-lane selector, kept structurally distinct from the integer barrel
// shifter. Sharing a general shift with ALU SLL pulls Store execution/alias
// admission into the ALU bypass and then into the next early Load's address.
module store_byte_align (
    input wire [31:0] value,
    input wire [1:0] offset,
    output reg [31:0] aligned
);
    always @* begin
        case (offset)
            2'd0: aligned = value;
            2'd1: aligned = {value[23:0], 8'b0};
            2'd2: aligned = {value[15:0], 16'b0};
            2'd3: aligned = {value[7:0], 24'b0};
        endcase
    end
endmodule
