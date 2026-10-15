// Ordered I-cache requests feed a separate instruction FIFO. Every accepted
// request reserves a FIFO slot, so a full response stream cannot deadlock.
// Redirects clear queued instructions and drain all accepted old requests
// before sending the latest target. No finite epoch/tag can wrap during drain.
module fetch_frontend #(
    parameter integer PREDICT_ENABLE = 1,
    parameter integer BTB_ENTRIES = 64,
    parameter integer FETCH_QUEUE_DEPTH = 8,
    parameter integer FETCH_OUTSTANDING = 4
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

    output logic i_req_valid,
    input logic i_req_ready,
    output logic [31:0] i_req_addr,
    input logic i_rsp_valid,
    output logic i_rsp_ready,
    input logic [31:0] i_rsp_data,
    input logic i_rsp_error,

    input logic update_valid,
    input logic [31:0] update_pc,
    input logic [31:0] update_target,
    input logic update_conditional,
    input logic update_taken
);
    localparam integer QW = (FETCH_QUEUE_DEPTH > 1) ? $clog2(FETCH_QUEUE_DEPTH) : 1;
    localparam integer QCW = $clog2(FETCH_QUEUE_DEPTH + 1);
    localparam integer OW = (FETCH_OUTSTANDING > 1) ? $clog2(FETCH_OUTSTANDING) : 1;
    localparam integer OCW = $clog2(FETCH_OUTSTANDING + 1);
    localparam integer TOTAL_W = $clog2(FETCH_QUEUE_DEPTH + FETCH_OUTSTANDING + 1);
    localparam integer BW = (BTB_ENTRIES > 1) ? $clog2(BTB_ENTRIES) : 1;

    logic [31:0] next_pc, predicted_next;
    logic draining;
    logic [QW-1:0] queue_head, queue_tail;
    logic [QCW-1:0] queue_count;
    logic [31:0] queue_pc [0:FETCH_QUEUE_DEPTH-1];
    logic [31:0] queue_data [0:FETCH_QUEUE_DEPTH-1];
    logic [31:0] queue_prediction [0:FETCH_QUEUE_DEPTH-1];
    logic [FETCH_QUEUE_DEPTH-1:0] queue_error;

    logic [OW-1:0] request_head, request_tail;
    logic [OCW-1:0] request_count;
    logic [31:0] request_pc [0:FETCH_OUTSTANDING-1];
    logic [31:0] request_prediction [0:FETCH_OUTSTANDING-1];

    logic [BTB_ENTRIES-1:0] btb_valid, btb_conditional;
    logic [31:0] btb_pc [0:BTB_ENTRIES-1];
    logic [31:0] btb_target [0:BTB_ENTRIES-1];
    logic [1:0] btb_counter [0:BTB_ENTRIES-1];
    logic [BW-1:0] lookup_index, update_index;
    logic [BTB_ENTRIES-1:0] train_enable;
    logic [31:0] train_pc, train_target;
    logic train_conditional, train_taken;
    logic [31:0] response_pc, response_prediction;
    logic prediction_hit;
    logic [BTB_ENTRIES-1:0] prediction_match;
    logic [31:0] prediction_target;

    logic instruction_fire, request_fire, response_fire, queue_push;
    logic [TOTAL_W-1:0] reserved_slots;

    function automatic [QW-1:0] next_queue(input [QW-1:0] pointer);
        next_queue = pointer == QW'(FETCH_QUEUE_DEPTH-1) ? '0 : pointer + 1'b1;
    endfunction

    function automatic [OW-1:0] next_request(input [OW-1:0] pointer);
        next_request = pointer == OW'(FETCH_OUTSTANDING-1) ? '0 : pointer + 1'b1;
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
        if (FETCH_QUEUE_DEPTH < 1 || FETCH_OUTSTANDING < 1
            || BTB_ENTRIES < 1 || BTB_ENTRIES > 65536) begin : invalid_parameters
            fetch_frontend_requires_positive_supported_sizes invalid_configuration();
        end
    endgenerate

    always_comb begin
        lookup_index = btb_index(next_pc[BW+1:2]);
        update_index = btb_index(update_pc[BW+1:2]);
        // Compare tags locally and OR one-hot target words. Dynamic array
        // reads would fan each PC index bit across all tag/target data muxes.
        prediction_target = 32'b0;
        for (integer b = 0; b < BTB_ENTRIES; b = b + 1) begin
            prediction_match[b] = PREDICT_ENABLE != 0 && lookup_index == BW'(b) && btb_valid[b]
                && btb_pc[b] == next_pc
                && (!btb_conditional[b] || btb_counter[b][1]);
            prediction_target = prediction_target | (btb_target[b] & {32{prediction_match[b]}});
        end
        prediction_hit = |prediction_match;
        predicted_next = prediction_hit ? prediction_target : next_pc + 32'd4;

        instruction_valid = !reset && !redirect_valid && queue_count != 0;
        // Decode a row once; a binary pointer must not drive every data mux.
        // Payload is don't-care when instruction_valid is low.
        instruction_pc = 32'b0;
        instruction_data = 32'b0;
        instruction_predicted_pc = 32'b0;
        instruction_error = 1'b0;
        for (integer q = 0; q < FETCH_QUEUE_DEPTH; q = q + 1) begin
            instruction_pc = instruction_pc | (queue_pc[q] & {32{queue_head == QW'(q)}});
            instruction_data = instruction_data | (queue_data[q] & {32{queue_head == QW'(q)}});
            instruction_predicted_pc = instruction_predicted_pc | (queue_prediction[q] & {32{queue_head == QW'(q)}});
            instruction_error = instruction_error | (queue_error[q] && queue_head == QW'(q));
        end
        response_pc = 32'b0;
        response_prediction = 32'b0;
        for (integer r = 0; r < FETCH_OUTSTANDING; r = r + 1) begin
            response_pc = response_pc | (request_pc[r] & {32{request_head == OW'(r)}});
            response_prediction = response_prediction | (request_prediction[r] & {32{request_head == OW'(r)}});
        end
        instruction_fire = instruction_valid && instruction_ready;

        // Accepted requests already reserve response space. If one is in
        // flight the instruction FIFO cannot be full, so response acceptance
        // need not depend on the decode/dispatch path of its oldest instruction.
        i_rsp_ready = !reset && request_count != 0;
        response_fire = i_rsp_valid && i_rsp_ready;
        queue_push = response_fire && !draining && !redirect_valid;

        reserved_slots = TOTAL_W'(queue_count) + TOTAL_W'(request_count);
        i_req_addr = next_pc;
        i_req_valid = !reset && !redirect_valid && !draining
                   && (request_count < OCW'(FETCH_OUTSTANDING) || response_fire)
                   && (reserved_slots < TOTAL_W'(FETCH_QUEUE_DEPTH) || instruction_fire);
        request_fire = i_req_valid && i_req_ready;
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            next_pc <= 32'b0;
            draining <= 1'b0;
            queue_head <= '0;
            queue_tail <= '0;
            queue_count <= '0;
            queue_error <= '0;
            request_head <= '0;
            request_tail <= '0;
            request_count <= '0;
        end else begin
            if (request_fire) begin
                request_pc[request_tail] <= next_pc;
                request_prediction[request_tail] <= predicted_next;
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
                next_pc <= redirect_pc;
                queue_head <= '0;
                queue_tail <= '0;
                queue_count <= '0;
                // A response consumed on the redirect edge belongs to the old
                // path too, including when it is the final outstanding one.
                draining <= request_count != 0
                         && !(response_fire && request_count == OCW'(1));
            end else begin
                if (draining && response_fire && request_count == OCW'(1))
                    draining <= 1'b0;
                if (queue_push) begin
                    queue_pc[queue_tail] <= response_pc;
                    queue_data[queue_tail] <= i_rsp_data;
                    queue_prediction[queue_tail] <= response_prediction;
                    queue_error[queue_tail] <= i_rsp_error || response_pc[1:0] != 0;
                    queue_tail <= next_queue(queue_tail);
                end
                if (instruction_fire)
                    queue_head <= next_queue(queue_head);
                case ({queue_push, instruction_fire})
                    2'b10: queue_count <= queue_count + 1'b1;
                    2'b01: queue_count <= queue_count - 1'b1;
                    default: ;
                endcase
            end

        end
    end

    // Train committed control flow through a registered bundle. One-hot row
    // enables cut the ROB-head-to-BTB path and eliminate dynamic training reads.
    // A redirect must not cancel this already-committed update.
    always_ff @(posedge clock) begin
        train_pc <= update_pc;
        train_target <= update_target;
        train_conditional <= update_conditional;
        train_taken <= update_taken;
    end
    generate
        for (genvar b = 0; b < BTB_ENTRIES; b = b + 1) begin : predictor_rows
            always_ff @(posedge clock) begin
                if (reset) begin
                    train_enable[b] <= 1'b0;
                    btb_valid[b] <= 1'b0;
                    btb_conditional[b] <= 1'b0;
                end else begin
                    train_enable[b] <= PREDICT_ENABLE != 0 && update_valid && update_index == BW'(b);
                    if (train_enable[b]) begin
                        btb_valid[b] <= 1'b1;
                        btb_conditional[b] <= train_conditional;
                    end
                end
                if (train_enable[b]) begin
                    btb_pc[b] <= train_pc;
                    btb_target[b] <= train_target;
                    if (!train_conditional)
                        btb_counter[b] <= 2'b11;
                    else if (btb_valid[b] && btb_pc[b] == train_pc && btb_conditional[b]) begin
                        if (train_taken && btb_counter[b] != 2'b11)
                            btb_counter[b] <= btb_counter[b] + 1'b1;
                        else if (!train_taken && btb_counter[b] != 2'b00)
                            btb_counter[b] <= btb_counter[b] - 1'b1;
                    end else btb_counter[b] <= train_taken ? 2'b10 : 2'b01;
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
        if (FETCH_QUEUE_DEPTH < 1 || FETCH_OUTSTANDING < 1 || BTB_ENTRIES < 1 || BTB_ENTRIES > 65536)
            $fatal(1, "Unsupported fetch frontend parameters");
    end
    always @(posedge clock) begin
        if (reset) begin
            stalled_request <= 1'b0;
            stalled_instruction <= 1'b0;
        end else begin
            assert (int'(queue_count) <= FETCH_QUEUE_DEPTH);
            assert (int'(request_count) <= FETCH_OUTSTANDING);
            assert (int'(reserved_slots) <= FETCH_QUEUE_DEPTH);
            if (stalled_request && !redirect_valid)
                assert (i_req_valid && i_req_addr == held_request_addr);
            if (stalled_instruction && !redirect_valid)
                assert (instruction_valid && instruction_pc == held_instruction_pc
                        && instruction_data == held_instruction_data
                        && instruction_predicted_pc == held_instruction_prediction
                        && instruction_error == held_instruction_error);
            if (draining) assert (!i_req_valid && queue_count == 0);
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
