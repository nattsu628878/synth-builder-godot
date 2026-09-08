extends Control
var source: Node
func _process(_delta: float) -> void:
	queue_redraw()
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("101722"))
	var center := size.y * 0.5
	draw_line(Vector2(0, center), Vector2(size.x, center), Color("293a4f"))
	if not is_instance_valid(source): return
	var samples: PackedFloat32Array = source.latest_samples
	if samples.size() < 2: return
	var points := PackedVector2Array()
	for i in samples.size():
		points.append(Vector2(float(i) * size.x / (samples.size() - 1), center - samples[i] * center * 0.95))
	draw_polyline(points, Color("76b5ff"), 1.5, true)
