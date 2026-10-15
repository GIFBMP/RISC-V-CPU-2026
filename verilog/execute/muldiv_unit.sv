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
        req_ready = state == IDLE && !reset && !flush;
        result_valid = state == RESULT && !reset && !flush;
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

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            state <= IDLE;
            active_operation <= 3'b0;
            iteration <= 6'b0;
            result_reg <= 32'b0;
            accumulator <= 64'b0;
            multiplicand <= 64'b0;
            multiplier <= 32'b0;
            negate_product <= 1'b0;
            divisor <= 32'b0;
            quotient <= 32'b0;
            remainder_value <= 32'b0;
            negate_quotient <= 1'b0;
            negate_remainder <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    if (req_valid && req_ready) begin
                        active_operation <= operation;
                        iteration <= 6'b0;
                        if (!operation[2]) begin
                            accumulator <= 64'b0;
                            multiplicand <= {32'b0, a_magnitude};
                            multiplier <= b_magnitude;
                            negate_product <= a_negative ^ b_negative;
                            state <= MULTIPLY;
                        end else if (operand_b == 32'b0) begin
                            // DIV[U] by zero is all ones; REM[U] returns rs1.
                            result_reg <= operation[1] ? operand_a : 32'hffff_ffff;
                            state <= RESULT;
                        end else begin
                            divisor <= b_magnitude;
                            quotient <= a_magnitude;
                            remainder_value <= 32'b0;
                            negate_quotient <= a_negative ^ b_negative;
                            negate_remainder <= a_negative;
                            state <= DIVIDE;
                        end
                    end
                end
                MULTIPLY: begin
                    accumulator <= product_sum;
                    multiplicand <= multiplicand << 1;
                    multiplier <= multiplier >> 1;
                    if (iteration == 6'd31) begin
                        result_reg <= active_operation == 3'b000 ?
                                      signed_product[31:0] : signed_product[63:32];
                        state <= RESULT;
                    end else begin
                        iteration <= iteration + 6'd1;
                    end
                end
                DIVIDE: begin
                    quotient <= next_quotient;
                    remainder_value <= next_remainder;
                    if (iteration == 6'd31) begin
                        if (active_operation[1])
                            result_reg <= negate_remainder ?
                                          (~next_remainder + 32'd1) : next_remainder;
                        else
                            result_reg <= negate_quotient ?
                                          (~next_quotient + 32'd1) : next_quotient;
                        state <= RESULT;
                    end else begin
                        iteration <= iteration + 6'd1;
                    end
                end
                RESULT: begin
                    if (result_valid && result_ready)
                        state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
