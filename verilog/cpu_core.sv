// PRF + ROB core: one rename/issue/retirement per cycle, oldest-ready issue.
// The ROB also owns the conservative LSQ metadata. Stores wait at its head;
// loads cannot pass an older store. Three completion sources share one PRF port.
module cpu_core #(
    parameter integer ROB_DEPTH = 16,
    parameter integer PRF_SIZE = 48,
    parameter integer IQ_DEPTH = 8,
    parameter integer LSQ_DEPTH = 8,
    parameter integer ISSUE_WIDTH = 1,
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
    localparam integer AW = RW + 1;
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
    logic [PRF_SIZE-1:0] prf_ready, free_regs;

    logic [ROB_DEPTH-1:0] rob_valid, rob_done, rob_redirect, rob_store_done;
    logic [RW-1:0] rob_head, rob_tail;
    logic [CW-1:0] rob_count;
    logic [LW-1:0] lsq_count;
    logic [31:0] rob_pc [0:ROB_DEPTH-1], rob_insn [0:ROB_DEPTH-1];
    logic [31:0] rob_imm [0:ROB_DEPTH-1], rob_target [0:ROB_DEPTH-1];
    logic [31:0] rob_addr [0:ROB_DEPTH-1], rob_data [0:ROB_DEPTH-1];
    logic [3:0] rob_strb [0:ROB_DEPTH-1], rob_fault [0:ROB_DEPTH-1];
    logic [4:0] rob_op [0:ROB_DEPTH-1], rob_rd [0:ROB_DEPTH-1];
    logic [2:0] rob_funct3 [0:ROB_DEPTH-1];
    logic [PW-1:0] rob_dst [0:ROB_DEPTH-1], rob_old [0:ROB_DEPTH-1];
    logic [ROB_DEPTH-1:0] rob_use_imm;

    logic [IQ_DEPTH-1:0] iq_valid;
    logic [RW-1:0] iq_rob [0:IQ_DEPTH-1];
    logic [PW-1:0] iq_src1 [0:IQ_DEPTH-1], iq_src2 [0:IQ_DEPTH-1];

    // A single uncancellable fetch may survive any number of recoveries.
    // Its drop bit stays set until the response is drained, so no finite epoch
    // can wrap while an old external transaction is still alive.
    logic [31:0] fetch_pc, fetch_active_pc, fetch_buffer_pc, fetch_buffer_insn;
    logic fetch_busy, fetch_drop, fetch_buffer_valid, fetch_buffer_error;
    logic halted;

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

    logic mdu_req_valid, mdu_req_ready, mdu_result_valid, mdu_result_ready;
    logic [31:0] mdu_result;
    logic [RW-1:0] mdu_rob;
    logic [PW-1:0] mdu_dst;

    logic commit_fire, flush, store_start, dispatch;
    logic dec_has_dst, dec_memory;
    logic free_found, iq_free_found;
    logic [PW-1:0] free_index;
    logic [QW-1:0] iq_free_index;
    logic [PRF_SIZE-1:0] recovery_used;

    logic issue_valid;
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
    integer scan, scan2;
    logic [AW-1:0] scan_age, best_age;
    logic older_store, candidate_ready;

    function automatic [RW-1:0] next_rob(input [RW-1:0] index);
        next_rob = (index == RW'(ROB_DEPTH-1)) ? '0 : index + 1'b1;
    endfunction

    function automatic [AW-1:0] rob_age(input [RW-1:0] index, input [RW-1:0] head);
        if (index >= head) rob_age = AW'(index) - AW'(head);
        else rob_age = AW'(index) + AW'(ROB_DEPTH) - AW'(head);
    endfunction

    generate
        if (ROB_DEPTH < 2 || PRF_SIZE < 33 || IQ_DEPTH < 1 || LSQ_DEPTH < 1
            || LSQ_DEPTH > ROB_DEPTH || ISSUE_WIDTH != 1) begin : invalid_parameters
            cpu_core_requires_valid_single_issue_configuration invalid_configuration();
        end
    endgenerate

    always_comb begin
        commit_fire = !reset && !halted && rob_count != 0 && rob_done[rob_head]
                   && rob_fault[rob_head] == FAULT_NONE
                   && (rob_op[rob_head] != OP_STORE || rob_store_done[rob_head]);
        flush = commit_fire && rob_redirect[rob_head];
        store_start = !reset && !halted && !mem_busy && rob_count != 0
                   && rob_op[rob_head] == OP_STORE && rob_done[rob_head]
                   && !rob_store_done[rob_head] && rob_fault[rob_head] == FAULT_NONE;

        free_found = 1'b0;
        free_index = '0;
        for (integer p = 1; p < PRF_SIZE; p = p + 1)
            if (!free_found && free_regs[p]) begin
                free_found = 1'b1;
                free_index = PW'(p);
            end
        iq_free_found = 1'b0;
        iq_free_index = '0;
        for (integer q = 0; q < IQ_DEPTH; q = q + 1)
            if (!iq_free_found && !iq_valid[q]) begin
                iq_free_found = 1'b1;
                iq_free_index = QW'(q);
            end

        dec_has_dst = dec_writes_rd && dec_rd != 0 && !dec_illegal && !fetch_buffer_error;
        dec_memory = !dec_illegal && !fetch_buffer_error
                  && (dec_op == OP_LOAD || dec_op == OP_STORE);
        dispatch = !reset && !halted && !flush && fetch_buffer_valid
                && rob_count < CW'(ROB_DEPTH) && iq_free_found
                && (!dec_has_dst || free_found)
                && (!dec_memory || lsq_count < LW'(LSQ_DEPTH));

        recovery_used = '0;
        for (integer a = 0; a < 32; a = a + 1)
            recovery_used[rrat[a]] = 1'b1;
        if (rob_rd[rob_head] != 0) begin
            recovery_used[rrat[rob_rd[rob_head]]] = 1'b0;
            recovery_used[rob_dst[rob_head]] = 1'b1;
        end
        recovery_used[0] = 1'b1;
    end

    always_comb begin
        i_req_addr = fetch_pc;
        i_req_valid = !reset && !halted && !flush && !fetch_busy && !fetch_buffer_valid;
        i_rsp_ready = !reset && fetch_busy && (!fetch_buffer_valid || fetch_drop || flush);
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

    // Age is relative to the circular ROB head, not the physical slot number.
    // Ready state is read from the PRF, so insertion concurrent with writeback
    // cannot miss a wakeup. No speculative memory disambiguation is needed.
    always_comb begin
        issue_valid = 1'b0;
        issue_index = '0;
        best_age = AW'(ROB_DEPTH);
        scan_age = 0;
        older_store = 1'b0;
        candidate_ready = 1'b0;
        for (scan = 0; scan < IQ_DEPTH; scan = scan + 1) begin
            scan_age = rob_age(iq_rob[scan], rob_head);
            older_store = 1'b0;
            for (scan2 = 0; scan2 < ROB_DEPTH; scan2 = scan2 + 1)
                if (rob_valid[scan2] && rob_op[scan2] == OP_STORE
                    && rob_age(RW'(scan2), rob_head) < scan_age)
                    older_store = 1'b1;
            candidate_ready = iq_valid[scan]
                           && prf_ready[iq_src1[scan]] && prf_ready[iq_src2[scan]];
            if (rob_fault[iq_rob[scan]] != FAULT_NONE)
                candidate_ready = candidate_ready && !load_completion && !mdu_result_valid;
            else if (rob_op[iq_rob[scan]] == OP_MULDIV)
                candidate_ready = candidate_ready && mdu_req_ready;
            else if (rob_op[iq_rob[scan]] == OP_LOAD)
                candidate_ready = candidate_ready && !mem_busy && !store_start && !older_store
                               && !load_completion && !mdu_result_valid;
            else
                candidate_ready = candidate_ready && !load_completion && !mdu_result_valid;
            if (candidate_ready && scan_age < best_age) begin
                issue_valid = 1'b1;
                issue_index = QW'(scan);
                best_age = scan_age;
            end
        end
        issue_valid = issue_valid && !reset && !halted && !flush;
    end

    assign issue_rob = iq_rob[issue_index];
    assign issue_op = rob_op[issue_rob];
    assign issue_a = prf[iq_src1[issue_index]];
    assign issue_b = prf[iq_src2[issue_index]];
    assign alu_lhs = (issue_op == OP_AUIPC) ? rob_pc[issue_rob] : issue_a;
    assign alu_rhs = rob_use_imm[issue_rob] ? rob_imm[issue_rob] : issue_b;
    alu integer_alu (.op(issue_op), .lhs(alu_lhs), .rhs(alu_rhs), .result(alu_result));

    always_comb begin
        issue_address = issue_a + rob_imm[issue_rob];
        issue_store_data = issue_b << {issue_address[1:0], 3'b000};
        case (rob_funct3[issue_rob][1:0])
            2'b00: issue_store_strb = 4'b0001 << issue_address[1:0];
            2'b01: issue_store_strb = 4'b0011 << issue_address[1:0];
            default: issue_store_strb = 4'b1111;
        endcase
        issue_misaligned = (rob_funct3[issue_rob][1:0] == 2'b01 && issue_address[0])
                         || (rob_funct3[issue_rob][1:0] == 2'b10 && issue_address[1:0] != 0);
        case (rob_funct3[issue_rob])
            3'b000: issue_branch_taken = issue_a == issue_b;
            3'b001: issue_branch_taken = issue_a != issue_b;
            3'b100: issue_branch_taken = $signed(issue_a) < $signed(issue_b);
            3'b101: issue_branch_taken = $signed(issue_a) >= $signed(issue_b);
            3'b110: issue_branch_taken = issue_a < issue_b;
            3'b111: issue_branch_taken = issue_a >= issue_b;
            default: issue_branch_taken = 1'b0;
        endcase
        issue_target = rob_pc[issue_rob] + 32'd4;
        if (issue_op == OP_JAL || (issue_op == OP_BRANCH && issue_branch_taken))
            issue_target = rob_pc[issue_rob] + rob_imm[issue_rob];
        if (issue_op == OP_JALR)
            issue_target = (issue_a + rob_imm[issue_rob]) & 32'hffff_fffe;
        issue_redirect = issue_target != rob_pc[issue_rob] + 32'd4;
        issue_value = (issue_op == OP_JAL || issue_op == OP_JALR)
                    ? rob_pc[issue_rob] + 32'd4 : alu_result;
        issue_fault = rob_fault[issue_rob];
        if (issue_fault == FAULT_NONE) begin
            if ((issue_op == OP_LOAD || issue_op == OP_STORE) && issue_misaligned)
                issue_fault = FAULT_ALIGN;
            if ((issue_op == OP_JAL || issue_op == OP_JALR || issue_op == OP_BRANCH)
                && issue_target[1:0] != 0)
                issue_fault = FAULT_ALIGN;
        end
        issue_simple = issue_fault != FAULT_NONE
                    || (issue_op != OP_LOAD && issue_op != OP_STORE && issue_op != OP_MULDIV);
        mdu_req_valid = issue_valid && issue_op == OP_MULDIV && issue_fault == FAULT_NONE;
    end

    muldiv_unit mdu (
        .clock(clock), .reset(reset), .flush(flush),
        .req_valid(mdu_req_valid), .req_ready(mdu_req_ready),
        .operation(rob_funct3[issue_rob]), .operand_a(issue_a), .operand_b(issue_b),
        .result_valid(mdu_result_valid), .result_ready(mdu_result_ready), .result(mdu_result)
    );

    always_comb begin
        wb_valid = 1'b0;
        wb_rob = issue_rob;
        wb_dst = rob_dst[issue_rob];
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

    integer j;
    always_ff @(posedge clock) begin
        if (reset) begin
            rob_valid <= '0;
            rob_done <= '0;
            rob_redirect <= '0;
            rob_store_done <= '0;
            rob_use_imm <= '0;
            rob_head <= '0;
            rob_tail <= '0;
            rob_count <= '0;
            lsq_count <= '0;
            iq_valid <= '0;
            fetch_pc <= 32'b0;
            fetch_active_pc <= 32'b0;
            fetch_buffer_pc <= 32'b0;
            fetch_buffer_insn <= 32'b0;
            fetch_busy <= 1'b0;
            fetch_drop <= 1'b0;
            fetch_buffer_valid <= 1'b0;
            fetch_buffer_error <= 1'b0;
            halted <= 1'b0;
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
            for (j = 0; j < 32; j = j + 1) begin
                rat[j] <= PW'(j);
                rrat[j] <= PW'(j);
            end
            for (j = 0; j < PRF_SIZE; j = j + 1) begin
                prf[j] <= 32'b0;
                prf_ready[j] <= 1'b1;
                free_regs[j] <= j >= 32;
            end
            for (j = 0; j < ROB_DEPTH; j = j + 1) begin
                rob_pc[j] <= 32'b0;
                rob_insn[j] <= 32'b0;
                rob_imm[j] <= 32'b0;
                rob_target[j] <= 32'b0;
                rob_addr[j] <= 32'b0;
                rob_data[j] <= 32'b0;
                rob_strb[j] <= 4'b0;
                rob_fault[j] <= FAULT_NONE;
                rob_op[j] <= 5'b0;
                rob_rd[j] <= 5'b0;
                rob_funct3[j] <= 3'b0;
                rob_dst[j] <= '0;
                rob_old[j] <= '0;
            end
            for (j = 0; j < IQ_DEPTH; j = j + 1) begin
                iq_rob[j] <= '0;
                iq_src1[j] <= '0;
                iq_src2[j] <= '0;
            end
        end else begin
            if (i_req_valid && i_req_ready) begin
                fetch_busy <= 1'b1;
                fetch_drop <= 1'b0;
                fetch_active_pc <= fetch_pc;
                fetch_pc <= fetch_pc + 32'd4;
            end
            if (i_rsp_valid && i_rsp_ready) begin
                fetch_busy <= 1'b0;
                fetch_drop <= 1'b0;
                if (!fetch_drop && !flush) begin
                    fetch_buffer_valid <= 1'b1;
                    fetch_buffer_pc <= fetch_active_pc;
                    fetch_buffer_insn <= i_rsp_data;
                    fetch_buffer_error <= i_rsp_error || fetch_active_pc[1:0] != 0;
                end
            end
            if (d_req_valid && d_req_ready)
                mem_sent <= 1'b1;
            if (mem_response) begin
                mem_busy <= 1'b0;
                mem_sent <= 1'b0;
                mem_killed <= 1'b0;
            end

            if (flush) begin
                rob_valid <= '0;
                rob_done <= '0;
                rob_redirect <= '0;
                rob_store_done <= '0;
                rob_head <= '0;
                rob_tail <= '0;
                rob_count <= '0;
                lsq_count <= '0;
                iq_valid <= '0;
                fetch_pc <= rob_target[rob_head];
                fetch_buffer_valid <= 1'b0;
                if (fetch_busy && !(i_rsp_valid && i_rsp_ready)) fetch_drop <= 1'b1;
                if (mem_busy && !mem_response) mem_killed <= 1'b1;
                free_regs <= ~recovery_used;
                prf_ready <= '1;
                for (j = 0; j < 32; j = j + 1)
                    if (rob_rd[rob_head] != 0 && rob_rd[rob_head] == 5'(j))
                        rat[j] <= rob_dst[rob_head];
                    else rat[j] <= rrat[j];
                if (rob_rd[rob_head] != 0)
                    rrat[rob_rd[rob_head]] <= rob_dst[rob_head];
            end else if (!halted) begin
                if (rob_count != 0 && rob_done[rob_head] && rob_fault[rob_head] != FAULT_NONE)
                    halted <= 1'b1;

                case ({dispatch, commit_fire})
                    2'b10: rob_count <= rob_count + 1'b1;
                    2'b01: rob_count <= rob_count - 1'b1;
                    default: ;
                endcase
                case ({dispatch && dec_memory,
                       commit_fire && (rob_op[rob_head] == OP_LOAD || rob_op[rob_head] == OP_STORE)})
                    2'b10: lsq_count <= lsq_count + 1'b1;
                    2'b01: lsq_count <= lsq_count - 1'b1;
                    default: ;
                endcase
                if (commit_fire) begin
                    rob_valid[rob_head] <= 1'b0;
                    rob_done[rob_head] <= 1'b0;
                    rob_head <= next_rob(rob_head);
                    if (rob_rd[rob_head] != 0) begin
                        rrat[rob_rd[rob_head]] <= rob_dst[rob_head];
                        free_regs[rob_old[rob_head]] <= 1'b1;
                    end
                end

                if (dispatch) begin
                    fetch_buffer_valid <= 1'b0;
                    rob_valid[rob_tail] <= 1'b1;
                    rob_done[rob_tail] <= 1'b0;
                    rob_redirect[rob_tail] <= 1'b0;
                    rob_store_done[rob_tail] <= 1'b0;
                    rob_pc[rob_tail] <= fetch_buffer_pc;
                    rob_insn[rob_tail] <= fetch_buffer_insn;
                    rob_op[rob_tail] <= (fetch_buffer_error || dec_illegal) ? 5'd31 : dec_op;
                    rob_imm[rob_tail] <= dec_imm;
                    rob_funct3[rob_tail] <= dec_funct3;
                    rob_use_imm[rob_tail] <= dec_use_imm;
                    rob_rd[rob_tail] <= dec_has_dst ? dec_rd : 5'b0;
                    rob_dst[rob_tail] <= dec_has_dst ? free_index : {PW{1'b0}};
                    rob_old[rob_tail] <= dec_has_dst ? rat[dec_rd] : {PW{1'b0}};
                    rob_fault[rob_tail] <= fetch_buffer_error ? FAULT_FETCH
                                        : dec_illegal ? FAULT_ILLEGAL : FAULT_NONE;
                    rob_tail <= next_rob(rob_tail);
                    iq_valid[iq_free_index] <= 1'b1;
                    iq_rob[iq_free_index] <= rob_tail;
                    iq_src1[iq_free_index] <= dec_use_rs1 && !dec_illegal && !fetch_buffer_error
                                            ? rat[dec_rs1] : {PW{1'b0}};
                    iq_src2[iq_free_index] <= dec_use_rs2 && !dec_illegal && !fetch_buffer_error
                                            ? rat[dec_rs2] : {PW{1'b0}};
                    if (dec_has_dst) begin
                        rat[dec_rd] <= free_index;
                        prf_ready[free_index] <= 1'b0;
                        free_regs[free_index] <= 1'b0;
                    end
                end

                if (issue_valid) begin
                    iq_valid[issue_index] <= 1'b0;
                    if (issue_fault == FAULT_NONE) begin
                        if (issue_op == OP_STORE) begin
                            rob_addr[issue_rob] <= {issue_address[31:2], 2'b0};
                            rob_data[issue_rob] <= issue_store_data;
                            rob_strb[issue_rob] <= issue_store_strb;
                            rob_done[issue_rob] <= 1'b1;
                        end else if (issue_op == OP_LOAD) begin
                            mem_busy <= 1'b1;
                            mem_sent <= 1'b0;
                            mem_killed <= 1'b0;
                            mem_write <= 1'b0;
                            mem_addr <= {issue_address[31:2], 2'b0};
                            mem_data <= 32'b0;
                            mem_strb <= 4'b0;
                            mem_offset <= issue_address[1:0];
                            mem_funct3 <= rob_funct3[issue_rob];
                            mem_rob <= issue_rob;
                            mem_dst <= rob_dst[issue_rob];
                        end else if (issue_op == OP_MULDIV) begin
                            mdu_rob <= issue_rob;
                            mdu_dst <= rob_dst[issue_rob];
                        end
                    end
                    if (issue_simple) begin
                        rob_redirect[issue_rob] <= issue_redirect && issue_fault == FAULT_NONE;
                        rob_target[issue_rob] <= issue_target;
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
                if (mem_response && mem_write && !mem_killed) begin
                    rob_store_done[mem_rob] <= 1'b1;
                    if (d_rsp_error) rob_fault[mem_rob] <= FAULT_STORE;
                end

                if (wb_valid) begin
                    rob_done[wb_rob] <= 1'b1;
                    rob_fault[wb_rob] <= wb_fault;
                    if (wb_dst != 0) begin
                        prf[wb_dst] <= wb_value;
                        prf_ready[wb_dst] <= 1'b1;
                    end
                end
            end
        end
    end

`ifndef SYNTHESIS
    // Debug-only identities never affect architectural execution or synthesis.
    logic [63:0] trace_cycle, trace_next_id, trace_retired, trace_mem_id;
    logic [31:0] trace_mem_pc;
    logic [63:0] trace_id [0:ROB_DEPTH-1];
    integer t;
    initial begin
        if (ROB_DEPTH < 2 || PRF_SIZE < 33 || IQ_DEPTH < 1 || LSQ_DEPTH < 1
            || LSQ_DEPTH > ROB_DEPTH || ISSUE_WIDTH != 1)
            $fatal(1, "Unsupported V1 core parameters");
    end
    always @(posedge clock) begin
        if (reset) begin
            trace_cycle <= 0;
            trace_next_id <= 0;
            trace_retired <= 0;
            trace_mem_id <= 0;
            trace_mem_pc <= 0;
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
            if (TRACE != 0 && wb_valid)
                $display("CPU_TRACE COMPLETE id=%0d cycle=%0d pc=%08x insn=%08x",
                         trace_id[wb_rob], trace_cycle, rob_pc[wb_rob], rob_insn[wb_rob]);
            if (issue_valid && issue_op == OP_LOAD && issue_fault == FAULT_NONE) begin
                trace_mem_id <= trace_id[issue_rob];
                trace_mem_pc <= rob_pc[issue_rob];
            end
            if (TRACE != 0 && flush)
                $display("CPU_TRACE FLUSH id=%0d cycle=%0d pc=%08x target=%08x load_pending=%0d",
                         trace_id[rob_head], trace_cycle, rob_pc[rob_head], rob_target[rob_head],
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
                assert (rat[0] == 0 && rrat[0] == 0 && prf[0] == 0 && prf_ready[0] && !free_regs[0]);
                assert (int'(rob_count) <= ROB_DEPTH && int'(lsq_count) <= LSQ_DEPTH);
                if (issue_valid) assert (rob_valid[issue_rob] && !rob_done[issue_rob]);
                if (wb_valid) assert (rob_valid[wb_rob] && rob_dst[wb_rob] == wb_dst);
                if (flush && mem_busy) assert (!mem_write);
                if (d_req_valid && mem_write) assert (mem_rob == rob_head && !mem_killed);
                if (rob_count != 0 && rob_done[rob_head] && rob_fault[rob_head] != FAULT_NONE)
                    $fatal(1, "CPU fault=%0d pc=%08x instruction=%08x",
                           rob_fault[rob_head], rob_pc[rob_head], rob_insn[rob_head]);
            end
        end
    end
`endif
endmodule
