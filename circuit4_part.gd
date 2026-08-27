class_name Circuit4Part
extends PanelContainer

## Spike #4 (see nattsu-hub/projects/synth-builder-godot.md): unlike
## spike #2's "block with one in / one out port", a part here is a plain
## 2-terminal component (ground has 1). Terminals are wired together at
## nodes by Circuit4Canvas, which compiles the whole thing into a netlist
## for MnaSolverRs. Throwaway UI.

signal terminal_pressed(part: Circuit4Part, term: int)
signal body_selected(part: Circuit4Part)
signal moved

const TERM_RADIUS := 8.0
const TERM_HIT := 13.0

@export var part_type := ""   # source | resistor | capacitor | diode | ground | output
@export var value := 0.0

var pname := ""               # stable netlist id, assigned by the main scene
var selected := false

var _dragging := false
var _press_pos := Vector2.ZERO
var _hover_term := -1

func term_count() -> int:
	return 1 if part_type == "ground" else 2

func term_local_pos(i: int) -> Vector2:
	if part_type == "ground":
		return Vector2(size.x * 0.5, size.y)
	return Vector2(0.0, size.y * 0.5) if i == 0 else Vector2(size.x, size.y * 0.5)

func term_global_pos(i: int) -> Vector2:
	return global_position + term_local_pos(i)

## Two of the terminals sit on the panel edge; extend the hit rect so the
## outer half of each still reaches _gui_input (same fix as spike #2).
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
			_dragging = true
			_press_pos = event.position
			body_selected.emit(self)
			accept_event()
		else:
			_dragging = false
	elif event is InputEventMouseMotion:
		if _dragging:
			position += event.relative
			moved.emit()
			accept_event()
		else:
			var h := _term_at(event.position)
			if h != _hover_term:
				_hover_term = h
				queue_redraw()

func _draw() -> void:
	if selected:
		draw_rect(Rect2(Vector2.ZERO, size), Color(1.0, 0.85, 0.3), false, 2.0)
	for i in term_count():
		var c := Color(0.55, 0.8, 1.0)
		if i == _hover_term:
			c = Color(0.85, 0.95, 1.0)
		draw_circle(term_local_pos(i), TERM_RADIUS, c)
