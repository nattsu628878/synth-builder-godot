//! Rust port of `mna_solver.gd` (see nattsu-hub/projects/synth-builder-godot.md).
//!
//! Spike #3 measured that a *generic* netlist MNA solver does not fit the
//! real-time audio budget in GDScript once you add nonlinearity,
//! oversampling, or polyphony. This is the same algorithm in Rust, to be
//! run as a GDExtension. The GDScript version stays as the golden
//! reference; `bench_mna.gd` cross-checks this port against it.
//!
//! Components: R, C (backward-Euler companion), ideal V source, Shockley
//! diode (Newton-Raphson with scaled-step damping), ideal op-amp (nullor).
//! Dense Gaussian elimination with partial pivoting.

use std::collections::HashMap;

const DIODE_IS: f64 = 2.52e-9;
const DIODE_N: f64 = 1.752;
const DIODE_VT: f64 = 0.025852;

// NPN BJT, Ebers-Moll transport form (fixed model, 2N3904-ish)
const BJT_IS: f64 = 1.0e-14;
const BJT_BF: f64 = 200.0;
const BJT_BR: f64 = 2.0;
const BJT_VT: f64 = 0.025852;
const NEWTON_MAX_ITERS: i32 = 50;
const NEWTON_TOL: f64 = 1.0e-7;
const VLIMIT: f64 = 0.5;

/// One parsed netlist entry, node names already known. `value` / `name`
/// are only meaningful for some kinds; the caller fills what applies.
pub struct RawComp {
    pub typ: String,
    pub nodes: Vec<String>,
    pub value: Option<f64>,
    pub name: Option<String>,
}

#[derive(Default)]
pub struct Mna {
    pub n: usize,
    pub num_nodes: usize,
    pub dt: f64,
    pub last_iters: i32,
    pub nonconverged: i64,

    w: usize,
    base: Vec<f64>,
    a: Vec<f64>,
    x: Vec<f64>,
    x_new: Vec<f64>,
    c_vprev: Vec<f64>, // voltage across each capacitor at the previous step

    // typed component tables (indices: -1 == ground)
    r: Vec<(i32, i32, f64)>,        // p, q, 1/R
    r_name: Vec<String>,            // parallel to `r`, "" if unnamed
    c: Vec<(i32, i32, f64, f64)>,   // p, q, Geq (=C/dt), farad
    c_name: Vec<String>,            // parallel to `c`
    d: Vec<(i32, i32)>,             // anode, cathode
    d_vlim: Vec<f64>,               // last limited junction voltage (SPICE pnjlim)
    d_vcrit: f64,
    q: Vec<(i32, i32, i32)>,        // NPN BJT: collector, base, emitter
    q_vbelim: Vec<f64>,
    q_vbclim: Vec<f64>,
    q_vcrit: f64,
    v: Vec<(i32, i32, usize)>,      // p, q, branch index
    v_val: Vec<f64>,                // source values, parallel to `v`
    v_name: Vec<String>,            // parallel to `v`
    opa: Vec<(i32, i32, i32, usize)>, // out, v+, v-, branch index

    node_idx: HashMap<String, usize>,
    ground: String,
}

impl Mna {
    pub fn new() -> Self {
        Self { dt: 1.0 / 44100.0, ..Default::default() }
    }

    pub fn build(&mut self, entries: &[RawComp], ground: &str) {
        self.ground = ground.to_string();
        self.node_idx.clear();
        self.r.clear();
        self.r_name.clear();
        self.c.clear();
        self.c_name.clear();
        self.d.clear();
        self.d_vlim.clear();
        self.q.clear();
        self.q_vbelim.clear();
        self.q_vbclim.clear();
        self.v.clear();
        self.v_val.clear();
        self.v_name.clear();
        self.opa.clear();

        for e in entries {
            for nm in &e.nodes {
                if nm != &self.ground && !self.node_idx.contains_key(nm) {
                    let idx = self.node_idx.len();
                    self.node_idx.insert(nm.clone(), idx);
                }
            }
        }
        self.num_nodes = self.node_idx.len();

        let idx_of = |nm: &str, m: &HashMap<String, usize>, g: &str| -> i32 {
            if nm == g { -1 } else { m[nm] as i32 }
        };

        let mut branch = self.num_nodes;
        for e in entries {
            let ix: Vec<i32> = e
                .nodes
                .iter()
                .map(|nm| idx_of(nm, &self.node_idx, &self.ground))
                .collect();
            match e.typ.as_str() {
                "R" => {
                    self.r.push((ix[0], ix[1], 1.0 / e.value.unwrap_or(1.0)));
                    self.r_name.push(e.name.clone().unwrap_or_default());
                }
                "C" => {
                    self.c.push((ix[0], ix[1], 0.0, e.value.unwrap_or(0.0)));
                    self.c_name.push(e.name.clone().unwrap_or_default());
                }
                "D" => self.d.push((ix[0], ix[1])),
                "Q" => self.q.push((ix[0], ix[1], ix[2])), // collector, base, emitter
                "V" => {
                    self.v.push((ix[0], ix[1], branch));
                    self.v_val.push(e.value.unwrap_or(0.0));
                    self.v_name
                        .push(e.name.clone().unwrap_or_else(|| format!("V{branch}")));
                    branch += 1;
                }
                "OPA" => {
                    self.opa.push((ix[0], ix[1], ix[2], branch));
                    branch += 1;
                }
                other => panic!("MnaSolver: unknown component type {other}"),
            }
        }

        self.n = branch;
        self.w = self.n + 1;
        self.base = vec![0.0; self.n * self.w];
        self.a = vec![0.0; self.n * self.w];
        self.x = vec![0.0; self.n];
        self.x_new = vec![0.0; self.n];
        self.c_vprev = vec![0.0; self.c.len()];
        self.d_vlim = vec![0.0; self.d.len()];
        self.q_vbelim = vec![0.0; self.q.len()];
        self.q_vbclim = vec![0.0; self.q.len()];
        self.d_vcrit = DIODE_N * DIODE_VT * (DIODE_N * DIODE_VT / (2.0_f64.sqrt() * DIODE_IS)).ln();
        self.q_vcrit = BJT_VT * (BJT_VT / (2.0_f64.sqrt() * BJT_IS)).ln();
        self.reset_state();
        self.refresh_dt();
    }

    pub fn reset_state(&mut self) {
        self.x.iter_mut().for_each(|v| *v = 0.0);
        self.c_vprev.iter_mut().for_each(|v| *v = 0.0);
        self.d_vlim.iter_mut().for_each(|v| *v = 0.0);
        self.q_vbelim.iter_mut().for_each(|v| *v = 0.0);
        self.q_vbclim.iter_mut().for_each(|v| *v = 0.0);
        self.last_iters = 0;
        self.nonconverged = 0;
    }

    /// Capacitor voltages keyed by name, so a rebuild (topology change)
    /// can carry the reactive state of unchanged parts instead of clicking.
    pub fn get_cap_state(&self) -> Vec<(String, f64)> {
        self.c_name
            .iter()
            .zip(&self.c_vprev)
            .filter(|(n, _)| !n.is_empty())
            .map(|(n, &v)| (n.clone(), v))
            .collect()
    }

    pub fn set_cap_state(&mut self, name: &str, value: f64) {
        if let Some(i) = self.c_name.iter().position(|n| n == name) {
            self.c_vprev[i] = value;
        }
    }

    pub fn set_dt(&mut self, dt: f64) {
        self.dt = dt;
        self.refresh_dt();
    }

    pub fn set_source(&mut self, name: &str, value: f64) {
        if let Some(i) = self.v_name.iter().position(|n| n == name) {
            self.v_val[i] = value;
        }
    }

    /// Change an R (ohms) or C (farads) value in place, keeping solver
    /// state intact -- for live slider tweaks without a rebuild.
    pub fn set_value(&mut self, name: &str, value: f64) {
        if let Some(i) = self.r_name.iter().position(|n| n == name) {
            self.r[i].2 = 1.0 / value;
            self.refresh_dt();
        } else if let Some(i) = self.c_name.iter().position(|n| n == name) {
            self.c[i].3 = value;
            self.refresh_dt();
        }
    }

    pub fn node_voltage(&self, name: &str) -> f64 {
        if name == self.ground {
            return 0.0;
        }
        self.node_idx.get(name).map_or(0.0, |&i| self.x[i])
    }

    /// Rebuild the constant part of the matrix (call after dt / topology change).
    fn refresh_dt(&mut self) {
        for entry in self.c.iter_mut() {
            entry.2 = entry.3 / self.dt;
        }
        for slot in self.base.iter_mut() {
            *slot = 0.0;
        }
        let w = self.w;
        // GMIN: tiny shunt from every node to ground so any wiring the
        // player makes (floating nodes included) stays solvable.
        for i in 0..self.num_nodes {
            self.base[i * w + i] += 1.0e-9;
        }
        for &(p, q, g) in &self.r {
            add_g(&mut self.base, w, p, q, g);
        }
        for &(p, q, geq, _) in &self.c {
            add_g(&mut self.base, w, p, q, geq);
        }
        for &(p, q, k) in &self.v {
            if p >= 0 {
                self.base[p as usize * w + k] += 1.0;
                self.base[k * w + p as usize] += 1.0;
            }
            if q >= 0 {
                self.base[q as usize * w + k] -= 1.0;
                self.base[k * w + q as usize] -= 1.0;
            }
        }
        for &(out, vp, vm, k) in &self.opa {
            if out >= 0 {
                self.base[out as usize * w + k] += 1.0;
            }
            if vp >= 0 {
                self.base[k * w + vp as usize] += 1.0;
            }
            if vm >= 0 {
                self.base[k * w + vm as usize] -= 1.0;
            }
        }
    }

    /// Advance one timestep dt. Returns the Newton iteration count.
    pub fn step(&mut self) -> i32 {
        let w = self.w;
        let n = self.n;
        let rhs = n;
        let max_iters = if self.d.is_empty() && self.q.is_empty() { 1 } else { NEWTON_MAX_ITERS };
        let mut iters = 0;

        while iters < max_iters {
            iters += 1;

            self.a.copy_from_slice(&self.base);

            // capacitor companion current sources (depend on previous step)
            for (ci, &(p, q, geq, _)) in self.c.iter().enumerate() {
                let ieq = geq * self.c_vprev[ci];
                if p >= 0 {
                    self.a[p as usize * w + rhs] += ieq;
                }
                if q >= 0 {
                    self.a[q as usize * w + rhs] -= ieq;
                }
            }

            // voltage source RHS
            for (i, &(_, _, k)) in self.v.iter().enumerate() {
                self.a[k * w + rhs] += self.v_val[i];
            }

            // diodes: Newton-linearised around the current guess x
            for (di, &(p, q)) in self.d.iter().enumerate() {
                let vpv = if p < 0 { 0.0 } else { self.x[p as usize] };
                let vqv = if q < 0 { 0.0 } else { self.x[q as usize] };
                let vd = pnjlim(vpv - vqv, self.d_vlim[di], DIODE_N * DIODE_VT, self.d_vcrit);
                self.d_vlim[di] = vd;
                let xarg = (vd / (DIODE_N * DIODE_VT)).clamp(-40.0, 40.0);
                let e = xarg.exp();
                let id = DIODE_IS * (e - 1.0);
                let gd = DIODE_IS / (DIODE_N * DIODE_VT) * e;
                let ieq = gd * vd - id;
                if p >= 0 {
                    self.a[p as usize * w + p as usize] += gd;
                    self.a[p as usize * w + rhs] += ieq;
                }
                if q >= 0 {
                    self.a[q as usize * w + q as usize] += gd;
                    self.a[q as usize * w + rhs] -= ieq;
                }
                if p >= 0 && q >= 0 {
                    self.a[p as usize * w + q as usize] -= gd;
                    self.a[q as usize * w + p as usize] -= gd;
                }
            }

            // NPN BJTs: Ebers-Moll transport model, Newton-linearised.
            for (qi, &(nc, nb, ne)) in self.q.iter().enumerate() {
                let vb = if nb < 0 { 0.0 } else { self.x[nb as usize] };
                let vc = if nc < 0 { 0.0 } else { self.x[nc as usize] };
                let ve = if ne < 0 { 0.0 } else { self.x[ne as usize] };
                let vbe = pnjlim(vb - ve, self.q_vbelim[qi], BJT_VT, self.q_vcrit);
                let vbc = pnjlim(vb - vc, self.q_vbclim[qi], BJT_VT, self.q_vcrit);
                self.q_vbelim[qi] = vbe;
                self.q_vbclim[qi] = vbc;
                let ebe = (vbe / BJT_VT).clamp(-40.0, 40.0).exp();
                let ebc = (vbc / BJT_VT).clamp(-40.0, 40.0).exp();
                let ic0 = BJT_IS * ((ebe - ebc) - (ebc - 1.0) / BJT_BR);
                let ib0 = BJT_IS * ((ebe - 1.0) / BJT_BF + (ebc - 1.0) / BJT_BR);
                let gpi = BJT_IS / (BJT_BF * BJT_VT) * ebe; // d ib / d Vbe
                let gmu = BJT_IS / (BJT_BR * BJT_VT) * ebc; // d ib / d Vbc
                let gmf = BJT_IS / BJT_VT * ebe; // d ic / d Vbe
                let gr = -(BJT_IS / BJT_VT) * ebc * (1.0 + 1.0 / BJT_BR); // d ic / d Vbc (<= 0)
                // Y[i][j] = d I_i / d V_j, i,j in {b,c,e}; I_e = -(I_b + I_c)
                let ybb = gpi + gmu;
                let ybc = -gmu;
                let ybe = -gpi;
                let ycb = gmf + gr;
                let ycc = -gr;
                let yce = -gmf;
                let yeb = -(ybb + ycb);
                let yec = -(ybc + ycc);
                let yee = -(ybe + yce);
                // RHS from the (possibly limited) junction voltages, not raw nodes
                let ieq_b = gpi * vbe + gmu * vbc - ib0;
                let ieq_c = gmf * vbe + gr * vbc - ic0;
                let ieq_e = -(ieq_b + ieq_c);
                stamp_y(&mut self.a, w, nb, nb, ybb);
                stamp_y(&mut self.a, w, nb, nc, ybc);
                stamp_y(&mut self.a, w, nb, ne, ybe);
                stamp_y(&mut self.a, w, nc, nb, ycb);
                stamp_y(&mut self.a, w, nc, nc, ycc);
                stamp_y(&mut self.a, w, nc, ne, yce);
                stamp_y(&mut self.a, w, ne, nb, yeb);
                stamp_y(&mut self.a, w, ne, nc, yec);
                stamp_y(&mut self.a, w, ne, ne, yee);
                if nb >= 0 {
                    self.a[nb as usize * w + rhs] += ieq_b;
                }
                if nc >= 0 {
                    self.a[nc as usize * w + rhs] += ieq_c;
                }
                if ne >= 0 {
                    self.a[ne as usize * w + rhs] += ieq_e;
                }
            }

            gauss(&mut self.a, w, n, &mut self.x_new);

            if max_iters == 1 {
                self.x.copy_from_slice(&self.x_new);
                break;
            }

            let mut dmax = 0.0_f64;
            for i in 0..n {
                let d = (self.x_new[i] - self.x[i]).abs();
                if d > dmax {
                    dmax = d;
                }
            }
            let scale = if dmax > VLIMIT { VLIMIT / dmax } else { 1.0 };
            for i in 0..n {
                self.x[i] += scale * (self.x_new[i] - self.x[i]);
            }
            if dmax * scale < NEWTON_TOL {
                break;
            }
        }

        if iters >= max_iters && max_iters != 1 {
            self.nonconverged += 1;
        }
        self.last_iters = iters;
        // remember each capacitor's terminal voltage for the next step
        for (ci, &(p, q, _, _)) in self.c.iter().enumerate() {
            let vp = if p < 0 { 0.0 } else { self.x[p as usize] };
            let vq = if q < 0 { 0.0 } else { self.x[q as usize] };
            self.c_vprev[ci] = vp - vq;
        }
        iters
    }
}

/// Add a single admittance term Y[i][j] (multiport / non-reciprocal), with
/// ground (index < 0) rows and columns dropped.
fn stamp_y(a: &mut [f64], w: usize, i: i32, j: i32, y: f64) {
    if i >= 0 && j >= 0 {
        a[i as usize * w + j as usize] += y;
    }
}

/// SPICE-style pn-junction limiting: damp the per-iteration change in a
/// junction voltage so exp() can't blow up and Newton doesn't overshoot.
fn pnjlim(vnew: f64, vold: f64, vt: f64, vcrit: f64) -> f64 {
    if vnew > vcrit && (vnew - vold).abs() > 2.0 * vt {
        if vold > 0.0 {
            let arg = 1.0 + (vnew - vold) / vt;
            if arg > 0.0 {
                vold + vt * arg.ln()
            } else {
                vcrit
            }
        } else {
            vt * (vnew / vt).ln()
        }
    } else {
        vnew
    }
}

fn add_g(m: &mut [f64], w: usize, p: i32, q: i32, g: f64) {
    if p >= 0 {
        m[p as usize * w + p as usize] += g;
    }
    if q >= 0 {
        m[q as usize * w + q as usize] += g;
    }
    if p >= 0 && q >= 0 {
        m[p as usize * w + q as usize] -= g;
        m[q as usize * w + p as usize] -= g;
    }
}

/// Dense Gaussian elimination with partial pivoting on the `n x (n+1)`
/// augmented matrix `a` (row-major, stride `w`); solution into `out`.
fn gauss(a: &mut [f64], w: usize, n: usize, out: &mut [f64]) {
    for col in 0..n {
        let mut piv = col;
        let mut best = a[col * w + col].abs();
        for r in (col + 1)..n {
            let v = a[r * w + col].abs();
            if v > best {
                best = v;
                piv = r;
            }
        }
        if piv != col {
            for c in col..w {
                a.swap(col * w + c, piv * w + c);
            }
        }
        let mut d = a[col * w + col];
        if d.abs() < 1.0e-30 {
            d = 1.0e-30;
        }
        for r in (col + 1)..n {
            let f = a[r * w + col] / d;
            if f != 0.0 {
                for c in col..w {
                    a[r * w + c] -= f * a[col * w + c];
                }
            }
        }
    }
    for row in (0..n).rev() {
        let mut s = a[row * w + n];
        for c in (row + 1)..n {
            s -= a[row * w + c] * out[c];
        }
        let mut d = a[row * w + row];
        if d.abs() < 1.0e-30 {
            d = 1.0e-30;
        }
        out[row] = s / d;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clipper() -> Vec<RawComp> {
        vec![
            RawComp { typ: "V".into(), nodes: vec!["in".into(), "gnd".into()], value: Some(0.0), name: Some("vin".into()) },
            RawComp { typ: "R".into(), nodes: vec!["in".into(), "out".into()], value: Some(4700.0), name: None },
            RawComp { typ: "C".into(), nodes: vec!["out".into(), "gnd".into()], value: Some(10.0e-9), name: None },
            RawComp { typ: "D".into(), nodes: vec!["out".into(), "gnd".into()], value: None, name: None },
            RawComp { typ: "D".into(), nodes: vec!["gnd".into(), "out".into()], value: None, name: None },
        ]
    }

    #[test]
    fn clipper_bounds_output_and_stays_finite() {
        let mut m = Mna::new();
        m.build(&clipper(), "gnd");
        m.set_dt(1.0 / 44100.0);
        let mut phase = 0.0_f64;
        let step = 220.0 / 44100.0;
        let mut peak_out = 0.0_f64;
        for _ in 0..44100 {
            phase = (phase + step).fract();
            let vin = 3.0 * (2.0 * phase - 1.0); // +/-3 V drive, well past the diode knee
            m.set_source("vin", vin);
            m.step();
            let v = m.node_voltage("out");
            assert!(v.is_finite());
            peak_out = peak_out.max(v.abs());
        }
        // anti-parallel diodes clamp the swing to roughly a diode drop
        assert!(peak_out < 0.8, "peak_out = {peak_out}");
        assert!(peak_out > 0.3, "peak_out = {peak_out}");
        assert_eq!(m.nonconverged, 0);
    }

    #[test]
    fn linear_rc_takes_single_solve() {
        let nl = vec![
            RawComp { typ: "V".into(), nodes: vec!["in".into(), "gnd".into()], value: Some(1.0), name: Some("vin".into()) },
            RawComp { typ: "R".into(), nodes: vec!["in".into(), "out".into()], value: Some(1000.0), name: None },
            RawComp { typ: "C".into(), nodes: vec!["out".into(), "gnd".into()], value: Some(100.0e-9), name: None },
        ];
        let mut m = Mna::new();
        m.build(&nl, "gnd");
        m.set_dt(1.0 / 44100.0);
        m.set_source("vin", 1.0);
        for _ in 0..44100 {
            assert_eq!(m.step(), 1); // no Newton loop for a linear circuit
        }
        // RC settled to the 1 V rail
        assert!((m.node_voltage("out") - 1.0).abs() < 1.0e-3);
    }

    /// Common-emitter stage: Vcc=9V -> Rc=2k -> collector; Vbb -> Rb=100k ->
    /// base; emitter to ground. The transistor should turn on (Vc well below
    /// Vcc, not saturated) and invert + amplify a base-voltage wiggle.
    #[test]
    fn common_emitter_amplifies_and_inverts() {
        let ce = |vbb: f64| {
            vec![
                RawComp { typ: "V".into(), nodes: vec!["vcc".into(), "gnd".into()], value: Some(9.0), name: Some("vcc".into()) },
                RawComp { typ: "V".into(), nodes: vec!["vbb".into(), "gnd".into()], value: Some(vbb), name: Some("vbb".into()) },
                RawComp { typ: "R".into(), nodes: vec!["vcc".into(), "col".into()], value: Some(2000.0), name: None },
                RawComp { typ: "R".into(), nodes: vec!["vbb".into(), "bas".into()], value: Some(100000.0), name: None },
                RawComp { typ: "Q".into(), nodes: vec!["col".into(), "bas".into(), "gnd".into()], value: None, name: None },
            ]
        };
        let settle = |vbb: f64| -> f64 {
            let mut m = Mna::new();
            m.build(&ce(vbb), "gnd");
            m.set_dt(1.0 / 44100.0);
            for _ in 0..4410 {
                m.step();
            }
            assert_eq!(m.nonconverged, 0);
            m.node_voltage("col")
        };
        let vc = settle(2.0);
        assert!(vc.is_finite());
        assert!(vc > 0.05 && vc < 8.5, "Vc = {vc} (should be on, not saturated/off)");
        // raising the base drives more Ic -> collector falls (inverting gain > 1)
        let vc_hi = settle(2.05);
        let gain = (vc_hi - vc) / 0.05;
        assert!(gain < -2.0, "small-signal gain = {gain} (expected inverting, |A|>2)");
    }
}
