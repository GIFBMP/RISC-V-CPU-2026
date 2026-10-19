#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$repo_root"
unit_out=${CPU2026_UNIT_BUILD:-build/unit/execute}
mkdir -p "$unit_out"

if ! iverilog -g2012 -s execute_decode_alu_tb -o "$unit_out/decode_alu" \
    verilog/execute/decoder.sv verilog/common/address_adder.sv verilog/execute/alu.sv \
    verification/unit/execute_decode_alu_tb.sv > "$unit_out/decode_alu.compile.log" 2>&1; then
    cat "$unit_out/decode_alu.compile.log" >&2
    exit 1
fi
vvp "$unit_out/decode_alu"

if ! iverilog -g2012 -s execute_muldiv_tb -o "$unit_out/muldiv" \
    verilog/execute/muldiv_unit.sv verification/unit/execute_muldiv_tb.sv \
    > "$unit_out/muldiv.compile.log" 2>&1; then
    cat "$unit_out/muldiv.compile.log" >&2
    exit 1
fi
vvp "$unit_out/muldiv"
