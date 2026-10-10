derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# Artist's pixel clock (rtl/pll_video.v, emu|pllv): sys_top.sdc's clock
# groups match only the core's main PLL, so a second PLL would be timed
# against every other domain (the scaler's input, the OSD ...). Its
# crossings are by construction: dual-clock RAMs (line buffers, LUT, the
# console's text), toggles with data held for a line, two-flop synchronisers
# of quasi-static values (rtl/artist/artist_video.sv, HP9K715.sv). The
# static configuration is the fastest clock (108.181 MHz), so this covers
# every mode it is reconfigured to.
set_clock_groups -asynchronous -group [get_clocks {emu|pllv|*|divclk}]
