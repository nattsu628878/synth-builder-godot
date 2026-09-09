extends VBoxContainer
signal structure_changed
var patch: InstrumentPatch
@onready var graph: GraphEdit = $Graph
@onready var status: Label = $Status

func _ready() -> void:
	graph.connection_request.connect(_connect)
	graph.disconnection_request.connect(_disconnect)
	graph.end_node_move.connect(_save_positions)
	graph.gui_input.connect(_graph_input)
	$Toolbar/Oscillator.pressed.connect(func(): patch.add_oscillator(); refresh(); structure_changed.emit())
	$Toolbar/Filter.pressed.connect(func(): patch.add_filter(); refresh(); structure_changed.emit())
	$Toolbar/Arrange.pressed.connect(func(): patch.graph_positions.clear(); refresh(); graph.scroll_offset = Vector2.ZERO)
	refresh()

func refresh() -> void:
	if not is_node_ready() or patch == null: return
	graph.clear_connections()
	for child in graph.get_children():
		if child is GraphNode:
			graph.remove_child(child)
			child.queue_free()
	for i in patch.oscillators.size():
		var o: Dictionary = patch.oscillators[i]
		_add_node(o.id, o.name, "Oscillator", false, true, Vector2(40, 70 + i * 110))
	for i in patch.filters.size():
		var f: Dictionary = patch.filters[i]
		_add_node(f.id, f.name, "LP filter" if f.enabled else "Bypassed", true, true, Vector2(340, 70 + i * 110))
	_add_node("output", "OUTPUT", "Master mix", true, false, Vector2(680, 180))
	for r in patch.routes: graph.connect_node(r.from, 0, r.to, 0)
	$Toolbar/Oscillator.disabled = patch.oscillators.size() >= 8
	$Toolbar/Filter.disabled = patch.filters.size() >= 8
	_save_positions()
	_status()

func _add_node(id: String, title: String, detail: String, input: bool, output: bool, fallback: Vector2) -> void:
	var block := GraphNode.new()
	block.name = id
	block.title = title
	block.custom_minimum_size.x = 190
	graph.add_child(block)
	var p: Dictionary = patch.graph_positions.get(id, {"x": fallback.x, "y": fallback.y})
	block.position_offset = Vector2(p.x, p.y)
	var label := Label.new()
	label.text = ("IN  ·  " if input else "") + detail + ("  ·  OUT" if output else "")
	block.add_child(label)
	block.set_slot(0, input, 0, Color("84c0ff"), output, 0, Color("84c0ff"))
	if id != "output":
		var remove := Button.new()
		remove.text = "Remove"
		block.add_child(remove)
		remove.pressed.connect(func():
			if patch.oscillators.any(func(o): return o.id == id): patch.remove_oscillator(id)
			else: patch.remove_filter(id)
			refresh()
			structure_changed.emit()
		)

func _save_positions() -> void:
	for block in graph.get_children():
		if block is GraphNode:
			var p: Vector2 = block.position_offset.clamp(Vector2(-10000, -10000), Vector2(10000, 10000))
			patch.graph_positions[str(block.name)] = {"x": p.x, "y": p.y}

func _connect(from_node: StringName, _from_port: int, to_node: StringName, _to_port: int) -> void:
	if patch.connect_audio(str(from_node), str(to_node)):
		graph.connect_node(from_node, 0, to_node, 0)
		_status()
	else: status.text = patch.last_error

func _disconnect(from_node: StringName, _from_port: int, to_node: StringName, _to_port: int) -> void:
	patch.disconnect_audio(str(from_node), str(to_node))
	graph.disconnect_node(from_node, 0, to_node, 0)
	_status()

func _graph_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		var edge := graph.get_closest_connection_at_point(event.position, 12.0)
		if not edge.is_empty():
			_disconnect(edge.from_node, edge.from_port, edge.to_node, edge.to_port)
			graph.accept_event()

func _status() -> void:
	var reachable := {}
	for o in patch.oscillators: reachable[o.id] = true
	for _i in patch.filters.size() + 1:
		for r in patch.routes:
			if reachable.has(r.from): reachable[r.to] = true
	status.text = "%d audio connections · Filters process each played note. Parameters are in Design." % patch.routes.size() if reachable.has("output") else "No oscillator reaches OUTPUT — connect a path to hear this instrument."
