//! Voice-local acyclic audio graph with global modulation sources.
use godot::prelude::*;
use std::{collections::HashSet, f64::consts::TAU};
const SR: f64 = 44100.0;
#[derive(Clone)]
struct Osc {
    id: String,
    wave: i64,
    gain: f64,
    transpose: f64,
}
#[derive(Clone)]
struct Filter {
    id: String,
    cutoff: f64,
    enabled: bool,
}
#[derive(Clone)]
struct Lfo {
    id: String,
    rate: f64,
    depth: f64,
    phase: f64,
}
#[derive(Clone)]
struct Route {
    from: String,
    to: String,
}
#[derive(Clone)]
struct Assignment {
    id: String,
    source: String,
    target: String,
    param: String,
    amount: f64,
}
#[derive(Clone, Default)]
struct State {
    id: String,
    phase: f64,
    low: f64,
}
struct Voice {
    note: i64,
    velocity: f64,
    env: f64,
    held: bool,
    states: Vec<State>,
    filters: Vec<State>,
}
#[derive(Default)]
struct Engine {
    oscillators: Vec<Osc>,
    filters: Vec<Filter>,
    lfos: Vec<Lfo>,
    voices: Vec<Voice>,
    gain: f64,
    edges: Vec<(usize, usize)>,
    outgoing: Vec<Vec<usize>>,
    order: Vec<usize>,
    assignments: Vec<(usize, usize, u8, f64)>,
}
impl Engine {
    fn configure(
        &mut self,
        os: Vec<Osc>,
        fs: Vec<Filter>,
        routes: Vec<Route>,
        mut ls: Vec<Lfo>,
        assignments: Vec<Assignment>,
        gain: f64,
    ) -> bool {
        if os.len() > 8 || fs.len() > 8 || ls.len() > 8 || routes.len() > 128 || assignments.len() > 64 || !gain.is_finite() {
            return false;
        }
        let mut ids = HashSet::new();
        for id in os
            .iter()
            .map(|o| &o.id)
            .chain(fs.iter().map(|f| &f.id))
            .chain(ls.iter().map(|l| &l.id))
        {
            if id.is_empty() || id == "output" || id == "master" || !ids.insert(id.clone()) {
                return false;
            }
        }
        let n = os.len() + fs.len();
        let lookup = |id: &str| {
            os.iter()
                .position(|o| o.id == id)
                .or_else(|| fs.iter().position(|f| f.id == id).map(|i| i + os.len()))
        };
        let mut edges = Vec::new();
        let mut seen = HashSet::new();
        let mut degree = vec![0usize; n];
        for r in routes {
            let Some(from) = lookup(&r.from) else {
                return false;
            };
            let to = if r.to == "output" {
                n
            } else {
                let Some(i) = fs.iter().position(|f| f.id == r.to) else {
                    return false;
                };
                i + os.len()
            };
            if from == to || !seen.insert((from, to)) {
                return false;
            }
            if to < n {
                degree[to] += 1;
            }
            edges.push((from, to));
        }
        let mut queue: Vec<usize> = (0..n).filter(|i| degree[*i] == 0).collect();
        let mut order = Vec::new();
        while let Some(i) = queue.pop() {
            order.push(i);
            for &(from, to) in &edges {
                if from == i && to < n {
                    degree[to] -= 1;
                    if degree[to] == 0 {
                        queue.push(to);
                    }
                }
            }
        }
        if order.len() != n {
            return false;
        }
        let mut mapped = Vec::new();
        let mut aids = HashSet::new();
        for a in assignments {
            if a.id.is_empty() || !aids.insert(a.id) || !a.amount.is_finite() {
                return false;
            }
            let Some(source) = ls.iter().position(|l| l.id == a.source) else {
                return false;
            };
            let target = if a.target == "master" {
                n
            } else {
                let Some(i) = lookup(&a.target) else {
                    return false;
                };
                i
            };
            let param = match a.param.as_str() {
                "gain" if target < os.len() || target == n => 0,
                "transpose" if target < os.len() => 1,
                "cutoff" if target >= os.len() && target < n => 2,
                _ => return false,
            };
            mapped.push((source, target, param, a.amount.clamp(-1.0, 1.0)));
        }
        for l in &mut ls {
            if let Some(old) = self.lfos.iter().find(|x| x.id == l.id) {
                l.phase = old.phase;
            }
        }
        for v in &mut self.voices {
            v.states = os
                .iter()
                .map(|o| {
                    v.states
                        .iter()
                        .find(|s| s.id == o.id)
                        .cloned()
                        .unwrap_or(State {
                            id: o.id.clone(),
                            ..Default::default()
                        })
                })
                .collect();
            v.filters = fs
                .iter()
                .map(|f| {
                    v.filters
                        .iter()
                        .find(|s| s.id == f.id)
                        .cloned()
                        .unwrap_or(State {
                            id: f.id.clone(),
                            ..Default::default()
                        })
                })
                .collect();
        }
        self.oscillators = os;
        self.filters = fs;
        self.lfos = ls;
        self.outgoing = vec![Vec::new(); n + 1];
        for &(from, to) in &edges { self.outgoing[from].push(to); }
        self.edges = edges;
        self.order = order;
        self.assignments = mapped;
        self.gain = gain.clamp(0.0, 1.0);
        true
    }
    fn on(&mut self, note: i64, velocity: f64) {
        let note = note.clamp(0, 127);
        if velocity <= 0.0 {
            self.off(note);
            return;
        }
        if let Some(v) = self.voices.iter_mut().find(|v| v.note == note) {
            v.held = true;
            v.velocity = velocity.clamp(0.0, 1.0);
            return;
        }
        if self.voices.len() >= 8 {
            let i = self.voices.iter().position(|v| !v.held).unwrap_or(0);
            self.voices.remove(i);
        }
        self.voices.push(Voice {
            note,
            velocity: velocity.clamp(0.0, 1.0),
            env: 0.0,
            held: true,
            states: self
                .oscillators
                .iter()
                .map(|o| State {
                    id: o.id.clone(),
                    ..Default::default()
                })
                .collect(),
            filters: self
                .filters
                .iter()
                .map(|f| State {
                    id: f.id.clone(),
                    ..Default::default()
                })
                .collect(),
        });
    }
    fn off(&mut self, note: i64) {
        for v in &mut self.voices {
            if v.note == note {
                v.held = false;
            }
        }
    }
    fn modulation(&mut self) -> [[f64; 3]; 17] {
        let mut values = [0.0; 8];
        for (i, l) in self.lfos.iter_mut().enumerate() {
            values[i] = (TAU * l.phase).sin() * l.depth;
            l.phase = (l.phase + l.rate / SR).fract();
        }
        let mut m = [[0.0; 3]; 17];
        for &(source, target, param, amount) in &self.assignments {
            m[target][param as usize] += values[source] * amount;
        }
        m
    }
    fn sample(&mut self) -> f32 {
        let mods = self.modulation();
        let no = self.oscillators.len();
        let n = no + self.filters.len();
        let mut coefficients = [0.0; 8];
        for (i, f) in self.filters.iter().enumerate() {
            let cutoff = (f.cutoff * 2f64.powf((mods[no + i][2] * 4.0).clamp(-20.0, 20.0))).clamp(20.0, 18000.0);
            coefficients[i] = 1.0 - (-TAU * cutoff / SR).exp();
        }
        let mut mix = 0.0;
        for v in &mut self.voices {
            let target = if v.held { 1.0 } else { 0.0 };
            v.env +=
                (target - v.env) * (1.0 - (-1.0 / (SR * if v.held { 0.005 } else { 0.045 })).exp());
            let mut audio = [0.0; 17];
            for (i, (o, s)) in self.oscillators.iter().zip(v.states.iter_mut()).enumerate() {
                let transpose = o.transpose + mods[i][1] * 12.0;
                let dt = (440.0
                    * 2f64.powf(((v.note as f64 - 69.0 + transpose) / 12.0).clamp(-20.0, 20.0))
                    / SR)
                    .min(0.45);
                let p = s.phase;
                let x = match o.wave {
                    1 => 2.0 * p - 1.0 - blep(p, dt),
                    2 => {
                        (if p < 0.5 { 1.0 } else { -1.0 }) + blep(p, dt)
                            - blep((p + 0.5).fract(), dt)
                    }
                    _ => (TAU * p).sin(),
                };
                s.phase = (p + dt).fract();
                audio[i] = x * (o.gain + mods[i][0]).clamp(0.0, 1.0);
            }
            for &i in &self.order {
                if i >= no {
                    let f = &self.filters[i - no];
                    let s = &mut v.filters[i - no];
                    s.low += coefficients[i - no] * (audio[i] - s.low);
                    if f.enabled {
                        audio[i] = s.low;
                    }
                }
                for &to in &self.outgoing[i] {
                    audio[to] += audio[i];
                }
            }
            mix += audio[n] * v.env * v.velocity;
        }
        self.voices.retain(|v| v.held || v.env > 0.00001);
        (mix * (self.gain + mods[n][0]).clamp(0.0, 1.0) * 0.25).tanh() as f32
    }
}
fn blep(t: f64, dt: f64) -> f64 {
    if t < dt {
        let x = t / dt;
        x + x - x * x - 1.0
    } else if t > 1.0 - dt {
        let x = (t - 1.0) / dt;
        x * x + x + x + 1.0
    } else {
        0.0
    }
}
fn number(d: &VarDictionary, key: &str, default: f64, min: f64, max: f64) -> f64 {
    let n = d
        .get(key)
        .and_then(|v| {
            v.try_to::<f64>()
                .ok()
                .or_else(|| v.try_to::<i64>().ok().map(|n| n as f64))
        })
        .unwrap_or(default);
    if n.is_finite() {
        n.clamp(min, max)
    } else {
        default
    }
}
fn string(d: &VarDictionary, key: &str, default: &str) -> String {
    d.get(key)
        .and_then(|v| v.try_to::<GString>().ok())
        .map(|s| s.to_string())
        .unwrap_or(default.into())
}

fn dictionaries(a: VarArray) -> Option<Vec<VarDictionary>> {
    a.iter_shared()
        .map(|v| v.try_to::<VarDictionary>().ok())
        .collect()
}
fn parse_os(ds: &[VarDictionary]) -> Vec<Osc> {
    ds.iter()
        .map(|d| Osc {
            id: string(d, "id", ""),
            wave: number(d, "wave", 0.0, 0.0, 2.0) as i64,
            gain: number(d, "gain", 0.5, 0.0, 1.0),
            transpose: number(d, "transpose", 0.0, -24.0, 24.0),
        })
        .collect()
}
fn parse_ls(ds: &[VarDictionary]) -> Vec<Lfo> {
    ds.iter()
        .map(|d| Lfo {
            id: string(d, "id", ""),
            rate: number(d, "rate", 1.0, 0.05, 20.0),
            depth: number(d, "depth", 0.0, 0.0, 1.0),
            phase: 0.0,
        })
        .collect()
}
#[derive(GodotClass)]
#[class(base=RefCounted,init)]
pub struct InstrumentSynthRs {
    engine: Engine,
    base: Base<RefCounted>,
}
#[godot_api]
impl InstrumentSynthRs {
    #[func]
    fn configure_graph(
        &mut self,
        oscillators: VarArray,
        filters: VarArray,
        routes: VarArray,
        modulators: VarArray,
        assignments: VarArray,
        master_gain: f64,
    ) -> bool {
        let (Some(os), Some(fs), Some(rs), Some(ls), Some(asg)) = (
            dictionaries(oscillators),
            dictionaries(filters),
            dictionaries(routes),
            dictionaries(modulators),
            dictionaries(assignments),
        ) else {
            return false;
        };
        let filters = fs
            .iter()
            .map(|d| Filter {
                id: string(d, "id", ""),
                cutoff: number(d, "cutoff", 8000.0, 40.0, 16000.0),
                enabled: d
                    .get("enabled")
                    .and_then(|v| v.try_to::<bool>().ok())
                    .unwrap_or(true),
            })
            .collect();
        let routes = rs
            .iter()
            .map(|d| Route {
                from: string(d, "from", ""),
                to: string(d, "to", ""),
            })
            .collect();
        let assignments = asg
            .iter()
            .map(|d| Assignment {
                id: string(d, "id", ""),
                source: string(d, "source", ""),
                target: string(d, "target", ""),
                param: string(d, "param", ""),
                amount: number(d, "amount", 0.0, -1.0, 1.0),
            })
            .collect();
        self.engine.configure(
            parse_os(&os),
            filters,
            routes,
            parse_ls(&ls),
            assignments,
            master_gain,
        )
    }
    /// Compatibility translation for the original per-oscillator filter prototype.
    #[func]
    fn configure(&mut self, oscillators: VarArray, modulators: VarArray, master_gain: f64) {
        let (Some(os), Some(ls)) = (dictionaries(oscillators), dictionaries(modulators)) else {
            return;
        };
        let oscillators = parse_os(&os);
        let lfos = parse_ls(&ls);
        let mut filters = Vec::new();
        let mut routes = Vec::new();
        let mut assignments = Vec::new();
        for (o, d) in oscillators.iter().zip(os.iter()) {
            let fid = format!("legacy_filter_{}", o.id);
            filters.push(Filter {
                id: fid.clone(),
                cutoff: number(d, "cutoff", 8000.0, 40.0, 16000.0),
                enabled: d
                    .get("filter")
                    .and_then(|v| v.try_to::<bool>().ok())
                    .unwrap_or(true),
            });
            routes.push(Route {
                from: o.id.clone(),
                to: fid.clone(),
            });
            routes.push(Route {
                from: fid.clone(),
                to: "output".into(),
            });
            for (l, ld) in lfos.iter().zip(ls.iter()) {
                let target = string(ld, "target", "all");
                if target == "all" || target == o.id {
                    assignments.push(Assignment {
                        id: format!("{}_{}", l.id, o.id),
                        source: l.id.clone(),
                        target: fid.clone(),
                        param: "cutoff".into(),
                        amount: 1.0,
                    });
                }
            }
        }
        self.engine
            .configure(oscillators, filters, routes, lfos, assignments, master_gain);
    }
    #[func]
    fn note_on(&mut self, note: i64, velocity: f64) {
        self.engine
            .on(note, if velocity.is_finite() { velocity } else { 0.0 });
    }
    #[func]
    fn note_off(&mut self, note: i64) {
        self.engine.off(note);
    }
    #[func]
    fn all_notes_off(&mut self) {
        for v in &mut self.engine.voices {
            v.held = false;
        }
    }
    #[func]
    fn render(&mut self, frames: i64) -> PackedVector2Array {
        let samples: Vec<Vector2> = (0..frames.clamp(0, 16384))
            .map(|_| {
                let s = self.engine.sample();
                Vector2::new(s, s)
            })
            .collect();
        PackedVector2Array::from(samples.as_slice())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn osc(id: &str) -> Osc {
        Osc {
            id: id.into(),
            wave: 0,
            gain: 0.5,
            transpose: 0.0,
        }
    }
    fn filter(id: &str) -> Filter {
        Filter {
            id: id.into(),
            cutoff: 100.0,
            enabled: true,
        }
    }
    fn route(from: &str, to: &str) -> Route {
        Route {
            from: from.into(),
            to: to.into(),
        }
    }
    fn make(fs: Vec<Filter>, rs: Vec<Route>) -> Engine {
        let mut e = Engine::default();
        assert!(e.configure(vec![osc("a"), osc("b")], fs, rs, vec![], vec![], 0.5));
        e
    }
    fn energy(e: &mut Engine) -> f32 {
        e.on(69, 1.0);
        for _ in 0..4410 {
            e.sample();
        }
        (0..4410).map(|_| e.sample().abs()).sum()
    }
    #[test]
    fn pitch_silence_release_and_polyphony() {
        let mut e = make(vec![], vec![route("a", "output")]);
        assert_eq!(e.sample(), 0.0);
        e.on(69, 1.0);
        for _ in 0..4410 {
            e.sample();
        }
        let a: Vec<_> = (0..44100).map(|_| e.sample()).collect();
        let crossings = a.windows(2).filter(|s| s[0] <= 0.0 && s[1] > 0.0).count();
        assert!((439..=441).contains(&crossings));
        e.off(69);
        for _ in 0..44100 {
            e.sample();
        }
        assert_eq!(e.sample(), 0.0);
        for n in 40..60 {
            e.on(n, 1.0);
        }
        assert_eq!(e.voices.len(), 8);
        for _ in 0..1000 {
            assert!(e.sample().abs() <= 1.0);
        }
    }
    #[test]
    fn routing_shared_serial_dry_disconnected() {
        let mut dry = make(vec![], vec![route("a", "output")]);
        let dry_energy = energy(&mut dry);
        let mut disconnected = make(vec![filter("f")], vec![route("a", "f")]);
        assert_eq!(energy(&mut disconnected), 0.0);
        let mut single = make(
            vec![filter("f")],
            vec![route("a", "f"), route("f", "output")],
        );
        let single_energy = energy(&mut single);
        assert!(single_energy < dry_energy * 0.3);
        let mut shared = make(
            vec![filter("f")],
            vec![route("a", "f"), route("b", "f"), route("f", "output")],
        );
        let shared_energy = energy(&mut shared);
        assert!(shared_energy > single_energy * 1.9);
        let mut serial = make(
            vec![filter("f"), filter("g")],
            vec![route("a", "f"), route("f", "g"), route("g", "output")],
        );
        assert!(energy(&mut serial) < single_energy * 0.3);
        let mut bypass = filter("f");
        bypass.enabled = false;
        let mut bypass = make(vec![bypass], vec![route("a", "f"), route("f", "output")]);
        assert_eq!(energy(&mut bypass), dry_energy);
        let mut fanout = make(
            vec![Filter {
                id: "f".into(),
                cutoff: 100.0,
                enabled: false,
            }],
            vec![route("a", "f"), route("a", "output"), route("f", "output")],
        );
        assert!(energy(&mut fanout) > dry_energy * 1.9);
    }
    #[test]
    fn invalid_graph_is_atomic() {
        let mut e = make(vec![], vec![route("a", "output")]);
        energy(&mut e);
        let phase = e.voices[0].states[0].phase;
        for rs in [
            vec![route("a", "f"), route("f", "g"), route("g", "f")],
            vec![route("a", "missing")],
            vec![route("a", "a")],
            vec![route("a", "output"), route("a", "output")],
            vec![route("output", "f")],
        ] {
            assert!(!e.configure(
                vec![osc("a")],
                vec![filter("f"), filter("g")],
                rs,
                vec![],
                vec![],
                0.9
            ));
            assert_eq!(e.gain, 0.5);
            assert_eq!(e.voices[0].states[0].phase, phase);
            assert_eq!(e.filters.len(), 0);
        }
        assert!(!e.configure(
            vec![osc("a"), osc("a")],
            vec![],
            vec![],
            vec![],
            vec![],
            0.1
        ));
    }
    fn assignment(id: &str, target: &str, param: &str, amount: f64) -> Assignment {
        Assignment {
            id: id.into(),
            source: "l".into(),
            target: target.into(),
            param: param.into(),
            amount,
        }
    }
    #[test]
    fn signed_multiple_target_modulation_and_state_retention() {
        let mut e = Engine::default();
        let os = vec![osc("a")];
        let fs = vec![filter("f")];
        let rs = vec![route("a", "f"), route("f", "output")];
        let ls = vec![Lfo {
            id: "l".into(),
            rate: 2.0,
            depth: 0.5,
            phase: 0.25,
        }];
        let asg = vec![
            assignment("1", "a", "gain", 1.0),
            assignment("2", "a", "gain", -0.25),
            assignment("3", "a", "transpose", -1.0),
            assignment("4", "f", "cutoff", 0.5),
            assignment("5", "master", "gain", -0.5),
        ];
        assert!(e.configure(
            os.clone(),
            fs.clone(),
            rs.clone(),
            ls.clone(),
            asg.clone(),
            0.5
        ));
        let m = e.modulation();
        assert_eq!(m[0][0], 0.375);
        assert_eq!(m[0][1], -0.5);
        assert_eq!(m[1][2], 0.25);
        assert_eq!(m[2][0], -0.25);
        e.on(69, 1.0);
        for _ in 0..1000 {
            e.sample();
        }
        let phase = e.voices[0].states[0].phase;
        let low = e.voices[0].filters[0].low;
        let lphase = e.lfos[0].phase;
        assert!(e.configure(os, fs, rs, ls, asg, 0.4));
        assert_eq!(e.voices[0].states[0].phase, phase);
        assert_eq!(e.voices[0].filters[0].low, low);
        assert_eq!(e.lfos[0].phase, lphase);
    }
    #[test]
    fn modulation_changes_sound_and_rejects_wrong_parameter() {
        let mut dry = make(vec![], vec![route("a", "output")]);
        let mut wet = make(vec![], vec![route("a", "output")]);
        let ls = vec![Lfo {
            id: "l".into(),
            rate: 0.05,
            depth: 1.0,
            phase: 0.25,
        }];
        assert!(wet.configure(
            wet.oscillators.clone(),
            vec![],
            vec![route("a", "output")],
            ls.clone(),
            vec![assignment("x", "a", "gain", -1.0)],
            0.5
        ));
        assert!(energy(&mut dry) > 10.0);
        assert_eq!(energy(&mut wet), 0.0);
        assert!(!wet.configure(
            vec![osc("a")],
            vec![],
            vec![],
            ls,
            vec![assignment("x", "a", "cutoff", 1.0)],
            0.5
        ));
    }
}
