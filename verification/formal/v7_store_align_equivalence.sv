module store_align_equivalence (
    input wire [31:0] value,
    input wire [1:0] offset,
    output wire ok
);
    wire [31:0] aligned;
    store_byte_align dut (.value(value), .offset(offset), .aligned(aligned));
    assign ok = aligned == (value << {offset,3'b000});
endmodule
