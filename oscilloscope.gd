class_name Oscilloscope
extends Control

## Rolling waveform display. Traces: source (green), the player's output
## (blue), and -- when a challenge is active -- the target to match, drawn
## bright, dashed, and ON TOP so it stays visible where it overlaps the
## player's trace (e.g. a clipped plateau). A small legend names them.

var data_in: PackedFloat32Array = PackedFloat32Array()
var data_out: PackedFloat32Array = PackedFloat32Array()
var data_target: PackedFloat32Array = PackedFloat32Array()
var show_target := false

const COL_IN := Color(0.35, 0.85, 0.4)
const COL_OUT := Color(0.35, 0.65, 1.0)
const COL_TARGET := Color(1.0, 0.78, 0.32)

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

	_draw_trace(data_in, COL_IN, 1.5)
	_draw_trace(data_out, COL_OUT, 1.6)
	if show_target:
		_draw_trace_dashed(data_target, COL_TARGET, 2.2)

	var font := get_theme_default_font()
	var fs := 11
	var rows := 3 if show_target else 2
	draw_rect(Rect2(4, 5, 96, 6 + rows * 14), Color(0.05, 0.05, 0.07, 0.72))
	draw_string(font, Vector2(10, 18), "— input", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COL_IN)
	draw_string(font, Vector2(10, 32), "— your output", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COL_OUT)
	if show_target:
		draw_string(font, Vector2(10, 46), "-- target", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COL_TARGET)

func _points(data: PackedFloat32Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.resize(data.size())
	var w := size.x
	var h := size.y
	for i in data.size():
		pts[i] = Vector2(w * float(i) / float(data.size() - 1), h * 0.5 - data[i] * h * 0.45)
	return pts

func _draw_trace(data: PackedFloat32Array, color: Color, width: float) -> void:
	if data.size() < 2:
		return
	draw_polyline(_points(data), color, width, true)

func _draw_trace_dashed(data: PackedFloat32Array, color: Color, width: float) -> void:
	if data.size() < 2:
		return
	var pts := _points(data)
	for i in range(0, pts.size() - 1, 2):  # every other segment -> dashed
		draw_line(pts[i], pts[i + 1], color, width, true)
