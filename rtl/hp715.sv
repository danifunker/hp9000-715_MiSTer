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

    pa_cpu u_cpu (
        .clk(clk), .rst_n(rst_n), .cfg_tq(rsel[47:32]), .cfg_tr(rsel[31:16]), .cfg_td(rsel[15:0]),
        .mem_req(mem_req), .mem_we(mem_we), .mem_ifill(mem_ifill), .mem_addr(mem_addr), .mem_ack(mem_ack),
        .mem_wdata(mem_wdata), .mem_wvalid(mem_wvalid), .mem_wready(mem_wready), .mem_rdata(mem_rdata),
        .mem_rvalid(mem_rvalid), .mem_rbeat(mem_rbeat), .mem_rerr(mem_rerr),
        .io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_be(io_be), .io_wdata(io_wdata),
        .io_ifetch(io_ifetch), .io_burst(io_burst), .io_rclr(io_rclr), .io_ack(io_ack), .io_last(io_last),
        .io_rdata(io_rdata), .io_err(io_err),
        .eir_set(eir_set), .eir_num(eir_num), .toc_req(toc_req), .hpmc_req(hpmc_req), .lpmc_req(lpmc_req),
        .powerfail(1'b0), .soft_pwr_n(soft_pwr_n),
        .dbg_retire(dbg_retire), .dbg_nullified(dbg_nullified), .dbg_iaoq_f(dbg_iaoq_f), .dbg_iaoq_b(dbg_iaoq_b),
        .dbg_iasq_f(), .dbg_insn(dbg_insn), .dbg_trap(dbg_trap), .dbg_trap_vec(dbg_trap_vec),
        .dbg_gr_we(), .dbg_gr_num0(), .dbg_gr_num1(), .dbg_gr_data0(), .dbg_gr_data1(),
        .dbg_psw(dbg_psw), .dbg_halted(dbg_halted), .dbg_gr(dbg_gr));

    // --------------------------------------------------------------- MIOC
    logic        gsc_req, gsc_we, gsc_ack, gsc_err;
    logic [1:0]  gsc_dev;
    logic [31:0] gsc_addr, gsc_wdata, gsc_rdata;
    logic [3:0]  gsc_be;
    logic        l_eir_req, l_eir_ack, l_eir_err, ext_toc;
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
        .ram_rdata(ram_rdata),
        .chk_req(chk_req), .chk_we(chk_we), .chk_addr(chk_addr), .chk_be(chk_be), .chk_wdata(chk_wdata),
        .chk_ack(chk_ack), .chk_rdata(chk_rdata),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_rvalid(rom_rvalid),
        .rom_rdata(rom_rdata), .rom_inval(rom_inval),
        .gsc_req(gsc_req), .gsc_we(gsc_we), .gsc_dev(gsc_dev), .gsc_addr(gsc_addr), .gsc_be(gsc_be),
        .gsc_wdata(gsc_wdata), .gsc_ack(gsc_ack), .gsc_err(gsc_err), .gsc_rdata(gsc_rdata),
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
        .pcr(lasi_pcr), .artist_rst(artist_rst));

    wax_stub u_wax (
        .clk(clk), .rst_n(rst_n), .req(gsc_req && gsc_dev == 2'd2), .we(gsc_we), .addr(gsc_addr),
        .ack(w_ack), .err(w_err), .rdata(w_rdata));

`ifdef SIMULATION
    // +gsctrace: every GSC access (device, address, byte enables, data)
    logic gsc_trace, gsc_pend_we;
    logic [31:0] gsc_pend_addr, gsc_pend_wdata;
    logic [3:0]  gsc_pend_be;
    logic [1:0]  gsc_pend_dev;
    initial gsc_trace = $test$plusargs("gsctrace");
    always_ff @(posedge clk) if (gsc_trace) begin
        if (gsc_req) begin
            gsc_pend_we <= gsc_we; gsc_pend_addr <= gsc_addr; gsc_pend_wdata <= gsc_wdata;
            gsc_pend_be <= gsc_be; gsc_pend_dev <= gsc_dev;
        end
        if (gsc_ack)
            $display("gsc %0d %s %08x be=%x %08x%s", gsc_pend_dev, gsc_pend_we ? "W" : "R", gsc_pend_addr,
                     gsc_pend_be, gsc_pend_we ? gsc_pend_wdata : gsc_rdata, gsc_err ? " ERR" : "");
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
