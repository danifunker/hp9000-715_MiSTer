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
// CAPACITY, VERIFY, SYNCHRONIZE CACHE; the CD-ROM adds READ TOC. Anything
// else: CHECK CONDITION, ILLEGAL REQUEST. SDTR is answered with the same
// period and offset (the transfer timing is not modelled anyway).
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
    always @(posedge clk) begin           // port A: hps_io
        if (sd_buff_wr && |sd_ack) buf_mem[sd_buff_addr[9:0]] <= sd_buff_dout;
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
        T_FREE, T_MOUT, T_MIN, T_CMD, T_EXEC, T_DIN, T_DOUT, T_FETCH, T_STORE, T_STAT, T_DONE, T_DISC
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
            8'h43: begin                                         // READ TOC (format 0, MSF bit ignored)
                // header (4) + track 1 (8) + lead-out (8)
                case (i)
                    0: syn = 8'h00; 1: syn = 8'd18; 2: syn = 8'd1; 3: syn = 8'd1;
                    5: syn = 8'h14; 6: syn = 8'd1;               // track 1: data, start LBA 0
                    13: syn = 8'h14; 14: syn = 8'hAA;            // lead-out
                    16: syn = nblk[31:24]; 17: syn = nblk[23:16]; 18: syn = nblk[15:8]; 19: syn = nblk[7:0];
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
                    total = hdr + 16'd8 + ((pg == 6'h3F) ? 16'd72 : (pg == 6'h01 || pg == 6'h08) ? 16'd12 :
                                           (pg == 6'h03 || pg == 6'h04) ? 16'd24 : 16'd0);
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
                        else              begin pcode = 8'h08; po = pi - 60; end
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
                        default: ;
                    endcase
                end
            end
            default: ;
        endcase
    end

    // the MODE SENSE pages served
    function automatic logic page_ok(input logic [5:0] pg);
        return pg == 6'h00 || pg == 6'h01 || pg == 6'h03 || pg == 6'h04 || pg == 6'h08 || pg == 6'h3F;
    endfunction

    // how many bytes a synthesised response has before the allocation length
    function automatic logic [15:0] resp_len(input logic [7:0] op, input logic [5:0] pg);
        case (op)
            8'h12: return 16'd36;
            8'h03: return 16'd18;
            8'h25: return 16'd8;
            8'h43: return 16'd20;
            8'h1A, 8'h5A: return ((op == 8'h5A) ? 16'd16 : 16'd12) +
                                 ((pg == 6'h3F) ? 16'd72 : (pg == 6'h01 || pg == 6'h08) ? 16'd12 :
                                  (pg == 6'h03 || pg == 6'h04) ? 16'd24 : 16'd0);
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
        sd_was_ack <= |sd_ack;
        if (rst || brst) begin
            st <= T_FREE; bsy <= 1'b0; req <= 1'b0; sd_rd <= 3'd0; sd_wr <= 3'd0; sd_busy <= 1'b0;
            for (int d = 0; d < 3; d++) begin skey[d] <= 4'd0; sasc[d] <= 8'd0; end
            pending <= 1'b0;
        end else begin
            // block device handshake: drop rd/wr when ack rises, done when it falls
            if (|(sd_ack & (sd_rd | sd_wr))) begin sd_rd <= 3'd0; sd_wr <= 3'd0; end
            if (sd_busy && sd_was_ack && !(|sd_ack) && !(|sd_rd) && !(|sd_wr)) sd_busy <= 1'b0;

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
                    d_idx <= 16'd0;
                    if (lun != 3'd0 && op != 8'h12 && op != 8'h03) begin
                        skey[dev] <= 4'h5; sasc[dev] <= 8'h25; go_status(8'h02);
                    end else case (op)
                        8'h00, 8'h01, 8'h04, 8'h0B, 8'h16, 8'h17, 8'h1B, 8'h1D, 8'h1E, 8'h2B, 8'h2F, 8'h35:
                            begin skey[dev] <= 4'd0; sasc[dev] <= 8'd0; go_status(8'h00); end
                        8'h12, 8'h03, 8'h25, 8'h43, 8'h1A, 8'h5A: begin
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
                                if (op == 8'h43 && !is_cd) begin skey[dev] <= 4'h5; sasc[dev] <= 8'h20; go_status(8'h02); end
                                else begin
                                    d_left <= (alloc < rl) ? alloc : rl;
                                    din_synth <= 1'b1;
                                    if (op != 8'h03) begin skey[dev] <= 4'd0; sasc[dev] <= 8'd0; end
                                    if ((alloc < rl ? alloc : rl) == 16'd0) go_status(8'h00);
                                    else begin st <= T_DIN; req <= 1'b0; phase <= P_DIN; pending <= 1'b1; end
                                end
                            end
                        end
                        8'h08, 8'h28: begin                                   // READ
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
                        if (x_blocks == 0 && d_left != 0) d_left <= d_left - 16'd1;      // MODE SELECT
                        else begin b_we <= 1'b1; b_wdata <= idata; end
                        chunk <= chunk - 12'd1;
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
