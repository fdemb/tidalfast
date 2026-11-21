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

// Gain_Setting is how the user has ReplayGain applied. Automatic leaves
// the choice of track or album gain to queue_gain_mode.
Gain_Setting :: enum u8 {
	Automatic,
	Track,
	Album,
	Off,
}

// setting_gain is the factor for rg under setting, auto being what
// queue_gain_mode chose for the track. Album gain without an album gain
// in the stream is the track's, as the playbackinfo reader fills it in.
setting_gain :: proc(rg: Replay_Gain, setting: Gain_Setting, auto: Gain_Mode) -> f32 {
	switch setting {
	case .Automatic:
		return replay_gain_linear(rg, auto)
	case .Track:
		return replay_gain_linear(rg, .Track)
	case .Album:
		return replay_gain_linear(rg, .Album)
	case .Off:
		return 1
	}
	return 1
}

// volume_gain maps the volume slider (0 to 1) to a factor. A cube follows
// loudness more closely than a straight line: half way is about -18 dB.
volume_gain :: proc "contextless" (v: f32) -> f32 {
	x := clamp(v, 0, 1)
	return x * x * x
}
