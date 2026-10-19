`timescale 1ns/1ps
// Independent ordered-request oracle for paired fetch, cancellation and partial
// decode consumption. No expected value is read from the implementation.
module wide_fetch_tb #(
    parameter integer QUEUE_DEPTH = 8, OUTSTANDING = 4, BYPASS = 1, DIRECT = 1
);
    logic clock = 0;
    always #5 clock = !clock;
    logic reset = 1, redirect_valid = 0;
    logic [31:0] redirect_pc = 0;
    logic instruction_valid, instruction_ready = 0, instruction_error;
    logic instruction2_valid, instruction2_ready = 0, instruction2_error;
    logic [31:0] instruction_pc, instruction_data, instruction_predicted_pc;
    logic [31:0] instruction2_pc, instruction2_data, instruction2_predicted_pc;
    logic i_req_valid, i_req_ready, i_rsp_valid, i_rsp_ready, i_rsp_error;
    logic [31:0] i_req_addr, i_rsp_data, i_rsp_data2;
    logic update_valid = 0, update_conditional = 0, update_taken = 1;
    logic [31:0] update_pc = 0, update_insn = 32'h0080006f, update_target = 0;
    logic cache_enable = 0, random_mode = 0;
    integer cycle = 0, ph = 0, pt = 0, eh = 0, et = 0;
    integer accepted = 0, delivered = 0, paired = 0, dropped = 0, faults = 0, partial = 0;
    logic [31:0] next_expected = 0, rng = 32'h91e2a381;
    logic [31:0] pending_pc [0:8191];
    integer pending_due [0:8191];
    logic pending_killed [0:8191];
    logic [31:0] expected_pc [0:16383], expected_prediction [0:16383];
    logic expected_error [0:16383];
    fetch_frontend #(.FETCH_WIDTH(2), .DECODE_WIDTH(2), .FETCH_QUEUE_DEPTH(QUEUE_DEPTH),
        .FETCH_OUTSTANDING(OUTSTANDING), .BTB_ENTRIES(64), .RAS_DEPTH(0),
        .REDIRECT_OVERLAP(1), .RESPONSE_BYPASS(BYPASS), .REDIRECT_REQUEST(DIRECT)) dut (.*);
    function automatic [31:0] prediction(input [31:0] pc);
        case (pc)
            32'h4: prediction = 32'h44;
            32'h4c: prediction = 0;
            32'h80: prediction = 32'h100;
            default: prediction = pc + 4;
        endcase
    endfunction
    function automatic logic error_at(input [31:0] pc);
        error_at = pc[1:0] != 0 || pc == 32'h44 || pc == 32'h148;
    endfunction
    function automatic [31:0] word_at(input [31:0] pc);
        word_at = pc ^ 32'hcafe5959;
    endfunction
    always_comb begin
        i_req_ready = cache_enable && (!random_mode || rng[2:0] != 0);
        i_rsp_valid = ph < pt && cycle >= pending_due[ph];
        i_rsp_data = word_at(pending_pc[ph]);
        i_rsp_data2 = word_at(pending_pc[ph] + 4);
        i_rsp_error = error_at(pending_pc[ph]);
    end
    task automatic check_output(input [31:0] pc, data, predicted, input logic fault);
        begin
            if (eh >= et || pc !== expected_pc[eh] || data !== word_at(pc)
                || predicted !== expected_prediction[eh] || fault !== expected_error[eh])
                $fatal(1, "wide fetch output order/data/target/error at index %0d: pc=%h expected=%h", eh, pc, expected_pc[eh]);
            eh = eh + 1;
            delivered = delivered + 1;
            if (fault) faults = faults + 1;
        end
    endtask
    logic sr, sf, so, so2, second_available, sd, req_pair;
    logic [31:0] sp, op, od, ot, op2, od2, ot2, redirect_sample;
    logic oe, oe2;
    integer k;
    always @(posedge clock) begin
        sr = i_req_valid && i_req_ready;
        sf = i_rsp_valid && i_rsp_ready;
        so = instruction_valid && instruction_ready;
        so2 = so && instruction2_valid && instruction2_ready;
        second_available = instruction2_valid;
        sd = redirect_valid;
        redirect_sample = redirect_pc;
        sp = i_req_addr;
        op = instruction_pc; od = instruction_data; ot = instruction_predicted_pc; oe = instruction_error;
        op2 = instruction2_pc; od2 = instruction2_data; ot2 = instruction2_predicted_pc; oe2 = instruction2_error;
        #1;
        if (!reset) begin
            cycle = cycle + 1;
            if (sd) begin
                if (so || so2) $fatal(1, "old-path output on redirect");
                eh = et;
                next_expected = redirect_sample;
                for (k = ph; k < pt; k = k + 1) pending_killed[k] = 1;
            end
            if (sf) begin
                if (pending_killed[ph]) dropped = dropped + 1;
                ph = ph + 1;
            end
            if (sr) begin
                if (sp !== next_expected) $fatal(1, "wrong request PC %h expected %h", sp, next_expected);
                req_pair = QUEUE_DEPTH >= 2 && sp[31:28] == 0 && sp[2:0] == 0 && prediction(sp) == sp + 4;
                pending_pc[pt] = sp;
                pending_killed[pt] = 0;
                pending_due[pt] = cycle + (random_mode ? 2 + int'(rng[6:3]) : 1);
                pt = pt + 1;
                accepted = accepted + 1;
                expected_pc[et] = sp;
                expected_prediction[et] = prediction(sp);
                expected_error[et] = error_at(sp);
                et = et + 1;
                if (req_pair) begin
                    expected_pc[et] = sp + 4;
                    expected_prediction[et] = prediction(sp + 4);
                    expected_error[et] = error_at(sp);
                    et = et + 1;
                    next_expected = prediction(sp + 4);
                end else next_expected = prediction(sp);
            end
            if (so) check_output(op, od, ot, oe);
            if (so2) begin check_output(op2, od2, ot2, oe2); paired = paired + 1; end
            if (so && !so2 && second_available) partial = partial + 1;
        end
    end
    task automatic train(input [31:0] pc, target);
        begin
            @(negedge clock); update_valid = 1; update_pc = pc; update_target = target;
            @(negedge clock); update_valid = 0;
            repeat (3) @(negedge clock);
        end
    endtask
    initial begin
        repeat (4) @(negedge clock);
        reset = 0;
        train(4, 32'h44); train(32'h4c, 0); train(32'h80, 32'h100);
        cache_enable = 1; instruction_ready = 1; instruction2_ready = 1;
        repeat (200) @(negedge clock);
        random_mode = 1;
        repeat (1500) begin
            @(negedge clock);
            rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
            instruction_ready = rng[0] || rng[1];
            instruction2_ready = rng[2];
            redirect_valid = rng[8:3] == 6'd17;
            case (rng[10:9])
                0: redirect_pc = 0;
                1: redirect_pc = 32'h80;
                2: redirect_pc = 32'h44;
                3: redirect_pc = 32'h2;
            endcase
        end
        @(negedge clock); redirect_valid = 0; random_mode = 0;
        instruction_ready = 1; instruction2_ready = 1;
        repeat (100) @(negedge clock);
        cache_enable = 0;
        repeat (60) @(negedge clock);
        if (eh != et || ph != pt || accepted < 100 || delivered < 100 || dropped < 1 || faults < 1
            || (QUEUE_DEPTH >= 2 && (paired < 10 || partial < 1)))
            $fatal(1, "wide fetch coverage failed accepted=%0d delivered=%0d paired=%0d dropped=%0d partial=%0d", accepted, delivered, paired, dropped, partial);
        $display("PASS wide_fetch Q=%0d O=%0d bypass=%0d direct=%0d requests=%0d words=%0d pairs=%0d canceled=%0d faults=%0d partial=%0d",
            QUEUE_DEPTH, OUTSTANDING, BYPASS, DIRECT, accepted, delivered, paired, dropped, faults, partial);
        $finish;
    end
    initial begin #200000; $fatal(1,"wide fetch timeout"); end
endmodule
