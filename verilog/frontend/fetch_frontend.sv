// Ordered I-cache requests feed a separate instruction FIFO. Every accepted
// request reserves one or two FIFO words, so a full response stream cannot deadlock.
// Redirects clear queued instructions and mark accepted old requests killed.
// Optional overlap reuses free credits before all old responses have drained.
// Per-context cancellation has no finite epoch/tag that can wrap.
module fetch_frontend #(
    parameter integer FETCH_WIDTH = 1,
    parameter integer DECODE_WIDTH = 1,
    parameter integer PREDICT_ENABLE = 1,
    parameter integer BTB_ENTRIES = 64,
    parameter integer BTB_INDEX_XOR = 0,
    parameter integer LOCAL_HISTORY_BITS = 0,
    parameter integer REDIRECT_OVERLAP = 0,
    parameter integer RESPONSE_BYPASS = 0,
    parameter integer REDIRECT_REQUEST = 0,
    parameter integer FETCH_QUEUE_DEPTH = 8,
    parameter integer FETCH_OUTSTANDING = 4,
    parameter integer RAS_DEPTH = 16
) (
    input logic clock,
    input logic reset,
    input logic redirect_valid,
    input logic [31:0] redirect_pc,

    output logic instruction_valid,
    input logic instruction_ready,
    output logic [31:0] instruction_pc,
    output logic [31:0] instruction_data,
    output logic [31:0] instruction_predicted_pc,
    output logic instruction_error,
    output logic instruction2_valid,
    input logic instruction2_ready,
    output logic [31:0] instruction2_pc, instruction2_data, instruction2_predicted_pc,
    output logic instruction2_error,

    output logic i_req_valid,
    input logic i_req_ready,
    output logic [31:0] i_req_addr,
    input logic i_rsp_valid,
    output logic i_rsp_ready,
    input logic [31:0] i_rsp_data, i_rsp_data2,
    input logic i_rsp_error,

    input logic update_valid,
    input logic [31:0] update_pc,
    input logic [31:0] update_insn,
    input logic [31:0] update_target,
    input logic update_conditional,
    input logic update_taken
);
    localparam integer QW = (FETCH_QUEUE_DEPTH > 1) ? $clog2(FETCH_QUEUE_DEPTH) : 1;
    localparam integer QCW = $clog2(FETCH_QUEUE_DEPTH + 1);
    localparam integer OW = (FETCH_OUTSTANDING > 1) ? $clog2(FETCH_OUTSTANDING) : 1;
    localparam integer OCW = $clog2(FETCH_OUTSTANDING + 1);
    localparam integer TOTAL_W = $clog2(FETCH_QUEUE_DEPTH + 2*FETCH_OUTSTANDING + 3);
    localparam integer BW = (BTB_ENTRIES > 1) ? $clog2(BTB_ENTRIES) : 1;
    localparam integer RS = RAS_DEPTH > 0 ? RAS_DEPTH : 1;
    localparam integer RW = RS > 1 ? $clog2(RS) : 1;
    localparam integer RCW = $clog2(RS + 1);
    localparam integer HW = LOCAL_HISTORY_BITS > 0 ? LOCAL_HISTORY_BITS : 1;
    localparam integer PATTERNS = 1 << LOCAL_HISTORY_BITS;

    logic [31:0] next_pc, predicted_next, fetch_pc;
    logic [31:0] first_prediction, pair_pc, pair_prediction, pair_target;
    logic [31:0] redirect_pair_pc, redirect_pair_target, redirect_pair_prediction;
    logic normal_fetch_pair, redirect_fetch_pair;
    logic [BW-1:0] pair_index, redirect_pair_index;
    logic [BTB_ENTRIES-1:0] pair_match, redirect_pair_match;
    logic fetch_pair, response_pair;
    logic [FETCH_OUTSTANDING-1:0] request_pair;
    logic [31:0] request_prediction2 [0:FETCH_OUTSTANDING-1];
    logic [31:0] response_prediction2;
    logic [1:0] fetch_words, response_words, queue_push_count;
    logic [TOTAL_W-1:0] request_slots;
    logic request_on_redirect;
    logic redirect_request_pending;
    logic draining;
    logic [QW-1:0] queue_head, queue_tail;
    logic [FETCH_QUEUE_DEPTH-1:0] queue_head_onehot, queue_second_onehot;
    assign queue_second_onehot = (queue_head_onehot << 1) | (queue_head_onehot >> (FETCH_QUEUE_DEPTH-1));
    logic [QCW-1:0] queue_count;
    logic [31:0] queue_pc [0:FETCH_QUEUE_DEPTH-1];
    logic [31:0] queue_data [0:FETCH_QUEUE_DEPTH-1];
    logic [31:0] queue_prediction [0:FETCH_QUEUE_DEPTH-1];
    logic [FETCH_QUEUE_DEPTH-1:0] queue_error;

    logic [OW-1:0] request_head, request_tail;
    logic [OCW-1:0] request_count;
    logic [31:0] request_pc [0:FETCH_OUTSTANDING-1];
    logic [31:0] request_prediction [0:FETCH_OUTSTANDING-1];
    logic [FETCH_OUTSTANDING-1:0] request_killed;

    logic [BTB_ENTRIES-1:0] btb_valid, btb_conditional;
    logic [31:0] btb_pc [0:BTB_ENTRIES-1];
    logic [31:0] btb_target [0:BTB_ENTRIES-1];
    logic [1:0] btb_counter [0:BTB_ENTRIES-1];
    logic [1:0] btb_ras_action [0:BTB_ENTRIES-1];
    logic [BW-1:0] lookup_index, redirect_lookup_index, update_index;
    logic [BTB_ENTRIES-1:0] train_enable;
    logic [31:0] train_pc, train_target;
    logic [BTB_ENTRIES-1:0] train_conditional, train_taken;
    logic [1:0] train_ras_action, update_ras_action, prediction_ras_action;
    logic [31:0] response_pc, response_prediction;
    logic prediction_hit;
    logic [BTB_ENTRIES-1:0] prediction_match;
    logic [BTB_ENTRIES-1:0] redirect_prediction_match;
    logic redirect_prediction_hit;
    logic [BTB_ENTRIES-1:0] prediction_taken;
    logic [31:0] prediction_target, redirect_prediction_target;

    // The committed stack is the recovery base. Speculative pushes shadow
    // individual slots; recovery only clears these small valid bits, avoiding
    // a global flush mux on every return-address payload register.
    logic [31:0] ras_committed [0:RS-1];
    logic [31:0] ras_shadow [0:RS-1];
    logic [RS-1:0] ras_shadow_valid;
    logic [RW-1:0] ras_commit_pointer, ras_spec_pointer;
    logic [RCW-1:0] ras_commit_count, ras_spec_count;
    logic [RW-1:0] ras_commit_next_pointer, ras_spec_next_pointer;
    logic [RCW-1:0] ras_commit_next_count, ras_spec_next_count;
    logic [RW-1:0] ras_commit_write_slot, ras_spec_write_slot, ras_top_slot;
    logic ras_commit_write, ras_spec_write;
    logic [31:0] ras_top;

    logic instruction_fire, instruction2_fire, request_fire, response_fire, queue_push;
    logic [1:0] queue_pop_count;
    logic response_killed, response_live, bypass_response, bypass_payload, queue_pop;
    logic [TOTAL_W-1:0] reserved_slots;

    function automatic [QW-1:0] next_queue(input [QW-1:0] pointer);
        next_queue = pointer == QW'(FETCH_QUEUE_DEPTH-1) ? '0 : pointer + 1'b1;
    endfunction

    function automatic [OW-1:0] next_request(input [OW-1:0] pointer);
        next_request = pointer == OW'(FETCH_OUTSTANDING-1) ? '0 : pointer + 1'b1;
    endfunction

    function automatic [RW-1:0] next_ras(input [RW-1:0] pointer);
        next_ras = pointer == RW'(RS-1) ? '0 : pointer + 1'b1;
    endfunction

    function automatic [RW-1:0] previous_ras(input [RW-1:0] pointer);
        previous_ras = pointer == 0 ? RW'(RS-1) : pointer - 1'b1;
    endfunction

    // RISC-V implicit hints: bit 1 pushes, bit 0 pops. Different link
    // registers in JALR pop then push (coroutines); identical ones only push.
    function automatic [1:0] ras_action(input [31:0] insn);
        logic rd_link, rs1_link;
        begin
            rd_link = insn[11:7] == 5'd1 || insn[11:7] == 5'd5;
            rs1_link = insn[19:15] == 5'd1 || insn[19:15] == 5'd5;
            ras_action = 2'b00;
            if (insn[6:0] == 7'b1101111)
                ras_action = {rd_link, 1'b0};
            else if (insn[6:0] == 7'b1100111 && insn[14:12] == 3'b000)
                ras_action = {rd_link, rs1_link && (!rd_link || insn[11:7] != insn[19:15])};
        end
    endfunction

    // Fold unused binary indices once for non-power-of-two BTBs. Store the
    // complete PC so folding/aliasing can only affect prediction accuracy.
    function automatic [BW-1:0] btb_index(input [BW-1:0] raw_index);
        begin
            if (BTB_ENTRIES == 1) btb_index = '0;
            else if ({1'b0, raw_index} >= (BW+1)'(BTB_ENTRIES))
                btb_index = raw_index - BW'(BTB_ENTRIES);
            else btb_index = raw_index;
        end
    endfunction

    generate
        if ((FETCH_WIDTH != 1 && FETCH_WIDTH != 2) || (DECODE_WIDTH != 1 && DECODE_WIDTH != 2)
            || FETCH_QUEUE_DEPTH < 1 || FETCH_OUTSTANDING < 1
            || BTB_ENTRIES < 1 || BTB_ENTRIES > 65536 || RAS_DEPTH < 0
            || LOCAL_HISTORY_BITS < 0 || LOCAL_HISTORY_BITS > 4) begin : invalid_parameters
            fetch_frontend_requires_positive_supported_sizes invalid_configuration();
        end
    endgenerate

    always_comb begin
        // The redirect target is already registered by the backend. With no
        // speculative RAS to restore, its first request can use this edge.
        request_on_redirect = REDIRECT_REQUEST != 0 && RAS_DEPTH == 0 && redirect_valid;
        fetch_pc = request_on_redirect ? redirect_pc : next_pc;
        // XOR adjacent PC fields to separate branches a table-size apart.
        // Full PC tags still reject aliases, including folded odd-size tables.
        lookup_index = btb_index(BW'(next_pc >> 2)
                       ^ (BTB_INDEX_XOR != 0 ? BW'(next_pc >> (BW+2)) : BW'(0)));
        redirect_lookup_index = btb_index(BW'(redirect_pc >> 2)
                       ^ (BTB_INDEX_XOR != 0 ? BW'(redirect_pc >> (BW+2)) : BW'(0)));
        update_index = btb_index(BW'(update_pc >> 2)
                       ^ (BTB_INDEX_XOR != 0 ? BW'(update_pc >> (BW+2)) : BW'(0)));
        // Compare tags locally and OR one-hot target words. Dynamic array
        // reads would fan each PC index bit across all tag/target data muxes.
        prediction_target = 32'b0;
        redirect_prediction_target = 32'b0;
        prediction_ras_action = 2'b00;
        for (integer b = 0; b < BTB_ENTRIES; b = b + 1) begin
            // Resolve the two PCs independently through the complete table.
            // Redirect selects the final word, not every row's match signal.
            prediction_match[b] = PREDICT_ENABLE != 0 && btb_valid[b]
                && lookup_index == BW'(b) && btb_pc[b] == next_pc
                && (!btb_conditional[b] || prediction_taken[b]);
            redirect_prediction_match[b] = PREDICT_ENABLE != 0
                && REDIRECT_REQUEST != 0 && RAS_DEPTH == 0 && btb_valid[b]
                && redirect_lookup_index == BW'(b) && btb_pc[b] == redirect_pc
                && (!btb_conditional[b] || prediction_taken[b]);
            prediction_target = prediction_target | (btb_target[b] & {32{prediction_match[b]}});
            redirect_prediction_target = redirect_prediction_target
                | (btb_target[b] & {32{redirect_prediction_match[b]}});
            prediction_ras_action = prediction_ras_action | (btb_ras_action[b] & {2{prediction_match[b]}});
        end
        prediction_hit = |prediction_match;
        redirect_prediction_hit = |redirect_prediction_match;
        predicted_next = request_on_redirect
            ? (redirect_prediction_hit ? redirect_prediction_target : redirect_pc + 32'd4)
            : (prediction_hit ? prediction_target : next_pc + 32'd4);
        if (RAS_DEPTH > 0 && prediction_ras_action[0] && ras_spec_count != 0)
            predicted_next = ras_top;
        first_prediction = predicted_next;
        // A second word is used only from an aligned 8-byte group. Avoid
        // putting a 32-bit incrementer before this independent BTB lookup.
        pair_pc = {next_pc[31:3], 3'b100};
        redirect_pair_pc = {redirect_pc[31:3], 3'b100};
        pair_index = btb_index(BW'(pair_pc >> 2)
            ^ (BTB_INDEX_XOR != 0 ? BW'(pair_pc >> (BW+2)) : BW'(0)));
        redirect_pair_index = btb_index(BW'(redirect_pair_pc >> 2)
            ^ (BTB_INDEX_XOR != 0 ? BW'(redirect_pair_pc >> (BW+2)) : BW'(0)));
        pair_target = 0;
        redirect_pair_target = 0;
        for (integer b = 0; b < BTB_ENTRIES; b = b + 1) begin
            pair_match[b] = FETCH_WIDTH == 2 && PREDICT_ENABLE != 0 && btb_valid[b]
                && pair_index == BW'(b) && btb_pc[b] == pair_pc
                && (!btb_conditional[b] || prediction_taken[b]);
            pair_target |= btb_target[b] & {32{pair_match[b]}};
            redirect_pair_match[b] = FETCH_WIDTH == 2 && PREDICT_ENABLE != 0
                && REDIRECT_REQUEST != 0 && RAS_DEPTH == 0 && btb_valid[b]
                && redirect_pair_index == BW'(b) && btb_pc[b] == redirect_pair_pc
                && (!btb_conditional[b] || prediction_taken[b]);
            redirect_pair_target |= btb_target[b] & {32{redirect_pair_match[b]}};
        end
        normal_fetch_pair = FETCH_WIDTH == 2 && RAS_DEPTH == 0 && FETCH_QUEUE_DEPTH >= 2
            && next_pc[31:28] == 0 && next_pc[2:0] == 0 && !prediction_hit;
        redirect_fetch_pair = FETCH_WIDTH == 2 && RAS_DEPTH == 0 && FETCH_QUEUE_DEPTH >= 2
            && redirect_pc[31:28] == 0 && redirect_pc[2:0] == 0 && !redirect_prediction_hit;
        redirect_pair_prediction = |redirect_pair_match ? redirect_pair_target : redirect_pc + 32'd8;
        pair_prediction = request_on_redirect ? redirect_pair_prediction :
            (|pair_match ? pair_target : next_pc + 32'd8);
        fetch_pair = request_on_redirect ? redirect_fetch_pair : normal_fetch_pair;
        if (fetch_pair) predicted_next = pair_prediction;
    end
    assign fetch_words = fetch_pair ? 2'd2 : 2'd1;
    assign response_words = response_pair ? 2'd2 : 2'd1;

    // Keep payload independent of the ready/valid block. Besides documenting
    // the actual acyclic path, this avoids process-level false cycles in older
    // simulators when decode readiness feeds the request-credit calculation.
    always_comb begin
        // Decode a row once; a binary pointer must not drive every data mux.
        // Payload is don't-care when instruction_valid is low.
        instruction_pc = 32'b0;
        instruction_data = 32'b0;
        instruction_predicted_pc = 32'b0;
        instruction_error = 1'b0;
        for (integer q = 0; q < FETCH_QUEUE_DEPTH; q = q + 1) begin
            instruction_pc = instruction_pc | (queue_pc[q] & {32{queue_head_onehot[q]}});
            instruction_data = instruction_data | (queue_data[q] & {32{queue_head_onehot[q]}});
            instruction_predicted_pc = instruction_predicted_pc | (queue_prediction[q] & {32{queue_head_onehot[q]}});
            instruction_error = instruction_error | (queue_error[q] && queue_head_onehot[q]);
        end
        instruction2_pc = 0;
        instruction2_data = 0;
        instruction2_predicted_pc = 0;
        instruction2_error = 0;
        for (integer q = 0; q < FETCH_QUEUE_DEPTH; q = q + 1) begin
            instruction2_pc |= queue_pc[q] & {32{queue_second_onehot[q]}};
            instruction2_data |= queue_data[q] & {32{queue_second_onehot[q]}};
            instruction2_predicted_pc |= queue_prediction[q] & {32{queue_second_onehot[q]}};
            instruction2_error |= queue_error[q] && queue_second_onehot[q];
        end
        response_pc = 32'b0;
        response_prediction = 32'b0;
        response_prediction2 = 0;
        response_pair = 0;
        response_killed = 1'b0;
        for (integer r = 0; r < FETCH_OUTSTANDING; r = r + 1) begin
            response_pc = response_pc | (request_pc[r] & {32{request_head == OW'(r)}});
            response_prediction = response_prediction | (request_prediction[r] & {32{request_head == OW'(r)}});
            response_prediction2 |= request_prediction2[r] & {32{request_head == OW'(r)}};
            response_pair |= request_pair[r] && request_head == OW'(r);
            response_killed = response_killed | (request_killed[r] && request_head == OW'(r));
        end

        if (queue_count == 0 && RESPONSE_BYPASS != 0) begin
            instruction2_pc = response_pc + 32'd4;
            instruction2_data = i_rsp_data2;
            instruction2_predicted_pc = response_prediction2;
            instruction2_error = i_rsp_error;
        end
        if (queue_count == 1 && RESPONSE_BYPASS != 0) begin
            instruction2_pc = response_pc;
            instruction2_data = i_rsp_data;
            instruction2_predicted_pc = response_prediction;
            instruction2_error = i_rsp_error || response_pc[1:0] != 0;
        end
        bypass_payload = RESPONSE_BYPASS != 0 && queue_count == 0;
        // Invalid payload is don't-care. Keep response validity/cancellation
        // out of the wide mux feeding decode and prospective rename payload.
        if (bypass_payload) begin
            instruction_pc = response_pc;
            instruction_data = i_rsp_data;
            instruction_predicted_pc = response_prediction;
            instruction_error = i_rsp_error || response_pc[1:0] != 0;
        end
    end

    // Accepted requests already reserve response space. If one is in flight
    // the instruction FIFO cannot be full, so response acceptance need not
    // depend on decode/dispatch. Individual assignments preserve the actual
    // ready/valid dependency graph for process-based simulator scheduling.
    assign i_rsp_ready = !reset && request_count != 0;
    assign response_fire = i_rsp_valid && i_rsp_ready;
    assign response_live = response_fire && !response_killed && !redirect_valid;
    assign bypass_response = bypass_payload && response_live;
    assign instruction_valid = !reset && !redirect_valid && (queue_count != 0 || bypass_response);
    assign instruction_fire = instruction_valid && instruction_ready;
    assign instruction2_valid = DECODE_WIDTH == 2 && !reset && !redirect_valid
        && (queue_count >= 2 || (RESPONSE_BYPASS != 0 && response_live
            && (queue_count == 1 || (queue_count == 0 && response_pair))));
    assign instruction2_fire = instruction_fire && instruction2_valid && instruction2_ready;
    assign queue_pop = instruction_fire;
    assign queue_pop_count = {1'b0, instruction_fire} + {1'b0, instruction2_fire};
    // Write every live response into its reserved rows, including words
    // consumed directly this cycle. Advancing both ends on bypass keeps the
    // payload writes independent of either decode lane's ready signal.
    assign queue_push = response_live;
    assign queue_push_count = response_live ? response_words : 2'd0;
    assign reserved_slots = TOTAL_W'(queue_count) + request_slots;
    assign i_req_addr = fetch_pc;
    // Dual decode releases credits at the following edge. The FIFO absorbs
    // this elasticity while its wide decoder stays off the request path.
    assign i_req_valid = !reset && (!redirect_valid || request_on_redirect)
                     && (!draining || request_on_redirect || redirect_request_pending)
                     && (request_count < OCW'(FETCH_OUTSTANDING) || response_fire)
                     && (request_on_redirect
                         ? (request_slots + TOTAL_W'(fetch_words) <= TOTAL_W'(FETCH_QUEUE_DEPTH)
                             + (response_fire ? TOTAL_W'(response_words) : TOTAL_W'(0)))
                         : (reserved_slots + TOTAL_W'(fetch_words) <= TOTAL_W'(FETCH_QUEUE_DEPTH) + (DECODE_WIDTH == 1 ? TOTAL_W'(queue_pop_count) : TOTAL_W'(0))));
    assign request_fire = i_req_valid && i_req_ready;

    always_comb begin
        update_ras_action = ras_action(update_insn);
        ras_commit_next_pointer = ras_commit_pointer;
        ras_commit_next_count = ras_commit_count;
        if (PREDICT_ENABLE != 0 && RAS_DEPTH > 0 && update_valid && update_ras_action[0]
            && ras_commit_count != 0) begin
            ras_commit_next_pointer = previous_ras(ras_commit_pointer);
            ras_commit_next_count = ras_commit_count - 1'b1;
        end
        ras_commit_write_slot = ras_commit_next_pointer;
        ras_commit_write = PREDICT_ENABLE != 0 && RAS_DEPTH > 0 && !reset
                         && update_valid && update_ras_action[1];
        if (ras_commit_write) begin
            ras_commit_next_pointer = next_ras(ras_commit_write_slot);
            if (ras_commit_next_count < RCW'(RS))
                ras_commit_next_count = ras_commit_next_count + 1'b1;
        end

        ras_spec_next_pointer = ras_spec_pointer;
        ras_spec_next_count = ras_spec_count;
        if (RAS_DEPTH > 0 && prediction_ras_action[0] && ras_spec_count != 0) begin
            ras_spec_next_pointer = previous_ras(ras_spec_pointer);
            ras_spec_next_count = ras_spec_count - 1'b1;
        end
        ras_spec_write_slot = ras_spec_next_pointer;
        ras_spec_write = RAS_DEPTH > 0 && request_fire && prediction_ras_action[1];
        if (RAS_DEPTH > 0 && prediction_ras_action[1]) begin
            ras_spec_next_pointer = next_ras(ras_spec_write_slot);
            if (ras_spec_next_count < RCW'(RS))
                ras_spec_next_count = ras_spec_next_count + 1'b1;
        end
    end

    always_comb begin
        ras_top_slot = previous_ras(ras_spec_pointer);
        ras_top = 32'b0;
        for (integer r = 0; r < RS; r = r + 1)
            ras_top = ras_top | ((ras_shadow_valid[r] ? ras_shadow[r] : ras_committed[r])
                                 & {32{ras_top_slot == RW'(r)}});
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            ras_commit_pointer <= '0;
            ras_commit_count <= '0;
            ras_spec_pointer <= '0;
            ras_spec_count <= '0;
        end else begin
            ras_commit_pointer <= ras_commit_next_pointer;
            ras_commit_count <= ras_commit_next_count;
            if (redirect_valid) begin
                // Include a retirement on this same edge before recovery.
                ras_spec_pointer <= ras_commit_next_pointer;
                ras_spec_count <= ras_commit_next_count;
            end else if (request_fire) begin
                ras_spec_pointer <= ras_spec_next_pointer;
                ras_spec_count <= ras_spec_next_count;
            end
        end
    end
    generate
        for (genvar r = 0; r < RS; r = r + 1) begin : return_stack_rows
            always_ff @(posedge clock) begin
                if (ras_commit_write && ras_commit_write_slot == RW'(r))
                    ras_committed[r] <= update_pc + 32'd4;
                if (ras_spec_write && ras_spec_write_slot == RW'(r))
                    ras_shadow[r] <= next_pc + 32'd4;
                if (reset || redirect_valid)
                    ras_shadow_valid[r] <= 1'b0;
                else if (ras_spec_write && ras_spec_write_slot == RW'(r))
                    ras_shadow_valid[r] <= 1'b1;
            end
        end
    endgenerate

    always_ff @(posedge clock) begin
        if (reset) begin
            next_pc <= 32'b0;
            draining <= 1'b0;
            redirect_request_pending <= 1'b0;
            queue_head <= '0;
            queue_head_onehot <= {{(FETCH_QUEUE_DEPTH-1){1'b0}}, 1'b1};
            queue_tail <= '0;
            queue_count <= '0;
            queue_error <= '0;
            request_head <= '0;
            request_tail <= '0;
            request_count <= '0;
            request_slots <= '0;
            request_killed <= '0;
        end else begin
            request_slots <= request_slots + (request_fire ? TOTAL_W'(fetch_words) : TOTAL_W'(0))
                - (response_fire ? TOTAL_W'(response_words) : TOTAL_W'(0));
            if (request_fire) begin
                redirect_request_pending <= 1'b0;
                request_killed[request_tail] <= 1'b0;
                request_tail <= next_request(request_tail);
                next_pc <= predicted_next;
            end
            if (response_fire)
                request_head <= next_request(request_head);
            case ({request_fire, response_fire})
                2'b10: request_count <= request_count + 1'b1;
                2'b01: request_count <= request_count - 1'b1;
                default: ;
            endcase

            if (redirect_valid) begin
                // Legacy full-drain mode may still launch on a redirect edge.
                // If backpressured, keep that new request valid until accepted.
                redirect_request_pending <= request_on_redirect && i_req_valid && !i_req_ready;
                next_pc <= request_fire ? predicted_next : redirect_pc;
                queue_head <= '0;
                queue_head_onehot <= {{(FETCH_QUEUE_DEPTH-1){1'b0}}, 1'b1};
                queue_tail <= '0;
                queue_count <= '0;
                // A response consumed on the redirect edge belongs to the old
                // path too, including when it is the final outstanding one.
                request_killed <= '1;
                // A same-edge accepted request belongs to the new path; all
                // previously accepted descriptors retain their killed state.
                if (request_fire) request_killed[request_tail] <= 1'b0;
                draining <= REDIRECT_OVERLAP == 0 && request_count != 0
                         && !(response_fire && request_count == OCW'(1));
            end else begin
                if (draining && response_fire && request_count == OCW'(1))
                    draining <= 1'b0;
                if (queue_push) begin
                    queue_error[queue_tail] <= i_rsp_error || response_pc[1:0] != 0;
                    if (response_pair) queue_error[next_queue(queue_tail)] <= i_rsp_error;
                    queue_tail <= response_pair ? next_queue(next_queue(queue_tail)) : next_queue(queue_tail);
                end
                if (queue_pop) begin
                    queue_head <= queue_pop_count == 2 ? next_queue(next_queue(queue_head)) : next_queue(queue_head);
                    queue_head_onehot <= queue_pop_count == 2
                        ? ((queue_second_onehot << 1) | (queue_second_onehot >> (FETCH_QUEUE_DEPTH-1)))
                        : queue_second_onehot;
                end
                queue_count <= queue_count + QCW'(queue_push_count) - QCW'(queue_pop_count);
            end

        end
    end

    // The next request descriptor is unoccupied unless the ring is full.
    // A full ring may overwrite its tail only when the old head response is
    // consumed at this edge. Actual request_fire alone allocates its identity.
    // Prewriting removes decode/rename credit from the wide metadata enables.
    generate
        for (genvar r = 0; r < FETCH_OUTSTANDING; r = r + 1) begin : request_rows
            always_ff @(posedge clock) begin
                if ((request_count < OCW'(FETCH_OUTSTANDING) || response_fire)
                    && request_tail == OW'(r)) begin
                    request_pc[r] <= fetch_pc;
                    request_prediction[r] <= first_prediction;
                    request_prediction2[r] <= pair_prediction;
                    request_pair[r] <= fetch_pair;
                end
            end
        end
    endgenerate

    // Every outstanding request reserves its one or two FIFO words. Thus a
    // nonzero request count proves that the queue is not full and its tail
    // payload is unoccupied, even if the current response is killed/stalled.
    // Prewrite only that free row; real pushes alone advance the valid count.
    // This removes rename-ready/redirect from the wide payload write enables.
    generate
        for (genvar q = 0; q < FETCH_QUEUE_DEPTH; q = q + 1) begin : instruction_queue_rows
            always_ff @(posedge clock) begin
                if (request_count != 0 && queue_tail == QW'(q)) begin
                    queue_pc[q] <= response_pc;
                    queue_data[q] <= i_rsp_data;
                    queue_prediction[q] <= response_prediction;
                end
                if (request_count != 0 && response_pair && next_queue(queue_tail) == QW'(q)) begin
                    queue_pc[q] <= response_pc + 32'd4;
                    queue_data[q] <= i_rsp_data2;
                    queue_prediction[q] <= response_prediction2;
                end
            end
        end
    endgenerate

    // Train committed control flow through a registered bundle. One-hot row
    // enables cut the ROB-head-to-BTB path and eliminate dynamic training reads.
    // Predecode direction/type into each row at the same edge: these registers
    // carry distinct one-hot functions, rather than broadcasting one direction
    // bit to every history, counter and chooser gate in the complete table.
    // A redirect must not cancel this already-committed update.
    always_ff @(posedge clock) begin
        train_pc <= update_pc;
        train_target <= update_target;
        train_ras_action <= update_ras_action;
    end
    generate
        for (genvar b = 0; b < BTB_ENTRIES; b = b + 1) begin : predictor_rows
            if (LOCAL_HISTORY_BITS > 0) begin : local_predictor
                logic [HW-1:0] history;
                logic [1:0] counters [0:PATTERNS-1];
                logic [1:0] chooser;
                wire local_taken = counters[history][1];
                assign prediction_taken[b] = chooser[1] ? local_taken : btb_counter[b][1];
                // Local histories train only from retired branches. Recovery
                // therefore needs no speculative history checkpoint. The
                // chooser changes only when local and bimodal disagree.
                always_ff @(posedge clock) begin
                    if (train_enable[b] && train_conditional[b]) begin
                        if (btb_valid[b] && btb_pc[b] == train_pc && btb_conditional[b]) begin
                            history <= (history << 1) | HW'(train_taken[b]);
                            if (local_taken != btb_counter[b][1]) begin
                                if (local_taken == train_taken[b] && chooser != 2'b11)
                                    chooser <= chooser + 1'b1;
                                else if (local_taken != train_taken[b] && chooser != 2'b00)
                                    chooser <= chooser - 1'b1;
                            end
                            for (integer p = 0; p < PATTERNS; p = p + 1) begin
                                if (history == HW'(p)) begin
                                    if (train_taken[b] && counters[p] != 2'b11)
                                        counters[p] <= counters[p] + 1'b1;
                                    else if (!train_taken[b] && counters[p] != 2'b00)
                                        counters[p] <= counters[p] - 1'b1;
                                end
                            end
                        end else begin
                            history <= HW'(train_taken[b]);
                            chooser <= 2'b01;
                            for (integer p = 0; p < PATTERNS; p = p + 1)
                                counters[p] <= p == 0 ? (train_taken[b] ? 2'b10 : 2'b00) : 2'b01;
                        end
                    end
                end
            end else begin : bimodal_predictor
                assign prediction_taken[b] = btb_counter[b][1];
            end
            always_ff @(posedge clock) begin
                if (reset) begin
                    train_enable[b] <= 1'b0;
                    train_taken[b] <= 1'b0;
                    train_conditional[b] <= 1'b0;
                    btb_valid[b] <= 1'b0;
                    btb_conditional[b] <= 1'b0;
                end else begin
                    train_enable[b] <= PREDICT_ENABLE != 0 && update_valid && update_index == BW'(b);
                    train_taken[b] <= PREDICT_ENABLE != 0 && update_valid
                                   && update_index == BW'(b) && update_taken;
                    train_conditional[b] <= PREDICT_ENABLE != 0 && update_valid
                                         && update_index == BW'(b) && update_conditional;
                    if (train_enable[b]) begin
                        btb_valid[b] <= 1'b1;
                        btb_conditional[b] <= train_conditional[b];
                    end
                end
                if (train_enable[b]) begin
                    btb_pc[b] <= train_pc;
                    btb_target[b] <= train_target;
                    btb_ras_action[b] <= train_ras_action;
                    if (!train_conditional[b])
                        btb_counter[b] <= 2'b11;
                    else if (btb_valid[b] && btb_pc[b] == train_pc && btb_conditional[b]) begin
                        if (train_taken[b] && btb_counter[b] != 2'b11)
                            btb_counter[b] <= btb_counter[b] + 1'b1;
                        else if (!train_taken[b] && btb_counter[b] != 2'b00)
                            btb_counter[b] <= btb_counter[b] - 1'b1;
                    end else btb_counter[b] <= train_taken[b] ? 2'b10 : 2'b01;
                end
            end
        end
    endgenerate

`ifndef SYNTHESIS
    logic stalled_request, stalled_instruction;
    logic [31:0] held_request_addr, held_instruction_pc, held_instruction_data;
    logic [31:0] held_instruction_prediction;
    logic held_instruction_error;
    initial begin
        if ((FETCH_WIDTH != 1 && FETCH_WIDTH != 2) || (DECODE_WIDTH != 1 && DECODE_WIDTH != 2)
            || FETCH_QUEUE_DEPTH < 1 || FETCH_OUTSTANDING < 1 || BTB_ENTRIES < 1 || BTB_ENTRIES > 65536 || RAS_DEPTH < 0
            || LOCAL_HISTORY_BITS < 0 || LOCAL_HISTORY_BITS > 4)
            $fatal(1, "Unsupported fetch frontend parameters");
    end
    always @(posedge clock) begin
        if (reset) begin
            stalled_request <= 1'b0;
            stalled_instruction <= 1'b0;
        end else begin
            assert (queue_head_onehot == ({{(FETCH_QUEUE_DEPTH-1){1'b0}}, 1'b1} << queue_head));
            assert (int'(queue_count) <= FETCH_QUEUE_DEPTH) else $fatal(1, "instruction FIFO overflow");
            assert (int'(request_count) <= FETCH_OUTSTANDING) else $fatal(1, "fetch context overflow");
            assert (int'(reserved_slots) <= FETCH_QUEUE_DEPTH) else $fatal(1, "fetch credit overflow");
            assert (int'(ras_commit_count) <= RS && int'(ras_spec_count) <= RS)
                else $fatal(1, "return stack count overflow");
            if (stalled_request && !redirect_valid)
                assert (i_req_valid && i_req_addr == held_request_addr)
                    else $fatal(1, "backpressured fetch request changed");
            if (stalled_instruction && !redirect_valid)
                assert (instruction_valid && instruction_pc == held_instruction_pc
                        && instruction_data == held_instruction_data
                        && instruction_predicted_pc == held_instruction_prediction
                        && instruction_error == held_instruction_error)
                    else $fatal(1, "backpressured instruction changed");
            if (draining)
                assert ((!i_req_valid || request_on_redirect || redirect_request_pending) && queue_count == 0)
                    else $fatal(1, "legacy drain invariant");
            stalled_request <= i_req_valid && !i_req_ready;
            held_request_addr <= i_req_addr;
            stalled_instruction <= instruction_valid && !instruction_ready;
            held_instruction_pc <= instruction_pc;
            held_instruction_data <= instruction_data;
            held_instruction_prediction <= instruction_predicted_pc;
            held_instruction_error <= instruction_error;
        end
    end
`endif
endmodule
