// Bus interface unit, uncached port side (docs/design/cpu.md 5.8, 6.6, 6.8):
// data accesses from W (in order, loads wait for the data, stores go into a
// one-entry store buffer and W continues), and 32-byte instruction-fetch
// bursts from the fetch unit (I/O-space code, the UIB). Any access waits for
// the store buffer to drain first, which keeps uncached accesses in program
// order. A posted store that ends in a bus error is reported with sb_err; the
// core takes it as an HPMC at its next instruction boundary.
//
// The cacheable line port (mem_*, cpu.md 6.8) is shared by the D-cache
// (write-backs and fills) and the I-cache (fills): the D side has priority,
// and a transaction holds the port until its last beat. The two never
// overlap in practice: I-fills are issued only when the pipeline is empty.
module pa_biu (
    input  logic        clk,
    input  logic        rst_n,
    // uncached port
    output logic        io_req,
    output logic        io_we,
    output logic [31:0] io_addr,
    output logic [7:0]  io_be,
    output logic [63:0] io_wdata,
    output logic        io_ifetch,
    output logic        io_burst,
    output logic        io_rclr,
    input  logic        io_ack,
    input  logic        io_last,
    input  logic [63:0] io_rdata,
    input  logic        io_err,
    // data access (W)
    input  logic        d_req,          // held until d_ack
    input  logic        d_we,
    input  logic [31:0] d_addr,
    input  logic [7:0]  d_be,
    input  logic [63:0] d_wdata,
    input  logic        d_rclr,
    output logic        d_ack,          // load: data valid this cycle; store: buffered
    output logic        d_err,
    output logic [63:0] d_rdata,
    output logic        sb_empty,       // store buffer drained and port idle
    output logic        sb_err,         // posted store answered with a bus error
    output logic        sb_valid_o,
    output logic [31:0] sb_addr_o,
    // cacheable line port
    output logic        mem_req, mem_we, mem_ifill,
    output logic [31:0] mem_addr,
    input  logic        mem_ack,
    output logic [63:0] mem_wdata,
    output logic        mem_wvalid,
    input  logic        mem_wready,
    input  logic [63:0] mem_rdata,
    input  logic        mem_rvalid,
    input  logic [1:0]  mem_rbeat,
    input  logic        mem_rerr,
    // D-cache line client
    input  logic        dl_req, dl_we,
    input  logic [31:0] dl_addr,
    output logic        dl_ack,
    input  logic [63:0] dl_wdata,
    input  logic        dl_wvalid,
    output logic        dl_wready,
    output logic [63:0] dl_rdata,
    output logic        dl_rvalid,
    output logic [1:0]  dl_rbeat,
    output logic        dl_rerr,
    // I-cache line client (reads only)
    input  logic        il_req,
    input  logic [31:0] il_addr,
    output logic        il_ack,
    output logic [63:0] il_rdata,
    output logic        il_rvalid,
    output logic [1:0]  il_rbeat,
    output logic        il_rerr,
    // instruction fetch burst (fetch unit)
    input  logic        f_req,          // held until f_done
    input  logic [31:0] f_addr,         // 32-byte aligned
    output logic        f_beat,         // one doubleword arrived
    output logic [1:0]  f_beat_idx,
    output logic [63:0] f_data,
    output logic        f_done,
    output logic        f_err
);
    // ---------------------------------------------------------------- line port
    // grant: 0 none, 1 D, 2 I; held from the request to the last beat
    logic [1:0] grant;
    logic [2:0] beats;
    wire d_sel = grant == 2'd1, i_sel = grant == 2'd2;
    always_comb begin
        mem_req = 1'b0; mem_we = 1'b0; mem_ifill = 1'b0; mem_addr = dl_addr; mem_wdata = dl_wdata; mem_wvalid = 1'b0;
        dl_ack = 1'b0; dl_wready = 1'b0; dl_rvalid = 1'b0; il_ack = 1'b0; il_rvalid = 1'b0;
        dl_rdata = mem_rdata; dl_rbeat = mem_rbeat; dl_rerr = mem_rerr;
        il_rdata = mem_rdata; il_rbeat = mem_rbeat; il_rerr = mem_rerr;
        if (d_sel) begin
            mem_req = dl_req && beats == 0; mem_we = dl_we; mem_addr = dl_addr;
            mem_wvalid = dl_wvalid; dl_ack = mem_ack; dl_wready = mem_wready; dl_rvalid = mem_rvalid;
        end else if (i_sel) begin
            mem_req = il_req && beats == 0; mem_ifill = 1'b1; mem_addr = il_addr;
            il_ack = mem_ack; il_rvalid = mem_rvalid;
        end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) begin grant <= 2'd0; beats <= 3'd0; end
        else begin
            case (grant)
                2'd0: begin
                    if (dl_req) grant <= 2'd1;
                    else if (il_req) grant <= 2'd2;
                    beats <= 3'd0;
                end
                default: begin
                    if (mem_ack) beats <= 3'd1;                      // transfer phase
                    if ((mem_rvalid && !mem_we) || (mem_wvalid && mem_wready)) begin
                        beats <= beats + 3'd1;
                        if (beats == 3'd4) begin grant <= 2'd0; beats <= 3'd0; end
                    end
                end
            endcase
        end
    end

    typedef enum logic [1:0] { S_IDLE, S_STORE, S_LOAD, S_FETCH } st_e;
    st_e st;
    logic        sb_valid;
    logic [31:0] sb_addr;
    logic [7:0]  sb_be;
    logic [63:0] sb_wdata;
    logic [1:0]  beat;
    logic        ferr;

    assign sb_empty   = !sb_valid && st == S_IDLE;
    assign sb_valid_o = sb_valid;
    assign sb_addr_o  = sb_addr;
    assign d_rdata    = io_rdata;

    // a store is accepted into the buffer whenever the buffer is free
    wire st_accept = d_req && d_we && !sb_valid;
    wire ld_issue  = d_req && !d_we && !sb_valid && st == S_IDLE;
    wire f_issue   = f_req && !d_req && !sb_valid && st == S_IDLE;

    always_comb begin
        d_ack = 1'b0; d_err = 1'b0;
        f_beat = 1'b0; f_done = 1'b0; f_err = 1'b0; f_beat_idx = beat; f_data = io_rdata;
        case (st)
            S_LOAD:  if (io_ack) begin d_ack = 1'b1; d_err = io_err; end
            S_FETCH: if (io_ack) begin
                f_beat = 1'b1;
                if (io_last || beat == 2'd3) begin f_done = 1'b1; f_err = ferr | io_err; end
            end
            default: ;
        endcase
        if (st_accept) d_ack = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE; sb_valid <= 1'b0; sb_err <= 1'b0;
            io_req <= 1'b0; io_we <= 1'b0; io_ifetch <= 1'b0; io_burst <= 1'b0; io_rclr <= 1'b0;
            io_addr <= 32'd0; io_be <= 8'd0; io_wdata <= 64'd0; beat <= 2'd0; ferr <= 1'b0;
            sb_addr <= 32'd0; sb_be <= 8'd0; sb_wdata <= 64'd0;
        end else begin
            sb_err <= 1'b0;
            if (st_accept) begin
                sb_valid <= 1'b1; sb_addr <= d_addr; sb_be <= d_be; sb_wdata <= d_wdata;
            end
            case (st)
                S_IDLE: begin
                    if (sb_valid) begin
                        st <= S_STORE;
                        io_req <= 1'b1; io_we <= 1'b1; io_addr <= sb_addr; io_be <= sb_be;
                        io_wdata <= sb_wdata; io_ifetch <= 1'b0; io_burst <= 1'b0; io_rclr <= 1'b0;
                    end else if (ld_issue) begin
                        st <= S_LOAD;
                        io_req <= 1'b1; io_we <= 1'b0; io_addr <= d_addr; io_be <= d_be;
                        io_ifetch <= 1'b0; io_burst <= 1'b0; io_rclr <= d_rclr;
                    end else if (f_issue) begin
                        st <= S_FETCH;
                        io_req <= 1'b1; io_we <= 1'b0; io_addr <= {f_addr[31:5], 5'd0}; io_be <= 8'hFF;
                        io_ifetch <= 1'b1; io_burst <= 1'b1; io_rclr <= 1'b0;
                        beat <= 2'd0; ferr <= 1'b0;
                    end
                end
                S_STORE: if (io_ack) begin
                    io_req <= 1'b0; io_we <= 1'b0; sb_valid <= 1'b0; st <= S_IDLE;
                    if (io_err) sb_err <= 1'b1;
                end
                S_LOAD: if (io_ack) begin
                    io_req <= 1'b0; io_rclr <= 1'b0; st <= S_IDLE;
                end
                S_FETCH: if (io_ack) begin
                    beat <= beat + 2'd1;
                    ferr <= ferr | io_err;
                    if (io_last || beat == 2'd3) begin
                        io_req <= 1'b0; io_ifetch <= 1'b0; io_burst <= 1'b0; st <= S_IDLE;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
