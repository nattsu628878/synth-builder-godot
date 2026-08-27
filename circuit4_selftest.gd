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
		solver.set_source("vin", vin)
		solver.step()
		var v: float = solver.node_voltage(res["out_pos"]) - solver.node_voltage(res["out_neg"])
		if not is_finite(v):
			finite = false
		max_v = maxf(max_v, v)
		min_v = minf(min_v, v)
	print("driven 1 s @3V:  finite=%s  out max=%.4f V  min=%.4f V" % [finite, max_v, min_v])
	print("  (single diode: max clamped near a diode drop, min swings free -> asymmetric)")
	var pass_ok := finite and max_v > 0.3 and max_v < 0.9 and min_v < -1.5
	print("SELFTEST OK" if pass_ok else "SELFTEST FAIL")
	quit(0 if pass_ok else 1)
