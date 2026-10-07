// PA-7100LC core: shared types. The decoded control word (ctrl_t) is the
// contract between pa_decode and every later stage; docs/design/cpu.md
// section 4 is the instruction-level specification.
//
// Instruction fields are named by PA-RISC bit numbers (bit 0 = MSB) in the
// comments; the Verilog slices are [31-k].
package pa_pkg;

    // ------------------------------------------------------------ units
    typedef enum logic [3:0] {
        FU_NOP,     // no architectural effect (and decode-time traps)
        FU_ALU,     // pa_alu (incl. COMCLR, DS, DCOR, long immediates)
        FU_SHIFT,   // pa_shift
        FU_MAX1,    // pa_max1
        FU_LOAD,    // integer loads (incl. LDCW, LDWA)
        FU_STORE,   // integer stores (incl. STBYS, STWA)
        FU_BRANCH,  // every branch
        FU_SYS,     // major 00 system control
        FU_DIAG,    // major 05 PCX-L diagnose
        FU_MMU,     // major 01 TLB / cache / probe
        FU_FP       // FP operations and FP loads/stores (later)
    } fu_e;

    // ------------------------------------------------------------ branches
    typedef enum logic [2:0] {
        BR_COND,    // PC-relative conditional (COMB/COMIB/ADDB/ADDIB/MOVB/MOVIB/BB/BVB)
        BR_BL,      // BL target,t
        BR_GATE,    // GATE target,t
        BR_BLR,     // BLR x,t
        BR_BV,      // BV x(b)
        BR_BE,      // BE wd(sr,b)
        BR_BLE      // BLE wd(sr,b)
    } br_e;

    typedef enum logic [1:0] {
        BC_ALU,     // condition from pa_alu (COMB/COMIB/ADDB/ADDIB)
        BC_SHIFT,   // shift/extract condition on the moved value (MOVB/MOVIB)
        BC_BIT      // BB / BVB bit test
    } brcond_e;

    // ------------------------------------------------------------ system ops
    typedef enum logic [5:0] {
        SYS_BREAK, SYS_SYNC, SYS_RFI, SYS_RFIR, SYS_SSM, SYS_RSM, SYS_MTSM,
        SYS_LDSID, SYS_MTSP, SYS_MFSP, SYS_MTCTL, SYS_MFCTL,
        // diagnose (FU_DIAG)
        DG_MTCPU, DG_MFCPU, DG_TOC_EN, DG_TOC_DIS, DG_SHDW_GR, DG_GR_SHDW,
        DG_SET_TAG,                                  // tag latch <- GR[x]
        DG_RDD, DG_RDT, DG_RDTLB, DG_WDD, DG_WDT,    // L2-D data/tag, real (RDTLB: virtual)
        DG_RI2D, DG_RI2T, DG_WI2D, DG_WI2T,          // L2-I data/tag
        DG_RI1, DG_WI1,                              // L1-I entry <-> DR27/28/29
        // memory management (FU_MMU)
        MM_TLB_INS, MM_TLB_PURGE, MM_PROBE, MM_LPA, MM_LCI,
        MM_FDC, MM_FDCE, MM_PDC, MM_FIC, MM_FICE
    } sysop_e;

    // ------------------------------------------------------------ cache engine operations
    typedef enum logic [3:0] {
        DC_MISS, DC_FDC, DC_FDCE, DC_PDC, DC_LDCW, DC_RDD, DC_RDT, DC_WDD, DC_WDT, DC_RD2
    } dc_op_e;
    typedef enum logic [3:0] {
        IC_FILL, IC_FIC, IC_FICE, IC_RI2D, IC_RI2T, IC_WI2D, IC_WI2T, IC_RI1, IC_WI1
    } ic_op_e;

    typedef enum logic [1:0] { TLB_INS_A, TLB_INS_P, TLB_PURGE, TLB_PURGE_ALL } tlb_op_e;
    typedef enum logic [3:0] {
        F_ADD, F_SUB, F_MPY, F_DIV, F_SQRT, F_CPY, F_ABS, F_CNVFF, F_CNVXF, F_CNVFX, F_CNVFXT,
        F_CMP, F_XMPYU, F_RND, F_RESERVED
    } fpu_op_e;

    // ------------------------------------------------------------ traps
    localparam logic [5:0] TRAP_NONE      = 6'd0;
    localparam logic [5:0] TRAP_HPMC      = 6'd1;
    localparam logic [5:0] TRAP_RCTR      = 6'd3;
    localparam logic [5:0] TRAP_EXT       = 6'd4;
    localparam logic [5:0] TRAP_LPMC      = 6'd5;
    localparam logic [5:0] TRAP_ITLB      = 6'd6;
    localparam logic [5:0] TRAP_IMP       = 6'd7;
    localparam logic [5:0] TRAP_ILLEGAL   = 6'd8;
    localparam logic [5:0] TRAP_BREAK     = 6'd9;
    localparam logic [5:0] TRAP_PRIV_OP   = 6'd10;
    localparam logic [5:0] TRAP_PRIV_REG  = 6'd11;
    localparam logic [5:0] TRAP_OVERFLOW  = 6'd12;
    localparam logic [5:0] TRAP_COND      = 6'd13;
    localparam logic [5:0] TRAP_ASSIST_EX = 6'd14;
    localparam logic [5:0] TRAP_DTLB      = 6'd15;
    localparam logic [5:0] TRAP_NA_DTLB   = 6'd17;
    localparam logic [5:0] TRAP_ASSIST_EM = 6'd22;
    localparam logic [5:0] TRAP_UNALIGNED = 6'd28;
    localparam logic [5:0] TRAP_HPT       = 6'd23;   // higher-privilege transfer
    localparam logic [5:0] TRAP_LPT       = 6'd24;   // lower-privilege transfer
    localparam logic [5:0] TRAP_TAKEN_BR  = 6'd25;
    localparam logic [5:0] TRAP_TOC       = 6'd32;   // not a vector: entry at 0xF0000000

    // ------------------------------------------------------------ control word
    typedef struct packed {
        fu_e         fu;
        logic        illegal;      // trap 8 at decode
        logic        priv;         // privileged: trap 10 at PL != 0
        logic        assist;       // trap 22 (SPOP, coprocessor uid >= 2, FP disabled)

        // register numbers and writes
        logic [4:0]  ra;           // GR read port A (operand a / r1 / x / r)
        logic [4:0]  rb;           // GR read port B (operand b / r2 / base)
        logic [4:0]  rt;           // GR write target
        logic        rt_we;
        logic        base_we;      // second write: GR[rb] <- new base (modify forms)

        // operands
        logic [31:0] imm;          // sign-extended immediate / displacement / target offset
        logic        a_imm;        // operand a = imm instead of GR[ra]

        // pa_alu
        logic [1:0]  a_shift;
        logic        logic_op;
        logic [1:0]  lop;
        logic        inv_b;
        logic [1:0]  cin_sel;
        logic [1:0]  dcor;
        logic        ds;
        logic [1:0]  cond_class;
        logic [2:0]  cond_c;
        logic        cond_f;
        logic        cb_we;        // update PSW C/B
        logic        clr_result;   // COMCLR/COMICLR: GR[t] <- 0
        logic        trap_ovf;     // *O forms: trap 12 on signed overflow
        logic        trap_cond;    // *T forms: trap 13 when the condition holds
        logic        nullify_cond; // condition nullifies the next instruction

        // pa_shift
        logic [1:0]  sh_op;        // 0 SHD, 1 EXTRACT, 2 DEPOSIT
        logic        sh_sign;
        logic        sh_zero;
        logic        sh_imm;       // deposit the immediate
        logic        sh_sar;       // position / amount from SAR
        logic [4:0]  sh_amount;    // fixed SHD amount or position p
        logic [5:0]  sh_len;
        logic [4:0]  sh_imm5;

        // pa_max1
        logic [2:0]  mx_op;
        logic [1:0]  mx_sat;
        logic [1:0]  mx_sa;

        // loads / stores
        logic [1:0]  size;         // 0 byte, 1 half, 2 word
        logic        use_index;
        logic        scale;
        logic        ea_is_base;   // post-modify (or LDWM/STWM with disp >= 0)
        logic        base_trunc;   // STBYS ,m
        logic [1:0]  stbys;
        logic        ldcw;
        logic [1:0]  cc;           // cache-control hint (bits 20:21); LDCW: != 0 -> in the cache
        logic        absolute;     // LDWA/STWA: physical address, priv
        logic [2:0]  sr;           // explicit space register (BE/BLE/MTSP/MFSP)
        logic [1:0]  s2;           // 2-bit s field: 0 -> SR[4 + GR[b]{0:1}]

        // branches
        logic [31:0] disp;         // branch displacement in bytes (PC-relative, BE/BLE)
        br_e         br;
        brcond_e     brcond;
        logic        nul;          // ,n completer
        logic        link;         // writes the link register (rt)

        // system / diagnose / MMU
        logic        tlb_p;        // IxTLBP (protection) rather than IxTLBA
        logic        tlb_i;        // instruction-side form (3-bit sr field)
        logic        tlb_all;      // PxTLBE
        logic        tlb_fast;     // IITLBxF / IDTLBxF: VA from IIAQ or ISR/IOR
        logic        probe_w;      // PROBEW
        sysop_e      sysop;
        logic [4:0]  cr;           // CR / DR number
        logic [9:0]  sm_imm;       // SSM/RSM immediate
    } ctrl_t;

    // ------------------------------------------------------------ helpers
    // low_sign_ext: the sign bit is the field's rightmost bit (ACD p.5-8)
    function automatic logic [31:0] low_sext5(input logic [4:0] x);
        return {{28{x[0]}}, x[4:1]};
    endfunction
    function automatic logic [31:0] low_sext11(input logic [10:0] x);
        return {{22{x[0]}}, x[10:1]};
    endfunction
    function automatic logic [31:0] low_sext14(input logic [13:0] x);
        return {{19{x[0]}}, x[13:1]};
    endfunction
    // assemble_21 (LDIL/ADDIL), already shifted left by 11
    function automatic logic [31:0] assemble_21(input logic [20:0] x);
        return {x[0], x[11:1], x[15:14], x[20:16], x[13:12], 11'd0};
    endfunction
    // assemble_12 (conditional branches), in bytes
    function automatic logic [31:0] br_disp12(input logic [31:0] w);
        return {{19{w[0]}}, w[2], w[12:3], 2'b00};
    endfunction
    // assemble_17 (BL/GATE/BE/BLE), in bytes
    function automatic logic [31:0] br_disp17(input logic [31:0] w);
        return {{14{w[0]}}, w[20:16], w[2], w[12:3], 2'b00};
    endfunction
    // assemble_3 of the 3-bit sr field (bits 16:18): cat(x{2}, x{0..1})
    function automatic logic [2:0] sr3(input logic [31:0] w);
        return {w[13], w[15:14]};
    endfunction

endpackage
