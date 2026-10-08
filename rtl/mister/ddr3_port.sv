// The machine's DDR3 clients on MiSTer's DDRAM bridge (docs/design/system.md
// 7, 8): the boot ROM store (written by the ROM loader during the download,
// read by the MIOC a 32-byte line at a time) and the ECC check store (one
// 32-bit word per RAM line). Clocked by the machine's clock (DDRAM_CLK =
// clk); one transaction at a time; the loader first, then the check store,
// then ROM reads. VRAM and the RAM above 128 MB are to come.
//
// Map inside the core's window (DDR3 bytes 0x3000_0000-0x3FFF_FFFF; the
// bridge counts 64-bit words):
//   0x3000_0000  boot ROM, 256 KB, as the loader assembled it (big-endian)
//   0x3100_0000  check store, 32 MB = 8M lines: line L in word L/2, the
//                even line in bits 63:32
//   0x3200_0000  the debug event ring (rtl/mister/trace_ddr3.sv): 32-byte
//                records, written last of all clients
module ddr3_port (
    input  logic        clk,
    input  logic        rst,
    // ROM loader writes (one doubleword at a time; ld_busy holds the loader)
    input  logic        ld_wr,
    input  logic [17:3] ld_addr,
    input  logic [63:0] ld_data,
    output logic        ld_busy,
    // ROM line reads (rtl/mioc.sv rom_*)
    input  logic        rom_req,
    input  logic [17:5] rom_addr,
    output logic        rom_ack,
    output logic        rom_rvalid,
    output logic [63:0] rom_rdata,
    // check store (rtl/mioc.sv chk_*)
    input  logic        chk_req,
    input  logic        chk_we,
    input  logic [22:0] chk_addr,
    input  logic [3:0]  chk_be,
    input  logic [31:0] chk_wdata,
    output logic        chk_ack,
    output logic [31:0] chk_rdata,
    // debug records (rtl/mister/trace_ddr3.sv): one 4-beat write each
    input  logic        tr_req,
    input  logic [15:0] tr_idx,
    input  logic [255:0] tr_data,
    output logic        tr_ack,
    // MiSTer DDRAM bridge
    input  logic        DDRAM_BUSY,
    output logic [7:0]  DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    input  logic [63:0] DDRAM_DOUT,
    input  logic        DDRAM_DOUT_READY,
    output logic        DDRAM_RD,
    output logic [63:0] DDRAM_DIN,
    output logic [7:0]  DDRAM_BE,
    output logic        DDRAM_WE
);
    localparam logic [28:0] ROM_BASE = 29'h0600_0000;     // 0x3000_0000 / 8
    localparam logic [28:0] CHK_BASE = 29'h0620_0000;     // 0x3100_0000 / 8
    localparam logic [28:0] TRC_BASE = 29'h0640_0000;     // 0x3200_0000 / 8

    // one loader doubleword waits here while the port is busy
    logic        ld_pend;
    logic [17:3] ld_a;
    logic [63:0] ld_d;
    assign ld_busy = ld_pend;

    typedef enum logic [2:0] { S_IDLE, S_CMD, S_RDATA, S_DONE, S_TWR } st_e;
    st_e st;
    logic [1:0] who;            // 0 loader, 1 check store, 2 ROM
    logic [1:0] beat;
    logic       odd;

    always_ff @(posedge clk) begin
        rom_ack <= 1'b0; rom_rvalid <= 1'b0; chk_ack <= 1'b0; tr_ack <= 1'b0;
        if (ld_wr) begin ld_pend <= 1'b1; ld_a <= ld_addr; ld_d <= ld_data; end
        if (rst) begin
            st <= S_IDLE; DDRAM_RD <= 1'b0; DDRAM_WE <= 1'b0; ld_pend <= 1'b0;
        end else case (st)
            S_IDLE: begin
                DDRAM_BURSTCNT <= 8'd1; DDRAM_BE <= 8'hFF;
                if (ld_pend) begin
                    who <= 2'd0; st <= S_CMD;
                    DDRAM_WE <= 1'b1; DDRAM_ADDR <= ROM_BASE + {14'd0, ld_a}; DDRAM_DIN <= ld_d;
                end else if (chk_req) begin
                    who <= 2'd1; st <= S_CMD; odd <= chk_addr[0];
                    DDRAM_ADDR <= CHK_BASE + {7'd0, chk_addr[22:1]};
                    if (chk_we) begin
                        DDRAM_WE <= 1'b1; DDRAM_DIN <= {2{chk_wdata}};
                        DDRAM_BE <= chk_addr[0] ? {4'd0, chk_be} : {chk_be, 4'd0};
                    end else DDRAM_RD <= 1'b1;
                end else if (rom_req) begin
                    who <= 2'd2; st <= S_CMD; beat <= 2'd0;
                    DDRAM_RD <= 1'b1; DDRAM_BURSTCNT <= 8'd4;
                    DDRAM_ADDR <= ROM_BASE + {14'd0, rom_addr, 2'b00};
                end else if (tr_req && !tr_ack) begin
                    // a 4-beat burst: address and count with the first beat
                    st <= S_TWR; beat <= 2'd0;
                    DDRAM_WE <= 1'b1; DDRAM_BURSTCNT <= 8'd4;
                    DDRAM_ADDR <= TRC_BASE + {11'd0, tr_idx, 2'b00}; DDRAM_DIN <= tr_data[63:0];
                end
            end
            // the command stays on the bus until the bridge takes it
            S_CMD: if (!DDRAM_BUSY) begin
                DDRAM_RD <= 1'b0; DDRAM_WE <= 1'b0;
                if (DDRAM_WE) begin
                    if (who == 2'd0) ld_pend <= ld_wr;      // a new one may have arrived
                    else chk_ack <= 1'b1;
                    st <= S_DONE;
                end else begin
                    if (who == 2'd2) rom_ack <= 1'b1;
                    st <= S_RDATA;
                end
            end
            S_RDATA: if (DDRAM_DOUT_READY) begin
                if (who == 2'd2) begin
                    rom_rvalid <= 1'b1; rom_rdata <= DDRAM_DOUT;
                    beat <= beat + 2'd1;
                    if (beat == 2'd3) st <= S_IDLE;
                end else begin
                    chk_ack <= 1'b1; chk_rdata <= odd ? DDRAM_DOUT[31:0] : DDRAM_DOUT[63:32];
                    st <= S_DONE;
                end
            end
            // the client drops its request the cycle after the acknowledge
            S_DONE: st <= S_IDLE;
            // the burst's beats, each held until the bridge takes it
            S_TWR: if (!DDRAM_BUSY) begin
                logic [1:0] nb;
                nb = beat + 2'd1;
                beat <= nb;
                DDRAM_DIN <= tr_data[64 * nb +: 64];
                if (beat == 2'd3) begin DDRAM_WE <= 1'b0; tr_ack <= 1'b1; st <= S_DONE; end
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule
