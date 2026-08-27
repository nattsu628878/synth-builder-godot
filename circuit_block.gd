class_name CircuitBlock
extends PanelContainer

## A single draggable block on the CircuitCanvas. Has at most one input
## port (left edge) and one output port (right edge), drawn as circles.
## "source" has no input port, "output" has no output port.

signal moved
signal output_port_pressed(block)
signal input_port_pressed(block)

@export var block_type: String = ""  # "source" | "rc" | "output"

const PORT_RADIUS := 10.0

var _dragging: bool = false

func get_output_port_global_pos() -> Vector2:
	return global_position + Vector2(size.x, size.y * 0.5)

func get_input_port_global_pos() -> Vector2:
	return global_position + Vector2(0, size.y * 0.5)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var local_pos: Vector2 = event.position
			var out_local := Vector2(size.x, size.y * 0.5)
			var in_local := Vector2(0.0, size.y * 0.5)
			if block_type != "source" and local_pos.distance_to(in_local) <= PORT_RADIUS + 4.0:
				input_port_pressed.emit(self)
				accept_event()
				return
			if block_type != "output" and local_pos.distance_to(out_local) <= PORT_RADIUS + 4.0:
				output_port_pressed.emit(self)
				accept_event()
				return
			_dragging = true
			accept_event()
		else:
			_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		position += event.relative
		moved.emit()
		accept_event()

func _draw() -> void:
	if block_type != "source":
		draw_circle(Vector2(0.0, size.y * 0.5), PORT_RADIUS, Color(0.95, 0.85, 0.3))
	if block_type != "output":
		draw_circle(Vector2(size.x, size.y * 0.5), PORT_RADIUS, Color(0.4, 0.75, 1.0))
