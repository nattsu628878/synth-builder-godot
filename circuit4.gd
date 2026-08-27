extends Control

## Spike #4 (see nattsu-hub/projects/synth-builder-godot.md): close the
## loop for the first time -- arrange 2-terminal parts, wire their
## terminals, and the wiring is compiled into a netlist, solved by
## MnaSolverRs every audio sample, and heard + shown on the scope. Values
## are live-editable without a rebuild (MnaSolver.set_value).
##
## Fixed part set (source / ground / output / 2R / 2C / diode); the player
## only rewires and revalues. No palette, no save. Throwaway.

const SR := 44100.0
const SCOPE_SAMPLES := 512
const RUST_CLASS := "MnaSolverRs"

var _solver: Object
var _using_rust := false

var _phase := 0.0
var _freq := 220.0
var _drive := 1.5

var _ok := false
var _out_pos := ""
var _out_neg := ""
var _status := "wire it up"

var _scope_in := PackedFloat32Array()
var _scope_out := PackedFloat32Array()
var _sidx := 0

@onready var _canvas: Circuit4Canvas = %Canvas
@onready var _scope: Control = %Scope
@onready var _status_label: Label = %StatusLabel
@onready var _sel_label: Label = %SelLabel
@onready var _value_slider: HSlider = %ValueSlider
@onready var _freq_slider: HSlider = %FreqSlider
@onready var _drive_slider: HSlider = %DriveSlider
@onready var _audio: AudioStreamPlayer = %AudioPlayer

var _playback: AudioStreamGeneratorPlayback

func _ready() -> void:
	_scope_in.resize(SCOPE_SAMPLES)
	_scope_out.resize(SCOPE_SAMPLES)

	if ClassDB.class_exists(RUST_CLASS):
		_solver = ClassDB.instantiate(RUST_CLASS)
		_using_rust = true
	else:
		_solver = preload("res://mna_solver.gd").new()

	var r_i := 0
	var c_i := 0
	var d_i := 0
	for child in _canvas.get_children():
		if child is Circuit4Part:
			_canvas.register_part(child)
			match child.part_type:
				"resistor": child.pname = "R%d" % r_i; r_i += 1
				"capacitor": child.pname = "C%d" % c_i; c_i += 1
				"diode": child.pname = "D%d" % d_i; d_i += 1
				"source": child.pname = "SRC"
				"ground": child.pname = "GND"
				"output": child.pname = "OUT"
			var lbl := child.get_node_or_null("Label")
			if lbl:
				lbl.text = child.pname

	_canvas.topology_changed.connect(_recompile)
	_canvas.selection_changed.connect(_on_selection_changed)
	_value_slider.value_changed.connect(_on_value_slider)
	_value_slider.visible = false
	_sel_label.text = "select a part to edit its value"

	_audio.play()
	_playback = _audio.get_stream_playback()
	_recompile()

func _recompile() -> void:
	var res := _canvas.compile_netlist()
	if not res["ok"]:
		_ok = false
		_status = "not ready: %s" % res["error"]
		return
	var used := {}
	for comp in res["netlist"]:
		for nn in comp["nodes"]:
			used[nn] = true
	if res["out_pos"] != "gnd" and not used.has(res["out_pos"]):
		_ok = false
		_status = "not ready: wire the output probe (+) into the circuit"
		return

	_solver.build(res["netlist"], "gnd")
	_solver.set_dt(1.0 / SR)
	_out_pos = res["out_pos"]
	_out_neg = res["out_neg"]
	_ok = true
	_status = "compiled: %d nodes, %d components  [%s]" % [
		res["num_nodes"], res["netlist"].size(), "Rust" if _using_rust else "GDScript"]

func _on_selection_changed(part: Circuit4Part) -> void:
	match part.part_type:
		"resistor":
			_value_slider.visible = true
			_value_slider.min_value = 100.0
			_value_slider.max_value = 100000.0
			_value_slider.exp_edit = true
			_value_slider.step = 1.0
			_value_slider.set_value_no_signal(part.value)
			_sel_label.text = "%s  resistance: %.0f ohm" % [part.pname, part.value]
		"capacitor":
			_value_slider.visible = true
			_value_slider.min_value = 1.0        # nF
			_value_slider.max_value = 1000.0
			_value_slider.exp_edit = true
			_value_slider.step = 0.1
			_value_slider.set_value_no_signal(part.value * 1.0e9)
			_sel_label.text = "%s  capacitance: %.1f nF" % [part.pname, part.value * 1.0e9]
		_:
			_value_slider.visible = false
			_sel_label.text = "%s  (no editable value -- use Drive/Freq below)" % part.pname

func _on_value_slider(v: float) -> void:
	var part := _canvas.selected
	if part == null:
		return
	if part.part_type == "resistor":
		part.value = v
		_solver.set_value(part.pname, v)
		_sel_label.text = "%s  resistance: %.0f ohm" % [part.pname, v]
	elif part.part_type == "capacitor":
		part.value = v * 1.0e-9
		_solver.set_value(part.pname, part.value)
		_sel_label.text = "%s  capacitance: %.1f nF" % [part.pname, v]

func _process(_delta: float) -> void:
	_freq = _freq_slider.value
	_drive = _drive_slider.value
	_fill_audio()
	_scope.set_data(_scope_in, _scope_out)
	_status_label.text = _status

func _fill_audio() -> void:
	if _playback == null:
		return
	var frames := _playback.get_frames_available()
	var inv_drive := 1.0 / maxf(_drive, 0.01)
	var step := _freq / SR
	for _i in frames:
		_phase += step
		if _phase >= 1.0:
			_phase -= 1.0
		var saw := 2.0 * _phase - 1.0
		var out_v := 0.0
		if _ok:
			_solver.set_source("vin", _drive * saw)
			_solver.step()
			out_v = _solver.node_voltage(_out_pos) - _solver.node_voltage(_out_neg)
		var s := clampf(out_v * inv_drive, -1.0, 1.0)
		_playback.push_frame(Vector2(s, s) if _ok else Vector2.ZERO)
		_scope_in[_sidx] = clampf(saw, -1.0, 1.0)
		_scope_out[_sidx] = s if _ok else 0.0
		_sidx = (_sidx + 1) % SCOPE_SAMPLES
