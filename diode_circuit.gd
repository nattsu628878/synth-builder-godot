class_name DiodeCircuit
extends RefCounted

## Spike #3 core (see nattsu-hub/projects/synth-builder-godot.md): the
## audio-rate nonlinear solver, factored out of the scene so a headless
## benchmark (bench.gd) can time it without the audio system.
##
## Circuit: sawtooth voltage source V1 at node 1 -> series R -> node 2,
## with C to ground and an anti-parallel diode pair to ground at node 2.
## Node 2 is the output. Full MNA is run (unknowns [v1, v2, i_V1], 3x3)
## with a Gaussian-elimination solve inside each Newton iteration, so the
## per-sample cost is representative of a real circuit solver (caveat:
## n=3, so the O(n^3) solve is still tiny compared with a 20-node circuit).

const DIODE_IS := 2.52e-9      # 1N4148-ish saturation current (A)
const DIODE_N := 1.752         # emission coefficient
const DIODE_VT := 0.025852     # thermal voltage ~300K (V)
const NEWTON_MAX_ITERS := 50
const NEWTON_TOL := 1.0e-7     # volts
const VLIMIT := 0.5            # max |dv| per Newton iteration (SPICE-style)

var resistance: float = 4700.0
var capacitance: float = 10.0e-9
var sample_rate: float = 44100.0
var oversample: int = 1

var _v2_prev: float = 0.0      # capacitor memory
var _v2_guess: float = 0.0     # Newton warm-start
var last_iters: int = 0        # Newton iterations used by the most recent step
var nonconverged: int = 0

## Preallocated 3x4 augmented matrix (row-major, 12 slots), reused every
## solve so the per-sample path does zero allocation. Naive earlier version
## built fresh Arrays each Newton step -- that alone was a big chunk of the
## cost at audio rate.
var _m := PackedFloat64Array()

func _init() -> void:
	_m.resize(12)

func reset() -> void:
	_v2_prev = 0.0
	_v2_guess = 0.0
	last_iters = 0
	nonconverged = 0

## Advance one AUDIO sample (runs `oversample` solver sub-steps) given the
## instantaneous source voltage. Returns the output-node voltage.
func process_sample(vin: float) -> float:
	var os := maxi(oversample, 1)
	var dt := 1.0 / (sample_rate * float(os))
	var gc := capacitance / dt
	var inv_r := 1.0 / resistance
	var v2 := 0.0
	for _s in os:
		v2 = _solve_step(vin, inv_r, gc)
	return v2

func _solve_step(vin: float, inv_r: float, gc: float) -> float:
	var v2 := _v2_guess
	var ieq_c := gc * _v2_prev
	var inv_nvt := 1.0 / (DIODE_N * DIODE_VT)
	var iters := 0
	while iters < NEWTON_MAX_ITERS:
		iters += 1
		var x: float = clampf(v2 * inv_nvt, -40.0, 40.0)
		var ep := exp(x)
		var en := exp(-x)
		var id := DIODE_IS * (ep - en)
		var gd := DIODE_IS * inv_nvt * (ep + en)
		var ieq_d := id - gd * v2

		# MNA system, unknowns [v1, v2, i_V1], stamped straight into the
		# reused 3x4 augmented matrix _m (row r, col c -> _m[r*4+c]).
		_m[0] = inv_r;  _m[1] = -inv_r;             _m[2] = 1.0;  _m[3] = 0.0
		_m[4] = -inv_r; _m[5] = inv_r + gc + gd;    _m[6] = 0.0;  _m[7] = ieq_c - ieq_d
		_m[8] = 1.0;    _m[9] = 0.0;                _m[10] = 0.0; _m[11] = vin

		var new_v2 := _gauss3()
		var dv := new_v2 - v2
		if absf(dv) > VLIMIT:
			new_v2 = v2 + signf(dv) * VLIMIT
		if absf(new_v2 - v2) < NEWTON_TOL:
			v2 = new_v2
			break
		v2 = new_v2

	if iters >= NEWTON_MAX_ITERS:
		nonconverged += 1
	last_iters = iters
	_v2_prev = v2
	_v2_guess = v2
	return v2

## Gaussian elimination with partial pivoting on the reused 3x4 matrix _m,
## unrolled (no range()/Array allocation). Returns the middle unknown (v2).
func _gauss3() -> float:
	# --- column 0 pivot ---
	var p := 0
	var best := absf(_m[0])
	if absf(_m[4]) > best:
		best = absf(_m[4]); p = 1
	if absf(_m[8]) > best:
		p = 2
	if p != 0:
		_swap_rows(0, p)
	var d0: float = _m[0]
	if absf(d0) < 1.0e-30:
		d0 = 1.0e-30
	var f: float = _m[4] / d0
	_m[5] -= f * _m[1]; _m[6] -= f * _m[2]; _m[7] -= f * _m[3]
	f = _m[8] / d0
	_m[9] -= f * _m[1]; _m[10] -= f * _m[2]; _m[11] -= f * _m[3]
	# --- column 1 pivot ---
	if absf(_m[9]) > absf(_m[5]):
		_swap_rows(1, 2)
	var d1: float = _m[5]
	if absf(d1) < 1.0e-30:
		d1 = 1.0e-30
	f = _m[9] / d1
	_m[10] -= f * _m[6]; _m[11] -= f * _m[7]
	# --- back-substitution (only x1 == v2 is needed) ---
	var d2: float = _m[10]
	if absf(d2) < 1.0e-30:
		d2 = 1.0e-30
	var x2 := _m[11] / d2
	return (_m[7] - _m[6] * x2) / d1

func _swap_rows(i: int, j: int) -> void:
	var bi := i * 4
	var bj := j * 4
	for k in 4:
		var t: float = _m[bi + k]
		_m[bi + k] = _m[bj + k]
		_m[bj + k] = t
