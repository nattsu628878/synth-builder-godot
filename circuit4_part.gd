class_name Circuit4Part
extends PanelContainer

## Spike #4 (see nattsu-hub/projects/synth-builder-godot.md): a plain
## 2-terminal component (ground has 1). Terminals are wired together at
## nodes by Circuit4Canvas, which compiles the whole thing into a netlist
## for MnaSolverRs. Draws its own schematic glyph + name + value.

signal terminal_pressed(part: Circuit4Part, term: int)
signal body_selected(part: Circuit4Part)
signal value_changed(part: Circuit4Part)
signal moved

const TERM_RADIUS := 7.0
const TERM_HIT := 13.0
const KNOB_R := 10.0
const KNOB_SWEEP := 2.35   # radians each side of straight-down
const KNOB_SENS := 0.006   # value-normalised units per pixel of vertical drag

# parts with an editable value get an on-board knob; [min, max] on a log scale
const VRANGE := {
	"resistor": [100.0, 100000.0],
	"capacitor": [1.0e-9, 1.0e-6],
	"ota": [1.0e-8, 1.0e-5],   # OTA bias current Iabc (sets cutoff)
}

@export var part_type := ""   # source | resistor | capacitor | diode | ground | output
@export var value := 0.0

var pname := ""
var selected := false

var _dragging := false
var _knob_drag := false
var _hover_term := -1

func has_knob() -> bool:
	return VRANGE.has(part_type)

func _knob_center() -> Vector2:
	return Vector2(size.x - 15.0, size.y - 13.0)

func _value_norm() -> float:
	var r: Array = VRANGE[part_type]
	var lo := log(float(r[0]))
	var hi := log(float(r[1]))
	return clampf((log(value) - lo) / (hi - lo), 0.0, 1.0)

func _set_norm(t: float) -> void:
	var r: Array = VRANGE[part_type]
	value = exp(lerpf(log(float(r[0])), log(float(r[1])), clampf(t, 0.0, 1.0)))

func term_count() -> int:
	match part_type:
		"ground": return 1
		"transistor", "ota": return 3
		_: return 2

func term_local_pos(i: int) -> Vector2:
	match part_type:
		"ground":
			return Vector2(size.x * 0.5, size.y)
		"transistor":
			# 0 = collector (top-right), 1 = base (left), 2 = emitter (bottom-right)
			match i:
				0: return Vector2(size.x, size.y * 0.22)
				1: return Vector2(0.0, size.y * 0.5)
				_: return Vector2(size.x, size.y * 0.78)
		"ota":
			# 0 = out (right), 1 = in+ (top-left), 2 = in- (bottom-left)
			match i:
				0: return Vector2(size.x, size.y * 0.5)
				1: return Vector2(0.0, size.y * 0.28)
				_: return Vector2(0.0, size.y * 0.72)
		_:
			return Vector2(0.0, size.y * 0.5) if i == 0 else Vector2(size.x, size.y * 0.5)

func term_global_pos(i: int) -> Vector2:
	return global_position + term_local_pos(i)

## The edge terminals stick out past the panel rect; widen the hit area so
## their outer half still reaches _gui_input (same fix as spike #2).
func _has_point(point: Vector2) -> bool:
	var m := TERM_HIT
	return point.x >= -m and point.x <= size.x + m and point.y >= -m and point.y <= size.y + m

func _term_at(local_pos: Vector2) -> int:
	for i in term_count():
		if local_pos.distance_to(term_local_pos(i)) <= TERM_HIT:
			return i
	return -1

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var t := _term_at(event.position)
			if t != -1:
				terminal_pressed.emit(self, t)
				accept_event()
				return
			if has_knob() and event.position.distance_to(_knob_center()) <= KNOB_R + 4.0:
				_knob_drag = true
				body_selected.emit(self)
				accept_event()
				return
			_dragging = true
			body_selected.emit(self)
			accept_event()
		else:
			_dragging = false
			_knob_drag = false
	elif event is InputEventMouseMotion:
		if _knob_drag:
			_set_norm(_value_norm() - event.relative.y * KNOB_SENS)  # drag up = more
			value_changed.emit(self)
			queue_redraw()
			accept_event()
		elif _dragging:
			position += event.relative
			moved.emit()
			accept_event()
		else:
			var h := _term_at(event.position)
			if h != _hover_term:
				_hover_term = h
				queue_redraw()

# --- drawing --------------------------------------------------------------

func value_text() -> String:
	match part_type:
		"resistor": return _fmt_si(value, "ohm")
		"capacitor": return _fmt_si(value, "F")
		"ota": return _fmt_si(value, "A")
		_: return ""

func _fmt_si(v: float, unit: String) -> String:
	var prefixes := [["G", 1e9], ["M", 1e6], ["k", 1e3], ["", 1.0], ["m", 1e-3], ["u", 1e-6], ["n", 1e-9], ["p", 1e-12]]
	for pr in prefixes:
		if absf(v) >= pr[1]:
			var scaled: float = v / pr[1]
			var s := ("%.0f" % scaled) if scaled >= 100.0 else ("%.1f" % scaled)
			return "%s%s%s" % [s, pr[0], unit]
	return "%g%s" % [v, unit]

func _draw() -> void:
	var mid := size.y * 0.5
	var fg := Color(0.82, 0.86, 0.92)
	var accent := Color(0.55, 0.8, 1.0)

	if selected:
		draw_rect(Rect2(Vector2.ZERO, size), Color(1.0, 0.85, 0.3), false, 2.0)

	# leads from each terminal toward the glyph
	if part_type != "ground" and part_type != "transistor" and part_type != "ota":
		draw_line(Vector2(0, mid), Vector2(size.x * 0.32, mid), fg, 2.0)
		draw_line(Vector2(size.x * 0.68, mid), Vector2(size.x, mid), fg, 2.0)

	match part_type:
		"resistor": _draw_resistor(mid, fg)
		"capacitor": _draw_capacitor(mid, fg)
		"diode": _draw_diode(mid, fg)
		"transistor": _draw_transistor(fg)
		"ota": _draw_ota(fg, accent)
		"source": _draw_source(mid, accent)
		"ground": _draw_ground(fg)
		"output": _draw_output(mid, accent)

	var font := get_theme_default_font()
	var fs := 11
	draw_string(font, Vector2(4, 12), pname, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.7, 0.75, 0.8))
	var vt := value_text()
	if vt != "":
		draw_string(font, Vector2(4, size.y - 4), vt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.75, 0.8, 0.55))

	if has_knob():
		var kc := _knob_center()
		draw_arc(kc, KNOB_R, 0.0, TAU, 18, Color(0.55, 0.6, 0.68), 2.0)
		var a: float = -PI / 2.0 + lerpf(-KNOB_SWEEP, KNOB_SWEEP, _value_norm())
		draw_line(kc, kc + Vector2(cos(a), sin(a)) * (KNOB_R - 2.0), Color(1.0, 0.85, 0.4), 2.5)

	# terminals
	for i in term_count():
		var c := Color(0.5, 0.78, 1.0)
		if i == _hover_term:
			c = Color(0.85, 0.95, 1.0)
		draw_circle(term_local_pos(i), TERM_RADIUS, c)

func _draw_resistor(mid: float, col: Color) -> void:
	var x0 := size.x * 0.32
	var x1 := size.x * 0.68
	var n := 6
	var pts := PackedVector2Array()
	pts.append(Vector2(x0, mid))
	for i in n:
		var x: float = x0 + (x1 - x0) * float(i + 1) / float(n + 1)
		pts.append(Vector2(x, mid + (8.0 if i % 2 == 0 else -8.0)))
	pts.append(Vector2(x1, mid))
	draw_polyline(pts, col, 2.0)

func _draw_capacitor(mid: float, col: Color) -> void:
	var cx := size.x * 0.5
	draw_line(Vector2(cx - 5, mid - 12), Vector2(cx - 5, mid + 12), col, 2.5)
	draw_line(Vector2(cx + 5, mid - 12), Vector2(cx + 5, mid + 12), col, 2.5)
	draw_line(Vector2(size.x * 0.32, mid), Vector2(cx - 5, mid), col, 2.0)
	draw_line(Vector2(cx + 5, mid), Vector2(size.x * 0.68, mid), col, 2.0)

func _draw_diode(mid: float, col: Color) -> void:
	var x0 := size.x * 0.4
	var x1 := size.x * 0.6
	var tri := PackedVector2Array([
		Vector2(x0, mid - 10), Vector2(x0, mid + 10), Vector2(x1, mid)])
	draw_colored_polygon(tri, col)
	draw_line(Vector2(x1, mid - 10), Vector2(x1, mid + 10), col, 2.5)

func _draw_ota(col: Color, accent: Color) -> void:
	var ax := size.x * 0.28
	var bx := size.x * 0.80
	var top := size.y * 0.16
	var bot := size.y * 0.84
	var tri := PackedVector2Array([Vector2(ax, top), Vector2(ax, bot), Vector2(bx, size.y * 0.5)])
	draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]), col, 2.0)
	draw_line(term_local_pos(1), Vector2(ax, size.y * 0.28), col, 2.0)
	draw_line(term_local_pos(2), Vector2(ax, size.y * 0.72), col, 2.0)
	draw_line(Vector2(bx, size.y * 0.5), term_local_pos(0), col, 2.0)
	var font := get_theme_default_font()
	draw_string(font, Vector2(ax + 4, size.y * 0.32), "+", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, accent)
	draw_string(font, Vector2(ax + 4, size.y * 0.80), "−", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, accent)

func _draw_transistor(col: Color) -> void:
	var bx := size.x * 0.42
	var bt := size.y * 0.30
	var bb := size.y * 0.70
	draw_line(Vector2(bx, bt), Vector2(bx, bb), col, 3.0)              # base bar
	draw_line(term_local_pos(1), Vector2(bx, size.y * 0.5), col, 2.0)  # base lead
	var cj := Vector2(bx, size.y * 0.40)
	var ej := Vector2(bx, size.y * 0.60)
	draw_line(cj, term_local_pos(0), col, 2.0)                        # collector
	draw_line(ej, term_local_pos(2), col, 2.0)                        # emitter
	# NPN: arrowhead on the emitter lead pointing away from the base
	var dir := (term_local_pos(2) - ej).normalized()
	var tip := ej + dir * 12.0
	var n := Vector2(-dir.y, dir.x)
	draw_colored_polygon(PackedVector2Array([
		tip, tip - dir * 6.0 + n * 4.0, tip - dir * 6.0 - n * 4.0]), col)

func _draw_source(mid: float, col: Color) -> void:
	var cx := size.x * 0.5
	draw_arc(Vector2(cx, mid), 14.0, 0.0, TAU, 24, col, 2.0)
	var w := PackedVector2Array()
	for i in 17:
		var t: float = float(i) / 16.0
		w.append(Vector2(cx - 9 + 18 * t, mid - sin(t * TAU) * 6.0))
	draw_polyline(w, col, 2.0)

func _draw_ground(col: Color) -> void:
	var cx := size.x * 0.5
	var y := size.y * 0.5
	draw_line(Vector2(cx, y), Vector2(cx, size.y), col, 2.0)
	draw_line(Vector2(cx - 12, size.y - 10), Vector2(cx + 12, size.y - 10), col, 2.0)
	draw_line(Vector2(cx - 8, size.y - 5), Vector2(cx + 8, size.y - 5), col, 2.0)
	draw_line(Vector2(cx - 4, size.y), Vector2(cx + 4, size.y), col, 2.0)

func _draw_output(mid: float, col: Color) -> void:
	var cx := size.x * 0.5
	draw_arc(Vector2(cx, mid), 13.0, 0.0, TAU, 20, col, 2.0)
	draw_string(get_theme_default_font(), Vector2(cx - 5, mid + 5), "V", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, col)
