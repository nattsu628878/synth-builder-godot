extends Control

## Spike goal (see nattsu-hub/projects/synth-builder-godot.md): this is NOT
## the real circuit engine. It's the cheapest possible test of the actual
## hypothesis -- does watching a waveform react live to a knob feel good?
## So the "circuit" here is a single hand-solved RC low-pass (an ODE
## integrated with forward Euler), not a general MNA solver. A sawtooth
## oscillator feeds it so the filtering effect is visible on the scope.
##
## All UI nodes live in main.tscn (not built in code) so they can be
## rearranged in the Godot editor -- this script only reads/writes them
## via unique names (%Name), which keep resolving even if you move nodes
## around in the tree.

const SAMPLE_RATE := 44100.0
const SCOPE_SAMPLES := 512

var freq_hz: float = 220.0
var resistance: float = 1000.0     # ohm
var capacitance: float = 100.0e-9  # farad (slider is in nF)

var _osc_phase: float = 0.0
var _vc: float = 0.0  # capacitor voltage = filter output

var _scope_in: PackedFloat32Array = PackedFloat32Array()
var _scope_out: PackedFloat32Array = PackedFloat32Array()
var _scope_write_idx: int = 0

@onready var _scope: Control = %Scope
@onready var _cutoff_label: Label = %CutoffLabel
@onready var _freq_slider: HSlider = %FreqSlider
@onready var _r_slider: HSlider = %RSlider
@onready var _c_slider: HSlider = %CSlider
@onready var _audio_player: AudioStreamPlayer = %AudioPlayer

var _playback: AudioStreamGeneratorPlayback

func _ready() -> void:
	_scope_in.resize(SCOPE_SAMPLES)
	_scope_out.resize(SCOPE_SAMPLES)
	_audio_player.play()
	_playback = _audio_player.get_stream_playback()

func _process(_delta: float) -> void:
	freq_hz = _freq_slider.value
	resistance = _r_slider.value
	capacitance = _c_slider.value * 1.0e-9

	var cutoff_hz := 1.0 / (TAU * resistance * capacitance)
	_cutoff_label.text = "Filter cutoff: %.0f Hz" % cutoff_hz

	_fill_audio()
	_scope.set_data(_scope_in, _scope_out)

func _fill_audio() -> void:
	if _playback == null:
		return
	var frames := _playback.get_frames_available()
	var dt := 1.0 / SAMPLE_RATE
	for _i in frames:
		# Sawtooth source, -1..1.
		_osc_phase += freq_hz / SAMPLE_RATE
		if _osc_phase >= 1.0:
			_osc_phase -= 1.0
		var vin := 2.0 * _osc_phase - 1.0

		# RC low-pass: dVc/dt = (Vin - Vc) / (R*C), forward Euler.
		_vc += dt * (vin - _vc) / (resistance * capacitance)
		_vc = clamp(_vc, -1.0, 1.0)

		_playback.push_frame(Vector2(_vc, _vc))

		_scope_in[_scope_write_idx] = vin
		_scope_out[_scope_write_idx] = _vc
		_scope_write_idx = (_scope_write_idx + 1) % SCOPE_SAMPLES
