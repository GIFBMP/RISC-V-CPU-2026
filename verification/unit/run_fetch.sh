#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$repo_root"
unit_out=${CPU2026_FETCH_UNIT_BUILD:-build/unit/fetch}
mkdir -p "$unit_out"

run_simulator() {
    if ! vvp "$unit_out/$name" > "$unit_out/$name.run.log" 2>&1; then
        cat "$unit_out/$name.run.log" >&2
        exit 1
    fi
    cat "$unit_out/$name.run.log"
    if grep -Eq '(^|[[:space:]])(%?Error|ERROR|FATAL)(:|[[:space:]])' "$unit_out/$name.run.log"; then
        exit 1
    fi
}

run_configuration() {
    name=$1
    queue=$2
    outstanding=$3
    btb=$4
    predict=$5
    hash=${6:-0}
    overlap=${7:-0}
    bypass=${8:-0}
    direct=${9:-0}
    ras=${10:-16}
    if ! iverilog -g2012 -s fetch_frontend_tb \
        -Pfetch_frontend_tb.QUEUE_DEPTH="$queue" \
        -Pfetch_frontend_tb.OUTSTANDING="$outstanding" \
        -Pfetch_frontend_tb.BTB_SIZE="$btb" \
        -Pfetch_frontend_tb.PREDICT="$predict" \
        -Pfetch_frontend_tb.BTB_HASH="$hash" \
        -Pfetch_frontend_tb.OVERLAP="$overlap" \
        -Pfetch_frontend_tb.BYPASS="$bypass" \
        -Pfetch_frontend_tb.DIRECT_REDIRECT="$direct" \
        -Pfetch_frontend_tb.RAS_SIZE="$ras" \
        -o "$unit_out/$name" \
        verilog/frontend/fetch_frontend.sv verification/unit/fetch_frontend_tb.sv \
        > "$unit_out/$name.compile.log" 2>&1; then
        cat "$unit_out/$name.compile.log" >&2
        exit 1
    fi
    run_simulator
}

run_configuration default 8 4 64 1
run_configuration non_power_two 5 3 5 1
run_configuration minimum 1 1 1 1
run_configuration prediction_disabled 8 4 64 0
run_configuration more_contexts_than_slots 3 5 3 1
run_configuration xor_index 8 4 64 1 1
run_configuration xor_non_power_two 5 3 5 1 1
run_configuration redirect_overlap 8 4 64 1 0 1
run_configuration response_bypass 8 4 64 1 0 0 1
run_configuration both 8 4 64 1 1 1 1
run_configuration both_non_power_two 5 3 5 1 1 1 1
run_configuration both_minimum 1 1 1 1 1 1 1
run_configuration both_more_contexts 3 5 3 1 1 1 1
run_configuration direct_redirect 8 4 64 1 1 1 1 1 0
run_configuration direct_non_power_two 5 3 5 1 1 1 1 1 0
run_configuration direct_minimum 1 1 1 1 1 1 1 1 0
run_configuration direct_more_contexts 3 5 3 1 1 1 1 1 0
run_configuration direct_no_prediction 8 4 64 0 1 1 1 1 0
run_configuration direct_legacy_drain 8 4 64 1 0 0 0 1 0
run_configuration direct_ras_fallback 8 4 64 1 1 1 1 1 3

run_predictor() {
    name=$1
    btb=$2
    hash=$3
    history=$4
    if ! iverilog -g2012 -s fetch_predictor_tb \
        -Pfetch_predictor_tb.BTB_SIZE="$btb" \
        -Pfetch_predictor_tb.BTB_HASH="$hash" \
        -Pfetch_predictor_tb.HISTORY_BITS="$history" \
        -o "$unit_out/$name" \
        verilog/frontend/fetch_frontend.sv verification/unit/fetch_predictor_tb.sv \
        > "$unit_out/$name.compile.log" 2>&1; then
        cat "$unit_out/$name.compile.log" >&2
        exit 1
    fi
    run_simulator
}
run_predictor local_one 64 1 1
run_predictor local_low_index 64 0 1
run_predictor local_non_power_two 5 1 1
run_predictor local_minimum 1 1 1
run_predictor local_two 64 1 2
run_predictor local_two_non_power_two 5 1 2
run_predictor local_four 64 1 4
