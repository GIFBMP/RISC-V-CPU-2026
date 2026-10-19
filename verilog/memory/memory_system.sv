module memory_system #(
    parameter integer FETCH_WIDTH = 1,
    parameter integer ICACHE_BYTES = 2048,
    parameter integer DCACHE_BYTES = 4096,
    parameter integer CACHE_LINE_BYTES = 16,
    parameter integer ICACHE_LINE_BYTES = CACHE_LINE_BYTES,
    parameter integer DCACHE_LINE_BYTES = CACHE_LINE_BYTES,
    parameter integer ICACHE_WAYS = 1,
    parameter integer DCACHE_WAYS = 4,
    parameter integer FAST_HIT_RESPONSE = 0,
    parameter integer PIPELINED_STORE_HITS = 0,
    parameter integer FAST_INSTRUCTION_RESPONSE = 0,
    parameter integer DCACHE_WRITE_BACK = 1
) (
    input  wire        clock,
    input  wire        reset,
    input  wire        i_req_valid,
    output wire        i_req_ready,
    input  wire [31:0] i_req_addr,
    output wire        i_rsp_valid,
    input  wire        i_rsp_ready,
    output wire [31:0] i_rsp_data, i_rsp_data2,
    output wire        i_rsp_error,
    input  wire        d_req_valid,
    output wire        d_req_ready,
    input  wire        d_req_write,
    input  wire [31:0] d_req_addr,
    input  wire [31:0] d_req_wdata,
    input  wire [3:0]  d_req_wstrb,
    output wire        d_rsp_valid,
    input  wire        d_rsp_ready,
    output wire [31:0] d_rsp_data,
    output wire        d_rsp_error,

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
    generate
        if (ICACHE_WAYS != 1 || (DCACHE_WAYS != 1 && DCACHE_WAYS != 2 && DCACHE_WAYS != 4) ||
            (DCACHE_WRITE_BACK != 0 && DCACHE_WRITE_BACK != 1) ||
            (DCACHE_WRITE_BACK == 0 && DCACHE_WAYS != 1)) begin : invalid_associativity
            memory_system_requires_supported_cache_configuration invalid_configuration();
        end
    endgenerate

    wire i_rd_valid, i_rd_ready, i_rd_rsp_valid, i_rd_rsp_ready, i_rd_rsp_error;
    wire d_rd_valid, d_rd_ready, d_rd_rsp_valid, d_rd_rsp_ready, d_rd_rsp_error;
    wire d_wr_valid, d_wr_ready, d_wr_rsp_valid, d_wr_rsp_ready, d_wr_rsp_error;
    wire [31:0] i_rd_addr, i_rd_rsp_data, d_rd_addr, d_rd_rsp_data;
    wire [31:0] d_wr_addr, d_wr_data;
    wire [3:0] d_wr_strb;
    icache_pipeline #(
        .FETCH_WIDTH(FETCH_WIDTH),
        .CACHE_BYTES(ICACHE_BYTES), .LINE_BYTES(ICACHE_LINE_BYTES),
        .FAST_INSTRUCTION_RESPONSE(FAST_INSTRUCTION_RESPONSE)
    ) instruction_cache (
        .clock(clock), .reset(reset),
        .req_valid(i_req_valid), .req_ready(i_req_ready), .req_addr(i_req_addr),
        .rsp_valid(i_rsp_valid), .rsp_ready(i_rsp_ready),
        .rsp_data(i_rsp_data), .rsp_data2(i_rsp_data2), .rsp_error(i_rsp_error),
        .mem_rd_valid(i_rd_valid), .mem_rd_ready(i_rd_ready), .mem_rd_addr(i_rd_addr),
        .mem_rd_rsp_valid(i_rd_rsp_valid), .mem_rd_rsp_ready(i_rd_rsp_ready),
        .mem_rd_rsp_data(i_rd_rsp_data), .mem_rd_rsp_error(i_rd_rsp_error)
    );

    generate if (DCACHE_WRITE_BACK == 1) begin : write_back
    dcache_writeback #(
        .CACHE_BYTES(DCACHE_BYTES), .LINE_BYTES(DCACHE_LINE_BYTES), .WAYS(DCACHE_WAYS),
        .FAST_HIT_RESPONSE(FAST_HIT_RESPONSE), .PIPELINED_STORE_HITS(PIPELINED_STORE_HITS)
    ) data_cache (
        .clock(clock), .reset(reset),
        .req_valid(d_req_valid), .req_ready(d_req_ready), .req_write(d_req_write),
        .req_addr(d_req_addr), .req_wdata(d_req_wdata), .req_wstrb(d_req_wstrb),
        .rsp_valid(d_rsp_valid), .rsp_ready(d_rsp_ready),
        .rsp_data(d_rsp_data), .rsp_error(d_rsp_error),
        .mem_rd_valid(d_rd_valid), .mem_rd_ready(d_rd_ready), .mem_rd_addr(d_rd_addr),
        .mem_rd_rsp_valid(d_rd_rsp_valid), .mem_rd_rsp_ready(d_rd_rsp_ready),
        .mem_rd_rsp_data(d_rd_rsp_data), .mem_rd_rsp_error(d_rd_rsp_error),
        .mem_wr_valid(d_wr_valid), .mem_wr_ready(d_wr_ready), .mem_wr_addr(d_wr_addr),
        .mem_wr_data(d_wr_data), .mem_wr_strb(d_wr_strb),
        .mem_wr_rsp_valid(d_wr_rsp_valid), .mem_wr_rsp_ready(d_wr_rsp_ready),
        .mem_wr_rsp_error(d_wr_rsp_error)
    );
    end else begin : write_through
    blocking_cache #(
        .CACHE_BYTES(DCACHE_BYTES), .LINE_BYTES(DCACHE_LINE_BYTES), .READ_ONLY(0)
    ) data_cache (
        .clock(clock), .reset(reset),
        .req_valid(d_req_valid), .req_ready(d_req_ready), .req_write(d_req_write),
        .req_addr(d_req_addr), .req_wdata(d_req_wdata), .req_wstrb(d_req_wstrb),
        .rsp_valid(d_rsp_valid), .rsp_ready(d_rsp_ready),
        .rsp_data(d_rsp_data), .rsp_error(d_rsp_error),
        .mem_rd_valid(d_rd_valid), .mem_rd_ready(d_rd_ready), .mem_rd_addr(d_rd_addr),
        .mem_rd_rsp_valid(d_rd_rsp_valid), .mem_rd_rsp_ready(d_rd_rsp_ready),
        .mem_rd_rsp_data(d_rd_rsp_data), .mem_rd_rsp_error(d_rd_rsp_error),
        .mem_wr_valid(d_wr_valid), .mem_wr_ready(d_wr_ready), .mem_wr_addr(d_wr_addr),
        .mem_wr_data(d_wr_data), .mem_wr_strb(d_wr_strb),
        .mem_wr_rsp_valid(d_wr_rsp_valid), .mem_wr_rsp_ready(d_wr_rsp_ready),
        .mem_wr_rsp_error(d_wr_rsp_error)
    );

    end endgenerate

    axi_lite_bridge bridge (
        .clock(clock), .reset(reset),
        .i_rd_valid(i_rd_valid), .i_rd_ready(i_rd_ready), .i_rd_addr(i_rd_addr),
        .i_rd_rsp_valid(i_rd_rsp_valid), .i_rd_rsp_ready(i_rd_rsp_ready),
        .i_rd_rsp_data(i_rd_rsp_data), .i_rd_rsp_error(i_rd_rsp_error),
        .d_rd_valid(d_rd_valid), .d_rd_ready(d_rd_ready), .d_rd_addr(d_rd_addr),
        .d_rd_rsp_valid(d_rd_rsp_valid), .d_rd_rsp_ready(d_rd_rsp_ready),
        .d_rd_rsp_data(d_rd_rsp_data), .d_rd_rsp_error(d_rd_rsp_error),
        .d_wr_valid(d_wr_valid), .d_wr_ready(d_wr_ready), .d_wr_addr(d_wr_addr),
        .d_wr_data(d_wr_data), .d_wr_strb(d_wr_strb),
        .d_wr_rsp_valid(d_wr_rsp_valid), .d_wr_rsp_ready(d_wr_rsp_ready),
        .d_wr_rsp_error(d_wr_rsp_error),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready)
    );
endmodule
