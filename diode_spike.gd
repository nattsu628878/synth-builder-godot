extends Control

## Spike #3 (see nattsu-hub/projects/synth-builder-godot.md): can Godot /
## GDScript run an audio-rate NONLINEAR circuit solver in real time?
##
## Spikes #1/#2 proved GDScript does audio-rate DSP for a linear
## hand-solved RC filter. The open question is the Newton-Raphson loop:
## solving a small MNA system with a nonlinear device every sample.
##
## The solver lives in DiodeCircuit (diode_circuit.gd); this scene wires
## it to a sawtooth source, the audio out, the scope, and an on-screen
## perf readout. bench.gd times the same solver headless.
##
## Throwaway: no save, no palette, no game. UI lives in diode_spike.tscn.

const SAMPLE_RATE := 44100.0
const SCOPE_SAMPLES := 512

var drive_v: float = 1.5
var freq_hz: float = 220.0
var _osc_phase: float = 0.0

const DiodeCircuitScript := preload("res://diode_circuit.gd")
var _circuit: DiodeCircuit = DiodeCircuitScript.new()

var _scope_in: PackedFloat32Array = PackedFloat32Array()
var _scope_out: PackedFloat32Array = PackedFloat32Array()
var _scope_write_idx: int = 0

var _last_us_per_sample: float = 0.0
var _worst_us_per_sample: float = 0.0
var _last_max_iters: int = 0
var _worst_iters: int = 0
var _underruns: int = 0
var _dsp_load: float = 0.0

@onready var _scope: Control = %Scope
@onready var _perf_label: Label = %PerfLabel
@onready var _cutoff_label: Label = %CutoffLabel
@onready var _drive_slider: HSlider = %DriveSlider
@onready var _freq_slider: HSlider = %FreqSlider
@onready var _r_slider: HSlider = %RSlider
@onready var _c_slider: HSlider = %CSlider
@onready var _os_option: OptionButton = %OversampleOption
@onready var _audio_player: AudioStreamPlayer = %AudioPlayer

var _playback: AudioStreamGeneratorPlayback
var _buffer_frames: int = 0

func _ready() -> void:
	_scope_in.resize(SCOPE_SAMPLES)
	_scope_out.resize(SCOPE_SAMPLES)
	_circuit.sample_rate = SAMPLE_RATE
	_audio_player.play()
	_playback = _audio_player.get_stream_playback()
	var gen := _audio_player.stream as AudioStreamGenerator
	_buffer_frames = int(gen.mix_rate * gen.buffer_length)

	_os_option.clear()
	for f in [1, 2, 4, 8]:
		_os_option.add_item("%dx" % f)
	_os_option.selected = 0
	_os_option.item_selected.connect(func(idx): _circuit.oversample = [1, 2, 4, 8][idx])

func _process(_delta: float) -> void:
	drive_v = _drive_slider.value
	freq_hz = _freq_slider.value
	_circuit.resistance = _r_slider.value
	_circuit.capacitance = _c_slider.value * 1.0e-9

	var lin_cutoff := 1.0 / (TAU * _circuit.resistance * _circuit.capacitance)
	_cutoff_label.text = "RC corner (linear, small-signal): %.0f Hz" % lin_cutoff

	_fill_audio()
	_scope.set_data(_scope_in, _scope_out)

	_perf_label.text = "\n".join([
		"solve time:  %.2f us/audio-sample   (worst %.2f)" % [_last_us_per_sample, _worst_us_per_sample],
		"Newton:      %d iters max this block   (worst %d)   non-converged total: %d" % [_last_max_iters, _worst_iters, _circuit.nonconverged],
		"DSP load:    %.1f %%   of the audio time budget" % [_dsp_load * 100.0],
		"engine FPS:  %.0f        buffer underruns: %d" % [Engine.get_frames_per_second(), _underruns],
		"oversample:  %dx  ->  effective solver rate %.0f kHz" % [_circuit.oversample, SAMPLE_RATE * _circuit.oversample / 1000.0],
	])

func _fill_audio() -> void:
	if _playback == null:
		return
	var frames := _playback.get_frames_available()
	if frames <= 0:
		return
	if frames >= _buffer_frames:
		_underruns += 1  # generator drained before refill; first fill trips this once

	var block_max_iters := 0
	var inv_drive := 1.0 / maxf(drive_v, 0.001)
	var step := freq_hz / SAMPLE_RATE

	var t0 := Time.get_ticks_usec()
	for _i in frames:
		_osc_phase += step
		if _osc_phase >= 1.0:
			_osc_phase -= 1.0
		var vin := drive_v * (2.0 * _osc_phase - 1.0)
		var out_v := _circuit.process_sample(vin)
		block_max_iters = maxi(block_max_iters, _circuit.last_iters)

		var sample := clampf(out_v * inv_drive, -1.0, 1.0)
		_playback.push_frame(Vector2(sample, sample))
		_scope_in[_scope_write_idx] = clampf(vin * inv_drive, -1.0, 1.0)
		_scope_out[_scope_write_idx] = sample
		_scope_write_idx = (_scope_write_idx + 1) % SCOPE_SAMPLES
	var elapsed_us := Time.get_ticks_usec() - t0

	_last_us_per_sample = float(elapsed_us) / float(maxi(frames, 1))
	_worst_us_per_sample = maxf(_worst_us_per_sample, _last_us_per_sample)
	_last_max_iters = block_max_iters
	_worst_iters = maxi(_worst_iters, block_max_iters)
	var audio_time_us := float(frames) / SAMPLE_RATE * 1.0e6
	_dsp_load = float(elapsed_us) / maxf(audio_time_us, 1.0)
