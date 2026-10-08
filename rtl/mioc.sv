// The PA-7100LC's memory and I/O controller as the 715 board sees it
// (docs/design/system.md 2-4; HW 1-3, 7): the CPU's two ports in, system
// RAM, the boot ROM, the ECC check store and the GSC I/O bus out.
//
// One transaction at a time, from three requesters in priority order: a
// LASI interrupt write (IAR -> IO_EIR), the CPU's cacheable line port
// (fills and write-backs, memory only) and the CPU's uncached port (I/O
// space, U-bit pages, LDCW, instruction fetches from the ROM). Neither CPU
// port depends on the other to finish, so serving them one after the other
// cannot deadlock.
//
// The CPU-port protocols are cpu.md 6.8's: a request is held until its
// acknowledge. The pa_cpu BIU drops a request the cycle after it sees the
// acknowledge, so after the last acknowledge of an uncached transaction the
// controller waits one cycle (S_IGAP) before it looks at io_req again, and
// it never answers a line beat in the cycle it acknowledges the request.
module mioc
    import mioc_ecc::*;
#(
    parameter bit HAS_ARTIST = 1'b0   // F800_0000-F9FF_FFFF answers (else bus error)
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [3:0]  cfg_ram_lg,   // installed RAM = 2^cfg_ram_lg MB, 3 (8 MB) .. 8 (256 MB)

    // CPU cacheable line port
    input  logic        mem_req, mem_we, mem_ifill,
    input  logic [31:0] mem_addr,
    output logic        mem_ack,
    input  logic [63:0] mem_wdata,
    input  logic        mem_wvalid,
    output logic        mem_wready,
    output logic [63:0] mem_rdata,
    output logic        mem_rvalid,
    output logic [1:0]  mem_rbeat,
    output logic        mem_rerr,
    // CPU uncached port
    input  logic        io_req, io_we,
    input  logic [31:0] io_addr,
    input  logic [7:0]  io_be,
    input  logic [63:0] io_wdata,
    input  logic        io_ifetch, io_burst, io_rclr,
    output logic        io_ack, io_last,
    output logic [63:0] io_rdata,
    output logic        io_err,
    // CPU interrupt inputs
    output logic        eir_set,
    output logic [4:0]  eir_num,
    output logic        toc_req,
    output logic        hpmc_req,
    output logic        lpmc_req,

    // system RAM: held until ram_ack; then 1 or 4 beats (wrapping from
    // ram_addr[4:3]) as ram_rvalid, or taken one per ram_wready
    output logic        ram_req, ram_we, ram_line,
    output logic [27:0] ram_addr,
    output logic [7:0]  ram_be,
    output logic [63:0] ram_wdata,
    input  logic        ram_ack, ram_wready, ram_rvalid,
    input  logic [63:0] ram_rdata,
    // ECC check store: one word per 32-byte line of RAM (byte k = doubleword k)
    output logic        chk_req, chk_we,
    output logic [22:0] chk_addr,
    output logic [3:0]  chk_be,
    output logic [31:0] chk_wdata,
    input  logic        chk_ack,
    input  logic [31:0] chk_rdata,
    // boot ROM: a 32-byte line, four beats in order after rom_ack
    output logic        rom_req,
    output logic [17:5] rom_addr,
    input  logic        rom_ack, rom_rvalid,
    input  logic [63:0] rom_rdata,
    input  logic        rom_inval,     // the ROM image is being (re)loaded
    // GSC I/O bus: gsc_req is a one-cycle strobe, the addressed device answers
    // with one gsc_ack (rdata, err) any number of cycles later
    output logic        gsc_req, gsc_we,
    output logic [1:0]  gsc_dev,       // 0 8-bit bus, 1 LASI, 2 WAX stub, 3 Artist
    output logic [31:0] gsc_addr,
    output logic [3:0]  gsc_be,        // gsc_be[3] = byte 0 = gsc_wdata[31:24]
    output logic [31:0] gsc_wdata,
    input  logic        gsc_ack, gsc_err,
    input  logic [31:0] gsc_rdata,
    // LASI's interrupt transaction (a GSC write it masters)
    input  logic        lasi_eir_req,
    input  logic [31:0] lasi_eir_addr,
    input  logic [4:0]  lasi_eir_data,
    output logic        lasi_eir_ack,
    output logic        lasi_eir_err,
    // TOC from LASI's external interrupt (ICR TOC remap); broadcast reset out
    input  logic        ext_toc,
    output logic        bcast_reset,
    // debug: a bus error, and the address that caused it
    output logic        dbg_buserr,
    output logic [31:0] dbg_buserr_addr
);
    // ------------------------------------------------------------ registers
    logic [31:0] r_control, r_status, r_mtcv, r_wrt_chk, r_err0, r_err1, r_rd_chk, r_derradd;
    logic [31:0] r_flexid;
    logic [31:0] r_comp [16];
    logic [31:0] r_mask [16];
    wire ecc_on = r_mtcv[26];               // MTCV bit 5 (PA numbering)
    wire slen   = r_control[12];            // MIOC_CONTROL bit 19
    wire pgape  = r_control[14];            // bit 17
    wire pgdpe  = r_control[13];            // bit 18

    assign hpmc_req = |(r_status[5:0] & 6'b101110);           // 0x02 0x04 0x08 0x20
    assign lpmc_req = (r_status[6] && slen) || r_status[0];   // 0x40 with slen, 0x01

    // ------------------------------------------------- memory block decode
    // comparator 2 = bank A (RAM offset 0, up to 128 MB), comparator 7 = bank
    // B (the second 128 MB of a 256 MB machine, at RAM offset 128 MB)
    wire [3:0]  lg_a = cfg_ram_lg > 4'd7 ? 4'd7 : cfg_ram_lg;
    wire        has_b = cfg_ram_lg == 4'd8;
    wire [27:0] mask_a = (28'd1 << (lg_a + 5'd20)) - 28'd1;

    typedef struct packed {
        logic        hit;     // some enabled comparator decodes the address
        logic        bank;    // ... and it has DRAM behind it
        logic [27:0] off;     // RAM byte offset
    } blk_t;

    function automatic blk_t blk_decode(input logic [31:0] a);
        blk_t r;
        logic found;
        r = '0; found = 1'b0;
        for (int n = 0; n < 16; n++) begin
            logic [8:0] m;
            m = {3'b000, r_mask[n][28:23]};
            if (!found && !r_mask[n][22] && (((a[31:23] ^ r_comp[n][31:23]) & ~m) == 9'd0)) begin
                found = 1'b1;
                r.hit = 1'b1;
                if (n == 2) begin
                    r.bank = 1'b1; r.off = a[27:0] & mask_a;
                end else if (n == 7 && has_b) begin
                    r.bank = 1'b1; r.off = {1'b1, a[26:0]};
                end
            end
        end
        return r;
    endfunction

    // ---------------------------------------------------------- poison table
    // doublewords whose stored check byte is not ECC(data) (system.md 3.2);
    // the syndrome's meaning is worked out when the doubleword is written
    typedef struct packed {
        logic        v;
        logic [24:0] dw;      // RAM offset [27:3]
        logic [7:0]  chk;     // stored check byte
        logic [1:0]  cls;     // ecc_class: 1 check bit, 2 data bit, 3 uncorrectable
        logic [5:0]  bitn;
    } pe_t;
    pe_t pt [8];
    logic [2:0] pt_ptr;

    // one doubleword's write: drop its entry; add one if the stored byte is bad
    logic        pw_en;
    logic [24:0] pw_dw;
    logic [7:0]  pw_stored, pw_ecc;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < 8; i++) pt[i].v <= 1'b0;
            pt_ptr <= 3'd0;
        end else if (pw_en) begin
            logic [7:0] c;
            c = ecc_class(pw_stored ^ pw_ecc);
            for (int i = 0; i < 8; i++) if (pt[i].dw == pw_dw) pt[i].v <= 1'b0;
            if (c[1:0] != 2'd0) begin
                pt[pt_ptr] <= '{v: 1'b1, dw: pw_dw, chk: pw_stored, cls: c[1:0], bitn: c[7:2]};
                pt_ptr <= pt_ptr + 3'd1;
            end
        end
    end

    // a doubleword read from RAM with ECC on: the entry that applies to it
    function automatic pe_t pt_find(input logic [24:0] dw);
        pe_t r;
        r = '0;
        for (int i = 0; i < 8; i++) if (pt[i].v && pt[i].dw == dw) r = pt[i];
        return r;
    endfunction

    // ------------------------------------------------------- address classes
    typedef enum logic [3:0] { C_MEM, C_ROM, C_XBUS, C_LASI, C_WAX, C_ART, C_CPU, C_MIOC, C_BCAST, C_BE } cls_e;
    function automatic cls_e io_class(input logic [31:0] a);
        if (a[31:28] != 4'hF)                          return C_MEM;
        if (a[31:18] == 14'h3C00)                      return C_ROM;    // F000_0000-F003_FFFF
        if (a[31:20] == 12'hF00)                       return C_XBUS;   // F004_0000-F00F_FFFF
        if (a[31:20] == 12'hF01)                       return C_LASI;   // F010_0000-F01F_FFFF
        if (a[31:15] == 17'h1E040)                     return C_WAX;    // F020_0000-F020_7FFF
        if (HAS_ARTIST && a[31:25] == 7'h7C)           return C_ART;    // F800_0000-F9FF_FFFF
        if (a[31:12] == 20'hFFFBE)                     return C_CPU;
        if (a[31:12] == 20'hFFFBF)                     return C_MIOC;
        if (a[31:18] == 14'h3FFF)                      return C_BCAST;  // FFFC_0000-FFFF_FFFF
        return C_BE;
    endfunction

    // ------------------------------------------------------------- the FSM
    typedef enum logic [4:0] {
        S_IDLE,
        S_LDEC, S_LWCOLL, S_LWPT, S_LWRAM, S_LWCHK, S_LRRAM, S_LRDEC,
        S_IDEC, S_IRAMRD, S_IMERGE, S_IRAMWR, S_ICHKWR, S_IRAMBURST,
        S_IROM, S_IROMOUT, S_IGSC, S_IGSCW, S_ICHKRD, S_IRESP, S_IGAP
    } st_e;
    st_e st;

    // latched line request
    logic        l_we;
    logic [31:0] l_addr;
    blk_t        l_blk;
    logic [63:0] wbuf [4];
    logic [7:0]  wecc [4];
    logic [31:0] l_chkw;
    logic [2:0]  cnt;            // beats collected / sent / received
    logic [1:0]  wcnt;           // RAM write beats sent

    // latched uncached request
    logic        u_we, u_burst, u_rclr;
    logic [31:0] u_addr;
    logic [7:0]  u_be;
    logic [63:0] u_wdata;
    cls_e        u_cls;
    blk_t        u_blk;
    logic [63:0] u_rdata;
    logic        u_err;
    logic        u_hi_pending, u_lo_pending;   // GSC words still to do
    logic [9:0]  tmo;

    // ROM line buffer
    logic [63:0] rb [4];
    logic [17:5] rb_line;
    logic        rb_valid;

    // last line filled from RAM (for the 0xDC register)
    logic [22:0] last_fill_line;

    // fill pipeline: stage 1 = the beat from RAM, stage 2 = mem_r* outputs
    logic        f1_v;
    logic [63:0] f1_data;
    logic [1:0]  f1_beat;
    logic [1:0]  f_start;


    // MIOC register read
    function automatic logic [31:0] mioc_rd(input logic [11:0] off);
        logic [31:0] r;
        r = 32'd0;
        case (off)
            12'h080: r = r_control;
            12'h084: r = {25'd0, r_status[6:0]};
            12'h0C0: r = r_mtcv;
            12'h0C4: r = r_wrt_chk;
            12'h0D0: r = r_err0;
            12'h0D4: r = r_err1;
            12'h0D8: r = r_rd_chk;
            12'h0E0: r = r_derradd;
            default:
                if (off[11:7] == 5'b00010) r = off[6] ? r_mask[off[5:2]] : r_comp[off[5:2]];
        endcase
        return r;
    endfunction

    wire [31:0] u_word = u_addr[2] ? u_wdata[31:0] : u_wdata[63:32];

    always_ff @(posedge clk) begin : p_main
        // status bits set / cleared this cycle and the error address logged,
        // applied once at the end (several sources can log in one cycle)
        logic [6:0]  st_set, st_clr;
        logic        ea_we;
        logic [31:0] ea_val;
        mem_ack <= 1'b0; mem_rvalid <= 1'b0; mem_rerr <= 1'b0;
        io_ack <= 1'b0; io_last <= 1'b0; io_err <= 1'b0;
        gsc_req <= 1'b0;
        eir_set <= 1'b0; toc_req <= 1'b0; bcast_reset <= 1'b0;
        lasi_eir_ack <= 1'b0; lasi_eir_err <= 1'b0;
        pw_en <= 1'b0;
        dbg_buserr <= 1'b0;
        if (rom_inval) rb_valid <= 1'b0;
        st_set = 7'd0; st_clr = 7'd0; ea_we = 1'b0; ea_val = 32'd0;

        if (!rst_n) begin
            st <= S_IDLE;
            r_control <= 32'd0; r_status <= 32'd0; r_mtcv <= 32'd0; r_wrt_chk <= 32'd0;
            r_err0 <= 32'd0; r_err1 <= 32'd0; r_rd_chk <= 32'd0; r_derradd <= 32'd0; r_flexid <= 32'd0;
            for (int n = 0; n < 16; n++) begin r_comp[n] <= 32'd0; r_mask[n] <= 32'h0040_0000; end
            ram_req <= 1'b0; chk_req <= 1'b0; rom_req <= 1'b0;
            mem_wready <= 1'b0; rb_valid <= 1'b0; f1_v <= 1'b0;
            last_fill_line <= 23'd0;
        end else begin
            if (ext_toc) begin toc_req <= 1'b1; st_set[4] = 1'b1; end

            // ---------------------------------------- fill pipeline, stage 2
            if (f1_v) begin
                pe_t        e;
                logic [63:0] d;
                logic [31:0] pa;
                e  = pt_find({l_blk.off[27:5], f1_beat});
                d  = f1_data;
                pa = {l_addr[31:5], f1_beat, 3'd0};
                if (ecc_on && e.v) begin
                    if (e.cls == 2'd2) d[63 - e.bitn] = ~d[63 - e.bitn];
                    if (e.cls == 2'd3 || !r_status[5]) begin
                        r_err0 <= f1_data[63:32]; r_err1 <= f1_data[31:0];
                        r_rd_chk <= {24'd0, e.chk}; ea_we = 1'b1; ea_val = pa;
                    end
                    if (e.cls == 2'd3) begin st_set[5] = 1'b1; mem_rerr <= 1'b1; end
                    else st_set[6] = 1'b1;
                end
                mem_rvalid <= 1'b1; mem_rdata <= d; mem_rbeat <= f1_beat;
            end
            f1_v <= 1'b0;

            case (st)
            // ----------------------------------------------------------- idle
            S_IDLE: begin
                if (lasi_eir_req && !lasi_eir_ack && !lasi_eir_err) begin
                    // LASI's interrupt write: the CPU's IO_EIR or a broadcast EIR
                    if (lasi_eir_addr[31:12] == 20'hFFFBE && lasi_eir_addr[11:2] == 10'd0 ||
                        lasi_eir_addr[31:18] == 14'h3FFF && lasi_eir_addr[16:2] == 15'd0) begin
                        eir_set <= 1'b1; eir_num <= lasi_eir_data; lasi_eir_ack <= 1'b1;
                    end else
                        lasi_eir_err <= 1'b1;
                end else if (mem_req) begin
                    mem_ack <= 1'b1;
                    l_we <= mem_we; l_addr <= mem_addr; cnt <= 3'd0;
                    st <= S_LDEC;
                end else if (io_req) begin
                    u_we <= io_we; u_addr <= io_addr; u_be <= io_be; u_wdata <= io_wdata;
                    u_burst <= io_burst; u_rclr <= io_rclr; u_err <= 1'b0;
                    st <= S_IDEC;
                end
            end

            // ------------------------------------------------- line port
            S_LDEC: begin
                l_blk <= blk_decode(l_addr);
                if (l_we) begin st <= S_LWCOLL; mem_wready <= 1'b1; end
                else st <= S_LRDEC;            // RAM fill, or the no-RAM answers
                cnt <= 3'd0;
            end
            S_LWCOLL: if (mem_wvalid && mem_wready) begin
                wbuf[cnt[1:0]] <= mem_wdata;
                wecc[cnt[1:0]] <= ecc_of(mem_wdata);
                cnt <= cnt + 3'd1;
                if (cnt == 3'd3) begin mem_wready <= 1'b0; st <= S_LWPT; cnt <= 3'd0; end
            end
            S_LWPT: begin
                // the check byte each doubleword is stored with, and its poison entry
                logic [7:0] stored;
                stored = ecc_on ? wecc[cnt[1:0]] : r_wrt_chk[31 - 8*cnt[1:0] -: 8];
                l_chkw[31 - 8*cnt[1:0] -: 8] <= stored;
                if (l_blk.bank) begin
                    pw_en <= 1'b1; pw_dw <= {l_blk.off[27:5], cnt[1:0]};
                    pw_stored <= stored; pw_ecc <= wecc[cnt[1:0]];
                end
                cnt <= cnt + 3'd1;
                if (cnt == 3'd3) begin
                    cnt <= 3'd0; wcnt <= 2'd0;
                    if (!l_blk.hit) begin
                        st_set[1] = 1'b1; ea_we = 1'b1; ea_val = {l_addr[31:5], 5'd0};
                        dbg_buserr <= 1'b1; dbg_buserr_addr <= l_addr;
                        st <= S_IDLE;
                    end else if (!l_blk.bank) st <= S_IDLE;
                    else begin
                        st <= S_LWRAM;
                        ram_req <= 1'b1; ram_we <= 1'b1; ram_line <= 1'b1; ram_be <= 8'hFF;
                        ram_addr <= {l_blk.off[27:5], 5'd0}; ram_wdata <= wbuf[0];
                    end
                end
            end
            S_LWRAM: begin
                if (ram_ack) ram_req <= 1'b0;
                if (ram_wready) begin
                    wcnt <= wcnt + 2'd1;
                    ram_wdata <= wbuf[wcnt + 2'd1];
                    if (wcnt == 2'd3) begin
                        st <= S_LWCHK;
                        chk_req <= 1'b1; chk_we <= 1'b1; chk_addr <= l_blk.off[27:5];
                        chk_be <= 4'hF; chk_wdata <= l_chkw;
                    end
                end
            end
            S_LWCHK: if (chk_ack) begin chk_req <= 1'b0; st <= S_IDLE; end

            S_LRDEC: begin
                if (l_blk.bank && cnt == 3'd0) begin
                    // RAM behind it: start the fill, critical doubleword first
                    st <= S_LRRAM;
                    ram_req <= 1'b1; ram_we <= 1'b0; ram_line <= 1'b1; ram_be <= 8'hFF;
                    ram_addr <= {l_blk.off[27:5], l_addr[4:3], 3'd0};
                    f_start <= l_addr[4:3];
                    last_fill_line <= l_blk.off[27:5];
                end else begin
                    // no comparator: bus error on every beat; empty bank: all ones
                    mem_rvalid <= 1'b1; mem_rdata <= 64'hFFFF_FFFF_FFFF_FFFF;
                    mem_rbeat <= l_addr[4:3] + cnt[1:0]; mem_rerr <= !l_blk.hit;
                    if (cnt == 3'd0 && !l_blk.hit) begin
                        st_set[1] = 1'b1; ea_we = 1'b1; ea_val = l_addr;
                        dbg_buserr <= 1'b1; dbg_buserr_addr <= l_addr;
                    end
                    cnt <= cnt + 3'd1;
                    if (cnt == 3'd3) st <= S_IDLE;
                end
            end
            S_LRRAM: begin
                if (ram_ack) ram_req <= 1'b0;
                if (ram_rvalid) begin
                    f1_v <= 1'b1; f1_data <= ram_rdata; f1_beat <= f_start + cnt[1:0];
                    cnt <= cnt + 3'd1;
                    if (cnt == 3'd3) st <= S_IDLE;     // stage 2 delivers the last beat next cycle
                end
            end

            // ---------------------------------------------- uncached port
            S_IDEC: begin
                cls_e c;
                c = io_class(u_addr);
                u_cls <= c;
                u_blk <= blk_decode(u_addr);
                cnt <= 3'd0;
                tmo <= 10'd0;
                u_hi_pending <= u_be[7:4] != 4'd0 || u_be == 8'd0;
                u_lo_pending <= u_be[3:0] != 4'd0;
                if (u_we && u_addr[31:28] == 4'hF && (pgape || pgdpe)) begin
                    // MIOC_CONTROL parity injection: this I/O store fails and is dropped
                    st_set[pgape ? 1 : 3] = 1'b1; ea_we = 1'b1; ea_val = u_addr;
                    r_control[14] <= 1'b0; r_control[13] <= 1'b0;
                    u_err <= 1'b1;
                    st <= S_IRESP;
                end else
                case (c)
                    C_MEM:  st <= S_IRAMRD;           // decided once u_blk is known
                    C_ROM:  begin
                        if (u_we) st <= S_IRESP;       // flash writes are dropped
                        else if (rb_valid && rb_line == u_addr[17:5] && !u_burst) begin
                            u_rdata <= rb[u_addr[4:3]]; st <= S_IRESP;
                        end else if (rb_valid && rb_line == u_addr[17:5]) st <= S_IROMOUT;
                        else begin
                            st <= S_IROM; rom_req <= 1'b1; rom_addr <= u_addr[17:5]; rb_valid <= 1'b0;
                        end
                    end
                    C_XBUS, C_LASI, C_WAX, C_ART: st <= S_IGSC;
                    C_CPU: begin
                        u_rdata <= 64'd0;
                        if (u_we && u_addr[11:2] == 10'd0) begin           // IO_EIR
                            eir_set <= 1'b1; eir_num <= u_word[4:0];
                        end
                        if (u_we && u_addr[11:2] == 10'h00C && u_word == 32'd5) begin  // IO_COMMAND
                            toc_req <= 1'b1; st_set[4] = 1'b1;
                        end
                        st <= S_IRESP;
                    end
                    C_MIOC: begin
                        if (u_we) begin
                            case (u_addr[11:0] & 12'hFFC)
                                12'h080: r_control <= u_word;
                                12'h084: st_clr = u_word[6:0];
                                12'h0C0: r_mtcv <= u_word;
                                12'h0C4: r_wrt_chk <= u_word;
                                12'h0D0: r_err0 <= u_word;
                                default:
                                    if (u_addr[11:7] == 5'b00010) begin
                                        if (u_addr[6]) r_mask[u_addr[5:2]] <= u_word;
                                        else           r_comp[u_addr[5:2]] <= u_word;
                                    end
                            endcase
                            st <= S_IRESP;
                        end else if ((u_addr[11:0] & 12'hFFC) == 12'h0DC) begin
                            st <= S_ICHKRD;
                            chk_req <= 1'b1; chk_we <= 1'b0; chk_addr <= last_fill_line; chk_be <= 4'hF;
                        end else begin
                            u_rdata <= {2{mioc_rd(u_addr[11:0] & 12'hFFC)}};
                            st <= S_IRESP;
                        end
                    end
                    C_BCAST: begin
                        u_rdata <= 64'd0;
                        if (u_we) case (u_addr[17:2] & 16'h3FFF)
                            16'h0000: begin eir_set <= 1'b1; eir_num <= u_word[4:0]; end
                            16'h0008: r_flexid <= u_word;
                            16'h000C: if (u_word == 32'd5) bcast_reset <= 1'b1;
                            default: ;
                        endcase
                        st <= S_IRESP;
                    end
                    default: begin
                        st_set[1] = 1'b1; ea_we = 1'b1; ea_val = u_addr;
                        u_err <= 1'b1; u_rdata <= 64'd0;
                        st <= S_IRESP;
                    end
                endcase
            end

            // uncached memory: single doubleword reads, read-modify-writes,
            // read-and-clear; bursts (code fetched from a U-bit page)
            S_IRAMRD: begin
                if (!u_blk.hit) begin
                    st_set[1] = 1'b1; ea_we = 1'b1; ea_val = u_addr;
                    u_err <= 1'b1; u_rdata <= 64'd0; st <= S_IRESP;
                end else if (!u_blk.bank) begin
                    u_rdata <= 64'hFFFF_FFFF_FFFF_FFFF;
                    st <= u_burst ? S_IRAMBURST : S_IRESP;
                end else if (!ram_req && cnt == 3'd0) begin
                    ram_req <= 1'b1; ram_we <= 1'b0; ram_be <= 8'hFF;
                    ram_line <= u_burst;
                    ram_addr <= u_burst ? {u_blk.off[27:5], 5'd0} : {u_blk.off[27:3], 3'd0};
                    cnt <= 3'd1;
                end else begin
                    if (ram_ack) ram_req <= 1'b0;
                    if (ram_rvalid) begin
                        pe_t e;
                        logic [63:0] d;
                        e = pt_find(u_burst ? {u_blk.off[27:5], cnt[1:0] - 2'd1} : u_blk.off[27:3]);
                        d = ram_rdata;
                        if (ecc_on && e.v && e.cls == 2'd2) d[63 - e.bitn] = ~d[63 - e.bitn];
                        if (ecc_on && e.v) st_set[e.cls == 2'd3 ? 5 : 6] = 1'b1;
                        if (u_burst) begin
                            io_ack <= 1'b1; io_rdata <= d; io_last <= cnt == 3'd4;
                            cnt <= cnt + 3'd1;
                            if (cnt == 3'd4) st <= S_IGAP;
                        end else begin
                            u_rdata <= d;
                            st <= (u_we || u_rclr) ? S_IMERGE : S_IRESP;
                        end
                    end
                end
            end
            S_IRAMBURST: begin       // an empty bank answering a burst
                io_ack <= 1'b1; io_rdata <= u_rdata; io_last <= cnt == 3'd3;
                cnt <= cnt + 3'd1;
                if (cnt == 3'd3) st <= S_IGAP;
            end
            S_IMERGE: begin
                logic [63:0] m;
                logic [7:0]  stored, e8;
                m = u_rdata;
                if (u_rclr) begin
                    if (u_addr[2]) m[31:0] = 32'd0; else m[63:32] = 32'd0;
                end else
                    for (int b = 0; b < 8; b++) if (u_be[b]) m[8*b +: 8] = u_wdata[8*b +: 8];
                e8 = ecc_of(m);
                stored = ecc_on ? e8 : r_wrt_chk[31 - 8*u_blk.off[4:3] -: 8];
                pw_en <= 1'b1; pw_dw <= u_blk.off[27:3]; pw_stored <= stored; pw_ecc <= e8;
                ram_req <= 1'b1; ram_we <= 1'b1; ram_line <= 1'b0; ram_be <= 8'hFF;
                ram_addr <= {u_blk.off[27:3], 3'd0}; ram_wdata <= m;
                chk_addr <= u_blk.off[27:5]; chk_be <= 4'b1000 >> u_blk.off[4:3];
                chk_wdata <= {4{stored}};
                st <= S_IRAMWR;
            end
            S_IRAMWR: begin
                if (ram_ack) ram_req <= 1'b0;
                if (ram_wready) begin
                    st <= S_ICHKWR; chk_req <= 1'b1; chk_we <= 1'b1;
                end
            end
            S_ICHKWR: if (chk_ack) begin chk_req <= 1'b0; st <= S_IRESP; end
            S_ICHKRD: if (chk_ack) begin
                chk_req <= 1'b0; u_rdata <= {2{chk_rdata}}; st <= S_IRESP;
            end

            // boot ROM: fill the line buffer, streaming the beats of a burst
            S_IROM: begin
                if (rom_ack) rom_req <= 1'b0;
                if (rom_rvalid) begin
                    rb[cnt[1:0]] <= rom_rdata;
                    if (u_burst) begin
                        io_ack <= 1'b1; io_rdata <= rom_rdata; io_last <= cnt == 3'd3;
                    end else if (cnt[1:0] == u_addr[4:3]) u_rdata <= rom_rdata;
                    cnt <= cnt + 3'd1;
                    if (cnt == 3'd3) begin
                        rb_valid <= !rom_inval; rb_line <= u_addr[17:5];
                        st <= u_burst ? S_IGAP : S_IRESP;
                    end
                end
            end
            S_IROMOUT: begin
                io_ack <= 1'b1; io_rdata <= rb[cnt[1:0]]; io_last <= cnt == 3'd3;
                cnt <= cnt + 3'd1;
                if (cnt == 3'd3) st <= S_IGAP;
            end

            // GSC devices: the upper word, then the lower word of the doubleword
            S_IGSC: begin
                gsc_req <= 1'b1; gsc_we <= u_we;
                gsc_dev <= u_cls == C_XBUS ? 2'd0 : u_cls == C_LASI ? 2'd1 : u_cls == C_WAX ? 2'd2 : 2'd3;
                if (u_hi_pending) begin
                    gsc_addr <= {u_addr[31:3], 3'd0}; gsc_be <= u_be[7:4] | {4{u_be == 8'd0}};
                    gsc_wdata <= u_wdata[63:32];
                end else begin
                    gsc_addr <= {u_addr[31:3], 3'd4}; gsc_be <= u_be[3:0]; gsc_wdata <= u_wdata[31:0];
                end
                tmo <= 10'd0;
                st <= S_IGSCW;
            end
            S_IGSCW: begin
                tmo <= tmo + 10'd1;
                if (gsc_ack || &tmo) begin
                    if (u_hi_pending) begin u_rdata[63:32] <= gsc_rdata; u_hi_pending <= 1'b0; end
                    else              begin u_rdata[31:0]  <= gsc_rdata; u_lo_pending <= 1'b0; end
                    if (!gsc_ack || gsc_err) begin
                        st_set[1] = 1'b1; ea_we = 1'b1; ea_val = u_addr; u_err <= 1'b1;
                        if (!gsc_ack) $display("mioc: GSC timeout at %08x", u_addr);
                    end
                    st <= (u_hi_pending && u_lo_pending) ? S_IGSC : S_IRESP;
                end
            end

            // the acknowledge of a single (non-burst) transfer
            S_IRESP: begin
                io_ack <= 1'b1; io_last <= 1'b1; io_err <= u_err;
                // a one-word device read: the word in both halves
                if (u_cls == C_XBUS || u_cls == C_LASI || u_cls == C_WAX || u_cls == C_ART)
                    io_rdata <= u_be[3:0] == 4'd0 ? {2{u_rdata[63:32]}} :
                                u_be[7:4] == 4'd0 ? {2{u_rdata[31:0]}} : u_rdata;
                else io_rdata <= u_rdata;
                if (u_err) begin dbg_buserr <= 1'b1; dbg_buserr_addr <= u_addr; end
                st <= S_IGAP;
            end
            S_IGAP: st <= S_IDLE;
            default: st <= S_IDLE;
            endcase

            r_status[6:0] <= (r_status[6:0] & ~st_clr) | st_set;
            if (ea_we) r_derradd <= ea_val;
        end
    end

    wire unused = mem_ifill | io_ifetch;
endmodule
