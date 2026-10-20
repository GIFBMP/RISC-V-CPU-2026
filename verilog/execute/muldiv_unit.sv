// Single-request RV32M unit: radix-4 Booth/CSA multiplication and
// leading-zero-skipping division with one retained quotient/remainder pair.
// Inputs are captured on req_valid && req_ready. Flush cancels both in-flight
// operations and an unconsumed result; it has priority over both handshakes.
module muldiv_unit (
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  logic        req_valid,
    input  logic [2:0]  operation,
    input  logic [31:0] operand_a,
    input  logic [31:0] operand_b,
    input  logic        result_ready,
    output logic        req_ready,
    output logic        result_valid,
    // State-only availability for scheduling; handshakes below still cancel
    // on reset/flush. Consumers must gate actual issue with their validity.
    output logic        req_available,
    output logic        result_pending,
    output logic [31:0] result
);
    localparam logic [2:0] IDLE = 3'd0;
    localparam logic [2:0] MULTIPLY = 3'd1;
    localparam logic [2:0] MUL_FINISH = 3'd2;
    localparam logic [2:0] DIV_PREP = 3'd3;
    localparam logic [2:0] DIVIDE = 3'd4;
    localparam logic [2:0] RESULT = 3'd5;

    logic [2:0] state;
    logic [2:0] active_operation;
    logic [5:0] iteration;
    logic [31:0] result_reg;

    logic [32:0] multiply_a, multiply_b;
    wire [34:0] booth_multiplier = {multiply_b[32], multiply_b, 1'b0};
    wire [63:0] partial_product [0:17];
    wire [16:0] booth_negative;
    logic [63:0] product_sum, product_carry;
    wire [63:0] product = product_sum + product_carry;

    // Sign/zero extension to 33 bits covers MULH, MULHSU and MULHU without
    // an absolute-value conversion or a final 64-bit sign correction.
    // Negative Booth digits use one's complement plus a separate correction
    // bit: no carry-propagating adder is needed in any partial-product row.
    for (genvar digit = 0; digit < 17; digit = digit + 1) begin : booth
        wire [2:0] code = booth_multiplier[2*digit +: 3];
        wire one = code[0] ^ code[1];
        wire two = code == 3'b011 || code == 3'b100;
        wire [33:0] magnitude = ({34{one}} & {multiply_a[32], multiply_a}) |
                                ({34{two}} & {multiply_a, 1'b0});
        wire [33:0] complemented = magnitude ^ {34{code[2]}};
        assign booth_negative[digit] = code[2];
        assign partial_product[digit] =
            {{30{complemented[33]}}, complemented} << (2*digit);
    end
    for (genvar bit_index = 0; bit_index < 64; bit_index = bit_index + 1) begin : correction
        if (bit_index <= 32 && bit_index % 2 == 0) begin : negative_digit
            assign partial_product[17][bit_index] = booth_negative[bit_index/2];
        end else begin : zero
            assign partial_product[17][bit_index] = 1'b0;
        end
    end

    // Pseudo-Wallace tree: 18 -> 12 -> 8 -> 6 -> 4 -> 3 -> 2 rows.
    // Every carry vector is shifted exactly once before the next level.
    for (genvar level = 0; level < 7; level = level + 1) begin : compression
        localparam integer ROWS = level == 0 ? 18 : level == 1 ? 12 :
                                  level == 2 ? 8 : level == 3 ? 6 :
                                  level == 4 ? 4 : level == 5 ? 3 : 2;
        wire [63:0] rows [0:ROWS-1];
        if (level == 0) begin : inputs
            for (genvar row = 0; row < ROWS; row = row + 1) begin : copy
                assign rows[row] = partial_product[row];
            end
        end else begin : reduce
            localparam integer PREVIOUS = level == 1 ? 18 : level == 2 ? 12 :
                                          level == 3 ? 8 : level == 4 ? 6 :
                                          level == 5 ? 4 : 3;
            for (genvar group_index = 0; group_index < PREVIOUS/3; group_index = group_index + 1) begin : csa
                wire [63:0] x = compression[level-1].rows[3*group_index];
                wire [63:0] y = compression[level-1].rows[3*group_index+1];
                wire [63:0] z = compression[level-1].rows[3*group_index+2];
                assign rows[2*group_index] = x ^ y ^ z;
                assign rows[2*group_index+1] = ((x & y) | (x & z) | (y & z)) << 1;
            end
            for (genvar rest = 0; rest < PREVIOUS%3; rest = rest + 1) begin : pass_through
                assign rows[2*(PREVIOUS/3)+rest] = compression[level-1].rows[3*(PREVIOUS/3)+rest];
            end
        end
    end

    logic [31:0] divisor;
    logic [31:0] quotient;
    logic [31:0] remainder_value;
    logic negate_quotient;
    logic negate_remainder;
    logic [32:0] shifted_remainder;
    logic [32:0] trial_remainder;
    logic [31:0] next_remainder;
    logic [31:0] next_quotient;
    logic [31:0] signed_quotient, signed_remainder;
    logic [4:0] leading_zeros;
    logic [31:0] normalize16, normalize8, normalize4, normalize2, normalized_dividend;

    // Reuse only exact operand bits and the same signed/unsigned interpretation.
    // Multiplication leaves this entry intact. Reset/flush invalidate it, and a
    // canceled division cannot install an entry.
    logic division_cached;
    logic cached_signed;
    logic [31:0] cached_a, cached_b, cached_quotient, cached_remainder;
    logic [31:0] active_a, active_b;
    logic reuse_division;

    logic a_negative;
    logic b_negative;
    logic [31:0] a_magnitude;
    logic [31:0] b_magnitude;

    always_comb begin
        req_available = state == IDLE;
        result_pending = state == RESULT;
        req_ready = req_available && !reset && !flush;
        result_valid = result_pending && !reset && !flush;
        result = result_reg;

        // Low-half MUL can use unsigned operands; the low bits are identical.
        a_negative = operand_a[31] &&
                     (operation == 3'b001 || operation == 3'b010 ||
                      operation == 3'b100 || operation == 3'b110);
        b_negative = operand_b[31] &&
                     (operation == 3'b001 || operation == 3'b100 ||
                      operation == 3'b110);
        a_magnitude = a_negative ? (~operand_a + 32'd1) : operand_a;
        b_magnitude = b_negative ? (~operand_b + 32'd1) : operand_b;

        // Binary leading-zero search and alignment share their mux stages.
        // Zero is deliberately assigned 31 skipped bits and one zero trial.
        leading_zeros[4] = quotient[31:16] == 0;
        normalize16 = leading_zeros[4] ? {quotient[15:0], 16'b0} : quotient;
        leading_zeros[3] = normalize16[31:24] == 0;
        normalize8 = leading_zeros[3] ? {normalize16[23:0], 8'b0} : normalize16;
        leading_zeros[2] = normalize8[31:28] == 0;
        normalize4 = leading_zeros[2] ? {normalize8[27:0], 4'b0} : normalize8;
        leading_zeros[1] = normalize4[31:30] == 0;
        normalize2 = leading_zeros[1] ? {normalize4[29:0], 2'b0} : normalize4;
        leading_zeros[0] = !normalize2[31];
        normalized_dividend = leading_zeros[0] ? {normalize2[30:0], 1'b0} : normalize2;

        shifted_remainder = {remainder_value, quotient[31]};
        trial_remainder = shifted_remainder - {1'b0, divisor};
        // The restoring invariant is remainder < divisor. The signed 33-bit
        // trial therefore fits, and its sign replaces a separate comparator.
        if (!trial_remainder[32]) begin
            next_remainder = trial_remainder[31:0];
            next_quotient = {quotient[30:0], 1'b1};
        end else begin
            next_remainder = shifted_remainder[31:0];
            next_quotient = {quotient[30:0], 1'b0};
        end
        signed_quotient = negate_quotient ? (~next_quotient + 32'd1) : next_quotient;
        signed_remainder = negate_remainder ? (~next_remainder + 32'd1) : next_remainder;
    end

    // Cancel validity/state only. A discarded iteration may update payload,
    // but a new request reinitializes every datum used by its operation.
    always_ff @(posedge clock) begin
        if (reset || flush) state <= IDLE;
        else case (state)
            IDLE: if (req_valid) begin
                if (!operation[2]) state <= MULTIPLY;
                else if (operand_b == 0) state <= RESULT;
                else state <= DIV_PREP;
            end
            MULTIPLY: state <= MUL_FINISH;
            MUL_FINISH: state <= RESULT;
            DIV_PREP: state <= reuse_division ? RESULT : DIVIDE;
            DIVIDE: if (iteration == 6'd31) state <= RESULT;
            RESULT: if (result_ready) state <= IDLE;
            default: state <= IDLE;
        endcase
    end
    always_ff @(posedge clock) begin
        if (reset || flush) division_cached <= 1'b0;
        else if (state == DIVIDE && iteration == 6'd31)
            division_cached <= 1'b1;
        if (state == DIVIDE && iteration == 6'd31) begin
            cached_a <= active_a;
            cached_b <= active_b;
            cached_signed <= !active_operation[0];
            cached_quotient <= signed_quotient;
            cached_remainder <= signed_remainder;
        end
    end
    always_ff @(posedge clock) begin
        case (state)
            // Idle payload is unobservable. Prepare operands independently of
            // the core's request/flush control; only the state handshake starts
            // an operation, on the same edge that captures its real operands.
            IDLE: begin
                active_operation <= operation;
                iteration <= 6'b0;
                active_a <= operand_a;
                active_b <= operand_b;
                // Register the lookup with the operands. A hit completes on
                // the DIV_PREP edge, keeping this wide comparison out of
                // the request-to-state control path.
                reuse_division <= division_cached && cached_signed == !operation[0]
                    && cached_a == operand_a && cached_b == operand_b;
                if (!operation[2]) begin
                    multiply_a <= {a_negative, operand_a};
                    multiply_b <= {b_negative, operand_b};
                end else if (operand_b == 0) begin
                    result_reg <= operation[1] ? operand_a : 32'hffff_ffff;
                end else begin
                    divisor <= b_magnitude;
                    quotient <= a_magnitude;
                    remainder_value <= 32'b0;
                    negate_quotient <= a_negative ^ b_negative;
                    negate_remainder <= a_negative;
                end
            end
            MULTIPLY: begin
                product_sum <= compression[6].rows[0];
                product_carry <= compression[6].rows[1];
            end
            MUL_FINISH:
                result_reg <= active_operation == 3'b000 ? product[31:0] : product[63:32];
            DIV_PREP: begin
                quotient <= normalized_dividend;
                iteration <= {1'b0, leading_zeros};
                if (reuse_division)
                    result_reg <= active_operation[1] ? cached_remainder : cached_quotient;
            end
            DIVIDE: begin
                quotient <= next_quotient;
                remainder_value <= next_remainder;
                if (iteration == 6'd31)
                    result_reg <= active_operation[1] ? signed_remainder : signed_quotient;
                else iteration <= iteration + 6'd1;
            end
            default: ;
        endcase
    end
endmodule
