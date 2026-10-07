// PA-7100LC MAX-1 multimedia unit: HADD, HSUB (modular, ,ss signed
// saturation, ,us unsigned saturation), HAVG, HSHLADD and HSHRADD on the
// two 16-bit halfwords of a 32-bit register.
//
// Semantics: PA-RISC 2.0 manual (docs/reference/txt/parisc2.0.txt, the MAX
// pages and Tables 6-3/6-4) applied to 32-bit registers, and the PA7300LC
// ERS chapter 13 (pcxl2_ers.txt); tests/cpu/model.py max1_half() documents
// each choice with page references. MAX-1 never nullifies and leaves the
// PSW C/B bits alone. Pure combinational.
module pa_max1 (
    input  logic [31:0] a,      // GR r1
    input  logic [31:0] b,      // GR r2
    input  logic [2:0]  op,     // 0 HADD, 1 HSUB, 2 HAVG, 3 HSHLADD, 4 HSHRADD
    input  logic [1:0]  sat,    // HADD/HSUB: 0 modular, 1 ,ss, 2 ,us
    input  logic [1:0]  sa,     // HSHLADD/HSHRADD shift amount (1..3)
    output logic [31:0] result
);
    function automatic logic [15:0] clamp_s(input logic signed [19:0] v);
        if (v > 20'sd32767)       clamp_s = 16'h7FFF;
        else if (v < -20'sd32768) clamp_s = 16'h8000;
        else                      clamp_s = v[15:0];
    endfunction

    function automatic logic [15:0] lane(input logic [2:0] op, input logic [1:0] sat,
                                         input logic [1:0] sa,
                                         input logic [15:0] h1, input logic [15:0] h2);
        logic signed [19:0] s1, s2, u1, v, sh;
        logic        [16:0] avg;
        s1 = 20'(signed'(h1));                 // sign-extended
        s2 = 20'(signed'(h2));
        u1 = {4'd0, h1};                       // zero-extended
        lane = 16'h0;
        case (op)
            3'd0, 3'd1: begin
                case (sat)
                    2'd1: begin                // ,ss: both signed
                        v = (op == 3'd0) ? s1 + s2 : s1 - s2;
                        lane = clamp_s(v);
                    end
                    2'd2: begin                // ,us: r1 unsigned, r2 signed
                        v = (op == 3'd0) ? u1 + s2 : u1 - s2;
                        lane = (v < 0) ? 16'h0000 : (v > 20'sd65535) ? 16'hFFFF : v[15:0];
                    end
                    default:                   // modular
                        lane = (op == 3'd0) ? h1 + h2 : h1 - h2;
                endcase
            end
            3'd2: begin                        // HAVG: (h1+h2)>>1, LSB |= bit shifted out
                avg  = {1'b0, h1} + {1'b0, h2};
                lane = avg[16:1] | {15'd0, avg[0]};
            end
            3'd3: begin                        // HSHLADD: pre-shift overflow saturates by h1's sign
                sh = s1 <<< sa;
                if (sh > 20'sd32767)       lane = 16'h7FFF;
                else if (sh < -20'sd32768) lane = 16'h8000;
                else                       lane = clamp_s(sh + s2);
            end
            default: begin                     // HSHRADD: arithmetic shift, add, saturate
                sh   = s1 >>> sa;
                lane = clamp_s(sh + s2);
            end
        endcase
    endfunction

    assign result = {lane(op, sat, sa, a[31:16], b[31:16]), lane(op, sat, sa, a[15:0], b[15:0])};
endmodule
