`timescale 1ns/1ps
// Black-box ordered-cache model and independent accepted-request scoreboard.
// Predictor expectations are explicit trained outcomes, not a second BTB RTL.
module fetch_frontend_tb #(
    parameter integer QUEUE_DEPTH = 8,
    parameter integer OUTSTANDING = 4,
    parameter integer BTB_SIZE = 64,
    parameter integer PREDICT = 1
);
    logic clock = 0;
    always #5 clock = !clock;
    logic reset = 1;
    logic redirect_valid = 0;
    logic [31:0] redirect_pc = 0;
    logic instruction_valid, instruction_ready = 0;
    logic [31:0] instruction_pc, instruction_data, instruction_predicted_pc;
    logic instruction_error;
    logic i_req_valid, i_req_ready;
    logic [31:0] i_req_addr;
    logic i_rsp_valid, i_rsp_ready;
    logic [31:0] i_rsp_data;
    logic i_rsp_error;
    logic update_valid = 0;
    logic [31:0] update_pc = 0, update_target = 0;
    logic update_conditional = 0, update_taken = 0;

    fetch_frontend #(
        .FETCH_QUEUE_DEPTH(QUEUE_DEPTH), .FETCH_OUTSTANDING(OUTSTANDING),
        .BTB_ENTRIES(BTB_SIZE), .PREDICT_ENABLE(PREDICT)
    ) dut (.*);

    localparam integer MODEL_SIZE = 8192;
    localparam integer BI = BTB_SIZE > 1 ? $clog2(BTB_SIZE) : 1;
    integer cycle = 0;
    integer pending_head = 0, pending_tail = 0;
    integer expected_head = 0, expected_tail = 0;
    logic [31:0] pending_pc [0:MODEL_SIZE-1];
    logic [31:0] pending_prediction [0:MODEL_SIZE-1];
    integer pending_due [0:MODEL_SIZE-1];
    logic pending_killed [0:MODEL_SIZE-1];
    logic [31:0] expected_pc [0:MODEL_SIZE-1];
    logic [31:0] expected_prediction [0:MODEL_SIZE-1];
    logic [31:0] expected_fetch_pc = 0;

    logic cache_accept = 0;
    integer response_latency = 1;
    logic variable_latency = 0;
    integer accepted = 0, delivered = 0, dropped = 0, redirects = 0;
    integer errors_delivered = 0, simultaneous_request_response = 0;
    integer simultaneous_output_response = 0, maximum_pending = 0;
    integer output_streak = 0, longest_output_streak = 0;
    integer request_streak = 0, longest_request_streak = 0;
    integer same_edge_redirect_response = 0;
    integer back_to_back_training = 0, redirect_capture_training = 0;
    integer redirect_apply_training = 0, canceled_training = 0;
    logic model_training_pending = 0;
    logic [31:0] random_state = 32'h3a19_75cb;

    // At most two known entries are used in a predictor test. Collision tests
    // explicitly invalidate the overwritten expectation before fetching again.
    logic expected_a_valid = 0, expected_a_taken = 0;
    logic [31:0] expected_a_pc = 0, expected_a_target = 0;
    logic expected_b_valid = 0, expected_b_taken = 0;
    logic [31:0] expected_b_pc = 0, expected_b_target = 0;

    function automatic [31:0] memory_word(input [31:0] address);
        memory_word = address ^ 32'hcafe_5a5a;
    endfunction

    function automatic logic memory_error(input [31:0] address);
        memory_error = address[7:2] == 6'd31;
    endfunction

    function automatic [31:0] prediction(input [31:0] address);
        begin
            prediction = address + 32'd4;
            if (PREDICT != 0) begin
                if (expected_a_valid && address == expected_a_pc && expected_a_taken)
                    prediction = expected_a_target;
                if (expected_b_valid && address == expected_b_pc && expected_b_taken)
                    prediction = expected_b_target;
            end
        end
    endfunction

    always_comb begin
        i_req_ready = !reset && cache_accept;
        i_rsp_valid = !reset && pending_head < pending_tail
                   && cycle >= pending_due[pending_head];
        i_rsp_data = pending_head < pending_tail ? memory_word(pending_pc[pending_head]) : 32'b0;
        i_rsp_error = pending_head < pending_tail && memory_error(pending_pc[pending_head]);
    end

    logic sampled_reset, sampled_redirect, sampled_request, sampled_response, sampled_output;
    logic sampled_update;
    logic [31:0] sampled_redirect_pc, sampled_request_pc;
    logic [31:0] sampled_output_pc, sampled_output_data, sampled_output_prediction;
    logic sampled_output_error;
    integer index, live_pending;
    always @(posedge clock) begin
        sampled_reset = reset;
        sampled_update = update_valid;
        sampled_redirect = redirect_valid;
        sampled_redirect_pc = redirect_pc;
        sampled_request = i_req_valid && i_req_ready;
        sampled_request_pc = i_req_addr;
        sampled_response = i_rsp_valid && i_rsp_ready;
        sampled_output = instruction_valid && instruction_ready;
        sampled_output_pc = instruction_pc;
        sampled_output_data = instruction_data;
        sampled_output_prediction = instruction_predicted_pc;
        sampled_output_error = instruction_error;
        // Update the external model only after DUT sequential sampling.
        #1;
        if (sampled_reset) begin
            if (model_training_pending) canceled_training = canceled_training + 1;
            model_training_pending = 0;
            pending_head = 0;
            pending_tail = 0;
            expected_head = 0;
            expected_tail = 0;
            expected_fetch_pc = 0;
            expected_a_valid = 0;
            expected_b_valid = 0;
            cycle = 0;
            output_streak = 0;
            request_streak = 0;
        end else begin
            if (sampled_update && model_training_pending) back_to_back_training = back_to_back_training + 1;
            if (sampled_redirect && sampled_update) redirect_capture_training = redirect_capture_training + 1;
            if (sampled_redirect && model_training_pending) redirect_apply_training = redirect_apply_training + 1;
            model_training_pending = sampled_update;
            if (sampled_redirect) begin
                if (sampled_request || sampled_output)
                    $fatal(1, "redirect accepted a new request or delivered an old instruction");
                expected_head = expected_tail;
                expected_fetch_pc = sampled_redirect_pc;
                for (index = pending_head; index < pending_tail; index = index + 1)
                    pending_killed[index] = 1;
                redirects = redirects + 1;
                if (sampled_response) same_edge_redirect_response = same_edge_redirect_response + 1;
            end

            if (sampled_output) begin
                if (expected_head == expected_tail)
                    $fatal(1, "instruction delivered without an earlier cache response");
                if (sampled_output_pc !== expected_pc[expected_head]
                    || sampled_output_prediction !== expected_prediction[expected_head]
                    || sampled_output_data !== memory_word(expected_pc[expected_head])
                    || sampled_output_error !== (memory_error(expected_pc[expected_head])
                                                 || expected_pc[expected_head][1:0] != 0))
                    $fatal(1, "instruction mismatch pc=%08x expected=%08x prediction=%08x expected=%08x",
                           sampled_output_pc, expected_pc[expected_head],
                           sampled_output_prediction, expected_prediction[expected_head]);
                expected_head = expected_head + 1;
                delivered = delivered + 1;
                if (sampled_output_error) errors_delivered = errors_delivered + 1;
                output_streak = output_streak + 1;
                if (output_streak > longest_output_streak) longest_output_streak = output_streak;
            end else output_streak = 0;

            if (sampled_response) begin
                if (pending_head == pending_tail) $fatal(1, "response consumed without a request");
                if (pending_killed[pending_head]) dropped = dropped + 1;
                else begin
                    expected_pc[expected_tail] = pending_pc[pending_head];
                    expected_prediction[expected_tail] = pending_prediction[pending_head];
                    expected_tail = expected_tail + 1;
                end
                pending_head = pending_head + 1;
            end

            if (sampled_request) begin
                if (sampled_request_pc !== expected_fetch_pc)
                    $fatal(1, "request address got=%08x expected=%08x cycle=%0d",
                           sampled_request_pc, expected_fetch_pc, cycle);
                if (pending_head < pending_tail && pending_killed[pending_head])
                    $fatal(1, "new path request accepted before stale requests drained");
                pending_pc[pending_tail] = sampled_request_pc;
                pending_prediction[pending_tail] = prediction(sampled_request_pc);
                pending_due[pending_tail] = cycle + response_latency
                                          + (variable_latency ? pending_tail % 7 : 0);
                pending_killed[pending_tail] = 0;
                pending_tail = pending_tail + 1;
                expected_fetch_pc = prediction(sampled_request_pc);
                accepted = accepted + 1;
                request_streak = request_streak + 1;
                if (request_streak > longest_request_streak) longest_request_streak = request_streak;
            end else request_streak = 0;

            if (sampled_request && sampled_response) simultaneous_request_response = simultaneous_request_response + 1;
            if (sampled_output && sampled_response) simultaneous_output_response = simultaneous_output_response + 1;
            if (pending_tail - pending_head > maximum_pending) maximum_pending = pending_tail - pending_head;
            if (pending_tail - pending_head > OUTSTANDING) $fatal(1, "too many accepted requests");
            if (expected_tail - expected_head > QUEUE_DEPTH) $fatal(1, "instruction FIFO overfull");
            live_pending = 0;
            for (index = pending_head; index < pending_tail; index = index + 1)
                if (!pending_killed[index]) live_pending = live_pending + 1;
            if (live_pending + expected_tail - expected_head > QUEUE_DEPTH)
                $fatal(1, "response capacity was not reserved");
            if (pending_tail >= MODEL_SIZE-8 || expected_tail >= MODEL_SIZE-8)
                $fatal(1, "testbench storage exhausted");
            cycle = cycle + 1;
        end
    end

    task automatic steps(input integer count);
        repeat (count) @(negedge clock);
    endtask

    task automatic redirect(input [31:0] target);
        begin
            @(negedge clock);
            redirect_pc = target;
            redirect_valid = 1;
            @(negedge clock);
            redirect_valid = 0;
        end
    endtask

    task automatic pause_and_clear;
        begin
            @(negedge clock);
            cache_accept = 0;
            instruction_ready = 1;
            redirect(0);
            while (pending_head != pending_tail) @(negedge clock);
            steps(3);
            if (instruction_valid) $fatal(1, "queued old instructions survived redirect");
        end
    endtask

    task automatic train(input [31:0] pc, input [31:0] target,
                         input logic conditional, input logic taken);
        begin
            @(negedge clock);
            update_valid = 1;
            update_pc = pc;
            update_target = target;
            update_conditional = conditional;
            update_taken = taken;
            @(negedge clock);
            update_valid = 0;
            // Capture at edge N; the BTB applies at edge N+1. Expectations
            // change only after that edge, so an accepted request on N+1 still
            // uses the old prediction. Directed tests below exercise that edge.
            @(negedge clock);
        end
    endtask

    task automatic run_from(input [31:0] pc, input integer count);
        begin
            redirect(pc);
            cache_accept = 1;
            instruction_ready = 1;
            steps(count);
            pause_and_clear();
        end
    endtask

    integer iteration;
    integer before_accepted;
    logic [31:0] alias_pc;
    initial begin
        steps(4);
        reset = 0;
        cache_accept = 1;
        instruction_ready = 1;
        response_latency = 1;
        steps(160);
        if (QUEUE_DEPTH >= 3 && OUTSTANDING >= 2
            && (longest_output_streak < 64 || longest_request_streak < 64))
            $fatal(1, "continuous-hit path failed one instruction per cycle");

        // Fill the FIFO, then exercise simultaneous full dequeue/enqueue.
        instruction_ready = 0;
        steps(50);
        if (expected_tail - expected_head != QUEUE_DEPTH)
            $fatal(1, "backpressure did not fill the instruction FIFO");
        before_accepted = accepted;
        steps(15);
        if (accepted != before_accepted) $fatal(1, "requests continued without reserved space");
        instruction_ready = 1;
        steps(100);

        // Deterministic independent request and rename backpressure.
        variable_latency = 1;
        response_latency = 3;
        for (iteration = 0; iteration < 1600; iteration = iteration + 1) begin
            @(negedge clock);
            random_state = random_state ^ (random_state << 13);
            random_state = random_state ^ (random_state >> 17);
            random_state = random_state ^ (random_state << 5);
            cache_accept = random_state[0] | random_state[1];
            instruction_ready = random_state[3] | random_state[4];
            if (iteration % 137 == 0) begin
                redirect_valid = 1;
                redirect_pc = 32'h1000 + 32'(iteration * 4);
            end else redirect_valid = 0;
        end
        redirect_valid = 0;
        pause_and_clear();

        // Multiple redirects while old accepted requests are still pending.
        variable_latency = 0;
        response_latency = 40;
        cache_accept = 1;
        instruction_ready = 0;
        steps(5);
        redirect(32'h4000);
        redirect(32'h5000);
        redirect(32'h6000);
        instruction_ready = 1;
        steps(160);
        pause_and_clear();

        // Redirect and final response on the same clock edge.
        response_latency = 12;
        cache_accept = 1;
        steps(2);
        cache_accept = 0;
        while (!i_rsp_valid) @(negedge clock);
        redirect_valid = 1;
        redirect_pc = 32'h7000;
        @(negedge clock);
        redirect_valid = 0;
        while (pending_head != pending_tail) @(negedge clock);
        steps(3);
        if (same_edge_redirect_response == 0) $fatal(1, "same-edge redirect/response was not exercised");

        // Backpressured unaccepted requests may be canceled by redirect.
        response_latency = 1;
        cache_accept = 0;
        run_from(32'h8000, 10);
        cache_accept = 0;
        redirect(32'h9000);
        steps(5);
        if (!i_req_valid || i_req_addr != 32'h9000) $fatal(1, "missing stalled request");
        redirect(32'ha000);
        steps(5);
        if (!i_req_valid || i_req_addr != 32'ha000) $fatal(1, "unaccepted request not canceled");
        cache_accept = 1;
        steps(25);
        pause_and_clear();

        // Explicit two-bit counter outcomes: 2,3,2,1,0,1,2.
        train(32'h100, 32'h100, 1, 1);
        expected_a_valid = 1;
        expected_a_pc = 32'h100;
        expected_a_target = 32'h100;
        expected_a_taken = 1;
        run_from(32'h100, 100);
        train(32'h100, 32'h100, 1, 1);
        train(32'h100, 32'h100, 1, 0);
        run_from(32'h100, 30);
        train(32'h100, 32'h100, 1, 0);
        expected_a_taken = 0;
        run_from(32'h100, 30);
        train(32'h100, 32'h100, 1, 0);
        train(32'h100, 32'h100, 1, 1);
        run_from(32'h100, 30);
        train(32'h100, 32'h100, 1, 1);
        expected_a_taken = 1;
        run_from(32'h100, 30);

        // Unconditional branches predict their target even if taken input=0.
        train(32'h100, 32'h300, 0, 0);
        expected_a_target = 32'h300;
        run_from(32'h100, 50);

        // Full PC tags prevent a collision from borrowing another target.
        alias_pc = 32'h100 + (32'd1 << (BI+2));
        train(alias_pc, alias_pc, 0, 1);
        expected_a_valid = 0;
        expected_b_valid = 1;
        expected_b_pc = alias_pc;
        expected_b_target = alias_pc;
        expected_b_taken = 1;
        run_from(32'h100, 35);
        run_from(alias_pc, 35);

        // Predictor updates during request stall must preserve request address;
        // the accepted context captures the then-current prediction exactly.
        redirect(32'h100);
        cache_accept = 0;
        steps(5);
        train(32'h100, 32'h900, 0, 1);
        expected_b_valid = 0;
        expected_a_valid = 1;
        expected_a_taken = 1;
        expected_a_pc = 32'h100;
        expected_a_target = 32'h900;
        cache_accept = 1;
        instruction_ready = 0;
        steps(15);
        cache_accept = 0;
        train(32'h100, 32'ha00, 0, 1);
        expected_a_target = 32'ha00;
        instruction_ready = 1;
        steps(30);
        pause_and_clear();

        // Back-to-back updates of the same entry must use the preceding update,
        // not a stale counter: known state 00, then T,T -> 01,10 (predict taken).
        train(32'h100, 32'h100, 1, 0);
        train(32'h100, 32'h100, 1, 0);
        expected_a_pc = 32'h100;
        expected_a_target = 32'h100;
        expected_a_valid = 1;
        expected_a_taken = 0;
        @(negedge clock);
        update_valid = 1;
        update_pc = 32'h100;
        update_target = 32'h100;
        update_conditional = 1;
        update_taken = 1;
        steps(2);
        update_valid = 0;
        steps(1);
        expected_a_taken = 1;
        run_from(32'h100, 35);

        // A request accepted exactly when delayed training is applied carries
        // the old target. The next request for this PC observes the new target.
        redirect(32'h100);
        cache_accept = 0;
        steps(3);
        @(negedge clock);
        update_valid = 1;
        update_pc = 32'h100;
        update_target = 32'h900;
        update_conditional = 0;
        update_taken = 1;
        @(negedge clock);
        update_valid = 0;
        cache_accept = 1;
        before_accepted = accepted;
        @(negedge clock);
        if (accepted != before_accepted + 1)
            $fatal(1, "training-application request edge was not exercised");
        expected_a_target = 32'h900;
        instruction_ready = 1;
        steps(35);
        pause_and_clear();

        // Redirect must preserve a committed update both when captured and
        // when applied one cycle later. Keep cache requests paused meanwhile.
        @(negedge clock);
        redirect_valid = 1;
        redirect_pc = 32'h100;
        update_valid = 1;
        update_pc = 32'h100;
        update_target = 32'hb00;
        update_conditional = 0;
        update_taken = 1;
        @(negedge clock);
        update_valid = 0;
        redirect_pc = 32'h100;
        @(negedge clock);
        redirect_valid = 0;
        expected_a_target = 32'hb00;
        run_from(32'h100, 35);

        // Reset on the application edge cancels pending training. Although
        // payload bits may still change, valid must remain clear after reset.
        @(negedge clock);
        update_valid = 1;
        update_pc = 32'h100;
        update_target = 32'hd00;
        update_conditional = 0;
        update_taken = 1;
        @(negedge clock);
        update_valid = 0;
        reset = 1;
        @(negedge clock);
        reset = 0;
        run_from(32'h100, 35);

        // Misalignment is propagated as fetch error, and reset removes both
        // prediction state and all outstanding/queued frontend state.
        run_from(32'h1003, 30);
        response_latency = 30;
        cache_accept = 1;
        instruction_ready = 0;
        steps(6);
        reset = 1;
        steps(3);
        reset = 0;
        response_latency = 1;
        instruction_ready = 1;
        cache_accept = 1;
        steps(80);
        pause_and_clear();

        if (accepted < 300 || delivered < 200 || dropped == 0 || errors_delivered == 0)
            $fatal(1, "insufficient activity accepted=%0d delivered=%0d dropped=%0d errors=%0d",
                   accepted, delivered, dropped, errors_delivered);
        if (QUEUE_DEPTH >= 3 && OUTSTANDING >= 2
            && (simultaneous_request_response == 0 || simultaneous_output_response == 0))
            $fatal(1, "simultaneous queue operations were not covered");
        if (back_to_back_training == 0 || redirect_capture_training == 0
            || redirect_apply_training == 0 || canceled_training == 0)
            $fatal(1, "training pipeline edge coverage missing");
        $display("PASS fetch_frontend Q=%0d OUT=%0d BTB=%0d PRED=%0d accepted=%0d delivered=%0d dropped=%0d longest_output_streak=%0d",
                 QUEUE_DEPTH, OUTSTANDING, BTB_SIZE, PREDICT, accepted, delivered, dropped, longest_output_streak);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "fetch frontend test timed out");
    end
endmodule
