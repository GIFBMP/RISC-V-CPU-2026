// V3: decoupled predicted fetch, rename, oldest-ready select/read, registered
// execute and in-order retirement. The conservative LSQ forbids loads passing
// older stores; external stores are issued only from the committed ROB head.
module cpu_core #(
    parameter integer ROB_DEPTH = 16,
    parameter integer PRF_SIZE = 48,
    parameter integer IQ_DEPTH = 8,
    parameter integer LSQ_DEPTH = 8,
    parameter integer ISSUE_WIDTH = 1,
    parameter integer FETCH_QUEUE_DEPTH = 8,
    parameter integer FETCH_OUTSTANDING = 4,
    parameter integer BTB_ENTRIES = 64,
    parameter integer PREDICT_ENABLE = 1,
    parameter integer TRACE = 0
) (
    input logic clock, reset,
    output logic i_req_valid,
    input logic i_req_ready,
    output logic [31:0] i_req_addr,
    input logic i_rsp_valid,
    output logic i_rsp_ready,
    input logic [31:0] i_rsp_data,
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
    localparam integer RW = (ROB_DEPTH > 1) ? $clog2(ROB_DEPTH) : 1;
    localparam integer PW = (PRF_SIZE > 1) ? $clog2(PRF_SIZE) : 1;
    localparam integer QW = (IQ_DEPTH > 1) ? $clog2(IQ_DEPTH) : 1;
    localparam integer CW = $clog2(ROB_DEPTH + 1);
    localparam integer LW = $clog2(LSQ_DEPTH + 1);
    localparam [4:0] OP_AUIPC = 5'd11,
                     OP_JAL = 5'd12, OP_JALR = 5'd13, OP_BRANCH = 5'd14,
                     OP_LOAD = 5'd15, OP_STORE = 5'd16, OP_MULDIV = 5'd17;
    localparam [3:0] FAULT_NONE = 4'd0, FAULT_FETCH = 4'd1,
                     FAULT_ILLEGAL = 4'd2, FAULT_ALIGN = 4'd3,
                     FAULT_LOAD = 4'd4, FAULT_STORE = 4'd5;

    logic [PW-1:0] rat [0:31], rrat [0:31];
    logic [31:0] prf [0:PRF_SIZE-1];
    logic [PRF_SIZE-1:0] prf_ready, free_regs, committed_regs;

    logic [ROB_DEPTH-1:0] rob_valid, rob_done, rob_redirect, rob_store_done;
    logic [ROB_DEPTH-1:0] rob_is_store, rob_is_load, rob_taken;
    logic [RW-1:0] rob_head, rob_tail;
    logic [CW-1:0] rob_count;
    logic [LW-1:0] lsq_count;
    logic [31:0] rob_pc [0:ROB_DEPTH-1], rob_insn [0:ROB_DEPTH-1];
    logic [31:0] rob_imm [0:ROB_DEPTH-1], rob_target [0:ROB_DEPTH-1];
    logic [31:0] rob_predicted [0:ROB_DEPTH-1], rob_branch_dest [0:ROB_DEPTH-1];
    logic [31:0] rob_addr [0:ROB_DEPTH-1], rob_data [0:ROB_DEPTH-1];
    logic [3:0] rob_strb [0:ROB_DEPTH-1], rob_fault [0:ROB_DEPTH-1];
    logic [4:0] rob_op [0:ROB_DEPTH-1], rob_rd [0:ROB_DEPTH-1];
    logic [2:0] rob_funct3 [0:ROB_DEPTH-1];
    logic [PW-1:0] rob_dst [0:ROB_DEPTH-1], rob_old [0:ROB_DEPTH-1];
    logic [ROB_DEPTH-1:0] rob_use_imm;

    logic [IQ_DEPTH-1:0] iq_valid;
    logic [RW-1:0] iq_rob [0:IQ_DEPTH-1];
    logic [PW-1:0] iq_src1 [0:IQ_DEPTH-1], iq_src2 [0:IQ_DEPTH-1];

    logic [IQ_DEPTH-1:0] iq_ready1, iq_ready2;
    logic [1:0] iq_kind [0:IQ_DEPTH-1]; // 0: ordinary, 1: load, 2: MDU
    logic [ROB_DEPTH-1:0] iq_stores [0:IQ_DEPTH-1];
    logic [ROB_DEPTH-1:0] retiring_store;
    logic [31:0] fetch_buffer_pc, fetch_buffer_insn, fetch_predicted;
    logic fetch_buffer_valid, fetch_buffer_error;
    logic halted, recovery_pending;
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

    // One LSU context remains occupied until its response, including after a
    // flush. A killed response never addresses a reused ROB/PRF allocation.
    logic mem_busy, mem_sent, mem_killed, mem_write;
    logic [31:0] mem_addr, mem_data;
    logic [3:0] mem_strb;
    logic [1:0] mem_offset;
    logic [2:0] mem_funct3;
    logic [RW-1:0] mem_rob;
    logic [PW-1:0] mem_dst;
    logic mem_response, load_completion;
    logic [31:0] load_shifted, load_value;

    logic mdu_req_valid, mdu_req_available, mdu_result_pending, mdu_result_valid, mdu_result_ready;
    logic [31:0] mdu_result;
    logic [RW-1:0] mdu_rob;
    logic [PW-1:0] mdu_dst;

    logic commit_fire, flush, store_start, dispatch;
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

    logic wb_valid;
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

    fetch_frontend #(
        .FETCH_QUEUE_DEPTH(FETCH_QUEUE_DEPTH), .FETCH_OUTSTANDING(FETCH_OUTSTANDING),
        .BTB_ENTRIES(BTB_ENTRIES), .PREDICT_ENABLE(PREDICT_ENABLE)
    ) frontend (
        .clock(clock), .reset(reset), .redirect_valid(flush), .redirect_pc(recovery_pc),
        .instruction_valid(fetch_buffer_valid), .instruction_ready(dispatch),
        .instruction_pc(fetch_buffer_pc), .instruction_data(fetch_buffer_insn),
        .instruction_predicted_pc(fetch_predicted), .instruction_error(fetch_buffer_error),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(i_rsp_error),
        .update_valid(commit_fire && (rob_op[rob_head] == OP_BRANCH
                     || rob_op[rob_head] == OP_JAL || rob_op[rob_head] == OP_JALR)),
        .update_pc(rob_pc[rob_head]), .update_target(rob_branch_dest[rob_head]),
        .update_conditional(rob_op[rob_head] == OP_BRANCH), .update_taken(rob_taken[rob_head])
    );

    generate
        if (ROB_DEPTH < 2 || PRF_SIZE < 33 || IQ_DEPTH < 1 || LSQ_DEPTH < 1
            || LSQ_DEPTH > ROB_DEPTH || ISSUE_WIDTH != 1) begin : invalid_parameters
            cpu_core_requires_valid_single_issue_configuration invalid_configuration();
        end
    endgenerate

    assign flush = recovery_pending;
    always_comb begin
        commit_fire = !reset && !halted && !flush && rob_count != 0 && rob_done[rob_head]
                   && rob_fault[rob_head] == FAULT_NONE
                   && (!rob_is_store[rob_head] || rob_store_done[rob_head]);
        store_start = !reset && !halted && !flush && !mem_busy && rob_count != 0
                   && rob_is_store[rob_head] && rob_done[rob_head]
                   && !rob_store_done[rob_head] && rob_fault[rob_head] == FAULT_NONE;
        retiring_store = '0;
        if (commit_fire && rob_is_store[rob_head]) retiring_store[rob_head] = 1'b1;
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
        dispatch = !reset && !halted && !flush && fetch_buffer_valid
                && rob_count < CW'(ROB_DEPTH) && iq_free_found
                && (!dec_has_dst || free_found)
                && (!dec_memory || lsq_count < LW'(LSQ_DEPTH));
    end

    always_comb begin
        d_req_valid = !reset && mem_busy && !mem_sent;
        d_req_write = mem_write;
        d_req_addr = mem_addr;
        d_req_wdata = mem_data;
        d_req_wstrb = mem_strb;
        d_rsp_ready = !reset && mem_busy && mem_sent;
        mem_response = d_rsp_valid && d_rsp_ready;
        load_completion = mem_response && !mem_write && !mem_killed && !flush;

        load_shifted = d_rsp_data >> {mem_offset, 3'b000};
        case (mem_funct3)
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
            candidate[q] = iq_valid[q] && iq_ready1[q] && iq_ready2[q];
            if (iq_kind[q] == 1)
                // Select on the old context's response cycle. Operands enter
                // EX at that edge, after the LSU context has become free.
                candidate[q] = candidate[q] && !(|iq_stores[q]) && (!mem_busy || mem_response)
                             && !(ex_valid && issue_op == OP_LOAD);
            if (iq_kind[q] == 2)
                candidate[q] = candidate[q] && mdu_req_available
                             && !(ex_valid && issue_op == OP_MULDIV);
        end
        // Pairwise age comparisons avoid a serial best-age priority chain.
        for (integer q = 0; q < IQ_DEPTH; q = q + 1) begin
            grant[q] = candidate[q];
            for (integer k = 0; k < IQ_DEPTH; k = k + 1)
                if (candidate[k] && older(iq_rob[k], iq_rob[q], rob_head)) grant[q] = 1'b0;
        end
        issue_index = '0;
        for (integer q = 0; q < IQ_DEPTH; q = q + 1)
            issue_index = issue_index | (QW'(q) & {QW{grant[q]}});
        select_found = |grant;
        select_fire = select_found && execute_slot_ready && !reset && !halted && !flush;
    end

    // Register operands and execution metadata to separate scheduling/PRF reads
    // from address calculation, ALU, completion arbitration and PRF writes.
    always_ff @(posedge clock) begin
        if (reset || flush) ex_valid <= 1'b0;
        else if (execute_slot_ready) ex_valid <= select_fire;
        // Only a live blocked EX must hold operands. Empty slots may sample
        // arbitrary candidates; ex_valid alone determines their relevance.
        if (execute_slot_ready) begin
            issue_rob <= iq_rob[issue_index];
            issue_op <= rob_op[iq_rob[issue_index]];
            issue_dst <= rob_dst[iq_rob[issue_index]];
            issue_funct3 <= rob_funct3[iq_rob[issue_index]];
            issue_initial_fault <= rob_fault[iq_rob[issue_index]];
            issue_a <= prf[iq_src1[issue_index]];
            issue_b <= prf[iq_src2[issue_index]];
            issue_pc <= rob_pc[iq_rob[issue_index]];
            issue_imm <= rob_imm[iq_rob[issue_index]];
            issue_use_imm <= rob_use_imm[iq_rob[issue_index]];
            issue_predicted <= rob_predicted[iq_rob[issue_index]];
        end
    end
    assign alu_lhs = (issue_op == OP_AUIPC) ? issue_pc : issue_a;
    assign alu_rhs = issue_use_imm ? issue_imm : issue_b;
    alu integer_alu (.op(issue_op), .lhs(alu_lhs), .rhs(alu_rhs), .result(alu_result));

    always_comb begin
        issue_address = issue_a + issue_imm;
        issue_store_data = issue_b << {issue_address[1:0], 3'b000};
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
            !(mem_response && !mem_write && !mem_killed) && !mdu_result_pending;
        // An eligible Load has no older Store; a younger Store cannot be at
        // the ROB head. Thus store_start is mutually exclusive by age, without
        // putting ROB-head decode back on the scheduling/EX critical path.
        else if (issue_op == OP_LOAD) execute_resources_ready = !mem_busy;
        else if (issue_op == OP_MULDIV) execute_resources_ready = mdu_req_available;
        issue_valid = ex_valid && execute_resources_ready && !reset && !halted && !flush;
        execute_slot_ready = !ex_valid || execute_resources_ready;
        mdu_req_valid = issue_valid && issue_op == OP_MULDIV && issue_fault == FAULT_NONE;
    end

    muldiv_unit mdu (
        .clock(clock), .reset(reset), .flush(flush),
        .req_valid(mdu_req_valid), .req_ready(),
        .req_available(mdu_req_available), .result_pending(mdu_result_pending),
        .operation(issue_funct3), .operand_a(issue_a), .operand_b(issue_b),
        .result_valid(mdu_result_valid), .result_ready(mdu_result_ready), .result(mdu_result)
    );

    always_comb begin
        wb_valid = 1'b0;
        wb_rob = issue_rob;
        wb_dst = issue_dst;
        wb_value = issue_value;
        wb_fault = issue_fault;
        if (load_completion) begin
            wb_valid = 1'b1;
            wb_rob = mem_rob;
            wb_dst = mem_dst;
            wb_value = load_value;
            wb_fault = d_rsp_error ? FAULT_LOAD : FAULT_NONE;
        end else if (mdu_result_valid && mdu_result_ready) begin
            wb_valid = 1'b1;
            wb_rob = mdu_rob;
            wb_dst = mdu_dst;
            wb_value = mdu_result;
            wb_fault = FAULT_NONE;
        end else if (issue_valid && issue_simple) begin
            wb_valid = 1'b1;
        end
        wb_valid = wb_valid && !reset && !halted && !flush;
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
                    if (flush) rat[a] <= rrat[a];
                    else if (dispatch && dec_has_dst && dec_rd == 5'(a)) rat[a] <= free_index;
                    if (commit_fire && rob_rd[rob_head] != 0 && rob_rd[rob_head] == 5'(a))
                        rrat[a] <= rob_dst[rob_head];
                end
            end
        end
        for (genvar p = 0; p < PRF_SIZE; p = p + 1) begin : physical_registers
            always_ff @(posedge clock) begin
                if (reset) prf[p] <= 32'b0;
                else if (wb_valid && wb_dst == PW'(p) && p != 0) prf[p] <= wb_value;
                if (reset) begin
                    committed_regs[p] <= p < 32;
                    free_regs[p] <= p >= 32;
                    prf_ready[p] <= 1'b1;
                end else begin
                    if (commit_fire && rob_rd[rob_head] != 0) begin
                        if (rob_old[rob_head] == PW'(p)) committed_regs[p] <= 1'b0;
                        if (rob_dst[rob_head] == PW'(p)) committed_regs[p] <= 1'b1;
                    end
                    if (flush) begin
                        free_regs[p] <= !committed_regs[p];
                        prf_ready[p] <= 1'b1;
                    end else begin
                        if (commit_fire && rob_rd[rob_head] != 0 && rob_old[rob_head] == PW'(p))
                            free_regs[p] <= 1'b1;
                        if (dispatch && dec_has_dst && free_index == PW'(p)) begin
                            free_regs[p] <= 1'b0;
                            prf_ready[p] <= 1'b0;
                        end
                        if (wb_valid && wb_dst == PW'(p) && p != 0) prf_ready[p] <= 1'b1;
                    end
                end
            end
        end
        for (genvar r = 0; r < ROB_DEPTH; r = r + 1) begin : reorder_entries
            wire allocate = dispatch && rob_tail == RW'(r);
            // The tail slot is unallocated whenever the ROB is not full.
            // Prewrite its payload even while rename is stalled; validity is
            // still set exclusively by dispatch, and flush clears validity.
            wire prepare_payload = rob_count < CW'(ROB_DEPTH) && rob_tail == RW'(r);
            wire retire = commit_fire && rob_head == RW'(r);
            wire complete = wb_valid && wb_rob == RW'(r);
            wire execute = issue_valid && issue_rob == RW'(r);
            wire store_complete = mem_response && mem_write && !mem_killed && mem_rob == RW'(r);
            always_ff @(posedge clock) begin
                if (reset || flush) begin
                    rob_valid[r] <= 1'b0;
                    rob_done[r] <= 1'b0;
                    rob_redirect[r] <= 1'b0;
                    rob_store_done[r] <= 1'b0;
                    rob_is_store[r] <= 1'b0;
                    rob_is_load[r] <= 1'b0;
                end else begin
                    if (retire) begin
                        rob_valid[r] <= 1'b0;
                        rob_done[r] <= 1'b0;
                        rob_is_store[r] <= 1'b0;
                        rob_is_load[r] <= 1'b0;
                    end
                    if (allocate) begin
                        rob_valid[r] <= 1'b1;
                        rob_done[r] <= 1'b0;
                        rob_redirect[r] <= 1'b0;
                        rob_store_done[r] <= 1'b0;
                        rob_is_store[r] <= dispatch_op == OP_STORE;
                        rob_is_load[r] <= dispatch_op == OP_LOAD;
                    end
                    if (execute && issue_op == OP_STORE && issue_fault == FAULT_NONE) rob_done[r] <= 1'b1;
                    if (execute && issue_simple) rob_redirect[r] <= issue_redirect && issue_fault == FAULT_NONE;
                    if (complete) rob_done[r] <= 1'b1;
                    if (store_complete) rob_store_done[r] <= 1'b1;
                end
                if (prepare_payload) begin
                    rob_pc[r] <= fetch_buffer_pc;
                    rob_insn[r] <= fetch_buffer_insn;
                    rob_imm[r] <= dec_imm;
                    rob_op[r] <= dispatch_op;
                    rob_funct3[r] <= dec_funct3;
                    rob_use_imm[r] <= dec_use_imm;
                    rob_predicted[r] <= fetch_predicted;
                    rob_rd[r] <= dec_has_dst ? dec_rd : 5'b0;
                    rob_dst[r] <= dec_has_dst ? free_index : {PW{1'b0}};
                    rob_old[r] <= dec_has_dst ? rat[dec_rd] : {PW{1'b0}};
                    rob_fault[r] <= fetch_buffer_error ? FAULT_FETCH : dec_illegal ? FAULT_ILLEGAL : FAULT_NONE;
                end
                if (complete) rob_fault[r] <= wb_fault;
                if (store_complete && d_rsp_error) rob_fault[r] <= FAULT_STORE;
                if (execute && issue_op == OP_STORE && issue_fault == FAULT_NONE) begin
                    rob_addr[r] <= {issue_address[31:2], 2'b0};
                    rob_data[r] <= issue_store_data;
                    rob_strb[r] <= issue_store_strb;
                end
                if (execute && issue_simple) begin
                    rob_target[r] <= issue_target;
                    rob_branch_dest[r] <= issue_branch_dest;
                    rob_taken[r] <= issue_op != OP_BRANCH || issue_branch_taken;
                end
            end
        end
        for (genvar q = 0; q < IQ_DEPTH; q = q + 1) begin : issue_entries
            wire allocate = dispatch && iq_free_index == QW'(q);
            always_ff @(posedge clock) begin
                if (reset || flush) iq_valid[q] <= 1'b0;
                else begin
                    if (select_fire && issue_index == QW'(q)) iq_valid[q] <= 1'b0;
                    if (allocate) iq_valid[q] <= 1'b1;
                end
                iq_stores[q] <= iq_stores[q] & ~retiring_store;
                if (wb_valid && wb_dst == iq_src1[q]) iq_ready1[q] <= 1'b1;
                if (wb_valid && wb_dst == iq_src2[q]) iq_ready2[q] <= 1'b1;
                // Invalid slots may prepare payload independently of global
                // rename/flush control; the chosen slot becomes valid on dispatch.
                if (!iq_valid[q]) begin
                    iq_rob[q] <= rob_tail;
                    iq_src1[q] <= dispatch_src1;
                    iq_src2[q] <= dispatch_src2;
                    iq_ready1[q] <= prf_ready[dispatch_src1] || (wb_valid && wb_dst == dispatch_src1);
                    iq_ready2[q] <= prf_ready[dispatch_src2] || (wb_valid && wb_dst == dispatch_src2);
                    iq_kind[q] <= dispatch_op == OP_LOAD ? 2'd1 : dispatch_op == OP_MULDIV ? 2'd2 : 2'd0;
                    iq_stores[q] <= rob_is_store & ~retiring_store;
                end
            end
        end
    endgenerate

    always_ff @(posedge clock) begin
        if (reset) begin
            rob_head <= '0;
            rob_tail <= '0;
            rob_count <= '0;
            lsq_count <= '0;
            halted <= 1'b0;
            recovery_pending <= 1'b0;
            recovery_pc <= 32'b0;
            mem_busy <= 1'b0;
            mem_sent <= 1'b0;
            mem_killed <= 1'b0;
            mem_write <= 1'b0;
            mem_addr <= 32'b0;
            mem_data <= 32'b0;
            mem_strb <= 4'b0;
            mem_offset <= 2'b0;
            mem_funct3 <= 3'b0;
            mem_rob <= '0;
            mem_dst <= '0;
            mdu_rob <= '0;
            mdu_dst <= '0;
        end else begin
            if (d_req_valid && d_req_ready) mem_sent <= 1'b1;
            if (mem_response) begin
                mem_busy <= 1'b0;
                mem_sent <= 1'b0;
                mem_killed <= 1'b0;
            end
            if (flush) begin
                rob_head <= '0;
                rob_tail <= '0;
                rob_count <= '0;
                lsq_count <= '0;
                recovery_pending <= 1'b0;
                if (mem_busy && !mem_response) mem_killed <= 1'b1;
            end else if (!halted) begin
                if (!flush && rob_count != 0 && rob_done[rob_head] && rob_fault[rob_head] != FAULT_NONE)
                    halted <= 1'b1;
                case ({dispatch, commit_fire})
                    2'b10: rob_count <= rob_count + 1'b1;
                    2'b01: rob_count <= rob_count - 1'b1;
                    default: ;
                endcase
                case ({dispatch && dec_memory,
                       commit_fire && (rob_is_load[rob_head] || rob_is_store[rob_head])})
                    2'b10: lsq_count <= lsq_count + 1'b1;
                    2'b01: lsq_count <= lsq_count - 1'b1;
                    default: ;
                endcase
                if (commit_fire) begin
                    rob_head <= next_rob(rob_head);
                    // This commit updates RRAT and committed_regs first. The
                    // following recovery cycle prevents any younger retirement.
                    if (rob_redirect[rob_head]) begin
                        recovery_pending <= 1'b1;
                        recovery_pc <= rob_target[rob_head];
                    end
                end
                if (dispatch) rob_tail <= next_rob(rob_tail);
                if (issue_valid && issue_fault == FAULT_NONE) begin
                    if (issue_op == OP_LOAD) begin
                        mem_busy <= 1'b1;
                        mem_sent <= 1'b0;
                        mem_killed <= 1'b0;
                        mem_write <= 1'b0;
                        mem_addr <= {issue_address[31:2], 2'b0};
                        mem_data <= 32'b0;
                        mem_strb <= 4'b0;
                        mem_offset <= issue_address[1:0];
                        mem_funct3 <= issue_funct3;
                        mem_rob <= issue_rob;
                        mem_dst <= issue_dst;
                    end else if (issue_op == OP_MULDIV) begin
                        mdu_rob <= issue_rob;
                        mdu_dst <= issue_dst;
                    end
                end
                if (store_start) begin
                    mem_busy <= 1'b1;
                    mem_sent <= 1'b0;
                    mem_killed <= 1'b0;
                    mem_write <= 1'b1;
                    mem_addr <= rob_addr[rob_head];
                    mem_data <= rob_data[rob_head];
                    mem_strb <= rob_strb[rob_head];
                    mem_rob <= rob_head;
                    mem_dst <= '0;
                end
            end
        end
    end

`ifndef SYNTHESIS
    // Debug-only identities never affect architectural execution or synthesis.
    logic [63:0] trace_cycle, trace_next_id, trace_retired, trace_mem_id;
    logic [31:0] trace_mem_pc, trace_recovery_pc;
    logic [63:0] trace_recovery_id;
    logic [63:0] trace_id [0:ROB_DEPTH-1];
    integer t;
    initial begin
        if (ROB_DEPTH < 2 || PRF_SIZE < 33 || IQ_DEPTH < 1 || LSQ_DEPTH < 1
            || LSQ_DEPTH > ROB_DEPTH || ISSUE_WIDTH != 1)
            $fatal(1, "Unsupported core parameters");
    end
    always @(posedge clock) begin
        if (reset) begin
            trace_cycle <= 0;
            trace_next_id <= 0;
            trace_retired <= 0;
            trace_mem_id <= 0;
            trace_mem_pc <= 0;
            trace_recovery_id <= 0;
            trace_recovery_pc <= 0;
            for (t = 0; t < ROB_DEPTH; t = t + 1) trace_id[t] <= 0;
        end else begin
            trace_cycle <= trace_cycle + 1;
            if (dispatch) begin
                trace_id[rob_tail] <= trace_next_id;
                trace_next_id <= trace_next_id + 1;
                if (TRACE != 0)
                    $display("CPU_TRACE DISPATCH id=%0d cycle=%0d pc=%08x insn=%08x rd=%0d pdst=%0d",
                             trace_next_id, trace_cycle, fetch_buffer_pc, fetch_buffer_insn,
                             dec_has_dst ? dec_rd : 5'b0, dec_has_dst ? free_index : {PW{1'b0}});
            end
            if (TRACE != 0 && issue_valid)
                $display("CPU_TRACE ISSUE id=%0d cycle=%0d pc=%08x insn=%08x",
                         trace_id[issue_rob], trace_cycle, rob_pc[issue_rob], rob_insn[issue_rob]);
            if (TRACE != 0 && !flush && !halted && ex_valid && issue_simple
                && !issue_valid && (load_completion || mdu_result_valid))
                $display("CPU_TRACE WB_STALL id=%0d cycle=%0d pc=%08x source=%0d",
                         trace_id[issue_rob], trace_cycle, issue_pc, load_completion ? 1 : 2);
            if (TRACE != 0 && dispatch && wb_valid && wb_dst != 0
                && (dispatch_src1 == wb_dst || dispatch_src2 == wb_dst))
                $display("CPU_TRACE RENAME_BYPASS id=%0d cycle=%0d pc=%08x source=%0d",
                         trace_next_id, trace_cycle, fetch_buffer_pc,
                         (dispatch_src1 == wb_dst ? 1 : 0) + (dispatch_src2 == wb_dst ? 2 : 0));
            if (TRACE != 0 && mem_response)
                $display("CPU_TRACE MEM_RESPONSE id=%0d cycle=%0d pc=%08x write=%0d killed=%0d",
                         mem_write ? trace_id[mem_rob] : trace_mem_id, trace_cycle,
                         mem_write ? rob_pc[mem_rob] : trace_mem_pc, mem_write, mem_killed || flush);
            if (TRACE != 0 && commit_fire && rob_is_store[rob_head])
                $display("CPU_TRACE STORE_RETIRE id=%0d cycle=%0d pc=%08x",
                         trace_id[rob_head], trace_cycle, rob_pc[rob_head]);
            if (TRACE != 0 && wb_valid)
                $display("CPU_TRACE COMPLETE id=%0d cycle=%0d pc=%08x insn=%08x",
                         trace_id[wb_rob], trace_cycle, rob_pc[wb_rob], rob_insn[wb_rob]);
            if (issue_valid && issue_op == OP_LOAD && issue_fault == FAULT_NONE) begin
                trace_mem_id <= trace_id[issue_rob];
                trace_mem_pc <= rob_pc[issue_rob];
            end
            if (commit_fire && rob_redirect[rob_head]) begin
                trace_recovery_id <= trace_id[rob_head];
                trace_recovery_pc <= rob_pc[rob_head];
            end
            if (TRACE != 0 && flush)
                $display("CPU_TRACE FLUSH id=%0d cycle=%0d pc=%08x target=%08x load_pending=%0d",
                         trace_recovery_id, trace_cycle, trace_recovery_pc, recovery_pc,
                         mem_busy && !mem_write && !mem_response);
            if (TRACE != 0 && mem_response && !mem_write && (mem_killed || flush))
                $display("CPU_TRACE DROP_LOAD id=%0d cycle=%0d pc=%08x",
                         trace_mem_id, trace_cycle, trace_mem_pc);
            // A store becomes irrevocable at the cache request handshake. Its
            // ROB entry remains at the head until B and the local update finish.
            // Recording here also includes exit MMIO, whose B ends the harness.
            if (d_req_valid && d_req_ready && mem_write) begin
                if (TRACE != 0)
                    $display("CPU_TRACE COMMIT seq=%0d id=%0d cycle=%0d pc=%08x insn=%08x rd=0 value=00000000 store=1 addr=%08x data=%08x strb=%01x",
                             trace_retired, trace_id[mem_rob], trace_cycle,
                             rob_pc[mem_rob], rob_insn[mem_rob], mem_addr, mem_data, mem_strb);
                trace_retired <= trace_retired + 1;
            end else if (commit_fire && rob_op[rob_head] != OP_STORE) begin
                if (TRACE != 0)
                    $display("CPU_TRACE COMMIT seq=%0d id=%0d cycle=%0d pc=%08x insn=%08x rd=%0d value=%08x store=0 addr=00000000 data=00000000 strb=0",
                             trace_retired, trace_id[rob_head], trace_cycle,
                             rob_pc[rob_head], rob_insn[rob_head], rob_rd[rob_head],
                             rob_rd[rob_head] == 0 ? 32'b0 : prf[rob_dst[rob_head]]);
                trace_retired <= trace_retired + 1;
            end
            if (!halted) begin
                if (ex_valid && !flush && issue_op == OP_LOAD && issue_fault == FAULT_NONE)
                    assert (!store_start);
                for (integer q = 0; q < IQ_DEPTH; q = q + 1)
                    if (iq_valid[q] && iq_kind[q] == 1)
                        for (integer r = 0; r < ROB_DEPTH; r = r + 1)
                            if (rob_valid[r] && rob_is_store[r] && older(RW'(r), iq_rob[q], rob_head))
                                assert (iq_stores[q][r]);
                assert (rat[0] == 0 && rrat[0] == 0 && prf[0] == 0 && prf_ready[0] && !free_regs[0]);
                assert (int'(rob_count) <= ROB_DEPTH && int'(lsq_count) <= LSQ_DEPTH);
                if (issue_valid) assert (rob_valid[issue_rob] && !rob_done[issue_rob]);
                if (wb_valid) assert (rob_valid[wb_rob] && rob_dst[wb_rob] == wb_dst);
                if (flush && mem_busy) assert (!mem_write);
                if (d_req_valid && mem_write) assert (mem_rob == rob_head && !mem_killed);
                if (!flush && rob_count != 0 && rob_done[rob_head] && rob_fault[rob_head] != FAULT_NONE)
                    $fatal(1, "CPU fault=%0d pc=%08x instruction=%08x",
                           rob_fault[rob_head], rob_pc[rob_head], rob_insn[rob_head]);
            end
        end
    end
`endif
endmodule
