// The HP 9000/715 machine (docs/design/system.md): the PA-7100LC, the MIOC,
// LASI, the 8-bit bus (EEPROM, LEDs, board ID) and the WAX stub, on one
// clock. Memory comes in through plain request/acknowledge ports -- system
// RAM, the ECC check store, the boot ROM store -- that the MiSTer top wires
// to SDRAM/DDR3 and the simulator to arrays. Nothing here is MiSTer-specific.
module hp715 #(
    parameter int CLK_HZ     = 64_000_000,  // clk's frequency (CR16 runs at the board's rate whatever it is)
    parameter bit SIM_FAST   = 1'b0,        // fast UART/PS/2 character timing (simulator)
    parameter bit HAS_ARTIST = 1'b0
) (
    input  logic        clk,
    input  logic        reset,              // power-on, the MiSTer reset, a ROM download
    // configuration
    input  logic [1:0]  cfg_model,          // 0 = 715/64, 1 = 715/80, 2 = 715/100
    input  logic [3:0]  cfg_ram_lg,         // 2^n MB of RAM, 3..8
    input  logic [3:0]  sim_cr16_mul,       // simulator only: CR16 counts n x faster (0 = real rate; tie 0 on the board)
    // front panel
    input  logic        soft_pwr_n,         // 0 while "soft power off" is requested
    input  logic        toc_button,
    output logic [7:0]  led_latch,          // the eight status LEDs (active low)
    output logic        led_strobe,
    output logic [31:0] lasi_pcr,           // bit 0 FLASH_LED, bit 1 PWR_ON_L
    // system RAM
    output logic        ram_req, ram_we, ram_line,
    output logic [27:0] ram_addr,
    output logic [7:0]  ram_be,
    output logic [63:0] ram_wdata,
    input  logic        ram_ack, ram_wready, ram_rvalid,
    input  logic [1:0]  ram_rbeat,
    input  logic [63:0] ram_rdata,
    // ECC check store
    output logic        chk_req, chk_we,
    output logic [22:0] chk_addr,
    output logic [3:0]  chk_be,
    output logic [31:0] chk_wdata,
    input  logic        chk_ack,
    input  logic [31:0] chk_rdata,
    // boot ROM store
    output logic        rom_req,
    output logic [17:5] rom_addr,
    input  logic        rom_ack, rom_rvalid,
    input  logic [63:0] rom_rdata,
    input  logic        rom_inval,
    // RS-232
    output logic        uart_txd,
    input  logic        uart_rxd,
    output logic        uart_tap_strobe,
    output logic [7:0]  uart_tap_byte,
    input  logic        uart_inj_strobe,
    input  logic [7:0]  uart_inj_byte,
    output logic        uart_inj_full,
    // PS/2 (hps_io format)
    input  logic [10:0] ps2_key,
    input  logic [24:0] ps2_mouse,
    // SCSI images (hps_io block devices, 512-byte blocks, WIDE): slot 0 the
    // disk at ID 6, 1 the disk at ID 5, 2 the CD-ROM at ID 2
    input  logic [2:0]  img_present,
    input  logic [31:0] img_blocks [3],
    output logic [31:0] sd_lba [3],
    output logic [5:0]  sd_blk_cnt [3],
    output logic [2:0]  sd_rd,
    output logic [2:0]  sd_wr,
    input  logic [2:0]  sd_ack,
    input  logic [12:0] sd_buff_addr,
    input  logic [15:0] sd_buff_dout,
    output logic [15:0] sd_buff_din [3],
    input  logic        sd_buff_wr,
    output logic        scsi_activity,
    // RTC load
    input  logic        rtc_set,
    input  logic [31:0] rtc_value,
    // EEPROM host port
    input  logic [10:0] ee_haddr,
    input  logic        ee_hwe,
    input  logic [31:0] ee_hwdata,
    output logic [31:0] ee_hrdata,
    output logic        ee_dirty,
    input  logic        ee_dirty_clr,
    // debug
    input  logic [7:0]  dbg_ctl,            // simulator trace switches: [0] GSC accesses, [1] I-cache, [2] SCSI
    // debug events for the board's recorder (rtl/mister/trace_ddr3.sv):
    // {type, aux, addr, data}, one per cycle at most
    output logic        dbg_ev_valid,
    output logic [111:0] dbg_ev,
    output logic        dbg_retire, dbg_nullified,
    output logic [31:0] dbg_iaoq_f, dbg_iaoq_b,
    output logic [31:0] dbg_insn,
    output logic        dbg_trap,
    output logic [5:0]  dbg_trap_vec,
    output logic [31:0] dbg_psw,
    output logic        dbg_halted,
    output logic        dbg_buserr,
    output logic [31:0] dbg_buserr_addr,
    output logic [31:0] dbg_gr [32]
);
    // ------------------------------------------------------------ reset
    // power-on reset, or the broadcast reset (16 cycles after the store)
    logic       bcast_reset;
    logic [4:0] brst;
    logic       rst_n;
    always_ff @(posedge clk) begin
        if (reset) brst <= 5'd0;
        else if (bcast_reset) brst <= 5'd16;
        else if (brst != 5'd0) brst <= brst - 5'd1;
        rst_n <= !reset && brst == 5'd0;
    end

    // ---------------------------------------------- CR16 rate: board / clk
    function automatic longint gcd(input longint a, input longint b);
        longint t;
        while (b != 0) begin t = a % b; a = b; b = t; end
        return a;
    endfunction
    localparam longint CLK = CLK_HZ;
    function automatic logic [47:0] ratio(input longint fb);
        longint q, r, g;
        q = fb / CLK; r = fb % CLK;
        g = (r == 0) ? CLK : gcd(r, CLK);
        return {q[15:0], (r == 0 ? 16'd0 : 16'(r / g)), (r == 0 ? 16'd1 : 16'(CLK / g))};
    endfunction
    localparam logic [47:0] R64 = ratio(64_000_000), R80 = ratio(80_000_000), R100 = ratio(100_000_000);
    wire [47:0] rsel = cfg_model == 2'd1 ? R80 : cfg_model == 2'd2 ? R100 : R64;
    wire [3:0]  model_id = cfg_model == 2'd1 ? 4'hB : cfg_model == 2'd2 ? 4'hF : 4'h7;

    // ---------------------------------------------------------------- CPU
    logic        mem_req, mem_we, mem_ifill, mem_ack, mem_wvalid, mem_wready, mem_rvalid, mem_rerr;
    logic [31:0] mem_addr;
    logic [63:0] mem_wdata, mem_rdata;
    logic [1:0]  mem_rbeat;
    logic        io_req, io_we, io_ifetch, io_burst, io_rclr, io_ack, io_last, io_err;
    logic [31:0] io_addr;
    logic [7:0]  io_be;
    logic [63:0] io_wdata, io_rdata;
    logic        eir_set, toc_req, hpmc_req, lpmc_req;
    logic [4:0]  eir_num;

    // the simulator's CR16 speed-up multiplies the integer ticks per clock
    // (exact only when the ratio is an integer, as for a 715/64 at 64 MHz)
    wire [15:0] cr16_tq = sim_cr16_mul == 4'd0 ? rsel[47:32] : rsel[47:32] * {12'd0, sim_cr16_mul};

    pa_cpu u_cpu (
        .clk(clk), .rst_n(rst_n), .cfg_tq(cr16_tq), .cfg_tr(rsel[31:16]), .cfg_td(rsel[15:0]),
        .mem_req(mem_req), .mem_we(mem_we), .mem_ifill(mem_ifill), .mem_addr(mem_addr), .mem_ack(mem_ack),
        .mem_wdata(mem_wdata), .mem_wvalid(mem_wvalid), .mem_wready(mem_wready), .mem_rdata(mem_rdata),
        .mem_rvalid(mem_rvalid), .mem_rbeat(mem_rbeat), .mem_rerr(mem_rerr),
        .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_be(io_be), .io_wdata(io_wdata),
        .io_ifetch(io_ifetch), .io_burst(io_burst), .io_rclr(io_rclr), .io_ack(io_ack), .io_last(io_last),
        .io_rdata(io_rdata), .io_err(io_err),
        .eir_set(eir_set), .eir_num(eir_num), .toc_req(toc_req), .hpmc_req(hpmc_req), .lpmc_req(lpmc_req),
        .powerfail(1'b0), .soft_pwr_n(soft_pwr_n),
        .dbg_retire(dbg_retire), .dbg_nullified(dbg_nullified), .dbg_iaoq_f(dbg_iaoq_f), .dbg_iaoq_b(dbg_iaoq_b),
        .dbg_iasq_f(c_iasq_f), .dbg_insn(dbg_insn), .dbg_trap(dbg_trap), .dbg_trap_vec(dbg_trap_vec),
        .dbg_gr_we(), .dbg_gr_num0(), .dbg_gr_num1(), .dbg_gr_data0(), .dbg_gr_data1(),
        .dbg_psw(dbg_psw), .dbg_halted(dbg_halted), .dbg_gr(dbg_gr),
        .dbg_cop_valid(c_cop_valid), .dbg_cop_i(c_cop_i), .dbg_cop(c_cop), .dbg_cop_addr(c_cop_addr),
        .dbg_cop_rpn(c_cop_rpn));
    logic [15:0] c_iasq_f;
    logic        c_cop_valid, c_cop_i;
    logic [3:0]  c_cop;
    logic [31:0] c_cop_addr;
    logic [19:0] c_cop_rpn;

    // --------------------------------------------------------------- MIOC
    logic        gsc_req, gsc_we, gsc_ack, gsc_err;
    logic [1:0]  gsc_dev;
    logic [31:0] gsc_addr, gsc_wdata, gsc_rdata;
    logic [3:0]  gsc_be;
    logic        l_eir_req, l_eir_ack, l_eir_err, ext_toc;
    logic        dma_req, dma_we, dma_ack, dma_err;
    logic [31:0] dma_addr;
    logic [7:0]  dma_be;
    logic [63:0] dma_wdata, dma_rdata;
    logic [31:0] l_eir_addr;
    logic [4:0]  l_eir_data;

    mioc #(.HAS_ARTIST(HAS_ARTIST)) u_mioc (
        .clk(clk), .rst_n(rst_n), .cfg_ram_lg(cfg_ram_lg),
        .mem_req(mem_req), .mem_we(mem_we), .mem_ifill(mem_ifill), .mem_addr(mem_addr), .mem_ack(mem_ack),
        .mem_wdata(mem_wdata), .mem_wvalid(mem_wvalid), .mem_wready(mem_wready), .mem_rdata(mem_rdata),
        .mem_rvalid(mem_rvalid), .mem_rbeat(mem_rbeat), .mem_rerr(mem_rerr),
        .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_be(io_be), .io_wdata(io_wdata),
        .io_ifetch(io_ifetch), .io_burst(io_burst), .io_rclr(io_rclr), .io_ack(io_ack), .io_last(io_last),
        .io_rdata(io_rdata), .io_err(io_err),
        .eir_set(eir_set), .eir_num(eir_num), .toc_req(toc_req), .hpmc_req(hpmc_req), .lpmc_req(lpmc_req),
        .ram_req(ram_req), .ram_we(ram_we), .ram_line(ram_line), .ram_addr(ram_addr), .ram_be(ram_be),
        .ram_wdata(ram_wdata), .ram_ack(ram_ack), .ram_wready(ram_wready), .ram_rvalid(ram_rvalid),
        .ram_rbeat(ram_rbeat), .ram_rdata(ram_rdata),
        .chk_req(chk_req), .chk_we(chk_we), .chk_addr(chk_addr), .chk_be(chk_be), .chk_wdata(chk_wdata),
        .chk_ack(chk_ack), .chk_rdata(chk_rdata),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_rvalid(rom_rvalid),
        .rom_rdata(rom_rdata), .rom_inval(rom_inval),
        .gsc_req(gsc_req), .gsc_we(gsc_we), .gsc_dev(gsc_dev), .gsc_addr(gsc_addr), .gsc_be(gsc_be),
        .gsc_wdata(gsc_wdata), .gsc_ack(gsc_ack), .gsc_err(gsc_err), .gsc_rdata(gsc_rdata),
        .dma_req(dma_req), .dma_we(dma_we), .dma_addr(dma_addr), .dma_be(dma_be), .dma_wdata(dma_wdata),
        .dma_ack(dma_ack), .dma_err(dma_err), .dma_rdata(dma_rdata),
        .lasi_eir_req(l_eir_req), .lasi_eir_addr(l_eir_addr), .lasi_eir_data(l_eir_data),
        .lasi_eir_ack(l_eir_ack), .lasi_eir_err(l_eir_err),
        .ext_toc(ext_toc), .bcast_reset(bcast_reset),
        .dbg_buserr(dbg_buserr), .dbg_buserr_addr(dbg_buserr_addr));

    // ------------------------------------------------------- GSC devices
    logic        x_ack, l_ack, w_ack, w_err;
    logic [31:0] x_rdata, l_rdata, w_rdata;
    logic        artist_rst;

    hp_xbus u_xbus (
        .clk(clk), .rst_n(rst_n), .cfg_model(model_id),
        .req(gsc_req && gsc_dev == 2'd0), .we(gsc_we), .addr(gsc_addr), .be(gsc_be), .wdata(gsc_wdata),
        .ack(x_ack), .rdata(x_rdata), .led_latch(led_latch), .led_strobe(led_strobe),
        .ee_haddr(ee_haddr), .ee_hwe(ee_hwe), .ee_hwdata(ee_hwdata), .ee_hrdata(ee_hrdata),
        .ee_dirty(ee_dirty), .ee_dirty_clr(ee_dirty_clr));

    lasi #(.CLK_HZ(CLK_HZ), .SIM_FAST(SIM_FAST)) u_lasi (
        .clk(clk), .rst_n(rst_n),
        .req(gsc_req && gsc_dev == 2'd1), .we(gsc_we), .addr(gsc_addr), .be(gsc_be), .wdata(gsc_wdata),
        .ack(l_ack), .rdata(l_rdata),
        .eir_req(l_eir_req), .eir_addr(l_eir_addr), .eir_data(l_eir_data), .eir_ack(l_eir_ack), .eir_err(l_eir_err),
        .ext_int(toc_button), .ext_toc(ext_toc),
        .uart_txd(uart_txd), .uart_rxd(uart_rxd), .uart_tap_strobe(uart_tap_strobe), .uart_tap_byte(uart_tap_byte),
        .uart_inj_strobe(uart_inj_strobe), .uart_inj_byte(uart_inj_byte), .uart_inj_full(uart_inj_full),
        .kbd_present(1'b1), .mouse_present(1'b1), .ps2_key(ps2_key), .ps2_mouse(ps2_mouse),
        .rtc_set(rtc_set), .rtc_value(rtc_value),
        .scsi_req(s_req), .scsi_we(s_we), .scsi_addr(s_addr), .scsi_be(s_be), .scsi_wdata(s_wdata),
        .scsi_rdata(s_rdata), .scsi_rst(s_rst), .scsi_irq(s_irq),
        .pcr(lasi_pcr), .artist_rst(artist_rst));

    // ------------------------------------------------------------ SCSI
    logic        s_req, s_we, s_rst, s_irq;
    logic [11:0] s_addr;
    logic [3:0]  s_be;
    logic [31:0] s_wdata, s_rdata;
    logic        sb_sel, sb_sel_atn, sb_sel_done, sb_sel_fail, sb_bsy, sb_req, sb_ack, sb_ackhold, sb_atn, sb_rst;
    logic [2:0]  sb_sel_id, sb_phase;
    logic [7:0]  sb_tdata, sb_idata;

    ncr53c710 #(.STO_CLKS(SIM_FAST ? 200_000 : CLK_HZ / 4)) u_scsi (
        .clk(clk), .rst(s_rst),
        .req(s_req), .we(s_we), .addr(s_addr), .be(s_be), .wdata(s_wdata), .rdata(s_rdata), .irq(s_irq),
        .dma_req(dma_req), .dma_we(dma_we), .dma_addr(dma_addr), .dma_be(dma_be), .dma_wdata(dma_wdata),
        .dma_ack(dma_ack), .dma_err(dma_err), .dma_rdata(dma_rdata),
        .sb_sel(sb_sel), .sb_sel_id(sb_sel_id), .sb_sel_atn(sb_sel_atn), .sb_sel_done(sb_sel_done),
        .sb_sel_fail(sb_sel_fail), .sb_bsy(sb_bsy), .sb_req(sb_req), .sb_phase(sb_phase), .sb_tdata(sb_tdata),
        .sb_ack(sb_ack), .sb_idata(sb_idata), .sb_ackhold(sb_ackhold), .sb_atn(sb_atn), .sb_rst(sb_rst),
        .dbg_dec(s_dec), .dbg_dsp(s_dsp), .dbg_ins(s_ins), .dbg_dsps(s_dsps), .dbg_dstat(s_dstat),
        .dbg_sstat0(s_sstat0));

    // ---------------------------------------------------- debug events
    // types: 1 SCSI bus byte (aux = phase), 2 SCRIPTS instruction (addr =
    // DSP, data = {DCMD/DBC, DSPS}), 3 SCSI interrupt (data = {DSTAT,
    // SSTAT0, DSPS}), 4/5 DMA read/write done (aux = byte enables), 6/7 CPU
    // line read/write accepted (a read's aux bit 0 = I-cache fill), 8/9 CPU
    // uncached read/write of RAM or the 53C710 (aux = byte enables, data as
    // read/written), 10 selection (aux = ID, data = 1 answered / 0 nobody),
    // 11 interruption taken (aux = vector, addr = IIAOQ front, data =
    // {instruction word, IIASQ, PSW[15:0]}), 12 cache maintenance done (aux
    // = {I side, 3'b0, operation}, addr = the physical line {RPN, VA[11:0]},
    // data = {VA, 32'd0}; of a run of FDCE or FICE only the first). Each
    // source has a one-deep slot; the lowest-numbered full slot goes out
    // each cycle.
    //
    // Freeze: 1024 events after a user-mode (PL 3) illegal-instruction,
    // privileged-operation or privileged-register trap (8, 10, 11) the
    // recorder stops until the next reset, so the ring keeps what led up to
    // it (HP-UX's user processes dying of SIGILL on stale text, 2026-10-09).
    logic        s_dec;
    logic [31:0] s_dsp, s_ins, s_dsps;
    logic [7:0]  s_dstat, s_sstat0;
    logic        ev_ack_q, ev_irq_q, ev_dec_q;
    logic [32:0] ev_line_q;
    logic [9:0]  ev_full;
    logic [111:0] ev_slot [10];
    logic [10:0] ev_freeze_cnt;
    logic        ev_freeze_arm, ev_frozen;
    logic [4:0]  ev_cop_q;
    always_ff @(posedge clk) begin
        logic [9:0]   set;
        logic [111:0] e [10];
        set = '0;
        for (int i = 0; i < 10; i++) e[i] = '0;
        ev_ack_q <= sb_ack; ev_irq_q <= s_irq; ev_dec_q <= s_dec;
        if (sb_ack && !ev_ack_q) begin set[0] = 1; e[0] = {8'd1, 5'd0, sb_phase, 32'd0, 56'd0, sb_phase[0] ? sb_tdata : sb_idata}; end
        if (s_dec && !ev_dec_q) begin set[1] = 1; e[1] = {8'd2, 8'd0, s_dsp, s_ins, s_dsps}; end
        if (s_irq && !ev_irq_q) begin set[2] = 1; e[2] = {8'd3, 8'd0, 32'd0, s_dstat, s_sstat0, 16'd0, s_dsps}; end
        if (dma_ack) begin set[3] = 1; e[3] = {dma_we ? 8'd5 : 8'd4, dma_be, dma_addr, dma_we ? dma_wdata : dma_rdata}; end
        // a line read repeating the previous one (a polling loop) is not recorded
        if (mem_req && mem_ack) begin
            ev_line_q <= {mem_we, mem_addr};
            if ({mem_we, mem_addr} != ev_line_q) begin set[4] = 1; e[4] = {mem_we ? 8'd7 : 8'd6, 7'd0, mem_ifill & ~mem_we, mem_addr, 64'd0}; end
        end
        if (io_req && io_ack && !io_ifetch && (io_addr[31:12] == 20'hF0106 || io_addr[31:28] != 4'hF)) begin
            set[5] = 1; e[5] = {io_we ? 8'd9 : 8'd8, io_be, io_addr, io_we ? io_wdata : io_rdata};
        end
        if (sb_sel_done || sb_sel_fail) begin set[6] = 1; e[6] = {8'd10, 5'd0, sb_sel_id, 32'd0, 63'd0, sb_sel_done}; end
        if (dbg_trap) begin set[7] = 1; e[7] = {8'd11, 2'd0, dbg_trap_vec, dbg_iaoq_f, dbg_insn, c_iasq_f, dbg_psw[15:0]}; end
        // a whole-cache loop (FDCE/FICE, op 2 on either side) is recorded by its first operation only
        if (c_cop_valid) begin
            ev_cop_q <= {c_cop_i, c_cop};
            if (!(c_cop == 4'd2 && {c_cop_i, c_cop} == ev_cop_q)) begin
                set[8] = 1; e[8] = {8'd12, c_cop_i, 3'd0, c_cop, c_cop_rpn, c_cop_addr[11:0], c_cop_addr, 32'd0};
            end
        end
        if (ev_frozen) set = '0;
        dbg_ev_valid <= 1'b0;
        if (!rst_n) begin
            ev_full <= '0; ev_freeze_arm <= 1'b0; ev_frozen <= 1'b0; ev_freeze_cnt <= '0;
        end else begin
            if (dbg_trap && dbg_iaoq_f[1:0] == 2'b11 && !ev_freeze_arm
                && (dbg_trap_vec == 6'd8 || dbg_trap_vec == 6'd10 || dbg_trap_vec == 6'd11)) begin
                ev_freeze_arm <= 1'b1; ev_freeze_cnt <= 11'd1024;
            end else if (ev_freeze_arm && !ev_frozen && |set) begin
                if (ev_freeze_cnt == 11'd0) ev_frozen <= 1'b1;
                else ev_freeze_cnt <= ev_freeze_cnt - 11'd1;
            end
        end
        if (rst_n) begin
            logic sent;
            sent = 1'b0;
            for (int i = 0; i < 10; i++) begin
                if (ev_full[i] && !sent) begin
                    dbg_ev_valid <= 1'b1; dbg_ev <= ev_slot[i]; sent = 1'b1;
                    ev_full[i] <= 1'b0;
                end
            end
            for (int i = 0; i < 10; i++) if (set[i]) begin ev_full[i] <= 1'b1; ev_slot[i] <= e[i]; end
        end
    end

    scsi_targets u_targets (
        .clk(clk), .rst(!rst_n),
        .sel(sb_sel), .sel_id(sb_sel_id), .sel_atn(sb_sel_atn), .sel_done(sb_sel_done), .sel_fail(sb_sel_fail),
        .bsy(sb_bsy), .req(sb_req), .phase(sb_phase), .tdata(sb_tdata), .ack(sb_ack), .idata(sb_idata),
        .ackhold(sb_ackhold), .atn(sb_atn), .brst(sb_rst),
        .img_present(img_present), .img_blocks(img_blocks),
        .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
        .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
        .sd_buff_wr(sd_buff_wr), .activity(scsi_activity));

    wax_stub u_wax (
        .clk(clk), .rst_n(rst_n), .req(gsc_req && gsc_dev == 2'd2), .we(gsc_we), .addr(gsc_addr),
        .ack(w_ack), .err(w_err), .rdata(w_rdata));

`ifdef SIMULATION
    // dbg_ctl[0]: every GSC access (device, address, byte enables, data)
    logic gsc_pend_we;
    logic [31:0] gsc_pend_addr, gsc_pend_wdata;
    logic [3:0]  gsc_pend_be;
    logic [1:0]  gsc_pend_dev;
    always_ff @(posedge clk) if (dbg_ctl[0]) begin
        if (gsc_req) begin
            gsc_pend_we <= gsc_we; gsc_pend_addr <= gsc_addr; gsc_pend_wdata <= gsc_wdata;
            gsc_pend_be <= gsc_be; gsc_pend_dev <= gsc_dev;
        end
        if (gsc_ack)
            $display("gsc %0d %s %08x be=%x %08x%s", gsc_pend_dev, gsc_pend_we ? "W" : "R", gsc_pend_addr,
                     gsc_pend_be, gsc_pend_we ? gsc_pend_wdata : gsc_rdata, gsc_err ? " ERR" : "");
    end

    // dbg_ctl[1]: the I-cache's diagnose writes, flushes and the L1 entries
    // of line 0 (the 0x41094 stale-L1 investigation, cpu-requests #4)
    always_ff @(posedge clk) if (dbg_ctl[1]) begin
        if (u_cpu.u_icache.st == 3 && !u_cpu.u_icache.cur_fill)
            $display("IC op=%0d addr=%08x e_idx=%04x hash=%02x wdata=%08x", u_cpu.u_icache.op, u_cpu.u_icache.op_addr,
                     u_cpu.u_icache.e_idx, u_cpu.u_icache.e_hash, u_cpu.u_icache.op_wdata);
        if (u_cpu.u_icache.l1_we && u_cpu.u_icache.l1_waddr < 7'd4)
            $display("L1 wr st=%0d idx=%0d rpn=%05x dw=%016x", u_cpu.u_icache.st, u_cpu.u_icache.l1_waddr,
                     u_cpu.u_icache.l1_wdata[85:66], u_cpu.u_icache.l1_wdata[63:0]);
        if (u_cpu.u_icache.lk_valid && u_cpu.u_icache.f1_addr[31:5] == 27'd0)
            $display("IF  addr=%08x hash=%02x l1hit=%0d l2hit=%0d word=%08x", u_cpu.u_icache.f1_addr,
                     u_cpu.u_icache.lk_hash, u_cpu.u_icache.l1_hit, u_cpu.u_icache.l2_hit, u_cpu.u_icache.f1_word);
    end
`endif

`ifdef SIMULATION
    // dbg_ctl[3]: the MIOC's transactions as it accepts them (line port,
    // uncached port, DMA) and its RAM requests
    always_ff @(posedge clk) if (dbg_ctl[3]) begin
        if (u_mioc.st == 0 && !(u_mioc.lasi_eir_req && !u_mioc.lasi_eir_ack && !u_mioc.lasi_eir_err)) begin
            if (mem_req) $display("MIO line %s %08x", mem_we ? "W" : "R", mem_addr);
            else if (dma_req && !dma_ack) $display("MIO dma  %s %08x be=%02x %016x", dma_we ? "W" : "R", dma_addr, dma_be, dma_wdata);
            else if (io_req) $display("MIO io   %s %08x be=%02x %016x", io_we ? "W" : "R", io_addr, io_be, io_wdata);
        end
        if (ram_req && ram_ack) $display("MIO ram  %s %07x line=%0d be=%02x", ram_we ? "W" : "R", ram_addr, ram_line, ram_be);
    end

    // dbg_ctl[2]: the 53C710 -- SCRIPTS instructions as decoded, selections,
    // interrupt status, the bytes on the bus, the block-device requests
    logic       sc_irq_q, sc_req_q, sc_ack_q;
    always_ff @(posedge clk) if (dbg_ctl[2]) begin
        sc_irq_q <= s_irq; sc_req_q <= sb_req; sc_ack_q <= sb_ack;
        if (u_scsi.est == 5'd2)
            $display("SCR %08x: %08x %08x", u_scsi.dsp - (u_scsi.ins0[31:30] == 2'b11 ? 32'd12 : 32'd8),
                     u_scsi.ins0, u_scsi.dsps);
        if (sb_sel) $display("SCR select id %0d atn %0d", sb_sel_id, sb_sel_atn);
        if (sb_sel_done) $display("SCR selected");
        if (sb_sel_fail) $display("SCR no target");
        if (s_irq && !sc_irq_q)
            $display("SCR IRQ dstat %02x sstat0 %02x dsps %08x dsp %08x", u_scsi.dstat, u_scsi.sstat0_st,
                     u_scsi.dsps, u_scsi.dsp);
        if (sb_ack && !sc_ack_q)
            $display("SCR byte ph %0d %02x", sb_phase, sb_phase[0] ? sb_tdata : sb_idata);
        if (|sd_rd) $display("SCR sd_rd %b lba %0d cnt %0d", sd_rd, sd_lba[0], sd_blk_cnt[0] + 1);
        if (|sd_wr) $display("SCR sd_wr %b lba %0d cnt %0d", sd_wr, sd_lba[0], sd_blk_cnt[0] + 1);
    end
`endif

    // Artist (gsc_dev 3) does not exist yet: HAS_ARTIST = 0 makes the MIOC
    // bus-error its range, so nothing is ever sent to it
    always_comb begin
        gsc_ack = x_ack | l_ack | w_ack;
        gsc_err = w_ack & w_err;
        gsc_rdata = x_ack ? x_rdata : l_ack ? l_rdata : w_rdata;
    end
endmodule
