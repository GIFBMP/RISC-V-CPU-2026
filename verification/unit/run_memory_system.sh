#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$repo_root"
mkdir -p build/unit-memory-system
iverilog -g2012 -s memory_system_tb -o build/unit-memory-system/test.vvp \
    scripts/ram/sram_fakeram.sv \
    verilog/memory/blocking_cache.sv verilog/bus/axi_lite_bridge.sv \
    verilog/memory/memory_system.sv verification/unit/memory_system_tb.sv
vvp build/unit-memory-system/test.vvp

# Exercise the minimum legal index widths, then check that unsupported cache
# shapes fail elaboration instead of silently becoming a different design.
iverilog -g2012 -s memory_system -o build/unit-memory-system/minimum.vvp \
    -Pmemory_system.ICACHE_BYTES=4 -Pmemory_system.DCACHE_BYTES=4 \
    -Pmemory_system.CACHE_LINE_BYTES=4 \
    scripts/ram/sram_fakeram.sv \
    verilog/memory/blocking_cache.sv verilog/bus/axi_lite_bridge.sv \
    verilog/memory/memory_system.sv

for invalid_parameter in ICACHE_WAYS=2 DCACHE_WAYS=2 ICACHE_BYTES=96 CACHE_LINE_BYTES=12; do
    if iverilog -g2012 -s memory_system \
        -o build/unit-memory-system/invalid.vvp \
        "-Pmemory_system.$invalid_parameter" \
        scripts/ram/sram_fakeram.sv \
        verilog/memory/blocking_cache.sv verilog/bus/axi_lite_bridge.sv \
        verilog/memory/memory_system.sv \
        >build/unit-memory-system/invalid-parameter.log 2>&1; then
        printf 'FAIL: invalid cache parameter accepted: %s\n' "$invalid_parameter" >&2
        exit 1
    fi
done
printf 'PASS memory_system parameter validation\n'
