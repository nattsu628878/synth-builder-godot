class_name InstrumentPatch
extends RefCounted

## v2: explicit audio DAG, independent filters, and many-to-many modulation.
var name: String = "My first instrument"
var master_gain: float = 0.55
var oscillators: Array = []
var filters: Array = []
var routes: Array = []
var modulators: Array = []
var assignments: Array = []
var controls: Array = []
var graph_positions: Dictionary = {}
var last_error: String = ""
var _serial: int = 0

func _init(populate: bool = true) -> void:
	if not populate: return
	for i in 3:
		var o := add_oscillator()
		o.wave = i
		o.transpose = [-12.0, 0.0, 12.0][i]
		o.gain = [0.5, 0.3, 0.15][i]
		var f := add_filter()
		f.cutoff = [2400.0, 1800.0, 3600.0][i]
		routes.append({"from": o.id, "to": f.id})
		routes.append({"from": f.id, "to": "output"})
		add_control(f.id, "cutoff")
	for i in 2:
		var m := add_lfo()
		m.rate = [0.4, 2.0][i]
		m.depth = [0.15, 0.08][i]
		add_assignment(m.id, filters[i].id, "cutoff", 1.0)
		add_control(m.id, "depth")
	add_control("master", "gain")

func add_filter() -> Dictionary:
	if filters.size() >= 8: return {}
	var f := {"id": _id("filter"), "name": _unique_name("FILTER", filters), "cutoff": 2400.0, "enabled": true}
	filters.append(f)
	return f

func remove_filter(id: String) -> void:
	filters = filters.filter(func(f): return f.id != id)
	_remove_references(id)

func _remove_references(id: String) -> void:
	routes = routes.filter(func(r): return r.from != id and r.to != id)
	assignments = assignments.filter(func(a): return a.source != id and a.target != id)
	controls = controls.filter(func(c): return c.target != id)
	graph_positions.erase(id)

func modulation_targets() -> Array:
	var result: Array = []
	for o in oscillators:
		for param in ["gain", "transpose"]:
			result.append({"target": o.id, "param": param, "label": o.name + " · " + param.capitalize()})
	for f in filters: result.append({"target": f.id, "param": "cutoff", "label": f.name + " · Cutoff"})
	result.append({"target": "master", "param": "gain", "label": "MASTER · Gain"})
	return result

func add_assignment(source: String, target: String, param: String, amount: float = 0.0) -> Dictionary:
	if assignments.size() >= 64: return {}
	if not modulators.any(func(m): return m.id == source): return {}
	if not modulation_targets().any(func(t): return t.target == target and t.param == param): return {}
	var a := {"id": _id("mod"), "source": source, "target": target, "param": param, "amount": clampf(amount, -1, 1)}
	assignments.append(a)
	return a

func remove_assignment(id: String) -> void:
	assignments = assignments.filter(func(a): return a.id != id)

func connect_audio(from_id: String, to_id: String) -> bool:
	var candidate := routes.duplicate(true)
	candidate.append({"from": from_id, "to": to_id})
	var error := validate_routes(candidate, oscillators, filters)
	if not error.is_empty():
		last_error = error
		return false
	routes = candidate
	last_error = ""
	return true

func disconnect_audio(from_id: String, to_id: String) -> void:
	routes = routes.filter(func(r): return not (r.from == from_id and r.to == to_id))

static func validate_routes(edges: Array, oscs: Array, fs: Array) -> String:
	if edges.size() > 128: return "Too many audio connections (128 maximum)."
	var nodes := {"output": true}
	var sources := {}
	var destinations := {"output": true}
	for o in oscs:
		nodes[o.id] = true
		sources[o.id] = true
	for f in fs:
		nodes[f.id] = true
		sources[f.id] = true
		destinations[f.id] = true
	var incoming := {}
	var seen := {}
	for id in nodes: incoming[id] = 0
	for r in edges:
		if not r is Dictionary or not r.get("from") is String or not r.get("to") is String: return "Invalid audio connection."
		if not sources.has(r.from) or not destinations.has(r.to): return "Connect an OSC/filter output to a filter or OUTPUT input."
		var key: String = r.from + ">" + r.to
		if seen.has(key): return "These ports are already connected."
		seen[key] = true
		incoming[r.to] += 1
	var queue: Array = []
	for id in nodes:
		if incoming[id] == 0: queue.append(id)
	var visited := 0
	while not queue.is_empty():
		var id: String = queue.pop_front()
		visited += 1
		for r in edges:
			if r.from == id:
				incoming[r.to] -= 1
				if incoming[r.to] == 0: queue.append(r.to)
	return "" if visited == nodes.size() else "Feedback loops are not supported. Previous wiring retained."

func _id(prefix: String) -> String:
	_serial += 1
	return "%s_%d" % [prefix, _serial]

func _unique_name(prefix: String, items: Array) -> String:
	var number := 1
	while items.any(func(item): return item.name == "%s %d" % [prefix, number]):
		number += 1
	return "%s %d" % [prefix, number]

func add_oscillator() -> Dictionary:
	if oscillators.size() >= 8:
		return {}
	var o := {"id": _id("osc"), "name": _unique_name("OSC", oscillators),
		"wave": 1, "gain": 0.3, "transpose": 0.0}
	oscillators.append(o)
	return o

func remove_oscillator(id: String) -> void:
	oscillators = oscillators.filter(func(o): return o.id != id)
	controls = controls.filter(func(c): return c.target != id)
	_remove_references(id)

func add_lfo() -> Dictionary:
	if modulators.size() >= 8:
		return {}
	var m := {"id": _id("lfo"), "name": _unique_name("LFO", modulators),
		"rate": 1.0, "depth": 1.0}
	modulators.append(m)
	return m

func remove_lfo(id: String) -> void:
	modulators = modulators.filter(func(m): return m.id != id)
	_remove_references(id)
	controls = controls.filter(func(c): return c.target != id)

func find_module(id: String) -> Dictionary:
	for item in oscillators + filters + modulators:
		if item.id == id:
			return item
	return {}

func parameter_range(target: String, param: String) -> Vector2:
	if target == "master" and param == "gain": return Vector2(0, 1)
	var item := find_module(target)
	if item.is_empty(): return Vector2.ZERO
	if item.has("wave"):
		match param:
			"gain": return Vector2(0, 1)
			"transpose": return Vector2(-24, 24)
	elif item.has("cutoff"):
		if param == "cutoff": return Vector2(40, 16000)
	else:
		match param:
			"rate": return Vector2(0.05, 20)
			"depth": return Vector2(0, 1)
	return Vector2.ZERO

func add_control(target: String, param: String) -> Dictionary:
	if controls.size() >= 32 or parameter_range(target, param) == Vector2.ZERO:
		return {}
	for c in controls:
		if c.target == target and c.param == param: return c
	var n := 0
	while n < 160:
		var candidate := Rect2(Vector2(24 + (n % 5) * 192, 24 + (n / 5) * 208), Vector2(176, 184))
		if not controls.any(func(item): return candidate.intersects(Rect2(Vector2(item.x, item.y), Vector2(176, 184)))):
			break
		n += 1
	var item := find_module(target)
	var title: String = "MASTER" if target == "master" else str(item.name)
	var c := {"id": _id("ctl"), "label": title + " · " + param.capitalize(),
		"target": target, "param": param, "x": float(24 + (n % 5) * 192), "y": float(24 + (n / 5) * 208)}
	controls.append(c)
	return c

func remove_control(id: String) -> void:
	controls = controls.filter(func(c): return c.id != id)

func get_parameter(target: String, param: String) -> float:
	if target == "master" and param == "gain": return master_gain
	return float(find_module(target).get(param, 0.0))

func set_parameter(target: String, param: String, value: float) -> void:
	if not is_finite(value): return
	var limits := parameter_range(target, param)
	if limits == Vector2.ZERO: return
	value = clampf(value, limits.x, limits.y)
	if target == "master": master_gain = value
	else: find_module(target)[param] = value

func to_dict() -> Dictionary:
	return {"version": 2, "name": name, "master_gain": master_gain,
		"oscillators": oscillators.duplicate(true), "filters": filters.duplicate(true),
		"routes": routes.duplicate(true), "modulators": modulators.duplicate(true),
		"assignments": assignments.duplicate(true), "controls": controls.duplicate(true),
		"graph_positions": graph_positions.duplicate(true)}

func _number(d: Dictionary, key: String, lo: float, hi: float) -> bool:
	var v: Variant = d.get(key)
	return (v is int or v is float) and is_finite(float(v)) and float(v) >= lo and float(v) <= hi

func load_dict(data: Variant) -> bool:
	last_error = "Invalid instrument file; current instrument retained."
	if not data is Dictionary: return false
	if data.get("version") == 1:
		var legacy = get_script().new(false)
		if not legacy._load_v1(data): return false
		legacy._upgrade_v1()
		data = legacy.to_dict()
	if not _validate_v2(data): return false
	name = data.name.left(100)
	master_gain = float(data.master_gain)
	oscillators = data.oscillators.duplicate(true)
	for o in oscillators: o.wave = int(o.wave)
	filters = data.filters.duplicate(true)
	routes = data.routes.duplicate(true)
	modulators = data.modulators.duplicate(true)
	assignments = data.assignments.duplicate(true)
	controls = data.controls.duplicate(true)
	graph_positions = data.graph_positions.duplicate(true)
	_serial = 0
	for item in oscillators + filters + modulators + assignments + controls:
		_serial = maxi(_serial, str(item.id).get_slice("_", 1).to_int())
	last_error = ""
	return true

func _validate_v2(data: Dictionary) -> bool:
	if data.get("version") != 2 or not data.get("name") is String or not _number(data, "master_gain", 0, 1): return false
	for key in ["oscillators", "filters", "routes", "modulators", "assignments", "controls"]:
		if not data.get(key) is Array: return false
	if data.oscillators.size() > 8 or data.filters.size() > 8 or data.modulators.size() > 8 or data.assignments.size() > 64 or data.controls.size() > 32: return false
	var ids := {"master": true, "output": true}
	var params := {"master": ["gain"]}
	var destinations := {"master": ["gain"]}
	var lfos := {}
	for item in data.oscillators + data.filters + data.modulators + data.assignments + data.controls:
		if not item is Dictionary or not item.get("id") is String: return false
		if item.id.is_empty() or not String(item.id).is_valid_identifier() or ids.has(item.id): return false
		ids[item.id] = true
	for o in data.oscillators:
		if not o.get("name") is String or not _number(o, "wave", 0, 2) or float(o.wave) != floor(float(o.wave)): return false
		if not _number(o, "gain", 0, 1) or not _number(o, "transpose", -24, 24): return false
		params[o.id] = ["gain", "transpose"]
		destinations[o.id] = params[o.id]
	for f in data.filters:
		if not f.get("name") is String or not f.get("enabled") is bool or not _number(f, "cutoff", 40, 16000): return false
		params[f.id] = ["cutoff"]
		destinations[f.id] = params[f.id]
	for m in data.modulators:
		if not m.get("name") is String or not _number(m, "rate", 0.05, 20) or not _number(m, "depth", 0, 1): return false
		params[m.id] = ["rate", "depth"]
		lfos[m.id] = true
	for a in data.assignments:
		if not a.get("source") is String or not a.get("target") is String or not a.get("param") is String: return false
		if not lfos.has(a.source) or not destinations.has(a.target) or not a.param in destinations[a.target] or not _number(a, "amount", -1, 1): return false
	for c in data.controls:
		if not c.get("label") is String or not c.get("target") is String or not c.get("param") is String: return false
		if not params.has(c.target) or not c.param in params[c.target]: return false
		if not _number(c, "x", 0, 824) or not _number(c, "y", 0, 5000): return false
	if not data.get("graph_positions") is Dictionary: return false
	var graph_ids := {"output": true}
	for item in data.oscillators + data.filters: graph_ids[item.id] = true
	for id in data.graph_positions:
		var pos: Variant = data.graph_positions[id]
		if not graph_ids.has(id) or not pos is Dictionary or not _number(pos, "x", -10000, 10000) or not _number(pos, "y", -10000, 10000): return false
	var error := validate_routes(data.routes, data.oscillators, data.filters)
	if not error.is_empty():
		last_error = error
		return false
	return true

func _upgrade_v1() -> void:
	var filter_ids := {}
	for o in oscillators:
		var f := add_filter()
		f.cutoff = o.cutoff
		f.enabled = o.filter
		filter_ids[o.id] = f.id
		routes.append({"from": o.id, "to": f.id})
		routes.append({"from": f.id, "to": "output"})
		o.erase("cutoff")
		o.erase("filter")
	for c in controls:
		if c.param == "cutoff" and filter_ids.has(c.target): c.target = filter_ids[c.target]
	for m in modulators:
		for osc_id in filter_ids:
			if m.target == "all" or m.target == osc_id: add_assignment(m.id, filter_ids[osc_id], "cutoff", 1.0)
		m.erase("target")

func _load_v1(data: Variant) -> bool:
	if not data is Dictionary: return false
	if data.get("version") != 1 or not data.get("name") is String: return false
	if not _number(data, "master_gain", 0, 1): return false
	for key in ["oscillators", "modulators", "controls"]:
		if not data.get(key) is Array: return false
	if data.oscillators.size() > 8 or data.modulators.size() > 8 or data.controls.size() > 32: return false
	var ids := {"master": true}
	var osc_ids := {"all": true}
	var params := {"master": ["gain"]}
	for item in data.oscillators + data.modulators + data.controls:
		if not item is Dictionary or not item.get("id") is String: return false
		if item.id.is_empty() or ids.has(item.id): return false
		ids[item.id] = true
	for o in data.oscillators:
		if not o.get("name") is String or not o.get("filter") is bool: return false
		if not _number(o, "wave", 0, 2) or float(o.wave) != floor(float(o.wave)): return false
		if not _number(o, "gain", 0, 1) or not _number(o, "transpose", -24, 24) or not _number(o, "cutoff", 40, 16000): return false
		osc_ids[o.id] = true
		params[o.id] = ["gain", "transpose", "cutoff"]
	for m in data.modulators:
		if not m.get("name") is String or not m.get("target") is String: return false
		if not osc_ids.has(m.target) or not _number(m, "rate", 0.05, 20) or not _number(m, "depth", 0, 1): return false
		params[m.id] = ["rate", "depth"]
	for c in data.controls:
		if not c.get("label") is String or not c.get("target") is String or not c.get("param") is String: return false
		if not params.has(c.target) or not c.param in params[c.target]: return false
		if not _number(c, "x", 0, 824) or not _number(c, "y", 0, 5000): return false
	name = data.name.left(100)
	master_gain = float(data.master_gain)
	oscillators = data.oscillators.duplicate(true)
	for o in oscillators: o.wave = int(o.wave)
	modulators = data.modulators.duplicate(true)
	controls = data.controls.duplicate(true)
	# Loaded IDs may have gaps: monotonically advance beyond every numeric suffix.
	_serial = 0
	for id in ids:
		_serial = maxi(_serial, str(id).get_slice("_", 1).to_int())
	return true
