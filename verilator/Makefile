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

# Core RTL under simulation. Stage 0: the template demo core paints the
# video window until the machine exists (docs/STUBS.md S-001).
V_SRC = \
	sim.v \
	$(RTL)/mycore.v \
	sim_lfsr.v

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
