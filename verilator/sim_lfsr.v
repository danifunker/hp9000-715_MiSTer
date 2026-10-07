// Simulation model of the template's free-running lcell-ring LFSR
// (rtl/lfsr.v): that ring is a hardware entropy source Verilator cannot
// settle, so the sim uses a timed shift register with the same taps.
module lfsr(output [N-1:0] rnd);
parameter N = 63;
reg [N-1:0] r = 63'h155555AAAAA5A5A;
assign rnd = r;
initial forever #7 r = {r[N-2:0], ~(r[N-1] ^ r[N-3] ^ r[N-4] ^ r[N-6] ^ r[N-10])};
endmodule
