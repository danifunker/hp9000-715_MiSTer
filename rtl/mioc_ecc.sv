// The MIOC's ECC code (docs/design/system.md 3.2; HW 1.6): one check byte
// per 64-bit doubleword, SEC-DED, the code tools/rom/hwmap_ecc.py finds
// (seed 715): ECC(d) = 8'h33 ^ XOR of col[j] over the set bits j of d, j = 0
// the MSB. It satisfies every check in the ROM: ECC(0) = 0x33, ECC(~0) =
// 0xCC, ECC(0x01234567FEDCBA98) = 0x55, odd-weight columns, none equal to
// 0xD0 or 0x0D, and the triple data error 0x00000D00 (upper word) of
// mem_ecc_multibit stays uncorrectable instead of miscorrecting.
package mioc_ecc;
    // ecc[7-k] = 33h[7-k] ^ ^(d & ECC_MASK[k]) (k = 0 is the check byte's MSB)
    localparam logic [63:0] ECC_MASK [8] = '{
        64'hb0c4ab7479ca8c6f, 64'hfd87586dcb457098, 64'h180d70d8649fef80, 64'h9bb462b33f187052,
        64'h47408caa1ec846ec, 64'he1d3c8037a732d43, 64'he97f07d191e630a9, 64'h7ee95df5e3aac7dc};
    localparam logic [7:0] ECC_COL [64] = '{
        8'hd6, 8'h4f, 8'hc7, 8'hf1, 8'h73, 8'h49, 8'h19, 8'h5e,
        8'hd5, 8'h8f, 8'h13, 8'h16, 8'h23, 8'hf2, 8'h46, 8'h67,
        8'h8c, 8'h75, 8'hb0, 8'h61, 8'hcd, 8'h0b, 8'h92, 8'h83,
        8'h3b, 8'he3, 8'hd9, 8'hb3, 8'h68, 8'hc1, 8'h1c, 8'h57,
        8'h43, 8'he5, 8'hb5, 8'h9e, 8'hdc, 8'h38, 8'h5d, 8'hd3,
        8'hab, 8'hce, 8'h07, 8'h34, 8'hb9, 8'h62, 8'ha7, 8'h64,
        8'ha1, 8'h79, 8'h76, 8'h52, 8'ha4, 8'had, 8'h29, 8'h25,
        8'h6b, 8'h9d, 8'h8a, 8'h51, 8'hcb, 8'h89, 8'h94, 8'h86};

    function automatic logic [7:0] ecc_of(input logic [63:0] d);
        logic [7:0] e;
        for (int k = 0; k < 8; k++) e[7-k] = ^(d & ECC_MASK[k]);
        return e ^ 8'h33;
    endfunction

    // what a read with ECC checking makes of a doubleword stored with check
    // byte `chk` and data `d`: 0 = clean, 1 = check-bit error (data intact),
    // 2 = data bit `bit` (0 = MSB) wrong, 3 = uncorrectable
    function automatic logic [7:0] ecc_class(input logic [7:0] syn);
        logic [1:0] cls;
        logic [5:0] bitn;
        cls = 2'd3; bitn = 6'd0;
        if (syn == 8'd0) cls = 2'd0;
        else if ((syn & (syn - 8'd1)) == 8'd0) cls = 2'd1;   // one bit set
        else
            for (int j = 0; j < 64; j++)
                if (syn == ECC_COL[j]) begin cls = 2'd2; bitn = j[5:0]; end
        return {bitn, cls};
    endfunction
endpackage
