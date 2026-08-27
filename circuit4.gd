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
var _source_names: PackedStringArray = []   # every "source" part's pname, all driven by the oscillator
var _status := "wire it up"

var _scope_in := PackedFloat32Array()
var _scope_out := PackedFloat32Array()
var _sidx := 0

var _count := {"resistor": 0, "capacitor": 0, "diode": 0, "source": 0, "ground": 0, "output": 0}
var _spawn_i := 0

const DEFAULTS := {"resistor": 4700.0, "capacitor": 1.0e-8}
const ABBR := {
	"resistor": "R", "capacitor": "C", "diode": "D",
	"source": "SRC", "ground": "GND", "output": "OUT",
}

const PATCH_DIR := "user://patches"

@onready var _canvas: Circuit4Canvas = %Canvas
@onready var _palette: HBoxContainer = %Palette
@onready var _scope: Control = %Scope
@onready var _status_label: Label = %StatusLabel
@onready var _sel_label: Label = %SelLabel
@onready var _freq_slider: HSlider = %FreqSlider
@onready var _drive_slider: HSlider = %DriveSlider
@onready var _audio: AudioStreamPlayer = %AudioPlayer
@onready var _patch_name: LineEdit = %PatchName
@onready var _patch_list: OptionButton = %PatchList
@onready var _save_btn: Button = %SaveBtn
@onready var _load_btn: Button = %LoadBtn

var _playback: AudioStreamGeneratorPlayback

func _ready() -> void:
	_scope_in.resize(SCOPE_SAMPLES)
	_scope_out.resize(SCOPE_SAMPLES)

	if ClassDB.class_exists(RUST_CLASS):
		_solver = ClassDB.instantiate(RUST_CLASS)
		_using_rust = true
	else:
		_solver = preload("res://mna_solver.gd").new()

	# parts pre-placed in the scene (source / ground / output)
	for child in _canvas.get_children():
		if child is Circuit4Part:
			_canvas.register_part(child)
			child.pname = ABBR[child.part_type]
			child.queue_redraw()
			_spawn_i += 1

	for btn in _palette.get_children():
		if btn is Button:
			btn.pressed.connect(_add_part.bind(btn.name.to_lower()))

	_canvas.topology_changed.connect(_recompile)
	_canvas.selection_changed.connect(_on_selection_changed)
	_canvas.part_value_changed.connect(_on_part_value_changed)
	_sel_label.text = "drag a part's knob to set its value  (click a part, Delete removes it)"

	_save_btn.pressed.connect(_save_patch)
	_load_btn.pressed.connect(_load_patch)
	DirAccess.make_dir_recursive_absolute(PATCH_DIR)
	_refresh_patch_list()

	_audio.play()
	_playback = _audio.get_stream_playback()
	_recompile()

func _spawn_part(type: String, pname: String, pos: Vector2, value: float) -> Circuit4Part:
	var p: Circuit4Part = preload("res://circuit4_part.gd").new()
	p.custom_minimum_size = Vector2(96, 50)
	p.part_type = type
	p.value = value
	p.position = pos
	p.pname = pname
	_canvas.add_child(p)
	_canvas.register_part(p)
	return p

func _add_part(type: String) -> void:
	var col := _spawn_i % 6
	var row := (_spawn_i / 6) % 3
	_spawn_i += 1
	var value: float = DEFAULTS.get(type, 0.0)
	_spawn_part(type, "%s%d" % [ABBR[type], _count[type]], Vector2(70.0 + col * 112.0, 20.0 + row * 84.0), value)
	_count[type] += 1
	_recompile()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_DELETE or event.keycode == KEY_BACKSPACE:
			if _canvas.selected and not _patch_name.has_focus():
				_canvas.remove_part(_canvas.selected)
				get_viewport().set_input_as_handled()

# --- patch save / load (JSON, user://patches/) --------------------------

func _patch_path(name: String) -> String:
	return "%s/%s.json" % [PATCH_DIR, name.strip_edges()]

func _save_patch() -> void:
	var name := _patch_name.text.strip_edges()
	if name.is_empty():
		_status = "name the patch before saving"
		return
	var parts_json := []
	for p in _canvas.parts:
		parts_json.append({
			"pname": p.pname, "type": p.part_type, "value": p.value,
			"pos": [p.position.x, p.position.y],
		})
	var wires_json := []
	for w in _canvas.wires:
		wires_json.append({
			"a": [w["a"][0].pname, w["a"][1]], "b": [w["b"][0].pname, w["b"][1]],
		})
	var data := {
		"version": 1, "parts": parts_json, "wires": wires_json,
		"drive": _drive_slider.value, "freq": _freq_slider.value,
	}
	var f := FileAccess.open(_patch_path(name), FileAccess.WRITE)
	if f == null:
		_status = "save failed: %s" % error_string(FileAccess.get_open_error())
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	_refresh_patch_list(name)
	_status = "saved '%s' (%d parts, %d wires)" % [name, parts_json.size(), wires_json.size()]

func _load_patch() -> void:
	if _patch_list.item_count == 0:
		return
	var name := _patch_list.get_item_text(_patch_list.selected)
	var text := FileAccess.get_file_as_string(_patch_path(name))
	if text.is_empty():
		_status = "load failed: %s not readable" % name
		return
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		_status = "load failed: %s is not valid JSON" % name
		return

	_canvas.clear_all()
	for k in _count:
		_count[k] = 0
	_spawn_i = 0

	var by := {}
	for pj in data.get("parts", []):
		var p := _spawn_part(pj["type"], pj["pname"], Vector2(pj["pos"][0], pj["pos"][1]), float(pj["value"]))
		by[p.pname] = p
		var idx := _trailing_int(p.pname)
		if idx >= 0:
			_count[p.part_type] = maxi(_count[p.part_type], idx + 1)
		_spawn_i += 1
	for wj in data.get("wires", []):
		if by.has(wj["a"][0]) and by.has(wj["b"][0]):
			_canvas.wires.append({
				"a": [by[wj["a"][0]], int(wj["a"][1])], "b": [by[wj["b"][0]], int(wj["b"][1])],
			})
	_drive_slider.value = data.get("drive", 1.5)
	_freq_slider.value = data.get("freq", 220.0)
	_canvas.queue_redraw()
	_recompile()
	_status = "loaded '%s' -- %s" % [name, _status]

func _trailing_int(s: String) -> int:
	var digits := ""
	for i in range(s.length() - 1, -1, -1):
		if s[i] >= "0" and s[i] <= "9":
			digits = s[i] + digits
		else:
			break
	return int(digits) if not digits.is_empty() else -1

func _refresh_patch_list(select: String = "") -> void:
	_patch_list.clear()
	var d := DirAccess.open(PATCH_DIR)
	if d == null:
		return
	for fn in d.get_files():
		if fn.ends_with(".json"):
			_patch_list.add_item(fn.get_basename())
	for i in _patch_list.item_count:
		if _patch_list.get_item_text(i) == select:
			_patch_list.selected = i

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

	var cap_state: Dictionary = _solver.get_cap_state() if _ok else {}
	_solver.build(res["netlist"], "gnd")
	_solver.set_dt(1.0 / SR)
	_solver.set_cap_state(cap_state)  # carry unchanged caps' charge across the rebuild
	_out_pos = res["out_pos"]
	_out_neg = res["out_neg"]
	_source_names.clear()
	for p in _canvas.parts:
		if p.part_type == "source":
			_source_names.append(p.pname)
	_ok = true
	_status = "compiled: %d nodes, %d components  [%s]" % [
		res["num_nodes"], res["netlist"].size(), "Rust" if _using_rust else "GDScript"]

func _part_desc(part: Circuit4Part) -> String:
	match part.part_type:
		"resistor": return "%s  %s" % [part.pname, part.value_text()]
		"capacitor": return "%s  %s" % [part.pname, part.value_text()]
		_: return "%s  (no value -- Drive/Freq below)" % part.pname

func _on_selection_changed(part: Circuit4Part) -> void:
	if part == null:
		_sel_label.text = "drag a part's knob to set its value  (click a part, Delete removes it)"
		return
	_sel_label.text = _part_desc(part)

func _on_part_value_changed(part: Circuit4Part) -> void:
	_solver.set_value(part.pname, part.value)
	if _canvas.selected == part:
		_sel_label.text = _part_desc(part)

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
			var vin := _drive * saw
			for sn in _source_names:
				_solver.set_source(sn, vin)
			_solver.step()
			out_v = _solver.node_voltage(_out_pos) - _solver.node_voltage(_out_neg)
		var s := clampf(out_v * inv_drive, -1.0, 1.0)
		_playback.push_frame(Vector2(s, s) if _ok else Vector2.ZERO)
		_scope_in[_sidx] = clampf(saw, -1.0, 1.0)
		_scope_out[_sidx] = s if _ok else 0.0
		_sidx = (_sidx + 1) % SCOPE_SAMPLES
