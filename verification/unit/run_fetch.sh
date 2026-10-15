#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$repo_root"
unit_out=${CPU2026_FETCH_UNIT_BUILD:-build/unit/fetch}
mkdir -p "$unit_out"

run_configuration() {
    name=$1
    queue=$2
    outstanding=$3
    btb=$4
    predict=$5
    if ! iverilog -g2012 -s fetch_frontend_tb \
        -Pfetch_frontend_tb.QUEUE_DEPTH="$queue" \
        -Pfetch_frontend_tb.OUTSTANDING="$outstanding" \
        -Pfetch_frontend_tb.BTB_SIZE="$btb" \
        -Pfetch_frontend_tb.PREDICT="$predict" \
        -o "$unit_out/$name" \
        verilog/frontend/fetch_frontend.sv verification/unit/fetch_frontend_tb.sv \
        > "$unit_out/$name.compile.log" 2>&1; then
        cat "$unit_out/$name.compile.log" >&2
        exit 1
    fi
    vvp "$unit_out/$name"
}

run_configuration default 8 4 64 1
run_configuration non_power_two 5 3 5 1
run_configuration minimum 1 1 1 1
run_configuration prediction_disabled 8 4 64 0
run_configuration more_contexts_than_slots 3 5 3 1
