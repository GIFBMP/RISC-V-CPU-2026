// Course interface. Defaults describe the V3 single-issue CPU.
module student_top #(
    parameter integer ROB_DEPTH = 16,
    parameter integer PRF_SIZE = 48,
    parameter integer IQ_DEPTH = 8,
    parameter integer LSQ_DEPTH = 8,
    parameter integer ICACHE_BYTES = 2048,
    parameter integer DCACHE_BYTES = 4096,
    parameter integer CACHE_LINE_BYTES = 16,
    parameter integer ICACHE_WAYS = 1,
    parameter integer DCACHE_WAYS = 4,
    parameter integer DCACHE_WRITE_BACK = 1,
    parameter integer ISSUE_WIDTH = 1,
    parameter integer FETCH_QUEUE_DEPTH = 8,
    parameter integer FETCH_OUTSTANDING = 4,
    parameter integer BTB_ENTRIES = 64,
    parameter integer PREDICT_ENABLE = 1,
    parameter integer TRACE = 0
) (
    input  logic clock,
    input  logic reset,
    output logic [31:0] araddr,
    output logic arvalid,
    input  logic arready,
    input  logic [31:0] rdata,
    input  logic [1:0] rresp,
    input  logic rvalid,
    output logic rready,
    output logic [31:0] awaddr,
    output logic awvalid,
    input  logic awready,
    output logic [31:0] wdata,
    output logic [3:0] wstrb,
    output logic wvalid,
    input  logic wready,
    input  logic [1:0] bresp,
    input  logic bvalid,
    output logic bready
);
    logic i_req_valid, i_req_ready, i_rsp_valid, i_rsp_ready, i_rsp_error;
    logic [31:0] i_req_addr, i_rsp_data;
    logic d_req_valid, d_req_ready, d_req_write;
    logic d_rsp_valid, d_rsp_ready, d_rsp_error;
    logic [31:0] d_req_addr, d_req_wdata, d_rsp_data;
    logic [3:0] d_req_wstrb;

    cpu_core #(
        .ROB_DEPTH(ROB_DEPTH), .PRF_SIZE(PRF_SIZE), .IQ_DEPTH(IQ_DEPTH),
        .LSQ_DEPTH(LSQ_DEPTH), .ISSUE_WIDTH(ISSUE_WIDTH), .TRACE(TRACE),
        .FETCH_QUEUE_DEPTH(FETCH_QUEUE_DEPTH), .FETCH_OUTSTANDING(FETCH_OUTSTANDING),
        .BTB_ENTRIES(BTB_ENTRIES), .PREDICT_ENABLE(PREDICT_ENABLE)
    ) core (
        .clock(clock), .reset(reset),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(i_rsp_error),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready),
        .d_req_write(d_req_write), .d_req_addr(d_req_addr),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready),
        .d_rsp_data(d_rsp_data), .d_rsp_error(d_rsp_error)
    );

    memory_system #(
        .ICACHE_BYTES(ICACHE_BYTES), .DCACHE_BYTES(DCACHE_BYTES),
        .CACHE_LINE_BYTES(CACHE_LINE_BYTES),
        .ICACHE_WAYS(ICACHE_WAYS), .DCACHE_WAYS(DCACHE_WAYS),
        .DCACHE_WRITE_BACK(DCACHE_WRITE_BACK)
    ) memory (
        .clock(clock), .reset(reset),
        .i_req_valid(i_req_valid), .i_req_ready(i_req_ready), .i_req_addr(i_req_addr),
        .i_rsp_valid(i_rsp_valid), .i_rsp_ready(i_rsp_ready),
        .i_rsp_data(i_rsp_data), .i_rsp_error(i_rsp_error),
        .d_req_valid(d_req_valid), .d_req_ready(d_req_ready),
        .d_req_write(d_req_write), .d_req_addr(d_req_addr),
        .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb),
        .d_rsp_valid(d_rsp_valid), .d_rsp_ready(d_rsp_ready),
        .d_rsp_data(d_rsp_data), .d_rsp_error(d_rsp_error),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready)
    );
endmodule
