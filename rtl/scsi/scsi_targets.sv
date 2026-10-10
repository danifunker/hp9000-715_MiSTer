// The SCSI devices on the 715's internal bus (docs/design/system.md 5;
// docs/review/06d): up to two disks and a CD-ROM, each an image on an
// hps_io block-device slot, behind a byte-level model of the bus (STUBS
// S-020): no REQ/ACK timing, no parity, no arbitration; one device is
// connected at a time and it never disconnects in the middle of a command
// (so the initiator never sees a reselection).
//
// The bus, as the initiator (rtl/scsi/ncr53c710.sv) drives it:
//   sel/sel_id/sel_atn  select a target (pulse); sel_done = it answered,
//                       sel_fail = nobody at that ID (the initiator times out)
//   bsy                 a target is connected
//   req, phase, tdata   the target requests a byte in phase {MSG, C/D, I/O};
//                       tdata is the byte for IN phases
//   ack, idata          the initiator took (IN) or gave (OUT) the byte
//   ackhold             the initiator holds ACK after a MESSAGE IN byte
//                       (until its CLEAR ACK); the target waits for it to drop
//   atn                 ATN; the target goes to MESSAGE OUT when it can
//   brst                bus reset
//
// Device commands: TEST UNIT READY, REZERO, REQUEST SENSE, FORMAT UNIT,
// READ/WRITE(6/10), SEEK, INQUIRY, MODE SELECT/SENSE(6/10) (pages 1, 3, 4,
// 8), RESERVE/RELEASE, START STOP, SEND DIAGNOSTIC, PREVENT ALLOW, READ
// CAPACITY, VERIFY, SYNCHRONIZE CACHE. The CD-ROM adds READ TOC (formats 0
// and 1, LBA or M:S:F) from the image's track table, and CD audio through
// rtl/scsi/cd_audio.sv: PLAY AUDIO (10), (12), MSF and TRACK/INDEX,
// PAUSE/RESUME, STOP PLAY, READ SUB-CHANNEL (formats 1-3) and MODE page 0x0E
// (the port volumes). The track table and the audio frames come from
// Main_MiSTer's windows on the CD slot (support/hp9k); with a Main that has
// none the table reads empty and the CD is one data track. Anything else:
// CHECK CONDITION, ILLEGAL REQUEST. SDTR is answered with the same period
// and offset (the transfer timing is not modelled anyway).
module scsi_targets #(
    parameter logic [2:0] DISK0_ID = 3'd6,
    parameter logic [2:0] DISK1_ID = 3'd5,
    parameter logic [2:0] CD_ID    = 3'd2
) (
    input  logic        clk,
    input  logic        rst,
    // the bus
    input  logic        sel,
    input  logic [2:0]  sel_id,
    input  logic        sel_atn,
    output logic        sel_done,
    output logic        sel_fail,
    output logic        bsy,
    output logic        req,
    output logic [2:0]  phase,
    output logic [7:0]  tdata,
    input  logic        ack,
    input  logic [7:0]  idata,
    input  logic        ackhold,
    input  logic        atn,
    input  logic        brst,
    // the images: slot 0 disk 0, 1 disk 1, 2 CD-ROM (hps_io block devices,
    // 512-byte blocks, WIDE)
    input  logic [2:0]  img_present,
    input  logic [31:0] img_blocks [3],     // size in 512-byte blocks
    output logic [31:0] sd_lba [3],
    output logic [5:0]  sd_blk_cnt [3],
    output logic [2:0]  sd_rd,
    output logic [2:0]  sd_wr,
    input  logic [2:0]  sd_ack,
    input  logic [12:0] sd_buff_addr,
    input  logic [15:0] sd_buff_dout,
    output logic [15:0] sd_buff_din [3],
    input  logic        sd_buff_wr,
    input  logic        cd_change,          // the CD slot's image was (re)mounted
    output logic signed [15:0] cd_l, cd_r,  // CD audio
    output logic        activity
);
    // INQUIRY identification: vendor (8), product (16), revision (4)
    localparam logic [223:0] ID_DISK = "SEAGATE ST32550N        0021";
    localparam logic [223:0] ID_CD   = "TOSHIBA CD-ROM XM-3301TA0272";
    localparam logic [2:0] P_DOUT = 3'b000, P_DIN = 3'b001, P_CMD = 3'b010, P_STAT = 3'b011,
                           P_MOUT = 3'b110, P_MIN = 3'b111;

    // ----------------------------------------------------- sector buffer
    // 2 KB = 1024 halfwords; hps_io's halfword w = {byte 2w+1, byte 2w}
    (* ramstyle = "M10K, no_rw_check" *) logic [1:0][7:0] buf_mem [0:1023];
    logic [10:0] b_addr;        // byte address, engine side
    logic        b_we;
    logic [7:0]  b_wdata, b_q;
    logic [15:0] h_q;
    logic        aud_xfer;              // the transfer is the CD player's frame
    always @(posedge clk) begin           // port A: hps_io
        if (sd_buff_wr && |sd_ack && !aud_xfer) buf_mem[sd_buff_addr[9:0]] <= sd_buff_dout;
        h_q <= buf_mem[sd_buff_addr[9:0]];
    end
    always @(posedge clk) begin           // port B: the engine, one byte
        if (b_we) buf_mem[b_addr[10:1]][b_addr[0]] <= b_wdata;
        b_q <= buf_mem[b_addr[10:1]][b_addr[0]];
    end
    assign sd_buff_din[0] = h_q;
    assign sd_buff_din[1] = h_q;
    assign sd_buff_din[2] = h_q;

    // ----------------------------------------------------------- state
    typedef enum logic [3:0] {
        T_FREE, T_MOUT, T_MIN, T_CMD, T_EXEC, T_DIN, T_DOUT, T_FETCH, T_STORE, T_STAT, T_DONE, T_DISC,
        T_TOC, T_TOCW, T_TOCCP, T_TRK
    } st_e;
    st_e st;
    logic [1:0]  dev;                    // 0, 1 disks, 2 CD-ROM
    logic [2:0]  lun;
    logic [7:0]  cdb [12];
    logic [3:0]  cdb_n, cdb_len;
    logic [7:0]  msg [5];
    logic [2:0]  msg_n;
    logic        sdtr_reply;
    logic [7:0]  sdtr_p, sdtr_o;
    logic [2:0]  min_n, min_len;
    logic [7:0]  min_b [5];
    logic [7:0]  status;
    logic [3:0]  skey [3];
    logic [7:0]  sasc [3];
    // data phase
    logic        din_synth;              // IN data synthesised (INQUIRY ...) rather than from the buffer
    logic [15:0] d_left;                 // bytes left in the data phase
    logic [15:0] d_idx;                  // byte index into the synthesised response
    logic [31:0] x_lba;                  // next block of a READ/WRITE
    logic [31:0] x_blocks;               // 512-byte blocks left
    logic [11:0] chunk;                  // bytes left in the buffer chunk
    logic        pending;                // waiting for the buffer byte
    logic        hold_seen;

    // ------------------------------------------------------------ CD audio
    logic        toc_ok, toc_we;
    logic [6:0]  toc_a, toc_a_r;
    logic [63:0] toc_wd, toc_q;
    logic [7:0]  toc_first, toc_n;
    logic [10:0] cp_b;                   // the table copy: byte, sub-step
    logic [1:0]  cp_s;
    logic        a_play, a_pause, a_resume, a_stop, a_stread;
    logic [23:0] a_start, a_end;
    logic [7:0]  a_status, q_ctl, q_track;
    logic [23:0] q_abs_lba, q_rel_lba, q_abs_msf, q_rel_msf;
    logic        fr_req, fr_go, fr_done;
    logic [31:0] fr_lba;
    logic [7:0]  vol0, vol1;
    logic [6:0]  rt_first;               // READ TOC: the first entry sent, how many
    logic [7:0]  rt_nd;
    logic [7:0]  rs_status, rs_ctl, rs_track;      // READ SUB-CHANNEL, taken at the command
    logic [23:0] rs_abs, rs_rel;
    logic [2:0]  trk_s;
    logic [15:0] ms_i;                   // MODE SELECT: parameter byte, block descriptor length, page
    logic [7:0]  ms_bdl;
    logic [5:0]  ms_pg;

    always_comb toc_a = (st == T_DIN && cdb[0] == 8'h43) ? 7'(rt_first + 7'((d_idx - 16'd4) >> 3)) : toc_a_r;

    cd_audio u_cda (
        .clk(clk), .rst(rst),
        .toc_we(toc_we), .toc_a(toc_a), .toc_wd(toc_wd), .toc_q(toc_q), .toc_first(toc_first), .toc_n(toc_n),
        .play(a_play), .p_start(a_start), .p_end(a_end), .pause(a_pause), .resume(a_resume), .stop(a_stop),
        .a_status(a_status), .status_read(a_stread), .q_ctl(q_ctl), .q_track(q_track),
        .q_abs_lba(q_abs_lba), .q_rel_lba(q_rel_lba), .q_abs_msf(q_abs_msf), .q_rel_msf(q_rel_msf),
        .fr_req(fr_req), .fr_lba(fr_lba), .fr_go(fr_go), .fr_done(fr_done),
        .fb_we(sd_buff_wr && sd_ack[2] && aud_xfer), .fb_addr(sd_buff_addr[10:0]), .fb_data(sd_buff_dout),
        .vol_l(vol0), .vol_r(vol1), .out_l(cd_l), .out_r(cd_r));

    // M:S:F (absolute, +150) to LBA
    function automatic logic [23:0] msf_lba(input logic [7:0] m, input logic [7:0] sec, input logic [7:0] f);
        return {16'd0, m} * 24'd4500 + {16'd0, sec} * 24'd75 + {16'd0, f} - 24'd150;
    endfunction

    wire [31:0] blocks = img_blocks[dev];
    wire        is_cd  = dev == 2'd2;
    wire [3:0]  bshift = is_cd ? 4'd2 : 4'd0;           // device block = 2^bshift 512-byte blocks

    // a group code's CDB length
    function automatic logic [3:0] cdb_length(input logic [7:0] op);
        case (op[7:5])
            3'd0: return 4'd6;
            3'd1, 3'd2: return 4'd10;
            3'd5: return 4'd12;
            default: return 4'd6;
        endcase
    endfunction

    // the synthesised IN data: INQUIRY, REQUEST SENSE, READ CAPACITY,
    // MODE SENSE, READ TOC
    logic [7:0] syn;
    always_comb begin
        logic [31:0] last;
        logic [31:0] nblk;
        logic [7:0]  op;
        logic [15:0] i;
        logic        ms10;
        logic [5:0]  pg;
        logic [15:0] hdr, k;
        op = cdb[0]; i = d_idx; syn = 8'd0;
        nblk = blocks >> bshift;
        last = nblk - 32'd1;
        case (op)
            8'h12: begin                                         // INQUIRY
                if (lun != 3'd0) syn = (i == 0) ? 8'h7F : 8'h00;
                else case (i)
                    0: syn = is_cd ? 8'h05 : 8'h00;
                    1: syn = is_cd ? 8'h80 : 8'h00;
                    2: syn = 8'h02;
                    3: syn = 8'h02;
                    4: syn = 8'd31;
                    7: syn = 8'h10;                               // synchronous transfers
                    default:
                        // vendor (8), product (16), revision (4)
                        if (i >= 8 && i < 36) syn = is_cd ? ID_CD[8'(35 - i) * 8 +: 8] : ID_DISK[8'(35 - i) * 8 +: 8];
                endcase
            end
            8'h03: case (i)                                      // REQUEST SENSE
                0: syn = 8'h70;
                2: syn = {4'd0, skey[dev]};
                7: syn = 8'd10;
                12: syn = sasc[dev];
                default: ;
            endcase
            8'h25: case (i)                                      // READ CAPACITY
                0: syn = last[31:24]; 1: syn = last[23:16]; 2: syn = last[15:8]; 3: syn = last[7:0];
                6: syn = is_cd ? 8'h08 : 8'h02; 7: syn = 8'h00;
                default: ;
            endcase
            8'h43: begin                                         // READ TOC
                logic [15:0] len, e;
                logic        msf;
                msf = cdb[1][1];
                if (toc_n == 8'd0) begin
                    // no track table: one data track, as the image is long
                    case (i)
                        0: syn = 8'h00; 1: syn = 8'd18; 2: syn = 8'd1; 3: syn = 8'd1;
                        5: syn = 8'h14; 6: syn = 8'd1;
                        13: syn = 8'h14; 14: syn = 8'hAA;
                        16: syn = nblk[31:24]; 17: syn = nblk[23:16]; 18: syn = nblk[15:8]; 19: syn = nblk[7:0];
                        default: ;
                    endcase
                end else begin
                    // header {length, first, last}, then rt_nd entries from rt_first
                    // (format 1: the first track's only), each {0, ADR/control,
                    // track, 0, address}; toc_q is the entry of this byte
                    len = 16'd2 + {5'd0, rt_nd, 3'd0};
                    e = i - 16'd4;
                    if (i < 4) case (i)
                        0: syn = len[15:8]; 1: syn = len[7:0];
                        2: syn = (cdb[9][7:6] == 2'd1 || cdb[2][3:0] == 4'd1) ? 8'd1 : toc_first;
                        3: syn = (cdb[9][7:6] == 2'd1 || cdb[2][3:0] == 4'd1) ? 8'd1 : toc_first + toc_n - 8'd1;
                        default: ;
                    endcase
                    else case (e[2:0])
                        3'd1: syn = toc_q[63:56];
                        3'd2: syn = toc_q[55:48];
                        3'd4: syn = 8'd0;
                        3'd5: syn = msf ? toc_q[47:40] : toc_q[23:16];
                        3'd6: syn = msf ? toc_q[39:32] : toc_q[15:8];
                        3'd7: syn = msf ? toc_q[31:24] : toc_q[7:0];
                        default: syn = 8'd0;
                    endcase
                end
            end
            8'h42: begin                                         // READ SUB-CHANNEL
                logic [15:0] dl;
                dl = !cdb[2][6] ? 16'd0 : cdb[3] == 8'd1 ? 16'd12 : 16'd20;
                case (i)
                    0: syn = 8'h00; 1: syn = rs_status; 2: syn = dl[15:8]; 3: syn = dl[7:0];
                    4: syn = cdb[3];
                    5: syn = cdb[3] == 8'd2 ? 8'h00 : rs_ctl;
                    6: syn = cdb[3] == 8'd1 || cdb[3] == 8'd3 ? rs_track : 8'h00;
                    7: syn = cdb[3] == 8'd1 ? 8'd1 : 8'h00;
                    // the positions: {0, M, S, F} or the LBA, as taken at the command
                    9: syn = cdb[3] == 8'd1 ? rs_abs[23:16] : 8'd0;
                    10: syn = cdb[3] == 8'd1 ? rs_abs[15:8] : 8'd0;
                    11: syn = cdb[3] == 8'd1 ? rs_abs[7:0] : 8'd0;
                    13: syn = cdb[3] == 8'd1 ? rs_rel[23:16] : 8'd0;
                    14: syn = cdb[3] == 8'd1 ? rs_rel[15:8] : 8'd0;
                    15: syn = cdb[3] == 8'd1 ? rs_rel[7:0] : 8'd0;
                    default: ;
                endcase
            end
            8'h1A, 8'h5A: begin                                  // MODE SENSE(6) / (10)
                ms10 = op == 8'h5A;
                pg = cdb[2][5:0];
                hdr = ms10 ? 16'd8 : 16'd4;
                // header, block descriptor (8), then page 1 (12), 3 (24), 4 (24), 8 (12)
                if (i < hdr) begin
                    logic [15:0] total;
                    total = hdr + 16'd8 + ((pg == 6'h3F) ? (is_cd ? 16'd88 : 16'd72) : (pg == 6'h01 || pg == 6'h08) ? 16'd12 :
                                           (pg == 6'h03 || pg == 6'h04) ? 16'd24 : (pg == 6'h0E) ? 16'd16 : 16'd0);
                    if (!ms10) case (i)
                        0: syn = total[7:0] - 8'd1;
                        3: syn = 8'd8;
                        default: ;
                    endcase
                    else case (i)
                        0: syn = 8'd0; 1: syn = total[7:0] - 8'd2;
                        7: syn = 8'd8;
                        default: ;
                    endcase
                end else if (i < hdr + 8) begin
                    k = i - hdr;
                    case (k)
                        1: syn = nblk[23:16]; 2: syn = nblk[15:8]; 3: syn = nblk[7:0];
                        6: syn = is_cd ? 8'h08 : 8'h02;
                        default: ;
                    endcase
                end else begin
                    logic [15:0] pi;                            // byte within the page list
                    logic [7:0]  pcode;
                    logic [15:0] po;
                    pi = i - hdr - 16'd8;
                    // which page, and the offset into it
                    if (pg == 6'h3F) begin
                        if (pi < 12)      begin pcode = 8'h01; po = pi; end
                        else if (pi < 36) begin pcode = 8'h03; po = pi - 12; end
                        else if (pi < 60) begin pcode = 8'h04; po = pi - 36; end
                        else if (pi < 72) begin pcode = 8'h08; po = pi - 60; end
                        else              begin pcode = 8'h0E; po = pi - 72; end
                    end else begin pcode = {2'b00, pg}; po = pi; end
                    case (pcode)
                        8'h01: case (po) 0: syn = 8'h01; 1: syn = 8'd10; default: ; endcase
                        8'h03: case (po)                          // format: 64 sectors/track, 512 bytes
                            0: syn = 8'h03; 1: syn = 8'd22; 11: syn = 8'd64; 12: syn = 8'h02; default: ;
                        endcase
                        8'h04: case (po)                          // geometry: 16 heads, cylinders = blocks / 1024
                            0: syn = 8'h04; 1: syn = 8'd22;
                            2: syn = {2'b00, nblk[31:26]}; 3: syn = nblk[25:18]; 4: syn = nblk[17:10];
                            5: syn = 8'd16; 20: syn = 8'h1C; 21: syn = 8'h20;    // 7200 rpm
                            default: ;
                        endcase
                        8'h08: case (po) 0: syn = 8'h08; 1: syn = 8'd10; default: ; endcase
                        8'h0E: case (po)                          // CD audio control: IMMED, ports 0/1 = left/right
                            0: syn = 8'h0E; 1: syn = 8'd14; 2: syn = 8'h04;
                            8: syn = 8'h01; 9: syn = vol0; 10: syn = 8'h02; 11: syn = vol1;
                            default: ;
                        endcase
                        default: ;
                    endcase
                end
            end
            default: ;
        endcase
    end

    // the MODE SENSE pages served
    function automatic logic page_ok(input logic [5:0] pg);
        return pg == 6'h00 || pg == 6'h01 || pg == 6'h03 || pg == 6'h04 || pg == 6'h08 || pg == 6'h3F ||
               (pg == 6'h0E && is_cd);
    endfunction

    // how many bytes a synthesised response has before the allocation length
    function automatic logic [15:0] resp_len(input logic [7:0] op, input logic [5:0] pg);
        case (op)
            8'h12: return 16'd36;
            8'h03: return 16'd18;
            8'h25: return 16'd8;
            8'h43: return 16'd20;
            8'h1A, 8'h5A: return ((op == 8'h5A) ? 16'd16 : 16'd12) +
                                 ((pg == 6'h3F) ? (is_cd ? 16'd88 : 16'd72) : (pg == 6'h01 || pg == 6'h08) ? 16'd12 :
                                  (pg == 6'h03 || pg == 6'h04) ? 16'd24 : (pg == 6'h0E) ? 16'd16 : 16'd0);
            default: return 16'd0;
        endcase
    endfunction

    // ------------------------------------------------------------- engine
    wire [2:0] id_hit = {img_present[2] && sel_id == CD_ID, img_present[1] && sel_id == DISK1_ID,
                         img_present[0] && sel_id == DISK0_ID};
    logic        sd_busy;
    logic [1:0]  sd_dev;
    logic        sd_was_ack;

    assign activity = st != T_FREE;

    task automatic go_status(input logic [7:0] s);
        status <= s; st <= T_STAT; req <= 1'b1; phase <= P_STAT; tdata <= s;
    endtask

    always_ff @(posedge clk) begin
        sel_done <= 1'b0; sel_fail <= 1'b0; b_we <= 1'b0;
        a_play <= 1'b0; a_pause <= 1'b0; a_resume <= 1'b0; a_stop <= 1'b0; a_stread <= 1'b0;
        toc_we <= 1'b0; fr_go <= 1'b0; fr_done <= 1'b0;
        sd_was_ack <= |sd_ack;
        if (rst || brst) begin
            st <= T_FREE; bsy <= 1'b0; req <= 1'b0; sd_rd <= 3'd0; sd_wr <= 3'd0; sd_busy <= 1'b0;
            for (int d = 0; d < 3; d++) begin skey[d] <= 4'd0; sasc[d] <= 8'd0; end
            pending <= 1'b0; aud_xfer <= 1'b0;
            if (rst) begin toc_ok <= 1'b0; toc_n <= 8'd0; vol0 <= 8'hFF; vol1 <= 8'hFF; a_stop <= 1'b1; end
        end else begin
            // block device handshake: drop rd/wr when ack rises, done when it falls
            if (|(sd_ack & (sd_rd | sd_wr))) begin sd_rd <= 3'd0; sd_wr <= 3'd0; end
            if (sd_busy && sd_was_ack && !(|sd_ack) && !(|sd_rd) && !(|sd_wr)) begin
                sd_busy <= 1'b0;
                if (aud_xfer) begin aud_xfer <= 1'b0; fr_done <= 1'b1; end
            end
            // a new disc: its table is read again at the next command that needs it
            if (cd_change) begin toc_ok <= 1'b0; toc_n <= 8'd0; a_stop <= 1'b1; end

            // a frame for the CD player, between the engine's own transfers
            if (fr_req && !fr_go && !sd_busy && img_present[2] &&
                st != T_FETCH && st != T_DOUT && st != T_STORE && st != T_TOC) begin
                sd_lba[2] <= fr_lba; sd_blk_cnt[2] <= 6'd4; sd_rd[2] <= 1'b1; sd_busy <= 1'b1; sd_dev <= 2'd2;
                aud_xfer <= 1'b1; fr_go <= 1'b1;
            end

            case (st)
                T_FREE: if (sel) begin
                    if (id_hit != 3'd0) begin
                        dev <= id_hit[0] ? 2'd0 : id_hit[1] ? 2'd1 : 2'd2;
                        bsy <= 1'b1; sel_done <= 1'b1; lun <= 3'd0; msg_n <= 3'd0; sdtr_reply <= 1'b0;
                        if (sel_atn) begin st <= T_MOUT; req <= 1'b1; phase <= P_MOUT; end
                        else begin st <= T_CMD; req <= 1'b1; phase <= P_CMD; cdb_n <= 4'd0; end
                    end else sel_fail <= 1'b1;
                end

                // MESSAGE OUT while ATN is asserted
                T_MOUT: if (ack && req) begin
                    logic [7:0] m;
                    m = idata;
                    if (msg_n == 3'd0 && m[7]) lun <= m[2:0];                 // IDENTIFY
                    if (msg_n == 3'd0 && m == 8'h01) msg_n <= 3'd1;           // extended message
                    else if (msg_n != 3'd0) begin
                        msg[msg_n] <= m;
                        msg_n <= msg_n + 3'd1;
                        if (msg_n == 3'd4 && msg[2] == 8'h01) begin           // SDTR complete
                            sdtr_reply <= 1'b1; sdtr_p <= msg[3]; sdtr_o <= m; msg_n <= 3'd0;
                        end else if (msg_n == 3'd4) msg_n <= 3'd0;
                    end
                    req <= 1'b0;
                end else if (!req) begin
                    // the next byte while ATN stays, else the next phase
                    if (atn) req <= 1'b1;
                    else if (sdtr_reply) begin
                        sdtr_reply <= 1'b0; st <= T_MIN; req <= 1'b1; phase <= P_MIN;
                        min_b[0] <= 8'h01; min_b[1] <= 8'h03; min_b[2] <= 8'h01; min_b[3] <= sdtr_p;
                        min_b[4] <= sdtr_o > 8'd8 ? 8'd8 : sdtr_o;
                        min_n <= 3'd0; min_len <= 3'd5; tdata <= 8'h01; hold_seen <= 1'b0;
                    end else begin st <= T_CMD; req <= 1'b1; phase <= P_CMD; cdb_n <= 4'd0; end
                end

                // MESSAGE IN (the SDTR reply), each byte held by the initiator
                T_MIN: begin
                    if (ack && req) begin req <= 1'b0; min_n <= min_n + 3'd1; hold_seen <= 1'b0; end
                    else if (!req) begin
                        if (ackhold) hold_seen <= 1'b1;
                        else if (atn) begin st <= T_MOUT; req <= 1'b1; phase <= P_MOUT; msg_n <= 3'd0; end
                        else if (min_n < min_len) begin req <= 1'b1; tdata <= min_b[min_n]; end
                        else begin st <= T_CMD; req <= 1'b1; phase <= P_CMD; cdb_n <= 4'd0; end
                    end
                end

                T_CMD: if (ack && req) begin
                    cdb[cdb_n] <= idata;
                    if (cdb_n == 4'd0) cdb_len <= cdb_length(idata);
                    cdb_n <= cdb_n + 4'd1;
                    req <= 1'b0;
                    if (cdb_n != 4'd0 && cdb_n + 4'd1 == cdb_len) st <= T_EXEC;
                    else if (cdb_n == 4'd0 && cdb_length(idata) == 4'd1) st <= T_EXEC;
                end else if (!req) req <= 1'b1;

                T_EXEC: begin
                    logic [7:0]  op;
                    logic [31:0] lba, cnt;
                    op = cdb[0];
                    // block address and count of the READ/WRITE forms
                    if (op[7:5] == 3'd0) begin
                        lba = {11'd0, cdb[1][4:0], cdb[2], cdb[3]};
                        cnt = {24'd0, cdb[4]};
                        if (cnt == 0 && (op == 8'h08 || op == 8'h0A)) cnt = 32'd256;
                    end else begin
                        lba = {cdb[2], cdb[3], cdb[4], cdb[5]};
                        cnt = {16'd0, cdb[7], cdb[8]};
                    end
                    d_idx <= 16'd0; ms_i <= 16'd0; ms_bdl <= 8'd0; ms_pg <= 6'h3F;
                    if (is_cd && !toc_ok && (op == 8'h43 || op == 8'h42 || op == 8'h45 || op == 8'h47 ||
                                             op == 8'h48 || op == 8'hA5)) begin
                        st <= T_TOC;                                  // the track table first
                    end else if (lun != 3'd0 && op != 8'h12 && op != 8'h03) begin
                        skey[dev] <= 4'h5; sasc[dev] <= 8'h25; go_status(8'h02);
                    end else if (!is_cd && (op == 8'h43 || op == 8'h42 || op == 8'h45 || op == 8'h47 ||
                                            op == 8'h48 || op == 8'hA5 || op == 8'h4B || op == 8'h4E)) begin
                        skey[dev] <= 4'h5; sasc[dev] <= 8'h20; go_status(8'h02);
                    end else case (op)
                        8'h43: begin                                  // READ TOC
                            logic [15:0] alloc, rl;
                            logic [7:0]  t0, e0, nd;
                            alloc = {cdb[7], cdb[8]};
                            t0 = cdb[6];
                            e0 = (t0 == 8'h00 || t0 <= toc_first) ? 8'd0 : t0 == 8'hAA ? toc_n : t0 - toc_first;
                            nd = toc_n + 8'd1 - e0;
                            if (cdb[9][7:6] == 2'd1 || cdb[2][3:0] == 4'd1) begin e0 = 8'd0; nd = 8'd1; end
                            rl = toc_n == 8'd0 ? 16'd20 : 16'd4 + {5'd0, nd, 3'd0};
                            if (toc_n != 8'd0 && t0 != 8'hAA && t0 > toc_first + toc_n - 8'd1) begin
                                skey[dev] <= 4'h5; sasc[dev] <= 8'h24; go_status(8'h02);
                            end else begin
                                rt_first <= e0[6:0]; rt_nd <= nd;
                                d_left <= (alloc < rl) ? alloc : rl; din_synth <= 1'b1;
                                skey[dev] <= 4'd0; sasc[dev] <= 8'd0;
                                if (((alloc < rl) ? alloc : rl) == 16'd0) go_status(8'h00);
                                else begin st <= T_DIN; req <= 1'b0; phase <= P_DIN; pending <= 1'b1; end
                            end
                        end
                        8'h42: begin                                  // READ SUB-CHANNEL
                            logic [15:0] alloc, rl;
                            alloc = {cdb[7], cdb[8]};
                            rl = !cdb[2][6] ? 16'd4 : cdb[3] == 8'd1 ? 16'd16 : 16'd24;
                            rs_status <= a_status; rs_ctl <= q_ctl; rs_track <= q_track;
                            rs_abs <= cdb[1][1] ? q_abs_msf : q_abs_lba;
                            rs_rel <= cdb[1][1] ? q_rel_msf : q_rel_lba;
                            a_stread <= 1'b1;
                            d_left <= (alloc < rl) ? alloc : rl; din_synth <= 1'b1;
                            skey[dev] <= 4'd0; sasc[dev] <= 8'd0;
                            if (((alloc < rl) ? alloc : rl) == 16'd0) go_status(8'h00);
                            else begin st <= T_DIN; req <= 1'b0; phase <= P_DIN; pending <= 1'b1; end
                        end
                        8'h45, 8'hA5, 8'h47: begin                    // PLAY AUDIO (10), (12), MSF
                            logic [23:0] p0, p1;
                            if (op == 8'h47) begin
                                p0 = (cdb[3] == 8'hFF && cdb[4] == 8'hFF && cdb[5] == 8'hFF) ? q_abs_lba
                                     : msf_lba(cdb[3], cdb[4], cdb[5]);
                                p1 = msf_lba(cdb[6], cdb[7], cdb[8]);
                            end else begin
                                p0 = {cdb[3], cdb[4], cdb[5]};
                                p1 = p0 + ((op == 8'h45) ? {8'd0, cdb[7], cdb[8]} : {cdb[7], cdb[8], cdb[9]});
                            end
                            a_start <= p0; a_end <= p1; a_play <= 1'b1;
                            skey[dev] <= 4'd0; sasc[dev] <= 8'd0; go_status(8'h00);
                        end
                        8'h48: begin                                  // PLAY AUDIO TRACK/INDEX
                            if (toc_n == 8'd0 || cdb[4] < toc_first || cdb[4] > toc_first + toc_n - 8'd1) begin
                                skey[dev] <= 4'h5; sasc[dev] <= 8'h24; go_status(8'h02);
                            end else begin
                                // the start of the first track, the start of the one after the last
                                toc_a_r <= 7'(cdb[4] - toc_first); trk_s <= 3'd0; st <= T_TRK;
                            end
                        end
                        8'h4B: begin                                  // PAUSE/RESUME
                            if (cdb[8][0]) a_resume <= 1'b1; else a_pause <= 1'b1;
                            skey[dev] <= 4'd0; sasc[dev] <= 8'd0; go_status(8'h00);
                        end
                        8'h4E: begin a_stop <= 1'b1; skey[dev] <= 4'd0; sasc[dev] <= 8'd0; go_status(8'h00); end
                        8'h00, 8'h01, 8'h04, 8'h0B, 8'h16, 8'h17, 8'h1B, 8'h1D, 8'h1E, 8'h2B, 8'h2F, 8'h35:
                            begin skey[dev] <= 4'd0; sasc[dev] <= 8'd0; go_status(8'h00); end
                        8'h12, 8'h03, 8'h25, 8'h1A, 8'h5A: begin
                            logic [15:0] alloc, rl;
                            rl = resp_len(op, cdb[2][5:0]);
                            alloc = (op == 8'h25) ? 16'd8 : (op == 8'h43 || op == 8'h5A) ? {cdb[7], cdb[8]} : {8'd0, cdb[4]};
                            if (op == 8'h1A || op == 8'h5A) begin
                                // supported pages only
                                if (!page_ok(cdb[2][5:0])) begin
                                    skey[dev] <= 4'h5; sasc[dev] <= 8'h24; go_status(8'h02);
                                end
                            end
                            if (!((op == 8'h1A || op == 8'h5A) && !page_ok(cdb[2][5:0]))) begin
                                d_left <= (alloc < rl) ? alloc : rl;
                                din_synth <= 1'b1;
                                if (op != 8'h03) begin skey[dev] <= 4'd0; sasc[dev] <= 8'd0; end
                                if ((alloc < rl ? alloc : rl) == 16'd0) go_status(8'h00);
                                else begin st <= T_DIN; req <= 1'b0; phase <= P_DIN; pending <= 1'b1; end
                            end
                        end
                        8'h08, 8'h28: begin                                   // READ
                            if (is_cd) a_stop <= 1'b1;                        // a data read ends a play
                            if (((lba + cnt) << bshift) > blocks) begin
                                skey[dev] <= 4'h5; sasc[dev] <= 8'h21; go_status(8'h02);
                            end else if (cnt == 0) go_status(8'h00);
                            else begin
                                x_lba <= lba << bshift; x_blocks <= cnt << bshift; din_synth <= 1'b0;
                                st <= T_FETCH; phase <= P_DIN; req <= 1'b0;
                            end
                        end
                        8'h0A, 8'h2A, 8'h2E, 8'h15, 8'h55: begin             // WRITE, MODE SELECT
                            if (op == 8'h15 || op == 8'h55) begin
                                // the parameter list is taken and ignored
                                d_left <= (op == 8'h15) ? {8'd0, cdb[4]} : {cdb[7], cdb[8]};
                                x_blocks <= 32'd0;
                                if (((op == 8'h15) ? cdb[4] : cdb[8]) == 8'd0 && (op == 8'h15 || cdb[7] == 8'd0)) go_status(8'h00);
                                else begin st <= T_DOUT; phase <= P_DOUT; req <= 1'b1; chunk <= 12'd0; end
                            end else if (is_cd) begin
                                skey[dev] <= 4'h7; sasc[dev] <= 8'h27; go_status(8'h02);   // write protected
                            end else if ((lba + cnt) > blocks) begin
                                skey[dev] <= 4'h5; sasc[dev] <= 8'h21; go_status(8'h02);
                            end else if (cnt == 0) go_status(8'h00);
                            else begin
                                x_lba <= lba; x_blocks <= cnt; d_left <= 16'd0;
                                chunk <= (cnt >= 4) ? 12'd2048 : {cnt[2:0], 9'd0};
                                b_addr <= 11'd0;
                                st <= T_DOUT; phase <= P_DOUT; req <= 1'b1;
                            end
                        end
                        default: begin skey[dev] <= 4'h5; sasc[dev] <= 8'h20; go_status(8'h02); end
                    endcase
                end

                // read the next chunk (up to 2 KB) from the image
                T_FETCH: if (!sd_busy) begin
                    if (x_blocks == 0) go_status(8'h00);
                    else begin
                        logic [31:0] n;
                        n = (x_blocks >= 4) ? 32'd4 : x_blocks;
                        sd_lba[dev] <= x_lba; sd_blk_cnt[dev] <= 6'(n - 1); sd_rd[dev] <= 1'b1; sd_busy <= 1'b1;
                        sd_dev <= dev;
                        x_lba <= x_lba + n; x_blocks <= x_blocks - n;
                        chunk <= {n[2:0], 9'd0};
                        b_addr <= 11'd0; pending <= 1'b1;
                        st <= T_DIN;
                    end
                end

                // DATA IN, from the synthesised response or the buffer
                T_DIN: begin
                    if (ack && req) begin
                        req <= 1'b0; pending <= 1'b1;
                        if (din_synth) begin d_idx <= d_idx + 16'd1; d_left <= d_left - 16'd1; end
                        else begin b_addr <= b_addr + 11'd1; chunk <= chunk - 12'd1; end
                    end else if (!req && !sd_busy) begin
                        if (din_synth && d_left == 16'd0) go_status(8'h00);
                        else if (!din_synth && chunk == 12'd0) st <= T_FETCH;
                        else if (pending) pending <= 1'b0;           // b_q / syn valid the cycle after
                        else begin req <= 1'b1; tdata <= din_synth ? syn : b_q; end
                    end
                end

                // DATA OUT into the buffer, written to the image per chunk
                T_DOUT: begin
                    if (ack && req) begin
                        req <= 1'b0;
                        // MODE SELECT's parameter bytes are counted by d_left alone: chunk
                        // stays 0 so the completion test below holds after the last byte
                        // (decrementing it here wrapped it to 0xFE8 and the target asked
                        // for DATA_OUT forever; HP-UX 10.20's first MODE SELECT then looped
                        // on phase-mismatch interrupts, 2026-10-08)
                        if (x_blocks == 0 && d_left != 0) begin                       // MODE SELECT
                            logic [15:0] hl, po;
                            d_left <= d_left - 16'd1;
                            // page 0x0E (CD audio control): ports 0 and 1 volume
                            hl = (cdb[0] == 8'h15) ? 16'd4 : 16'd8;
                            po = hl + {8'd0, ms_bdl};
                            if (ms_i == hl - 16'd1) ms_bdl <= idata;
                            if (ms_i == po) ms_pg <= idata[5:0];
                            if (is_cd && ms_pg == 6'h0E && ms_i == po + 16'd9) vol0 <= idata;
                            if (is_cd && ms_pg == 6'h0E && ms_i == po + 16'd11) vol1 <= idata;
                            ms_i <= ms_i + 16'd1;
                        end
                        else begin b_we <= 1'b1; b_wdata <= idata; chunk <= chunk - 12'd1; end
                    end else if (!req) begin
                        if (b_we) b_addr <= b_addr + 11'd1;
                        if (x_blocks == 0 && d_left == 0 && chunk == 0 && !b_we) go_status(8'h00);
                        else if (x_blocks == 0 && d_left != 0) req <= 1'b1;
                        else if (chunk == 12'd0 && !b_we) begin
                            logic [31:0] n;
                            n = (x_blocks >= 4) ? 32'd4 : x_blocks;
                            sd_lba[dev] <= x_lba; sd_blk_cnt[dev] <= 6'(n - 1); sd_wr[dev] <= 1'b1;
                            sd_busy <= 1'b1; sd_dev <= dev;
                            x_lba <= x_lba + n; x_blocks <= x_blocks - n;
                            st <= T_STORE;
                        end else if (!b_we) req <= 1'b1;
                    end
                end
                T_STORE: if (!sd_busy && !(|sd_wr)) begin
                    if (x_blocks == 0) go_status(8'h00);
                    else begin
                        st <= T_DOUT; b_addr <= 11'd0; req <= 1'b1;
                        chunk <= (x_blocks >= 4) ? 12'd2048 : {x_blocks[2:0], 9'd0};
                    end
                end

                // the track table: 2 blocks from the window into the buffer, then
                // header bytes 0 (first track) and 1 (n) and n + 1 entries of 8
                // bytes from byte 8 into toc; then the command runs again
                T_TOC: if (!sd_busy) begin
                    sd_lba[2] <= 32'hC000_0000; sd_blk_cnt[2] <= 6'd1; sd_rd[2] <= 1'b1;
                    sd_busy <= 1'b1; sd_dev <= 2'd2; st <= T_TOCW;
                end
                T_TOCW: if (!sd_busy) begin cp_b <= 11'd0; cp_s <= 2'd0; st <= T_TOCCP; end
                T_TOCCP: case (cp_s)
                    2'd0: begin b_addr <= cp_b; cp_s <= 2'd1; end
                    2'd1: cp_s <= 2'd2;
                    2'd2: begin
                        logic last_e;
                        last_e = cp_b >= 11'd8 && cp_b[2:0] == 3'd7 && 8'((cp_b - 11'd8) >> 3) == toc_n;
                        if (cp_b == 11'd0) toc_first <= b_q;
                        else if (cp_b == 11'd1) toc_n <= b_q > 8'd99 ? 8'd99 : b_q;
                        else if (cp_b >= 11'd8) begin
                            toc_wd[8 * (7 - cp_b[2:0]) +: 8] <= b_q;
                            if (cp_b[2:0] == 3'd7) begin toc_we <= 1'b1; toc_a_r <= 7'((cp_b - 11'd8) >> 3); end
                        end
                        if ((cp_b == 11'd1 && b_q == 8'd0) || last_e) cp_s <= 2'd3;
                        else begin cp_b <= cp_b == 11'd1 ? 11'd8 : cp_b + 11'd1; cp_s <= 2'd0; end
                    end
                    default: begin toc_ok <= 1'b1; st <= T_EXEC; end
                endcase

                // PLAY AUDIO TRACK/INDEX: from the first track's start to the start
                // of the track after the last (the lead-out for the last one)
                T_TRK: begin
                    trk_s <= trk_s + 3'd1;
                    if (trk_s == 3'd1) begin
                        logic [7:0] et;
                        a_start <= toc_q[23:0];
                        et = (cdb[7] == 8'd0 || cdb[7] > toc_first + toc_n - 8'd1) ? toc_first + toc_n - 8'd1 :
                             cdb[7] < cdb[4] ? cdb[4] : cdb[7];
                        toc_a_r <= 7'(et - toc_first + 8'd1);
                    end
                    if (trk_s == 3'd3) begin
                        a_end <= toc_q[23:0]; a_play <= 1'b1;
                        skey[dev] <= 4'd0; sasc[dev] <= 8'd0; go_status(8'h00);
                    end
                end

                T_STAT: if (ack && req) begin
                    req <= 1'b0; st <= T_DONE; hold_seen <= 1'b0;
                end
                // STATUS taken: MESSAGE IN COMMAND COMPLETE (or MESSAGE OUT on ATN)
                T_DONE: if (!req) begin
                    if (atn) begin st <= T_MOUT; req <= 1'b1; phase <= P_MOUT; msg_n <= 3'd0; end
                    else begin st <= T_DISC; req <= 1'b1; phase <= P_MIN; tdata <= 8'h00; end
                end
                // COMMAND COMPLETE taken; once the initiator releases ACK, free the bus
                T_DISC: begin
                    if (ack && req) begin req <= 1'b0; hold_seen <= 1'b0; end
                    else if (!req) begin
                        if (ackhold) hold_seen <= 1'b1;
                        else if (atn) begin st <= T_MOUT; req <= 1'b1; phase <= P_MOUT; msg_n <= 3'd0; end
                        else begin st <= T_FREE; bsy <= 1'b0; end
                    end
                end
                default: st <= T_FREE;
            endcase
        end
    end
endmodule
