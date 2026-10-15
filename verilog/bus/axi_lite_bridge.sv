// Pipelined I/D AXI reads. A registered AR slot reserves one of 16 credits;
// accepted AR owners are queued until their ordered R response is consumed.
// Fair arbitration happens at each internal request acceptance. Writes are
// independent and still allow only one outstanding AW/W/B transaction.
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
    localparam [1:0] WRITE_IDLE = 2'd0, WRITE_SEND = 2'd1, WRITE_ACK = 2'd2;
    reg [1:0] write_state;
    reg ar_pending, ar_owner_d;
    reg [15:0] read_owners;
    reg [3:0] read_head, read_tail;
    reg [4:0] read_count;
    reg prefer_d;
    reg [31:0] read_address;
    reg [31:0] write_address;
    reg [31:0] write_data;
    reg [3:0] write_strobe;
    reg aw_sent;
    reg w_sent;

    wire grant_i = i_rd_valid && (!d_rd_valid || !prefer_d);
    wire grant_d = d_rd_valid && (!i_rd_valid || prefer_d);
    wire read_owner_d = read_owners[read_head];
    wire ar_fire = arvalid && arready;
    wire r_fire = rvalid && rready;
    wire [5:0] reserved_reads = {1'b0, read_count} + {5'b0, ar_pending};
    wire ar_slot_ready = (!ar_pending || arready) && (reserved_reads < 6'd16 || r_fire);
    assign i_rd_ready = !reset && ar_slot_ready && grant_i;
    assign d_rd_ready = !reset && ar_slot_ready && grant_d;
    assign arvalid = !reset && ar_pending;
    assign araddr = read_address;
    assign rready = !reset && read_count != 0 &&
        (read_owner_d ? d_rd_rsp_ready : i_rd_rsp_ready);
    assign i_rd_rsp_valid = !reset && read_count != 0 && !read_owner_d && rvalid;
    assign d_rd_rsp_valid = !reset && read_count != 0 && read_owner_d && rvalid;
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
            ar_pending <= 1'b0;
            ar_owner_d <= 1'b0;
            read_owners <= 16'b0;
            read_head <= 4'b0;
            read_tail <= 4'b0;
            read_count <= 5'b0;
            write_state <= WRITE_IDLE;
            prefer_d <= 1'b0;
            read_address <= 32'b0;
            write_address <= 32'b0;
            write_data <= 32'b0;
            write_strobe <= 4'b0;
            aw_sent <= 1'b0;
            w_sent <= 1'b0;
        end else begin
            if (ar_fire) begin
                read_owners[read_tail] <= ar_owner_d;
                read_tail <= read_tail + 1'b1;
            end
            if (r_fire)
                read_head <= read_head + 1'b1;
            case ({ar_fire, r_fire})
                2'b10: read_count <= read_count + 1'b1;
                2'b01: read_count <= read_count - 1'b1;
                default: begin end
            endcase
            if (i_rd_valid && i_rd_ready) begin
                read_address <= i_rd_addr;
                ar_owner_d <= 1'b0;
                ar_pending <= 1'b1;
                prefer_d <= 1'b1;
            end else if (d_rd_valid && d_rd_ready) begin
                read_address <= d_rd_addr;
                ar_owner_d <= 1'b1;
                ar_pending <= 1'b1;
                prefer_d <= 1'b0;
            end else if (ar_fire)
                ar_pending <= 1'b0;
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
