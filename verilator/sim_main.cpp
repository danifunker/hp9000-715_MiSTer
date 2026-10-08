// HP 9000/715 -- Verilator simulation main
//
// The MiSTer cores' simulator shell (ImGui + SDL2, the sim/ helpers copied
// from ../MacQuadra800_MiSTer/verilator/sim): a control window with
// run/pause/step, a machine panel with the CPU debug taps, the serial
// console, the debug log and the emulated screen. Headless runs drive the
// same loop without SDL for scripted tests.
//
//   make && ./obj_dir/Vemu [--rom FILE] [+eeprom=HEX]     GUI
//   ./obj_dir/Vemu --headless --frames 3 --screenshot 2
//   ./obj_dir/Vemu --headless --max-cycles 5000000 --serial-log out.txt
//
// The boot ROM (default ../roms/hp715_pdc_rev1.6.bin) is loaded through the
// ioctl download at start-up, as hps_io does on the board. For long scripted
// ROM runs use the headless verilator/romsim instead (faster, checkpoints).

#include <verilated.h>
#include "Vemu.h"

#include "imgui.h"
#include <stdio.h>
#include <string.h>
#include <string>
#include <vector>
#include <algorithm>
#include <SDL.h>
#include <SDL_opengl.h>

#include "sim_console.h"
#include "sim_video.h"
#include "sim_input.h"
#include "sim_clock.h"
#include "sim_audio.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "sim/stb_image_write.h"

// Top-level ports are public members of Vemu itself; internals (for
// deeper debug views later) would need "Vemu___024root.h" and top->rootp.
#define VERTOPINTERN top

// Simulation control
// ------------------
static int  initialReset = 48;
static bool run_enable = true;
static int  batchSize = 250000;
static bool single_step = false;
static bool multi_step = false;
static int  multi_step_amount = 1024;

// Core options (stand-ins for the OSD's status word; see sim.v)
static int opt_model = 0;          // 0 = 715/64, 1 = /80, 2 = /100
static int opt_ram_lg = 3;         // 2^n MB
static int opt_turbo = 0;          // CR16 speed-up (0 = real rate)
static bool opt_toc = false, opt_softoff = false;

// Boot ROM download state
static std::vector<unsigned char> rom_img;
static size_t rom_pos = 0;
static int rom_phase = 0;          // 0 waiting, 1 downloading, 2 done
static const char* rom_path = "../roms/hp715_pdc_rev1.6.bin";

// Serial input queue (typed into the console window)
static std::string serial_in;
static unsigned long long serial_next = 0;

// Headless / scripted runs
static bool headless = false;
static int  stop_at_frame = -1;
static unsigned long long max_cycles = 0;
static std::vector<int> screenshot_frames;
static FILE* serial_log = nullptr;

// Verilog module
// --------------
Vemu* top = nullptr;
vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

SimClock clk_sys(1);
SimAudio audio(50000000, false);
DebugConsole console;

const char* windowTitle = "HP 9000/715 sim";
const char* windowTitle_Control = "Simulation control";
const char* windowTitle_Video = "Video output";
static bool showDebugLog = true;

SimVideo video(1024, 768, 0);
static float vga_scale = 1.0f;
SimInput input(12, console);

// Serial console (LASI UART TX tap)
// ---------------------------------
static std::string serial_text;
static bool serial_scroll = true;
static unsigned long long retired = 0;

static void serial_byte(uint8_t b) {
	if (b == '\r') return;
	serial_text.push_back((char)b);
	if (serial_text.size() > (1u << 20)) serial_text.erase(0, serial_text.size() - (1u << 19));
	if (serial_log) { fputc(b, serial_log); fflush(serial_log); }
	if (headless) { fputc(b, stdout); fflush(stdout); }
}

static void save_screenshot(int frame) {
	char filename[64];
	snprintf(filename, sizeof(filename), "screenshot_f%d.png", frame);
	stbi_write_png(filename, output_width, output_height, 4, output_ptr, output_width * 4);
	printf("Saved %s (%dx%d)\n", filename, output_width, output_height);
}

static int verilate() {
	if (Verilated::gotFinish()) return 0;
	if (main_time < (vluint64_t)initialReset) VERTOPINTERN->reset = 1;
	if (main_time == (vluint64_t)initialReset) VERTOPINTERN->reset = 0;

	clk_sys.Tick();
	VERTOPINTERN->clk_sys = clk_sys.clk;
	VERTOPINTERN->sim_status = (opt_model & 3) | ((opt_ram_lg & 15) << 2) | ((opt_turbo & 15) << 6);
	VERTOPINTERN->toc_button = opt_toc;
	VERTOPINTERN->soft_power_off = opt_softoff;

	// the ROM download, one 16-bit write every other clock, during reset
	if (clk_sys.IsRising()) {
		VERTOPINTERN->ioctl_wr = 0;
		VERTOPINTERN->uart_rx_strobe = 0;
		if (rom_phase == 0 && main_time > 8 && !rom_img.empty()) { rom_phase = 1; VERTOPINTERN->ioctl_download = 1; }
		else if (rom_phase == 1) {
			if (rom_pos >= rom_img.size()) { rom_phase = 2; VERTOPINTERN->ioctl_download = 0; }
			else if (main_time & 2) {
				VERTOPINTERN->ioctl_addr = rom_pos;
				VERTOPINTERN->ioctl_dout = rom_img[rom_pos] | (rom_img[rom_pos + 1] << 8);
				VERTOPINTERN->ioctl_wr = 1;
				rom_pos += 2;
			}
		} else if (!serial_in.empty() && main_time >= serial_next && !VERTOPINTERN->uart_rx_full) {
			VERTOPINTERN->uart_rx_strobe = 1;
			VERTOPINTERN->uart_rx_byte = serial_in[0];
			serial_in.erase(0, 1);
			serial_next = main_time + 40000;
		}
	}

	if (clk_sys.clk != clk_sys.old) {
		if (clk_sys.clk) input.BeforeEval();
		top->eval();
		if (clk_sys.clk && !VERTOPINTERN->reset) {
			if (VERTOPINTERN->uart_tx_strobe) serial_byte(VERTOPINTERN->uart_tx_byte);
			if (VERTOPINTERN->debug_retire) retired++;
		}
	}

	if (clk_sys.IsRising() && !headless)
		audio.Clock(VERTOPINTERN->AUDIO_L, VERTOPINTERN->AUDIO_R);

	if (clk_sys.IsRising() && VERTOPINTERN->CE_PIXEL) {
		uint32_t colour = 0xFF000000 | (VERTOPINTERN->VGA_B << 16) |
		                  (VERTOPINTERN->VGA_G << 8) | VERTOPINTERN->VGA_R;
		video.Clock(VERTOPINTERN->VGA_HB, VERTOPINTERN->VGA_VB,
		            VERTOPINTERN->VGA_HS, VERTOPINTERN->VGA_VS, colour);
	}

	main_time++;
	return 1;
}

static void reset_core() {
	VERTOPINTERN->reset = 1;
	for (int i = 0; i < 8; i++) verilate();
	VERTOPINTERN->reset = 0;
	retired = 0;
}

static void usage() {
	printf("usage: Vemu [--headless] [--frames N] [--max-cycles N]\n"
	       "            [--screenshot N[,N...]] [--serial-log FILE]\n");
}

int main(int argc, char** argv, char** env) {
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--headless") || !strcmp(argv[i], "--no-gui")) {
			headless = true;
		} else if (!strcmp(argv[i], "--frames") && i + 1 < argc) {
			stop_at_frame = atoi(argv[++i]);
		} else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc) {
			max_cycles = strtoull(argv[++i], nullptr, 0);
		} else if (!strcmp(argv[i], "--screenshot") && i + 1 < argc) {
			char* s = argv[++i];
			for (char* t = strtok(s, ","); t; t = strtok(nullptr, ","))
				screenshot_frames.push_back(atoi(t));
		} else if (!strcmp(argv[i], "--serial-log") && i + 1 < argc) {
			serial_log = fopen(argv[++i], "w");
		} else if (!strcmp(argv[i], "--rom") && i + 1 < argc) {
			rom_path = argv[++i];
		} else if (!strcmp(argv[i], "--help")) {
			usage();
			return 0;
		} else if (argv[i][0] != '+') {   // +plusargs belong to the Verilog
			usage();
			return 1;
		}
	}

	top = new Vemu();
	Verilated::commandArgs(argc, argv);
	{
		FILE* rf = fopen(rom_path, "rb");
		if (rf) {
			int c;
			while ((c = fgetc(rf)) != EOF) rom_img.push_back((unsigned char)c);
			fclose(rf);
			if (rom_img.size() & 1) rom_img.push_back(0);
		} else fprintf(stderr, "no boot ROM at %s (roms/README.md)\n", rom_path);
	}
	VERTOPINTERN->sim_trace = 0;
	VERTOPINTERN->uart_rx_strobe = 0;
	VERTOPINTERN->toc_button = 0;
	VERTOPINTERN->soft_power_off = 0;

	VERTOPINTERN->clk_sys = 0;
	VERTOPINTERN->reset = 1;
	VERTOPINTERN->ps2_key = 0;
	VERTOPINTERN->ps2_mouse = 0;
	VERTOPINTERN->ioctl_download = 0;
	VERTOPINTERN->ioctl_wr = 0;
	VERTOPINTERN->ioctl_addr = 0;
	VERTOPINTERN->ioctl_dout = 0;
	VERTOPINTERN->ioctl_index = 0;
	input.ps2_key = &VERTOPINTERN->ps2_key;
	top->eval();

	input.Initialise();
	if (!headless) {
		audio.Initialise();
		if (video.Initialise(windowTitle) == 1) return 1;
	} else {
		// headless: no SDL window, but render into the buffer for screenshots
		extern unsigned int output_size;
		output_width = video.output_width;
		output_height = video.output_height;
		output_size = output_width * output_height * 4;
		output_ptr = (uint32_t*)calloc(1, output_size);
	}

	bool done = false;
	while (!done) {
		if (!headless) {
			SDL_Event event;
			while (SDL_PollEvent(&event)) {
				ImGui_ImplSDL2_ProcessEvent(&event);
				if (event.type == SDL_QUIT) done = true;
			}
			video.StartFrame();
			input.Read();
			ImGui::NewFrame();

			// Control
			ImGui::Begin(windowTitle_Control);
			ImGui::SetWindowPos(windowTitle_Control, ImVec2(0, 0), ImGuiCond_Once);
			ImGui::SetWindowSize(windowTitle_Control, ImVec2(500, 200), ImGuiCond_Once);
			if (ImGui::Button("Reset simulation")) main_time = 0;
			ImGui::SameLine();
			if (ImGui::Button("Reset core")) reset_core();
			ImGui::SameLine();
			ImGui::Checkbox("RUN", &run_enable);
			ImGui::SliderInt("Batch size", &batchSize, 1000, 1000000);
			if (single_step) single_step = false;
			if (ImGui::Button("Single step")) single_step = true;
			ImGui::SameLine();
			if (multi_step) multi_step = false;
			if (ImGui::Button("Multi step")) multi_step = true;
			ImGui::SameLine();
			ImGui::SliderInt("Steps", &multi_step_amount, 8, 1024);
			ImGui::RadioButton("715/64", &opt_model, 0); ImGui::SameLine();
			ImGui::RadioButton("715/80", &opt_model, 1); ImGui::SameLine();
			ImGui::RadioButton("715/100", &opt_model, 2);
			ImGui::SliderInt("RAM 2^n MB", &opt_ram_lg, 3, 6);
			ImGui::SliderInt("CR16 x (0 = real)", &opt_turbo, 0, 15);
			ImGui::Checkbox("TOC button", &opt_toc); ImGui::SameLine();
			ImGui::Checkbox("Soft power off", &opt_softoff);
			ImGui::Text("cycle %llu  frame %d  %.1f fps  %dx%d",
			            (unsigned long long)main_time, video.count_frame, video.stats_fps,
			            video.stats_xMax - video.stats_xMin + 1,
			            video.stats_yMax - video.stats_yMin + 1);
			ImGui::End();

			// Machine: CPU debug taps
			ImGui::Begin("Machine");
			ImGui::SetWindowPos("Machine", ImVec2(0, 210), ImGuiCond_Once);
			ImGui::SetWindowSize("Machine", ImVec2(500, 150), ImGuiCond_Once);
			ImGui::Text("HP 9000/715/64 -- PA-7100LC, LASI, Artist");
			ImGui::Separator();
			ImGui::Text("IAOQ  front %08X  back %08X", VERTOPINTERN->debug_iaoq_f,
			            VERTOPINTERN->debug_iaoq_b);
			ImGui::Text("insn  %08X   retired %llu   %s", VERTOPINTERN->debug_insn,
			            retired, VERTOPINTERN->debug_halted ? "HALTED" : "");
			{
				char leds[9];
				for (int b = 0; b < 8; b++) leds[b] = (VERTOPINTERN->leds >> (7 - b)) & 1 ? '.' : '*';
				leds[8] = 0;
				ImGui::Text("LEDs 8..1  %s   (code %02X)   ROM %s", leds, (~VERTOPINTERN->leds) & 0xFF,
				            rom_phase == 2 ? "loaded" : rom_phase == 1 ? "loading" : "missing");
			}
			ImGui::End();

			// Serial console
			ImGui::Begin("Serial console");
			ImGui::SetWindowPos("Serial console", ImVec2(0, 370), ImGuiCond_Once);
			ImGui::SetWindowSize("Serial console", ImVec2(500, 300), ImGuiCond_Once);
			if (ImGui::Button("Clear")) serial_text.clear();
			ImGui::SameLine();
			ImGui::Checkbox("Auto-scroll", &serial_scroll);
			{
				static char line[256] = "";
				ImGui::SameLine();
				ImGui::SetNextItemWidth(200);
				if (ImGui::InputText("##send", line, sizeof line, ImGuiInputTextFlags_EnterReturnsTrue)) {
					serial_in += line; serial_in += '\r'; line[0] = 0;
				}
				ImGui::SameLine();
				if (ImGui::Button("Esc")) serial_in += '\x1b';
			}
			ImGui::BeginChild("serial", ImVec2(0, 0), true, ImGuiWindowFlags_HorizontalScrollbar);
			ImGui::TextUnformatted(serial_text.c_str());
			if (serial_scroll) ImGui::SetScrollHereY(1.0f);
			ImGui::EndChild();
			ImGui::End();

			console.Draw("Debug log", &showDebugLog, ImVec2(500, 250));
			ImGui::SetWindowPos("Debug log", ImVec2(0, 680), ImGuiCond_Once);

			// Video
			ImGui::Begin(windowTitle_Video);
			ImGui::SetWindowPos(windowTitle_Video, ImVec2(510, 0), ImGuiCond_Once);
			ImGui::SetWindowSize(windowTitle_Video,
			                     ImVec2(video.output_width * vga_scale + 24,
			                            video.output_height * vga_scale + 46), ImGuiCond_Once);
			ImGui::SliderFloat("Zoom", &vga_scale, 0.25f, 4.0f);
			ImGui::Image(video.texture_id,
			             ImVec2(video.output_width * vga_scale, video.output_height * vga_scale));
			ImGui::End();

			video.UpdateTexture();
		}

		if (!screenshot_frames.empty()) {
			auto it = std::find(screenshot_frames.begin(), screenshot_frames.end(),
			                    (int)video.count_frame);
			if (it != screenshot_frames.end()) {
				save_screenshot(video.count_frame);
				screenshot_frames.erase(it);
			}
		}
		if (stop_at_frame >= 0 && (int)video.count_frame >= stop_at_frame) {
			printf("Reached frame %d, exiting\n", stop_at_frame);
			break;
		}
		if (max_cycles && main_time >= max_cycles) {
			printf("Reached %llu cycles, exiting\n", (unsigned long long)main_time);
			break;
		}

		if (Verilated::gotFinish() && run_enable) Verilated::gotFinish(false);
		if (Verilated::gotFinish()) run_enable = false;
		if (run_enable || headless)
			for (int step = 0; step < batchSize; step++) verilate();
		else {
			if (single_step) verilate();
			if (multi_step)
				for (int step = 0; step < multi_step_amount; step++) verilate();
		}
		if (headless && Verilated::gotFinish()) done = true;
	}

	if (serial_log) fclose(serial_log);
	if (!headless) { audio.CleanUp(); video.CleanUp(); input.CleanUp(); }
	top->final();
	delete top;
	return 0;
}
