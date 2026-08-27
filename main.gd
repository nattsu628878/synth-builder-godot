extends Control

## Spike goal (see nattsu-hub/projects/synth-builder-godot.md): this is NOT
## the real circuit engine. It's the cheapest possible test of the actual
## hypothesis -- does watching a waveform react live to a knob feel good?
## So the "circuit" here is a single hand-solved RC low-pass (an ODE
## integrated with forward Euler), not a general MNA solver. A sawtooth
## oscillator feeds it so the filtering effect is visible on the scope.

const SAMPLE_RATE := 44100.0
const SCOPE_SAMPLES := 512

var freq_hz: float = 220.0
var resistance: float = 1000.0     # ohm
var capacitance: float = 100.0e-9  # farad (set via slider in nF)

var _osc_phase: float = 0.0
var _vc: float = 0.0  # capacitor voltage = filter output

var _scope_in: PackedFloat32Array = PackedFloat32Array()
var _scope_out: PackedFloat32Array = PackedFloat32Array()
var _scope_write_idx: int = 0

var _scope: Control
var _freq_slider: HSlider
var _r_slider: HSlider
var _c_slider: HSlider
var _cutoff_label: Label

var _audio_player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback

func _ready() -> void:
	_scope_in.resize(SCOPE_SAMPLES)
	_scope_out.resize(SCOPE_SAMPLES)
	_build_ui()
	_setup_audio()

func _build_ui() -> void:
	custom_minimum_size = Vector2(820, 560)
	anchor_right = 1.0
	anchor_bottom = 1.0

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "RC low-pass spike -- sawtooth in, filtered out. Drag the sliders."
	vbox.add_child(title)

	_scope = preload("res://oscilloscope.gd").new()
	_scope.custom_minimum_size = Vector2(780, 280)
	vbox.add_child(_scope)

	_cutoff_label = Label.new()
	vbox.add_child(_cutoff_label)

	_freq_slider = _add_slider(vbox, "Oscillator frequency (Hz)", 50.0, 2000.0, freq_hz)
	_r_slider = _add_slider(vbox, "Resistance (ohm)", 100.0, 20000.0, resistance)
	_c_slider = _add_slider(vbox, "Capacitance (nF)", 1.0, 1000.0, capacitance * 1.0e9)

func _add_slider(parent: Node, label_text: String, min_v: float, max_v: float, default_v: float) -> HSlider:
	var label := Label.new()
	label.text = label_text
	parent.add_child(label)
	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = (max_v - min_v) / 200.0
	slider.value = default_v
	slider.custom_minimum_size = Vector2(400, 24)
	parent.add_child(slider)
	return slider

func _setup_audio() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = SAMPLE_RATE
	gen.buffer_length = 0.1
	_audio_player = AudioStreamPlayer.new()
	_audio_player.stream = gen
	add_child(_audio_player)
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
