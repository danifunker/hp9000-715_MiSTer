// LASI, the 715's core I/O chip, at F010_0000-F01F_FFFF (docs/design/
// system.md 5; Lasi ERS; HW 4; R06 4.1, R06b). A GSC slave with one access
// at a time, answered the cycle after the request; and a GSC master for its
// interrupt transaction (IAR[4:0] written to IAR[31:5]).
//
// Pages (4 KB, offset bits 15:12): 0 interrupt registers, 4 Harmony audio
// and 6 SCSI (rtl/lasi/harmony.sv and the 53C710, outside this module on
// the aud_* and scsi_* ports), 5 RS-232, 8 PS/2, 9 RTC, B clock registers,
// C PCR/ERRLOG/VER/IORESET/AMR. The units not built yet -- parallel and its
// DMA (1-3, P-010), LAN (7, P-005), floppy (A, D, P-004) -- read 0 and
// ignore writes (STUBS S-015); so does everything above page D (LASI
// answers its whole space, Lasi ERS app. A).
module lasi #(
    parameter int CLK_HZ    = 64_000_000,
    parameter bit SIM_FAST  = 1'b0          // fast UART and PS/2 timing (simulator)
) (
    input  logic        clk,
    input  logic        rst_n,
    // GSC slave
    input  logic        req,
    input  logic        we,
    input  logic [31:0] addr,
    input  logic [3:0]  be,
    input  logic [31:0] wdata,
    output logic        ack,
    output logic [31:0] rdata,
    // interrupt transaction to the MIOC
    output logic        eir_req,
    output logic [31:0] eir_addr,
    output logic [4:0]  eir_data,
    input  logic        eir_ack,
    input  logic        eir_err,
    // the front-panel TOC button (LASI's external interrupt input)
    input  logic        ext_int,
    output logic        ext_toc,          // ... remapped to TOC by ICR bit 1
    // RS-232
    output logic        uart_txd,
    input  logic        uart_rxd,
    output logic        uart_tap_strobe,
    output logic [7:0]  uart_tap_byte,
    input  logic        uart_inj_strobe,
    input  logic [7:0]  uart_inj_byte,
    output logic        uart_inj_full,
    // PS/2 devices (hps_io format)
    input  logic        kbd_present,
    input  logic        mouse_present,
    input  logic [10:0] ps2_key,
    input  logic [24:0] ps2_mouse,
    // RTC: load a value (e.g. the MiSTer's clock at power-up)
    input  logic        rtc_set,
    input  logic [31:0] rtc_value,
    // the SCSI unit (page 6, rtl/scsi/ncr53c710.sv): its registers answer
    // the cycle after the request, so LASI acknowledges a cycle later
    output logic        scsi_req,
    output logic        scsi_we,
    output logic [11:0] scsi_addr,
    output logic [3:0]  scsi_be,
    output logic [31:0] scsi_wdata,
    input  logic [31:0] scsi_rdata,
    output logic        scsi_rst,          // machine reset, IORESET bit 0 clear, or a write to +0x000
    input  logic        scsi_irq,
    // Harmony (page 4, rtl/lasi/harmony.sv), the same way
    output logic        aud_req,
    output logic        aud_rst,           // machine reset or IORESET bit 3 (RST_AUD_L) clear
    input  logic [31:0] aud_rdata,
    input  logic        aud_irq,
    // misc outputs
    output logic [31:0] pcr,
    output logic        artist_rst,       // IORESET bit 8 (RST_ARTIST_L) clear
    // debug: a byte on a PS/2 port ({port, 1 = device to host, byte})
    output logic        dbg_ps2_valid,
    output logic [9:0]  dbg_ps2
);
    localparam int UNITS_CLK = SIM_FAST ? 2_000 : CLK_HZ / 1000;     // one PS/2 byte

    // --------------------------------------------------------- core registers
    logic [31:0] irr, imr, ipr, iar, icr_be;   // icr_be: ICR bit 8
    logic [8:0]  ioreset;
    logic [31:0] amr, errlog, clkreg [4];
    logic        toc_remap;
    logic        irr_clr;                    // an IRR read last cycle

    wire rst_intr = !rst_n || !ioreset[4];
    wire rst_uart_l = !rst_n || !ioreset[6];
    wire rst_kbd_l  = !rst_n || !ioreset[7];
    assign artist_rst = !ioreset[8];

    // ------------------------------------------------------------- decode
    wire [3:0]  page = addr[15:12];
    wire        in_lasi = addr[19:16] == 4'h0;      // F010_xxxx; above that unassigned
    // byte lane of a one-byte access (be[3] = byte 0)
    logic [1:0] lane;
    always_comb casez (be)
        4'b1???: lane = 2'd0;
        4'b01??: lane = 2'd1;
        4'b001?: lane = 2'd2;
        default: lane = 2'd3;
    endcase
    wire [7:0] wbyte = wdata[31 - 8*lane -: 8];

    // --------------------------------------------------------------- UART
    logic       u_sel, u_rst_pulse, u_irq;
    logic [7:0] u_rdata;
    wire        u_is_reg = in_lasi && page == 4'h5 && addr[11:3] == 9'h100;    // +0x800-0x807
    assign u_sel = req && u_is_reg;
    assign u_rst_pulse = req && we && in_lasi && page == 4'h5 && addr[11:2] == 10'd0;
    lasi_uart #(.CLK_HZ(CLK_HZ), .SIM_FAST(SIM_FAST)) u_uart (
        .clk(clk), .rst(rst_uart_l || u_rst_pulse), .sel(u_sel), .we(we), .ra({addr[2], lane}),
        .wdata(wbyte), .rdata(u_rdata), .irq(u_irq), .txd(uart_txd), .rxd(uart_rxd),
        .tap_strobe(uart_tap_strobe), .tap_byte(uart_tap_byte),
        .inj_strobe(uart_inj_strobe), .inj_byte(uart_inj_byte), .inj_full(uart_inj_full));

    // --------------------------------------------------------------- PS/2
    logic [7:0] k_rdata, m_rdata;
    logic       k_line, m_line, cmpintr;
    logic       k_txv, m_txv, k_rxv, m_rxv, k_rxr, m_rxr;
    logic [7:0] k_txb, m_txb, k_rxb, m_rxb;
    wire        p_is = in_lasi && page == 4'h8;
    assign cmpintr = k_line || m_line;
    lasi_ps2 #(.ID(4'd0), .BYTE_CLKS(UNITS_CLK), .LPB_CLKS(SIM_FAST ? 64 : CLK_HZ / 181_818)) u_kbd (
        .clk(clk), .rst(rst_kbd_l), .sel(req && p_is && !addr[8]), .we(we), .ra(addr[3:2]), .wdata(wbyte),
        .rdata(k_rdata), .cmpintr(cmpintr), .irq_line(k_line), .dev_present(kbd_present),
        .dev_tx_valid(k_txv), .dev_tx_byte(k_txb), .dev_rx_valid(k_rxv), .dev_rx_byte(k_rxb), .dev_rx_ready(k_rxr));
    lasi_ps2 #(.ID(4'd1), .BYTE_CLKS(UNITS_CLK), .LPB_CLKS(SIM_FAST ? 64 : CLK_HZ / 181_818)) u_mouse (
        .clk(clk), .rst(rst_kbd_l), .sel(req && p_is && addr[8]), .we(we), .ra(addr[3:2]), .wdata(wbyte),
        .rdata(m_rdata), .cmpintr(cmpintr), .irq_line(m_line), .dev_present(mouse_present),
        .dev_tx_valid(m_txv), .dev_tx_byte(m_txb), .dev_rx_valid(m_rxv), .dev_rx_byte(m_rxb), .dev_rx_ready(m_rxr));
    ps2_dev #(.MOUSE(1'b0), .BYTE_CLKS(UNITS_CLK), .RESET_CLKS(UNITS_CLK * 10)) u_kbd_dev (
        .clk(clk), .rst(!rst_n), .tx_valid(k_txv), .tx_byte(k_txb), .rx_valid(k_rxv), .rx_byte(k_rxb),
        .rx_ready(k_rxr), .ps2_key(ps2_key), .ps2_mouse(ps2_mouse));
    ps2_dev #(.MOUSE(1'b1), .BYTE_CLKS(UNITS_CLK), .RESET_CLKS(UNITS_CLK * 10)) u_mouse_dev (
        .clk(clk), .rst(!rst_n), .tx_valid(m_txv), .tx_byte(m_txb), .rx_valid(m_rxv), .rx_byte(m_rxb),
        .rx_ready(m_rxr), .ps2_key(ps2_key), .ps2_mouse(ps2_mouse));

    always_comb begin
        dbg_ps2_valid = 1'b1;
        if      (k_txv)         dbg_ps2 = {2'b00, k_txb};
        else if (k_rxv && k_rxr) dbg_ps2 = {2'b01, k_rxb};
        else if (m_txv)         dbg_ps2 = {2'b10, m_txb};
        else if (m_rxv && m_rxr) dbg_ps2 = {2'b11, m_rxb};
        else begin dbg_ps2_valid = 1'b0; dbg_ps2 = 10'd0; end
    end

    // ---------------------------------------------------------------- RTC
    logic [31:0] rtc;
    logic [31:0] rtc_pre;
    localparam int RTC_DIV = CLK_HZ;
    always_ff @(posedge clk) begin
        if (rtc_set) begin rtc <= rtc_value; rtc_pre <= 32'd0; end
        else if (req && we && in_lasi && page == 4'h9 && addr[11:2] == 10'd0) begin
            rtc <= wdata; rtc_pre <= 32'd0;
        end else if (rtc_pre == RTC_DIV - 1) begin rtc_pre <= 32'd0; rtc <= rtc + 32'd1; end
        else rtc_pre <= rtc_pre + 32'd1;
    end

    // -------------------------------------------------------- SCSI unit
    wire s_page = in_lasi && page == 4'h6;
    assign scsi_req = req && s_page;
    assign scsi_we = we;
    assign scsi_addr = addr[11:0];
    assign scsi_be = be;
    assign scsi_wdata = wdata;
    assign scsi_rst = !rst_n || !ioreset[0] || (req && we && s_page && addr[11:2] == 10'd0);
    logic s_pend, a_pend;

    // -------------------------------------------------------- Harmony
    wire a_page = in_lasi && page == 4'h4;
    assign aud_req = req && a_page;
    assign aud_rst = !rst_n || !ioreset[3];

    // -------------------------------------------- interrupt sources (GSC bits)
    logic [31:0] src, src_q;
    logic        ext_q;
    always_comb begin
        src = 32'd0;
        src[5]  = u_irq;
        src[9]  = scsi_irq;
        src[13] = aud_irq;
        src[21] = ext_int && !toc_remap;
        src[26] = cmpintr;
    end

    // ------------------------------------------------------- register access
    always_ff @(posedge clk) begin
        ack <= 1'b0;
        ext_toc <= 1'b0;
        irr_clr <= 1'b0;
        s_pend <= 1'b0;
        a_pend <= 1'b0;
        if (s_pend) begin ack <= 1'b1; rdata <= scsi_rdata; end
        if (a_pend) begin ack <= 1'b1; rdata <= aud_rdata; end

        if (!rst_n) begin
            ioreset <= 9'd0; amr <= 32'd0; errlog <= 32'd0; pcr <= 32'd1;
            for (int i = 0; i < 4; i++) clkreg[i] <= 32'd0;
        end

        if (rst_intr) begin
            irr <= 32'd0; imr <= 32'd0; ipr <= 32'd0; iar <= 32'hFFFB_E003; icr_be <= 32'd0;
            toc_remap <= 1'b0; eir_req <= 1'b0; src_q <= 32'd0; ext_q <= 1'b0;
        end else begin
            logic [31:0] ipr_n, irr_n, newb;
            src_q <= src;
            ext_q <= ext_int;
            if (ext_int && !ext_q && toc_remap) ext_toc <= 1'b1;
            ipr_n = ipr;
            irr_n = irr;
            // an IRR read clears IRR and the unmasked IPR bits on the next cycle
            if (irr_clr) begin irr_n = 32'd0; ipr_n = ipr_n & ~imr; end
            if (req && we && in_lasi && page == 4'h0 && addr[11:2] == 10'd2) ipr_n = 32'd0;   // IPR write clears it
            ipr_n = ipr_n | (src & ~src_q);                    // rising edges (win over clears)
            newb  = ipr_n & imr & ~irr_n;
            irr_n = irr_n | (ipr_n & imr);
            ipr <= ipr_n;
            irr <= irr_n;
            // the interrupt transaction
            if (eir_req && (eir_ack || eir_err)) begin
                eir_req <= 1'b0;
                if (eir_err) icr_be[8] <= 1'b1;
            end
            if (newb != 32'd0 && !icr_be[8]) begin
                eir_req <= 1'b1; eir_addr <= {iar[31:5], 5'd0}; eir_data <= iar[4:0];
            end
            if (req && we && in_lasi && page == 4'h0) case (addr[11:2])
                10'd1: imr <= wdata;
                10'd3: begin toc_remap <= wdata[1]; icr_be[8] <= wdata[8]; end
                10'd4: iar <= wdata;
                default: ;
            endcase
        end

        if (rst_n && req && s_page) s_pend <= 1'b1;
        if (rst_n && req && a_page) a_pend <= 1'b1;
        if (rst_n && req && !s_page && !a_page) begin
            logic [31:0] r;
            r = 32'd0;
            if (in_lasi) case (page)
                4'h0: case (addr[11:2])
                    10'd0: begin r = irr; if (!we) irr_clr <= 1'b1; end
                    10'd1: r = imr;
                    10'd2: r = ipr;
                    10'd3: r = icr_be & 32'h100;
                    10'd4: r = iar;
                    default: ;
                endcase
                4'h5: r = {4{u_rdata}};
                4'h8: r = {4{addr[8] ? m_rdata : k_rdata}};
                4'h9: r = rtc;
                4'hB: begin r = clkreg[addr[3:2]]; if (we && addr[11:4] == 8'd0) clkreg[addr[3:2]] <= wdata; end
                4'hC: case (addr[11:2])
                    10'd0: begin r = pcr; if (we) pcr <= wdata; end
                    10'd1: begin r = errlog; if (we) errlog <= wdata; end
                    10'd2: r = 32'd0;                                  // VER
                    10'd3: begin r = {23'd0, ioreset}; if (we) ioreset <= wdata[8:0]; end
                    10'd4: begin r = amr; if (we) amr <= wdata; end
                    default: ;
                endcase
                default: ;
            endcase
            rdata <= r;
            ack <= 1'b1;
        end
    end
endmodule
