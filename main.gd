extends Control

## Spike #2 goal (see nattsu-hub/projects/synth-builder-godot.md): spike #1
## tested "does watching a value change feel good". This one tests the
## other half of "circuit design" -- does placing and wiring blocks
## yourself feel good, separately from tweaking their parameters?
##
## Still not the real circuit engine: three fixed blocks (no palette to
## add more yet), single-input/single-output ports, a strict series
## chain (no branching/summing). The RC block's math is the same
## hand-solved ODE as spike #1.
##
## All UI nodes live in main.tscn so they can be rearranged in the Godot
## editor -- this script only reads/writes them via unique names (%Name).

const SAMPLE_RATE := 44100.0
const SCOPE_SAMPLES := 512

var freq_hz: float = 220.0
var resistance: float = 1000.0     # ohm
var capacitance: float = 100.0e-9  # farad (slider is in nF)

var _osc_phase: float = 0.0
var _vc: float = 0.0  # capacitor voltage = RC block's internal state

var _scope_in: PackedFloat32Array = PackedFloat32Array()
var _scope_out: PackedFloat32Array = PackedFloat32Array()
var _scope_write_idx: int = 0

@onready var _scope: Control = %Scope
@onready var _cutoff_label: Label = %CutoffLabel
@onready var _status_label: Label = %StatusLabel
@onready var _freq_slider: HSlider = %FreqSlider
@onready var _r_slider: HSlider = %RSlider
@onready var _c_slider: HSlider = %CSlider
@onready var _audio_player: AudioStreamPlayer = %AudioPlayer
@onready var _canvas = %Canvas
@onready var _source_block = %SourceBlock
@onready var _rc_block = %RCBlock
@onready var _output_block = %OutputBlock

var _playback: AudioStreamGeneratorPlayback

func _ready() -> void:
	_scope_in.resize(SCOPE_SAMPLES)
	_scope_out.resize(SCOPE_SAMPLES)
	_audio_player.play()
	_playback = _audio_player.get_stream_playback()

	_canvas.register_block("source", _source_block)
	_canvas.register_block("rc", _rc_block)
	_canvas.register_block("output", _output_block)

func _process(_delta: float) -> void:
	freq_hz = _freq_slider.value
	resistance = _r_slider.value
	capacitance = _c_slider.value * 1.0e-9

	var cutoff_hz := 1.0 / (TAU * resistance * capacitance)
	_cutoff_label.text = "RC block cutoff: %.0f Hz" % cutoff_hz

	var chain: Array = _canvas.get_chain_from_source()
	var reaches_output: bool = chain.size() > 0 and chain[-1] == "output"
	var wired_text := "Wired to output: yes" if reaches_output else "Wired to output: no"
	_status_label.text = "%s (%s)" % [wired_text, _canvas.get_pending_description()]

	_fill_audio(chain, reaches_output)
	_scope.set_data(_scope_in, _scope_out)

func _fill_audio(chain: Array, reaches_output: bool) -> void:
	if _playback == null:
		return
	var frames := _playback.get_frames_available()
	var dt := 1.0 / SAMPLE_RATE
	for _i in frames:
		# Sawtooth source, -1..1. Always runs, regardless of wiring, so the
		# scope's "in" trace is always live.
		_osc_phase += freq_hz / SAMPLE_RATE
		if _osc_phase >= 1.0:
			_osc_phase -= 1.0
		var vin := 2.0 * _osc_phase - 1.0

		var value := 0.0
		if reaches_output:
			value = vin
			for id in chain:
				if id == "rc":
					value = _apply_rc(value, dt)
			_playback.push_frame(Vector2(value, value))
		else:
			_playback.push_frame(Vector2(0.0, 0.0))

		_scope_in[_scope_write_idx] = vin
		_scope_out[_scope_write_idx] = value
		_scope_write_idx = (_scope_write_idx + 1) % SCOPE_SAMPLES

func _apply_rc(vin: float, dt: float) -> float:
	# RC low-pass: dVc/dt = (Vin - Vc) / (R*C), forward Euler.
	_vc += dt * (vin - _vc) / (resistance * capacitance)
	_vc = clamp(_vc, -1.0, 1.0)
	return _vc
