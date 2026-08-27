extends SceneTree

## Headless benchmark for the netlist-driven MnaSolver. Run:
##   godot --headless --script bench_mna.gd
##
## Times MnaSolver.step() over one second of audio for several circuits of
## increasing size / nonlinearity, so we can see how the per-sample cost
## grows with node count and diode count and decide whether GDScript
## prototyping of the circuit engine stays viable.

const MnaSolverScript := preload("res://mna_solver.gd")
const DiodeCircuitScript := preload("res://diode_circuit.gd")

const SR := 44100.0

func _init() -> void:
	print("MnaSolver headless benchmark  (Godot %s)" % Engine.get_version_info().string)
	print("budget = %.2f us per audio sample at %.0f Hz\n" % [1.0e6 / SR, SR])

	_selfcheck()

	_run("diode clipper + RC        ", _diode_clipper(), "out", 1.5)
	_run("Sallen-Key LP VCF (linear)", _sallen_key(), "out", 1.5)
	_run("4-stage diode RC ladder   ", _diode_ladder(4), "n4", 1.5)
	_run("8-stage RC ladder (linear)", _rc_ladder(8), "n8", 1.5)

	print("\nRead: 'load' = share of one sample's wall-clock budget spent solving")
	print("at 1x. Under ~40-50%% with the game still to render = GDScript is fine;")
	print("crowding 100%% = the circuit engine wants Rust/gdext.")
	quit()

## Sanity check: the generic solver on the diode-clipper netlist must
## track the hand-stamped diode_circuit.gd from spike #3 (same circuit,
## same models). Reports the worst-case sample difference.
func _selfcheck() -> void:
	var gen: MnaSolver = MnaSolverScript.new()
	gen.build(_diode_clipper(), "gnd")
	gen.set_dt(1.0 / SR)
	gen.reset_state()
	var hand := DiodeCircuitScript.new()
	hand.sample_rate = SR
	hand.oversample = 1
	hand.reset()

	var phase := 0.0
	var step := 220.0 / SR
	var worst := 0.0
	for _i in 4000:
		phase += step
		if phase >= 1.0:
			phase -= 1.0
		var vin := 1.5 * (2.0 * phase - 1.0)
		gen.set_source("vin", vin)
		gen.step()
		var a := gen.node_voltage("out")
		var b: float = hand.process_sample(vin)
		worst = maxf(worst, absf(a - b))
	print("self-check  generic vs hand-stamped diode clipper: worst |dV| = %.9f V  (%s)\n" % [
		worst, "OK" if worst < 1.0e-3 else "MISMATCH"])

func _run(label: String, netlist: Array, out_node: String, drive: float) -> void:
	for os in [1, 2, 4]:
		var solver: MnaSolver = MnaSolverScript.new()
		solver.build(netlist, "gnd")
		solver.set_dt(1.0 / (SR * os))
		solver.reset_state()
		var total := int(SR)  # 1 s of audio
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
			phase += step
			if phase >= 1.0:
				phase -= 1.0
			solver.set_source("vin", drive * (2.0 * phase - 1.0))
			for _s in os:
				var it := solver.step()
				iter_sum += it
				if it > iter_max:
					iter_max = it
		var elapsed := Time.get_ticks_usec() - t0

		var us := float(elapsed) / float(total)
		var load := us / (1.0e6 / SR) * 100.0
		var solves := total * int(os)
		print("%s  N=%2d  os=%dx  ->  %7.3f us/sample  load %6.1f%%  Newton avg %.2f/max %d  nonconv %d" % [
			label, solver.n, os, us, load, float(iter_sum) / float(solves), iter_max, solver.nonconverged])
	print("")

# --- circuits ------------------------------------------------------------

func _diode_clipper() -> Array:
	return [
		{"type": "V", "name": "vin", "nodes": ["in", "gnd"], "value": 0.0},
		{"type": "R", "nodes": ["in", "out"], "value": 4700.0},
		{"type": "C", "nodes": ["out", "gnd"], "value": 10.0e-9},
		{"type": "D", "nodes": ["out", "gnd"]},
		{"type": "D", "nodes": ["gnd", "out"]},
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
