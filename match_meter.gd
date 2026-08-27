class_name MatchMeter
extends Control

## The match feedback for a challenge (North Star: "弄った瞬間にメーターが
## 反応して見える"). Main bar = level match, thin bar under it = shape match
## (best-fit gain removed), a tick at the win threshold, and a charging
## overlay past the tick while the win latch is holding.

const WIN_MARK := 0.92

var match_val := 0.0   # 0..1
var shape_val := 0.0
var win_frac := 0.0    # hold progress 0..1
var solved := false
var active := false
var _flash := 0.0      # 1 -> 0 white pulse on solve

func set_state(m: float, s: float, wf: float, sv: bool, on: bool) -> void:
	match_val = m
	shape_val = s
	win_frac = wf
	solved = sv
	active = on
	queue_redraw()

func pulse() -> void:
	_flash = 1.0

func _process(delta: float) -> void:
	if _flash > 0.0:
		_flash = maxf(_flash - delta * 3.0, 0.0)
		queue_redraw()

func _draw() -> void:
	var w := size.x
	var h := size.y
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.09, 0.09, 0.11))
	if not active:
		draw_string(get_theme_default_font(), Vector2(6, h * 0.62),
			"pick a target to score against a reference circuit",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.55, 0.58, 0.63))
		return

	var mv := clampf(match_val, 0.0, 1.0)
	var sv := clampf(shape_val, 0.0, 1.0)
	# shape bar (thin, lower)
	draw_rect(Rect2(0, h * 0.60, w * sv, h * 0.16), Color(0.5, 0.55, 0.72, 0.65))
	# level match bar
	var col := Color(0.85, 0.3, 0.3).lerp(Color(0.35, 0.82, 0.42), clampf(mv / WIN_MARK, 0.0, 1.0))
	if solved:
		col = Color(0.3, 0.85, 0.45)
	col = col.lerp(Color.WHITE, _flash * 0.8)
	draw_rect(Rect2(0, h * 0.12, w * mv, h * 0.42), col)
	# win threshold tick
	var tx := w * WIN_MARK
	draw_line(Vector2(tx, 0.0), Vector2(tx, h), Color(1, 1, 1, 0.55), 2.0)
	# hold-progress charge past the tick
	if win_frac > 0.0 and not solved:
		draw_rect(Rect2(tx, h * 0.12, (w - tx) * clampf(win_frac, 0.0, 1.0), h * 0.42),
			Color(1.0, 0.95, 0.55, 0.8))

	var font := get_theme_default_font()
	var txt := "match %d%%    shape %d%%" % [roundi(mv * 100.0), roundi(sv * 100.0)]
	if solved:
		txt = "SOLVED ✓    " + txt
	draw_string(font, Vector2(6, h - 6), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
		Color(0.92, 0.94, 0.97))
