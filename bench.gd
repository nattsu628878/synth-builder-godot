extends SceneTree

## Headless benchmark for the Spike #3 solver. Run:
##   godot --headless --script bench.gd
##
## Times DiodeCircuit.process_sample over one second of audio for a few
## drive levels and oversample factors, and reports us/sample plus the
## implied DSP-load fraction (us used / us available). Nothing here touches
## the audio system, so it works headless and is deterministic.

const DiodeCircuitScript := preload("res://diode_circuit.gd")

func _init() -> void:
	var sr := 44100.0
	var seconds := 1.0
	var total := int(sr * seconds)
	print("DiodeCircuit headless benchmark  (Godot %s)" % Engine.get_version_info().string)
	print("samples/run = %d   (%.1f s of audio at %.0f Hz)\n" % [total, seconds, sr])

	for os in [1, 2, 4, 8]:
		for drive in [0.5, 1.5, 3.0]:
			var c := DiodeCircuitScript.new()
			c.sample_rate = sr
			c.oversample = os
			c.resistance = 4700.0
			c.capacitance = 10.0e-9
			c.reset()
			var phase := 0.0
			var freq := 220.0
			var step := freq / sr
			var max_iters := 0
			var iter_sum := 0
			# warm up (JIT-less, but lets exp() caches / branch predictor settle)
			for _i in 2000:
				phase = fposmod(phase + step, 1.0)
				c.process_sample(drive * (2.0 * phase - 1.0))

			var t0 := Time.get_ticks_usec()
			for _i in total:
				phase += step
				if phase >= 1.0:
					phase -= 1.0
				c.process_sample(drive * (2.0 * phase - 1.0))
				iter_sum += c.last_iters
				if c.last_iters > max_iters:
					max_iters = c.last_iters
			var elapsed := Time.get_ticks_usec() - t0

			var us_per_sample := float(elapsed) / float(total)
			var budget_us := 1.0e6 / sr
			var load := us_per_sample / budget_us * 100.0
			print("os=%dx drive=%.1fV  ->  %6.3f us/sample   load %5.1f%%   Newton avg %.2f / max %d   nonconv %d" % [
				os, drive, us_per_sample, load, float(iter_sum) / float(total), max_iters, c.nonconverged])
		print("")

	print("Interpretation: 'load' is the share of one audio sample's wall-clock")
	print("budget (%.2f us at %.0f Hz) spent solving. Well under 100%% with headroom" % [1.0e6 / sr, sr])
	print("for the rest of the game = GDScript is viable; near/over 100%% = need Rust.")
	quit()
