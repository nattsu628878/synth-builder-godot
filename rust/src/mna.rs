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
    x_prev: Vec<f64>,

    // typed component tables (indices: -1 == ground)
    r: Vec<(i32, i32, f64)>,        // p, q, 1/R
    c: Vec<(i32, i32, f64, f64)>,   // p, q, Geq (=C/dt), farad
    d: Vec<(i32, i32)>,             // anode, cathode
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
        self.c.clear();
        self.d.clear();
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
                "R" => self.r.push((ix[0], ix[1], 1.0 / e.value.unwrap_or(1.0))),
                "C" => self.c.push((ix[0], ix[1], 0.0, e.value.unwrap_or(0.0))),
                "D" => self.d.push((ix[0], ix[1])),
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
        self.x_prev = vec![0.0; self.n];
        self.reset_state();
        self.refresh_dt();
    }

    pub fn reset_state(&mut self) {
        self.x.iter_mut().for_each(|v| *v = 0.0);
        self.x_prev.iter_mut().for_each(|v| *v = 0.0);
        self.last_iters = 0;
        self.nonconverged = 0;
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

    pub fn node_voltage(&self, name: &str) -> f64 {
        if name == self.ground {
            0.0
        } else {
            self.x[self.node_idx[name]]
        }
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
        let max_iters = if self.d.is_empty() { 1 } else { NEWTON_MAX_ITERS };
        let mut iters = 0;

        while iters < max_iters {
            iters += 1;

            self.a.copy_from_slice(&self.base);

            // capacitor companion current sources (depend on previous step)
            for &(p, q, geq, _) in &self.c {
                let vp = if p < 0 { 0.0 } else { self.x_prev[p as usize] };
                let vq = if q < 0 { 0.0 } else { self.x_prev[q as usize] };
                let ieq = geq * (vp - vq);
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
            for &(p, q) in &self.d {
                let vpv = if p < 0 { 0.0 } else { self.x[p as usize] };
                let vqv = if q < 0 { 0.0 } else { self.x[q as usize] };
                let vd = vpv - vqv;
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
        self.x_prev.copy_from_slice(&self.x);
        iters
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
}
