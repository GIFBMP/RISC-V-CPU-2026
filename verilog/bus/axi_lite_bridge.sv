// I/D read arbitration with one outstanding AXI read. The chosen owner/address
// remain latched through response acceptance. Writes progress independently.
module axi_lite_bridge (
    input  wire        clock,
    input  wire        reset,
    input  wire        i_rd_valid,
    output wire        i_rd_ready,
    input  wire [31:0] i_rd_addr,
    output wire        i_rd_rsp_valid,
    input  wire        i_rd_rsp_ready,
    output wire [31:0] i_rd_rsp_data,
    output wire        i_rd_rsp_error,
    input  wire        d_rd_valid,
    output wire        d_rd_ready,
    input  wire [31:0] d_rd_addr,
    output wire        d_rd_rsp_valid,
    input  wire        d_rd_rsp_ready,
    output wire [31:0] d_rd_rsp_data,
    output wire        d_rd_rsp_error,
    input  wire        d_wr_valid,
    output wire        d_wr_ready,
    input  wire [31:0] d_wr_addr,
    input  wire [31:0] d_wr_data,
    input  wire [3:0]  d_wr_strb,
    output wire        d_wr_rsp_valid,
    input  wire        d_wr_rsp_ready,
    output wire        d_wr_rsp_error,

    output wire [31:0] araddr,
    output wire        arvalid,
    input  wire        arready,
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,
    input  wire        rvalid,
    output wire        rready,
    output wire [31:0] awaddr,
    output wire        awvalid,
    input  wire        awready,
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,
    output wire        wvalid,
    input  wire        wready,
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready
);
    localparam [1:0] READ_IDLE = 2'd0, READ_ADDRESS = 2'd1, READ_DATA = 2'd2;
    localparam [1:0] WRITE_IDLE = 2'd0, WRITE_SEND = 2'd1, WRITE_ACK = 2'd2;
    reg [1:0] read_state;
    reg [1:0] write_state;
    reg read_owner_d;
    reg prefer_d;
    reg [31:0] read_address;
    reg [31:0] write_address;
    reg [31:0] write_data;
    reg [3:0] write_strobe;
    reg aw_sent;
    reg w_sent;

    wire grant_i = i_rd_valid && (!d_rd_valid || !prefer_d);
    wire grant_d = d_rd_valid && (!i_rd_valid || prefer_d);
    assign i_rd_ready = !reset && read_state == READ_IDLE && grant_i;
    assign d_rd_ready = !reset && read_state == READ_IDLE && grant_d;
    assign arvalid = !reset && read_state == READ_ADDRESS;
    assign araddr = read_address;
    assign rready = !reset && read_state == READ_DATA &&
        (read_owner_d ? d_rd_rsp_ready : i_rd_rsp_ready);
    assign i_rd_rsp_valid = !reset && read_state == READ_DATA && !read_owner_d && rvalid;
    assign d_rd_rsp_valid = !reset && read_state == READ_DATA && read_owner_d && rvalid;
    assign i_rd_rsp_data = rdata;
    assign d_rd_rsp_data = rdata;
    assign i_rd_rsp_error = rresp != 2'b00;
    assign d_rd_rsp_error = rresp != 2'b00;

    assign d_wr_ready = !reset && write_state == WRITE_IDLE;
    assign awvalid = !reset && write_state == WRITE_SEND && !aw_sent;
    assign wvalid = !reset && write_state == WRITE_SEND && !w_sent;
    assign awaddr = write_address;
    assign wdata = write_data;
    assign wstrb = write_strobe;
    assign bready = !reset && write_state == WRITE_ACK && d_wr_rsp_ready;
    assign d_wr_rsp_valid = !reset && write_state == WRITE_ACK && bvalid;
    assign d_wr_rsp_error = bresp != 2'b00;

    always @(posedge clock) begin
        if (reset) begin
            read_state <= READ_IDLE;
            write_state <= WRITE_IDLE;
            read_owner_d <= 1'b0;
            prefer_d <= 1'b0;
            read_address <= 32'b0;
            write_address <= 32'b0;
            write_data <= 32'b0;
            write_strobe <= 4'b0;
            aw_sent <= 1'b0;
            w_sent <= 1'b0;
        end else begin
            case (read_state)
                READ_IDLE: begin
                    if (i_rd_valid && i_rd_ready) begin
                        read_address <= i_rd_addr;
                        read_owner_d <= 1'b0;
                        prefer_d <= 1'b1;
                        read_state <= READ_ADDRESS;
                    end else if (d_rd_valid && d_rd_ready) begin
                        read_address <= d_rd_addr;
                        read_owner_d <= 1'b1;
                        prefer_d <= 1'b0;
                        read_state <= READ_ADDRESS;
                    end
                end
                READ_ADDRESS: if (arvalid && arready)
                    read_state <= READ_DATA;
                READ_DATA: if (rvalid && rready)
                    read_state <= READ_IDLE;
                default: read_state <= READ_IDLE;
            endcase
            case (write_state)
                WRITE_IDLE: if (d_wr_valid && d_wr_ready) begin
                    write_address <= d_wr_addr;
                    write_data <= d_wr_data;
                    write_strobe <= d_wr_strb;
                    aw_sent <= 1'b0;
                    w_sent <= 1'b0;
                    write_state <= WRITE_SEND;
                end
                WRITE_SEND: begin
                    if (awvalid && awready)
                        aw_sent <= 1'b1;
                    if (wvalid && wready)
                        w_sent <= 1'b1;
                    if ((aw_sent || (awvalid && awready)) &&
                        (w_sent || (wvalid && wready)))
                        write_state <= WRITE_ACK;
                end
                WRITE_ACK: if (bvalid && bready)
                    write_state <= WRITE_IDLE;
                default: write_state <= WRITE_IDLE;
            endcase
        end
    end
endmodule
