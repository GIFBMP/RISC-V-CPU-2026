#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$repo_root"
unit_out=${CPU2026_WIDE_UNIT_BUILD:-build/unit/wide-fetch}
mkdir -p "$unit_out"
run_simulator() {
    vvp "$unit_out/$name" > "$unit_out/$name.run.log" 2>&1 || { cat "$unit_out/$name.run.log"; exit 1; }
    cat "$unit_out/$name.run.log"
    if rg -q '(^|[[:space:]])(ERROR|FATAL):' "$unit_out/$name.run.log" ||
        ! rg -q '^PASS ' "$unit_out/$name.run.log"; then
        exit 1
    fi
}
for config in '8 4 1 1' '5 3 1 1' '3 5 1 1' '2 1 1 1' '1 1 1 1' '8 4 0 1' '8 4 1 0'; do
    set -- $config
    name=fetch-$1-$2-$3-$4
    iverilog -g2012 -s wide_fetch_tb -Pwide_fetch_tb.QUEUE_DEPTH="$1" \
        -Pwide_fetch_tb.OUTSTANDING="$2" -Pwide_fetch_tb.BYPASS="$3" -Pwide_fetch_tb.DIRECT="$4" \
        -o "$unit_out/$name" verilog/frontend/fetch_frontend.sv verification/unit/wide_fetch_tb.sv \
        > "$unit_out/$name.compile.log" 2>&1
    run_simulator
done
for fast in 0 1; do
    for line in 8 128; do
        name=memory-$fast-$line
        iverilog -g2012 -s writeback_memory_tb -Pwriteback_memory_tb.FETCH_WIDTH=2 \
            -Pwriteback_memory_tb.ICACHE_LINE_BYTES="$line" -Pwriteback_memory_tb.FAST_INSTRUCTION_RESPONSE="$fast" \
            -o "$unit_out/$name" scripts/ram/sram_fakeram.sv verilog/bus/axi_lite_bridge.sv \
            verilog/memory/blocking_cache.sv verilog/memory/icache_pipeline.sv \
            verilog/memory/dcache_writeback.sv verilog/memory/memory_system.sv \
            verification/unit/writeback_memory_tb.sv > "$unit_out/$name.compile.log" 2>&1
        run_simulator
    done
done
