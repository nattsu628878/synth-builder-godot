class_name CircuitCanvas
extends Control

## Owns the wiring between CircuitBlocks. Click any port, then any other
## port on a different block, to connect them -- order doesn't matter
## (output-then-input or input-then-output both work; clicking two ports
## of the same polarity just moves the pending end instead of failing
## silently). Click empty canvas space to cancel a pending wire, or to
## delete the nearest wire if none is pending.

const WIRE_HIT_TOLERANCE := 8.0

var blocks: Dictionary = {}       # id (String) -> CircuitBlock
var connections: Array = []       # [{from: id, to: id}, ...]

var _pending: Dictionary = {}     # {} or {"id": String, "is_output": bool}

func register_block(id: String, block) -> void:
	blocks[id] = block
	block.port_pressed.connect(_on_port_pressed.bind(id))
	block.moved.connect(queue_redraw)

func _on_port_pressed(is_output: bool, id: String) -> void:
	if _pending.is_empty():
		_pending = {"id": id, "is_output": is_output}
		queue_redraw()
		return
	if _pending["id"] == id:
		_pending = {}
		queue_redraw()
		return
	if _pending["is_output"] == is_output:
		# Same polarity clicked twice (e.g. two outputs in a row) -- move
		# the pending end here instead of doing nothing.
		_pending = {"id": id, "is_output": is_output}
		queue_redraw()
		return
	var from_id: String = _pending["id"] if _pending["is_output"] else id
	var to_id: String = id if _pending["is_output"] else _pending["id"]
	connections = connections.filter(func(c): return c.from != from_id and c.to != to_id)
	connections.append({"from": from_id, "to": to_id})
	_pending = {}
	queue_redraw()

func get_pending_description() -> String:
	if _pending.is_empty():
		return "click a port to start a wire"
	var side := "output" if _pending["is_output"] else "input"
	return "wiring from %s's %s -- click another port" % [_pending["id"], side]

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not _pending.is_empty():
			_pending = {}
			queue_redraw()
		else:
			_try_delete_wire_near(event.position)

func _process(_delta: float) -> void:
	# While a wire is pending, its loose end tracks the mouse. _gui_input
	# stops firing the moment the pointer moves over a block (child controls
	# consume the motion events), which froze the rubber-band line. Redraw
	# every frame instead while wiring is in progress.
	if not _pending.is_empty():
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
	if not _pending.is_empty() and blocks.has(_pending["id"]):
		var block = blocks[_pending["id"]]
		var a: Vector2 = (block.get_output_port_global_pos() if _pending["is_output"] else block.get_input_port_global_pos()) - global_position
		draw_line(a, get_local_mouse_position(), Color(0.85, 0.8, 0.3, 0.7), 2.0)
