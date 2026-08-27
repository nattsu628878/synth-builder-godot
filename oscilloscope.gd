class_name Oscilloscope
extends Control

## Rolling waveform display. Three traces: source (green), the player's
## output (blue), and -- when a challenge is active -- a dim target the
## player is trying to match (amber). No zoom/grid/trigger.

var data_in: PackedFloat32Array = PackedFloat32Array()
var data_out: PackedFloat32Array = PackedFloat32Array()
var data_target: PackedFloat32Array = PackedFloat32Array()
var show_target := false

func set_data(a: PackedFloat32Array, b: PackedFloat32Array) -> void:
	data_in = a
	data_out = b
	queue_redraw()

func set_target(t: PackedFloat32Array, visible: bool) -> void:
	data_target = t
	show_target = visible

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.05, 0.07))
	draw_line(Vector2(0, size.y * 0.5), Vector2(size.x, size.y * 0.5), Color(1, 1, 1, 0.06), 1.0)
	if show_target:
		_draw_trace(data_target, Color(1.0, 0.75, 0.3, 0.55), 3.0)
	_draw_trace(data_in, Color(0.35, 0.85, 0.4), 1.5)
	_draw_trace(data_out, Color(0.35, 0.65, 1.0), 1.5)

func _draw_trace(data: PackedFloat32Array, color: Color, width: float) -> void:
	if data.size() < 2:
		return
	var points := PackedVector2Array()
	points.resize(data.size())
	var w := size.x
	var h := size.y
	for i in data.size():
		var x := w * float(i) / float(data.size() - 1)
		var y := h * 0.5 - data[i] * h * 0.45
		points[i] = Vector2(x, y)
	draw_polyline(points, color, width, true)
