// PA-7100LC instruction decoder: instruction word -> ctrl_t.
//
// docs/design/cpu.md section 4 is the specification (opcode map, every
// encoding, decode policy: undefined majors / extensions and every PA 2.0-only
// form -> illegal instruction, trap 8). Field positions were checked against
// GNU as and QEMU's insns.decode. Pure combinational.
//
// Not decoded yet (they raise trap 8 or 22 until their units exist): the
// PCX-L explicit-endian word loads/stores (03/3, 03/B), the TLB/probe ops of
// major 01, RDTLB's translation, and the FPU (every FP instruction raises
// assist emulation) -- docs/STUBS.md S-005.
module pa_decode
    import pa_pkg::*;
(
    input  logic [31:0] insn,
    output ctrl_t       c
);
    logic [5:0] op;
    logic [4:0] f6_10, f11_15, f27_31;
    logic [2:0] c3;
    logic       f19, f26;
    logic [5:0] ext6;
    logic [3:0] ext4;
    logic [2:0] ext3;
    logic [7:0] ext8;
    logic [4:0] cp, clen;

    assign op     = insn[31:26];
    assign f6_10  = insn[25:21];
    assign f11_15 = insn[20:16];
    assign f27_31 = insn[4:0];
    assign c3     = insn[15:13];
    assign f19    = insn[12];
    assign f26    = insn[5];
    assign ext6   = insn[11:6];
    assign ext4   = insn[9:6];
    assign ext3   = insn[12:10];
    assign ext8   = insn[12:5];
    assign cp     = insn[9:5];
    assign clen   = insn[4:0];

    function automatic logic is_max1(input logic [5:0] e);
        case (e)
            6'h04, 6'h05, 6'h07, 6'h0B, 6'h0C, 6'h0D, 6'h0F,
            6'h15, 6'h16, 6'h17, 6'h1D, 6'h1E, 6'h1F: is_max1 = 1'b1;
            default: is_max1 = 1'b0;
        endcase
    endfunction

    always_comb begin
        c = '0;
        c.fu = FU_NOP;

        unique case (op)
        // ------------------------------------------------------ 00 system
        6'h00: begin
            c.fu = FU_SYS;
            c.rt = f27_31;
            c.sr = sr3(insn);
            c.s2 = insn[15:14];
            c.cr = f6_10;
            c.sm_imm = insn[25:16];
            case (ext8)
                8'h00: c.sysop = SYS_BREAK;
                8'h20: begin
                    c.sysop = SYS_SYNC;
                    if (f6_10 != 0 || (f11_15 != 5'h00 && f11_15 != 5'h10) || c3 != 0 || f27_31 != 0)
                        c.illegal = 1'b1;
                end
                8'h60: begin c.sysop = SYS_RFI;  c.priv = 1'b1; end
                8'h65: begin c.sysop = SYS_RFIR; c.priv = 1'b1; end
                8'h6B: begin c.sysop = SYS_SSM;  c.priv = 1'b1; c.rt_we = 1'b1; end
                8'h73: begin c.sysop = SYS_RSM;  c.priv = 1'b1; c.rt_we = 1'b1; end
                8'hC3: begin c.sysop = SYS_MTSM; c.priv = 1'b1; c.ra = f11_15; end
                8'h85: begin c.sysop = SYS_LDSID; c.rb = f6_10; c.rt_we = 1'b1; end
                8'hC1: begin c.sysop = SYS_MTSP;  c.ra = f11_15; end
                8'h25: begin c.sysop = SYS_MFSP;  c.rt_we = 1'b1; end
                8'hC2: begin c.sysop = SYS_MTCTL; c.ra = f11_15; end
                8'h45: begin c.sysop = SYS_MFCTL; c.rt_we = 1'b1; end
                default: c.illegal = 1'b1;
            endcase
        end

        // ------------------------------------------------------ 01 memory management
        // Instruction group (bit 19 = 0): ext7 = bits 19:25, sr = 16:18.
        // Data group (bit 19 = 1): ext8 = bits 18:25, s = 16:17. m = bit 26.
        // The cache flushes decode here; TLB/probe ops stay illegal until
        // pa_tlb exists (STUBS S-005).
        6'h01: begin
            c.fu = FU_MMU;
            c.priv = 1'b0;
            c.rb = f6_10;               // base
            c.ra = f11_15;              // index x
            c.use_index = 1'b1;
            c.base_we = f26;            // ,m: GR[b] <- GR[b] + GR[x]
            c.sr = sr3(insn);
            c.s2 = insn[15:14];
            c.illegal = 1'b1;
            // PCX-L fast inserts: bits 18:25 = 10/11/50/51, b and s ignored (cpu.md 4.3.2)
            case (insn[13:6])
                8'h10: begin c.illegal = 1'b0; c.sysop = MM_TLB_INS; c.priv = 1'b1; c.ra = f11_15; c.tlb_p = 1'b1; c.tlb_fast = 1'b1; c.tlb_i = 1'b1; c.use_index = 1'b0; c.base_we = 1'b0; end
                8'h11: begin c.illegal = 1'b0; c.sysop = MM_TLB_INS; c.priv = 1'b1; c.ra = f11_15; c.tlb_fast = 1'b1; c.tlb_i = 1'b1; c.use_index = 1'b0; c.base_we = 1'b0; end
                8'h50: begin c.illegal = 1'b0; c.sysop = MM_TLB_INS; c.priv = 1'b1; c.ra = f11_15; c.tlb_p = 1'b1; c.tlb_fast = 1'b1; c.use_index = 1'b0; c.base_we = 1'b0; end
                8'h51: begin c.illegal = 1'b0; c.sysop = MM_TLB_INS; c.priv = 1'b1; c.ra = f11_15; c.tlb_fast = 1'b1; c.use_index = 1'b0; c.base_we = 1'b0; end
                default: ;
            endcase
            if (c.illegal) begin
                if (!f19) begin
                    // instruction group: IxTLBA/P r,(sr,b), PITLB/E x(sr,b), FIC/FICE
                    c.tlb_i = 1'b1;
                    case (insn[12:6])       // ext7
                        7'h00: begin c.illegal = 1'b0; c.sysop = MM_TLB_INS; c.priv = 1'b1; c.tlb_p = 1'b1; c.use_index = 1'b0; c.base_we = 1'b0; end
                        7'h01: begin c.illegal = 1'b0; c.sysop = MM_TLB_INS; c.priv = 1'b1; c.use_index = 1'b0; c.base_we = 1'b0; end
                        7'h08: begin c.illegal = 1'b0; c.sysop = MM_TLB_PURGE; c.priv = 1'b1; end
                        7'h09: begin c.illegal = 1'b0; c.sysop = MM_TLB_PURGE; c.priv = 1'b1; c.tlb_all = 1'b1; end
                        7'h0A: begin c.illegal = 1'b0; c.sysop = MM_FIC; end
                        7'h0B: begin c.illegal = 1'b0; c.sysop = MM_FICE; end
                        default: ;
                    endcase
                end else begin
                    // data group: ext8 = bits 18:25
                    case (insn[13:6])
                        8'h40: begin c.illegal = 1'b0; c.sysop = MM_TLB_INS; c.priv = 1'b1; c.tlb_p = 1'b1; c.use_index = 1'b0; c.base_we = 1'b0; end
                        8'h41: begin c.illegal = 1'b0; c.sysop = MM_TLB_INS; c.priv = 1'b1; c.use_index = 1'b0; c.base_we = 1'b0; end
                        8'h48: begin c.illegal = 1'b0; c.sysop = MM_TLB_PURGE; c.priv = 1'b1; end
                        8'h49: begin c.illegal = 1'b0; c.sysop = MM_TLB_PURGE; c.priv = 1'b1; c.tlb_all = 1'b1; end
                        8'h4A: begin c.illegal = 1'b0; c.sysop = MM_FDC; end
                        8'h4B: begin c.illegal = 1'b0; c.sysop = MM_FDCE; end
                        8'h4E: begin c.illegal = 1'b0; c.sysop = MM_PDC; end
                        8'h46, 8'h47, 8'hC6, 8'hC7: begin                   // PROBER/W, PROBERI/WI
                            c.illegal = 1'b0; c.sysop = MM_PROBE; c.rt = f27_31; c.rt_we = 1'b1;
                            c.use_index = 1'b0; c.base_we = 1'b0;
                            c.probe_w = insn[6];
                            c.a_imm = insn[13];                              // immediate PL
                            c.imm = {30'd0, insn[17:16]};
                        end
                        8'h4D: begin c.illegal = 1'b0; c.sysop = MM_LPA; c.priv = 1'b1; c.rt = f27_31; c.rt_we = 1'b1; end
                        8'h4C: begin c.illegal = 1'b0; c.sysop = MM_LCI; c.priv = 1'b1; c.rt = f27_31; c.rt_we = 1'b1; end
                        default: ;
                    endcase
                end
            end
        end

        // ------------------------------------------------------ 02 arith/logical, MAX-1
        6'h02: begin
            c.ra = f11_15;              // r1
            c.rb = f6_10;               // r2
            c.rt = f27_31;
            c.rt_we = 1'b1;
            c.cond_c = c3;
            c.cond_f = f19;
            c.nullify_cond = 1'b1;
            if (insn[15:12] == 4'h0 && is_max1(ext6) && !f26) begin
                c.fu = FU_MAX1;
                c.nullify_cond = 1'b0;
                case (ext6)
                    6'h0F: begin c.mx_op = 3'd0; c.mx_sat = 2'd0; end
                    6'h0D: begin c.mx_op = 3'd0; c.mx_sat = 2'd1; end
                    6'h0C: begin c.mx_op = 3'd0; c.mx_sat = 2'd2; end
                    6'h07: begin c.mx_op = 3'd1; c.mx_sat = 2'd0; end
                    6'h05: begin c.mx_op = 3'd1; c.mx_sat = 2'd1; end
                    6'h04: begin c.mx_op = 3'd1; c.mx_sat = 2'd2; end
                    6'h0B: c.mx_op = 3'd2;
                    6'h1D, 6'h1E, 6'h1F: begin c.mx_op = 3'd3; c.mx_sa = ext6[1:0]; end
                    default: begin c.mx_op = 3'd4; c.mx_sa = ext6[1:0]; end
                endcase
            end else begin
                c.fu = FU_ALU;
                if (f26) c.illegal = 1'b1;              // PA 2.0 ",*" forms
                case (ext6)
                    6'h00: begin c.logic_op = 1'b1; c.lop = 2'd1; c.cond_class = 2'd1; end  // ANDCM
                    6'h08: begin c.logic_op = 1'b1; c.lop = 2'd0; c.cond_class = 2'd1; end  // AND
                    6'h09: begin c.logic_op = 1'b1; c.lop = 2'd2; c.cond_class = 2'd1; end  // OR
                    6'h0A: begin c.logic_op = 1'b1; c.lop = 2'd3; c.cond_class = 2'd1; end  // XOR
                    6'h0E: begin c.logic_op = 1'b1; c.lop = 2'd3; c.cond_class = 2'd2; end  // UXOR
                    6'h10, 6'h30: begin c.inv_b = 1'b1; c.cin_sel = 2'd1; c.cb_we = 1'b1;
                                        c.trap_ovf = ext6[5]; end                       // SUB, SUBO
                    6'h13, 6'h33: begin c.inv_b = 1'b1; c.cin_sel = 2'd1; c.cb_we = 1'b1;
                                        c.trap_cond = 1'b1; c.nullify_cond = 1'b0;
                                        c.trap_ovf = ext6[5]; end                       // SUBT, SUBTO
                    6'h14, 6'h34: begin c.inv_b = 1'b1; c.cin_sel = 2'd2; c.cb_we = 1'b1;
                                        c.trap_ovf = ext6[5]; end                       // SUBB, SUBBO
                    6'h11: begin c.ds = 1'b1; c.cb_we = 1'b1; end                       // DS
                    6'h18, 6'h19, 6'h1A, 6'h1B, 6'h38, 6'h39, 6'h3A, 6'h3B: begin       // ADD, SHnADD (O)
                        c.a_shift = ext6[1:0]; c.cb_we = 1'b1; c.trap_ovf = ext6[5]; end
                    6'h1C, 6'h3C: begin c.cin_sel = 2'd2; c.cb_we = 1'b1;
                                        c.trap_ovf = ext6[5]; end                       // ADDC, ADDCO
                    6'h28, 6'h29, 6'h2A, 6'h2B: c.a_shift = ext6[1:0];                  // ADDL, SHnADDL
                    6'h22: begin c.inv_b = 1'b1; c.cin_sel = 2'd1; c.clr_result = 1'b1; end // COMCLR
                    6'h26: begin c.inv_b = 1'b1; c.cond_class = 2'd2; end               // UADDCM
                    6'h27: begin c.inv_b = 1'b1; c.cond_class = 2'd2;
                                 c.trap_cond = 1'b1; c.nullify_cond = 1'b0; end         // UADDCMT
                    6'h2E: begin c.dcor = 2'd1; c.cond_class = 2'd2;
                                 if (f11_15 != 0) c.illegal = 1'b1; end                 // DCOR
                    6'h2F: begin c.dcor = 2'd2; c.cond_class = 2'd2;
                                 if (f11_15 != 0) c.illegal = 1'b1; end                 // IDCOR
                    default: c.illegal = 1'b1;
                endcase
            end
        end

        // ------------------------------------------------------ 03 indexed / short memory
        6'h03: begin
            c.rb = f6_10;
            c.s2 = insn[15:14];
            c.cc = insn[11:10];
            if (!f19) begin                                         // indexed
                c.ra = f11_15;
                c.rt = f27_31;
                c.use_index = 1'b1;
                c.scale = insn[13];
                c.ea_is_base = f26;
                c.base_we = f26;
                c.rt_we = 1'b1;
                c.fu = FU_LOAD;
                case (ext4)
                    4'h0: c.size = 2'd0;
                    4'h1: c.size = 2'd1;
                    4'h2: c.size = 2'd2;
                    4'h6: begin c.size = 2'd2; c.absolute = 1'b1; c.priv = 1'b1; end  // LDWAX
                    4'h7: begin c.size = 2'd2; c.ldcw = 1'b1; end                     // LDCWX
                    default: c.illegal = 1'b1;   // 3: explicit-endian (S-005); 4/5/8-F: PA 2.0
                endcase
            end else begin                                          // short displacement
                c.ea_is_base = f26 & ~insn[13];                     // ,ma
                c.base_we = f26;                                    // ,ma / ,mb
                if (!ext4[3]) begin                                 // loads
                    c.fu = FU_LOAD;
                    c.imm = low_sext5(f11_15);
                    c.rt = f27_31;
                    c.rt_we = 1'b1;
                    case (ext4)
                        4'h0: c.size = 2'd0;
                        4'h1: c.size = 2'd1;
                        4'h2: c.size = 2'd2;
                        4'h6: begin c.size = 2'd2; c.absolute = 1'b1; c.priv = 1'b1; end  // LDWAS
                        4'h7: begin c.size = 2'd2; c.ldcw = 1'b1; end                     // LDCWS
                        default: c.illegal = 1'b1;
                    endcase
                end else begin                                      // stores
                    c.fu = FU_STORE;
                    c.ra = f11_15;                                  // source GR r
                    c.imm = low_sext5(f27_31);
                    case (ext4)
                        4'h8: c.size = 2'd0;
                        4'h9: c.size = 2'd1;
                        4'hA: c.size = 2'd2;
                        4'hC: begin                                 // STBYS ,b/,e (,m)
                            c.size = 2'd0;
                            c.stbys = insn[13] ? 2'd2 : 2'd1;
                            c.ea_is_base = f26 & ~insn[13];
                            c.base_trunc = f26;
                        end
                        4'hE: begin c.size = 2'd2; c.absolute = 1'b1; c.priv = 1'b1; end  // STWAS
                        default: c.illegal = 1'b1;
                    endcase
                end
            end
        end

        // ------------------------------------------------------ 04 SPOP: no SFU
        6'h04: begin c.fu = FU_NOP; c.assist = 1'b1; end

        // ------------------------------------------------------ 05 DIAG (PCX-L)
        // Code = bits 19:26; the ERS s.8.3.9 table decodes bits 19 | 20:22 |
        // 23 | 24 | 25 (bit 26 and the X bits are ignored). Anything else is
        // undefined -> trap 8 (cpu.md 4.1, Q7).
        6'h05: begin
            c.fu = FU_DIAG;
            c.priv = 1'b1;
            c.cr = f6_10;                                       // DR number
            c.illegal = 1'b1;
            casez ({insn[12], insn[11:9], insn[8], insn[7], insn[6]})
                7'b?_001_?_?_1: begin c.illegal = 1'b0; c.sysop = DG_MTCPU;  c.ra = f11_15; end
                7'b1_010_?_?_0: begin c.illegal = 1'b0; c.sysop = DG_MFCPU;  c.rt = f27_31; c.rt_we = 1'b1; end
                7'b0_011_?_?_0: begin c.illegal = 1'b0; c.sysop = DG_MFCPU;  c.rt = f11_15; c.rt_we = 1'b1; end
                7'b0_101_?_?_0: begin c.illegal = 1'b0; c.sysop = DG_TOC_EN; end
                7'b0_101_?_?_1: begin c.illegal = 1'b0; c.sysop = DG_TOC_DIS; end
                7'b1_101_?_?_0: begin c.illegal = 1'b0; c.sysop = DG_SHDW_GR; end
                7'b1_101_?_?_1: begin c.illegal = 1'b0; c.sysop = DG_GR_SHDW; end
                // cache diagnose (ERS s.8.3.4-8.3.7): reads b = 6:10, t = 27:31;
                // writes b = 6:10, x = 11:15; RI1 indexes with IIAOQ back
                7'b1_110_0_0_1: begin c.illegal = 1'b0; c.sysop = DG_RDD;   c.rb = f6_10; c.rt = f27_31; c.rt_we = 1'b1; end
                7'b1_110_0_1_1: begin c.illegal = 1'b0; c.sysop = DG_RDTLB; c.rb = f6_10; c.rt = f27_31; c.rt_we = 1'b1; c.s2 = insn[15:14]; end
                7'b1_110_1_0_1: begin c.illegal = 1'b0; c.sysop = DG_RDT;   c.rb = f6_10; c.rt = f27_31; c.rt_we = 1'b1; end
                7'b0_110_0_0_1: begin c.illegal = 1'b0; c.sysop = DG_RI2D;  c.rb = f6_10; c.rt = f27_31; c.rt_we = 1'b1; end
                7'b0_110_1_0_1: begin c.illegal = 1'b0; c.sysop = DG_RI2T;  c.rb = f6_10; c.rt = f27_31; c.rt_we = 1'b1; end
                7'b0_100_0_0_0: begin c.illegal = 1'b0; c.sysop = DG_RI1; end
                7'b1_111_0_0_1: begin c.illegal = 1'b0; c.sysop = DG_WDD;   c.rb = f6_10; c.ra = f11_15; end
                7'b1_111_1_0_1: begin c.illegal = 1'b0; c.sysop = DG_WDT;   c.rb = f6_10; end
                7'b0_111_0_0_1: begin c.illegal = 1'b0; c.sysop = DG_WI2D;  c.rb = f6_10; c.ra = f11_15; end
                7'b0_111_1_0_1: begin c.illegal = 1'b0; c.sysop = DG_WI2T;  c.rb = f6_10; end
                7'b0_111_0_0_0: begin c.illegal = 1'b0; c.sysop = DG_WI1;   c.rb = f6_10; end
                7'b0_100_?_0_1: begin c.illegal = 1'b0; c.sysop = DG_SET_TAG; c.ra = f11_15; end
                default: ;
            endcase
        end

        // ------------------------------------------------------ 08 LDIL, 0A ADDIL, 0D LDO
        6'h08: begin
            c.fu = FU_ALU; c.a_imm = 1'b1; c.imm = assemble_21(insn[20:0]);
            c.rb = 5'd0; c.rt = f6_10; c.rt_we = 1'b1;
        end
        6'h0A: begin
            c.fu = FU_ALU; c.a_imm = 1'b1; c.imm = assemble_21(insn[20:0]);
            c.rb = f6_10; c.rt = 5'd1; c.rt_we = 1'b1;
        end
        6'h0D: begin
            c.fu = FU_ALU; c.a_imm = 1'b1; c.imm = low_sext14(insn[13:0]);
            c.rb = f6_10; c.rt = f11_15; c.rt_we = 1'b1;
        end

        // ------------------------------------------------------ 10-13 loads, 18-1B stores
        6'h10, 6'h11, 6'h12, 6'h13: begin
            c.fu = FU_LOAD;
            c.rb = f6_10; c.rt = f11_15; c.rt_we = 1'b1;
            c.s2 = insn[15:14];
            c.imm = low_sext14(insn[13:0]);
            c.size = (op == 6'h10) ? 2'd0 : (op == 6'h11) ? 2'd1 : 2'd2;
            if (op == 6'h13) begin                              // LDWM: pre if d < 0
                c.base_we = 1'b1;
                c.ea_is_base = ~insn[0];
            end
        end
        6'h18, 6'h19, 6'h1A, 6'h1B: begin
            c.fu = FU_STORE;
            c.rb = f6_10; c.ra = f11_15;
            c.s2 = insn[15:14];
            c.imm = low_sext14(insn[13:0]);
            c.size = (op == 6'h18) ? 2'd0 : (op == 6'h19) ? 2'd1 : 2'd2;
            if (op == 6'h1B) begin                              // STWM
                c.base_we = 1'b1;
                c.ea_is_base = ~insn[0];
            end
        end

        // ------------------------------------------------------ immediates
        6'h2D, 6'h2C, 6'h25: begin                              // ADDI(O), ADDIT(O), SUBI(O)
            c.fu = FU_ALU; c.a_imm = 1'b1; c.imm = low_sext11(insn[10:0]);
            c.rb = f6_10; c.rt = f11_15; c.rt_we = 1'b1;
            c.cond_c = c3; c.cond_f = f19;
            c.cb_we = 1'b1;
            c.trap_ovf = insn[11];
            c.nullify_cond = (op != 6'h2C);
            c.trap_cond = (op == 6'h2C);
            if (op == 6'h25) begin c.inv_b = 1'b1; c.cin_sel = 2'd1; end
        end
        6'h24: begin                                            // COMICLR
            c.fu = FU_ALU; c.a_imm = 1'b1; c.imm = low_sext11(insn[10:0]);
            c.rb = f6_10; c.rt = f11_15; c.rt_we = 1'b1;
            c.cond_c = c3; c.cond_f = f19; c.nullify_cond = 1'b1;
            c.inv_b = 1'b1; c.cin_sel = 2'd1; c.clr_result = 1'b1;
            if (insn[11]) c.illegal = 1'b1;                     // PA 2.0 doubleword
        end

        // ------------------------------------------------------ conditional branches
        6'h20, 6'h22, 6'h21, 6'h23,                             // COMB(T/F), COMIB(T/F)
        6'h28, 6'h2A, 6'h29, 6'h2B: begin                       // ADDB(T/F), ADDIB(T/F)
            c.fu = FU_BRANCH; c.br = BR_COND; c.brcond = BC_ALU;
            c.rb = f6_10;
            c.ra = f11_15;
            c.a_imm = op[0];
            c.imm = low_sext5(f11_15);
            c.disp = br_disp12(insn);
            c.cond_c = c3;
            c.cond_f = op[1];
            c.nul = insn[1];
            if (op[3]) begin                                    // add and branch: writes r2
                c.rt = f6_10; c.rt_we = 1'b1;
            end else begin
                c.inv_b = 1'b1; c.cin_sel = 2'd1;               // compare: a - b
            end
        end
        6'h32, 6'h33: begin                                     // MOVB, MOVIB
            c.fu = FU_BRANCH; c.br = BR_COND; c.brcond = BC_SHIFT;
            c.ra = f11_15; c.a_imm = op[0]; c.imm = low_sext5(f11_15);
            c.disp = br_disp12(insn);
            c.rt = f6_10; c.rt_we = 1'b1;
            c.cond_c = c3;
            c.nul = insn[1];
        end
        6'h30, 6'h31: begin                                     // BVB, BB
            c.fu = FU_BRANCH; c.br = BR_COND; c.brcond = BC_BIT;
            c.ra = f11_15;
            c.sh_sar = ~op[0];
            c.sh_amount = f6_10;                                // BB: bit p
            c.cond_f = insn[15];                                // bit 16 only (cpu.md 4.3.9)
            c.disp = br_disp12(insn);
            c.nul = insn[1];
            if (!op[0] && f6_10 != 0) c.illegal = 1'b1;
        end

        // ------------------------------------------------------ shift / extract / deposit
        6'h34: begin
            c.fu = FU_SHIFT;
            c.cond_c = c3; c.nullify_cond = 1'b1;
            c.rt_we = 1'b1;
            case (ext3)
                3'd0, 3'd2: begin                               // VSHD, SHD
                    c.sh_op = 2'd0;
                    c.ra = f11_15; c.rb = f6_10; c.rt = f27_31;
                    c.sh_sar = (ext3 == 3'd0);
                    c.sh_amount = 5'd31 - cp;
                    if (ext3 == 3'd0 && cp != 0) c.illegal = 1'b1;
                end
                3'd4, 3'd5, 3'd6, 3'd7: begin                   // VEXTRU/S, EXTRU/S
                    c.sh_op = 2'd1;
                    c.sh_sign = ext3[0];
                    c.ra = f6_10; c.rt = f11_15;
                    c.sh_sar = ~ext3[1];
                    c.sh_amount = cp;
                    c.sh_len = 6'd32 - {1'b0, clen};
                    if (!ext3[1] && cp != 0) c.illegal = 1'b1;
                end
                default: c.illegal = 1'b1;
            endcase
        end
        6'h35: begin
            c.fu = FU_SHIFT;
            c.sh_op = 2'd2;
            c.cond_c = c3; c.nullify_cond = 1'b1;
            c.rt = f6_10; c.rt_we = 1'b1;
            c.rb = f6_10;                                       // old target, for DEP
            c.ra = f11_15;
            c.sh_zero = ~ext3[0];
            c.sh_imm = ext3[2];
            c.sh_imm5 = {f11_15[0], f11_15[4:1]};             // low_sign_ext field -> two's complement
            c.sh_sar = ~ext3[1];
            c.sh_amount = 5'd31 - cp;
            c.sh_len = 6'd32 - {1'b0, clen};
            if (!ext3[1] && cp != 0) c.illegal = 1'b1;
        end

        // ------------------------------------------------------ unconditional branches
        6'h38, 6'h39: begin                                     // BE, BLE
            c.fu = FU_BRANCH;
            c.br = (op == 6'h38) ? BR_BE : BR_BLE;
            c.rb = f6_10;
            c.sr = sr3(insn);
            c.disp = br_disp17(insn);
            c.nul = insn[1];
            if (op == 6'h39) begin c.rt = 5'd31; c.rt_we = 1'b1; c.link = 1'b1; end
        end
        6'h3A: begin
            c.fu = FU_BRANCH;
            c.nul = insn[1];
            c.rt = f6_10;
            case (c3)
                3'd0: begin c.br = BR_BL;   c.disp = br_disp17(insn); c.rt_we = 1'b1; c.link = 1'b1; end
                3'd1: begin c.br = BR_GATE; c.disp = br_disp17(insn); c.rt_we = 1'b1; c.link = 1'b1; end
                3'd2: begin
                    c.br = BR_BLR; c.ra = f11_15; c.rt_we = 1'b1; c.link = 1'b1;
                    if (insn[12:2] != 0 || insn[0]) c.illegal = 1'b1;
                end
                3'd6: begin
                    c.br = BR_BV; c.ra = f11_15; c.rb = f6_10;
                    if (insn[12:2] != 0 || insn[0]) c.illegal = 1'b1;
                end
                default: c.illegal = 1'b1;
            endcase
        end

        // ------------------------------------------------------ floating point (S-005)
        6'h06, 6'h09, 6'h0B, 6'h0C, 6'h0E, 6'h26: begin
            c.fu = FU_FP;
            c.assist = 1'b1;
        end

        default: c.illegal = 1'b1;                              // undefined / PA 2.0 majors
        endcase

        if (c.illegal) begin
            c.rt_we = 1'b0;
            c.base_we = 1'b0;
        end
    end
endmodule
