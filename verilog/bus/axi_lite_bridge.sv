// Pipelined I/D AXI reads. A registered AR slot reserves one of 16 credits;
// accepted AR owners are queued until their ordered R response is consumed.
// Fair arbitration happens at each internal request acceptance. Writes are
// independent, with sixteen ordered write credits and separate AW/W progress.
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
    reg ar_pending, ar_owner_d;
    reg [15:0] read_owners;
    reg [3:0] read_head, read_tail;
    reg [4:0] read_count;
    reg prefer_d;
    reg [31:0] read_address;
    reg [31:0] write_address [0:15], write_data [0:15];
    reg [3:0] write_strobe [0:15];
    reg [3:0] write_tail, aw_head, w_head;
    reg [4:0] write_count, aw_count, w_count;
    wire aw_fire = awvalid && awready;
    wire w_fire = wvalid && wready;
    wire b_fire = bvalid && bready;
    wire write_push = d_wr_valid && d_wr_ready;
    wire sent_pair = write_count > aw_count && write_count > w_count;
    reg [31:0] selected_awaddr, selected_wdata;
    reg [3:0] selected_wstrb;

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

    assign d_wr_ready = !reset && (write_count < 5'd16 || b_fire);
    assign awvalid = !reset && aw_count != 0;
    assign wvalid = !reset && w_count != 0;
    assign awaddr = selected_awaddr;
    assign wdata = selected_wdata;
    assign wstrb = selected_wstrb;
    assign bready = !reset && sent_pair && d_wr_rsp_ready;
    assign d_wr_rsp_valid = !reset && sent_pair && bvalid;
    assign d_wr_rsp_error = bresp != 2'b00;
    always @* begin
        selected_awaddr = 0;
        selected_wdata = 0;
        selected_wstrb = 0;
        for (integer slot = 0; slot < 16; slot = slot + 1) begin
            selected_awaddr = selected_awaddr | (write_address[slot] & {32{aw_head == 4'(slot)}});
            selected_wdata = selected_wdata | (write_data[slot] & {32{w_head == 4'(slot)}});
            selected_wstrb = selected_wstrb | (write_strobe[slot] & {4{w_head == 4'(slot)}});
        end
    end
    generate
        for (genvar slot = 0; slot < 16; slot = slot + 1) begin : write_slots
            always @(posedge clock) begin
                if (write_push && write_tail == 4'(slot)) begin
                    write_address[slot] <= d_wr_addr;
                    write_data[slot] <= d_wr_data;
                    write_strobe[slot] <= d_wr_strb;
                end
            end
        end
    endgenerate
    always @(posedge clock) begin
        if (reset) begin
            write_tail <= 0;
            aw_head <= 0;
            w_head <= 0;
            write_count <= 0;
            aw_count <= 0;
            w_count <= 0;
        end else begin
            if (write_push) write_tail <= write_tail + 1'b1;
            if (aw_fire) aw_head <= aw_head + 1'b1;
            if (w_fire) w_head <= w_head + 1'b1;
            case ({write_push, b_fire})
                2'b10: write_count <= write_count + 1'b1;
                2'b01: write_count <= write_count - 1'b1;
                default: ;
            endcase
            case ({write_push, aw_fire})
                2'b10: aw_count <= aw_count + 1'b1;
                2'b01: aw_count <= aw_count - 1'b1;
                default: ;
            endcase
            case ({write_push, w_fire})
                2'b10: w_count <= w_count + 1'b1;
                2'b01: w_count <= w_count - 1'b1;
                default: ;
            endcase
        end
    end

    always @(posedge clock) begin
        if (reset) begin
            ar_pending <= 1'b0;
            ar_owner_d <= 1'b0;
            read_owners <= 16'b0;
            read_head <= 4'b0;
            read_tail <= 4'b0;
            read_count <= 5'b0;
            prefer_d <= 1'b0;
            read_address <= 32'b0;
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
        end
    end
`ifndef SYNTHESIS
    always @(posedge clock) if (!reset) begin
        assert (write_count <= 16 && aw_count <= write_count && w_count <= write_count);
        assert (read_count <= 16 && reserved_reads <= 16);
    end
`endif
endmodule
