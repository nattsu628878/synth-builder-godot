extends SceneTree

## Headless benchmark + cross-check for the netlist MNA solver, in both
## implementations:
##   - MnaSolver     (mna_solver.gd, pure GDScript -- the golden reference)
##   - MnaSolverRs   (rust/, GDExtension -- the real-time circuit core)
##
## Run:  godot --headless --script bench_mna.gd
##
## Spike #3 showed the GDScript generic solver does not fit the audio
## budget once a circuit has diodes / oversampling / polyphony. This
## measures how much headroom the Rust port buys, and checks the two
## produce the same waveform.

const MnaSolverScript := preload("res://mna_solver.gd")
const DiodeCircuitScript := preload("res://diode_circuit.gd")

const SR := 44100.0
const BUDGET_US := 1.0e6 / SR

var _have_rust := false

func _init() -> void:
	_have_rust = ClassDB.class_exists("MnaSolverRs")
	print("MNA solver benchmark  (Godot %s)" % Engine.get_version_info().string)
	print("budget = %.2f us / audio sample at %.0f Hz    Rust extension: %s\n" % [
		BUDGET_US, SR, "loaded" if _have_rust else "NOT LOADED"])

	_selfcheck_gd()
	if _have_rust:
		_crosscheck_rust()

	var circuits := [
		["diode clipper + RC        ", _diode_clipper(), "out"],
		["Sallen-Key LP VCF (linear)", _sallen_key(), "out"],
		["common-emitter BJT stage  ", _common_emitter(), "col"],
		["OTA 2-pole LP VCF         ", _ota_vcf(), "out"],
		["4-stage diode RC ladder   ", _diode_ladder(4), "n4"],
		["8-stage RC ladder (linear)", _rc_ladder(8), "n8"],
	]
	for engine in (["gd", "rs"] if _have_rust else ["gd"]):
		print("--- %s ---" % ("GDScript MnaSolver" if engine == "gd" else "Rust MnaSolverRs"))
		for c in circuits:
			_run(engine, c[0], c[1], 1.5)
		print("")

	print("Read: 'load' = wall-clock us spent solving per audio sample, over the")
	print("%.2f us real-time budget. Headroom for oscillator+envelope+game+render" % BUDGET_US)
	print("means staying well under 100%%, ideally under ~40%% at the oversample")
	print("factor a nonlinear circuit needs (2x+), times the voice count.")
	quit()

# --- correctness -------------------------------------------------------------

## generic GDScript solver vs the hand-stamped diode_circuit.gd from spike #3
func _selfcheck_gd() -> void:
	var gen: MnaSolver = MnaSolverScript.new()
	gen.build(_diode_clipper(), "gnd")
	gen.set_dt(1.0 / SR)
	var hand := DiodeCircuitScript.new()
	hand.sample_rate = SR
	hand.oversample = 1
	hand.reset()
	var phase := 0.0
	var step := 220.0 / SR
	var worst := 0.0
	for _i in 4000:
		phase = fposmod(phase + step, 1.0)
		var vin := 1.5 * (2.0 * phase - 1.0)
		gen.set_source("vin", vin)
		gen.step()
		worst = maxf(worst, absf(gen.node_voltage("out") - hand.process_sample(vin)))
	print("check  GDScript generic vs hand-stamped : worst |dV| = %.9f V  (%s)" % [
		worst, "OK" if worst < 1.0e-3 else "MISMATCH"])

## Rust MnaSolverRs vs GDScript MnaSolver, across every benchmark circuit
func _crosscheck_rust() -> void:
	var worst_all := 0.0
	for c in [_diode_clipper(), _sallen_key(), _common_emitter(), _ota_vcf(), _diode_ladder(4), _rc_ladder(8)]:
		var gd: MnaSolver = MnaSolverScript.new()
		gd.build(c, "gnd"); gd.set_dt(1.0 / SR)
		var rs: Object = ClassDB.instantiate("MnaSolverRs")
		rs.build(c, "gnd"); rs.set_dt(1.0 / SR)
		var phase := 0.0
		var step := 220.0 / SR
		var worst := 0.0
		for _i in 8000:
			phase = fposmod(phase + step, 1.0)
			var vin := 1.5 * (2.0 * phase - 1.0)
			gd.set_source("vin", vin); gd.step()
			rs.set_source("vin", vin); rs.step()
			for node in ["in", "a", "b", "out", "n1", "n2", "n3", "n4", "vcc", "col", "bas", "m1"]:
				if gd.has_node_name(node):
					worst = maxf(worst, absf(gd.node_voltage(node) - rs.node_voltage(node)))
		worst_all = maxf(worst_all, worst)
	print("check  Rust MnaSolverRs vs GDScript      : worst |dV| = %.9f V  (%s)\n" % [
		worst_all, "OK" if worst_all < 1.0e-6 else "MISMATCH"])

# --- timing ----------------------------------------------------------------

func _run(engine: String, label: String, netlist: Array, drive: float) -> void:
	for os in [1, 2, 4]:
		var solver: Object = MnaSolverScript.new() if engine == "gd" else ClassDB.instantiate("MnaSolverRs")
		solver.build(netlist, "gnd")
		solver.set_dt(1.0 / (SR * os))
		solver.reset_state()
		var total := int(SR)
		var phase := 0.0
		var step := 220.0 / SR
		var iter_sum := 0
		var iter_max := 0

		for _i in 3000:  # warm-up
			phase = fposmod(phase + step, 1.0)
			solver.set_source("vin", drive * (2.0 * phase - 1.0))
			for _s in os:
				solver.step()

		var t0 := Time.get_ticks_usec()
		for _i in total:
			phase = fposmod(phase + step, 1.0)
			solver.set_source("vin", drive * (2.0 * phase - 1.0))
			for _s in os:
				var it: int = solver.step()
				iter_sum += it
				iter_max = maxi(iter_max, it)
		var elapsed := Time.get_ticks_usec() - t0

		var us := float(elapsed) / float(total)
		var n_val: int = solver.n if engine == "gd" else solver.get_n()
		var nonconv: int = solver.nonconverged if engine == "gd" else solver.get_nonconverged()
		var solves := total * int(os)
		print("%s  N=%2d  os=%dx  ->  %8.3f us/sample  load %7.1f%%  Newton avg %.2f/max %d  nonconv %d" % [
			label, n_val, os, us, us / BUDGET_US * 100.0, float(iter_sum) / float(solves), iter_max, nonconv])

# --- circuits ------------------------------------------------------------

func _diode_clipper() -> Array:
	return [
		{"type": "V", "name": "vin", "nodes": ["in", "gnd"], "value": 0.0},
		{"type": "R", "nodes": ["in", "out"], "value": 4700.0},
		{"type": "C", "nodes": ["out", "gnd"], "value": 10.0e-9},
		{"type": "D", "nodes": ["out", "gnd"]},
		{"type": "D", "nodes": ["gnd", "out"]},
	]

## common-emitter NPN stage: Vcc/Rc load, base biased by a divider from
## Vcc, ac in through Rb. Output at the collector.
func _common_emitter() -> Array:
	return [
		{"type": "V", "name": "vcc", "nodes": ["vcc", "gnd"], "value": 9.0},
		{"type": "V", "name": "vin", "nodes": ["vin", "gnd"], "value": 0.0},
		{"type": "R", "nodes": ["vcc", "col"], "value": 2000.0},
		{"type": "R", "nodes": ["vcc", "bas"], "value": 470000.0},
		{"type": "R", "nodes": ["vin", "bas"], "value": 100000.0},
		{"type": "Q", "nodes": ["col", "bas", "gnd"]},
	]

## two cascaded OTA integrators = a 2-pole low-pass VCF. Iabc sets cutoff.
func _ota_vcf() -> Array:
	return [
		{"type": "V", "name": "vin", "nodes": ["in", "gnd"], "value": 0.0},
		{"type": "OTA", "name": "ota1", "nodes": ["m1", "in", "m1"], "value": 3.0e-7},
		{"type": "C", "nodes": ["m1", "gnd"], "value": 10.0e-9},
		{"type": "OTA", "name": "ota2", "nodes": ["out", "m1", "out"], "value": 3.0e-7},
		{"type": "C", "nodes": ["out", "gnd"], "value": 10.0e-9},
	]

## unity-gain Sallen-Key low-pass, ~1 kHz, Q ~ 0.7 (C1/C2 = 2, R1 = R2)
func _sallen_key() -> Array:
	return [
		{"type": "V", "name": "vin", "nodes": ["in", "gnd"], "value": 0.0},
		{"type": "R", "nodes": ["in", "a"], "value": 10000.0},
		{"type": "R", "nodes": ["a", "b"], "value": 10000.0},
		{"type": "C", "nodes": ["a", "out"], "value": 22.0e-9},
		{"type": "C", "nodes": ["b", "gnd"], "value": 11.0e-9},
		{"type": "OPA", "nodes": ["out", "b", "out"]},
	]

func _diode_ladder(stages: int) -> Array:
	var nl: Array = [{"type": "V", "name": "vin", "nodes": ["in", "gnd"], "value": 0.0}]
	var prev := "in"
	for k in range(1, stages + 1):
		var nk := "n%d" % k
		nl.append({"type": "R", "nodes": [prev, nk], "value": 4700.0})
		nl.append({"type": "C", "nodes": [nk, "gnd"], "value": 10.0e-9})
		nl.append({"type": "D", "nodes": [nk, "gnd"]})
		nl.append({"type": "D", "nodes": ["gnd", nk]})
		prev = nk
	return nl

func _rc_ladder(stages: int) -> Array:
	var nl: Array = [{"type": "V", "name": "vin", "nodes": ["in", "gnd"], "value": 0.0}]
	var prev := "in"
	for k in range(1, stages + 1):
		var nk := "n%d" % k
		nl.append({"type": "R", "nodes": [prev, nk], "value": 4700.0})
		nl.append({"type": "C", "nodes": [nk, "gnd"], "value": 10.0e-9})
		prev = nk
	return nl
