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
	check(copy.modulators[0].target == "all", "removing destination repairs modulation target")
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
		synth.configure(patch.oscillators, patch.modulators, patch.master_gain)
		var silent: PackedVector2Array = synth.render(512)
		check(_peak(silent) == 0, "no notes means silence")
		synth.note_on(60, 0.8)
		var output: PackedVector2Array = synth.render(4096)
		check(_peak(output) > 0.01 and _finite(output), "instrument note produces finite audible signal")
		synth.all_notes_off()
		for i in 10: synth.render(4096)
		check(_peak(synth.render(512)) < 0.0001, "all notes off releases to silence")
	if ResourceLoader.exists("res://instrument_designer.tscn"):
		var scene = load("res://instrument_designer.tscn").instantiate()
		root.add_child(scene)
		await process_frame
		await process_frame
		check(scene.get_script() != null and scene.get("engine") != null and scene.engine.available, "designer scene has live audio engine")
		var tabs: TabContainer = scene.get_node("Margin/Main/Tabs")
		tabs.current_tab = 1
		await process_frame
		var surface: Control = scene.surface
		check(surface.get_child_count() == scene.patch.controls.size(), "panel generated from instrument bindings")
		var first: Control = surface.get_child(0)
		var slider: HSlider = first.get_node("Content/Slider")
		slider.value = 1200.0
		check(is_equal_approx(scene.patch.oscillators[0].cutoff, 1200.0), "performance slider updates live instrument")
		tabs.current_tab = 0
		await process_frame
		var spins: Array[Node] = scene.modules.find_children("*", "SpinBox", true, false)
		check(spins.size() >= 3 and is_equal_approx(spins[2].value, 1200.0), "return to design refreshes current values")
		scene.get_node("Margin/Main/Tabs/Panel/Toolbar/Layout").button_pressed = true
		tabs.current_tab = 1
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
