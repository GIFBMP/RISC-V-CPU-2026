#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$repo_root"
unit_out=${CPU2026_ICACHE_UNIT_BUILD:-build/v5/unit-icache-preread}
mkdir -p "$unit_out"
for fast_i in 0 1; do
    iverilog -g2012 -s icache_preread_tb \
        "-Picache_preread_tb.FAST_INSTRUCTION_RESPONSE=$fast_i" \
        -o "$unit_out/noise-$fast_i.vvp" scripts/ram/sram_fakeram.sv \
        verilog/memory/blocking_cache.sv verilog/memory/icache_pipeline.sv \
        verilog/memory/dcache_writeback.sv verilog/bus/axi_lite_bridge.sv \
        verilog/memory/memory_system.sv verification/unit/writeback_memory_tb.sv \
        verification/unit/icache_preread_tb.sv \
        >"$unit_out/noise-$fast_i.compile.log" 2>&1
    for mode in slow fast; do
        if [ "$mode" = fast ]; then
            set -- +READ_LATENCY=1 +FAST_WRITE
        else
            set -- +READ_LATENCY=64
        fi
        log="$unit_out/noise-$fast_i.$mode.log"
        if ! vvp "$unit_out/noise-$fast_i.vvp" "$@" >"$log" 2>&1; then
            cat "$log"
            exit 1
        fi
        cat "$log"
        if rg -q '(^|[[:space:]])(ERROR|FATAL):' "$log" ||
            ! rg -q '^PASS writeback_memory:' "$log" ||
            ! rg -q '^PASS icache_preread:' "$log"; then
            exit 1
        fi
    done
done
