// One CPU request at a time. Data lives in the framework's synchronous 1RW SRAM.
// Stores are write-through/no-write-allocate and acknowledge only after both the
// external response and any local hit update. There is deliberately no flush:
// every accepted request drains; the core owns speculative-result cancellation.
module blocking_cache #(
    parameter integer CACHE_BYTES = 2048,
    parameter integer LINE_BYTES = 16,
    parameter integer READ_ONLY = 0
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [31:0] req_addr,
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wstrb,
    output wire        rsp_valid,
    input  wire        rsp_ready,
    output wire [31:0] rsp_data,
    output wire        rsp_error,

    output wire        mem_rd_valid,
    input  wire        mem_rd_ready,
    output wire [31:0] mem_rd_addr,
    input  wire        mem_rd_rsp_valid,
    output wire        mem_rd_rsp_ready,
    input  wire [31:0] mem_rd_rsp_data,
    input  wire        mem_rd_rsp_error,
    output wire        mem_wr_valid,
    input  wire        mem_wr_ready,
    output wire [31:0] mem_wr_addr,
    output wire [31:0] mem_wr_data,
    output wire [3:0]  mem_wr_strb,
    input  wire        mem_wr_rsp_valid,
    output wire        mem_wr_rsp_ready,
    input  wire        mem_wr_rsp_error
);
    localparam integer WORDS = (CACHE_BYTES >= 4) ? CACHE_BYTES / 4 : 1;
    localparam integer LINES = (LINE_BYTES >= 4 && CACHE_BYTES >= LINE_BYTES)
        ? CACHE_BYTES / LINE_BYTES : 1;
    localparam integer LINE_WORDS = (LINE_BYTES >= 4) ? LINE_BYTES / 4 : 1;
    localparam integer WORD_BITS = (WORDS > 1) ? $clog2(WORDS) : 1;
    localparam integer SET_BITS = (LINES > 1) ? $clog2(LINES) : 1;
    localparam integer FILL_BITS = (LINE_WORDS > 1) ? $clog2(LINE_WORDS) : 1;
    localparam integer LINE_OFFSET = (LINE_BYTES >= 4) ? $clog2(LINE_BYTES) : 2;
    localparam integer CACHE_OFFSET = (CACHE_BYTES >= 4) ? $clog2(CACHE_BYTES) : 2;
    localparam integer TAG_BITS = 32 - CACHE_OFFSET;

    // An illegal configuration also fails synthesis elaboration, not just a
    // simulation assertion. The nonexistent module is absent for valid shapes.
    generate
        if (CACHE_BYTES < 4 || CACHE_BYTES > 2097152 || LINE_BYTES < 4 ||
            LINE_BYTES > CACHE_BYTES || (CACHE_BYTES & (CACHE_BYTES - 1)) != 0 ||
            (LINE_BYTES & (LINE_BYTES - 1)) != 0 ||
            (READ_ONLY != 0 && READ_ONLY != 1)) begin : invalid_parameters
            blocking_cache_requires_power_of_two_sizes invalid_configuration();
        end
    endgenerate

    localparam [3:0] IDLE = 4'd0, LOOKUP = 4'd1, RAM_CAPTURE = 4'd2,
        READ_REQUEST = 4'd3, READ_RESPONSE = 4'd4, FILL_WRITE = 4'd5,
        WRITE_REQUEST = 4'd6, WRITE_RESPONSE = 4'd7, STORE_WRITE = 4'd8,
        RESPONSE = 4'd9;

    reg [3:0] state;
    reg [31:0] address;
    reg [31:0] store_data;
    reg [3:0] store_strobe;
    reg is_write;
    reg is_refill;
    reg store_hit;
    reg [FILL_BITS-1:0] fill_word;
    reg [31:0] fill_data;
    reg [31:0] requested_data;
    reg [31:0] response_data;
    reg response_error;
    reg [LINES-1:0] valid_bits;
    reg [TAG_BITS-1:0] tags [0:LINES-1];

    wire [SET_BITS-1:0] set_index =
        SET_BITS'((address >> LINE_OFFSET) & (LINES - 1));
    wire [TAG_BITS-1:0] address_tag = address[31:CACHE_OFFSET];
    wire [WORD_BITS-1:0] word_index = WORD_BITS'((address >> 2) & (WORDS - 1));
    wire [FILL_BITS-1:0] requested_word = FILL_BITS'((address >> 2) & (LINE_WORDS - 1));
    wire [WORD_BITS-1:0] refill_word_index =
        (word_index & ~WORD_BITS'(LINE_WORDS - 1)) | WORD_BITS'(fill_word);
    wire cacheable = address[31:28] == 4'h0;
    wire aligned = address[1:0] == 2'b00;
    wire hit = valid_bits[set_index] && tags[set_index] == address_tag;

    reg ram_en;
    reg ram_we;
    reg [WORD_BITS-1:0] ram_addr;
    reg [31:0] ram_wdata;
    reg [3:0] ram_wmask;
    wire [31:0] ram_rdata;

    sram_fakeram #(
        .DEPTH(WORDS), .WIDTH(32), .WRITE_GRANULARITY(8)
    ) data_array (
        .clk(clock), .en(ram_en), .we(ram_we), .wmask(ram_wmask),
        .addr(ram_addr), .wdata(ram_wdata), .rdata(ram_rdata)
    );

    assign req_ready = !reset && state == IDLE;
    assign rsp_valid = !reset && state == RESPONSE;
    assign rsp_data = response_data;
    assign rsp_error = response_error;
    assign mem_rd_valid = !reset && state == READ_REQUEST;
    assign mem_rd_addr = is_refill
        ? ((address & ~32'(LINE_BYTES - 1)) | (32'(fill_word) << 2)) : address;
    assign mem_rd_rsp_ready = !reset && state == READ_RESPONSE;
    assign mem_wr_valid = !reset && state == WRITE_REQUEST;
    assign mem_wr_addr = address;
    assign mem_wr_data = store_data;
    assign mem_wr_strb = store_strobe;
    assign mem_wr_rsp_ready = !reset && state == WRITE_RESPONSE;

    always @* begin
        ram_en = 1'b0;
        ram_we = 1'b0;
        ram_addr = word_index;
        ram_wdata = store_data;
        ram_wmask = store_strobe;
        if (!reset) begin
            case (state)
                LOOKUP: ram_en = !is_write && aligned && cacheable && hit;
                FILL_WRITE: begin
                    ram_en = 1'b1;
                    ram_we = 1'b1;
                    ram_addr = refill_word_index;
                    ram_wdata = fill_data;
                    ram_wmask = 4'hf;
                end
                STORE_WRITE: begin
                    ram_en = 1'b1;
                    ram_we = 1'b1;
                end
                default: begin end
            endcase
        end
    end

    always @(posedge clock) begin
        if (reset) begin
            state <= IDLE;
            address <= 32'b0;
            store_data <= 32'b0;
            store_strobe <= 4'b0;
            is_write <= 1'b0;
            is_refill <= 1'b0;
            store_hit <= 1'b0;
            fill_word <= {FILL_BITS{1'b0}};
            fill_data <= 32'b0;
            requested_data <= 32'b0;
            response_data <= 32'b0;
            response_error <= 1'b0;
            valid_bits <= {LINES{1'b0}};
        end else begin
            case (state)
                IDLE: if (req_valid && req_ready) begin
                    address <= req_addr;
                    store_data <= req_wdata;
                    store_strobe <= req_wstrb;
                    is_write <= req_write;
                    response_data <= 32'b0;
                    response_error <= 1'b0;
                    state <= LOOKUP;
                end
                LOOKUP: begin
                    if (!aligned || (is_write && READ_ONLY != 0)) begin
                        response_error <= 1'b1;
                        state <= RESPONSE;
                    end else if (is_write) begin
                        store_hit <= cacheable && hit;
                        state <= WRITE_REQUEST;
                    end else if (cacheable && hit) begin
                        // This edge issues the SRAM read; capture next edge.
                        state <= RAM_CAPTURE;
                    end else begin
                        is_refill <= cacheable;
                        fill_word <= {FILL_BITS{1'b0}};
                        if (cacheable)
                            valid_bits[set_index] <= 1'b0;
                        state <= READ_REQUEST;
                    end
                end
                RAM_CAPTURE: begin
                    response_data <= ram_rdata;
                    state <= RESPONSE;
                end
                READ_REQUEST: if (mem_rd_valid && mem_rd_ready)
                    state <= READ_RESPONSE;
                READ_RESPONSE: if (mem_rd_rsp_valid && mem_rd_rsp_ready) begin
                    if (mem_rd_rsp_error) begin
                        // The victim was invalidated before refill started.
                        // Partial data never becomes a valid cache line.
                        response_error <= 1'b1;
                        state <= RESPONSE;
                    end else if (is_refill) begin
                        fill_data <= mem_rd_rsp_data;
                        if (fill_word == requested_word)
                            requested_data <= mem_rd_rsp_data;
                        state <= FILL_WRITE;
                    end else begin
                        response_data <= mem_rd_rsp_data;
                        state <= RESPONSE;
                    end
                end
                FILL_WRITE: begin
                    if (fill_word == FILL_BITS'(LINE_WORDS - 1)) begin
                        // SRAM accepts the final word on this same edge.
                        tags[set_index] <= address_tag;
                        valid_bits[set_index] <= 1'b1;
                        response_data <= requested_data;
                        state <= RESPONSE;
                    end else begin
                        fill_word <= fill_word + 1'b1;
                        state <= READ_REQUEST;
                    end
                end
                WRITE_REQUEST: if (mem_wr_valid && mem_wr_ready)
                    state <= WRITE_RESPONSE;
                WRITE_RESPONSE: if (mem_wr_rsp_valid && mem_wr_rsp_ready) begin
                    if (mem_wr_rsp_error) begin
                        response_error <= 1'b1;
                        if (store_hit)
                            valid_bits[set_index] <= 1'b0;
                        state <= RESPONSE;
                    end else if (store_hit) begin
                        state <= STORE_WRITE;
                    end else begin
                        // Write-no-allocate and MMIO need no local SRAM write.
                        state <= RESPONSE;
                    end
                end
                STORE_WRITE: state <= RESPONSE;
                RESPONSE: if (rsp_valid && rsp_ready)
                    state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
