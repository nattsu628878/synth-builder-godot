extends SceneTree

## Headless smoke test for spike #4's wire -> netlist -> solve chain.
## Wires the fixed parts into a diode clipper (SRC -> R0 -> OUT node, that
## node -> C0 -> GND and -> D0 -> GND, OUT probe across it) and checks the
## solver produces a finite, clipped waveform.
##   godot --headless --script circuit4_selftest.gd

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var scene: PackedScene = load("res://circuit4.tscn")
	var root := scene.instantiate()
	get_root().add_child(root)
	await process_frame  # let _ready() register parts and build the solver
	await process_frame

	var canvas: Circuit4Canvas = root.get_node("%Canvas")

	# palette-add the parts the fixed scene no longer pre-places
	root._add_part("resistor")   # R0
	root._add_part("capacitor")  # C0
	root._add_part("diode")      # D0

	var by := {}
	for p in canvas.parts:
		by[p.pname] = p

	# helper
	var wire := func(a: String, at: int, b: String, bt: int) -> void:
		canvas.wires.append({"a": [by[a], at], "b": [by[b], bt]})

	wire.call("SRC", 0, "R0", 0)      # source+ -> R0
	wire.call("R0", 1, "OUT", 0)      # R0 -> output node (probe +)
	wire.call("OUT", 0, "C0", 0)      # output node -> C0
	wire.call("C0", 1, "GND", 0)      # C0 -> ground
	wire.call("OUT", 0, "D0", 0)      # output node -> diode
	wire.call("D0", 1, "GND", 0)      # diode -> ground
	wire.call("SRC", 1, "GND", 0)     # source- -> ground
	wire.call("OUT", 1, "GND", 0)     # probe - -> ground

	var res: Dictionary = canvas.compile_netlist()
	print("compile ok=%s  err=%s  nodes=%s  comps=%s" % [
		res.get("ok"), res.get("error", "-"), res.get("num_nodes", "-"),
		res["netlist"].size() if res.get("ok") else "-"])
	if not res["ok"]:
		quit(1)
		return
	print("  out_pos=%s out_neg=%s" % [res["out_pos"], res["out_neg"]])
	for c in res["netlist"]:
		print("  ", c)

	root._recompile()
	print("status: ", root._status, "  _ok=", root._ok)

	# drive it and sanity-check the output
	# D0 is wired anode=n1, cathode=gnd -> a single (half-wave) clipper:
	# the positive half is clamped near a diode drop, the negative half
	# swings freely. That asymmetry is the nonlinearity we want to see.
	var solver: Object = root._solver
	var phase := 0.0
	var step := 220.0 / 44100.0
	var max_v := -1e9
	var min_v := 1e9
	var finite := true
	for _i in 44100:
		phase = fposmod(phase + step, 1.0)
		var vin := 3.0 * (2.0 * phase - 1.0)
		for sn in root._source_names: solver.set_source(sn, vin)
		solver.step()
		var v: float = solver.node_voltage(res["out_pos"]) - solver.node_voltage(res["out_neg"])
		if not is_finite(v):
			finite = false
		max_v = maxf(max_v, v)
		min_v = minf(min_v, v)
	print("driven 1 s @3V:  finite=%s  out max=%.4f V  min=%.4f V" % [finite, max_v, min_v])
	print("  (single diode: max clamped near a diode drop, min swings free -> asymmetric)")
	var drive_ok := finite and max_v > 0.3 and max_v < 0.9 and min_v < -1.5

	# --- save / load round-trip ---
	root._patch_name.text = "selftest"
	root._save_patch()
	print("save: ", root._status)
	root._load_patch()
	print("load: ", root._status)
	var res2: Dictionary = root._canvas.compile_netlist()
	var solver2: Object = root._solver
	var mx := -1e9
	var mn := 1e9
	phase = 0.0
	for _i in 44100:
		phase = fposmod(phase + step, 1.0)
		var vin := 3.0 * (2.0 * phase - 1.0)
		for sn in root._source_names: solver2.set_source(sn, vin)
		solver2.step()
		var v: float = solver2.node_voltage(res2["out_pos"]) - solver2.node_voltage(res2["out_neg"])
		mx = maxf(mx, v)
		mn = minf(mn, v)
	print("after reload:      out max=%.4f V  min=%.4f V" % [mx, mn])
	var roundtrip_ok := absf(mx - max_v) < 1e-4 and absf(mn - min_v) < 1e-4

	# --- capacitor state carries across a rebuild (topology change) ---
	# charge C0 up with a DC-ish drive, snapshot, force a recompile, and
	# check the cap voltage survived instead of being zeroed (the click).
	root._drive_slider.value = 3.0
	root._freq_slider.value = 3.0
	for _i in 8000:
		for sn in root._source_names: solver2.set_source(sn, 3.0)
		solver2.step()
	var before: Dictionary = solver2.get_cap_state()
	root._recompile()  # same topology -> build() + set_cap_state()
	var after: Dictionary = root._solver.get_cap_state()
	print("cap state  before=%s  after recompile=%s" % [before, after])
	var carried := before.has("C0") and after.has("C0") \
		and absf(before["C0"]) > 0.05 and absf(after["C0"] - before["C0"]) < 1e-6

	var bjt_ok: bool = await _check_common_emitter()
	var ota_ok: bool = await _check_ota_lp()

	var pass_ok := drive_ok and roundtrip_ok and carried and bjt_ok and ota_ok
	print("drive_ok=%s  roundtrip_ok=%s  cap_carried=%s  bjt_ok=%s  ota_ok=%s" % [
		drive_ok, roundtrip_ok, carried, bjt_ok, ota_ok])
	print("SELFTEST OK" if pass_ok else "SELFTEST FAIL")
	quit(0 if pass_ok else 1)

## Build a common-emitter stage through the spike-4 wiring path (3-terminal
## part, TKEY=3 keying, "Q" netlist entry) and check it turns on and inverts.
func _check_common_emitter() -> bool:
	var scene: PackedScene = load("res://circuit4.tscn")
	var root := scene.instantiate()
	get_root().add_child(root)
	await process_frame
	await process_frame
	var canvas: Circuit4Canvas = root.get_node("%Canvas")

	root._add_part("source")      # SRC0 -> Vcc rail
	root._add_part("resistor")    # R0 -> collector load
	root._add_part("resistor")    # R1 -> base bias from Vcc
	root._add_part("resistor")    # R2 -> base from input
	root._add_part("transistor")  # Q0
	var by := {}
	for p in canvas.parts:
		by[p.pname] = p
	var wire := func(a, at, b, bt): canvas.wires.append({"a": [by[a], at], "b": [by[b], bt]})
	wire.call("SRC0", 0, "R0", 0)   # Vcc -> Rc
	wire.call("SRC0", 0, "R1", 0)   # Vcc -> Rb_bias
	wire.call("SRC0", 1, "GND", 0)  # Vcc-
	wire.call("R0", 1, "Q0", 0)     # Rc -> collector
	wire.call("R1", 1, "Q0", 1)     # Rb_bias -> base
	wire.call("R2", 1, "Q0", 1)     # Rin -> base
	wire.call("R2", 0, "SRC", 0)    # Rin <- input source
	wire.call("SRC", 1, "GND", 0)
	wire.call("Q0", 2, "GND", 0)    # emitter -> gnd
	wire.call("OUT", 0, "Q0", 0)    # probe collector
	wire.call("OUT", 1, "GND", 0)
	by["R0"].value = 2000.0
	by["R1"].value = 470000.0
	by["R2"].value = 100000.0

	var res: Dictionary = canvas.compile_netlist()
	var has_q := false
	for c in res.get("netlist", []):
		if c["type"] == "Q":
			has_q = true
	print("CE: compile ok=%s has_Q=%s nodes=%s" % [res.get("ok"), has_q, res.get("num_nodes")])
	if not res["ok"] or not has_q:
		return false
	root._recompile()
	var s: Object = root._solver
	var settle := func(vin_amp: float) -> float:
		for _i in 6000:
			s.set_source("SRC0", 9.0)
			s.set_source("SRC", vin_amp)
			s.step()
		return s.node_voltage(res["out_pos"]) - s.node_voltage(res["out_neg"])
	var vc0: float = settle.call(0.0)
	var vc1: float = settle.call(0.1)
	print("CE: Vc(vin=0)=%.3f  Vc(vin=0.1)=%.3f  gain=%.1f" % [vc0, vc1, (vc1 - vc0) / 0.1])
	return is_finite(vc0) and vc0 > 0.1 and vc0 < 8.5 and (vc1 - vc0) / 0.1 < -1.0

## Build a 1-pole OTA low-pass through the spike-4 UI path (OTA part with
## an Iabc knob) and check it low-passes and that Iabc sets the cutoff.
func _check_ota_lp() -> bool:
	var scene: PackedScene = load("res://circuit4.tscn")
	var root := scene.instantiate()
	get_root().add_child(root)
	await process_frame
	await process_frame
	var canvas: Circuit4Canvas = root.get_node("%Canvas")

	root._add_part("ota")        # OTA0
	root._add_part("capacitor")  # C0 (integrator cap)
	var by := {}
	for p in canvas.parts:
		by[p.pname] = p
	var wire := func(a, at, b, bt): canvas.wires.append({"a": [by[a], at], "b": [by[b], bt]})
	wire.call("SRC", 0, "OTA0", 1)   # input -> in+
	wire.call("SRC", 1, "GND", 0)
	wire.call("OTA0", 0, "OTA0", 2)  # out -> in-  (unity-gain follower / integrator)
	wire.call("OTA0", 0, "C0", 0)    # out -> C
	wire.call("C0", 1, "GND", 0)
	wire.call("OUT", 0, "OTA0", 0)   # probe the output
	wire.call("OUT", 1, "GND", 0)
	by["C0"].value = 10.0e-9

	var res: Dictionary = canvas.compile_netlist()
	var has_ota := false
	for c in res.get("netlist", []):
		if c["type"] == "OTA":
			has_ota = true
	print("OTA: compile ok=%s has_OTA=%s" % [res.get("ok"), has_ota])
	if not res["ok"] or not has_ota:
		return false
	root._recompile()
	var s: Object = root._solver

	var reach := func(iabc: float, n: int) -> float:
		s.reset_state()          # start each run from a discharged cap
		s.set_value("OTA0", iabc)
		for _i in n:
			s.set_source("SRC", 0.05)
			s.step()
		return s.node_voltage(res["out_pos"]) - s.node_voltage(res["out_neg"])
	var settled: float = reach.call(3.0e-7, 8820)
	var fast: float = reach.call(3.0e-6, 60)
	var slow: float = reach.call(3.0e-7, 60)
	print("OTA: settled=%.4f  fast60=%.4f  slow60=%.4f" % [settled, fast, slow])
	return is_finite(settled) and absf(settled - 0.05) < 3.0e-3 and fast > slow * 1.3
