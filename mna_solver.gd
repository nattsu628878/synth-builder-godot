class_name MnaSolver
extends RefCounted

## Spike #3, step 2 (see nattsu-hub/projects/synth-builder-godot.md):
## generalise the hand-stamped 3x3 diode clipper of diode_circuit.gd into
## a netlist-driven N-node MNA solver, so a real synth filter circuit can
## be benchmarked and the "keep prototyping in GDScript vs move to Rust"
## call can be made on data.
##
## Supported components (enough for the classic synth filters):
##   {"type": "R",   "nodes": [a, b],       "value": ohms}
##   {"type": "C",   "nodes": [a, b],       "value": farads}
##   {"type": "V",   "nodes": [p, n],       "value": volts, "name": id}   ideal source (also the input)
##   {"type": "D",   "nodes": [anode, cath]}                              Shockley diode
##   {"type": "OPA", "nodes": [out, vplus, vminus]}                       ideal op-amp (nullor)
## Node names are arbitrary strings; the ground node name is passed to build().
##
## MNA layout: unknown vector x = [ node voltages (num_nodes) | branch
## currents (one per V and per OPA) ]. Backward-Euler companion model for
## capacitors. Newton-Raphson (with scaled-step damping) wraps the linear
## solve for the diodes; a purely linear circuit converges in 2 iterations.
## Dense Gaussian elimination with partial pivoting -- the pessimistic
## baseline (a real engine would use sparse LU).
##
## Hot path is written for speed within GDScript's limits: everything the
## per-sample loop touches lives in typed Packed arrays (no Dictionary, no
## range()), and the constant part of the matrix (resistors, cap Geq, the
## structural 1s of sources/op-amps) is assembled once into _base and
## copied each Newton iteration; only the cap RHS and the diode stamps are
## re-added.

const DIODE_IS := 2.52e-9
const DIODE_N := 1.752
const DIODE_VT := 0.025852

# NPN BJT, Ebers-Moll transport form (fixed model, 2N3904-ish)
const BJT_IS := 1.0e-14
const BJT_BF := 200.0
const BJT_BR := 2.0
const BJT_VT := 0.025852
const NEWTON_MAX_ITERS := 50
const NEWTON_TOL := 1.0e-7
const VLIMIT := 0.5  # max |delta v| across one Newton iteration (whole vector, scaled)

var n: int = 0                 # total unknowns
var num_nodes: int = 0
var dt: float = 1.0 / 44100.0
var last_iters: int = 0
var nonconverged: int = 0

var _ground := "gnd"
var _node_idx: Dictionary = {}
var _src_name_to_i: Dictionary = {}   # V source name -> row in _v_*

var _w: int = 0                       # augmented width = n + 1
var _base := PackedFloat64Array()     # constant part of the augmented matrix
var _a := PackedFloat64Array()        # working matrix (destroyed by _gauss)
var _x := PackedFloat64Array()
var _x_new := PackedFloat64Array()

# typed component tables (filled by build())
var _r_p := PackedInt32Array()
var _r_q := PackedInt32Array()
var _r_g := PackedFloat64Array()      # 1/R
var _r_name := PackedStringArray()    # optional, for set_value()
var _c_p := PackedInt32Array()
var _c_q := PackedInt32Array()
var _c_geq := PackedFloat64Array()    # C/dt, filled once dt is known
var _c_farad := PackedFloat64Array()
var _c_name := PackedStringArray()    # optional, for set_value() / get_cap_state()
var _c_vprev := PackedFloat64Array()  # voltage across each C at the previous step
var _d_p := PackedInt32Array()
var _d_q := PackedInt32Array()
var _d_vlim := PackedFloat64Array()   # last limited junction voltage (SPICE pnjlim)
var _d_vcrit := 0.0
var _q_c := PackedInt32Array()   # NPN BJT collector / base / emitter node indices
var _q_b := PackedInt32Array()
var _q_e := PackedInt32Array()
var _q_vbelim := PackedFloat64Array()
var _q_vbclim := PackedFloat64Array()
var _q_vcrit := 0.0
var _v_p := PackedInt32Array()
var _v_q := PackedInt32Array()
var _v_k := PackedInt32Array()        # branch index
var _v_val := PackedFloat64Array()
var _o_out := PackedInt32Array()
var _o_vp := PackedInt32Array()
var _o_vm := PackedInt32Array()
var _o_k := PackedInt32Array()

func build(netlist: Array, ground_name: String = "gnd") -> void:
	_ground = ground_name
	_node_idx.clear()
	_src_name_to_i.clear()
	for arr in [_r_p, _r_q, _r_g, _r_name, _c_p, _c_q, _c_geq, _c_farad, _c_name, _d_p, _d_q,
			_q_c, _q_b, _q_e, _v_p, _v_q, _v_k, _v_val, _o_out, _o_vp, _o_vm, _o_k]:
		arr.clear()

	for c in netlist:
		for nm in c["nodes"]:
			if nm != _ground and not _node_idx.has(nm):
				_node_idx[nm] = _node_idx.size()
	num_nodes = _node_idx.size()

	var branch := num_nodes
	for c in netlist:
		var ix: Array = []
		for nm in c["nodes"]:
			ix.append(-1 if nm == _ground else int(_node_idx[nm]))
		match c["type"]:
			"R":
				_r_p.append(ix[0]); _r_q.append(ix[1]); _r_g.append(1.0 / float(c["value"]))
				_r_name.append(String(c.get("name", "")))
			"C":
				_c_p.append(ix[0]); _c_q.append(ix[1])
				_c_farad.append(float(c["value"])); _c_geq.append(0.0)
				_c_name.append(String(c.get("name", "")))
			"D":
				_d_p.append(ix[0]); _d_q.append(ix[1])
			"Q":
				_q_c.append(ix[0]); _q_b.append(ix[1]); _q_e.append(ix[2])
			"V":
				_v_p.append(ix[0]); _v_q.append(ix[1]); _v_k.append(branch)
				_v_val.append(float(c.get("value", 0.0)))
				_src_name_to_i[c.get("name", "V%d" % branch)] = _v_val.size() - 1
				branch += 1
			"OPA":
				_o_out.append(ix[0]); _o_vp.append(ix[1]); _o_vm.append(ix[2]); _o_k.append(branch)
				branch += 1
			_:
				push_error("MnaSolver: unknown component type %s" % c["type"])

	n = branch
	_w = n + 1
	_base.resize(n * _w)
	_a.resize(n * _w)
	_x.resize(n); _x_new.resize(n)
	_c_vprev.resize(_c_p.size())
	_d_vlim.resize(_d_p.size())
	_q_vbelim.resize(_q_c.size())
	_q_vbclim.resize(_q_c.size())
	_d_vcrit = DIODE_N * DIODE_VT * log(DIODE_N * DIODE_VT / (sqrt(2.0) * DIODE_IS))
	_q_vcrit = BJT_VT * log(BJT_VT / (sqrt(2.0) * BJT_IS))
	reset_state()
	_refresh_dt()

func reset_state() -> void:
	_x.fill(0.0)
	_d_vlim.fill(0.0)
	_q_vbelim.fill(0.0)
	_q_vbclim.fill(0.0)
	_c_vprev.fill(0.0)
	last_iters = 0
	nonconverged = 0

## Capacitor voltages keyed by name -- lets a rebuild (topology change)
## carry the reactive state of unchanged parts instead of clicking.
func get_cap_state() -> Dictionary:
	var d := {}
	for i in _c_name.size():
		if _c_name[i] != "":
			d[_c_name[i]] = _c_vprev[i]
	return d

func set_cap_state(state: Dictionary) -> void:
	for i in _c_name.size():
		if _c_name[i] != "" and state.has(_c_name[i]):
			_c_vprev[i] = float(state[_c_name[i]])

func set_dt(v: float) -> void:
	dt = v
	_refresh_dt()

func set_source(name: String, value: float) -> void:
	if _src_name_to_i.has(name):
		_v_val[int(_src_name_to_i[name])] = value

## Change an R (ohms) or C (farads) value in place, keeping solver state
## (capacitor memory) intact -- for live slider tweaks without a rebuild.
func set_value(name: String, value: float) -> void:
	var i := _r_name.find(name)
	if i != -1:
		_r_g[i] = 1.0 / value
		_refresh_dt()
		return
	i = _c_name.find(name)
	if i != -1:
		_c_farad[i] = value
		_refresh_dt()

func node_voltage(name: String) -> float:
	if name == _ground or not _node_idx.has(name):
		return 0.0
	return _x[int(_node_idx[name])]

func has_node_name(name: String) -> bool:
	return name == _ground or _node_idx.has(name)

## rebuild the constant part of the matrix (call after dt or topology change)
func _refresh_dt() -> void:
	for i in _c_farad.size():
		_c_geq[i] = _c_farad[i] / dt
	_base.fill(0.0)
	var w := _w
	# GMIN: a tiny shunt conductance from every node to ground, so any
	# topology the player wires (floating nodes included) stays solvable.
	for i in num_nodes:
		_base[i * w + i] += 1.0e-9
	# resistors
	for i in _r_p.size():
		_add_g(_base, _r_p[i], _r_q[i], _r_g[i])
	# capacitor companion conductance (constant given dt)
	for i in _c_p.size():
		_add_g(_base, _c_p[i], _c_q[i], _c_geq[i])
	# voltage sources: structural 1s
	for i in _v_p.size():
		var p := _v_p[i]; var q := _v_q[i]; var k := _v_k[i]
		if p >= 0:
			_base[p * w + k] += 1.0; _base[k * w + p] += 1.0
		if q >= 0:
			_base[q * w + k] -= 1.0; _base[k * w + q] -= 1.0
	# op-amps: structural (non-reciprocal) 1s
	for i in _o_out.size():
		var oo := _o_out[i]; var vp := _o_vp[i]; var vm := _o_vm[i]; var k := _o_k[i]
		if oo >= 0:
			_base[oo * w + k] += 1.0
		if vp >= 0:
			_base[k * w + vp] += 1.0
		if vm >= 0:
			_base[k * w + vm] -= 1.0

func _add_g(m: PackedFloat64Array, p: int, q: int, g: float) -> void:
	var w := _w
	if p >= 0:
		m[p * w + p] += g
	if q >= 0:
		m[q * w + q] += g
	if p >= 0 and q >= 0:
		m[p * w + q] -= g
		m[q * w + p] -= g

## single admittance term Y[i][j] (multiport / non-reciprocal), ground dropped
func _stamp_y(ri: int, ci: int, y: float) -> void:
	if ri >= 0 and ci >= 0:
		_a[ri * _w + ci] += y

## SPICE-style pn-junction limiting: damp the per-iteration change in a
## junction voltage so exp() can't blow up and Newton doesn't overshoot.
func _pnjlim(vnew: float, vold: float, vt: float, vcrit: float) -> float:
	if vnew > vcrit and absf(vnew - vold) > 2.0 * vt:
		if vold > 0.0:
			var arg := 1.0 + (vnew - vold) / vt
			return vold + vt * log(arg) if arg > 0.0 else vcrit
		return vt * log(vnew / vt)
	return vnew

## Advance one timestep dt. Returns Newton iteration count.
func step() -> int:
	var w := _w
	var rhs := n  # column index of the augmented RHS
	var size := _base.size()
	var max_iters := 1 if (_d_p.is_empty() and _q_c.is_empty()) else NEWTON_MAX_ITERS  # linear -> one solve
	var iters := 0
	var i := 0
	while iters < max_iters:
		iters += 1

		# start from the constant matrix
		var t := 0
		while t < size:
			_a[t] = _base[t]
			t += 1

		# capacitor companion current sources (depend on previous timestep)
		i = 0
		while i < _c_p.size():
			var p := _c_p[i]
			var q := _c_q[i]
			var ieq := _c_geq[i] * _c_vprev[i]
			if p >= 0:
				_a[p * w + rhs] += ieq
			if q >= 0:
				_a[q * w + rhs] -= ieq
			i += 1

		# voltage source RHS
		i = 0
		while i < _v_k.size():
			_a[_v_k[i] * w + rhs] += _v_val[i]
			i += 1

		# diodes: Newton-linearised around the current guess _x
		i = 0
		while i < _d_p.size():
			var p := _d_p[i]
			var q := _d_q[i]
			var vd_raw := (0.0 if p < 0 else _x[p]) - (0.0 if q < 0 else _x[q])
			var vd := _pnjlim(vd_raw, _d_vlim[i], DIODE_N * DIODE_VT, _d_vcrit)
			_d_vlim[i] = vd
			var xarg: float = vd / (DIODE_N * DIODE_VT)
			if xarg > 40.0:
				xarg = 40.0
			elif xarg < -40.0:
				xarg = -40.0
			var e := exp(xarg)
			var id := DIODE_IS * (e - 1.0)
			var gd := DIODE_IS / (DIODE_N * DIODE_VT) * e
			var ieq := gd * vd - id
			if p >= 0:
				_a[p * w + p] += gd
				_a[p * w + rhs] += ieq
			if q >= 0:
				_a[q * w + q] += gd
				_a[q * w + rhs] -= ieq
			if p >= 0 and q >= 0:
				_a[p * w + q] -= gd
				_a[q * w + p] -= gd
			i += 1

		# NPN BJTs: Ebers-Moll transport model, Newton-linearised
		i = 0
		while i < _q_c.size():
			var nc := _q_c[i]
			var nb := _q_b[i]
			var ne := _q_e[i]
			var vb := 0.0 if nb < 0 else _x[nb]
			var vc := 0.0 if nc < 0 else _x[nc]
			var ve := 0.0 if ne < 0 else _x[ne]
			var vbe := _pnjlim((vb - ve), _q_vbelim[i], BJT_VT, _q_vcrit)
			var vbc := _pnjlim((vb - vc), _q_vbclim[i], BJT_VT, _q_vcrit)
			_q_vbelim[i] = vbe
			_q_vbclim[i] = vbc
			var ebe := exp(clampf(vbe / BJT_VT, -40.0, 40.0))
			var ebc := exp(clampf(vbc / BJT_VT, -40.0, 40.0))
			var ic0 := BJT_IS * ((ebe - ebc) - (ebc - 1.0) / BJT_BR)
			var ib0 := BJT_IS * ((ebe - 1.0) / BJT_BF + (ebc - 1.0) / BJT_BR)
			var gpi := BJT_IS / (BJT_BF * BJT_VT) * ebe
			var gmu := BJT_IS / (BJT_BR * BJT_VT) * ebc
			var gmf := BJT_IS / BJT_VT * ebe
			var gr := -(BJT_IS / BJT_VT) * ebc * (1.0 + 1.0 / BJT_BR)
			var ybb := gpi + gmu
			var ybc := -gmu
			var ybe := -gpi
			var ycb := gmf + gr
			var ycc := -gr
			var yce := -gmf
			var yeb := -(ybb + ycb)
			var yec := -(ybc + ycc)
			var yee := -(ybe + yce)
			# RHS from the (possibly limited) junction voltages, not the raw nodes
			var ieq_b := gpi * vbe + gmu * vbc - ib0
			var ieq_c := gmf * vbe + gr * vbc - ic0
			var ieq_e := -(ieq_b + ieq_c)
			_stamp_y(nb, nb, ybb); _stamp_y(nb, nc, ybc); _stamp_y(nb, ne, ybe)
			_stamp_y(nc, nb, ycb); _stamp_y(nc, nc, ycc); _stamp_y(nc, ne, yce)
			_stamp_y(ne, nb, yeb); _stamp_y(ne, nc, yec); _stamp_y(ne, ne, yee)
			if nb >= 0:
				_a[nb * w + rhs] += ieq_b
			if nc >= 0:
				_a[nc * w + rhs] += ieq_c
			if ne >= 0:
				_a[ne * w + rhs] += ieq_e
			i += 1

		_gauss()

		if max_iters == 1:
			# linear circuit: the single solve is exact, take it as-is
			i = 0
			while i < n:
				_x[i] = _x_new[i]
				i += 1
			break

		var dmax := 0.0
		i = 0
		while i < n:
			var d: float = _x_new[i] - _x[i]
			if d < 0.0:
				d = -d
			if d > dmax:
				dmax = d
			i += 1
		var scale := 1.0
		if dmax > VLIMIT:
			scale = VLIMIT / dmax
		i = 0
		while i < n:
			_x[i] += scale * (_x_new[i] - _x[i])
			i += 1
		if dmax * scale < NEWTON_TOL:
			break

	if iters >= NEWTON_MAX_ITERS:
		nonconverged += 1
	last_iters = iters
	# remember each capacitor's terminal voltage for the next step
	i = 0
	while i < _c_p.size():
		var p := _c_p[i]
		var q := _c_q[i]
		_c_vprev[i] = (0.0 if p < 0 else _x[p]) - (0.0 if q < 0 else _x[q])
		i += 1
	return iters

## dense Gaussian elimination with partial pivoting on _a -> _x_new
func _gauss() -> void:
	var w := _w
	var col := 0
	while col < n:
		var piv := col
		var best: float = _a[col * w + col]
		if best < 0.0:
			best = -best
		var r := col + 1
		while r < n:
			var v: float = _a[r * w + col]
			if v < 0.0:
				v = -v
			if v > best:
				best = v
				piv = r
			r += 1
		if piv != col:
			var c := col
			while c < w:
				var tmp: float = _a[col * w + c]
				_a[col * w + c] = _a[piv * w + c]
				_a[piv * w + c] = tmp
				c += 1
		var d: float = _a[col * w + col]
		if d < 1.0e-30 and d > -1.0e-30:
			d = 1.0e-30
		r = col + 1
		while r < n:
			var f: float = _a[r * w + col] / d
			if f != 0.0:
				var c := col
				while c < w:
					_a[r * w + c] -= f * _a[col * w + c]
					c += 1
			r += 1
		col += 1
	var row := n - 1
	while row >= 0:
		var s: float = _a[row * w + n]
		var c := row + 1
		while c < n:
			s -= _a[row * w + c] * _x_new[c]
			c += 1
		var dd: float = _a[row * w + row]
		if dd < 1.0e-30 and dd > -1.0e-30:
			dd = 1.0e-30
		_x_new[row] = s / dd
		row -= 1
