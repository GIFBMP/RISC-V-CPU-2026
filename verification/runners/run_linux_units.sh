#!/bin/sh
# Run the existing execution/frontend benches with the course Linux toolchain.
# Invoke inside cpu2026:arm64; that image has Verilator but no Icarus Verilog.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$repo_root"
unit_out=${CPU2026_LINUX_UNIT_BUILD:-build/verification/unit-linux}
case "$unit_out" in /*) ;; *) unit_out="$repo_root/$unit_out" ;; esac
mkdir -p "$unit_out"

run_unit() {
    name=$1
    top=$2
    shift 2
    case_dir="$unit_out/$name"
    mkdir -p "$case_dir"
    if ! verilator --binary --timing --assert -Wno-fatal --top-module "$top" \
        --Mdir "$case_dir/obj" -o "$case_dir/sim" -j "${CPU2026_UNIT_JOBS:-3}" \
        "$@" > "$case_dir/compile.log" 2>&1; then
        cat "$case_dir/compile.log" >&2
        exit 1
    fi
    "$case_dir/sim" > "$case_dir/run.log" 2>&1
    cat "$case_dir/run.log"
}

run_unit decode_alu execute_decode_alu_tb verilog/execute/decoder.sv \
    verilog/execute/alu.sv verification/unit/execute_decode_alu_tb.sv
run_unit muldiv execute_muldiv_tb verilog/execute/muldiv_unit.sv \
    verification/unit/execute_muldiv_tb.sv

run_fetch() {
    name=$1
    queue=$2
    outstanding=$3
    btb=$4
    predict=$5
    ras=$6
    run_unit "$name" fetch_frontend_tb "-GQUEUE_DEPTH=$queue" "-GOUTSTANDING=$outstanding" \
        "-GBTB_SIZE=$btb" "-GPREDICT=$predict" "-GRAS_SIZE=$ras" \
        verilog/frontend/fetch_frontend.sv verification/unit/fetch_frontend_tb.sv
}
run_fetch fetch_default 8 4 64 1 16
run_fetch fetch_non_power_two 5 3 5 1 16
run_fetch fetch_minimum 1 1 1 1 16
run_fetch fetch_prediction_disabled 8 4 64 0 16
run_fetch fetch_more_contexts 3 5 3 1 16
run_fetch fetch_ras_zero 8 4 64 1 0
run_fetch fetch_ras_one 8 4 64 1 1
run_fetch fetch_ras_three 8 4 64 1 3
