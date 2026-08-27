class_name Oscilloscope
extends Control

## Throwaway spike widget: draws two rolling waveform traces (pre-filter /
## post-filter) so a value tweak's effect is visible the instant it happens.
## Not meant to survive past the spike -- no zoom, grid, or trigger.

var data_in: PackedFloat32Array = PackedFloat32Array()
var data_out: PackedFloat32Array = PackedFloat32Array()

func set_data(a: PackedFloat32Array, b: PackedFloat32Array) -> void:
	data_in = a
	data_out = b
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.05, 0.07))
	_draw_trace(data_in, Color(0.35, 0.85, 0.4))
	_draw_trace(data_out, Color(0.35, 0.65, 1.0))

func _draw_trace(data: PackedFloat32Array, color: Color) -> void:
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
	draw_polyline(points, color, 1.5, true)
