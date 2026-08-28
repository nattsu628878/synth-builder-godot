extends Control

## Game-slice host (see nattsu-hub/projects/synth-builder-godot.md, North
## Star): arrange parts from the palette, wire their terminals, and the
## wiring is compiled to a netlist, solved by MnaSolverRs every sample,
## and heard + shown on the scope. Pick a Target and a reference circuit
## (solved by a second engine instance in parallel) is drawn as a ghost
## trace; match it -- hold >=92% for ~0.7s -- to SOLVE it.

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

# --- waveform-match challenges (North Star) ---
# Each target is a small reference circuit, solved by a 2nd engine instance
# in parallel with the player's, so the target is reachable by construction
# and level-comparable. netlist parts are palette parts only. `hint` is the
# wiring the "reveal" shows on solve.
const CHALLENGES := [
	{
		"name": "RC low-pass", "freq": 220.0, "drive": 1.5, "out_pos": "out", "out_neg": "gnd",
		"need": "needs: 1 resistor + 1 capacitor   —   SRC → R → OUT,  C from OUT to GND",
		"hint": "SRC → R(10k) → OUT ;  C(22nF) OUT → GND",
		"netlist": [
			{"type": "V", "name": "vin", "nodes": ["in", "gnd"], "value": 0.0},
			{"type": "R", "nodes": ["in", "out"], "value": 10000.0},
			{"type": "C", "nodes": ["out", "gnd"], "value": 22.0e-9},
		],
	},
	{
		"name": "diode soft-clip", "freq": 220.0, "drive": 2.5, "out_pos": "out", "out_neg": "gnd",
		"need": "needs: 1 resistor + 2 diodes   —   SRC → R → OUT,  two diodes OUT↔GND facing opposite ways",
		"hint": "SRC → R(4.7k) → OUT ;  two diodes OUT↔GND (anti-parallel)",
		"netlist": [
			{"type": "V", "name": "vin", "nodes": ["in", "gnd"], "value": 0.0},
			{"type": "R", "nodes": ["in", "out"], "value": 4700.0},
			{"type": "D", "nodes": ["out", "gnd"]},
			{"type": "D", "nodes": ["gnd", "out"]},
		],
	},
	{
		"name": "half-wave rectify", "freq": 220.0, "drive": 2.5, "out_pos": "out", "out_neg": "gnd",
		"need": "needs: 1 diode + 1 resistor   —   SRC → diode → OUT,  R from OUT to GND",
		"hint": "SRC → diode → OUT ;  R(10k) OUT → GND",
		"netlist": [
			{"type": "V", "name": "vin", "nodes": ["in", "gnd"], "value": 0.0},
			{"type": "D", "nodes": ["in", "out"]},
			{"type": "R", "nodes": ["out", "gnd"], "value": 10000.0},
		],
	},
]
const WIN_MATCH := 0.92
const WIN_DROP := 0.88      # hysteresis: hold-timer only resets below this
const WIN_HOLD_SEC := 0.7   # wall-clock time above WIN_MATCH to latch a solve

var _target := PackedFloat32Array()
var _target_kind := 0          # 0 = off, else CHALLENGES[_target_kind - 1]
var _ref_solver: Object        # 2nd engine instance for the reference circuit
var _match := 0.0              # smoothed level match, 0..1
var _shape := 0.0             # smoothed match with a best-fit gain removed
var _win_time := 0.0
var _solved := false
var _solved_set: Array = [false, false, false]  # per-challenge, kept for the session
var _solve_fx := false     # rising-edge flag: fire the solve cue once
var _value_edit: LineEdit
var _edit_target: Circuit4Part
var _beep_t := 0.0         # remaining seconds of the solve chime
var _beep_phase := 0.0

var _count := {"resistor": 0, "capacitor": 0, "diode": 0, "transistor": 0, "ota": 0, "source": 0, "ground": 0, "output": 0}
var _spawn_i := 0

const DEFAULTS := {"resistor": 4700.0, "capacitor": 1.0e-8, "ota": 1.0e-6}
const ABBR := {
	"resistor": "R", "capacitor": "C", "diode": "D", "transistor": "Q", "ota": "OTA",
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
# patch save/load is dev-bench only; game.tscn omits these nodes
@onready var _patch_name: LineEdit = get_node_or_null("%PatchName")
@onready var _patch_list: OptionButton = get_node_or_null("%PatchList")
@onready var _save_btn: Button = get_node_or_null("%SaveBtn")
@onready var _load_btn: Button = get_node_or_null("%LoadBtn")
@onready var _target_option: OptionButton = %TargetOption
@onready var _next_btn: Button = %NextBtn
@onready var _need_label: Label = %NeedLabel
@onready var _match_meter: MatchMeter = %MatchMeter

var _playback: AudioStreamGeneratorPlayback

func _ready() -> void:
	_scope_in.resize(SCOPE_SAMPLES)
	_scope_out.resize(SCOPE_SAMPLES)
	_target.resize(SCOPE_SAMPLES)
	var win := get_window()
	if win:
		win.min_size = Vector2i(720, 480)  # content scrolls (game.tscn wraps in a ScrollContainer)

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
	_canvas.part_edit_requested.connect(_on_part_edit_requested)
	_value_edit = LineEdit.new()
	_value_edit.custom_minimum_size = Vector2(96, 0)
	_value_edit.visible = false
	_value_edit.text_submitted.connect(_on_value_edit_submitted)
	_value_edit.focus_exited.connect(func(): _value_edit.visible = false)
	_canvas.add_child(_value_edit)
	_sel_label.text = "drag a part's knob to set its value  (click a part, Delete removes it)"

	if _save_btn:
		_save_btn.pressed.connect(_save_patch)
		_load_btn.pressed.connect(_load_patch)
		DirAccess.make_dir_recursive_absolute(PATCH_DIR)
		_refresh_patch_list()

	_target_option.clear()
	_target_option.add_item("off")
	for ch in CHALLENGES:
		_target_option.add_item(ch["name"])
	_target_option.item_selected.connect(_on_target_selected)
	_next_btn.pressed.connect(_on_next_pressed)
	_on_target_selected(0)

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
			if _canvas.selected and not (_patch_name and _patch_name.has_focus()):
				_canvas.remove_part(_canvas.selected)
				get_viewport().set_input_as_handled()

# --- patch save / load (JSON, user://patches/) --------------------------

func _patch_path(name: String) -> String:
	return "%s/%s.json" % [PATCH_DIR, name.strip_edges()]

func _save_patch() -> void:
	if _patch_name == null:
		return
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
	if _patch_list == null or _patch_list.item_count == 0:
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
	if _patch_list == null:
		return
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
		"transistor": return "%s  NPN (terminals: C top, B left, E bottom)" % part.pname
		"ota": return "%s  Iabc %s  (knob sets cutoff)" % [part.pname, part.value_text()]
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

## double-click a knob -> a small field to type an exact value (accepts
## "4700", "4.7k", "10n", "1e-6", "3u" ...)
func _on_part_edit_requested(part: Circuit4Part) -> void:
	_edit_target = part
	_value_edit.text = part.value_text().trim_suffix("ohm").trim_suffix("F").trim_suffix("A")
	_value_edit.position = part.position + Vector2(0.0, part.size.y + 3.0)
	_value_edit.visible = true
	_value_edit.grab_focus()
	_value_edit.select_all()

func _on_value_edit_submitted(txt: String) -> void:
	_value_edit.visible = false
	var v := _parse_si(txt)
	if _edit_target != null and is_finite(v) and v > 0.0:
		var r: Array = Circuit4Part.VRANGE.get(_edit_target.part_type, [v, v])
		v = clampf(v, r[0], r[1])
		_edit_target.value = v
		_solver.set_value(_edit_target.pname, v)
		_edit_target.queue_redraw()
		if _canvas.selected == _edit_target:
			_sel_label.text = _part_desc(_edit_target)

func _parse_si(s: String) -> float:
	s = s.strip_edges().to_lower()
	var mult := 1.0
	for suf in [["meg", 1.0e6], ["k", 1.0e3], ["g", 1.0e9], ["m", 1.0e-3],
			["u", 1.0e-6], ["µ", 1.0e-6], ["n", 1.0e-9], ["p", 1.0e-12]]:
		if s.ends_with(suf[0]):
			mult = suf[1]
			s = s.substr(0, s.length() - String(suf[0]).length())
			break
	return s.to_float() * mult if s.is_valid_float() else NAN

func _process(_delta: float) -> void:
	_freq = _freq_slider.value
	_drive = _drive_slider.value
	_fill_audio()  # advances _match/_shape and the win latch on the audio clock
	_scope.set_data(_scope_in, _scope_out)
	_scope.set_target(_target, _target_kind > 0)
	_scope.queue_redraw()
	_status_label.text = _status

	if _solve_fx:  # rising edge of _solved
		_solve_fx = false
		_beep_t = 0.18
		_beep_phase = 0.0  # start the chime from zero so repeat solves don't click
		if _target_kind >= 1:
			_solved_set[_target_kind - 1] = true
		_match_meter.pulse()
		_need_label.text = "SOLVED ✓   reference:  %s" % CHALLENGES[_target_kind - 1]["hint"]
	_match_meter.set_progress(_solved_set, _target_kind)
	_match_meter.set_state(_match, _shape, _win_time / WIN_HOLD_SEC, _solved, _target_kind > 0)

func _on_next_pressed() -> void:
	if _target_kind == 0:
		return
	var nx := (_target_kind % CHALLENGES.size()) + 1  # 1 -> 2 -> 3 -> 1
	_target_option.select(nx)
	_on_target_selected(nx)

func _on_target_selected(idx: int) -> void:
	_target_kind = idx
	_match = 0.0
	_shape = 0.0
	_win_time = 0.0
	_solved = false
	_target.fill(0.0)
	_next_btn.visible = idx > 0
	if idx == 0:
		_need_label.text = ""
		_freq_slider.editable = true
		_drive_slider.editable = true
		_ref_solver = null
		return
	var ch: Dictionary = CHALLENGES[idx - 1]
	_need_label.text = ch["need"]
	_ref_solver = ClassDB.instantiate(RUST_CLASS) if _using_rust else preload("res://mna_solver.gd").new()
	_ref_solver.build(ch["netlist"], "gnd")
	_ref_solver.set_dt(1.0 / SR)
	# both circuits must see identical vin, so pin the drive controls
	_freq_slider.value = ch["freq"]
	_drive_slider.value = ch["drive"]
	_freq_slider.editable = false
	_drive_slider.editable = false

func _fill_audio() -> void:
	if _playback == null:
		return
	var frames := _playback.get_frames_available()
	var inv_drive := 1.0 / maxf(_drive, 0.01)
	var step := _freq / SR
	var challenge: bool = _target_kind > 0 and _ref_solver != null
	var ref_src := ""
	var ref_pos := ""
	var ref_neg := ""
	if challenge:
		var ch: Dictionary = CHALLENGES[_target_kind - 1]
		ref_src = "vin"
		ref_pos = ch["out_pos"]
		ref_neg = ch["out_neg"]
	var err2 := 0.0    # Σ (s - tgt)^2
	var ref2 := 0.0   # Σ tgt^2
	var so2 := 0.0     # Σ s^2         (for the best-fit gain)
	var sot := 0.0     # Σ s·tgt
	for _i in frames:
		_phase += step
		if _phase >= 1.0:
			_phase -= 1.0
		var saw := 2.0 * _phase - 1.0
		var vin := _drive * saw
		var out_v := 0.0
		if _ok:
			for sn in _source_names:
				_solver.set_source(sn, vin)
			_solver.step()
			out_v = _solver.node_voltage(_out_pos) - _solver.node_voltage(_out_neg)
		var s := clampf(out_v * inv_drive, -1.0, 1.0) if _ok else 0.0

		var tgt := 0.0
		if challenge:
			_ref_solver.set_source(ref_src, vin)
			_ref_solver.step()
			tgt = clampf((_ref_solver.node_voltage(ref_pos) - _ref_solver.node_voltage(ref_neg)) * inv_drive, -1.0, 1.0)

		var out_sample := s
		if _beep_t > 0.0:  # short decaying chime on solve
			_beep_phase += 880.0 / SR
			out_sample = clampf(s * 0.4 + sin(_beep_phase * TAU) * 0.35 * (_beep_t / 0.18), -1.0, 1.0)
			_beep_t = maxf(_beep_t - 1.0 / SR, 0.0)
		_playback.push_frame(Vector2(out_sample, out_sample))
		_scope_in[_sidx] = clampf(saw, -1.0, 1.0)
		_scope_out[_sidx] = s
		_target[_sidx] = tgt
		_sidx = (_sidx + 1) % SCOPE_SAMPLES
		if challenge:
			var e := s - tgt
			err2 += e * e
			ref2 += tgt * tgt
			so2 += s * s
			sot += s * tgt

	if challenge and frames > 0:
		var block_match := clampf(1.0 - sqrt(err2 / maxf(ref2, 1.0e-6)), 0.0, 1.0)
		# shape score: remove the least-squares gain that maps s onto tgt.
		# k is floored at 0 so a wrong-polarity circuit gets no shape credit.
		var k := maxf(sot / maxf(so2, 1.0e-9), 0.0)
		var shape_err2 := ref2 - 2.0 * k * sot + k * k * so2  # = Σ (k·s - tgt)^2
		var block_shape := clampf(1.0 - sqrt(maxf(shape_err2, 0.0) / maxf(ref2, 1.0e-6)), 0.0, 1.0)
		_match += 0.15 * (block_match - _match)
		_shape += 0.15 * (block_shape - _shape)
		# win latch on the audio clock (immune to fps and to buffer stalls)
		if not _solved:
			if _match >= WIN_MATCH:
				_win_time += float(frames) / SR
				if _win_time >= WIN_HOLD_SEC:
					_solved = true
					_solve_fx = true
			elif _match < WIN_DROP:
				_win_time = 0.0
