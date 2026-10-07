// PA-RISC 1.1 load/store address generation and data formatting.
//
// Address: the offset (Pa11_acd chapter 5, "Indexed Loads", "Short
// Displacement Loads and Stores", LDWM/STWM, STBYS) is GR[b] plus either
// the sign-extended displacement or the (optionally scaled) index -- or
// GR[b] alone for the post-modify forms -- and GR[b] is optionally updated
// to the sum. The decoder chooses the mode; this unit only computes:
//   indexed ,m / ,sm          offset = GR[b];     GR[b] += index
//   short ,ma                 offset = GR[b];     GR[b] += disp
//   short ,mb                 offset = GR[b]+disp; GR[b] += disp
//   LDWM/STWM                 pre-modify if disp < 0, else post-modify
//   STBYS ,b,m                offset = GR[b];     GR[b] = (GR[b]+disp) & ~3
//   STBYS ,e,m                offset = GR[b]+disp; GR[b] = (GR[b]+disp) & ~3
// Data (big-endian, byte 0 = bits 31:24 of the word):
//   stores: byte enables + data on the word lanes; STBYS ,b stores bytes
//   pos..3 of GR[r], ,e bytes 0..pos-1 (nothing when pos = 0)
//   loads: extract and zero-extend
// PSW[E] (little-endian) is not supported here: docs/STUBS.md.
// Pure combinational.
module pa_ldst (
    // address generation
    input  logic [31:0] base,         // GR[b]
    input  logic [31:0] index,        // GR[x]
    input  logic [31:0] disp,         // sign-extended displacement
    input  logic        use_index,    // indexed form
    input  logic        scale,        // ,s: index * size
    input  logic        ea_is_base,   // post-modify: offset = GR[b]
    input  logic        base_trunc,   // STBYS ,m: new GR[b] word-aligned
    input  logic [1:0]  size,         // 0 byte, 1 halfword, 2 word
    output logic [31:0] ea,
    output logic [31:0] new_base,     // the decoder decides whether to write it
    output logic        unaligned,    // unaligned data reference
    // stores
    input  logic [1:0]  stbys,        // 0 normal, 1 STBYS,B, 2 STBYS,E
    input  logic [31:0] st_src,       // GR[r]
    output logic [3:0]  st_be,        // byte enables, [3] = byte 0
    output logic [31:0] st_data,
    // loads
    input  logic [31:0] ld_word,      // the aligned word read at ea
    output logic [31:0] ld_data
);
    logic [31:0] off, sum;
    always_comb begin
        if (use_index)
            off = scale ? (index << size) : index;
        else
            off = disp;
        sum      = base + off;
        ea       = ea_is_base ? base : sum;
        new_base = base_trunc ? {sum[31:2], 2'b00} : sum;
    end

    always_comb
        case (size)
            2'd0:    unaligned = 1'b0;
            2'd1:    unaligned = ea[0];
            default: unaligned = (stbys == 2'd0) && (ea[1:0] != 2'b00);
        endcase

    always_comb begin
        st_data = st_src;
        case (stbys)
            2'd1: st_be = 4'b1111 >> ea[1:0];                   // bytes pos..3
            2'd2: st_be = ~(4'b1111 >> ea[1:0]);                // bytes 0..pos-1
            default:
                case (size)
                    2'd0: begin
                        st_be   = 4'b1000 >> ea[1:0];
                        st_data = {4{st_src[7:0]}};
                    end
                    2'd1: begin
                        st_be   = ea[1] ? 4'b0011 : 4'b1100;
                        st_data = {2{st_src[15:0]}};
                    end
                    default: st_be = 4'b1111;
                endcase
        endcase
    end

    always_comb
        case (size)
            2'd0:    ld_data = {24'd0, ld_word[8 * (3 - ea[1:0]) +: 8]};
            2'd1:    ld_data = {16'd0, ea[1] ? ld_word[15:0] : ld_word[31:16]};
            default: ld_data = ld_word;
        endcase
endmodule
