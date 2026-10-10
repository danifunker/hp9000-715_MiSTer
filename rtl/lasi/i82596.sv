// The Intel 82596CA on LASI (page 7, 0xF0107000, IRQ = LASI bit 8; LASI ERS
// 4.5-4.8, review 06 4.3, HW 4.6; STUBS S-027), as HP's ROM, HP-UX's lan2
// and Linux's lasi_82596 drive it:
//   +0x0 write: hardware reset; +0x4 write: PORT, two words, the low halfword
//   of the value first, each in bits 15:0 (bits 3:0 the function: 0 reset,
//   1 self-test, 2 alternative SCP, 3 dump; 31:4 the address); +0x8 write:
//   channel attention. Reads return 0.
// 32-bit linear mode, big-endian: 16-bit fields are big-endian halfwords,
// 32-bit pointers two halfwords low half first, frame bytes in memory order.
//
// The first CA after a reset reads the SCP's ISCP pointer (+8), the ISCP's
// SCB pointer (+4), clears the ISCP's busy word and reports CX|CNA. Later CAs
// take the SCB command (+2: ACK bits, CUC, RESET, RUC), clear it and write
// the status (+0). The command unit runs the CB list {+0 status, +2 command
// (EL, S, I, opcode), +4 link}: NOP, IA setup, configure (loopback, AL-LOC,
// promiscuous, broadcast disable and CRC-in-memory kept), multicast setup
// (every multicast frame is taken), transmit (the TCB's own data from +16,
// then in the flexible mode its TBD chain), TDR (link OK), dump, diagnose
// (passed), each completed C|OK. The receive unit fills RFDs {+0 status, +2
// command, +4 link, +8 RBD, +12 count, +14 size, +16 data}, in the flexible
// mode continuing into RBDs {+0 count, +4 next, +8 buffer, +12 size}; the RBD
// list is followed from the RFD's pointer when it has one, else from where
// the last frame left it, and the RBD used is written back into the RFD.
//
// The wire is Main_MiSTer's Ethernet bridge (support/hp9k with
// support/sun/sun_enet.cpp: a DDR3 mailbox of 64-bit little-endian words,
// nb_*: magic, generation, TX/RX ring pointers, the station address, 8 TX
// slots at 0x1000 and 16 RX slots at 0x5000 of 2 KB each), or, in the
// loopback modes the ROM's self-test uses, the receive unit directly.
module i82596 (
    input  logic        clk,
    input  logic        rst,            // machine reset
    input  logic        rst_lan,        // IORESET bit 1 (RST_LAN_L) clear
    // registers: req a one-cycle strobe, rdata the cycle after
    input  logic        req, we,
    input  logic [11:0] addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        irq,
    // DMA: one doubleword, held until dma_ack ([7] of dma_be = byte offset 0)
    output logic        dma_req, dma_we,
    output logic [31:0] dma_addr,
    output logic [7:0]  dma_be,
    output logic [63:0] dma_wdata,
    input  logic        dma_ack,
    input  logic [63:0] dma_rdata,
    // the bridge's mailbox: one 64-bit word (offset in words), held until nb_ack
    output logic        nb_req, nb_we,
    output logic [12:0] nb_addr,
    output logic [63:0] nb_wdata,
    input  logic        nb_ack,
    input  logic [63:0] nb_rdata
);
    localparam logic [31:0] NUL = 32'hFFFF_FFFF;

    // ------------------------------------------------------------ the mailbox
    localparam logic [12:0] NB_MAGIC = 13'h0000, NB_GEN = 13'h0001, NB_TXW = 13'h0002, NB_TXR = 13'h0003,
                            NB_RXW = 13'h0004, NB_RXR = 13'h0005, NB_MAC = 13'h0006;
    localparam logic [12:0] NB_TX = 13'h0200, NB_RX = 13'h0A00;     // 0x1000 / 8, 0x5000 / 8; slots of 0x100 words
    localparam logic [63:0] MAGIC = 64'h4850_4554_4830_3031;       // "HPETH001"

    // ------------------------------------------------------------ fields
    function automatic logic [7:0] get8(input logic [63:0] d, input logic [2:0] o);
        return d[63 - 8 * o -: 8];
    endfunction
    function automatic logic [15:0] get16(input logic [63:0] d, input logic [2:0] o);
        return {d[63 - 8 * o -: 8], d[55 - 8 * o -: 8]};
    endfunction
    function automatic logic [31:0] get32(input logic [63:0] d, input logic [2:0] o);
        return {get16(d, o + 3'd2), get16(d, o)};
    endfunction

    // ------------------------------------------------------------ the frame buffer
    logic [7:0]  fbuf [2048];
    logic        fb_we;
    logic [10:0] fb_wa, fb_pos, fb_len;
    logic [7:0]  fb_wd, fb_q;
    always_ff @(posedge clk) begin
        if (fb_we) fbuf[fb_wa] <= fb_wd;
        fb_q <= fbuf[fb_pos];
    end

    // ------------------------------------------------------------ state
    typedef enum logic [6:0] {
        S_BOOT, S_IDLE, S_MEM, S_NB, S_PORT,
        S_INIT1, S_INIT2, S_INIT3,
        S_CA1, S_CA2, S_CA3, S_CA4, S_CA5, S_STAT, S_STAT2,
        S_CB1, S_CB2, S_IA, S_CONF, S_CBF, S_CBF2,
        S_TX1, S_TX2, S_TX3, S_TX4, S_TX5, S_TX6, S_TXSEND,
        S_TXO1, S_TXO2, S_TXO3, S_TXO4, S_TXO5,
        S_RXP1, S_RXP2, S_RXP3, S_RXP4,
        S_RX0, S_RX1, S_RX2, S_RX3, S_RX4, S_RX5, S_RX9, S_RX10, S_RX11, S_RX12,
        S_RB0, S_RB2, S_RB3, S_RB4, S_RB5, S_RB6,
        S_GATHER, S_SCAT, S_SCAT2
    } st_e;
    st_e st, ret, nret, cret, rxret;

    // a memory doubleword (m_dw keeps the last one read: c_tag, c_tv)
    logic [31:0] m_a;
    logic        m_we;
    logic [7:0]  m_be;
    logic [63:0] m_wd, m_dw;
    logic [28:0] c_tag;
    logic        c_tv;
    // a mailbox word
    logic [12:0] n_a;
    logic        n_we;
    logic [63:0] n_wd, n_rd;

    task automatic rd(input logic [31:0] a, input st_e r);
        m_a <= a; m_we <= 1'b0; ret <= r; st <= S_MEM;
    endtask
    task automatic wr16(input logic [31:0] a, input logic [15:0] v, input st_e r);
        m_a <= a; m_we <= 1'b1; m_be <= 8'hC0 >> {a[2:1], 1'b0}; m_wd <= {4{v}}; ret <= r; st <= S_MEM;
    endtask
    task automatic wr32(input logic [31:0] a, input logic [31:0] v, input st_e r);
        m_a <= a; m_we <= 1'b1; m_be <= a[2] ? 8'h0F : 8'hF0; m_wd <= {2{v[15:0], v[31:16]}}; ret <= r; st <= S_MEM;
    endtask
    task automatic nb(input logic [12:0] a, input logic w, input logic [63:0] v, input st_e r);
        n_a <= a; n_we <= w; n_wd <= v; nret <= r; st <= S_NB;
    endtask

    // registers
    logic [15:0] port_lo;
    logic        port_half, port_pend, ca_pend, hrst_pend;
    logic [31:0] port_v;
    // the chip
    localparam logic [2:0] CU_IDLE = 3'd0, CU_SUSP = 3'd1, CU_ACT = 3'd2;
    localparam logic [3:0] RU_IDLE = 4'd0, RU_SUSP = 4'd1, RU_NORES = 4'd2, RU_READY = 4'd4;
    logic        inited;
    logic [31:0] scp, iscp, scb;
    logic [3:0]  ev, pub_ev;            // CX FR CNA RNR: pending, and as last written to the SCB
    logic        irq_gap;
    logic [2:0]  cus;
    logic [3:0]  rus;
    logic [15:0] scb_cmd;
    logic [31:0] cb, cb_link;
    logic [15:0] cb_cmd;
    logic [3:0]  k, cf_n;
    logic [47:0] mac;
    logic [1:0]  lpbk;
    logic        al_loc, prm, bc_dis, crcinm;
    // transmit
    logic [31:0] tbd, tbd_next;
    logic [13:0] tbd_sz;
    logic        tbd_eof, tx_flex;
    logic [63:0] txw, rxr;
    logic [12:0] slot;
    logic [63:0] w64;
    logic [15:0] tx_wait;
    // receive
    logic        rx_loop, rx_runt, da_me, da_bc, da_mc;
    logic [31:0] rfd, rfd_link, rfd_rbd, rb_cur, rb_next, rb_buf, rb_first;
    logic [15:0] rfd_cmd;
    logic        rb_v, rb_el, rb_used;
    logic [13:0] rx_cnt;
    logic [9:0]  poll_t;
    // byte copies: c_n bytes at c_a (sc_n copied); the scatter's staging doubleword
    logic [31:0] c_a;
    logic [13:0] c_n, sc_n;
    logic [63:0] sg_dw;
    logic [7:0]  sg_be;
    logic [2:0]  bk;
    logic [31:0] tick = 32'd0;

    wire accept = rx_loop || prm || da_me || (da_bc && !bc_dis) || (da_mc && !da_bc);
    wire done   = fb_pos == fb_len;

    assign rdata = 32'd0;
    assign irq = |pub_ev && !irq_gap;

    always_ff @(posedge clk) begin
        fb_we <= 1'b0;
        irq_gap <= 1'b0;
        tick <= tick + 32'd1;
        if (rst || (rst_lan && !dma_req && !nb_req)) begin
            st <= S_BOOT; bk <= 3'd0; dma_req <= 1'b0; nb_req <= 1'b0;
            port_half <= 1'b0; port_pend <= 1'b0; ca_pend <= 1'b0; hrst_pend <= 1'b0;
            inited <= 1'b0; scp <= 32'h00FF_FFF4; ev <= 4'd0; pub_ev <= 4'd0; cus <= CU_IDLE; rus <= RU_IDLE;
            lpbk <= 2'd0; al_loc <= 1'b1; prm <= 1'b0; bc_dis <= 1'b0; crcinm <= 1'b0; mac <= 48'd0;
            c_tv <= 1'b0; rb_v <= 1'b0; poll_t <= 10'd0; sg_be <= 8'd0;
        end else begin
            // ---- register writes, taken by the engine between its steps
            if (req && we) case (addr[11:2])
                10'h000: begin hrst_pend <= 1'b1; port_half <= 1'b0; end
                10'h001: begin
                    if (!port_half) port_lo <= wdata[15:0];
                    else begin port_v <= {wdata[15:0], port_lo}; port_pend <= 1'b1; end
                    port_half <= !port_half;
                end
                10'h002: ca_pend <= 1'b1;
                default: ;
            endcase
            if (poll_t != 10'd0) poll_t <= poll_t - 10'd1;

            case (st)
                // ---- a doubleword at m_a (a read of the one in m_dw is free), then ret
                S_MEM: if (!dma_req) begin
                    if (!m_we && c_tv && c_tag == m_a[31:3]) st <= ret;
                    else begin
                        dma_req <= 1'b1; dma_we <= m_we; dma_addr <= {m_a[31:3], 3'd0};
                        dma_be <= m_we ? m_be : 8'hFF; dma_wdata <= m_wd;
                    end
                end else if (dma_ack) begin
                    dma_req <= 1'b0; st <= ret;
                    if (!m_we) begin m_dw <= dma_rdata; c_tag <= m_a[31:3]; c_tv <= 1'b1; end
                    else if (c_tv && c_tag == m_a[31:3])
                        for (int i = 0; i < 8; i++) if (m_be[7 - i]) m_dw[63 - 8 * i -: 8] <= m_wd[63 - 8 * i -: 8];
                end
                // ---- a mailbox word, then nret
                S_NB: if (!nb_req) begin
                    nb_req <= 1'b1; nb_we <= n_we; nb_addr <= n_a; nb_wdata <= n_wd;
                end else if (nb_ack) begin
                    nb_req <= 1'b0; n_rd <= nb_rdata; st <= nret;
                end

                // ---- the mailbox at start-up: the magic off, Main's ring positions taken over, the magic last
                S_BOOT: begin
                    bk <= bk + 3'd1;
                    case (bk)
                        3'd0: nb(NB_MAGIC, 1'b1, 64'd0, S_BOOT);
                        3'd1: nb(NB_TXR, 1'b0, 64'd0, S_BOOT);
                        3'd2: begin txw <= n_rd; nb(NB_TXW, 1'b1, n_rd, S_BOOT); end
                        3'd3: nb(NB_RXW, 1'b0, 64'd0, S_BOOT);
                        3'd4: begin rxr <= n_rd; nb(NB_RXR, 1'b1, n_rd, S_BOOT); end
                        3'd5: nb(NB_MAC, 1'b1, 64'd0, S_BOOT);
                        3'd6: nb(NB_GEN, 1'b1, {32'd0, tick}, S_BOOT);
                        default: nb(NB_MAGIC, 1'b1, MAGIC, S_IDLE);
                    endcase
                end

                S_IDLE: begin
                    c_tv <= 1'b0;
                    if (hrst_pend) begin
                        hrst_pend <= 1'b0; inited <= 1'b0; ev <= 4'd0; pub_ev <= 4'd0;
                        cus <= CU_IDLE; rus <= RU_IDLE; rb_v <= 1'b0;
                    end else if (port_pend) begin
                        port_pend <= 1'b0; st <= S_PORT;
                    end else if (ca_pend) begin
                        ca_pend <= 1'b0;
                        if (!inited) rd(scp + 32'd8, S_INIT1);
                        else rd(scb, S_CA1);
                    end else if (rus == RU_READY && poll_t == 10'd0) begin
                        poll_t <= 10'd1023;
                        nb(NB_RXW, 1'b0, 64'd0, S_RXP1);
                    end else if (cus == CU_ACT) rd(cb, S_CB1);
                end

                // ---- PORT: reset, self-test (signature, result 0 = passed), alternative SCP, dump
                S_PORT: begin
                    st <= S_IDLE;
                    case (port_v[3:0])
                        4'd0: hrst_pend <= 1'b1;
                        4'd1: begin
                            m_a <= {port_v[31:4], 4'd0}; m_we <= 1'b1; m_be <= 8'hFF;
                            m_wd <= 64'd0; ret <= S_IDLE; st <= S_MEM;
                            hrst_pend <= 1'b1;
                        end
                        4'd2: scp <= {port_v[31:4], 4'd0};
                        default: ;
                    endcase
                end

                // ---- initialisation: SCP -> ISCP -> SCB, the busy word cleared, CX|CNA
                S_INIT1: begin iscp <= get32(m_dw, m_a[2:0]); rd(get32(m_dw, m_a[2:0]) + 32'd4, S_INIT2); end
                S_INIT2: begin scb <= get32(m_dw, m_a[2:0]); wr32(iscp, 32'd0, S_INIT3); end
                S_INIT3: begin inited <= 1'b1; cus <= CU_IDLE; rus <= RU_IDLE; ev <= 4'b1010; st <= S_STAT; end

                // ---- a channel attention: the SCB command, cleared
                S_CA1: begin
                    logic [15:0] c;
                    c = get16(m_dw, scb[2:0] + 3'd2);
                    scb_cmd <= c;
                    ev <= ev & ~c[15:12];
                    wr16(scb + 32'd2, 16'd0, S_CA2);
                end
                S_CA2: if (scb_cmd[7]) begin                               // software reset
                    inited <= 1'b0; ev <= 4'd0; pub_ev <= 4'd0; cus <= CU_IDLE; rus <= RU_IDLE; rb_v <= 1'b0;
                    st <= S_IDLE;
                end else case (scb_cmd[10:8])
                    3'd1: rd(scb + 32'd4, S_CA3);                            // CU start: the CBL
                    3'd2: begin if (cus == CU_SUSP) cus <= CU_ACT; st <= S_CA4; end
                    3'd3: begin if (cus == CU_ACT) begin cus <= CU_SUSP; ev[1] <= 1'b1; end st <= S_CA4; end
                    3'd4: begin if (cus == CU_ACT) ev[1] <= 1'b1; cus <= CU_IDLE; st <= S_CA4; end
                    default: st <= S_CA4;
                endcase
                S_CA3: begin cb <= get32(m_dw, m_a[2:0]); cus <= CU_ACT; st <= S_CA4; end
                S_CA4: case (scb_cmd[6:4])
                    3'd1: rd(scb + 32'd8, S_CA5);                            // RU start: the RFA
                    3'd2: begin if (rus == RU_SUSP) rus <= RU_READY; st <= S_STAT; end
                    3'd3: begin if (rus == RU_READY) begin rus <= RU_SUSP; ev[0] <= 1'b1; end st <= S_STAT; end
                    3'd4: begin if (rus == RU_READY) ev[0] <= 1'b1; rus <= RU_IDLE; st <= S_STAT; end
                    default: st <= S_STAT;
                endcase
                S_CA5: begin rfd <= get32(m_dw, m_a[2:0]); rus <= RU_READY; st <= S_STAT; end

                // ---- the SCB status word; then the interrupt (a gap if it was already up)
                S_STAT: wr16(scb, {ev, 1'b0, cus, rus, 4'd0}, S_STAT2);
                S_STAT2: begin
                    pub_ev <= ev;
                    if (|(ev & ~pub_ev) && |pub_ev) irq_gap <= 1'b1;
                    st <= S_IDLE;
                end

                // ---- the command unit: a CB
                S_CB1: begin cb_cmd <= get16(m_dw, cb[2:0] + 3'd2); rd(cb + 32'd4, S_CB2); end
                S_CB2: begin
                    cb_link <= get32(m_dw, m_a[2:0]);
                    k <= 4'd0;
                    case (cb_cmd[2:0])
                        3'd1: rd(cb + 32'd8, S_IA);
                        3'd2: rd(cb + 32'd8, S_CONF);
                        3'd4: rd(cb + 32'd8, S_TX1);
                        3'd5: wr16(cb + 32'd8, 16'h8000, S_CBF);             // TDR: link OK, no fault
                        default: st <= S_CBF;                                // NOP, MC setup, dump, diagnose
                    endcase
                end
                // IA setup: 6 bytes at +8, then the bridge learns them
                S_IA: begin
                    logic [47:0] a;
                    a = {mac[39:0], get8(m_dw, m_a[2:0])};
                    mac <= a; k <= k + 4'd1;
                    if (k == 4'd5) nb(NB_MAC, 1'b1, {1'b1, 15'd0, a}, S_CBF);
                    else rd(m_a + 32'd1, S_IA);
                end
                // configure: byte 0's count of bytes from +8
                S_CONF: begin
                    logic [7:0] b;
                    logic [3:0] n;
                    b = get8(m_dw, m_a[2:0]);
                    n = k == 4'd0 ? b[3:0] : cf_n;
                    if (k == 4'd0) cf_n <= b[3:0];
                    if (k == 4'd3) begin lpbk <= b[7:6]; al_loc <= b[3]; end
                    if (k == 4'd8) begin prm <= b[0]; bc_dis <= b[1]; end
                    if (k == 4'd11) crcinm <= b[2];
                    k <= k + 4'd1;
                    if (k + 4'd1 >= n || k == 4'd13) st <= S_CBF;
                    else rd(m_a + 32'd1, S_CONF);
                end
                // the CB done: C|OK; then I, EL, S
                S_CBF: wr16(cb, 16'hA000, S_CBF2);
                S_CBF2: begin
                    if (cb_cmd[13]) ev[3] <= 1'b1;
                    if (cb_cmd[15]) begin cus <= CU_IDLE; ev[1] <= 1'b1; end
                    else if (cb_cmd[14]) begin cus <= CU_SUSP; ev[1] <= 1'b1; cb <= cb_link; end
                    else cb <= cb_link;
                    st <= S_STAT;
                end

                // ---- transmit: +8 TBD, +12 count (EOF), +16 the TCB's data; flexible: the TBDs
                S_TX1: begin tbd <= get32(m_dw, m_a[2:0]); rd(cb + 32'd12, S_TX2); end
                S_TX2: begin
                    logic [15:0] w;
                    w = get16(m_dw, m_a[2:0]);
                    fb_len <= 11'd0; c_a <= cb + 32'd16; c_n <= w[13:0];
                    tx_flex <= cb_cmd[3] && !w[15];
                    cret <= S_TX3; st <= S_GATHER;
                end
                S_TX3: if (!tx_flex || tbd == NUL) st <= S_TXSEND;
                       else rd(tbd, S_TX4);
                S_TX4: begin
                    logic [15:0] w;
                    w = get16(m_dw, m_a[2:0]);
                    tbd_sz <= w[13:0]; tbd_eof <= w[15];
                    rd(tbd + 32'd4, S_TX5);
                end
                S_TX5: begin tbd_next <= get32(m_dw, m_a[2:0]); rd(tbd + 32'd8, S_TX6); end
                S_TX6: begin
                    c_a <= get32(m_dw, m_a[2:0]); c_n <= tbd_sz;
                    tbd <= tbd_eof ? NUL : tbd_next;
                    cret <= S_TX3; st <= S_GATHER;
                end
                // the frame: looped back to the receive unit, or into a TX slot
                S_TXSEND: begin
                    fb_pos <= 11'd0;
                    if (fb_len == 11'd0) st <= S_CBF;
                    else if (lpbk != 2'd0) begin
                        if (rus == RU_READY) begin rx_loop <= 1'b1; rxret <= S_CBF; st <= S_RX0; end
                        else st <= S_CBF;
                    end else begin tx_wait <= 16'd0; nb(NB_TXR, 1'b0, 64'd0, S_TXO1); end
                end
                // a free slot (Main takes them; a ring full for ~1 ms drops the frame)
                S_TXO1: if (txw - n_rd < 64'd8) begin
                    slot <= NB_TX + {2'd0, txw[2:0], 8'd0}; st <= S_TXO2;
                end else if (tx_wait == 16'hFFFF) st <= S_CBF;
                else begin tx_wait <= tx_wait + 16'd1; nb(NB_TXR, 1'b0, 64'd0, S_TXO1); end
                S_TXO2: st <= S_TXO3;                                        // fb_q <- fbuf[fb_pos]
                S_TXO3: begin
                    logic [63:0] w;
                    w = fb_pos[2:0] == 3'd0 ? 64'd0 : w64;
                    w[8 * fb_pos[2:0] +: 8] = fb_q;
                    w64 <= w; fb_pos <= fb_pos + 11'd1;
                    if (fb_pos + 11'd1 == fb_len) nb(slot + 13'd1 + {5'd0, fb_pos[10:3]}, 1'b1, w, S_TXO4);
                    else if (fb_pos[2:0] == 3'd7) nb(slot + 13'd1 + {5'd0, fb_pos[10:3]}, 1'b1, w, S_TXO2);
                    else st <= S_TXO2;
                end
                S_TXO4: nb(slot, 1'b1, {53'd0, fb_len}, S_TXO5);
                S_TXO5: begin txw <= txw + 64'd1; nb(NB_TXW, 1'b1, txw + 64'd1, S_CBF); end

                // ---- the bridge: a frame waiting (RXW, Main's)? Into fbuf, its address checked on the way
                S_RXP1: if (n_rd != rxr) begin
                    slot <= NB_RX + {1'b0, rxr[3:0], 8'd0};
                    nb(NB_RX + {1'b0, rxr[3:0], 8'd0}, 1'b0, 64'd0, S_RXP2);
                end else st <= S_IDLE;
                S_RXP2: begin
                    logic [10:0] n;
                    n = n_rd[10:0];                                          // with the FCS
                    fb_len <= crcinm ? n : n - 11'd4; fb_pos <= 11'd0;
                    rx_runt <= n < 11'd18;
                    if (n < 11'd18) st <= S_RXP4;
                    else nb(slot + 13'd1, 1'b0, 64'd0, S_RXP3);
                end
                S_RXP3: begin
                    logic [7:0] b;
                    b = n_rd[8 * fb_pos[2:0] +: 8];
                    fb_we <= 1'b1; fb_wa <= fb_pos; fb_wd <= b; fb_pos <= fb_pos + 11'd1;
                    if (fb_pos < 11'd6) begin
                        da_me <= (fb_pos == 11'd0 || da_me) && b == mac[47 - 8 * fb_pos[2:0] -: 8];
                        da_bc <= (fb_pos == 11'd0 || da_bc) && b == 8'hFF;
                        if (fb_pos == 11'd0) da_mc <= b[0];
                    end
                    if (fb_pos + 11'd1 == fb_len) st <= S_RXP4;
                    else if (fb_pos[2:0] == 3'd7) nb(slot + 13'd2 + {5'd0, fb_pos[10:3]}, 1'b0, 64'd0, S_RXP3);
                end
                S_RXP4: begin
                    rxr <= rxr + 64'd1; rx_loop <= 1'b0; rxret <= S_STAT;
                    nb(NB_RXR, 1'b1, rxr + 64'd1, rx_runt ? S_IDLE : S_RX0);
                end

                // ---- the receive unit: the frame in fbuf into the next RFD (then rxret)
                S_RX0: begin
                    c_tv <= 1'b0; fb_pos <= 11'd0;
                    if (!accept) st <= S_IDLE;
                    else rd(rfd, S_RX1);
                end
                S_RX1: begin rfd_cmd <= get16(m_dw, rfd[2:0] + 3'd2); rd(rfd + 32'd4, S_RX2); end
                S_RX2: begin rfd_link <= get32(m_dw, m_a[2:0]); rd(rfd + 32'd8, S_RX3); end
                S_RX3: begin rfd_rbd <= get32(m_dw, m_a[2:0]); rd(rfd + 32'd12, S_RX4); end
                S_RX4: begin
                    logic [15:0] w;
                    w = get16(m_dw, m_a[2:0] + 3'd2);
                    c_a <= rfd + 32'd16; c_n <= w[13:0]; sc_n <= 14'd0;
                    rb_used <= 1'b0;
                    cret <= S_RX5; st <= S_SCAT;
                end
                S_RX5: begin
                    rx_cnt <= sc_n;
                    if (done || !rfd_cmd[3]) st <= S_RX9;
                    else if (rfd_rbd != NUL) begin rb_cur <= rfd_rbd; rb_first <= rfd_rbd; rb_v <= 1'b1; st <= S_RB0; end
                    else begin rb_first <= rb_cur; st <= S_RB0; end
                end
                // RBDs: +4 next, +8 buffer, +12 size (EL); the count written back (EOF, F)
                S_RB0: if (!rb_v || rb_cur == NUL) st <= S_RX9;
                       else begin rb_used <= 1'b1; rd(rb_cur + 32'd4, S_RB2); end
                S_RB2: begin rb_next <= get32(m_dw, m_a[2:0]); rd(rb_cur + 32'd8, S_RB3); end
                S_RB3: begin rb_buf <= get32(m_dw, m_a[2:0]); rd(rb_cur + 32'd12, S_RB4); end
                S_RB4: begin
                    logic [15:0] w;
                    w = get16(m_dw, m_a[2:0]);
                    rb_el <= w[15]; c_a <= rb_buf; c_n <= w[13:0]; sc_n <= 14'd0;
                    cret <= S_RB5; st <= S_SCAT;
                end
                S_RB5: wr16(rb_cur, {done, 1'b1, sc_n}, S_RB6);
                S_RB6: begin
                    rb_cur <= rb_el ? NUL : rb_next;
                    st <= done || rb_el ? S_RX9 : S_RB0;
                end
                // the RFD: its RBD, count (EOF, F), status C|OK (C alone: out of buffers), then EL / S
                S_RX9: if (rb_used) wr32(rfd + 32'd8, rb_first, S_RX10);
                       else st <= S_RX10;
                S_RX10: wr16(rfd + 32'd12, {done, 1'b1, rx_cnt}, S_RX11);
                S_RX11: wr16(rfd, done ? 16'hA000 : 16'h8000, S_RX12);
                S_RX12: begin
                    ev[2] <= 1'b1;
                    if (rfd_cmd[15] || !done) begin rus <= RU_NORES; ev[0] <= 1'b1; end
                    else if (rfd_cmd[14]) begin rus <= RU_SUSP; ev[0] <= 1'b1; rfd <= rfd_link; end
                    else rfd <= rfd_link;
                    st <= rxret;
                end

                // ---- memory -> fbuf: c_n bytes from c_a, appended at fb_len
                S_GATHER: if (c_n == 14'd0) st <= cret;
                    else if (c_tv && c_tag == c_a[31:3]) begin
                        if (fb_len != 11'h7FF) begin
                            fb_we <= 1'b1; fb_wa <= fb_len; fb_wd <= get8(m_dw, c_a[2:0]); fb_len <= fb_len + 11'd1;
                        end
                        c_a <= c_a + 32'd1; c_n <= c_n - 14'd1;
                    end else rd(c_a, S_GATHER);
                // ---- fbuf from fb_pos -> memory at c_a, up to c_n bytes (sc_n counts them), a doubleword at a time
                S_SCAT: if (c_n == 14'd0 || done) begin
                    if (sg_be != 8'd0) begin
                        m_a <= c_a - 32'd1; m_we <= 1'b1; m_be <= sg_be; m_wd <= sg_dw; sg_be <= 8'd0;
                        ret <= cret; st <= S_MEM;
                    end else st <= cret;
                end else st <= S_SCAT2;                                      // fb_q <- fbuf[fb_pos]
                S_SCAT2: begin
                    logic [63:0] d;
                    d = sg_dw;
                    d[63 - 8 * c_a[2:0] -: 8] = fb_q;
                    sg_dw <= d;
                    c_a <= c_a + 32'd1; c_n <= c_n - 14'd1; fb_pos <= fb_pos + 11'd1; sc_n <= sc_n + 14'd1;
                    if (c_a[2:0] == 3'd7) begin
                        m_a <= c_a; m_we <= 1'b1; m_be <= sg_be | 8'h01; m_wd <= d; sg_be <= 8'd0;
                        ret <= S_SCAT; st <= S_MEM;
                    end else begin
                        sg_be <= sg_be | (8'h80 >> c_a[2:0]);
                        st <= S_SCAT;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
