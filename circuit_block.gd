class_name CircuitBlock
extends PanelContainer

## A single draggable block on the CircuitCanvas. Has at most one input
## port (left edge) and one output port (right edge), drawn as circles.
## "source" has no input port, "output" has no output port.

signal moved
signal port_pressed(is_output: bool)

const PORT_RADIUS := 10.0
const PORT_HIT_MARGIN := 10.0  # extra click tolerance beyond the drawn radius

@export var block_type: String = ""  # "source" | "rc" | "output"

var _dragging: bool = false
var _hover_port: int = 0  # -1 = input, 1 = output, 0 = none (for visual feedback)

func get_output_port_global_pos() -> Vector2:
	return global_position + Vector2(size.x, size.y * 0.5)

func get_input_port_global_pos() -> Vector2:
	return global_position + Vector2(0, size.y * 0.5)

## Ports are drawn ON the block's edge, so half of each circle sits
## outside the PanelContainer's own rect. Without this override, clicks
## aimed at that outer half never reach _gui_input at all -- they fall
## through to whatever is behind the block instead.
func _has_point(point: Vector2) -> bool:
	var m := PORT_RADIUS + PORT_HIT_MARGIN
	return point.x >= -m and point.x <= size.x + m and point.y >= -m and point.y <= size.y + m

func _port_at(local_pos: Vector2) -> int:
	var hit_radius := PORT_RADIUS + PORT_HIT_MARGIN
	if block_type != "source":
		var in_local := Vector2(0.0, size.y * 0.5)
		if local_pos.distance_to(in_local) <= hit_radius:
			return -1
	if block_type != "output":
		var out_local := Vector2(size.x, size.y * 0.5)
		if local_pos.distance_to(out_local) <= hit_radius:
			return 1
	return 0

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var hit := _port_at(event.position)
			if hit == -1:
				port_pressed.emit(false)
				accept_event()
				return
			if hit == 1:
				port_pressed.emit(true)
				accept_event()
				return
			_dragging = true
			accept_event()
		else:
			_dragging = false
	elif event is InputEventMouseMotion:
		if _dragging:
			position += event.relative
			moved.emit()
			accept_event()
		else:
			var new_hover := _port_at(event.position)
			if new_hover != _hover_port:
				_hover_port = new_hover
				queue_redraw()

func _draw() -> void:
	if block_type != "source":
		var c := Color(0.95, 0.85, 0.3)
		if _hover_port == -1:
			c = Color(1.0, 1.0, 0.6)
		draw_circle(Vector2(0.0, size.y * 0.5), PORT_RADIUS, c)
	if block_type != "output":
		var c := Color(0.4, 0.75, 1.0)
		if _hover_port == 1:
			c = Color(0.7, 0.9, 1.0)
		draw_circle(Vector2(size.x, size.y * 0.5), PORT_RADIUS, c)
