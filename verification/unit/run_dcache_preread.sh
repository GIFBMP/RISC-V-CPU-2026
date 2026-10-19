#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$repo_root"
unit_out=${CPU2026_DCACHE_UNIT_BUILD:-build/v5/unit-dcache-preread}
mkdir -p "$unit_out"
for fast_d in 0 1; do
    for pipelined_stores in 0 1; do
        name="noise-$fast_d-$pipelined_stores"
        iverilog -g2012 -s dcache_preread_tb \
            "-Pdcache_preread_tb.FAST_HIT_RESPONSE=$fast_d" \
            "-Pdcache_preread_tb.PIPELINED_STORE_HITS=$pipelined_stores" \
            -o "$unit_out/$name.vvp" scripts/ram/sram_fakeram.sv \
            verilog/memory/blocking_cache.sv verilog/memory/icache_pipeline.sv \
            verilog/memory/dcache_writeback.sv verilog/bus/axi_lite_bridge.sv \
            verilog/memory/memory_system.sv verification/unit/writeback_memory_tb.sv \
            verification/unit/dcache_preread_tb.sv \
            >"$unit_out/$name.compile.log" 2>&1
        for mode in slow fast; do
            if [ "$mode" = fast ]; then
                set -- +READ_LATENCY=1 +FAST_WRITE
            else
                set -- +READ_LATENCY=64
            fi
            log="$unit_out/$name.$mode.log"
            if ! vvp "$unit_out/$name.vvp" "$@" >"$log" 2>&1; then
                cat "$log"
                exit 1
            fi
            cat "$log"
            if rg -q '(^|[[:space:]])(ERROR|FATAL):' "$log" ||
                ! rg -q '^PASS writeback_memory:' "$log" ||
                ! rg -q '^PASS dcache_preread:' "$log"; then
                exit 1
            fi
        done
    done
done
