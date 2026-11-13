// Offline check of the module's decoder (no game). Built with -DPBA_TESTS=ON (target pba_decode_test).
// Pass: a 16-bit PCM WAV whose 18-byte "fmt " chunk has a cbSize claiming 18 more bytes that are not there
// (as HL2's sound/combined/*_cc.wav, which also state a block align of 1 and carry a "VDAT" caption chunk
// after the data) decodes to its full length, as the engine plays it; a correct PCM WAV keeps decoding; the
// loop start comes from the first loop of a "smpl" chunk, else from the first "cue " point, a smpl chunk
// without loops not hiding the cue (npc/manhack/mh_engine_loop1.wav).
// `pba_decode_test census <list> <root>`: decodes every file of <list> (lines "path<TAB>engine seconds<TAB>
// size", read under <root>) and prints those whose decoded length is more than 2 % off the given one.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>

#include "../src/render.h"

static int fails = 0;
static void Check(bool ok, const char* what, double a = 0, double b = 0) {
	std::printf("%s %s (%.4g, %.4g)\n", ok ? "ok  " : "FAIL", what, a, b);
	if (!ok) ++fails;
}

// A mono 16-bit PCM WAV of `frames` frames at 44100 Hz; blockAlign as given; when `cc`, as the _cc files:
// an 18-byte fmt whose cbSize says 18 (an extension that is not there), a trailing VDAT chunk.
static std::string Wav(int frames, uint16_t blockAlign, bool cc) {
	std::string body;
	auto u32 = [](std::string& d, uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [](std::string& d, uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	const int rate = 44100;
	body += "WAVEfmt "; u32(body, cc ? 18 : 16);
	u16(body, 1); u16(body, 1); u32(body, rate); u32(body, rate * 2); u16(body, blockAlign); u16(body, 16);
	if (cc) u16(body, 18);
	body += "data"; u32(body, frames * 2);
	for (int i = 0; i < frames; ++i) u16(body, (uint16_t)(int16_t)(12000 * std::sin(2 * 3.14159265 * 440 * i / rate)));
	if (cc) { const std::string v = "VERSION 1.0\nPLAINTEXT\n{\n}\n"; body += "VDAT"; u32(body, (uint32_t)v.size()); body += v; if (v.size() & 1) body.push_back(0); }
	std::string d = "RIFF"; u32(d, (uint32_t)body.size()); return d + body;
}

// A mono 16-bit PCM WAV of `frames` frames at 44100 Hz followed by a "smpl" chunk of `loops` loops (the
// first starting at frame smplStart) and a "cue " chunk of one point at frame cueAt (as
// npc/manhack/mh_engine_loop1.wav: a smpl with 0 loops, then the cue point the engine loops from).
static std::string LoopWav(int frames, int loops, int smplStart, int cueAt) {
	std::string body;
	auto u32 = [](std::string& d, uint32_t v) { for (int i = 0; i < 4; ++i) d.push_back((char)(v >> (8 * i))); };
	auto u16 = [](std::string& d, uint16_t v) { for (int i = 0; i < 2; ++i) d.push_back((char)(v >> (8 * i))); };
	const int rate = 44100;
	body += "WAVEfmt "; u32(body, 16);
	u16(body, 1); u16(body, 1); u32(body, rate); u32(body, rate * 2); u16(body, 2); u16(body, 16);
	body += "data"; u32(body, frames * 2);
	for (int i = 0; i < frames; ++i) u16(body, (uint16_t)(int16_t)(12000 * std::sin(2 * 3.14159265 * 440 * i / rate)));
	body += "smpl"; u32(body, 36 + 24 * loops);
	for (int i = 0; i < 7; ++i) u32(body, 0);
	u32(body, (uint32_t)loops); u32(body, 0);
	for (int l = 0; l < loops; ++l) { u32(body, 0); u32(body, 0); u32(body, (uint32_t)smplStart); u32(body, (uint32_t)frames - 1); u32(body, 0); u32(body, 0); }
	body += "cue "; u32(body, 4 + 24); u32(body, 1);
	u32(body, 1); u32(body, (uint32_t)cueAt); body += "data"; u32(body, 0); u32(body, 0); u32(body, (uint32_t)cueAt);
	std::string d = "RIFF"; u32(d, (uint32_t)body.size()); return d + body;
}

static std::string Slurp(const std::string& p) { std::ifstream f(p, std::ios::binary); std::stringstream ss; ss << f.rdbuf(); return ss.str(); }

static int Census(const char* list, const char* root) {
	std::ifstream l(list); std::string line; int n = 0, bad = 0;
	while (std::getline(l, line)) {
		const size_t t1 = line.find('\t'), t2 = line.find('\t', t1 + 1);
		if (t1 == std::string::npos) continue;
		const std::string f = line.substr(0, t1);
		const double eng = atof(line.substr(t1 + 1, t2 - t1 - 1).c_str());
		const std::string d = Slurp(std::string(root) + "/" + f);
		double secs = -1;
		const std::string e = render::LoadSound("census", d.data(), d.size(), &secs);
		++n;
		if (!e.empty() || std::fabs(secs - eng) > 0.02 * eng + 0.01) {
			++bad;
			std::printf("%s\tengine=%.3f\tmodule=%.3f\tbytes=%zu\t%s\n", f.c_str(), eng, secs, d.size(), e.c_str());
		}
	}
	std::printf("census %d files, %d off\n", n, bad);
	return 0;
}

int main(int argc, char** argv) {
	if (argc >= 4 && std::string(argv[1]) == "census") return Census(argv[2], argv[3]);
	const int frames = 44100 * 3 / 2; // 1.5 s
	double secs = -1;
	const std::string good = Wav(frames, 2, false);
	Check(render::LoadSound("good.wav", good.data(), good.size(), &secs).empty(), "decode a correct PCM WAV");
	Check(std::fabs(secs - 1.5) < 0.01, "correct PCM WAV length", secs, 1.5);
	secs = -1;
	const std::string cc = Wav(frames, 1, true);
	const std::string err = render::LoadSound("cc.wav", cc.data(), cc.size(), &secs);
	Check(err.empty(), ("decode a PCM WAV with a wrong fmt cbSize (" + err + ")").c_str());
	Check(std::fabs(secs - 1.5) < 0.01, "wrong-cbSize WAV length", secs, 1.5);
	// loop start: a smpl chunk without loops does not hide the cue point after it; a smpl loop wins
	double ls = -1;
	const std::string noLoops = LoopWav(44100, 0, 0, 11025);
	Check(render::LoadSound("smpl0.wav", noLoops.data(), noLoops.size(), &secs, &ls).empty(), "decode smpl(0 loops) + cue");
	Check(std::fabs(ls - 0.25) < 0.001, "smpl(0 loops) + cue: loop from the cue point", ls, 0.25);
	ls = -1;
	const std::string withLoop = LoopWav(44100, 1, 22050, 11025);
	Check(render::LoadSound("smpl1.wav", withLoop.data(), withLoop.size(), &secs, &ls).empty(), "decode smpl(1 loop) + cue");
	Check(std::fabs(ls - 0.5) < 0.001, "smpl(1 loop) + cue: loop from the smpl loop", ls, 0.5);
	std::printf(fails ? "FAILED (%d)\n" : "PASSED\n", fails);
	return fails ? 1 : 0;
}
