class_name Circuit4Canvas
extends Control

## Owns the wiring between Circuit4Part terminals and compiles the result
## into an MnaSolverRs netlist. A node is a set of terminals joined by
## wires (union-find); the set containing any ground terminal is "gnd".

signal topology_changed
signal selection_changed(part: Circuit4Part)
signal part_value_changed(part: Circuit4Part)

const WIRE_HIT := 8.0
const TKEY := 3   # terminal-key stride (max terminals on any part)

var parts: Array[Circuit4Part] = []
var wires: Array = []          # [{a=[part,term], b=[part,term]}]
var selected: Circuit4Part = null

var _pending := {}             # {} or {part=Circuit4Part, term=int}
var _name_of := {}             # union-find root -> node name (rebuilt each compile)
var _ncount := 0
var _hover_wire := -1          # index of the wire under the cursor (delete on click)

func register_part(p: Circuit4Part) -> void:
	parts.append(p)
	p.terminal_pressed.connect(_on_terminal_pressed)
	p.body_selected.connect(_on_body_selected)
	p.value_changed.connect(func(pt): part_value_changed.emit(pt))
	p.moved.connect(queue_redraw)

func clear_all() -> void:
	for p in parts:
		p.queue_free()
	parts.clear()
	wires.clear()
	selected = null
	_pending = {}
	queue_redraw()

func remove_part(p: Circuit4Part) -> void:
	wires = wires.filter(func(w): return w["a"][0] != p and w["b"][0] != p)
	parts.erase(p)
	if not _pending.is_empty() and _pending["part"] == p:
		_pending = {}
	if selected == p:
		selected = null
		selection_changed.emit(null)
	p.queue_free()
	topology_changed.emit()
	queue_redraw()

func _on_body_selected(p: Circuit4Part) -> void:
	if selected == p:
		return
	if selected:
		selected.selected = false
		selected.queue_redraw()
	selected = p
	p.selected = true
	p.queue_redraw()
	selection_changed.emit(p)

func _on_terminal_pressed(part: Circuit4Part, term: int) -> void:
	if _pending.is_empty():
		_pending = {"part": part, "term": term}
		queue_redraw()
		return
	if _pending["part"] == part and _pending["term"] == term:
		_pending = {}
		queue_redraw()
		return
	if _pending["part"] == part:
		# same part, other terminal -- move the pending end instead of shorting it
		_pending = {"part": part, "term": term}
		queue_redraw()
		return
	wires.append({"a": [_pending["part"], _pending["term"]], "b": [part, term]})
	_pending = {}
	topology_changed.emit()
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not _pending.is_empty():
			_pending = {}
			queue_redraw()
		else:
			_delete_wire_near(event.position)
	elif event is InputEventMouseMotion and _pending.is_empty():
		var h := _wire_near(event.position)
		if h != _hover_wire:
			_hover_wire = h
			queue_redraw()

func _process(_delta: float) -> void:
	if not _pending.is_empty():
		queue_redraw()  # keep the rubber-band line tracking the mouse (spike #2 fix)

func _wire_near(p: Vector2) -> int:
	for i in range(wires.size() - 1, -1, -1):
		var w = wires[i]
		var a: Vector2 = w["a"][0].term_global_pos(w["a"][1]) - global_position
		var b: Vector2 = w["b"][0].term_global_pos(w["b"][1]) - global_position
		if _dist_to_seg(p, a, b) <= WIRE_HIT:
			return i
	return -1

func _delete_wire_near(p: Vector2) -> void:
	var i := _wire_near(p)
	if i != -1:
		wires.remove_at(i)
		_hover_wire = -1
		topology_changed.emit()
		queue_redraw()

func _dist_to_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := 0.0
	if ab.length_squared() > 1e-6:
		t = clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)

# --- netlist compilation ------------------------------------------------

func _uf_find(uf: Dictionary, x: int) -> int:
	while uf[x] != x:
		uf[x] = uf[uf[x]]
		x = uf[x]
	return x

func _node_name(uf: Dictionary, key: int, ground_roots: Dictionary) -> String:
	var r := _uf_find(uf, key)
	if ground_roots.has(r):
		return "gnd"
	if not _name_of.has(r):
		_name_of[r] = "n%d" % _ncount
		_ncount += 1
	return _name_of[r]

## -> {ok, netlist, out_pos, out_neg, num_nodes, error}
func compile_netlist() -> Dictionary:
	_name_of.clear()
	_ncount = 0
	var uf := {}
	for pi in parts.size():
		for t in parts[pi].term_count():
			var k := pi * TKEY + t
			uf[k] = k
	for w in wires:
		var ka: int = parts.find(w["a"][0]) * TKEY + w["a"][1]
		var kb: int = parts.find(w["b"][0]) * TKEY + w["b"][1]
		uf[_uf_find(uf, ka)] = _uf_find(uf, kb)

	var ground_roots := {}
	for pi in parts.size():
		if parts[pi].part_type == "ground":
			ground_roots[_uf_find(uf, pi * TKEY)] = true

	var netlist := []
	var out_pos := ""
	var out_neg := ""
	var has_source := false
	for pi in parts.size():
		var p := parts[pi]
		var nn := PackedStringArray()
		for t in 3:
			nn.append(_node_name(uf, pi * TKEY + t, ground_roots) if t < p.term_count() else "gnd")
		match p.part_type:
			"resistor":
				netlist.append({"type": "R", "name": p.pname, "nodes": [nn[0], nn[1]], "value": p.value})
			"capacitor":
				netlist.append({"type": "C", "name": p.pname, "nodes": [nn[0], nn[1]], "value": p.value})
			"diode":
				netlist.append({"type": "D", "nodes": [nn[0], nn[1]]})
			"transistor":
				netlist.append({"type": "Q", "nodes": [nn[0], nn[1], nn[2]]})  # collector, base, emitter
			"source":
				netlist.append({"type": "V", "name": p.pname, "nodes": [nn[0], nn[1]], "value": 0.0})
				has_source = true
			"output":
				out_pos = nn[0]
				out_neg = nn[1]
			"ground":
				pass

	if not has_source:
		return {"ok": false, "error": "no source placed/necessary"}
	if ground_roots.is_empty():
		return {"ok": false, "error": "no ground wired"}
	if out_pos == "":
		return {"ok": false, "error": "no output probe"}
	if out_pos == out_neg:
		return {"ok": false, "error": "output probe shorted"}
	return {
		"ok": true, "netlist": netlist, "out_pos": out_pos, "out_neg": out_neg,
		"num_nodes": _ncount,
	}

# --- drawing ----------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.07, 0.09))
	for i in wires.size():
		var w = wires[i]
		var a: Vector2 = w["a"][0].term_global_pos(w["a"][1]) - global_position
		var b: Vector2 = w["b"][0].term_global_pos(w["b"][1]) - global_position
		var col := Color(0.95, 0.4, 0.4) if i == _hover_wire else Color(0.82, 0.84, 0.9)
		var wide := 3.0 if i == _hover_wire else 2.5
		draw_line(a, b, col, wide)
		draw_circle(a, 3.0, col)
		draw_circle(b, 3.0, col)
	if not _pending.is_empty():
		var p: Circuit4Part = _pending["part"]
		var a: Vector2 = p.term_global_pos(_pending["term"]) - global_position
		draw_line(a, get_local_mouse_position(), Color(0.9, 0.8, 0.35, 0.7), 2.0)
