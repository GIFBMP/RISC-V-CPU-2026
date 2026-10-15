// Environment self-check only. This is NOT a CPU and executes no instructions.
// Read one AXI word at address zero, round-trip it through synchronous SRAM,
// and return that word through the framework's exit MMIO transaction.
module student_top (
    input  logic        clock,
    input  logic        reset,

    output logic [31:0] araddr,
    output logic        arvalid,
    input  logic        arready,
    input  logic [31:0] rdata,
    input  logic [1:0]  rresp,
    input  logic        rvalid,
    output logic        rready,

    output logic [31:0] awaddr,
    output logic        awvalid,
    input  logic        awready,
    output logic [31:0] wdata,
    output logic [3:0]  wstrb,
    output logic        wvalid,
    input  logic        wready,
    input  logic [1:0]  bresp,
    input  logic        bvalid,
    output logic        bready
);
    typedef enum logic [3:0] {
        READ_ADDRESS,
        READ_RESPONSE,
        SRAM_WRITE,
        SRAM_READ,
        SRAM_CAPTURE,
        WRITE_REQUEST,
        WRITE_RESPONSE,
        DONE,
        ERROR
    } state_t;

    state_t state;
    logic [31:0] input_word;
    logic [31:0] output_word;
    logic aw_accepted;
    logic w_accepted;
    logic ram_en;
    logic ram_we;
    logic [31:0] ram_rdata;

    // Framework-provided model; do not add its source to this file list.
    sram_fakeram #(
        .DEPTH(16),
        .WIDTH(32),
        .WRITE_GRANULARITY(8)
    ) sample_ram (
        .clk(clock),
        .en(ram_en),
        .we(ram_we),
        .wmask(4'hf),
        .addr(4'h0),
        .wdata(input_word),
        .rdata(ram_rdata)
    );

    always_comb begin
        araddr = 32'h0000_0000;
        arvalid = !reset && state == READ_ADDRESS;
        rready = !reset && state == READ_RESPONSE;

        awaddr = 32'h8000_0000;
        awvalid = !reset && state == WRITE_REQUEST && !aw_accepted;
        wdata = output_word;
        wstrb = 4'hf;
        wvalid = !reset && state == WRITE_REQUEST && !w_accepted;
        bready = !reset && state == WRITE_RESPONSE;

        ram_en = !reset && (state == SRAM_WRITE || state == SRAM_READ);
        ram_we = state == SRAM_WRITE;
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            state <= READ_ADDRESS;
            input_word <= 32'h0;
            output_word <= 32'h0;
            aw_accepted <= 1'b0;
            w_accepted <= 1'b0;
        end else begin
            case (state)
                READ_ADDRESS: begin
                    if (arvalid && arready)
                        state <= READ_RESPONSE;
                end
                READ_RESPONSE: begin
                    if (rvalid && rready) begin
                        if (rresp == 2'b00) begin
                            input_word <= rdata;
                            state <= SRAM_WRITE;
                        end else begin
                            state <= ERROR;
                        end
                    end
                end
                SRAM_WRITE: state <= SRAM_READ;
                SRAM_READ: state <= SRAM_CAPTURE;
                SRAM_CAPTURE: begin
                    // The preceding rising edge issued a synchronous read.
                    // Capture before the disabled SRAM output becomes invalid.
                    output_word <= ram_rdata;
                    state <= WRITE_REQUEST;
                end
                WRITE_REQUEST: begin
                    // AW and W may handshake in either order, or together.
                    // Each VALID stays asserted until its own handshake.
                    if (awvalid && awready)
                        aw_accepted <= 1'b1;
                    if (wvalid && wready)
                        w_accepted <= 1'b1;
                    if ((aw_accepted || (awvalid && awready)) &&
                        (w_accepted || (wvalid && wready)))
                        state <= WRITE_RESPONSE;
                end
                WRITE_RESPONSE: begin
                    if (bvalid && bready) begin
                        if (bresp == 2'b00)
                            state <= DONE;
                        else
                            state <= ERROR;
                    end
                end
                DONE: state <= DONE;
                ERROR: state <= ERROR;
                default: state <= ERROR;
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge clock) begin
        if (!reset && rvalid && rready && rresp != 2'b00)
            $fatal(1, "Environment self-check: AXI read error");
        if (!reset && bvalid && bready && bresp != 2'b00)
            $fatal(1, "Environment self-check: AXI write error");
    end
`endif
endmodule
