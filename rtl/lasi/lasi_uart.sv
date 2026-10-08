// LASI's RS-232 port: an NS16550A (Lasi ERS 7; docs/review/06b-hpux-lasi-
// peripherals.md 2; HW 4.3). Byte registers 0-7 (the unit maps them at
// +0x800); 16-byte TX and RX FIFOs with the 16550A's trigger levels, the
// character timeout and the interrupt priorities; LSR/MSR read-to-clear;
// TEMT when the transmitter is idle; scratch register; loopback (MCR bit 4).
// Without real modem lines the inputs read DCD = DSR = CTS = 1, RI = 0.
//
// Baud reference 7.3728 MHz (STUBS P-009; LASI uses 40 MHz / 5.5), from
// clk by a fractional divider. SIM_FAST makes one 16x tick per clock, so a
// character takes ~160 clocks instead of ~1 ms at 9600 baud.
//
// Besides the serial pins, `tap_*` reports every byte the transmitter
// starts to send, and `inj_*` pushes a byte straight into the RX FIFO (the
// simulator's console).
module lasi_uart #(
    parameter int  CLK_HZ   = 64_000_000,
    parameter bit  SIM_FAST = 1'b0
) (
    input  logic       clk,
    input  logic       rst,          // unit reset (LASI IORESET, +0x000 write, machine reset)
    input  logic       sel,          // register access strobe
    input  logic       we,
    input  logic [2:0] ra,
    input  logic [7:0] wdata,
    output logic [7:0] rdata,        // valid in the cycle of sel (read side effects happen then)
    output logic       irq,
    output logic       txd,
    input  logic       rxd,
    output logic       tap_strobe,
    output logic [7:0] tap_byte,
    input  logic       inj_strobe,
    input  logic [7:0] inj_byte,
    output logic       inj_full      // RX FIFO full: the injector waits
);
    // ------------------------------------------------------------ registers
    logic [7:0] ier, lcr, mcr, scr, dll, dlm;
    logic       fifo_en;
    logic [1:0] rx_trig;
    logic       dlab;
    assign dlab = lcr[7];

    // FIFOs (16 deep)
    logic [7:0] txf [16];
    logic [3:0] txf_rd, txf_wr;
    logic [4:0] txf_n;
    logic [10:0] rxf [16];          // {break, frame, parity, data}
    logic [3:0] rxf_rd, rxf_wr;
    logic [4:0] rxf_n;

    logic       lsr_oe, lsr_pe, lsr_fe, lsr_bi;   // sticky until LSR read
    logic       thre_int;                         // THRE interrupt pending
    logic       tsr_busy;                         // transmitter shifting
    logic [3:0] msr_delta;                        // DCTS, DDSR, TERI, DDCD
    logic       timeout_int;
    logic [9:0] to_cnt;

    // modem inputs: loopback or the tied-off lines
    wire cts = mcr[4] ? mcr[1] : 1'b1;
    wire dsr = mcr[4] ? mcr[0] : 1'b1;
    wire ri  = mcr[4] ? mcr[2] : 1'b0;
    wire dcd = mcr[4] ? mcr[3] : 1'b1;
    logic cts_q, dsr_q, ri_q, dcd_q;

    // ------------------------------------------------------- baud generator
    localparam int REF_HZ = 7_372_800;
    logic [31:0] acc;
    logic        ref_ce;
    always_ff @(posedge clk) begin
        if (SIM_FAST) ref_ce <= 1'b1;
        else if (acc + REF_HZ / 100 >= CLK_HZ / 100) begin
            acc <= acc + REF_HZ / 100 - CLK_HZ / 100; ref_ce <= 1'b1;
        end else begin
            acc <= acc + REF_HZ / 100; ref_ce <= 1'b0;
        end
    end
    logic [15:0] bdiv;
    logic        tick16;
    always_ff @(posedge clk) begin
        tick16 <= 1'b0;
        if (SIM_FAST) tick16 <= 1'b1;
        else if (ref_ce) begin
            if (bdiv <= 16'd1) begin bdiv <= {dlm, dll}; tick16 <= 1'b1; end
            else bdiv <= bdiv - 16'd1;
        end
    end

    // character format
    wire [3:0] dbits = 4'd5 + {2'd0, lcr[1:0]};
    wire       penable = lcr[3];
    wire       peven = lcr[4];
    wire       pstick = lcr[5];
    wire [3:0] sbits = lcr[2] ? 4'd2 : 4'd1;
    function automatic logic par_of(input logic [7:0] d, input logic [3:0] n);
        logic p;
        p = 1'b0;
        for (int i = 0; i < 8; i++) if (i < n) p ^= d[i];
        return p;
    endfunction
    wire [7:0] dmask = 8'hFF >> (4'd8 - dbits);

    // ---------------------------------------------------------- transmitter
    logic [7:0] tsr;
    logic [3:0] tx_bit;               // 0 start, 1..dbits data, then parity, stop(s)
    logic [3:0] tx_tick;
    logic [1:0] tx_phase;             // 0 start, 1 data, 2 parity, 3 stop
    logic [1:0] tx_stop;
    logic       tx_out;
    logic       tx_pop;
    logic       lb_push;              // loopback: a character arrives at the receiver
    logic [7:0] lb_byte;
    assign txd = mcr[4] ? 1'b1 : (tsr_busy ? tx_out : 1'b1) & !lcr[6];

    // ------------------------------------------------------------- receiver
    logic       rxd_s1, rxd_s2;
    logic       rx_busy;
    logic [3:0] rx_tick;
    logic [3:0] rx_bit;
    logic [7:0] rx_sr;
    logic       rx_par;
    logic       rx_push;
    logic [10:0] rx_word;

    // ------------------------------------------------------------ the logic
    wire rx_in = mcr[4] ? 1'b1 : rxd_s2;       // loopback is done at the byte level below
    wire [10:0] rx_head = rxf[rxf_rd];
    wire        rx_avail = rxf_n != 5'd0;
    wire [4:0]  trig_lvl = rx_trig == 2'd0 ? 5'd1 : rx_trig == 2'd1 ? 5'd4 : rx_trig == 2'd2 ? 5'd8 : 5'd14;
    wire        rda = fifo_en ? (rxf_n >= trig_lvl) : rx_avail;
    wire        lsr_err_fifo = 1'b0;
    wire        temt = txf_n == 5'd0 && !tsr_busy;
    wire        rls_int = ier[2] && (lsr_oe || lsr_pe || lsr_fe || lsr_bi);
    wire        rda_int = ier[0] && rda;
    wire        to_i    = ier[0] && timeout_int;
    wire        thr_int = ier[1] && thre_int;
    wire        ms_int  = ier[3] && msr_delta != 4'd0;
    logic [3:0] iid;
    always_comb begin
        if (rls_int)      iid = 4'b0110;
        else if (rda_int) iid = 4'b0100;
        else if (to_i)    iid = 4'b1100;
        else if (thr_int) iid = 4'b0010;
        else if (ms_int)  iid = 4'b0000;
        else              iid = 4'b0001;
    end
    assign irq = !iid[0];              // LASI's MCR bit 3 is unused (no OUT2 gate)

    wire [7:0] lsr = {fifo_en && lsr_err_fifo, temt, txf_n == 5'd0, lsr_bi, lsr_fe, lsr_pe, lsr_oe, rx_avail};
    wire [7:0] msr = {dcd, ri, dsr, cts, msr_delta[3], msr_delta[2], msr_delta[1], msr_delta[0]};

    always_comb begin
        case (ra)
            3'd0: rdata = dlab ? dll : rx_head[7:0];
            3'd1: rdata = dlab ? dlm : {4'd0, ier[3:0]};
            3'd2: rdata = {fifo_en, fifo_en, 2'b00, iid};
            3'd3: rdata = lcr;
            3'd4: rdata = {3'd0, mcr[4:0]};
            3'd5: rdata = lsr;
            3'd6: rdata = msr;
            default: rdata = scr;
        endcase
    end

    assign inj_full = rxf_n >= 5'd16;
    assign tap_strobe = tx_pop;

    wire rd_rbr = sel && !we && ra == 3'd0 && !dlab;
    wire rd_iir = sel && !we && ra == 3'd2;
    wire rd_lsr = sel && !we && ra == 3'd5;
    wire rd_msr = sel && !we && ra == 3'd6;
    wire wr_thr = sel && we && ra == 3'd0 && !dlab;

    always_ff @(posedge clk) begin
        rxd_s1 <= rxd; rxd_s2 <= rxd_s1;
        tx_pop <= 1'b0; lb_push <= 1'b0; rx_push <= 1'b0;
        if (rst) begin
            ier <= 8'd0; lcr <= 8'd0; mcr <= 8'd0; scr <= 8'd0; dll <= 8'd0; dlm <= 8'd0;
            fifo_en <= 1'b0; rx_trig <= 2'd0;
            txf_rd <= 4'd0; txf_wr <= 4'd0; txf_n <= 5'd0;
            rxf_rd <= 4'd0; rxf_wr <= 4'd0; rxf_n <= 5'd0;
            lsr_oe <= 1'b0; lsr_pe <= 1'b0; lsr_fe <= 1'b0; lsr_bi <= 1'b0;
            thre_int <= 1'b0; tsr_busy <= 1'b0; msr_delta <= 4'd0; timeout_int <= 1'b0; to_cnt <= 10'd0;
            rx_busy <= 1'b0; tx_out <= 1'b1;
            cts_q <= 1'b1; dsr_q <= 1'b1; ri_q <= 1'b0; dcd_q <= 1'b1;
        end else begin
            // ---- register writes
            if (sel && we) case (ra)
                3'd0: if (dlab) dll <= wdata;
                3'd1: if (dlab) dlm <= wdata;
                      else begin
                          ier <= {4'd0, wdata[3:0]};
                          // enabling the THRE interrupt with the THR empty raises it
                          if (wdata[1] && !ier[1] && txf_n == 5'd0) thre_int <= 1'b1;
                      end
                3'd2: begin
                    fifo_en <= wdata[0]; rx_trig <= wdata[7:6];
                    if (wdata[1] || (wdata[0] != fifo_en)) begin rxf_rd <= 4'd0; rxf_wr <= 4'd0; rxf_n <= 5'd0; timeout_int <= 1'b0; end
                    if (wdata[2] || (wdata[0] != fifo_en)) begin txf_rd <= 4'd0; txf_wr <= 4'd0; txf_n <= 5'd0; end
                end
                3'd3: lcr <= wdata;
                3'd4: mcr <= {3'd0, wdata[4:0]};
                3'd7: scr <= wdata;
                default: ;
            endcase

            // ---- read side effects
            if (rd_iir && iid == 4'b0010) thre_int <= 1'b0;
            if (rd_lsr) begin lsr_oe <= 1'b0; lsr_pe <= 1'b0; lsr_fe <= 1'b0; lsr_bi <= 1'b0; end
            if (rd_msr) msr_delta <= 4'd0;

            // ---- modem status deltas
            cts_q <= cts; dsr_q <= dsr; ri_q <= ri; dcd_q <= dcd;
            if (cts != cts_q) msr_delta[0] <= 1'b1;
            if (dsr != dsr_q) msr_delta[1] <= 1'b1;
            if (ri_q && !ri)  msr_delta[2] <= 1'b1;
            if (dcd != dcd_q) msr_delta[3] <= 1'b1;

            // ---- TX FIFO
            begin
                logic push, pop;
                push = wr_thr && (fifo_en ? txf_n < 5'd16 : txf_n == 5'd0);
                pop  = !tsr_busy && txf_n != 5'd0 && tick16;
                if (push) begin txf[txf_wr] <= wdata; txf_wr <= txf_wr + 4'd1; thre_int <= 1'b0; end
                if (pop) begin
                    tsr <= txf[txf_rd]; txf_rd <= txf_rd + 4'd1; tx_pop <= 1'b1; tap_byte <= txf[txf_rd];
                    tsr_busy <= 1'b1; tx_phase <= 2'd0; tx_tick <= 4'd0; tx_bit <= 4'd0; tx_out <= 1'b0;
                    if (txf_n == 5'd1 && !push) thre_int <= 1'b1;
                end
                txf_n <= txf_n + (push ? 5'd1 : 5'd0) - (pop ? 5'd1 : 5'd0);
            end

            // ---- transmitter bit timing
            if (tsr_busy && tick16) begin
                tx_tick <= tx_tick + 4'd1;
                if (tx_tick == 4'd15) begin
                    case (tx_phase)
                        2'd0: begin tx_phase <= 2'd1; tx_bit <= 4'd0; tx_out <= tsr[0]; end
                        2'd1: if (tx_bit + 4'd1 < dbits) begin
                                  tx_bit <= tx_bit + 4'd1; tx_out <= tsr[3'(tx_bit + 4'd1)];
                              end else if (penable) begin
                                  tx_phase <= 2'd2;
                                  tx_out <= pstick ? !peven : (par_of(tsr, dbits) ^ !peven);
                              end else begin tx_phase <= 2'd3; tx_stop <= 2'd0; tx_out <= 1'b1; end
                        2'd2: begin tx_phase <= 2'd3; tx_stop <= 2'd0; tx_out <= 1'b1; end
                        default: begin
                            if (tx_stop + 2'd1 >= sbits[1:0]) begin
                                tsr_busy <= 1'b0;
                                if (mcr[4]) begin lb_push <= 1'b1; lb_byte <= tsr & dmask; end
                            end else tx_stop <= tx_stop + 2'd1;
                        end
                    endcase
                end
            end

            // ---- receiver (serial pin)
            if (tick16) begin
                if (!rx_busy) begin
                    if (!rx_in) begin rx_busy <= 1'b1; rx_tick <= 4'd0; rx_bit <= 4'd0; rx_sr <= 8'd0; end
                end else begin
                    rx_tick <= rx_tick + 4'd1;
                    if (rx_tick == 4'd7) begin           // mid-bit sample
                        if (rx_bit == 4'd0) begin
                            if (rx_in) rx_busy <= 1'b0;  // false start
                        end else if (rx_bit <= dbits) rx_sr[3'(rx_bit - 4'd1)] <= rx_in;
                        else if (penable && rx_bit == dbits + 4'd1) rx_par <= rx_in;
                        else begin
                            rx_push <= 1'b1;
                            rx_word <= {1'b0, !rx_in, penable && (rx_par != (pstick ? !peven : (par_of(rx_sr, dbits) ^ !peven))), rx_sr};
                            rx_busy <= 1'b0;
                        end
                        rx_bit <= rx_bit + 4'd1;
                    end
                end
            end

            // ---- RX FIFO: serial receiver, loopback, injection; RBR reads pop
            begin
                logic push, pop;
                logic [10:0] w;
                push = rx_push || lb_push || inj_strobe;
                w = rx_push ? rx_word : lb_push ? {3'd0, lb_byte} : {3'd0, inj_byte};
                pop = rd_rbr && rx_avail;
                if (push) begin
                    if (rxf_n == 5'd16 || (!fifo_en && rxf_n != 5'd0 && !pop)) lsr_oe <= 1'b1;
                    else begin
                        rxf[fifo_en ? rxf_wr : 4'd0] <= w; rxf_wr <= fifo_en ? rxf_wr + 4'd1 : 4'd1;
                        if (w[8]) lsr_pe <= 1'b1;
                        if (w[9]) lsr_fe <= 1'b1;
                    end
                end
                if (pop) rxf_rd <= fifo_en ? rxf_rd + 4'd1 : 4'd0;
                if (!fifo_en) begin
                    if (push && !(rxf_n != 5'd0 && !pop)) rxf_n <= 5'd1;
                    else if (pop) rxf_n <= 5'd0;
                    if (push) rxf_rd <= 4'd0;
                end else
                    rxf_n <= rxf_n + ((push && rxf_n != 5'd16) ? 5'd1 : 5'd0) - (pop ? 5'd1 : 5'd0);
                // character timeout: data waiting and no activity for ~4 characters
                if (push || pop || !fifo_en || !rx_avail) begin to_cnt <= 10'd0; timeout_int <= 1'b0; end
                else if (tick16 && !timeout_int) begin
                    to_cnt <= to_cnt + 10'd1;
                    if (to_cnt == 10'd639) timeout_int <= 1'b1;
                end
            end
        end
    end
endmodule
