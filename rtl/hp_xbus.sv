// LASI's external 8-bit bus apart from the boot ROM (docs/design/system.md
// 6; HW 5; FW 5.1): the 8 KB EEPROM at F00C_0000 (mirrored to F00D_FFFF),
// the front-panel LED latch at F00E_0000-F00E_FFFF and the board-ID word in
// F00F_0000-F00F_FFFF. F004_0000-F00B_FFFF has nothing fitted and reads
// 0xFF. One GSC word per access, byte lanes big-endian (be[3] = byte 0).
//
// The EEPROM is a true dual-port RAM (2048 x 32 with byte enables): port A
// is the CPU's (a byte write reads back at once, so the ROM's data polling
// succeeds on its first read), port B the host's (load at start-up, save to
// the SD card); `ee_dirty` is set by every CPU write and cleared by the host.
module hp_xbus (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [3:0]  cfg_model,      // board-ID nibble: 7 = 715/64, B = /80, F = /100
    // GSC slave
    input  logic        req,
    input  logic        we,
    input  logic [31:0] addr,
    input  logic [3:0]  be,
    input  logic [31:0] wdata,
    output logic        ack,
    output logic [31:0] rdata,
    // front-panel LEDs (the latch, active low)
    output logic [7:0]  led_latch,
    output logic        led_strobe,     // a write to the latch (chassis code)
    // EEPROM host port (word address, big-endian bytes in the word)
    input  logic [10:0] ee_haddr,
    input  logic        ee_hwe,
    input  logic [31:0] ee_hwdata,
    output logic [31:0] ee_hrdata,
    output logic        ee_dirty,
    input  logic        ee_dirty_clr
);
    logic [31:0] ee [2048];
    logic [31:0] ee_q;

    wire is_ee  = addr[19:17] == 3'b110;     // F00C_0000-F00D_FFFF
    wire is_led = addr[19:16] == 4'hE;
    wire is_id  = addr[19:16] == 4'hF;

    // port A: the CPU
    always_ff @(posedge clk) begin
        if (req && we && is_ee)
            for (int b = 0; b < 4; b++) if (be[b]) ee[addr[12:2]][8*b +: 8] <= wdata[8*b +: 8];
        ee_q <= ee[addr[12:2]];
    end
    // port B: the host
    always_ff @(posedge clk) begin
        if (ee_hwe) ee[ee_haddr] <= ee_hwdata;
        ee_hrdata <= ee[ee_haddr];
    end

    logic       pend;
    logic [1:0] kind;           // 0 EEPROM, 1 LED, 2 ID, 3 empty
    always_ff @(posedge clk) begin
        ack <= 1'b0; led_strobe <= 1'b0;
        if (ee_dirty_clr) ee_dirty <= 1'b0;
        if (!rst_n) begin
            pend <= 1'b0; led_latch <= 8'hFF;
        end else begin
            if (req) begin
                pend <= 1'b1;
                kind <= is_ee ? 2'd0 : is_led ? 2'd1 : is_id ? 2'd2 : 2'd3;
                if (we && is_ee) ee_dirty <= 1'b1;
                if (we && is_led) begin
                    // the byte on the lane written (the ROM writes 0xF00EFFFF, HP-UX 0xF00E0000)
                    for (int b = 0; b < 4; b++) if (be[b]) led_latch <= wdata[8*b +: 8];
                    led_strobe <= 1'b1;
                end
            end
            if (pend) begin               // EEPROM data is ready one cycle after req
                pend <= 1'b0; ack <= 1'b1;
                case (kind)
                    2'd0: rdata <= ee_q;
                    2'd1: rdata <= {4{led_latch}};
                    2'd2: rdata <= {24'd0, cfg_model, 4'd0};
                    default: rdata <= 32'hFFFF_FFFF;
                endcase
            end
        end
    end

`ifdef SIMULATION
    // +eeprom=<hex file of 2048 32-bit words> preloads the EEPROM; without
    // it the part is blank (all ones), as a new one is
    initial begin
        string f;
        for (int i = 0; i < 2048; i++) ee[i] = 32'hFFFF_FFFF;
        if ($value$plusargs("eeprom=%s", f)) $readmemh(f, ee);
    end
    // +eeprom_out=<file>: the EEPROM's contents when the simulation ends
    final begin
        string f;
        if ($value$plusargs("eeprom_out=%s", f)) $writememh(f, ee);
    end
`endif
endmodule
