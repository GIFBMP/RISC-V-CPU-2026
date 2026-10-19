// V7: ALU/LSU/MDU and ALU/branch selection lanes.
// Store addresses can resolve before their data; non-aliasing Loads may pass.
// Ready RAM Loads may enter the ordered memory queue at selection.
module cpu_core #(
    parameter integer FETCH_WIDTH = 1,
    parameter integer ROB_DEPTH = 16,
    parameter integer PRF_SIZE = 48,
    parameter integer IQ_DEPTH = 8,
    parameter integer LSQ_DEPTH = 8,
    parameter integer MEM_QUEUE_DEPTH = 8,
    parameter integer ISSUE_WIDTH = 1,
    parameter integer RENAME_WIDTH = 1,
    parameter integer COMMIT_WIDTH = 1,
    parameter integer FETCH_QUEUE_DEPTH = 8,
    parameter integer FETCH_OUTSTANDING = 4,
    parameter integer BTB_ENTRIES = 64,
    parameter integer BTB_INDEX_XOR = 0,
    parameter integer LOCAL_HISTORY_BITS = 0,
    parameter integer REDIRECT_OVERLAP = 0,
    parameter integer RESPONSE_BYPASS = 0,
    parameter integer REDIRECT_REQUEST = 0,
    parameter integer RAS_DEPTH = 0,
    parameter integer SELECT_LOAD = 1,
    parameter integer EXECUTE_REDIRECT = 1,
    parameter integer EARLY_FETCH = 1,
    parameter integer EARLY_RECOVERY = 1,
    parameter integer PARALLEL_COMPLETION = 1,
    parameter integer BRANCH_CHECKPOINTS = 4,
    parameter integer TRAIN_EXECUTE = 0,
    parameter integer LOAD_REQUEST_BYPASS = 0,
    parameter integer PARALLEL_STORE_ENQUEUE = 1,
    parameter integer PREDICT_ENABLE = 1,
    parameter integer TRACE = 0
) (
    input logic clock, reset,
    output logic i_req_valid,
    input logic i_req_ready,
    output logic [31:0] i_req_addr,
    input logic i_rsp_valid,
    output logic i_rsp_ready,
    input logic [31:0] i_rsp_data, i_rsp_data2,
    input logic i_rsp_error,
    output logic d_req_valid,
    input logic d_req_ready,
    output logic d_req_write,
    output logic [31:0] d_req_addr, d_req_wdata,
    output logic [3:0] d_req_wstrb,
    input logic d_rsp_valid,
    output logic d_rsp_ready,
    input logic [31:0] d_rsp_data,
    input logic d_rsp_error
);
    localparam integer CPW = BRANCH_CHECKPOINTS > 1 ? $clog2(BRANCH_CHECKPOINTS) : 1;
    localparam integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1;
    localparam integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1;
    localparam integer QW = (IQ_DEPTH > 1) ? $clog2(IQ_DEPTH) : 1;
    localparam integer CW = $clog2(ROB_DEPTH + 1);
    localparam integer LW = $clog2(LSQ_DEPTH + 1);
    localparam integer MW = MEM_QUEUE_DEPTH > 1 ? $clog2(MEM_QUEUE_DEPTH) : 1;
    localparam integer MCW = $clog2(MEM_QUEUE_DEPTH + 1);
    localparam [4:0] OP_AUIPC = 5'd11,
                     OP_JAL = 5'd12, OP_JALR = 5'd13, OP_BRANCH = 5'd14,
                     OP_LOAD = 5'd15, OP_STORE = 5'd16, OP_MULDIV = 5'd17;
    localparam [3:0] FAULT_NONE = 4'd0, FAULT_FETCH = 4'd1,
                     FAULT_ILLEGAL = 4'd2, FAULT_ALIGN = 4'd3,
                     FAULT_LOAD = 4'd4, FAULT_STORE = 4'd5;

    logic [PW-1:0] rat [0:31], rrat [0:31];
    logic [31:0] prf [0:PRF_SIZE-1];
    logic [PRF_SIZE-1:0] prf_ready, free_regs, committed_regs;

    logic [ROB_DEPTH-1:0] rob_valid, rob_done, rob_redirect, rob_store_done, rob_store_sent;
    logic [ROB_DEPTH-1:0] rob_is_store, rob_is_load, rob_taken;
    logic [ROB_DEPTH-1:0] rob_store_address_ready;
    logic [PW-1:0] rob_store_source [0:ROB_DEPTH-1];
    logic [1:0] rob_store_offset [0:ROB_DEPTH-1];
    logic [PW-1:0] issue_store_source;
    logic issue_store_ready, issue_store_value_ready, load_data_hazard;
    logic [31:0] issue_store_value;
    logic [RW-1:0] rob_head, rob_tail;
    logic [CW-1:0] rob_count;
    logic [LW-1:0] lsq_count;
    logic [31:0] rob_pc [0:ROB_DEPTH-1], rob_insn [0:ROB_DEPTH-1];
    logic [31:0] rob_target [0:ROB_DEPTH-1];
    logic [31:0] rob_branch_dest [0:ROB_DEPTH-1];
    logic [31:0] rob_addr [0:ROB_DEPTH-1], rob_data [0:ROB_DEPTH-1];
    logic [3:0] rob_strb [0:ROB_DEPTH-1], rob_fault [0:ROB_DEPTH-1];
    logic [4:0] rob_op [0:ROB_DEPTH-1], rob_rd [0:ROB_DEPTH-1];
    logic [PW-1:0] rob_dst [0:ROB_DEPTH-1], rob_old [0:ROB_DEPTH-1];

    logic [CPW-1:0] rob_checkpoint [0:ROB_DEPTH-1];
    logic [BRANCH_CHECKPOINTS-1:0] checkpoint_valid;
    logic [RW-1:0] checkpoint_owner [0:BRANCH_CHECKPOINTS-1];
    logic [PW-1:0] checkpoint_map [0:BRANCH_CHECKPOINTS*32-1];
    logic [PW-1:0] recovery_map [0:31];
    logic checkpoint_found, dec_control;
    logic [CPW-1:0] checkpoint_index, recovery_checkpoint;
    logic [RW-1:0] recovery_rob;
    logic [ROB_DEPTH-1:0] recovery_kill;
    logic [PRF_SIZE-1:0] recovery_free;
    logic [CW-1:0] recovery_count;
    logic [LW-1:0] recovery_lsq_count;
    logic [ROB_DEPTH-1:0] head_onehot, head2_onehot;
    logic [RW-1:0] head2_index, tail2_index;
    logic head2_done;
    logic [3:0] head2_fault;
    logic [4:0] head2_op, head2_rd;
    logic [PW-1:0] head2_dst, head2_old;
    logic [31:0] head2_pc, head2_insn, head2_branch_dest;
    logic head2_taken, head2_redirect;
    logic [31:0] head2_addr, head2_data;
    logic [3:0] head2_strb;
    logic head2_store_sent;
    logic store_select_second, selected_store_valid, selected_store_done, selected_store_sent;
    logic [3:0] selected_store_fault, selected_store_strb;
    logic [31:0] selected_store_addr, selected_store_data, selected_store_pc, selected_store_insn;
    logic [RW-1:0] selected_store_rob;
    assign head2_onehot = {head_onehot[ROB_DEPTH-2:0], head_onehot[ROB_DEPTH-1]};
    assign head2_index = next_rob(rob_head);
    assign tail2_index = next_rob(rob_tail);
    always_comb begin
        head2_done = 0; head2_fault = 0; head2_op = 0; head2_rd = 0;
        head2_dst = 0; head2_old = 0; head2_pc = 0; head2_insn = 0;
        head2_branch_dest = 0; head2_taken = 0; head2_redirect = 0;
        head2_addr = 0; head2_data = 0; head2_strb = 0; head2_store_sent = 0;
        for (integer r = 0; r < ROB_DEPTH; r = r + 1) begin
            head2_done |= rob_done[r] && head2_onehot[r];
            head2_fault |= rob_fault[r] & {4{head2_onehot[r]}};
            head2_op |= rob_op[r] & {5{head2_onehot[r]}};
            head2_rd |= rob_rd[r] & {5{head2_onehot[r]}};
            head2_dst |= rob_dst[r] & {PW{head2_onehot[r]}};
            head2_old |= rob_old[r] & {PW{head2_onehot[r]}};
            head2_pc |= rob_pc[r] & {32{head2_onehot[r]}};
            head2_insn |= rob_insn[r] & {32{head2_onehot[r]}};
            head2_branch_dest |= rob_branch_dest[r] & {32{head2_onehot[r]}};
            head2_taken |= rob_taken[r] && head2_onehot[r];
            head2_redirect |= rob_redirect[r] && head2_onehot[r];
            head2_addr |= rob_addr[r] & {32{head2_onehot[r]}};
            head2_data |= rob_data[r] & {32{head2_onehot[r]}};
            head2_strb |= rob_strb[r] & {4{head2_onehot[r]}};
            head2_store_sent |= rob_store_sent[r] && head2_onehot[r];
        end
    end
    logic [32-1:0] head_addr;
    logic [32-1:0] head_branch_dest;
    logic [32-1:0] head_data;
    logic head_done;
    logic [PW-1:0] head_dst;
    logic [4-1:0] head_fault;
    logic [32-1:0] head_insn;
    logic head_is_load;
    logic head_is_store;
    logic [PW-1:0] head_old;
    logic [5-1:0] head_op;
    logic [32-1:0] head_pc;
    logic [5-1:0] head_rd;
    logic head_redirect;
    logic head_store_done;
    logic head_store_sent;
    logic [4-1:0] head_strb;
    logic head_taken;
    logic [32-1:0] head_target;
    // Rotate the actual head token; wide commit reads do not repeatedly
    // decode the binary age pointer into a high-fanout row enable.
    always_comb begin
        head_addr = 0;
        head_branch_dest = 0;
        head_data = 0;
        head_done = 0;
        head_dst = 0;
        head_fault = 0;
        head_insn = 0;
        head_is_load = 0;
        head_is_store = 0;
        head_old = 0;
        head_op = 0;
        head_pc = 0;
        head_rd = 0;
        head_redirect = 0;
        head_store_done = 0;
        head_store_sent = 0;
        head_strb = 0;
        head_taken = 0;
        head_target = 0;
        for (integer r = 0; r < ROB_DEPTH; r = r + 1) begin
            head_addr = head_addr | (rob_addr[r] & {32{head_onehot[r]}});
            head_branch_dest = head_branch_dest | (rob_branch_dest[r] & {32{head_onehot[r]}});
            head_data = head_data | (rob_data[r] & {32{head_onehot[r]}});
            head_done = head_done | (rob_done[r] && head_onehot[r]);
            head_dst = head_dst | (rob_dst[r] & {PW{head_onehot[r]}});
            head_fault = head_fault | (rob_fault[r] & {4{head_onehot[r]}});
            head_insn = head_insn | (rob_insn[r] & {32{head_onehot[r]}});
            head_is_load = head_is_load | (rob_is_load[r] && head_onehot[r]);
            head_is_store = head_is_store | (rob_is_store[r] && head_onehot[r]);
            head_old = head_old | (rob_old[r] & {PW{head_onehot[r]}});
            head_op = head_op | (rob_op[r] & {5{head_onehot[r]}});
            head_pc = head_pc | (rob_pc[r] & {32{head_onehot[r]}});
            head_rd = head_rd | (rob_rd[r] & {5{head_onehot[r]}});
            head_redirect = head_redirect | (rob_redirect[r] && head_onehot[r]);
            head_store_done = head_store_done | (rob_store_done[r] && head_onehot[r]);
            head_store_sent = head_store_sent | (rob_store_sent[r] && head_onehot[r]);
            head_strb = head_strb | (rob_strb[r] & {4{head_onehot[r]}});
            head_taken = head_taken | (rob_taken[r] && head_onehot[r]);
            head_target = head_target | (rob_target[r] & {32{head_onehot[r]}});
        end
    end

    localparam integer IQ_PAYLOAD_BITS = 5 + PW + 3 + 4 + 32*3 + 1;
    logic [IQ_PAYLOAD_BITS-1:0] iq_payload [0:IQ_DEPTH-1];
    logic [IQ_PAYLOAD_BITS-1:0] selected_payload;
    logic [PW-1:0] selected_src1, selected_src2;
    logic [IQ_DEPTH-1:0] wb_match1, wb_match2, ex_match1, ex_match2;
    logic [IQ_DEPTH-1:0] second_match1, second_match2;
    logic [IQ_DEPTH-1:0] iq_older [0:IQ_DEPTH-1];
    logic [IQ_DEPTH-1:0] second_candidate, second_grant, integer_candidate, branch_candidate;
    logic [IQ_PAYLOAD_BITS-1:0] second_payload;
    logic [PW-1:0] second_src1, second_src2, second_dst;
    logic [RW-1:0] second_selected_rob, second_rob;
    logic [31:0] second_a, second_b, second_pc, second_imm, second_result;
    logic [4:0] second_op;
    logic second_use_imm, second_valid, second_select, second_wb;
    logic second_wb1, second_wb2, second_ex1, second_ex2, second_own1, second_own2;
    logic [2:0] second_funct3;
    logic [3:0] second_initial_fault, second_fault;
    logic [31:0] second_alu_result, second_target, second_branch_dest;
    logic second_control, second_taken;
    logic branch_valid, branch_redirect, branch_taken;
    logic [RW-1:0] branch_rob;
    logic [31:0] branch_pc, branch_target, branch_dest;
    logic [4:0] branch_op;
    logic [3:0] branch_fault;
    logic [31:0] second_prediction;
    logic selected_wb1, selected_wb2, selected_ex1, selected_ex2;
    logic [31:0] selected_a, selected_b, selected_pc, selected_imm, selected_prediction, selected_address;
    logic [4:0] selected_op;
    logic [PW-1:0] selected_dst;
    logic [2:0] selected_funct3;
    logic [3:0] selected_fault;
    logic selected_use_imm, selected_misaligned, selected_load_hazard, early_load, load_payload_early;
    logic [31:0] load_address;
    logic [RW-1:0] load_rob;
    logic [PW-1:0] load_dst;
    logic [2:0] load_funct3;
    logic [ROB_DEPTH-1:0] load_stores;
    logic [RW-1:0] selected_rob;
    logic [ROB_DEPTH-1:0] selected_stores;
    logic [IQ_DEPTH-1:0] iq_valid;
    logic [RW-1:0] iq_rob [0:IQ_DEPTH-1];
    logic [PW-1:0] iq_src1 [0:IQ_DEPTH-1], iq_src2 [0:IQ_DEPTH-1];

    logic [IQ_DEPTH-1:0] iq_ready1, iq_ready2;
    logic [1:0] iq_kind [0:IQ_DEPTH-1]; // 0: ordinary, 1: load, 2: MDU
    logic [ROB_DEPTH-1:0] iq_stores [0:IQ_DEPTH-1];
    logic [ROB_DEPTH-1:0] retiring_store;
    logic [31:0] fetch_buffer_pc, fetch_buffer_insn, fetch_predicted;
    logic fetch_buffer_valid, fetch_buffer_error;
    logic fetch2_valid, fetch2_error;
    logic [31:0] fetch2_pc, fetch2_insn, fetch2_prediction;
    logic [4:0] dec2_op, dec2_rs1, dec2_rs2, dec2_rd;
    logic dec2_use_rs1, dec2_use_rs2, dec2_writes_rd, dec2_use_imm, dec2_illegal, dec2_has_dst;
    logic [31:0] dec2_imm;
    logic [2:0] dec2_funct3;
    logic dispatch2, commit2, commit2_register;
    logic dec2_memory, dec2_control;
    logic head_control, head2_control, retire_control_second;
    logic free2_found, iq_free2_found, dec2_dependency1, dec2_dependency2;
    logic [PW-1:0] free2_index, dispatch2_src1, dispatch2_src2, dispatch2_old;
    logic [QW-1:0] iq_free2_index;
    decoder decode2 (
        .instruction(fetch2_insn), .op(dec2_op), .rs1(dec2_rs1), .rs2(dec2_rs2), .rd(dec2_rd),
        .use_rs1(dec2_use_rs1), .use_rs2(dec2_use_rs2), .writes_rd(dec2_writes_rd),
        .use_imm(dec2_use_imm), .immediate(dec2_imm), .funct3(dec2_funct3), .illegal(dec2_illegal)
    );
    logic halted, recovery_pending;
    logic early_pending, early_pulse, recovery_prepared;
    logic [RW-1:0] early_rob;
    logic [31:0] early_target;
    logic early_detect;
    logic [31:0] recovery_pc;

    logic [4:0] dec_op, dec_rs1, dec_rs2, dec_rd;
    logic dec_use_rs1, dec_use_rs2, dec_writes_rd, dec_use_imm, dec_illegal;
    logic [31:0] dec_imm;
    logic [2:0] dec_funct3;
    decoder decode (
        .instruction(fetch_buffer_insn), .op(dec_op),
        .rs1(dec_rs1), .rs2(dec_rs2), .rd(dec_rd),
        .use_rs1(dec_use_rs1), .use_rs2(dec_use_rs2), .writes_rd(dec_writes_rd),
        .use_imm(dec_use_imm), .immediate(dec_imm),
        .funct3(dec_funct3), .illegal(dec_illegal)
    );

    // Ordered memory descriptors outlive ROB allocations, including killed
    // requests. Send and response pointers advance independently; no finite
    // generation tag can alias a late response after a branch recovery.
    logic [MW-1:0] mq_head, mq_send, mq_tail;
    logic [MW-1:0] mq_store_tail;
    logic [1:0] mem_enqueue_count;
    logic [MCW-1:0] mq_count, mq_unsent;
    logic [MEM_QUEUE_DEPTH-1:0] mq_valid, mq_killed, mq_write, mq_committed;
    logic [31:0] mq_addr [0:MEM_QUEUE_DEPTH-1], mq_data [0:MEM_QUEUE_DEPTH-1];
    logic [31:0] mq_forward [0:MEM_QUEUE_DEPTH-1];
    logic [3:0] mq_strb [0:MEM_QUEUE_DEPTH-1], mq_mask [0:MEM_QUEUE_DEPTH-1];
    logic [1:0] mq_offset [0:MEM_QUEUE_DEPTH-1];
    logic [2:0] mq_funct3 [0:MEM_QUEUE_DEPTH-1];
    logic [RW-1:0] mq_rob [0:MEM_QUEUE_DEPTH-1];
    logic [PW-1:0] mq_dst [0:MEM_QUEUE_DEPTH-1];
    wire mem_busy = mq_count != 0;
    wire mem_sent = mq_count > mq_unsent;
    wire mem_killed = mq_killed[mq_head];
    wire mem_write = mq_write[mq_head];
    wire [RW-1:0] mem_rob = mq_rob[mq_head];
    wire [PW-1:0] mem_dst = mq_dst[mq_head];
    logic load_request_bypass;
    logic mem_response, mem_completion_pending, load_completion, mem_space, mem_enqueue, load_enqueue, load_available;
    logic [31:0] load_shifted, load_value, load_merged;
    logic [ROB_DEPTH-1:0] issue_stores;
    logic [31:0] forward_data;
    logic [3:0] forward_mask;
    logic [ROB_DEPTH-1:0] forward_match [0:3], forward_grant [0:3];

    logic mdu_req_valid, mdu_req_available, mdu_result_pending, mdu_result_valid, mdu_result_ready;
    logic [31:0] mdu_result;
    logic [RW-1:0] mdu_rob;
    logic [PW-1:0] mdu_dst;

    logic commit_fire, commit_register, flush, store_start, store_bufferable, dispatch;
    logic dec_has_dst, dec_memory;
    logic free_found, iq_free_found;
    logic [PW-1:0] free_index;
    logic [QW-1:0] iq_free_index;
    logic [PW-1:0] dispatch_src1, dispatch_src2;
    logic [4:0] dispatch_op;

    logic issue_valid, ex_valid, select_fire, select_found, execute_slot_ready, execute_resources_ready;
    logic [IQ_DEPTH-1:0] candidate, grant;
    logic [PW-1:0] issue_dst;
    logic [2:0] issue_funct3;
    logic [3:0] issue_initial_fault;
    logic [31:0] issue_pc, issue_imm, issue_predicted, issue_branch_dest;
    logic issue_use_imm;
    logic [QW-1:0] issue_index;
    logic [RW-1:0] issue_rob;
    logic [4:0] issue_op;
    logic [31:0] issue_a, issue_b, alu_lhs, alu_rhs, alu_result;
    logic [31:0] issue_address, issue_store_data, issue_target, issue_value;
    logic [3:0] issue_store_strb, issue_fault;
    logic issue_misaligned, issue_branch_taken, issue_redirect, issue_simple;

    logic wb_valid, wb_available, ex_wb_valid, ex_wb_available;
    logic [RW-1:0] wb_rob;
    logic [PW-1:0] wb_dst;
    logic [31:0] wb_value;
    logic [3:0] wb_fault;
    function automatic [RW-1:0] next_rob(input [RW-1:0] index);
        next_rob = (index == RW'(ROB_DEPTH-1)) ? '0 : index + 1'b1;
    endfunction

    function automatic older(input [RW-1:0] a, b, head);
        if ((a >= head) != (b >= head)) older = a >= head;
        else older = a < b;
    endfunction

    assign head_control = head_op == OP_BRANCH || head_op == OP_JAL || head_op == OP_JALR;
    assign head2_control = head2_op == OP_BRANCH || head2_op == OP_JAL || head2_op == OP_JALR;
    assign retire_control_second = commit2 && head2_control;
    localparam bit DIRECT_EXECUTE_REDIRECT = EXECUTE_REDIRECT != 0 && EARLY_RECOVERY != 0;
    localparam bit TRAIN_EARLY = TRAIN_EXECUTE != 0 && RAS_DEPTH == 0;
    fetch_frontend #(
        .DECODE_WIDTH(RENAME_WIDTH), .FETCH_WIDTH(FETCH_WIDTH),
        .FETCH_QUEUE_DEPTH(FETCH_QUEUE_DEPTH), .FETCH_OUTSTANDING(FETCH_OUTSTANDING),
        .BTB_ENTRIES(BTB_ENTRIES), .BTB_INDEX_XOR(BTB_INDEX_XOR), .LOCAL_HISTORY_BITS(LOCAL_HISTORY_BITS),
        .REDIRECT_OVERLAP(REDIRECT_OVERLAP), .RESPONSE_BYPASS(RESPONSE_BYPASS), .REDIRECT_REQUEST(REDIRECT_REQUEST), .RAS_DEPTH(RAS_DEPTH), .PREDICT_ENABLE(PREDICT_ENABLE)
    ) frontend (
        .clock(clock), .reset(reset),
        .redirect_valid((DIRECT_EXECUTE_REDIRECT && early_detect) || early_pulse || (flush && !recovery_prepared)),
        .redirect_pc(DIRECT_EXECUTE_REDIRECT && early_detect ? branch_target
            : flush && !recovery_prepared ? recovery_pc : early_target),
        .instruction_valid(fetch_buffer_valid), .instruction_ready(dispatch),
        .instruction2_valid(fetch2_valid), .instruction2_ready(dispatch2),
        .instruction2_pc(fetch2_pc), .instruction2_data(fetch2_insn),
        .instruction2_predicted_pc(fetch2_prediction), .instruction2_error(fetch2_error),
        .instruction_pc(fetch_buffer_pc), .instruction_data(fetch_buffer_insn),
        .instruction_predicted_pc(fetch_predicted), .instruction_error(fetch_buffer_error),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_data2(i_rsp_data2), .i_rsp_error(i_rsp_error),
        .update_valid(TRAIN_EARLY ? branch_valid && branch_fault == FAULT_NONE
                     : (commit_fire && head_control) || retire_control_second),
        .update_pc(TRAIN_EARLY ? branch_pc : retire_control_second ? head2_pc : head_pc),
        .update_insn(TRAIN_EARLY ? rob_insn[branch_rob] : retire_control_second ? head2_insn : head_insn),
        .update_target(TRAIN_EARLY ? branch_dest : retire_control_second ? head2_branch_dest : head_branch_dest),
        .update_conditional(TRAIN_EARLY ? branch_op == OP_BRANCH : retire_control_second ? head2_op == OP_BRANCH : head_op == OP_BRANCH),
        .update_taken(TRAIN_EARLY ? branch_taken : retire_control_second ? head2_taken : head_taken)
    );

    generate
        if (ROB_DEPTH < 2 || PRF_SIZE < 33 || IQ_DEPTH < 1 || LSQ_DEPTH < 1
            || LSQ_DEPTH > ROB_DEPTH || (ISSUE_WIDTH != 1 && ISSUE_WIDTH != 2)
            || (RENAME_WIDTH != 1 && RENAME_WIDTH != 2) || (COMMIT_WIDTH != 1 && COMMIT_WIDTH != 2)
            || (FETCH_WIDTH != 1 && FETCH_WIDTH != 2) || MEM_QUEUE_DEPTH < 1 || BRANCH_CHECKPOINTS < 1) begin : invalid_parameters
            cpu_core_requires_valid_widths_and_queue_sizes invalid_configuration();
        end
    endgenerate

    function automatic [MW-1:0] next_mem(input [MW-1:0] index);
        next_mem = index == MW'(MEM_QUEUE_DEPTH-1) ? '0 : index + 1'b1;
    endfunction

    always_comb begin
        checkpoint_found = 0;
        checkpoint_index = 0;
        for (integer c = BRANCH_CHECKPOINTS-1; c >= 0; c = c - 1)
            if (!checkpoint_valid[c]) begin
                checkpoint_found = 1;
                checkpoint_index = CPW'(c);
            end
        dec_control = !fetch_buffer_error && !dec_illegal
                   && (dec_op == OP_BRANCH || dec_op == OP_JAL || dec_op == OP_JALR);
        recovery_kill = 0;
        recovery_free = free_regs;
        recovery_count = 0;
        recovery_lsq_count = 0;
        for (integer r = 0; r < ROB_DEPTH; r = r + 1) begin
            recovery_kill[r] = rob_valid[r] && older(recovery_rob, RW'(r), rob_head);
            if (recovery_kill[r] && rob_rd[r] != 0) recovery_free[rob_dst[r]] = 1;
            if (rob_valid[r] && !recovery_kill[r]) begin
                recovery_count = recovery_count + 1'b1;
                if (rob_is_load[r] || rob_is_store[r]) recovery_lsq_count = recovery_lsq_count + 1'b1;
            end
        end
        for (integer a = 0; a < 32; a = a + 1) begin
            recovery_map[a] = 0;
            for (integer c = 0; c < BRANCH_CHECKPOINTS; c = c + 1)
                recovery_map[a] |= checkpoint_map[c*32+a] & {PW{recovery_checkpoint == CPW'(c)}};
        end
    end
    generate
        for (genvar c = 0; c < BRANCH_CHECKPOINTS; c = c + 1) begin : checkpoints
            always_ff @(posedge clock) begin
                if (reset) checkpoint_valid[c] <= 0;
                else begin
                    if (flush && (EARLY_RECOVERY == 0 || recovery_kill[checkpoint_owner[c]]))
                        checkpoint_valid[c] <= 0;
                    if (commit_fire && (head_op == OP_BRANCH || head_op == OP_JAL || head_op == OP_JALR)
                        && rob_checkpoint[rob_head] == CPW'(c)) checkpoint_valid[c] <= 0;
                    if (retire_control_second && rob_checkpoint[head2_index] == CPW'(c))
                        checkpoint_valid[c] <= 0;
                    if (((dispatch && dec_control) || (dispatch2 && dec2_control)) && checkpoint_index == CPW'(c))
                        checkpoint_valid[c] <= 1;
                end
                if (!checkpoint_valid[c]) checkpoint_owner[c] <= dec2_control && !dec_control ? tail2_index : rob_tail;
            end
            for (genvar a = 0; a < 32; a = a + 1) begin : mappings
                always_ff @(posedge clock) if (!checkpoint_valid[c])
                    checkpoint_map[c*32+a] <= dec2_control && !dec_control && dec2_has_dst && dec2_rd == 5'(a)
                        ? free2_index : dec_has_dst && dec_rd == 5'(a) ? free_index : rat[a];
            end
        end
    endgenerate

    assign flush = recovery_pending;
    assign branch_valid = ISSUE_WIDTH == 2 ? second_wb && second_control
        : issue_valid && (issue_op == OP_BRANCH || issue_op == OP_JAL || issue_op == OP_JALR);
    assign branch_rob = ISSUE_WIDTH == 2 ? second_rob : issue_rob;
    assign branch_pc = ISSUE_WIDTH == 2 ? second_pc : issue_pc;
    assign branch_target = ISSUE_WIDTH == 2 ? second_target : issue_target;
    assign branch_dest = ISSUE_WIDTH == 2 ? second_branch_dest : issue_branch_dest;
    assign branch_op = ISSUE_WIDTH == 2 ? second_op : issue_op;
    assign branch_fault = ISSUE_WIDTH == 2 ? second_fault : issue_fault;
    assign branch_taken = ISSUE_WIDTH == 2 ? second_taken : issue_op != OP_BRANCH || issue_branch_taken;
    assign branch_redirect = ISSUE_WIDTH == 2 ? second_target != second_prediction : issue_redirect;
    assign early_detect = (EARLY_FETCH != 0 || EARLY_RECOVERY != 0) && branch_valid
        && branch_fault == FAULT_NONE && branch_redirect
        && !(rob_count != 0 && head_done && head_fault == FAULT_NONE && head_redirect)
        && (!early_pending || older(branch_rob, early_rob, rob_head));
    assign mem_space = mq_count < MCW'(MEM_QUEUE_DEPTH);
    assign load_available = early_load || (ex_valid && execute_resources_ready
                         && issue_op == OP_LOAD && issue_fault == FAULT_NONE);
    assign {selected_op, selected_dst, selected_funct3, selected_fault,
            selected_pc, selected_imm, selected_use_imm, selected_prediction} = selected_payload;
    assign selected_a = selected_wb1 ? wb_value : selected_ex1 ? issue_value
        : |(grant & second_match1) ? second_result : prf[selected_src1];
    assign selected_b = selected_wb2 ? wb_value : selected_ex2 ? issue_value
        : |(grant & second_match2) ? second_result : prf[selected_src2];
    // Carry-select address generation bounds the two serial additions on
    // an ALU-result-to-Load bypass path without adding a pipeline stage.
    logic [16:0] selected_address_low;
    logic [15:0] selected_address_high0, selected_address_high1;
    assign selected_address_low = {1'b0, selected_a[15:0]} + {1'b0, selected_imm[15:0]};
    assign selected_address_high0 = selected_a[31:16] + selected_imm[31:16];
    assign selected_address_high1 = selected_a[31:16] + selected_imm[31:16] + 16'd1;
    assign selected_address = {selected_address_low[16] ? selected_address_high1 : selected_address_high0,
                               selected_address_low[15:0]};
    assign selected_misaligned = (selected_funct3[1:0] == 2'b01 && selected_address[0])
        || (selected_funct3[1:0] == 2'b10 && selected_address[1:0] != 0);
    always_comb begin
        selected_load_hazard = 0;
        for (integer r = 0; r < ROB_DEPTH; r = r + 1)
            if (selected_stores[r] && rob_valid[r] && !rob_done[r]
                && rob_addr[r] == {selected_address[31:2],2'b0}) selected_load_hazard = 1;
    end
    assign early_load = SELECT_LOAD != 0 && select_fire && selected_op == OP_LOAD
        && selected_fault == FAULT_NONE && !selected_misaligned && selected_address[31:28] == 0
        && !selected_load_hazard && !(ex_valid && issue_op == OP_LOAD);
    // Payload preparation is independent of recovery and admission. A live
    // old EX Load always owns this path; otherwise a selected Load may prepare
    // its data while only early_load authorizes queue/cache acceptance.
    assign load_payload_early = SELECT_LOAD != 0 && selected_op == OP_LOAD
        && !(ex_valid && issue_op == OP_LOAD);
    assign load_address = load_payload_early ? selected_address : issue_address;
    assign load_rob = load_payload_early ? selected_rob : issue_rob;
    assign load_dst = load_payload_early ? selected_dst : issue_dst;
    assign load_funct3 = load_payload_early ? selected_funct3 : issue_funct3;
    assign load_stores = load_payload_early ? selected_stores : issue_stores;
    assign load_enqueue = load_available && !reset && !halted && !flush;
    assign mem_enqueue = load_enqueue || store_start;
    assign mem_enqueue_count = {1'b0, load_enqueue} + {1'b0, store_start};
    assign mq_store_tail = load_enqueue ? next_mem(mq_tail) : mq_tail;
    assign store_select_second = COMMIT_WIDTH == 2 && rob_count >= 2 && !head_is_store
        && head_done && head_fault == FAULT_NONE && !head_redirect
        && head2_op == OP_STORE && head2_done && head2_fault == FAULT_NONE && head2_addr[31:28] == 0;
    assign selected_store_valid = store_select_second || (rob_count != 0 && head_is_store);
    assign selected_store_done = store_select_second ? head2_done : head_done;
    assign selected_store_sent = store_select_second ? head2_store_sent : head_store_sent;
    assign selected_store_fault = store_select_second ? head2_fault : head_fault;
    assign selected_store_addr = store_select_second ? head2_addr : head_addr;
    assign selected_store_data = store_select_second ? head2_data : head_data;
    assign selected_store_strb = store_select_second ? head2_strb : head_strb;
    assign selected_store_rob = store_select_second ? head2_index : rob_head;
    assign selected_store_pc = store_select_second ? head2_pc : head_pc;
    assign selected_store_insn = store_select_second ? head2_insn : head_insn;
    assign store_bufferable = selected_store_addr[31:28] == 0;
    always_comb begin
        store_start = !reset && !halted && !flush && mem_space
                   && (!load_enqueue || (PARALLEL_STORE_ENQUEUE != 0 && store_bufferable
                       && mq_count < MCW'(MEM_QUEUE_DEPTH-1))) && rob_count != 0
                   && selected_store_valid && selected_store_done
                   && !selected_store_sent && selected_store_fault == FAULT_NONE;
        commit_fire = !reset && !halted && !flush && rob_count != 0 && head_done
                   && head_fault == FAULT_NONE
                   && (!head_is_store || head_store_done || (store_start && store_bufferable));
        // A destination register excludes Store, so architectural register
        // retirement does not depend on the Store enqueue arbitration.
        commit_register = !reset && !halted && !flush && rob_count != 0
                        && head_done && head_fault == FAULT_NONE && head_rd != 0;
        commit2 = COMMIT_WIDTH == 2 && commit_fire && rob_count >= 2 && !head_redirect
            && head2_done && head2_fault == FAULT_NONE
            && (head2_op <= OP_AUIPC || head2_op == OP_LOAD || head2_op == OP_MULDIV || head2_control
                || (head2_op == OP_STORE && store_select_second && store_start))
            && !head2_redirect && !(head_control && head2_control)
            && (!head_is_store || store_bufferable);
        commit2_register = commit2 && head2_rd != 0;
        retiring_store = (head_onehot & {ROB_DEPTH{commit_fire && head_is_store}})
            | (head2_onehot & {ROB_DEPTH{commit2 && head2_op == OP_STORE}});
        free_found = 1'b0;
        free_index = '0;
        for (integer p = PRF_SIZE-1; p >= 1; p = p - 1)
            if (free_regs[p]) begin
                free_found = 1'b1;
                free_index = PW'(p);
            end
        iq_free_found = 1'b0;
        iq_free_index = '0;
        for (integer q = IQ_DEPTH-1; q >= 0; q = q - 1)
            if (!iq_valid[q]) begin
                iq_free_found = 1'b1;
                iq_free_index = QW'(q);
            end
        dec_has_dst = dec_writes_rd && dec_rd != 0 && !dec_illegal && !fetch_buffer_error;
        dec_memory = !dec_illegal && !fetch_buffer_error
                  && (dec_op == OP_LOAD || dec_op == OP_STORE);
        dispatch_op = (fetch_buffer_error || dec_illegal) ? 5'd31 : dec_op;
        dispatch_src1 = dec_use_rs1 && !dec_illegal && !fetch_buffer_error ? rat[dec_rs1] : '0;
        dispatch_src2 = dec_use_rs2 && !dec_illegal && !fetch_buffer_error ? rat[dec_rs2] : '0;
        dispatch = !reset && !halted && !flush && !early_pending && fetch_buffer_valid
                && rob_count < CW'(ROB_DEPTH) && iq_free_found
                && (!dec_has_dst || free_found)
                && (!dec_memory || lsq_count < LW'(LSQ_DEPTH))
                && (EARLY_RECOVERY == 0 || !dec_control || checkpoint_found);
        free2_found = 0;
        free2_index = 0;
        for (integer p = PRF_SIZE-1; p >= 1; p = p - 1)
            if (free_regs[p] && (!dec_has_dst || free_index != PW'(p))) begin
                free2_found = 1;
                free2_index = PW'(p);
            end
        iq_free2_found = 0;
        iq_free2_index = 0;
        for (integer q = IQ_DEPTH-1; q >= 0; q = q - 1)
            if (!iq_valid[q] && iq_free_index != QW'(q)) begin
                iq_free2_found = 1;
                iq_free2_index = QW'(q);
            end
        dec2_control = dec2_op == OP_BRANCH || dec2_op == OP_JAL || dec2_op == OP_JALR;
        dec2_memory = dec2_op == OP_LOAD || dec2_op == OP_STORE;
        dec2_has_dst = dec2_writes_rd && dec2_rd != 0 && !dec2_illegal && !fetch2_error;
        dec2_dependency1 = dec2_use_rs1 && dec_has_dst && dec2_rs1 == dec_rd;
        dec2_dependency2 = dec2_use_rs2 && dec_has_dst && dec2_rs2 == dec_rd;
        dispatch2_src1 = !dec2_use_rs1 ? PW'(0) : dec2_dependency1 ? free_index : rat[dec2_rs1];
        dispatch2_src2 = !dec2_use_rs2 ? PW'(0) : dec2_dependency2 ? free_index : rat[dec2_rs2];
        dispatch2_old = dec_has_dst && dec_rd == dec2_rd ? free_index : rat[dec2_rd];
        dispatch2 = RENAME_WIDTH == 2 && dispatch && fetch2_valid && !fetch2_error && !dec2_illegal
            && !fetch_buffer_error && !dec_illegal
            && (dec2_op <= OP_AUIPC || dec2_memory || dec2_op == OP_MULDIV || dec2_control)
            && (!dec2_control || (!dec_control && (EARLY_RECOVERY == 0 || checkpoint_found)))
            && (!dec2_memory || lsq_count < LW'(LSQ_DEPTH) - LW'(dec_memory))
            && rob_count < CW'(ROB_DEPTH-1) && iq_free2_found && (!dec2_has_dst || free2_found);
    end

    always_comb begin
        // Uncached/MMIO is an ordering barrier: every preceding response must
        // have completed successfully before this request reaches the cache.
        // With no queued unsent request, a RAM Load can start its synchronous
        // cache lookup on the same edge that reserves its persistent context.
        // Backpressure falls back to the queue; MMIO keeps the ordered barrier.
        // A bypass is RAM-only, so its local admission already satisfies the
        // RAM-or-no-older-Store condition in execute_resources_ready. Derive
        // it directly instead of traversing that shared, wide payload select.
        load_request_bypass = LOAD_REQUEST_BYPASS != 0 && mq_unsent == 0
                            && load_available && mem_space && !reset && !halted && !flush
                            && load_address[31:28] == 0;
        d_req_valid = load_request_bypass || (!reset && mq_unsent != 0
            && (mq_addr[mq_send][31:28] == 0 || (mq_count == mq_unsent && !halted)));
        d_req_write = !load_request_bypass && mq_write[mq_send];
        d_req_addr = load_request_bypass ? {load_address[31:2], 2'b0} : mq_addr[mq_send];
        d_req_wdata = load_request_bypass ? 32'b0 : mq_data[mq_send];
        d_req_wstrb = load_request_bypass ? 4'b0 : mq_strb[mq_send];
        d_rsp_ready = !reset && !flush && mem_busy && mem_sent;
        mem_response = d_rsp_valid && d_rsp_ready;
        mem_completion_pending = d_rsp_valid && mem_busy && mem_sent && !mem_write && !mem_killed;
        load_completion = mem_response && !mem_write && !mem_killed && !flush;

        load_merged = d_rsp_data;
        for (integer b = 0; b < 4; b = b + 1)
            if (mq_mask[mq_head][b]) load_merged[b*8 +: 8] = mq_forward[mq_head][b*8 +: 8];
        load_shifted = load_merged >> {mq_offset[mq_head], 3'b000};
        case (mq_funct3[mq_head])
            3'b000: load_value = {{24{load_shifted[7]}}, load_shifted[7:0]};
            3'b001: load_value = {{16{load_shifted[15]}}, load_shifted[15:0]};
            3'b010: load_value = load_shifted;
            3'b100: load_value = {24'b0, load_shifted[7:0]};
            3'b101: load_value = {16'b0, load_shifted[15:0]};
            default: load_value = 32'b0;
        endcase
        mdu_result_ready = !reset && !halted && !flush && !load_completion;
    end

    // Readiness is broadcast into the IQ; each load snapshots older store
    // slots at rename. A retired store clears its bit before that slot is reused.
    always_comb begin
        candidate = '0;
        grant = '0;
        for (integer q = 0; q < IQ_DEPTH; q = q + 1) begin
            // Reuse local wakeup comparisons for operand bypass. Do not turn
            // the grant back into a binary register number and compare again.
            wb_match1[q] = wb_available && wb_dst == iq_src1[q];
            wb_match2[q] = wb_available && wb_dst == iq_src2[q];
            ex_match1[q] = ex_wb_available && issue_dst == iq_src1[q];
            ex_match2[q] = ex_wb_available && issue_dst == iq_src2[q];
            second_match1[q] = second_valid && second_dst != 0 && second_dst == iq_src1[q];
            second_match2[q] = second_valid && second_dst != 0 && second_dst == iq_src2[q];
            candidate[q] = iq_valid[q]
                && !(ex_valid && issue_op == OP_LOAD && iq_rob[q] == issue_rob)
                && (iq_ready1[q] || wb_match1[q] || ex_match1[q] || second_match1[q])
                && (iq_payload[q][IQ_PAYLOAD_BITS-1 -: 5] == OP_STORE
                    || iq_ready2[q] || wb_match2[q] || ex_match2[q] || second_match2[q]);
            if (iq_kind[q] == 1)
                // Select on the old context's response cycle. Operands enter
                // EX at that edge, after the LSU context has become free.
                candidate[q] = candidate[q] && !(|(iq_stores[q] & ~rob_store_address_ready)) && mem_space;
            if (iq_kind[q] == 2)
                candidate[q] = candidate[q] && mdu_req_available
                             && !(ex_valid && issue_op == OP_MULDIV);
        end
        for (integer q = 0; q < IQ_DEPTH; q = q + 1) begin
            integer_candidate[q] = ISSUE_WIDTH == 2 && candidate[q]
                && iq_payload[q][IQ_PAYLOAD_BITS-1 -: 5] <= OP_AUIPC;
            branch_candidate[q] = ISSUE_WIDTH == 2 && candidate[q]
                && (iq_payload[q][IQ_PAYLOAD_BITS-1 -: 5] == OP_BRANCH
                    || iq_payload[q][IQ_PAYLOAD_BITS-1 -: 5] == OP_JAL
                    || iq_payload[q][IQ_PAYLOAD_BITS-1 -: 5] == OP_JALR);
            if (integer_candidate[q] || branch_candidate[q]) candidate[q] = 0;
        end
        second_candidate = |branch_candidate ? branch_candidate : integer_candidate;
        // Pairwise age comparisons avoid a serial best-age priority chain.
        for (integer q = 0; q < IQ_DEPTH; q = q + 1) begin
            integer older_integer_count;
            older_integer_count = 0;
            for (integer k = 0; k < IQ_DEPTH; k = k + 1)
                if (integer_candidate[k] && iq_older[k][q])
                    older_integer_count = older_integer_count + 1;
            grant[q] = candidate[q];
            for (integer k = 0; k < IQ_DEPTH; k = k + 1)
                if (candidate[k] && iq_older[k][q]) grant[q] = 1'b0;
            // Fill the primary lane with the oldest integer when the branch lane
            // is occupied, otherwise take the second-oldest integer.
            if (ISSUE_WIDTH == 2 && !(|candidate) && integer_candidate[q]) begin
                grant[q] = older_integer_count == ((|branch_candidate) ? 0 : 1);
            end
        end
        selected_wb1 = wb_dst != 0 && |(grant & wb_match1);
        selected_wb2 = wb_dst != 0 && |(grant & wb_match2);
        selected_ex1 = issue_dst != 0 && |(grant & ex_match1);
        selected_ex2 = issue_dst != 0 && |(grant & ex_match2);
        selected_payload = '0;
        selected_src1 = 0;
        selected_src2 = 0;
        selected_rob = 0;
        selected_stores = 0;
        for (integer q = 0; q < IQ_DEPTH; q = q + 1) begin
            selected_payload |= iq_payload[q] & {IQ_PAYLOAD_BITS{grant[q]}};
            selected_src1 |= iq_src1[q] & {PW{grant[q]}};
            selected_src2 |= iq_src2[q] & {PW{grant[q]}};
            selected_rob |= iq_rob[q] & {RW{grant[q]}};
            selected_stores |= iq_stores[q] & {ROB_DEPTH{grant[q]}};
        end
        issue_index = '0;
        for (integer q = 0; q < IQ_DEPTH; q = q + 1)
            issue_index = issue_index | (QW'(q) & {QW{grant[q]}});
        select_found = |grant;
        select_fire = select_found && execute_slot_ready && !reset && !halted && !flush
                   && !(EARLY_RECOVERY != 0 && early_detect);
    end

    // Register operands and execution metadata to separate scheduling/PRF reads
    // from address calculation, ALU, completion arbitration and PRF writes.
    always_ff @(posedge clock) begin
        if (reset) ex_valid <= 1'b0;
        else if (flush) begin
            if (EARLY_RECOVERY == 0 || recovery_kill[issue_rob]) ex_valid <= 1'b0;
        end else if (execute_slot_ready) ex_valid <= select_fire && !early_load;
        // Only a live blocked EX must hold operands. Empty slots may sample
        // arbitrary candidates; ex_valid alone determines their relevance.
        issue_stores <= issue_stores & ~retiring_store & ~(flush ? recovery_kill : {ROB_DEPTH{1'b0}});
        if (!flush && execute_slot_ready) begin
            issue_stores <= selected_stores & ~retiring_store;
            issue_rob <= selected_rob;
            issue_store_source <= selected_src2;
            issue_store_ready <= |(grant & iq_ready2) || selected_wb2 || selected_ex2 || |(grant & second_match2);
            {issue_op, issue_dst, issue_funct3, issue_initial_fault,
             issue_pc, issue_imm, issue_use_imm, issue_predicted} <= selected_payload;
            issue_a <= selected_a;
            issue_b <= selected_b;
        end
    end
    // The secondary selector serves control flow first, then integer work.
    // The primary selector serves LSU/MDU work, filling idle slots with integers.
    always_comb begin
        second_grant = 0;
        for (integer q = 0; q < IQ_DEPTH; q = q + 1) begin
            second_grant[q] = second_candidate[q];
            for (integer k = 0; k < IQ_DEPTH; k = k + 1)
                if (second_candidate[k] && iq_older[k][q]) second_grant[q] = 0;
        end
        second_payload = 0;
        second_src1 = 0;
        second_src2 = 0;
        second_selected_rob = 0;
        for (integer q = 0; q < IQ_DEPTH; q = q + 1) begin
            second_payload |= iq_payload[q] & {IQ_PAYLOAD_BITS{second_grant[q]}};
            second_src1 |= iq_src1[q] & {PW{second_grant[q]}};
            second_src2 |= iq_src2[q] & {PW{second_grant[q]}};
            second_selected_rob |= iq_rob[q] & {RW{second_grant[q]}};
        end
        second_wb1 = wb_dst != 0 && |(second_grant & wb_match1);
        second_wb2 = wb_dst != 0 && |(second_grant & wb_match2);
        second_ex1 = issue_dst != 0 && |(second_grant & ex_match1);
        second_ex2 = issue_dst != 0 && |(second_grant & ex_match2);
        second_own1 = |(second_grant & second_match1);
        second_own2 = |(second_grant & second_match2);
        second_select = |second_grant && !reset && !halted && !flush
                      && !(EARLY_RECOVERY != 0 && early_detect);
    end
    always_ff @(posedge clock) begin
        if (reset || flush) second_valid <= 0;
        else second_valid <= second_select;
        second_rob <= second_selected_rob;
        {second_op, second_dst, second_funct3, second_initial_fault,
         second_pc, second_imm, second_use_imm, second_prediction} <= second_payload;
        second_a <= second_wb1 ? wb_value : second_ex1 ? issue_value
                  : second_own1 ? second_result : prf[second_src1];
        second_b <= second_wb2 ? wb_value : second_ex2 ? issue_value
                  : second_own2 ? second_result : prf[second_src2];
    end
    alu second_alu (.op(second_op), .lhs(second_op == OP_AUIPC ? second_pc : second_a),
        .rhs(second_use_imm ? second_imm : second_b), .result(second_alu_result));
    always_comb begin
        second_control = second_op == OP_BRANCH || second_op == OP_JAL || second_op == OP_JALR;
        second_taken = second_op != OP_BRANCH;
        if (second_op == OP_BRANCH) begin
            case (second_funct3)
                3'b000: second_taken = second_a == second_b;
                3'b001: second_taken = second_a != second_b;
                3'b100: second_taken = $signed(second_a) < $signed(second_b);
                3'b101: second_taken = $signed(second_a) >= $signed(second_b);
                3'b110: second_taken = second_a < second_b;
                3'b111: second_taken = second_a >= second_b;
                default: second_taken = 0;
            endcase
        end
        second_branch_dest = second_op == OP_JALR
            ? (second_a + second_imm) & 32'hffff_fffe : second_pc + second_imm;
        second_target = second_control && second_taken ? second_branch_dest : second_pc + 32'd4;
        second_fault = second_initial_fault;
        if (second_initial_fault == FAULT_NONE && second_control && second_target[1:0] != 0)
            second_fault = FAULT_ALIGN;
        second_result = second_op == OP_JAL || second_op == OP_JALR ? second_pc + 32'd4 : second_alu_result;
    end
    assign second_wb = second_valid && !reset && !flush && !halted;

    assign alu_lhs = (issue_op == OP_AUIPC) ? issue_pc : issue_a;
    assign alu_rhs = issue_use_imm ? issue_imm : issue_b;
    alu integer_alu (.op(issue_op), .lhs(alu_lhs), .rhs(alu_rhs), .result(alu_result));

    always_comb begin
        issue_address = issue_a + issue_imm;
        issue_store_value_ready = issue_store_ready
            || (wb_available && wb_dst != 0 && wb_dst == issue_store_source)
            || (second_valid && second_dst != 0 && second_dst == issue_store_source);
        issue_store_value = issue_store_ready ? issue_b
            : (wb_available && wb_dst != 0 && wb_dst == issue_store_source) ? wb_value : second_result;
        issue_store_data = issue_store_value << {issue_address[1:0], 3'b000};
        load_data_hazard = 0;
        for (integer r = 0; r < ROB_DEPTH; r = r + 1)
            if (issue_stores[r] && rob_valid[r] && !rob_done[r]
                && rob_addr[r] == {issue_address[31:2], 2'b0}) load_data_hazard = 1;
        case (issue_funct3[1:0])
            2'b00: issue_store_strb = 4'b0001 << issue_address[1:0];
            2'b01: issue_store_strb = 4'b0011 << issue_address[1:0];
            default: issue_store_strb = 4'b1111;
        endcase
        issue_misaligned = (issue_funct3[1:0] == 2'b01 && issue_address[0])
                         || (issue_funct3[1:0] == 2'b10 && issue_address[1:0] != 0);
        case (issue_funct3)
            3'b000: issue_branch_taken = issue_a == issue_b;
            3'b001: issue_branch_taken = issue_a != issue_b;
            3'b100: issue_branch_taken = $signed(issue_a) < $signed(issue_b);
            3'b101: issue_branch_taken = $signed(issue_a) >= $signed(issue_b);
            3'b110: issue_branch_taken = issue_a < issue_b;
            3'b111: issue_branch_taken = issue_a >= issue_b;
            default: issue_branch_taken = 1'b0;
        endcase
        issue_target = issue_pc + 32'd4;
        if (issue_op == OP_JAL || (issue_op == OP_BRANCH && issue_branch_taken))
            issue_target = issue_pc + issue_imm;
        if (issue_op == OP_JALR)
            issue_target = (issue_a + issue_imm) & 32'hffff_fffe;
        issue_branch_dest = (issue_op == OP_JALR)
                          ? (issue_a + issue_imm) & 32'hffff_fffe : issue_pc + issue_imm;
        issue_redirect = issue_target != issue_predicted;
        issue_value = (issue_op == OP_JAL || issue_op == OP_JALR)
                    ? issue_pc + 32'd4 : alu_result;
        issue_fault = issue_initial_fault;
        if (issue_fault == FAULT_NONE) begin
            if ((issue_op == OP_LOAD || issue_op == OP_STORE) && issue_misaligned)
                issue_fault = FAULT_ALIGN;
            if ((issue_op == OP_JAL || issue_op == OP_JALR || issue_op == OP_BRANCH)
                && issue_target[1:0] != 0)
                issue_fault = FAULT_ALIGN;
        end
        // Branches/jumps always use ordinary writeback, including a target
        // alignment fault. Their 32-bit comparison need not control EX holding.
        // Only memory alignment/initial faults change a special unit into WB.
        issue_simple = (issue_op != OP_LOAD && issue_op != OP_STORE && issue_op != OP_MULDIV)
                    || issue_initial_fault != FAULT_NONE
                    || ((issue_op == OP_LOAD || issue_op == OP_STORE) && issue_misaligned);
        // Resource availability excludes global cancellation. Invalid payload
        // may be sampled during recovery; only issue/select handshakes authorize
        // effects. This keeps recovery out of candidate selection and EX data.
        execute_resources_ready = 1'b1;
        if (issue_simple) execute_resources_ready =
            PARALLEL_COMPLETION != 0 || (!mem_completion_pending && !mdu_result_pending);
        // Load enqueue wins arbitration with a committing Store. Admission
        // uses local resources; Store start checks the actual Load handshake,
        // avoiding a ROB-head dependency on the scheduling/EX critical path.
        else if (issue_op == OP_LOAD) execute_resources_ready = mem_space && !load_data_hazard
            && (issue_address[31:28] == 0 || !(|issue_stores));
        else if (issue_op == OP_MULDIV) execute_resources_ready = mdu_req_available;
        issue_valid = ex_valid && execute_resources_ready && !reset && !halted && !flush;
        // A blocked Load stays in its IQ entry and retries, allowing older
        // data producers to use EX instead of deadlocking behind the Load.
        execute_slot_ready = !ex_valid || execute_resources_ready || issue_op == OP_LOAD;
        mdu_req_valid = issue_valid && issue_op == OP_MULDIV && issue_fault == FAULT_NONE;
    end

    always_comb begin
        forward_data = 0;
        forward_mask = 0;
        for (integer b = 0; b < 4; b = b + 1) begin
            forward_match[b] = '0;
            forward_grant[b] = '0;
            for (integer r = 0; r < ROB_DEPTH; r = r + 1)
                forward_match[b][r] = load_stores[r] && rob_valid[r] && rob_done[r]
                    && rob_fault[r] == FAULT_NONE && rob_strb[r][b]
                    && rob_addr[r] == {load_address[31:2], 2'b0};
            for (integer r = 0; r < ROB_DEPTH; r = r + 1) begin
                forward_grant[b][r] = forward_match[b][r];
                for (integer k = 0; k < ROB_DEPTH; k = k + 1)
                    if (forward_match[b][k] && older(RW'(r), RW'(k), rob_head))
                        forward_grant[b][r] = 0;
                forward_data[b*8 +: 8] = forward_data[b*8 +: 8]
                    | (rob_data[r][b*8 +: 8] & {8{forward_grant[b][r]}});
            end
            forward_mask[b] = |forward_match[b];
        end
    end

    muldiv_unit mdu (
        .clock(clock), .reset(reset), .flush(flush && (EARLY_RECOVERY == 0 || recovery_kill[mdu_rob])),
        .req_valid(mdu_req_valid), .req_ready(),
        .req_available(mdu_req_available), .result_pending(mdu_result_pending),
        .operation(issue_funct3), .operand_a(issue_a), .operand_b(issue_b),
        .result_valid(mdu_result_valid), .result_ready(mdu_result_ready), .result(mdu_result)
    );

    always_comb begin
        // Data selection and prospective wakeup are local resource signals.
        // Cancellation gates only real writes/selects, not invalid EX payload.
        wb_available = 1'b0;
        wb_rob = PARALLEL_COMPLETION != 0 ? mdu_rob : issue_rob;
        wb_dst = PARALLEL_COMPLETION != 0 ? mdu_dst : issue_dst;
        wb_value = PARALLEL_COMPLETION != 0 ? mdu_result : issue_value;
        wb_fault = PARALLEL_COMPLETION != 0 ? FAULT_NONE : issue_fault;
        if (mem_completion_pending) begin
            wb_available = 1'b1;
            wb_rob = mem_rob;
            wb_dst = mem_dst;
            wb_value = load_value;
            wb_fault = d_rsp_error ? FAULT_LOAD : FAULT_NONE;
        end else if (mdu_result_pending) begin
            wb_available = 1'b1;
            wb_rob = mdu_rob;
            wb_dst = mdu_dst;
            wb_value = mdu_result;
            wb_fault = FAULT_NONE;
        end else if (PARALLEL_COMPLETION == 0 && ex_valid && execute_resources_ready && issue_simple) begin
            wb_available = 1'b1;
        end
        // Parallel mode gives ordinary EX a dedicated completion port. Its
        // wakeup and data no longer depend on the memory/MDU arbiter at all.
        // Distinct live destinations cannot alias in the renamed PRF.
        ex_wb_available = PARALLEL_COMPLETION != 0 && ex_valid && issue_simple;
        ex_wb_valid = ex_wb_available && !reset && !halted && !flush;
        wb_valid = wb_available && !reset && !halted && !flush;
    end

    // All wide metadata banks use per-entry enables. Reset/recovery only
    // clears their validity; it does not drive thousands of payload D inputs.
    generate
        for (genvar a = 0; a < 32; a = a + 1) begin : maps
            always_ff @(posedge clock) begin
                if (reset) begin
                    rat[a] <= PW'(a);
                    rrat[a] <= PW'(a);
                end else begin
                    if (flush) rat[a] <= EARLY_RECOVERY != 0 ? recovery_map[a] : rrat[a];
                    else begin
                        if (dispatch && dec_has_dst && dec_rd == 5'(a)) rat[a] <= free_index;
                        if (dispatch2 && dec2_has_dst && dec2_rd == 5'(a)) rat[a] <= free2_index;
                    end
                    if (commit_register && head_rd == 5'(a))
                        rrat[a] <= head_dst;
                    if (commit2_register && head2_rd == 5'(a)) rrat[a] <= head2_dst;
                end
            end
        end
        for (genvar p = 0; p < PRF_SIZE; p = p + 1) begin : physical_registers
            always_ff @(posedge clock) begin
                if (reset) prf[p] <= 32'b0;
                else begin
                    if (wb_valid && wb_dst == PW'(p) && p != 0) prf[p] <= wb_value;
                    if (ex_wb_valid && issue_dst == PW'(p) && p != 0) prf[p] <= issue_value;
                    if (second_wb && second_dst == PW'(p) && p != 0) prf[p] <= second_result;
                end
                if (reset) begin
                    committed_regs[p] <= p < 32;
                    free_regs[p] <= p >= 32;
                    prf_ready[p] <= 1'b1;
                end else begin
                    if (commit_register) begin
                        if (head_old == PW'(p)) committed_regs[p] <= 1'b0;
                        if (head_dst == PW'(p)) committed_regs[p] <= 1'b1;
                    end
                    if (commit2_register) begin
                        if (head2_old == PW'(p)) committed_regs[p] <= 1'b0;
                        if (head2_dst == PW'(p)) committed_regs[p] <= 1'b1;
                    end
                    if (flush) begin
                        free_regs[p] <= EARLY_RECOVERY != 0 ? recovery_free[p] : !committed_regs[p];
                        if (EARLY_RECOVERY == 0) prf_ready[p] <= 1'b1;
                    end else begin
                        if (commit_register && head_old == PW'(p))
                            free_regs[p] <= 1'b1;
                        if (commit2_register && head2_old == PW'(p)) free_regs[p] <= 1'b1;
                        if (dispatch2 && dec2_has_dst && free2_index == PW'(p)) begin
                            free_regs[p] <= 1'b0;
                            prf_ready[p] <= 1'b0;
                        end
                        if (dispatch && dec_has_dst && free_index == PW'(p)) begin
                            free_regs[p] <= 1'b0;
                            prf_ready[p] <= 1'b0;
                        end
                        if (wb_valid && wb_dst == PW'(p) && p != 0) prf_ready[p] <= 1'b1;
                        if (ex_wb_valid && issue_dst == PW'(p) && p != 0) prf_ready[p] <= 1'b1;
                        if (second_wb && second_dst == PW'(p) && p != 0) prf_ready[p] <= 1'b1;
                    end
                end
            end
        end
        for (genvar r = 0; r < ROB_DEPTH; r = r + 1) begin : reorder_entries
            wire allocate1 = dispatch && rob_tail == RW'(r);
            wire allocate2 = dispatch2 && tail2_index == RW'(r);
            wire allocate = allocate1 || allocate2;
            // The tail slot is unallocated whenever the ROB is not full.
            // Prewrite its payload even while rename is stalled; validity is
            // still set exclusively by dispatch, and flush clears validity.
            wire prepare_payload = rob_count < CW'(ROB_DEPTH) && rob_tail == RW'(r);
            wire retire = (commit_fire && rob_head == RW'(r)) || (commit2 && head2_index == RW'(r));
            wire complete_main = wb_valid && wb_rob == RW'(r);
            wire complete_second = second_wb && second_rob == RW'(r);
            wire complete = complete_main || (ex_wb_valid && issue_rob == RW'(r)) || complete_second;
            wire execute = issue_valid && issue_rob == RW'(r);
            wire store_source_wb = wb_valid && wb_dst != 0 && wb_dst == rob_store_source[r];
            wire store_source_ex = ex_wb_valid && issue_dst != 0 && issue_dst == rob_store_source[r];
            wire store_source_second = second_wb && second_dst != 0 && second_dst == rob_store_source[r];
            wire store_data_capture = rob_valid[r] && rob_is_store[r] && rob_store_address_ready[r] && !rob_done[r]
                && (store_source_wb || store_source_ex || store_source_second);
            wire [31:0] captured_store_data = store_source_wb ? wb_value : store_source_ex ? issue_value : second_result;
            wire store_complete = mem_response && mem_write && !mq_committed[mq_head] && !mem_killed && mem_rob == RW'(r);
`ifndef SYNTHESIS
            always @(posedge clock) if (!reset && !halted && TRACE != 0) begin
                if (execute && issue_op == OP_STORE && issue_fault == FAULT_NONE) begin
                    $display("CPU_TRACE STORE_ADDR id=%0d cycle=%0d pc=%08x addr=%08x strb=%01x ready=%0d psrc=%0d",
                        trace_id[r], trace_cycle, rob_pc[r], {issue_address[31:2], 2'b0},
                        issue_store_strb, issue_store_value_ready, issue_store_source);
                    if (issue_store_value_ready)
                        $display("CPU_TRACE STORE_DATA id=%0d cycle=%0d pc=%08x data=%08x late=0 psrc=%0d",
                            trace_id[r], trace_cycle, rob_pc[r], issue_store_data, issue_store_source);
                end
                if (store_data_capture && !(flush && (EARLY_RECOVERY == 0 || recovery_kill[r])))
                    $display("CPU_TRACE STORE_DATA id=%0d cycle=%0d pc=%08x data=%08x late=1 psrc=%0d",
                        trace_id[r], trace_cycle, rob_pc[r], captured_store_data << {rob_store_offset[r], 3'b000},
                        rob_store_source[r]);
            end
`endif
            always_ff @(posedge clock) begin
                if (reset || (flush && (EARLY_RECOVERY == 0 || recovery_kill[r]))) begin
                    rob_valid[r] <= 1'b0;
                    rob_done[r] <= 1'b0;
                    rob_redirect[r] <= 1'b0;
                    rob_store_done[r] <= 1'b0;
                    rob_store_sent[r] <= 1'b0;
                    rob_is_store[r] <= 1'b0;
                    rob_is_load[r] <= 1'b0;
                    rob_store_address_ready[r] <= 0;
                end else begin
                    if (flush && EARLY_RECOVERY != 0 && recovery_rob == RW'(r)) rob_redirect[r] <= 0;
                    if (retire) begin
                        rob_store_address_ready[r] <= 0;
                        rob_valid[r] <= 1'b0;
                        rob_done[r] <= 1'b0;
                        rob_is_store[r] <= 1'b0;
                        rob_is_load[r] <= 1'b0;
                    end
                    if (allocate) begin
                        rob_store_address_ready[r] <= 0;
                        rob_valid[r] <= 1'b1;
                        rob_done[r] <= 1'b0;
                        rob_redirect[r] <= 1'b0;
                        rob_store_done[r] <= 1'b0;
                        rob_store_sent[r] <= 1'b0;
                        rob_is_store[r] <= (allocate1 && dispatch_op == OP_STORE) || (allocate2 && dec2_op == OP_STORE);
                        rob_is_load[r] <= (allocate1 && dispatch_op == OP_LOAD) || (allocate2 && dec2_op == OP_LOAD);
                    end
                    if (execute && issue_op == OP_STORE && issue_fault == FAULT_NONE) begin
                        rob_store_address_ready[r] <= 1;
                        rob_done[r] <= issue_store_value_ready;
                    end
                    if (store_data_capture) rob_done[r] <= 1;
                    if (execute && issue_simple) rob_redirect[r] <= issue_redirect && issue_fault == FAULT_NONE;
                    if (complete_second && second_control)
                        rob_redirect[r] <= second_target != second_prediction && second_fault == FAULT_NONE;
                    if (complete) rob_done[r] <= 1'b1;
                    if (store_start && selected_store_rob == RW'(r)) rob_store_sent[r] <= 1'b1;
                    if (store_complete) rob_store_done[r] <= 1'b1;
                end
                if (prepare_payload) begin
                    rob_checkpoint[r] <= checkpoint_index;
                    rob_pc[r] <= fetch_buffer_pc;
                    rob_insn[r] <= fetch_buffer_insn;
                    rob_op[r] <= dispatch_op;
                    rob_rd[r] <= dec_has_dst ? dec_rd : 5'b0;
                    rob_dst[r] <= dec_has_dst ? free_index : {PW{1'b0}};
                    rob_old[r] <= dec_has_dst ? rat[dec_rd] : {PW{1'b0}};
                    rob_fault[r] <= fetch_buffer_error ? FAULT_FETCH : dec_illegal ? FAULT_ILLEGAL : FAULT_NONE;
                end
                if (rob_count < CW'(ROB_DEPTH-1) && tail2_index == RW'(r) && RENAME_WIDTH == 2) begin
                    rob_checkpoint[r] <= checkpoint_index;
                    rob_pc[r] <= fetch2_pc;
                    rob_insn[r] <= fetch2_insn;
                    rob_op[r] <= dec2_op;
                    rob_rd[r] <= dec2_has_dst ? dec2_rd : 5'b0;
                    rob_dst[r] <= dec2_has_dst ? free2_index : PW'(0);
                    rob_old[r] <= dec2_has_dst ? dispatch2_old : PW'(0);
                    rob_fault[r] <= FAULT_NONE;
                end
                if (complete) rob_fault[r] <= complete_second ? second_fault : complete_main ? wb_fault : issue_fault;
                if (store_complete && d_rsp_error) rob_fault[r] <= FAULT_STORE;
                if (execute && issue_op == OP_STORE && issue_fault == FAULT_NONE) begin
                    rob_store_source[r] <= issue_store_source;
                    rob_store_offset[r] <= issue_address[1:0];
                    rob_addr[r] <= {issue_address[31:2], 2'b0};
                    rob_data[r] <= issue_store_data;
                    rob_strb[r] <= issue_store_strb;
                end
                if (execute && issue_simple) begin
                    rob_target[r] <= issue_target;
                    rob_branch_dest[r] <= issue_branch_dest;
                    rob_taken[r] <= issue_op != OP_BRANCH || issue_branch_taken;
                end
                if (store_data_capture)
                    rob_data[r] <= captured_store_data << {rob_store_offset[r], 3'b000};
                if (complete_second && second_control) begin
                    rob_target[r] <= second_target;
                    rob_branch_dest[r] <= second_branch_dest;
                    rob_taken[r] <= second_taken;
                end
            end
        end
        for (genvar q = 0; q < IQ_DEPTH; q = q + 1) begin : issue_entries
            wire allocate1 = dispatch && iq_free_index == QW'(q);
            wire allocate2 = dispatch2 && iq_free2_index == QW'(q);
            wire allocate = allocate1 || allocate2;
            always_ff @(posedge clock) begin
                if (reset || (flush && (EARLY_RECOVERY == 0 || recovery_kill[iq_rob[q]]))) iq_valid[q] <= 1'b0;
                else begin
                    if (select_fire && issue_index == QW'(q) && selected_op != OP_LOAD) iq_valid[q] <= 1'b0;
                    if (iq_valid[q] && load_enqueue && load_rob == iq_rob[q]) iq_valid[q] <= 0;
                    if (iq_valid[q] && issue_valid && issue_op == OP_LOAD && issue_fault != FAULT_NONE
                        && issue_rob == iq_rob[q]) iq_valid[q] <= 0;
                    if (second_select && second_grant[q]) iq_valid[q] <= 1'b0;
                    if (allocate) iq_valid[q] <= 1'b1;
                end
                iq_stores[q] <= iq_stores[q] & ~retiring_store & ~(flush ? recovery_kill : {ROB_DEPTH{1'b0}});
                if ((wb_valid && wb_dst == iq_src1[q]) || (ex_wb_valid && issue_dst == iq_src1[q]) || (second_wb && second_dst == iq_src1[q])) iq_ready1[q] <= 1'b1;
                if ((wb_valid && wb_dst == iq_src2[q]) || (ex_wb_valid && issue_dst == iq_src2[q]) || (second_wb && second_dst == iq_src2[q])) iq_ready2[q] <= 1'b1;
                for (integer k = 0; k < IQ_DEPTH; k = k + 1) begin
                    if (allocate2) iq_older[q][k] <= 0;
                    else if (allocate1) iq_older[q][k] <= dispatch2 && iq_free2_index == QW'(k);
                    else if ((dispatch && iq_free_index == QW'(k)) || (dispatch2 && iq_free2_index == QW'(k)))
                        iq_older[q][k] <= iq_valid[q];
                end
                // Invalid slots may prepare payload independently of global
                // rename/flush control; the chosen slot becomes valid on dispatch.
                if (!iq_valid[q]) begin
                    iq_rob[q] <= rob_tail;
                    iq_payload[q] <= {dispatch_op, dec_has_dst ? free_index : {PW{1'b0}},
                        dec_funct3, fetch_buffer_error ? FAULT_FETCH : dec_illegal ? FAULT_ILLEGAL : FAULT_NONE,
                        fetch_buffer_pc, dec_imm, dec_use_imm, fetch_predicted};
                    iq_src1[q] <= dispatch_src1;
                    iq_src2[q] <= dispatch_src2;
                    iq_ready1[q] <= prf_ready[dispatch_src1] || (wb_valid && wb_dst == dispatch_src1)
                                  || (ex_wb_valid && issue_dst == dispatch_src1) || (second_wb && second_dst == dispatch_src1);
                    iq_ready2[q] <= prf_ready[dispatch_src2] || (wb_valid && wb_dst == dispatch_src2)
                                  || (ex_wb_valid && issue_dst == dispatch_src2) || (second_wb && second_dst == dispatch_src2);
                    iq_kind[q] <= dispatch_op == OP_LOAD ? 2'd1 : dispatch_op == OP_MULDIV ? 2'd2 : 2'd0;
                    iq_stores[q] <= rob_is_store & ~retiring_store;
                    if (RENAME_WIDTH == 2 && iq_free2_index == QW'(q) && iq_free2_found) begin
                        iq_rob[q] <= tail2_index;
                        iq_payload[q] <= {dec2_op, dec2_has_dst ? free2_index : PW'(0),
                            dec2_funct3, FAULT_NONE, fetch2_pc, dec2_imm, dec2_use_imm, fetch2_prediction};
                        iq_src1[q] <= dispatch2_src1;
                        iq_src2[q] <= dispatch2_src2;
                        iq_ready1[q] <= !dec2_dependency1 && (prf_ready[dispatch2_src1]
                            || (wb_valid && wb_dst == dispatch2_src1) || (ex_wb_valid && issue_dst == dispatch2_src1)
                            || (second_wb && second_dst == dispatch2_src1));
                        iq_ready2[q] <= !dec2_dependency2 && (prf_ready[dispatch2_src2]
                            || (wb_valid && wb_dst == dispatch2_src2) || (ex_wb_valid && issue_dst == dispatch2_src2)
                            || (second_wb && second_dst == dispatch2_src2));
                        iq_kind[q] <= dec2_op == OP_LOAD ? 2'd1 : dec2_op == OP_MULDIV ? 2'd2 : 2'd0;
                        iq_stores[q] <= (rob_is_store & ~retiring_store)
                            | (({{(ROB_DEPTH-1){1'b0}}, 1'b1} << rob_tail)
                                & {ROB_DEPTH{dispatch_op == OP_STORE}});
                    end
                end
            end
        end
    endgenerate

    always_ff @(posedge clock) begin
        if (reset) begin
            rob_head <= '0;
            head_onehot <= {{(ROB_DEPTH-1){1'b0}}, 1'b1};
            rob_tail <= '0;
            rob_count <= '0;
            lsq_count <= '0;
            halted <= 1'b0;
            recovery_pending <= 1'b0;
            recovery_pc <= 32'b0;
            recovery_rob <= 0;
            recovery_checkpoint <= 0;
            early_pending <= 0;
            early_pulse <= 0;
            early_rob <= 0;
            early_target <= 0;
            recovery_prepared <= 0;
            mdu_rob <= '0;
            mdu_dst <= '0;
        end else begin
            early_pulse <= 0;
            if (early_detect) begin
                early_pending <= 1;
                early_pulse <= !DIRECT_EXECUTE_REDIRECT;
                early_rob <= branch_rob;
                early_target <= branch_target;
                if (EARLY_RECOVERY != 0) begin
                    recovery_pending <= 1;
                    recovery_pc <= branch_target;
                    recovery_rob <= branch_rob;
                    recovery_checkpoint <= rob_checkpoint[branch_rob];
                    recovery_prepared <= DIRECT_EXECUTE_REDIRECT;
                end
            end
            if (mem_response && mem_write && mq_committed[mq_head] && d_rsp_error)
                halted <= 1'b1;
            if (flush) begin
                if (EARLY_RECOVERY != 0) begin
                    rob_tail <= next_rob(recovery_rob);
                    rob_count <= recovery_count;
                    lsq_count <= recovery_lsq_count;
                end else begin
                    rob_head <= '0;
                    head_onehot <= {{(ROB_DEPTH-1){1'b0}}, 1'b1};
                    rob_tail <= '0;
                    rob_count <= '0;
                    lsq_count <= '0;
                end
                recovery_pending <= 1'b0;
                recovery_prepared <= 0;
                early_pending <= 0;
                early_pulse <= 0;
            end else if (!halted) begin
                if (!flush && rob_count != 0 && head_done && head_fault != FAULT_NONE)
                    halted <= 1'b1;
                rob_count <= rob_count + CW'(dispatch) + CW'(dispatch2) - CW'(commit_fire) - CW'(commit2);
                lsq_count <= lsq_count + LW'(dispatch && dec_memory)
                    + LW'(dispatch2 && dec2_memory)
                    - LW'(commit_fire && (head_is_load || head_is_store))
                    - LW'(commit2 && (head2_op == OP_LOAD || head2_op == OP_STORE));
                if (commit_fire) begin
                    rob_head <= commit2 ? next_rob(head2_index) : head2_index;
                    head_onehot <= commit2 ? {head2_onehot[ROB_DEPTH-2:0], head2_onehot[ROB_DEPTH-1]} : head2_onehot;
                    // This commit updates RRAT and committed_regs first. The
                    // following recovery cycle prevents any younger retirement.
                    if (head_redirect && EARLY_RECOVERY == 0) begin
                        recovery_pending <= 1'b1;
                        recovery_pc <= head_target;
                        recovery_prepared <= early_pending && early_rob == rob_head;
                    end
                end
                if (dispatch) rob_tail <= dispatch2 ? next_rob(tail2_index) : tail2_index;
                if (issue_valid && issue_op == OP_MULDIV && issue_fault == FAULT_NONE) begin
                    mdu_rob <= issue_rob;
                    mdu_dst <= issue_dst;
                end
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            mq_head <= 0;
            mq_send <= 0;
            mq_tail <= 0;
            mq_count <= 0;
            mq_unsent <= 0;
        end else begin
            if (mem_enqueue) mq_tail <= mem_enqueue_count == 2 ? next_mem(next_mem(mq_tail)) : next_mem(mq_tail);
            if (d_req_valid && d_req_ready) mq_send <= next_mem(mq_send);
            if (mem_response) mq_head <= next_mem(mq_head);
            mq_count <= mq_count + MCW'(mem_enqueue_count) - MCW'(mem_response);
            mq_unsent <= mq_unsent + MCW'(mem_enqueue_count) - MCW'(d_req_valid && d_req_ready);
        end
    end
    generate
        for (genvar m = 0; m < MEM_QUEUE_DEPTH; m = m + 1) begin : memory_descriptors
            always_ff @(posedge clock) begin
                if (reset) begin
                    mq_valid[m] <= 0;
                    mq_killed[m] <= 0;
                end else begin
                    if (mem_response && mq_head == MW'(m)) mq_valid[m] <= 0;
                    if (flush && mq_valid[m] && !mq_committed[m]
                        && (EARLY_RECOVERY == 0 || recovery_kill[mq_rob[m]])) mq_killed[m] <= 1;
                    if ((load_enqueue && mq_tail == MW'(m)) || (store_start && mq_store_tail == MW'(m))) begin
                        mq_valid[m] <= 1;
                        mq_killed[m] <= 0;
                    end
                end
                // The free tail may prepare payload before admission. Only
                // mem_enqueue sets valid; occupied descriptors never change.
                // Raw Load selection keeps recovery off the wide data mux.
                if (mem_space && mq_tail == MW'(m)) begin
                    mq_write[m] <= !load_available;
                    mq_committed[m] <= !load_available && store_bufferable;
                    mq_addr[m] <= !load_available ? selected_store_addr : {load_address[31:2], 2'b0};
                    mq_data[m] <= !load_available ? selected_store_data : 32'b0;
                    mq_strb[m] <= !load_available ? selected_store_strb : 4'b0;
                    mq_rob[m] <= !load_available ? selected_store_rob : load_rob;
                    mq_dst[m] <= !load_available ? PW'(0) : load_dst;
                    mq_offset[m] <= load_address[1:0];
                    mq_funct3[m] <= load_funct3;
                    mq_forward[m] <= forward_data;
                    mq_mask[m] <= !load_available ? 4'b0 : forward_mask;
                end
                // A second admission lane lets a ready RAM Store retire while
                // EX enqueues a Load. The Load stays first and snapshots the
                // retiring Store's forwarded bytes before its ROB slot is freed.
                // With two free slots, prepare the second payload independently
                // of the admission handshake; only mq_valid authorizes use.
                if (PARALLEL_STORE_ENQUEUE != 0 && mq_count < MCW'(MEM_QUEUE_DEPTH-1)
                    && next_mem(mq_tail) == MW'(m)) begin
                    mq_write[m] <= 1;
                    mq_committed[m] <= 1;
                    mq_addr[m] <= selected_store_addr;
                    mq_data[m] <= selected_store_data;
                    mq_strb[m] <= selected_store_strb;
                    mq_rob[m] <= selected_store_rob;
                    mq_dst[m] <= 0;
                    mq_mask[m] <= 0;
                end
            end
        end
    endgenerate

`ifndef SYNTHESIS
    // Debug-only identities never affect architectural execution or synthesis.
    logic [63:0] trace_cycle, trace_next_id, trace_retired;
    logic [63:0] trace_mq_id [0:MEM_QUEUE_DEPTH-1];
    logic [31:0] trace_mq_pc [0:MEM_QUEUE_DEPTH-1], trace_mq_insn [0:MEM_QUEUE_DEPTH-1];
    wire [63:0] trace_mem_id = trace_mq_id[mq_head];
    wire [31:0] trace_mem_pc = trace_mq_pc[mq_head];
    logic [31:0] trace_recovery_pc;
    logic [63:0] trace_recovery_id;
    logic [63:0] trace_id [0:ROB_DEPTH-1];
    integer t;
    initial begin
        if (ROB_DEPTH < 2 || PRF_SIZE < 33 || IQ_DEPTH < 1 || LSQ_DEPTH < 1
            || LSQ_DEPTH > ROB_DEPTH || (ISSUE_WIDTH != 1 && ISSUE_WIDTH != 2)
            || (RENAME_WIDTH != 1 && RENAME_WIDTH != 2) || (COMMIT_WIDTH != 1 && COMMIT_WIDTH != 2)
            || (FETCH_WIDTH != 1 && FETCH_WIDTH != 2) || MEM_QUEUE_DEPTH < 1 || BRANCH_CHECKPOINTS < 1)
            $fatal(1, "Unsupported core parameters");
    end
    always @(posedge clock) begin
        if (reset) begin
            trace_cycle <= 0;
            trace_next_id <= 0;
            trace_retired <= 0;
            trace_recovery_id <= 0;
            trace_recovery_pc <= 0;
            for (t = 0; t < ROB_DEPTH; t = t + 1) trace_id[t] <= 0;
        end else begin
            trace_cycle <= trace_cycle + 1;
            if (TRACE != 0 && trace_cycle == 0)
                $display("CPU_TRACE CONFIG id=0 cycle=0 pc=00000000 early_recovery=%0d dual_wb=%0d version=7 select_width=%0d rename_width=%0d commit_width=%0d checkpoints=%0d select_load=%0d execute_redirect=%0d",
                         EARLY_RECOVERY != 0, PARALLEL_COMPLETION != 0, ISSUE_WIDTH, RENAME_WIDTH,
                         COMMIT_WIDTH, BRANCH_CHECKPOINTS, SELECT_LOAD, EXECUTE_REDIRECT);
            if (dispatch) begin
                trace_id[rob_tail] <= trace_next_id;
                trace_next_id <= trace_next_id + 1;
                if (TRACE != 0)
                    $display("CPU_TRACE DISPATCH id=%0d cycle=%0d pc=%08x insn=%08x rd=%0d pdst=%0d slot=%0d",
                             trace_next_id, trace_cycle, fetch_buffer_pc, fetch_buffer_insn,
                             dec_has_dst ? dec_rd : 5'b0, dec_has_dst ? free_index : {PW{1'b0}}, rob_tail);
            end
            if (dispatch2) begin
                trace_id[tail2_index] <= trace_next_id + 1;
                trace_next_id <= trace_next_id + 2;
                if (TRACE != 0)
                    $display("CPU_TRACE DISPATCH id=%0d cycle=%0d pc=%08x insn=%08x rd=%0d pdst=%0d slot=%0d",
                        trace_next_id + 1, trace_cycle, fetch2_pc, fetch2_insn,
                        dec2_has_dst ? dec2_rd : 5'b0, dec2_has_dst ? free2_index : PW'(0), tail2_index);
            end
            if (TRACE != 0 && select_fire)
                $display("CPU_TRACE SELECT id=%0d cycle=%0d pc=%08x insn=%08x lane=0 fast=%0d",
                    trace_id[selected_rob], trace_cycle, selected_pc, rob_insn[selected_rob], early_load);
            if (TRACE != 0 && second_select)
                $display("CPU_TRACE SELECT id=%0d cycle=%0d pc=%08x insn=%08x lane=1 fast=0",
                    trace_id[second_selected_rob], trace_cycle, rob_pc[second_selected_rob], rob_insn[second_selected_rob]);
            if (TRACE != 0 && !halted && !flush && ex_valid && issue_op == OP_LOAD && !execute_resources_ready)
                $display("CPU_TRACE LOAD_RETRY id=%0d cycle=%0d pc=%08x hazard=%0d space=%0d",
                    trace_id[issue_rob], trace_cycle, issue_pc, load_data_hazard, mem_space);
            if (TRACE != 0 && flush && EARLY_RECOVERY != 0 && ex_valid && !recovery_kill[issue_rob])
                $display("CPU_TRACE EX_KEEP id=%0d cycle=%0d pc=%08x insn=%08x",
                    trace_id[issue_rob], trace_cycle, issue_pc, rob_insn[issue_rob]);
            if (TRACE != 0 && early_load)
                $display("CPU_TRACE ISSUE id=%0d cycle=%0d pc=%08x insn=%08x",
                    trace_id[selected_rob], trace_cycle, selected_pc, rob_insn[selected_rob]);
            if (TRACE != 0 && issue_valid)
                $display("CPU_TRACE ISSUE id=%0d cycle=%0d pc=%08x insn=%08x",
                         trace_id[issue_rob], trace_cycle, rob_pc[issue_rob], rob_insn[issue_rob]);
            if (TRACE != 0 && second_wb) begin
                $display("CPU_TRACE ISSUE id=%0d cycle=%0d pc=%08x insn=%08x", trace_id[second_rob], trace_cycle, second_pc, rob_insn[second_rob]);
                $display("CPU_TRACE COMPLETE id=%0d cycle=%0d pc=%08x insn=%08x", trace_id[second_rob], trace_cycle, second_pc, rob_insn[second_rob]);
                if (wb_valid) $display("CPU_TRACE WB_PAIR id=%0d cycle=%0d pc=%08x load_id=%0d ex_id=%0d memory=%0d",
                    trace_id[second_rob], trace_cycle, second_pc, trace_id[wb_rob], trace_id[second_rob],
                    mem_response && !mem_write && !mem_killed);
            end
            if (TRACE != 0 && early_detect)
                $display("CPU_TRACE EARLY_FETCH id=%0d cycle=%0d pc=%08x target=%08x prev_id=%0d override=%0d",
                         trace_id[branch_rob], trace_cycle, branch_pc, branch_target,
                         early_pending ? trace_id[early_rob] : 64'b0, early_pending);
            if (TRACE != 0 && EARLY_FETCH != 0 && branch_valid
                && branch_fault == FAULT_NONE && branch_redirect && commit_fire && head_redirect)
                $display("CPU_TRACE EARLY_BLOCK id=%0d cycle=%0d pc=%08x head_id=%0d",
                         trace_id[branch_rob], trace_cycle, branch_pc, trace_id[rob_head]);
            if (TRACE != 0 && !flush && !halted && ex_valid && issue_simple
                && !issue_valid && (load_completion || mdu_result_valid))
                $display("CPU_TRACE WB_STALL id=%0d cycle=%0d pc=%08x source=%0d",
                         trace_id[issue_rob], trace_cycle, issue_pc, load_completion ? 1 : 2);
            if (TRACE != 0 && dispatch &&
                ((wb_valid && wb_dst != 0 && (dispatch_src1 == wb_dst || dispatch_src2 == wb_dst)) ||
                 (ex_wb_valid && issue_dst != 0 && (dispatch_src1 == issue_dst || dispatch_src2 == issue_dst)) ||
                 (second_wb && second_dst != 0 && (dispatch_src1 == second_dst || dispatch_src2 == second_dst))))
                $display("CPU_TRACE RENAME_BYPASS id=%0d cycle=%0d pc=%08x source=%0d",
                    trace_next_id, trace_cycle, fetch_buffer_pc,
                    (((wb_valid && wb_dst != 0 && dispatch_src1 == wb_dst) ||
                      (ex_wb_valid && issue_dst != 0 && dispatch_src1 == issue_dst) ||
                      (second_wb && second_dst != 0 && dispatch_src1 == second_dst)) ? 1 : 0) +
                    (((wb_valid && wb_dst != 0 && dispatch_src2 == wb_dst) ||
                      (ex_wb_valid && issue_dst != 0 && dispatch_src2 == issue_dst) ||
                      (second_wb && second_dst != 0 && dispatch_src2 == second_dst)) ? 2 : 0));
            if (TRACE != 0 && dispatch2 &&
                ((wb_valid && wb_dst != 0 && (dispatch2_src1 == wb_dst || dispatch2_src2 == wb_dst)) ||
                 (ex_wb_valid && issue_dst != 0 && (dispatch2_src1 == issue_dst || dispatch2_src2 == issue_dst)) ||
                 (second_wb && second_dst != 0 && (dispatch2_src1 == second_dst || dispatch2_src2 == second_dst))))
                $display("CPU_TRACE RENAME_BYPASS id=%0d cycle=%0d pc=%08x source=%0d",
                    trace_next_id + 1, trace_cycle, fetch2_pc,
                    (((wb_valid && wb_dst != 0 && dispatch2_src1 == wb_dst) ||
                      (ex_wb_valid && issue_dst != 0 && dispatch2_src1 == issue_dst) ||
                      (second_wb && second_dst != 0 && dispatch2_src1 == second_dst)) ? 1 : 0) +
                    (((wb_valid && wb_dst != 0 && dispatch2_src2 == wb_dst) ||
                      (ex_wb_valid && issue_dst != 0 && dispatch2_src2 == issue_dst) ||
                      (second_wb && second_dst != 0 && dispatch2_src2 == second_dst)) ? 2 : 0));
            if (TRACE != 0 && d_req_valid && d_req_ready)
                $display("CPU_TRACE MEM_REQUEST id=%0d cycle=%0d pc=%08x write=%0d addr=%08x killed=%0d",
                         load_request_bypass ? trace_id[load_rob] : trace_mq_id[mq_send], trace_cycle,
                         load_request_bypass ? rob_pc[load_rob] : trace_mq_pc[mq_send],
                         d_req_write, d_req_addr, !load_request_bypass && mq_killed[mq_send]);
            if (TRACE != 0 && mem_response)
                $display("CPU_TRACE MEM_RESPONSE id=%0d cycle=%0d pc=%08x write=%0d killed=%0d",
                         trace_mem_id, trace_cycle, trace_mem_pc, mem_write, mem_killed || (flush && !mq_committed[mq_head]));
            if (TRACE != 0 && ((commit_fire && head_is_store) || (commit2 && head2_op == OP_STORE)))
                $display("CPU_TRACE STORE_RETIRE id=%0d cycle=%0d pc=%08x",
                         trace_id[selected_store_rob], trace_cycle, selected_store_pc);
            if (TRACE != 0 && wb_valid)
                $display("CPU_TRACE COMPLETE id=%0d cycle=%0d pc=%08x insn=%08x",
                         trace_id[wb_rob], trace_cycle, rob_pc[wb_rob], rob_insn[wb_rob]);
            if (TRACE != 0 && ex_wb_valid) begin
                $display("CPU_TRACE COMPLETE id=%0d cycle=%0d pc=%08x insn=%08x",
                         trace_id[issue_rob], trace_cycle, issue_pc, rob_insn[issue_rob]);
                if (wb_valid) $display("CPU_TRACE WB_PAIR id=%0d cycle=%0d pc=%08x load_id=%0d ex_id=%0d memory=%0d",
                         trace_id[issue_rob], trace_cycle, issue_pc, trace_id[wb_rob], trace_id[issue_rob],
                         mem_response && !mem_write && !mem_killed);
            end
            if (mem_enqueue) begin
                trace_mq_id[mq_tail] <= trace_id[load_enqueue ? load_rob : selected_store_rob];
                trace_mq_pc[mq_tail] <= rob_pc[load_enqueue ? load_rob : selected_store_rob];
                trace_mq_insn[mq_tail] <= rob_insn[load_enqueue ? load_rob : selected_store_rob];
                if (TRACE != 0 && load_enqueue)
                    $display("CPU_TRACE LOAD_QUEUE id=%0d cycle=%0d pc=%08x mask=%01x depth=%0d addr=%08x data=%08x fast=%0d",
                             trace_id[load_rob], trace_cycle, rob_pc[load_rob], forward_mask, mq_count,
                             {load_address[31:2], 2'b0}, forward_data, early_load);
            end
            if (load_enqueue && store_start) begin
                trace_mq_id[mq_store_tail] <= trace_id[selected_store_rob];
                trace_mq_pc[mq_store_tail] <= selected_store_pc;
                trace_mq_insn[mq_store_tail] <= selected_store_insn;
                if (TRACE != 0) $display("CPU_TRACE MEM_PAIR id=%0d cycle=%0d pc=%08x load_id=%0d store_id=%0d",
                    trace_id[selected_store_rob], trace_cycle, selected_store_pc, trace_id[load_rob], trace_id[selected_store_rob]);
            end
            if (EARLY_RECOVERY == 0 && commit_fire && head_redirect) begin
                trace_recovery_id <= trace_id[rob_head];
                trace_recovery_pc <= head_pc;
            end
            if (EARLY_RECOVERY != 0 && early_detect) begin
                trace_recovery_id <= trace_id[branch_rob];
                trace_recovery_pc <= branch_pc;
            end
            if (TRACE != 0 && flush)
                $display("CPU_TRACE FLUSH id=%0d cycle=%0d pc=%08x target=%08x load_pending=%0d prepared=%0d selective=%0d head_id=%0d kept=%0d killed=%0d",
                         trace_recovery_id, trace_cycle, trace_recovery_pc, recovery_pc,
                         mq_count != 0 && !(mq_count == 1 && mem_response), recovery_prepared, EARLY_RECOVERY != 0, trace_id[rob_head],
                         EARLY_RECOVERY != 0 ? recovery_count : 0,
                         EARLY_RECOVERY != 0 ? rob_count - recovery_count : rob_count);
            if (TRACE != 0 && flush && EARLY_RECOVERY != 0) begin
                if (mem_completion_pending && !recovery_kill[mem_rob])
                    $display("CPU_TRACE RECOVERY_HOLD id=%0d cycle=%0d pc=%08x source=1",
                             trace_mem_id, trace_cycle, trace_mem_pc);
                if (mdu_result_pending && !recovery_kill[mdu_rob])
                    $display("CPU_TRACE RECOVERY_HOLD id=%0d cycle=%0d pc=%08x source=2",
                             trace_id[mdu_rob], trace_cycle, rob_pc[mdu_rob]);
            end
            if (TRACE != 0 && flush && !mdu_req_available
                && (EARLY_RECOVERY == 0 || recovery_kill[mdu_rob]))
                $display("CPU_TRACE DROP_MDU id=%0d cycle=%0d pc=%08x",
                         trace_id[mdu_rob], trace_cycle, rob_pc[mdu_rob]);
            if (TRACE != 0 && mem_response && !mem_write && (mem_killed || flush))
                $display("CPU_TRACE DROP_LOAD id=%0d cycle=%0d pc=%08x",
                         trace_mem_id, trace_cycle, trace_mem_pc);
            // RAM stores retire into the persistent queue. MMIO remains at
            // the ROB head until its response; trace its irrevocable request
            // so exit MMIO is included before the harness ends at B.
            if (store_start && store_bufferable && !store_select_second) begin
                if (TRACE != 0)
                    $display("CPU_TRACE COMMIT seq=%0d id=%0d cycle=%0d pc=%08x insn=%08x rd=0 value=00000000 store=1 addr=%08x data=%08x strb=%01x",
                             trace_retired, trace_id[rob_head], trace_cycle,
                             head_pc, head_insn, head_addr, head_data, head_strb);
                trace_retired <= trace_retired + 1;
            end else if (d_req_valid && d_req_ready && d_req_write && !mq_committed[mq_send]) begin
                if (TRACE != 0)
                    $display("CPU_TRACE COMMIT seq=%0d id=%0d cycle=%0d pc=%08x insn=%08x rd=0 value=00000000 store=1 addr=%08x data=%08x strb=%01x",
                             trace_retired, trace_mq_id[mq_send], trace_cycle,
                             trace_mq_pc[mq_send], trace_mq_insn[mq_send], d_req_addr, d_req_wdata, d_req_wstrb);
                trace_retired <= trace_retired + 1;
            end else if (commit_fire && head_op != OP_STORE) begin
                if (TRACE != 0)
                    $display("CPU_TRACE COMMIT seq=%0d id=%0d cycle=%0d pc=%08x insn=%08x rd=%0d value=%08x store=0 addr=00000000 data=00000000 strb=0",
                             trace_retired, trace_id[rob_head], trace_cycle,
                             head_pc, head_insn, head_rd,
                             head_rd == 0 ? 32'b0 : prf[head_dst]);
                trace_retired <= trace_retired + 1;
            end
            if (commit2) begin
                if (TRACE != 0) begin
                    if (head2_op == OP_STORE)
                        $display("CPU_TRACE COMMIT seq=%0d id=%0d cycle=%0d pc=%08x insn=%08x rd=0 value=00000000 store=1 addr=%08x data=%08x strb=%01x",
                            trace_retired + 1, trace_id[head2_index], trace_cycle, head2_pc, head2_insn,
                            head2_addr, head2_data, head2_strb);
                    else
                        $display("CPU_TRACE COMMIT seq=%0d id=%0d cycle=%0d pc=%08x insn=%08x rd=%0d value=%08x store=0 addr=00000000 data=00000000 strb=0",
                            trace_retired + 1, trace_id[head2_index], trace_cycle, head2_pc, head2_insn,
                            head2_rd, head2_rd == 0 ? 32'b0 : prf[head2_dst]);
                end
                trace_retired <= trace_retired + 2;
            end
            if (!halted) begin
                if (dispatch2) begin
                    assert (dispatch && iq_free_index != iq_free2_index && rob_tail != tail2_index);
                    assert (!dec_has_dst || !dec2_has_dst || free_index != free2_index);
                end
                if (commit2) assert (commit_fire && rob_count >= 2 && (head2_op != OP_STORE || (store_start && store_select_second && store_bufferable)) && !head2_redirect && !(head_control && head2_control));
                assert ($onehot0(grant) && $onehot0(second_grant));
                if (second_wb) begin
                    assert (rob_valid[second_rob] && !rob_done[second_rob] && rob_dst[second_rob] == second_dst);
                    assert (!wb_valid || wb_rob != second_rob);
                    assert (!ex_wb_valid || issue_rob != second_rob);
                end
                if (flush && EARLY_RECOVERY != 0) begin
                    assert (checkpoint_valid[recovery_checkpoint]);
                    assert (checkpoint_owner[recovery_checkpoint] == recovery_rob);
                end
                assert (commit_register == (commit_fire && head_rd != 0));
                if (load_enqueue && store_start) begin
                    assert (PARALLEL_STORE_ENQUEUE != 0 && store_bufferable);
                    assert (mq_store_tail != mq_tail && !mq_valid[mq_store_tail]);
                end
                if (load_request_bypass) begin
                    assert (load_enqueue && mem_enqueue && mq_unsent == 0 && mq_send == mq_tail);
                    assert (!d_req_write && load_address[31:28] == 0);
                end
                if (mem_enqueue) assert (load_available == load_enqueue);
                if (mem_space) assert (!mq_valid[mq_tail]);
                assert (mq_count <= MCW'(MEM_QUEUE_DEPTH) && mq_unsent <= mq_count);
                for (integer q = 0; q < IQ_DEPTH; q = q + 1)
                    if (iq_valid[q] && iq_kind[q] == 1)
                        for (integer r = 0; r < ROB_DEPTH; r = r + 1)
                            if (rob_valid[r] && rob_is_store[r] && older(RW'(r), iq_rob[q], rob_head))
                                assert (iq_stores[q][r]);
                assert (head_onehot == ({{(ROB_DEPTH-1){1'b0}}, 1'b1} << rob_head));
                assert (rat[0] == 0 && rrat[0] == 0 && prf[0] == 0 && prf_ready[0] && !free_regs[0]);
                assert (int'(rob_count) <= ROB_DEPTH && int'(lsq_count) <= LSQ_DEPTH);
                if (early_load) assert (rob_valid[selected_rob] && !rob_done[selected_rob]);
                if (issue_valid) assert (rob_valid[issue_rob] && !rob_done[issue_rob]);
                if (wb_valid) assert (rob_valid[wb_rob] && rob_dst[wb_rob] == wb_dst);
                if (ex_wb_valid) begin
                    assert (rob_valid[issue_rob] && rob_dst[issue_rob] == issue_dst);
                    if (wb_valid) assert (wb_rob != issue_rob);
                    if (wb_valid) assert (wb_dst == 0 || issue_dst == 0 || wb_dst != issue_dst);
                end
                for (integer m = 0; m < MEM_QUEUE_DEPTH; m = m + 1)
                    if (flush && mq_valid[m] && !mq_committed[m]
                        && (EARLY_RECOVERY == 0 || recovery_kill[mq_rob[m]])) assert (!mq_write[m]);
                if (d_req_valid && d_req_write) begin
                    assert (!mq_killed[mq_send]);
                    if (!mq_committed[mq_send]) assert (mq_rob[mq_send] == rob_head);
                end
                if (mem_response && mem_write && mq_committed[mq_head] && d_rsp_error)
                    $fatal(1, "CPU fault=%0d pc=%08x instruction=%08x buffered_store=1",
                           FAULT_STORE, trace_mq_pc[mq_head], trace_mq_insn[mq_head]);
                if (!flush && rob_count != 0 && head_done && head_fault != FAULT_NONE)
                    $fatal(1, "CPU fault=%0d pc=%08x instruction=%08x",
                           head_fault, head_pc, head_insn);
            end
        end
    end
`endif
endmodule
