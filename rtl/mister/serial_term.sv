// The MiSTer screen until Artist exists (STUBS S-018): the machine's RS-232
// console as text, 80 x 29 characters of 8 x 16 on a 640 x 480 picture,
// with the front-panel LEDs and the power LED on a status line below.
//
// The terminal takes what the machine transmits (the LASI UART's output
// tap): printable ASCII at the cursor, CR, LF (scrolling at the bottom),
// BS, TAB; ESC [ ... H homes the cursor, ESC [ ... J clears the screen,
// ESC [ ... K the rest of the line; every other escape sequence is skipped.
// Bytes come at most one per character time (9600 baud: ~67k clocks), so
// the clearing loops never fall behind.
//
// Video, on the pixel clock pclk: the caller's 640 x 480 counters (hc, vc)
// change on the clock before pix_ce, at least three pclks apart; the
// colours, syncs and DE are registered on pix_ce, one pixel after the
// counters (the syncs given here are delayed to match). The text is kept on
// clk; the picture reads it through a dual-clock RAM, and the scroll offset
// and the LEDs through two flops each (a scroll can show one wrong
// character for a frame).
module serial_term #(
    parameter FONT = "rtl/mister/font8x16.hex"      // relative to the Quartus project
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       pclk,
    // the console
    input  logic       tx_strobe,
    input  logic [7:0] tx_byte,
    // status line
    input  logic [7:0] leds,            // the LED latch, active low
    input  logic       pwr,             // the power LED is lit
    // video (pclk)
    input  logic       pix_ce,
    input  logic [9:0] hc, vc,
    input  logic       hs_in, vs_in, de_in,
    output logic [7:0] r, g, b,
    output logic       hs, vs, de
);
    localparam int COLS = 80, ROWS = 29;

    // ---------------------------------------------------------- the text
    (* ramstyle = "M10K" *) logic [7:0] tbuf [0:4095];
    logic [11:0] w_addr;
    logic [7:0]  w_data;
    logic        w_en;
    always_ff @(posedge clk) if (w_en) tbuf[w_addr] <= w_data;

    logic [7:0] font [0:2047];
    initial $readmemh(FONT, font);

    logic [6:0]  col;               // cursor
    logic [4:0]  row;               // logical row 0..ROWS-1
    logic [4:0]  top;               // physical row of logical row 0
    logic [1:0]  esc;               // 0 text, 1 after ESC, 2 in ESC [
    // clearing: cells [clr_from, clr_to) of the screen, physical order
    logic        clearing;
    logic [11:0] clr_at, clr_end;
    logic        rx_pend;
    logic [7:0]  rx_b;

    function automatic logic [4:0] prow(input logic [4:0] t_, input logic [4:0] r_);
        logic [5:0] p;
        p = {1'b0, t_} + {1'b0, r_};
        return p >= 6'(ROWS) ? 5'(p - 6'(ROWS)) : p[4:0];
    endfunction
    function automatic logic [11:0] cell_ix(input logic [4:0] pr, input logic [6:0] c);
        return 12'(pr) * 12'd80 + 12'(c);
    endfunction

    always_ff @(posedge clk) begin
        w_en <= 1'b0;
        if (tx_strobe) begin rx_pend <= 1'b1; rx_b <= tx_byte; end
        if (rst) begin
            col <= 0; row <= 0; top <= 0; esc <= 0; rx_pend <= 1'b0;
            clearing <= 1'b1; clr_at <= 0; clr_end <= 12'(COLS * ROWS);
        end else if (clearing) begin
            w_en <= 1'b1; w_addr <= clr_at; w_data <= 8'h20;
            clr_at <= clr_at + 12'd1;
            if (clr_at + 12'd1 == clr_end) clearing <= 1'b0;
        end else if (rx_pend) begin
            logic [7:0] c;
            c = rx_b;
            rx_pend <= 1'b0;
            if (esc == 2'd1) esc <= (c == 8'h5B) ? 2'd2 : 2'd0;          // ESC [
            else if (esc == 2'd2) begin
                if (c >= 8'h40 && c <= 8'h7E) begin                      // the final byte
                    esc <= 2'd0;
                    case (c)
                        8'h48, 8'h66: begin row <= 0; col <= 0; end      // H, f: home
                        8'h4A: begin clearing <= 1'b1; clr_at <= 0; clr_end <= 12'(COLS * ROWS); end
                        8'h4B: begin
                            clearing <= 1'b1; clr_at <= cell_ix(prow(top, row), col);
                            clr_end <= cell_ix(prow(top, row), 7'd0) + 12'd80;
                        end
                        default: ;
                    endcase
                end
            end else case (c)
                8'h1B: esc <= 2'd1;
                8'h0D: col <= 0;
                8'h08: if (col != 0) col <= col - 7'd1;
                8'h09: col <= (col | 7'd7) == 7'd79 ? 7'd79 : (col | 7'd7) + 7'd1;
                8'h0A: begin
                    if (row != 5'(ROWS - 1)) row <= row + 5'd1;
                    else begin
                        // scroll: the top row becomes the new bottom one, cleared
                        clearing <= 1'b1; clr_at <= cell_ix(top, 7'd0); clr_end <= cell_ix(top, 7'd0) + 12'd80;
                        top <= (top == 5'(ROWS - 1)) ? 5'd0 : top + 5'd1;
                    end
                end
                default: if (c >= 8'h20 && c < 8'h7F) begin
                    w_en <= 1'b1; w_addr <= cell_ix(prow(top, row), col); w_data <= c;
                    if (col != 7'(COLS - 1)) col <= col + 7'd1;
                    else begin
                        col <= 0;
                        // wrap: as LF
                        rx_pend <= 1'b1; rx_b <= 8'h0A;
                    end
                end
            endcase
        end
    end

    // ---------------------------------------------------------- the picture
    // three clocks per pixel: read the character, then its font row, then
    // register the pixel with the delayed syncs on pix_ce
    wire        in_text = vc < 10'(ROWS * 16) && hc < 10'd640;
    wire [4:0]  t_row = 5'(vc[9:4]);
    logic [11:0] r_addr;
    logic [7:0]  ch, fbits;
    logic [2:0]  px_x, px_x2;
    logic [3:0]  px_y;
    logic        txt_q, txt_q2;
    logic [4:0]  top_s1, top_p;
    logic [7:0]  leds_s1, leds_p;
    logic        pwr_s1, pwr_p;
    always_ff @(posedge pclk) begin
        top_s1 <= top; top_p <= top_s1;
        leds_s1 <= leds; leds_p <= leds_s1;
        pwr_s1 <= pwr; pwr_p <= pwr_s1;
    end
    always_ff @(posedge pclk) begin
        r_addr <= cell_ix(prow(top_p, t_row), 7'(hc[9:3]));
        px_x <= hc[2:0]; px_y <= vc[3:0]; txt_q <= in_text;
        ch <= tbuf[r_addr];
        px_x2 <= px_x; txt_q2 <= txt_q;
        fbits <= font[{ch[6:0], px_y}];
    end

    // status line: rows 464..479 -- eight LED squares and the power LED
    wire        in_stat = vc >= 10'(ROWS * 16) + 10'd3 && vc < 10'(ROWS * 16) + 10'd13;
    wire [9:0]  sx = hc - 10'd200;
    wire        in_led = in_stat && hc >= 10'd200 && hc < 10'd440 && sx[4:0] < 5'd20;
    wire [2:0]  led_n = 3'd7 - sx[7:5];
    wire        in_pwr = in_stat && hc >= 10'd470 && hc < 10'd490;

    // the status colour and the syncs of pixel N are taken on its pix_ce and
    // output on the next one, with pixel N's text bit (ready by then)
    logic        hs_d, vs_d, de_d, txt_d;
    logic [23:0] bg_d;
    always_ff @(posedge pclk) if (pix_ce) begin
        hs_d <= hs_in; vs_d <= vs_in; de_d <= de_in;
        if (!de_in)                              bg_d <= 24'h000000;
        else if (in_led)                         bg_d <= leds_p[led_n] ? 24'h302000 : 24'hFFB000;
        else if (in_pwr)                         bg_d <= pwr_p ? 24'h00FF00 : 24'h002000;
        else if (vc == 10'(ROWS * 16) + 10'd1)   bg_d <= 24'h404040;   // a rule above the status line
        else                                     bg_d <= 24'h000000;
        hs <= hs_d; vs <= vs_d; de <= de_d;
        {r, g, b} <= (txt_q2 && fbits[3'd7 - px_x2] && de_d) ? 24'hC8F0C8 : bg_d;
    end
endmodule
