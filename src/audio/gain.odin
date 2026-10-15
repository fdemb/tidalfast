package audio

import "core:math"

// Replay_Gain is the loudness data TIDAL's playbackinfo carries for a
// track. Gains are in dB, peaks are linear sample peaks (1.0 is full
// scale). A gain TIDAL left out is 0 dB, a peak it left out 1.0.
Replay_Gain :: struct {
	track_gain: f64,
	track_peak: f64,
	album_gain: f64,
	album_peak: f64,
}

Gain_Mode :: enum u8 {
	Track,
	Album,
}

// replay_gain_linear turns ReplayGain into the factor applied to the
// samples: 10^(gain/20), lowered if needed so the peak stays at or below
// full scale.
replay_gain_linear :: proc(rg: Replay_Gain, mode: Gain_Mode) -> f32 {
	gain, peak := rg.track_gain, rg.track_peak
	if mode == .Album {
		gain, peak = rg.album_gain, rg.album_peak
	}
	g := math.pow(10, gain / 20)
	if peak > 0 && g * peak > 1 {
		g = 1 / peak
	}
	return f32(g)
}

// volume_gain maps the volume slider (0 to 1) to a factor. A cube follows
// loudness more closely than a straight line: half way is about -18 dB.
volume_gain :: proc "contextless" (v: f32) -> f32 {
	x := clamp(v, 0, 1)
	return x * x * x
}
