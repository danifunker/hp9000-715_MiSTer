# HP 9000/715 -- Verilator GUI simulation (same setup as the other cores'
# verilator directories: ImGui + SDL2, `make && ./obj_dir/Vemu`).
V = verilator

TOP = --top-module emu
RTL = ../rtl
V_INC = +incdir+$(RTL)
V_DEFINE = +define+SIMULATION=1 \
	-CFLAGS "-I../sim/imgui -I../sim/ -g" \
	--timescale-override 1ps/1ps -Wno-TIMESCALEMOD -I$(RTL)
V_DEFINE += -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-IMPLICIT \
	-Wno-PINMISSING -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
	-Wno-UNSIGNED -Wno-CMPCONST -Wno-LATCH -Wno-UNDRIVEN -Wno-MISINDENT \
	-Wno-COMBDLY -Wno-INITIALDLY -Wno-SYNCASYNCNET -Wno-BLKLOOPINIT \
	-Wno-MULTIDRIVEN -Wno-GENUNNAMED -Wno-DECLFILENAME
V_DEFINE += --timing -sv

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S), Linux)
	LIBS += -lGL -ldl `sdl2-config --libs`
	CXXFLAGS += `sdl2-config --cflags` -Iimgui
	CFLAGS = $(CXXFLAGS)
endif
ifeq ($(UNAME_S), Darwin)
	LIBS += -framework OpenGL `sdl2-config --libs` -L/opt/homebrew/lib -llz4 -lzstd -lz
	CXXFLAGS += `sdl2-config --cflags` -I/opt/homebrew/include -Iimgui -DGL_SILENCE_DEPRECATION
	CFLAGS = $(CXXFLAGS)
endif

CFLAGS += -Iimgui
LDFLAGS = $(LIBS)
EXE = ./obj_dir/Vemu
V_OPT = --x-assign fast --x-initial fast --noassert --unroll-count 256

# Core RTL under simulation: the machine (rtl/hp715.sv) inside sim.v.
# CPU_RTL is defined below with the CPU benches.
MACHINE_RTL = $(RTL)/mioc_ecc.sv $(RTL)/mioc.sv $(RTL)/hp_xbus.sv $(RTL)/lasi/lasi_uart.sv \
	$(RTL)/lasi/lasi_ps2.sv $(RTL)/lasi/ps2_dev.sv $(RTL)/lasi/lasi.sv $(RTL)/wax_stub.sv \
	$(RTL)/scsi/ncr53c710.sv $(RTL)/scsi/scsi_targets.sv $(RTL)/artist/artist.sv \
	$(RTL)/rom_loader.sv $(RTL)/hp715.sv
V_SRC = $(CPU_PIPE_RTL) $(MACHINE_RTL) sim.v

C_SRC = \
	sim_main.cpp \
	sim/sim_console.cpp sim/sim_video.cpp sim/sim_input.cpp sim/sim_clock.cpp \
	sim/sim_audio.cpp \
	sim/imgui/imgui_impl_sdl.cpp sim/imgui/imgui_impl_opengl2.cpp \
	sim/imgui/imgui_draw.cpp sim/imgui/imgui_widgets.cpp \
	sim/imgui/imgui_tables.cpp sim/imgui/imgui.cpp

VOUT = obj_dir/Vemu.cpp

all: $(EXE)

$(VOUT): $(V_SRC) $(C_SRC) Makefile
	$V -cc $(V_OPT) -LDFLAGS "$(LDFLAGS)" -exe --Mdir ./obj_dir \
		$(V_DEFINE) $(V_INC) $(TOP) -CFLAGS "$(CFLAGS)" $(V_SRC) $(C_SRC)
	@touch $(VOUT)

$(EXE): $(VOUT)
	@# Vemu.mk does not track our C sources: evict stale objects first
	@for f in $(C_SRC); do o=obj_dir/$$(basename $${f%.*}).o; \
		[ -e $$o ] && [ $$f -nt $$o ] && rm -f $$o obj_dir/Vemu || true; done
	$(MAKE) -C obj_dir -f Vemu.mk

# Headless smoke test: three frames and a screenshot of frame 2
smoke: $(EXE)
	$(EXE) --headless --frames 3 --screenshot 2

clean:
	rm -rf obj_dir obj_dir_tb screenshot_*.png

.PHONY: all smoke clean

# ---------------------------------------------------------------------------
# CPU unit benches: each replays vectors derived from the CPU test suites'
# QEMU reference logs (tests/cpu/unit_vectors.py). Need `make -C ../tests/cpu`
# (for build/gen_*.json); the logs are committed in tests/cpu/ref/qemu.
CPUT = ../tests/cpu
TB_V = $(V) --cc --exe --build -j 0 -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
	--Mdir obj_dir_tb -O3

obj_dir_tb/alu_vectors.txt: $(CPUT)/unit_vectors.py $(CPUT)/model.py $(CPUT)/ref/qemu/alu1.log $(CPUT)/ref/qemu/alu2.log
	@mkdir -p obj_dir_tb
	$(MAKE) -C $(CPUT) build/gen_alu1.json build/gen_alu2.json >/dev/null
	python3 $(CPUT)/unit_vectors.py alu $(CPUT)/ref/qemu/alu1.log $(CPUT)/ref/qemu/alu2.log -o $@

obj_dir_tb/shift_vectors.txt: $(CPUT)/unit_vectors.py $(CPUT)/model.py $(CPUT)/ref/qemu/shift.log
	@mkdir -p obj_dir_tb
	$(MAKE) -C $(CPUT) build/gen_shift.json >/dev/null
	python3 $(CPUT)/unit_vectors.py shift $(CPUT)/ref/qemu/shift.log -o $@

tb_alu: obj_dir_tb/alu_vectors.txt
	$(TB_V) --top-module pa_alu -o tb_alu $(RTL)/cpu/pa_alu.sv tb/tb_alu.cpp
	./obj_dir_tb/tb_alu obj_dir_tb/alu_vectors.txt

tb_shift: obj_dir_tb/shift_vectors.txt
	$(TB_V) --top-module pa_shift -o tb_shift $(RTL)/cpu/pa_shift.sv tb/tb_shift.cpp
	./obj_dir_tb/tb_shift obj_dir_tb/shift_vectors.txt

.PHONY: tb_alu tb_shift

obj_dir_tb/fp_vectors.txt: $(CPUT)/unit_vectors.py $(CPUT)/ref/qemu/fp.log
	@mkdir -p obj_dir_tb
	$(MAKE) -C $(CPUT) build/gen_fp.json >/dev/null
	python3 $(CPUT)/unit_vectors.py fp $(CPUT)/ref/qemu/fp.log -o $@

# the same vectors (fp) plus the fpedge suite's, with model.py's expectations
# (ERS s.7.3: results, flags and the unimplemented exception)
obj_dir_tb/fpmodel_vectors.txt: $(CPUT)/unit_vectors.py $(CPUT)/model.py $(CPUT)/gen_tests.py
	@mkdir -p obj_dir_tb
	$(MAKE) -C $(CPUT) build/gen_fp.json build/gen_fpedge.json >/dev/null
	python3 $(CPUT)/unit_vectors.py fpmodel -o $@

tb_fpu: obj_dir_tb/fp_vectors.txt obj_dir_tb/fpmodel_vectors.txt
	$(TB_V) --top-module pa_fpu -o tb_fpu $(RTL)/cpu/pa_pkg.sv $(RTL)/cpu/pa_fpu.sv tb/tb_fpu.cpp
	./obj_dir_tb/tb_fpu obj_dir_tb/fp_vectors.txt
	./obj_dir_tb/tb_fpu obj_dir_tb/fpmodel_vectors.txt

.PHONY: tb_fpu

obj_dir_tb/max1_vectors.txt: $(CPUT)/unit_vectors.py $(CPUT)/model.py
	@mkdir -p obj_dir_tb
	$(MAKE) -C $(CPUT) build/gen_max1.json >/dev/null
	python3 $(CPUT)/unit_vectors.py max1 -o $@

tb_max1: obj_dir_tb/max1_vectors.txt
	$(TB_V) --top-module pa_max1 -o tb_max1 $(RTL)/cpu/pa_max1.sv tb/tb_max1.cpp
	./obj_dir_tb/tb_max1 obj_dir_tb/max1_vectors.txt

.PHONY: tb_max1

obj_dir_tb/mem_vectors.txt: $(CPUT)/unit_vectors.py $(CPUT)/ref/qemu/mem.log
	@mkdir -p obj_dir_tb
	$(MAKE) -C $(CPUT) build/gen_mem.json >/dev/null
	python3 $(CPUT)/unit_vectors.py mem $(CPUT)/ref/qemu/mem.log -o $@

tb_ldst: obj_dir_tb/mem_vectors.txt
	$(TB_V) --top-module pa_ldst -o tb_ldst $(RTL)/cpu/pa_ldst.sv tb/tb_ldst.cpp
	./obj_dir_tb/tb_ldst obj_dir_tb/mem_vectors.txt

.PHONY: tb_ldst

# Artist (rtl/artist/artist.sv) against a reference model of its drawing
# semantics, with a VRAM model of random latency (tb/tb_artist.cpp)
tb_artist:
	$(TB_V) +define+SIMULATION=1 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module artist -o tb_artist \
		$(RTL)/artist/artist.sv tb/tb_artist.cpp
	./obj_dir_tb/tb_artist

.PHONY: tb_artist

# ---------------------------------------------------------------------------
# CPU test ROMs on the RTL core (verilator/cputest): `make cputest SUITE=alu1`
# runs tests/cpu/build/<suite>.bin and checks the log with compare.py.
# CORE=seq runs the sequential bring-up core, CORE=pipe (default) the
# pipelined pa_cpu; the binaries live in obj_dir_ct/$(CORE).
CPU_PIPE_RTL = $(RTL)/cpu/pa_pkg.sv $(RTL)/cpu/pa_decode.sv $(RTL)/cpu/pa_alu.sv $(RTL)/cpu/pa_shift.sv \
	$(RTL)/cpu/pa_max1.sv $(RTL)/cpu/pa_ldst.sv $(RTL)/cpu/pa_regfile.sv $(RTL)/cpu/pa_cr16.sv \
	$(RTL)/cpu/pa_biu.sv $(RTL)/cpu/pa_fetch.sv $(RTL)/cpu/pa_core.sv $(RTL)/cpu/pa_cpu.sv \
	$(RTL)/cpu/pa_cache_ram.sv $(RTL)/cpu/pa_dcache.sv $(RTL)/cpu/pa_icache.sv $(RTL)/cpu/pa_tlb.sv \
	$(RTL)/cpu/pa_fpu.sv $(RTL)/cpu/pa_fpunit.sv
CPU_RTL = $(CPU_PIPE_RTL) $(RTL)/cpu/pa_core_seq.sv
CT_RTL = $(CPU_RTL) cputest/cputest_top.sv
CORE ?= pipe
CT_PIPE_seq = 0
CT_PIPE_pipe = 1
CT_EXE = obj_dir_ct/$(CORE)/Vcputest_top
SUITE ?= alu1

obj_dir_ct/%/Vcputest_top: $(CT_RTL) cputest/tb_cputest.cpp
	$(V) --cc --exe --build -j 0 -O3 -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
		-Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --x-assign fast --x-initial fast \
		-GPIPE=$(CT_PIPE_$*) \
		--Mdir obj_dir_ct/$* --top-module cputest_top -o Vcputest_top $(CT_RTL) $(abspath cputest/tb_cputest.cpp)

obj_dir_ct/%.hex: $(CPUT)/build/%.bin
	@mkdir -p obj_dir_ct
	python3 -c "import sys;d=open(sys.argv[1],'rb').read();d+=bytes(-len(d)%8);open(sys.argv[2],'w').write('\n'.join(d[i:i+8].hex() for i in range(0,len(d),8))+'\n')" $< $@

cputest: $(CT_EXE) obj_dir_ct/$(SUITE).hex
	$(CT_EXE) +rom=obj_dir_ct/$(SUITE).hex --log obj_dir_ct/$(SUITE).log
	python3 $(CPUT)/compare.py $(SUITE) obj_dir_ct/$(SUITE).log $(if $(filter alu1 alu2 shift max1,$(SUITE)),--model,--ref $(CPUT)/ref/qemu/$(SUITE).log)

.PHONY: cputest

# ---------------------------------------------------------------------------
# Lockstep co-simulation of the sequential and the pipelined core on one
# ROM: `make cosim SUITE=alu1` (tests/run-cosim.sh runs every suite).
COSIM_EXE = obj_dir_cosim/Vcosim_top
$(COSIM_EXE): $(CT_RTL) cosim/cosim_top.sv cosim/tb_cosim.cpp
	$(V) --cc --exe --build -j 0 -O3 -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
		-Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --x-assign fast --x-initial fast \
		--Mdir obj_dir_cosim --top-module cosim_top -o Vcosim_top $(CT_RTL) cosim/cosim_top.sv \
		$(abspath cosim/tb_cosim.cpp)

cosim: $(COSIM_EXE) obj_dir_ct/$(SUITE).hex
	$(COSIM_EXE) +rom=obj_dir_ct/$(SUITE).hex

.PHONY: cosim

# ---------------------------------------------------------------------------
# The whole machine on HP's boot ROM, headless (verilator/romsim):
# `make romsim` builds obj_dir_rom/Vemu; tests/run-rom.sh runs it.
# ROMSIM_DIR: build a second copy elsewhere without disturbing a running
# simulation (checkpoints only restore into the build that made them);
# ROMSIM_OPT: the C++ optimisation (-Os measured 8 % faster than -O2)
# ROMSIM_SDRAM=1: system RAM is rtl/mister/sdram64.sv on a chip model
# (sim_sdram_chip.sv), as on the board, instead of the ideal array
ROMSIM_DIR ?= obj_dir_rom
ROMSIM_OPT ?= -Os
ROMSIM_SDRAM ?= 0
ifeq ($(ROMSIM_SDRAM),1)
ROMSIM_EXTRA = +define+SDRAM_MODEL=1 $(RTL)/mister/sdram64.sv sim_sdram_chip.sv
endif
ROMSIM_EXE = $(ROMSIM_DIR)/Vemu
$(ROMSIM_EXE): $(CPU_PIPE_RTL) $(MACHINE_RTL) sim.v romsim/tb_rom.cpp $(RTL)/mister/sdram64.sv sim_sdram_chip.sv
	$(V) --cc --exe --build -j 0 -O3 -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
		-Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD --x-assign fast --x-initial fast \
		+define+SIMULATION=1 --savable --Mdir $(ROMSIM_DIR) --top-module emu -o Vemu \
		-MAKEFLAGS "OPT_FAST='$(ROMSIM_OPT)'" $(ROMSIM_EXTRA) $(CPU_PIPE_RTL) $(MACHINE_RTL) sim.v \
		$(abspath romsim/tb_rom.cpp)

romsim: $(ROMSIM_EXE)

.PHONY: romsim

# The on-screen serial terminal (rtl/mister/serial_term.sv): types console
# text into it and writes one frame, obj_dir_term/term.ppm
tb_term: ../rtl/mister/serial_term.sv tb/tb_term.sv tb/tb_term.cpp
	$(V) --cc --exe --build -j 0 -Wno-fatal --Mdir obj_dir_term --top-module tb_term -o Vtb_term \
		../rtl/mister/serial_term.sv tb/tb_term.sv $(abspath tb/tb_term.cpp)
	cd obj_dir_term && ./Vtb_term
.PHONY: tb_term

# ---------------------------------------------------------------------------
# Board-side units: `make tb_sdram64` runs rtl/mister/sdram64.sv against a
# behavioural SDRAM (tb/tb_sdram64.sv).
tb_sdram64: tb/tb_sdram64.sv $(RTL)/mister/sdram64.sv
	$(V) --binary --timing -j 0 -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-WIDTHEXPAND \
		-Wno-WIDTHTRUNC -Wno-TIMESCALEMOD --Mdir obj_dir_tb/sdram64 --top-module tb_sdram64 -o tb_sdram64 \
		$(RTL)/mister/sdram64.sv tb/tb_sdram64.sv
	./obj_dir_tb/sdram64/tb_sdram64

.PHONY: tb_sdram64
