class_name CircuitCanvas
extends Control

## Owns the wiring between CircuitBlocks: click an output port then an
## input port to connect them (replacing any existing connection on
## either port -- single-wire-per-port, no branching, matches the
## "series chain" assumption main.gd uses to evaluate the signal).
## Click empty canvas space to cancel a pending wire, or to delete the
## nearest wire if none is pending.

const WIRE_HIT_TOLERANCE := 8.0

var blocks: Dictionary = {}       # id (String) -> CircuitBlock
var connections: Array = []       # [{from: id, to: id}, ...]

var _pending_output_block: String = ""

func register_block(id: String, block) -> void:
	blocks[id] = block
	block.output_port_pressed.connect(_on_output_pressed.bind(id))
	block.input_port_pressed.connect(_on_input_pressed.bind(id))
	block.moved.connect(queue_redraw)

func _on_output_pressed(id: String) -> void:
	connections = connections.filter(func(c): return c.from != id)
	_pending_output_block = id
	queue_redraw()

func _on_input_pressed(id: String) -> void:
	if _pending_output_block == "" or _pending_output_block == id:
		_pending_output_block = ""
		queue_redraw()
		return
	connections = connections.filter(func(c): return c.to != id)
	connections.append({"from": _pending_output_block, "to": id})
	_pending_output_block = ""
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _pending_output_block != "":
			_pending_output_block = ""
			queue_redraw()
		else:
			_try_delete_wire_near(event.position)
	elif event is InputEventMouseMotion and _pending_output_block != "":
		queue_redraw()

func _try_delete_wire_near(p: Vector2) -> void:
	for i in range(connections.size() - 1, -1, -1):
		var c = connections[i]
		if not blocks.has(c.from) or not blocks.has(c.to):
			continue
		var a: Vector2 = blocks[c.from].get_output_port_global_pos() - global_position
		var b: Vector2 = blocks[c.to].get_input_port_global_pos() - global_position
		if _distance_to_segment(p, a, b) <= WIRE_HIT_TOLERANCE:
			connections.remove_at(i)
			queue_redraw()
			return

func _distance_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := 0.0
	if ab.length_squared() > 0.0001:
		t = clamp((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	var closest := a + ab * t
	return p.distance_to(closest)

## Walks forward from the "source" block through connections, returning
## the ordered chain of block ids reached (e.g. ["source", "rc", "output"]).
## Stops early if a block has no outgoing connection.
func get_chain_from_source() -> Array:
	var source_id := ""
	for id in blocks:
		if blocks[id].block_type == "source":
			source_id = id
			break
	if source_id == "":
		return []
	var chain: Array = [source_id]
	var current := source_id
	var guard := 0
	while guard < blocks.size() + 1:
		guard += 1
		var next_id := ""
		for c in connections:
			if c.from == current:
				next_id = c.to
				break
		if next_id == "" or chain.has(next_id):
			break
		chain.append(next_id)
		current = next_id
	return chain

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.08, 0.1))
	for c in connections:
		if not blocks.has(c.from) or not blocks.has(c.to):
			continue
		var a: Vector2 = blocks[c.from].get_output_port_global_pos() - global_position
		var b: Vector2 = blocks[c.to].get_input_port_global_pos() - global_position
		draw_line(a, b, Color(0.85, 0.85, 0.9), 2.0)
	if _pending_output_block != "" and blocks.has(_pending_output_block):
		var a: Vector2 = blocks[_pending_output_block].get_output_port_global_pos() - global_position
		draw_line(a, get_local_mouse_position(), Color(0.85, 0.8, 0.3, 0.7), 2.0)
