// The MiSTer keyboard as a serial terminal's keyboard (with
// rtl/mister/serial_term.sv, until Artist and its console exist): hps_io's
// key events (ps2_key: [10] toggles per event, [9] pressed, [8] E0 prefix,
// [7:0] the set-2 code) to US-layout ASCII, one byte per key press, for the
// LASI UART's receive side. Shift, Ctrl (letter & 0x1F) and Caps Lock;
// Enter = CR, Backspace = BS, Tab, Esc, Delete = DEL; cursor keys, function
// keys and the keypad (but its Enter) send nothing.
module ps2_ascii (
    input  logic        clk,
    input  logic        rst,
    input  logic [10:0] ps2_key,
    output logic        strobe,
    output logic [7:0]  ascii
);
    logic       tog_q, lshift, rshift, lctrl, rctrl, caps;

    // {unshifted, shifted} for a set-2 code without the E0 prefix
    function automatic logic [15:0] map(input logic [7:0] k);
        case (k)
            8'h1C: return {8'h61, 8'h41}; 8'h32: return {8'h62, 8'h42}; 8'h21: return {8'h63, 8'h43};
            8'h23: return {8'h64, 8'h44}; 8'h24: return {8'h65, 8'h45}; 8'h2B: return {8'h66, 8'h46};
            8'h34: return {8'h67, 8'h47}; 8'h33: return {8'h68, 8'h48}; 8'h43: return {8'h69, 8'h49};
            8'h3B: return {8'h6A, 8'h4A}; 8'h42: return {8'h6B, 8'h4B}; 8'h4B: return {8'h6C, 8'h4C};
            8'h3A: return {8'h6D, 8'h4D}; 8'h31: return {8'h6E, 8'h4E}; 8'h44: return {8'h6F, 8'h4F};
            8'h4D: return {8'h70, 8'h50}; 8'h15: return {8'h71, 8'h51}; 8'h2D: return {8'h72, 8'h52};
            8'h1B: return {8'h73, 8'h53}; 8'h2C: return {8'h74, 8'h54}; 8'h3C: return {8'h75, 8'h55};
            8'h2A: return {8'h76, 8'h56}; 8'h1D: return {8'h77, 8'h57}; 8'h22: return {8'h78, 8'h58};
            8'h35: return {8'h79, 8'h59}; 8'h1A: return {8'h7A, 8'h5A};
            8'h45: return {8'h30, 8'h29}; 8'h16: return {8'h31, 8'h21}; 8'h1E: return {8'h32, 8'h40};
            8'h26: return {8'h33, 8'h23}; 8'h25: return {8'h34, 8'h24}; 8'h2E: return {8'h35, 8'h25};
            8'h36: return {8'h36, 8'h5E}; 8'h3D: return {8'h37, 8'h26}; 8'h3E: return {8'h38, 8'h2A};
            8'h46: return {8'h39, 8'h28};
            8'h0E: return {8'h60, 8'h7E}; 8'h4E: return {8'h2D, 8'h5F}; 8'h55: return {8'h3D, 8'h2B};
            8'h5D: return {8'h5C, 8'h7C}; 8'h54: return {8'h5B, 8'h7B}; 8'h5B: return {8'h5D, 8'h7D};
            8'h4C: return {8'h3B, 8'h3A}; 8'h52: return {8'h27, 8'h22}; 8'h41: return {8'h2C, 8'h3C};
            8'h49: return {8'h2E, 8'h3E}; 8'h4A: return {8'h2F, 8'h3F};
            8'h29: return {8'h20, 8'h20};
            8'h5A: return {8'h0D, 8'h0D}; 8'h66: return {8'h08, 8'h08};
            8'h0D: return {8'h09, 8'h09}; 8'h76: return {8'h1B, 8'h1B};
            default: return 16'd0;
        endcase
    endfunction

    always_ff @(posedge clk) begin
        strobe <= 1'b0;
        tog_q <= ps2_key[10];
        if (rst) begin
            lshift <= 0; rshift <= 0; lctrl <= 0; rctrl <= 0; caps <= 0;
        end else if (ps2_key[10] != tog_q) begin
            logic       dn, ext, shift, ctrl;
            logic [7:0] k, c;
            logic [15:0] m;
            dn = ps2_key[9]; ext = ps2_key[8]; k = ps2_key[7:0];
            shift = lshift || rshift; ctrl = lctrl || rctrl;
            if (!ext && k == 8'h12) lshift <= dn;
            else if (!ext && k == 8'h59) rshift <= dn;
            else if (k == 8'h14) begin if (ext) rctrl <= dn; else lctrl <= dn; end
            else if (!ext && k == 8'h58) begin if (dn) caps <= !caps; end
            else if (dn) begin
                if (ext) c = (k == 8'h5A) ? 8'h0D : (k == 8'h71) ? 8'h7F : (k == 8'h4A) ? 8'h2F : 8'h00;
                else begin
                    m = map(k);
                    // Caps Lock shifts letters only
                    c = (shift ^ (caps && m[15:8] >= 8'h61 && m[15:8] <= 8'h7A)) ? m[7:0] : m[15:8];
                    if (ctrl && m[15:8] >= 8'h61 && m[15:8] <= 8'h7A) c = m[15:8] & 8'h1F;
                end
                if (c != 8'h00) begin strobe <= 1'b1; ascii <= c; end
            end
        end
    end
endmodule
