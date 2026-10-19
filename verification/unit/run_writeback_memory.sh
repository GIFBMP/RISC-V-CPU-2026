#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$repo_root"
unit_out=${CPU2026_WB_UNIT_BUILD:-build/v5/unit-writeback}
mkdir -p "$unit_out"

run_configuration() {
    name=$1
    ways=$2
    bytes=$3
    line=$4
    latency=$5
    write_mode=${6:-normal}
    fast_d=${7:-0}
    fast_i=${8:-0}
    pipelined_stores=${9:-0}
    i_line=${10:-$line}
    iverilog -g2012 -s writeback_memory_tb \
        "-Pwriteback_memory_tb.DCACHE_WAYS=$ways" \
        "-Pwriteback_memory_tb.DCACHE_BYTES=$bytes" \
        "-Pwriteback_memory_tb.CACHE_LINE_BYTES=$line" \
        "-Pwriteback_memory_tb.ICACHE_LINE_BYTES=$i_line" \
        "-Pwriteback_memory_tb.FAST_HIT_RESPONSE=$fast_d" \
        "-Pwriteback_memory_tb.FAST_INSTRUCTION_RESPONSE=$fast_i" \
        "-Pwriteback_memory_tb.PIPELINED_STORE_HITS=$pipelined_stores" \
        -o "$unit_out/$name.vvp" scripts/ram/sram_fakeram.sv \
        verilog/memory/blocking_cache.sv verilog/memory/icache_pipeline.sv \
        verilog/memory/dcache_writeback.sv verilog/bus/axi_lite_bridge.sv \
        verilog/memory/memory_system.sv verification/unit/writeback_memory_tb.sv \
        >"$unit_out/$name.compile.log" 2>&1
    if [ "$write_mode" = fast ]; then
        if ! vvp "$unit_out/$name.vvp" "+READ_LATENCY=$latency" +FAST_WRITE >"$unit_out/$name.run.log" 2>&1; then
            cat "$unit_out/$name.run.log"
            return 1
        fi
    else
        if ! vvp "$unit_out/$name.vvp" "+READ_LATENCY=$latency" >"$unit_out/$name.run.log" 2>&1; then
            cat "$unit_out/$name.run.log"
            return 1
        fi
    fi
    cat "$unit_out/$name.run.log"
    # Icarus immediate assertions can report ERROR yet exit zero. Treat those
    # diagnostics as failures as well as checking the explicit end-of-test PASS.
    if rg -q '(^|[[:space:]])(ERROR|FATAL):' "$unit_out/$name.run.log" ||
        ! rg -q '^PASS writeback_memory:' "$unit_out/$name.run.log"; then
        return 1
    fi
}

run_configuration direct 1 256 16 64
run_configuration two_way 2 256 16 64
run_configuration four_way 4 256 16 64
run_configuration low_latency 4 256 16 1
run_configuration fast_write 4 256 16 1 fast
run_configuration long_line 4 256 64 64
run_configuration long_line_fast 4 256 64 1 fast
# More than sixteen words forces the writeback SRAM FIFO to stop/restart while
# all bridge write credits are occupied; 64B lines alone cannot cover that now.
run_configuration beyond_write_credits 4 1024 128 64
run_configuration production_two_way 2 4096 16 64
run_configuration production_four_way 4 4096 16 64
run_configuration production_large 4 16384 64 64
run_configuration production_large_fast 4 16384 64 1 fast
run_configuration production_128 4 16384 128 64
run_configuration production_128_fast 4 16384 128 1 fast

# Independent and combined fall-through paths must retain ordering, backpressure,
# RAW store/load semantics, miss errors and the complete writeback/flush checks.
run_configuration fallthrough_d 4 256 16 1 fast 1 0
run_configuration fallthrough_i 4 256 16 1 fast 0 1
run_configuration fallthrough_direct 1 256 16 64 normal 1 1
run_configuration fallthrough_two_way 2 256 16 64 normal 1 1
run_configuration fallthrough_both 4 256 16 64 normal 1 1
run_configuration fallthrough_production 4 16384 128 64 normal 1 1
run_configuration fallthrough_production_fast 4 16384 128 1 fast 1 1

run_configuration pipelined_stores_registered 4 256 16 1 fast 0 0 1
run_configuration pipelined_stores_direct 1 256 16 64 normal 1 1 1
run_configuration pipelined_stores_two_way 2 256 16 64 normal 1 1 1
run_configuration pipelined_stores_production 4 16384 128 64 normal 1 1 1
run_configuration pipelined_stores_production_fast 4 16384 128 1 fast 1 1 1
run_configuration pipelined_stores_256 4 16384 256 64 normal 1 1 1
run_configuration pipelined_stores_256_fast 4 16384 256 1 fast 1 1 1
run_configuration final_split_line 4 16384 256 64 normal 1 1 1 128
run_configuration final_split_line_fast 4 16384 256 1 fast 1 1 1 128

# Narrow indices and one-word lines must elaborate. Unsupported shapes must fail.
iverilog -g2012 -s dcache_writeback -Pdcache_writeback.CACHE_BYTES=4 \
    -Pdcache_writeback.LINE_BYTES=4 -Pdcache_writeback.WAYS=1 \
    -o "$unit_out/minimum.vvp" scripts/ram/sram_fakeram.sv verilog/memory/dcache_writeback.sv
for invalid_parameter in WAYS=3 CACHE_BYTES=96 LINE_BYTES=12 FAST_HIT_RESPONSE=2 PIPELINED_STORE_HITS=2; do
    if iverilog -g2012 -s dcache_writeback "-Pdcache_writeback.$invalid_parameter" \
        -o "$unit_out/invalid.vvp" scripts/ram/sram_fakeram.sv verilog/memory/dcache_writeback.sv \
        >"$unit_out/invalid.log" 2>&1; then
        printf 'FAIL: invalid writeback cache parameter accepted: %s\n' "$invalid_parameter" >&2
        exit 1
    fi
done
if iverilog -g2012 -s icache_pipeline -Picache_pipeline.FAST_INSTRUCTION_RESPONSE=2 \
    -o "$unit_out/invalid-i.vvp" scripts/ram/sram_fakeram.sv verilog/memory/icache_pipeline.sv \
    >"$unit_out/invalid-i.log" 2>&1; then
    printf 'FAIL: invalid instruction cache response parameter accepted\n' >&2
    exit 1
fi
printf 'PASS writeback_memory parameter validation\n'
