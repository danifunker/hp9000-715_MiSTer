// tb_term -- rtl/mister/serial_term.sv with the top's 640x480 counters:
// types console text into it, then writes one frame as a PPM (term.ppm).
//   make -C verilator tb_term
module tb_term (input logic clk);
    logic [1:0] pdiv = 0;
    logic [9:0] hc = 0, vc = 0;
    always_ff @(posedge clk) begin
        pdiv <= (pdiv == 2'd2) ? 2'd0 : pdiv + 2'd1;
        if (pdiv == 2'd2) begin
            if (hc == 10'd679) begin hc <= 0; vc <= (vc == 10'd524) ? 10'd0 : vc + 10'd1; end
            else hc <= hc + 10'd1;
        end
    end
    logic        rst, tx;
    logic [7:0]  txb;
    logic [7:0]  r, g, b;
    logic        hs, vs, de;
    serial_term #(.FONT("../../rtl/mister/font8x16.hex")) dut (.clk(clk), .rst(rst), .pclk(clk), .tx_strobe(tx), .tx_byte(txb), .leds(8'b1101_1110), .pwr(1'b1),
        .pix_ce(pdiv == 2'd0), .hc(hc), .vc(vc), .hs_in(hc >= 10'd656 && hc < 10'd672),
        .vs_in(vc >= 10'd490 && vc < 10'd492), .de_in(hc < 10'd640 && vc < 10'd480),
        .r(r), .g(g), .b(b), .hs(hs), .vs(vs), .de(de));

    string text = {"\x1b[2J\x1b[H0x04.1081\r\n0x04.2097\r\n",
                   "-----------------------------------------------------------------\r\n",
                   "BootRom Version    1.6\r\nMemory Size:  64 MB\r\n\r\n",
                   "BOOT_ADMIN> search\r\n   Device Path              Device Type\r\n",
                   "   scsi.6.0                 SEAGATE ST32550N\r\n\r\nBOOT_ADMIN> bo\x08\x08boot\tscsi.6"};
    int fd, k = 0, n = 0, px = 0, frame = 0;
    logic vs_q = 0;
    initial begin rst = 1; tx = 0; end
    always_ff @(posedge clk) begin
        n <= n + 1;
        tx <= 0;
        if (n == 10) rst <= 0;
        if (n > 5000 && n % 3000 == 0 && k < text.len()) begin tx <= 1; txb <= text[k]; k <= k + 1; end
        vs_q <= vs;
        if (vs && !vs_q && k == text.len()) frame <= frame + 1;
        if (frame == 1 && pdiv == 2'd1 && de) begin
            if (px == 0) begin fd = $fopen("term.ppm", "wb"); $fwrite(fd, "P6 640 480 255\n"); end
            $fwrite(fd, "%c%c%c", r, g, b);
            px <= px + 1;
            if (px == 640 * 480 - 1) begin $fclose(fd); $finish; end
        end
    end
endmodule
