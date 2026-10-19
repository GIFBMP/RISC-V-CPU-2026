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
    if ! "$case_dir/sim" > "$case_dir/run.log" 2>&1; then
        cat "$case_dir/run.log" >&2
        exit 1
    fi
    cat "$case_dir/run.log"
    # Some simulators print an immediate-assert error but return success.
    # A PASS banner must never hide such a diagnostic.
    if grep -Eq '(^|[[:space:]])(%?Error|ERROR|FATAL)(:|[[:space:]])' "$case_dir/run.log"; then
        exit 1
    fi
}

run_unit decode_alu execute_decode_alu_tb verilog/execute/decoder.sv \
    verilog/common/address_adder.sv verilog/execute/alu.sv verification/unit/execute_decode_alu_tb.sv
run_unit muldiv execute_muldiv_tb verilog/execute/muldiv_unit.sv \
    verification/unit/execute_muldiv_tb.sv

run_fetch() {
    name=$1
    queue=$2
    outstanding=$3
    btb=$4
    predict=$5
    ras=$6
    hash=${7:-0}
    overlap=${8:-0}
    bypass=${9:-0}
    direct=${10:-0}
    run_unit "$name" fetch_frontend_tb "-GQUEUE_DEPTH=$queue" "-GOUTSTANDING=$outstanding" \
        "-GBTB_SIZE=$btb" "-GPREDICT=$predict" "-GRAS_SIZE=$ras" \
        "-GBTB_HASH=$hash" "-GOVERLAP=$overlap" "-GBYPASS=$bypass" "-GDIRECT_REDIRECT=$direct" \
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
run_fetch fetch_xor_index 8 4 64 1 16 1
run_fetch fetch_xor_non_power_two 5 3 5 1 16 1
run_fetch fetch_redirect_overlap 8 4 64 1 16 0 1
run_fetch fetch_response_bypass 8 4 64 1 16 0 0 1
run_fetch fetch_both 8 4 64 1 16 1 1 1
run_fetch fetch_both_non_power_two 5 3 5 1 16 1 1 1
run_fetch fetch_both_minimum 1 1 1 1 16 1 1 1
run_fetch fetch_both_more_contexts 3 5 3 1 16 1 1 1
run_fetch fetch_direct_redirect 8 4 64 1 0 1 1 1 1
run_fetch fetch_direct_non_power_two 5 3 5 1 0 1 1 1 1
run_fetch fetch_direct_minimum 1 1 1 1 0 1 1 1 1
run_fetch fetch_direct_more_contexts 3 5 3 1 0 1 1 1 1
run_fetch fetch_direct_no_prediction 8 4 64 0 0 1 1 1 1
run_fetch fetch_direct_legacy_drain 8 4 64 1 0 0 0 0 1
run_fetch fetch_direct_ras_fallback 8 4 64 1 3 1 1 1 1

run_predictor() {
    name=$1
    btb=$2
    hash=$3
    history=$4
    run_unit "$name" fetch_predictor_tb "-GBTB_SIZE=$btb" "-GBTB_HASH=$hash" \
        "-GHISTORY_BITS=$history" verilog/frontend/fetch_frontend.sv verification/unit/fetch_predictor_tb.sv
}
run_predictor predictor_local_one 64 1 1
run_predictor predictor_local_low_index 64 0 1
run_predictor predictor_local_non_power_two 5 1 1
run_predictor predictor_local_minimum 1 1 1
run_predictor predictor_local_two 64 1 2
run_predictor predictor_local_two_non_power_two 5 1 2
run_predictor predictor_local_four 64 1 4
