// Single-request RV32M unit: 32 shift/add or restoring-division iterations.
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
    localparam logic [1:0] IDLE = 2'd0;
    localparam logic [1:0] MULTIPLY = 2'd1;
    localparam logic [1:0] DIVIDE = 2'd2;
    localparam logic [1:0] RESULT = 2'd3;

    logic [1:0] state;
    logic [2:0] active_operation;
    logic [5:0] iteration;
    logic [31:0] result_reg;

    logic [63:0] accumulator;
    logic [63:0] multiplicand;
    logic [31:0] multiplier;
    logic negate_product;
    logic [63:0] product_sum;
    logic [63:0] signed_product;

    logic [31:0] divisor;
    logic [31:0] quotient;
    logic [31:0] remainder_value;
    logic negate_quotient;
    logic negate_remainder;
    logic [32:0] shifted_remainder;
    logic [31:0] next_remainder;
    logic [31:0] next_quotient;

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

        product_sum = accumulator;
        if (multiplier[0])
            product_sum = accumulator + multiplicand;
        signed_product = negate_product ? (~product_sum + 64'd1) : product_sum;

        shifted_remainder = {remainder_value, quotient[31]};
        if (shifted_remainder >= {1'b0, divisor}) begin
            // Comparison needs 33 bits; the reduced remainder fits 32 bits.
            next_remainder = shifted_remainder[31:0] - divisor;
            next_quotient = {quotient[30:0], 1'b1};
        end else begin
            next_remainder = shifted_remainder[31:0];
            next_quotient = {quotient[30:0], 1'b0};
        end
    end

    // Cancel validity/state only. A discarded iteration may update payload,
    // but a new request reinitializes every datum used by its operation.
    always_ff @(posedge clock) begin
        if (reset || flush) state <= IDLE;
        else case (state)
            IDLE: if (req_valid) begin
                if (!operation[2]) state <= MULTIPLY;
                else if (operand_b == 0) state <= RESULT;
                else state <= DIVIDE;
            end
            MULTIPLY, DIVIDE: if (iteration == 6'd31) state <= RESULT;
            RESULT: if (result_ready) state <= IDLE;
            default: state <= IDLE;
        endcase
    end
    always_ff @(posedge clock) begin
        case (state)
            // Idle payload is unobservable. Prepare operands independently of
            // the core's request/flush control; only the state handshake starts
            // an operation, on the same edge that captures its real operands.
            IDLE: begin
                active_operation <= operation;
                iteration <= 6'b0;
                if (!operation[2]) begin
                    accumulator <= 64'b0;
                    multiplicand <= {32'b0, a_magnitude};
                    multiplier <= b_magnitude;
                    negate_product <= a_negative ^ b_negative;
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
                accumulator <= product_sum;
                multiplicand <= multiplicand << 1;
                multiplier <= multiplier >> 1;
                if (iteration == 6'd31)
                    result_reg <= active_operation == 3'b000 ? signed_product[31:0] : signed_product[63:32];
                else iteration <= iteration + 6'd1;
            end
            DIVIDE: begin
                quotient <= next_quotient;
                remainder_value <= next_remainder;
                if (iteration == 6'd31) begin
                    if (active_operation[1])
                        result_reg <= negate_remainder ? (~next_remainder + 32'd1) : next_remainder;
                    else
                        result_reg <= negate_quotient ? (~next_quotient + 32'd1) : next_quotient;
                end else iteration <= iteration + 6'd1;
            end
            default: ;
        endcase
    end
endmodule
