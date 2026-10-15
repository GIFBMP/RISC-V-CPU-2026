#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$repo_root"
unit_out=${CPU2026_WB_UNIT_BUILD:-build/v3/unit-writeback}
mkdir -p "$unit_out"

run_configuration() {
    name=$1
    ways=$2
    bytes=$3
    line=$4
    latency=$5
    iverilog -g2012 -s writeback_memory_tb \
        "-Pwriteback_memory_tb.DCACHE_WAYS=$ways" \
        "-Pwriteback_memory_tb.DCACHE_BYTES=$bytes" \
        "-Pwriteback_memory_tb.CACHE_LINE_BYTES=$line" \
        -o "$unit_out/$name.vvp" scripts/ram/sram_fakeram.sv \
        verilog/memory/blocking_cache.sv verilog/memory/icache_pipeline.sv \
        verilog/memory/dcache_writeback.sv verilog/bus/axi_lite_bridge.sv \
        verilog/memory/memory_system.sv verification/unit/writeback_memory_tb.sv \
        >"$unit_out/$name.compile.log" 2>&1
    vvp "$unit_out/$name.vvp" "+READ_LATENCY=$latency"
}

run_configuration direct 1 256 16 64
run_configuration two_way 2 256 16 64
run_configuration four_way 4 256 16 64
run_configuration low_latency 4 256 16 1
run_configuration long_line 4 256 64 64
run_configuration production_two_way 2 4096 16 64
run_configuration production_four_way 4 4096 16 64

# Narrow indices and one-word lines must elaborate. Unsupported shapes must fail.
iverilog -g2012 -s dcache_writeback -Pdcache_writeback.CACHE_BYTES=4 \
    -Pdcache_writeback.LINE_BYTES=4 -Pdcache_writeback.WAYS=1 \
    -o "$unit_out/minimum.vvp" scripts/ram/sram_fakeram.sv verilog/memory/dcache_writeback.sv
for invalid_parameter in WAYS=3 CACHE_BYTES=96 LINE_BYTES=12; do
    if iverilog -g2012 -s dcache_writeback "-Pdcache_writeback.$invalid_parameter" \
        -o "$unit_out/invalid.vvp" scripts/ram/sram_fakeram.sv verilog/memory/dcache_writeback.sv \
        >"$unit_out/invalid.log" 2>&1; then
        printf 'FAIL: invalid writeback cache parameter accepted: %s\n' "$invalid_parameter" >&2
        exit 1
    fi
done
printf 'PASS writeback_memory parameter validation\n'
