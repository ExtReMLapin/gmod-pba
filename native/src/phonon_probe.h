// Level probe of the phonon.dll in use: does its reflection simulator give an impulse response in the units of
// the direct sound? Steam Audio 4.8.1 as released (and the fork builds before the level fix) deposits energy
// 11 dB too loud into the reconstructed response (ReflectionSimulator / Reconstructor: the response was not
// normalised for the noise it is built from and the number of samples per bin); the fixed builds give a
// physical response, the first reflection off a lossless floor at the energy 1/(path length)^2.
// The probe measures that on the DLL itself, with the public API only: a mirror floor, a source and a listener at
// a known distance, the response convolved with an impulse. Used by the Lua side to tie the one-time retune of the
// reverb defaults to a phonon.dll that really is the fixed one (a file hash would be a list to maintain).
// No dependency on the module: it builds its own Steam Audio context.
#pragma once

namespace probe {

// Threshold between the two populations (measured: old builds +8.5 (official 4.8.1) .. +10.0 (fork pba.3) dB over the physical level for a
// mirror floor at 4 m, 1.5 m high, fixed build -1.0 dB): between them, 5 dB.
constexpr double kThresholdDb = 5.0;

struct Result {
	bool ok = false;        // the measurement ran (false: a Steam Audio call failed; nothing is known)
	double levelDb = 0.0;   // energy of the response over the physical energy of the reflection, dB
	bool fixed() const { return ok && levelDb < kThresholdDb; }
};

Result MeasureReflectionLevel();

} // namespace probe
