class_name InstrumentPatch
extends RefCounted

## Serializable instrument definition shared by the design and performance views.
## IDs, rather than display names or array positions, own every connection.
var name: String = "My first instrument"
var master_gain: float = 0.55
var oscillators: Array = []
var modulators: Array = []
var controls: Array = []
var _serial: int = 0

func _init() -> void:
	for i in 3:
		var o := add_oscillator()
		o.wave = i
		o.transpose = [-12.0, 0.0, 12.0][i]
		o.gain = [0.5, 0.3, 0.15][i]
		o.cutoff = [2400.0, 1800.0, 3600.0][i]
	for i in 2:
		var m := add_lfo()
		m.target = oscillators[i].id
		m.rate = [0.4, 2.0][i]
		m.depth = [0.15, 0.08][i]
	for o in oscillators:
		add_control(o.id, "cutoff")
	for m in modulators:
		add_control(m.id, "depth")
	add_control("master", "gain")

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
		"wave": 1, "gain": 0.3, "transpose": 0.0, "filter": true, "cutoff": 2400.0}
	oscillators.append(o)
	return o

func remove_oscillator(id: String) -> void:
	oscillators = oscillators.filter(func(o): return o.id != id)
	controls = controls.filter(func(c): return c.target != id)
	for m in modulators:
		if m.target == id:
			m.target = "all"

func add_lfo() -> Dictionary:
	if modulators.size() >= 8:
		return {}
	var m := {"id": _id("lfo"), "name": _unique_name("LFO", modulators),
		"rate": 1.0, "depth": 0.0, "target": "all"}
	modulators.append(m)
	return m

func remove_lfo(id: String) -> void:
	modulators = modulators.filter(func(m): return m.id != id)
	controls = controls.filter(func(c): return c.target != id)

func find_module(id: String) -> Dictionary:
	for item in oscillators + modulators:
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
			"cutoff": return Vector2(40, 16000)
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
	return {"version": 1, "name": name, "master_gain": master_gain,
		"oscillators": oscillators.duplicate(true), "modulators": modulators.duplicate(true),
		"controls": controls.duplicate(true)}

func _number(d: Dictionary, key: String, lo: float, hi: float) -> bool:
	var v: Variant = d.get(key)
	return (v is int or v is float) and is_finite(float(v)) and float(v) >= lo and float(v) <= hi

## Validate the entire document before replacing any live state.
func load_dict(data: Variant) -> bool:
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
