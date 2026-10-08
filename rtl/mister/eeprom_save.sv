// The 8 KB EEPROM's image on the SD card (docs/design/system.md 6): an
// hps_io block-device slot ("SC1,EEP,..."), the pattern of the Quadra core's
// PRAM save.
//   load: when an image is mounted (size != 0): one 16-block read straight
//         into the EEPROM's host port;
//   save: when the guest has written the EEPROM and either the OSD opens
//         or ~2 s have passed since its last write (the ROM's byte-wise
//         updates coalesce into one save).
// `ready` holds the machine in reset until the first load has landed, the
// slot reports no image, or a 3 s backstop expires.
// File order is EEPROM byte order; hps_io's WIDE halfwords carry the
// earlier byte in the low half.
module eeprom_save #(
    parameter int CLK_HZ = 64_000_000
) (
    input  logic        clk,
    input  logic        rst,             // PLL not locked
    output logic        ready,
    input  logic        osd_open,
    // hps_io block device (one slot)
    input  logic        img_mounted,
    input  logic [63:0] img_size,
    output logic [31:0] sd_lba,
    output logic [5:0]  sd_blk_cnt,
    output logic        sd_rd,
    output logic        sd_wr,
    input  logic        sd_ack,
    input  logic [12:0] sd_buff_addr,
    input  logic [15:0] sd_buff_dout,
    output logic [15:0] sd_buff_din,
    input  logic        sd_buff_wr,
    // the EEPROM's host port (rtl/hp_xbus.sv)
    output logic [10:0] ee_haddr,
    output logic        ee_hwe,
    output logic [31:0] ee_hwdata,
    input  logic [31:0] ee_hrdata,
    input  logic        ee_dirty,
    output logic        ee_dirty_clr
);
    localparam int MS = CLK_HZ / 1000;
    typedef enum logic [2:0] { P_IDLE, P_LOAD, P_LOAD_DAT, P_SAVE, P_SAVE_DAT } st_e;
    st_e st;
    logic        ena;              // an image is mounted
    logic        mnt_q, osd_q, ack_q;
    logic [31:0] ms_div;
    logic        ms;
    logic [11:0] settle, backstop;
    logic        dirty_q;
    logic [15:0] upper;
    logic        half_q;

    assign sd_lba = 32'd0;
    assign sd_blk_cnt = 6'd15;              // 16 x 512 bytes
    // the host port follows the HPS's buffer address (the 8 KB is halfwords 0-4095; 32-bit word w = halfwords
    // 2w, 2w+1), except in the cycle a loaded word is written
    logic [10:0] wr_addr;
    assign ee_haddr = ee_hwe ? wr_addr : sd_buff_addr[11:1];
    always_ff @(posedge clk) half_q <= sd_buff_addr[0];
    wire [15:0] h = half_q ? ee_hrdata[15:0] : ee_hrdata[31:16];
    assign sd_buff_din = {h[7:0], h[15:8]};

    always_ff @(posedge clk) begin
        ee_hwe <= 1'b0; ee_dirty_clr <= 1'b0;
        ms <= 1'b0;
        if (ms_div == MS - 1) begin ms_div <= 0; ms <= 1'b1; end else ms_div <= ms_div + 1;
        if (rst) begin
            st <= P_IDLE; sd_rd <= 1'b0; sd_wr <= 1'b0; ena <= 1'b0; ready <= 1'b0;
            mnt_q <= 1'b0; osd_q <= 1'b0; ack_q <= 1'b0; settle <= 12'd0; backstop <= 12'd0; dirty_q <= 1'b0;
        end else begin
            mnt_q <= img_mounted; osd_q <= osd_open; ack_q <= sd_ack; dirty_q <= ee_dirty;
            if (ms && !ready) begin
                backstop <= backstop + 12'd1;
                if (backstop == 12'd3000) ready <= 1'b1;
            end
            // the settle timer restarts with every new guest write
            if (ee_dirty && !dirty_q) settle <= 12'd2000;
            else if (ms && settle > 12'd1) settle <= settle - 12'd1;

            case (st)
                P_IDLE: begin
                    if (img_mounted && !mnt_q) begin
                        ena <= img_size != 0;
                        if (img_size != 0) begin st <= P_LOAD; sd_rd <= 1'b1; end
                        else ready <= 1'b1;
                    end else if (ena && ee_dirty && ((osd_open && !osd_q) || (ms && settle == 12'd1))) begin
                        st <= P_SAVE; sd_wr <= 1'b1; ee_dirty_clr <= 1'b1; settle <= 12'd0;
                    end
                end
                P_LOAD: if (sd_ack) begin sd_rd <= 1'b0; st <= P_LOAD_DAT; end
                P_LOAD_DAT: begin
                    if (sd_buff_wr) begin
                        // bytes 2h (low half) and 2h+1 of the file
                        if (!sd_buff_addr[0]) upper <= {sd_buff_dout[7:0], sd_buff_dout[15:8]};
                        else begin
                            ee_hwe <= 1'b1; wr_addr <= sd_buff_addr[11:1];
                            ee_hwdata <= {upper, sd_buff_dout[7:0], sd_buff_dout[15:8]};
                        end
                    end
                    if (!sd_ack && ack_q) begin st <= P_IDLE; ready <= 1'b1; ee_dirty_clr <= 1'b1; end
                end
                P_SAVE: if (sd_ack) begin sd_wr <= 1'b0; st <= P_SAVE_DAT; end
                P_SAVE_DAT: if (!sd_ack && ack_q) st <= P_IDLE;
                default: st <= P_IDLE;
            endcase
        end
    end
endmodule
