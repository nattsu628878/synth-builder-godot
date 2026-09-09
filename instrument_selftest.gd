extends SceneTree
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message)
	print("PASS " if ok else "FAIL ", message)
func _init() -> void:
	_run.call_deferred()
func _run() -> void:
	var patch = preload("res://instrument_patch.gd").new()
	check(patch.oscillators.size() == 3 and patch.modulators.size() == 2, "default instrument topology")
	var snapshot: Dictionary = patch.to_dict()
	var copy = preload("res://instrument_patch.gd").new()
	check(copy.load_dict(JSON.parse_string(JSON.stringify(snapshot))), "JSON roundtrip accepts valid document")
	check(JSON.stringify(copy.to_dict()) == JSON.stringify(snapshot), "JSON roundtrip preserves topology, panel, and values")
	var bad: Dictionary = snapshot.duplicate(true)
	bad.controls[0].target = "missing"
	check(not copy.load_dict(bad) and JSON.stringify(copy.to_dict()) == JSON.stringify(snapshot), "dangling panel binding rejected atomically")
	bad = snapshot.duplicate(true)
	bad.oscillators[1].id = bad.oscillators[0].id
	check(not copy.load_dict(bad), "duplicate module IDs rejected")
	bad = snapshot.duplicate(true)
	bad.controls[0].x = 3000
	check(not copy.load_dict(bad), "unreachable panel position rejected")
	bad = snapshot.duplicate(true)
	bad.modulators[0].rate = "bad"
	check(not copy.load_dict(bad), "invalid numeric data rejected")
	var removed: String = copy.oscillators[0].id
	copy.remove_oscillator(removed)
	check(copy.routes.all(func(r): return r.from != removed and r.to != removed), "removing module removes connected audio wires")
	check(copy.controls.all(func(c): return c.target != removed), "removing module removes panel bindings")
	var added: Dictionary = copy.add_oscillator()
	check(added.id != removed, "new module keeps unique identity")
	check(copy.oscillators.filter(func(o): return o.name == added.name).size() == 1, "new module display name is unambiguous")
	var ctl: Dictionary = copy.add_control(added.id, "gain")
	copy.set_parameter(ctl.target, ctl.param, 0.73)
	check(is_equal_approx(copy.find_module(added.id).gain, 0.73), "panel binding changes module parameter")
	check(ClassDB.class_exists("InstrumentSynthRs"), "native software engine registered")
	if ClassDB.class_exists("InstrumentSynthRs"):
		var synth = ClassDB.instantiate("InstrumentSynthRs")
		check(synth.configure_graph(patch.oscillators, patch.filters, patch.routes, patch.modulators, patch.assignments, patch.master_gain), "native accepts graph")
		var silent: PackedVector2Array = synth.render(512)
		check(_peak(silent) == 0, "no notes means silence")
		synth.note_on(60, 0.8)
		var output: PackedVector2Array = synth.render(4096)
		check(_peak(output) > 0.01 and _finite(output), "instrument note produces finite audible signal")
		var wave_outputs: Array[PackedVector2Array] = []
		for wave in 3:
			var voice = ClassDB.instantiate("InstrumentSynthRs")
			var osc: Dictionary = patch.oscillators[0].duplicate()
			osc.wave = wave
			osc.filter = false
			voice.configure([osc], [], 0.5)
			voice.note_on(69, 1.0)
			wave_outputs.append(voice.render(2048))
		check(_difference(wave_outputs[0], wave_outputs[1]) > 0.01, "integer saw selection differs from sine across native boundary")
		check(_difference(wave_outputs[0], wave_outputs[2]) > 0.01, "integer square selection differs from sine across native boundary")
		synth.all_notes_off()
		for i in 10: synth.render(4096)
		check(_peak(synth.render(512)) < 0.0001, "all notes off releases to silence")
	_test_graph_and_migration(patch)
	if ResourceLoader.exists("res://instrument_designer.tscn"):
		var scene = load("res://instrument_designer.tscn").instantiate()
		root.add_child(scene)
		await process_frame
		await process_frame
		check(scene.get_script() != null and scene.get("engine") != null and scene.engine.available, "designer scene has live audio engine")
		var tabs: TabContainer = scene.get_node("Margin/Main/Tabs")
		tabs.current_tab = tabs.get_tab_idx_from_control(scene.get_node("Margin/Main/Tabs/Panel"))
		await process_frame
		var routing: Node = scene.routing
		var from_id: String = scene.patch.oscillators[0].id
		var to_id: String = scene.patch.filters[0].id
		routing.graph.disconnection_request.emit(StringName(from_id), 0, StringName(to_id), 0)
		check(not routing.graph.is_node_connected(from_id, 0, to_id, 0) and not scene.patch.routes.any(func(r): return r.from == from_id and r.to == to_id), "GraphEdit disconnect updates visible and audio graphs")
		routing.graph.connection_request.emit(StringName(from_id), 0, StringName(to_id), 0)
		check(routing.graph.is_node_connected(from_id, 0, to_id, 0) and scene.patch.routes.any(func(r): return r.from == from_id and r.to == to_id), "GraphEdit connect updates visible and audio graphs")
		var matrix_row: Node = scene.modulation.rows.get_child(0)
		var amount: SpinBox = matrix_row.get_child(2)
		amount.value = -0.4
		check(is_equal_approx(scene.patch.assignments[0].amount, -0.4), "matrix amount reaches instrument")
		var surface: Control = scene.surface
		check(surface.get_child_count() == scene.patch.controls.size(), "panel generated from instrument bindings")
		var first: Control = surface.get_child(0)
		var slider: HSlider = first.get_node("Content/Slider")
		slider.value = 1200.0
		check(is_equal_approx(scene.patch.filters[0].cutoff, 1200.0), "performance slider updates live instrument")
		tabs.current_tab = 0
		await process_frame
		var spins: Array[Node] = scene.modules.find_children("*", "SpinBox", true, false)
		var cutoff_spins: Array = spins.filter(func(spin): return spin.get_meta("target") == scene.patch.filters[0].id and spin.get_meta("param") == "cutoff")
		check(cutoff_spins.size() == 1 and is_equal_approx(cutoff_spins[0].value, 1200.0), "return to design refreshes current values")
		scene.get_node("Margin/Main/Tabs/Panel/Toolbar/Layout").button_pressed = true
		tabs.current_tab = tabs.get_tab_idx_from_control(scene.get_node("Margin/Main/Tabs/Panel"))
		scene._refresh_panel()
		await process_frame
		var label_edit: LineEdit = surface.get_child(0).get_node("Content/LabelEdit")
		label_edit.text = "Warmth"
		label_edit.text_changed.emit("Warmth")
		check(scene.patch.controls[0].label == "Warmth", "custom control label persists in definition")
		if "--render" in OS.get_cmdline_user_args():
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("/tmp/instrument-panel.png")
			tabs.current_tab = 0
			await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("/tmp/instrument-design.png")
			tabs.current_tab = tabs.get_tab_idx_from_control(scene.routing)
			await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("/tmp/instrument-routing.png")
			tabs.current_tab = tabs.get_tab_idx_from_control(scene.modulation)
			await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("/tmp/instrument-modulation.png")
		scene.queue_free()
		await process_frame
	print("INSTRUMENT SELFTEST OK" if failures.is_empty() else "INSTRUMENT SELFTEST FAIL: " + str(failures))
	quit(0 if failures.is_empty() else 1)
func _peak(block: PackedVector2Array) -> float:
	var peak := 0.0
	for v in block: peak = maxf(peak, absf(v.x))
	return peak
func _finite(block: PackedVector2Array) -> bool:
	for v in block:
		if not is_finite(v.x) or not is_finite(v.y) or absf(v.x) > 1.0: return false
	return true

func _difference(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var difference := 0.0
	for i in a.size(): difference = maxf(difference, absf(a[i].x - b[i].x))
	return difference

func _test_graph_and_migration(patch: InstrumentPatch) -> void:
	var p := InstrumentPatch.new()
	var a: String = p.filters[0].id
	var b: String = p.filters[1].id
	check(p.connect_audio(a, b), "serial filters can connect")
	var routes_before := p.routes.duplicate(true)
	check(not p.connect_audio(b, a) and p.routes == routes_before, "feedback connection rejected without losing wiring")
	check(not p.connect_audio(a, b), "duplicate audio wire rejected")
	check(not p.connect_audio("output", a), "output cannot be an audio source")
	p.disconnect_audio(a, b)
	var modulation := p.add_assignment(p.modulators[0].id, p.oscillators[0].id, "transpose", -0.5)
	check(not modulation.is_empty(), "one LFO can modulate another parameter with signed amount")
	p.remove_filter(a)
	check(p.assignments.all(func(r): return r.target != a) and p.controls.all(func(c): return c.target != a), "filter deletion cleans assignments and panel controls")
	var broken := patch.to_dict()
	broken.routes.append({"from": patch.filters[0].id, "to": patch.filters[0].id})
	check(not p.load_dict(broken), "saved cyclic graph rejected")
	var legacy := {"version": 1, "name": "Legacy test", "master_gain": 0.5,
		"oscillators": [{"id": "osc_1", "name": "OSC 1", "wave": 1, "gain": 0.5, "transpose": 0.0, "filter": true, "cutoff": 1500.0}],
		"modulators": [{"id": "lfo_2", "name": "LFO 1", "rate": 1.2, "depth": 0.2, "target": "all"}],
		"controls": [{"id": "ctl_3", "label": "Tone", "target": "osc_1", "param": "cutoff", "x": 24.0, "y": 24.0}]}
	check(p.load_dict(legacy), "v1 instrument migrated")
	check(p.filters.size() == 1 and p.routes.size() == 2 and p.assignments.size() == 1 and p.controls[0].target == p.filters[0].id, "migration preserves filter and panel meaning")
	var old = ClassDB.instantiate("InstrumentSynthRs")
	var current = ClassDB.instantiate("InstrumentSynthRs")
	old.configure(legacy.oscillators, legacy.modulators, legacy.master_gain)
	check(current.configure_graph(p.oscillators, p.filters, p.routes, p.modulators, p.assignments, p.master_gain), "migrated instrument compiles")
	old.note_on(60, 0.8)
	current.note_on(60, 0.8)
	check(_difference(old.render(4096), current.render(4096)) < 0.000001, "migration preserves rendered sound")
	var disconnected = ClassDB.instantiate("InstrumentSynthRs")
	disconnected.configure_graph(p.oscillators, p.filters, [], p.modulators, [], p.master_gain)
	disconnected.note_on(60, 0.8)
	check(_peak(disconnected.render(2048)) == 0.0, "disconnected graph renders silence")
