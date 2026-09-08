//! Independent software-instrument engine; circuit simulation is intentionally separate.
use godot::prelude::*;
use std::f64::consts::TAU;
const SR: f64 = 44100.0;
#[derive(Clone)]
struct Osc {
    id: String,
    wave: i64,
    gain: f64,
    transpose: f64,
    filter: bool,
    cutoff: f64,
}
struct Lfo {
    id: String,
    rate: f64,
    depth: f64,
    target: String,
    phase: f64,
}
#[derive(Default, Clone)]
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
}
#[derive(Default)]
struct Engine {
    oscillators: Vec<Osc>,
    lfos: Vec<Lfo>,
    voices: Vec<Voice>,
    gain: f64,
}
impl Engine {
    fn configure(&mut self, oscillators: Vec<Osc>, mut lfos: Vec<Lfo>, gain: f64) {
        for l in &mut lfos {
            if let Some(old) = self.lfos.iter().find(|x| x.id == l.id) {
                l.phase = old.phase;
            }
        }
        for v in &mut self.voices {
            v.states = oscillators
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
        }
        self.oscillators = oscillators;
        self.lfos = lfos;
        self.gain = gain;
    }
    fn on(&mut self, note: i64, velocity: f64) {
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
            note: note.clamp(0, 127),
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
        });
    }
    fn off(&mut self, note: i64) {
        for v in &mut self.voices {
            if v.note == note {
                v.held = false;
            }
        }
    }
    fn sample(&mut self) -> f32 {
        let mut modulation = [0.0; 8];
        for l in &mut self.lfos {
            let value = (TAU * l.phase).sin() * l.depth * 4.0;
            for (i, o) in self.oscillators.iter().enumerate() {
                if l.target == "all" || l.target == o.id {
                    modulation[i] += value;
                }
            }
            l.phase = (l.phase + l.rate / SR).fract();
        }
        let mut mix = 0.0;
        for v in &mut self.voices {
            let target = if v.held { 1.0 } else { 0.0 };
            v.env += (target - v.env)
                * if v.held {
                    1.0 - (-1.0 / (SR * 0.005)).exp()
                } else {
                    1.0 - (-1.0 / (SR * 0.045)).exp()
                };
            for (i, (o, s)) in self.oscillators.iter().zip(v.states.iter_mut()).enumerate() {
                let dt =
                    (440.0 * 2f64.powf((v.note as f64 - 69.0 + o.transpose) / 12.0) / SR).min(0.45);
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
                let cutoff =
                    (o.cutoff * 2f64.powf(modulation[i].clamp(-12.0, 12.0))).clamp(20.0, 18000.0);
                s.low += (1.0 - (-TAU * cutoff / SR).exp()) * (x - s.low);
                mix += (if o.filter { s.low } else { x }) * o.gain * v.env * v.velocity;
            }
        }
        self.voices.retain(|v| v.held || v.env > 0.00001);
        (mix * self.gain * 0.25).tanh() as f32
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
        .and_then(|v| v.try_to::<f64>().ok())
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
#[derive(GodotClass)]
#[class(base=RefCounted,init)]
pub struct InstrumentSynthRs {
    engine: Engine,
    base: Base<RefCounted>,
}
#[godot_api]
impl InstrumentSynthRs {
    #[func]
    fn configure(&mut self, oscillators: VarArray, modulators: VarArray, master_gain: f64) {
        let os = oscillators
            .iter_shared()
            .take(8)
            .filter_map(|v| v.try_to::<VarDictionary>().ok())
            .enumerate()
            .map(|(i, d)| Osc {
                id: string(&d, "id", &format!("osc{i}")),
                wave: number(&d, "wave", 0.0, 0.0, 2.0) as i64,
                gain: number(&d, "gain", 0.5, 0.0, 1.0),
                transpose: number(&d, "transpose", 0.0, -24.0, 24.0),
                filter: d
                    .get("filter")
                    .and_then(|v| v.try_to::<bool>().ok())
                    .unwrap_or(true),
                cutoff: number(&d, "cutoff", 8000.0, 40.0, 16000.0),
            })
            .collect();
        let ls = modulators
            .iter_shared()
            .take(8)
            .filter_map(|v| v.try_to::<VarDictionary>().ok())
            .enumerate()
            .map(|(i, d)| Lfo {
                id: string(&d, "id", &format!("lfo{i}")),
                rate: number(&d, "rate", 1.0, 0.05, 20.0),
                depth: number(&d, "depth", 0.0, 0.0, 1.0),
                target: string(&d, "target", "all"),
                phase: 0.0,
            })
            .collect();
        self.engine.configure(
            os,
            ls,
            if master_gain.is_finite() {
                master_gain.clamp(0.0, 1.0)
            } else {
                0.0
            },
        );
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
    fn engine() -> Engine {
        let mut e = Engine::default();
        e.configure(
            vec![Osc {
                id: "a".into(),
                wave: 0,
                gain: 1.0,
                transpose: 0.0,
                filter: false,
                cutoff: 40.0,
            }],
            vec![],
            0.5,
        );
        e
    }
    #[test]
    fn silence_pitch_and_release() {
        let mut e = engine();
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
    }
    #[test]
    fn filter_and_gain_change() {
        let mut e = engine();
        e.on(90, 1.0);
        for _ in 0..4410 {
            e.sample();
        }
        let dry: f32 = (0..4410).map(|_| e.sample().abs()).sum();
        e.oscillators[0].filter = true;
        let wet: f32 = (0..4410).map(|_| e.sample().abs()).sum();
        assert!(wet < dry * 0.1);
        e.gain = 0.0;
        assert_eq!(e.sample(), 0.0);
    }
    #[test]
    fn polyphony_is_bounded_and_reconfigure_preserves_phase() {
        let mut e = engine();
        for n in 40..60 {
            e.on(n, 1.0);
        }
        assert_eq!(e.voices.len(), 8);
        for _ in 0..100 {
            assert!(e.sample().abs() <= 1.0);
        }
        let phase = e.voices[0].states[0].phase;
        e.configure(e.oscillators.clone(), vec![], 0.5);
        assert_eq!(e.voices[0].states[0].phase, phase);
    }
    #[test]
    fn lfo_routes_only_to_its_destination_and_retains_phase() {
        let mut dry = engine();
        let mut wet = engine();
        dry.oscillators[0].filter = true;
        wet.oscillators[0].filter = true;
        wet.lfos.push(Lfo { id: "lfo".into(), rate: 2.0, depth: 1.0,
            target: "missing".into(), phase: 0.25 });
        dry.on(69, 1.0);
        wet.on(69, 1.0);
        for _ in 0..1000 { assert_eq!(dry.sample(), wet.sample()); }
        wet.lfos[0].target = "a".into();
        let mut difference = 0.0f32;
        for _ in 0..4410 { difference += (dry.sample() - wet.sample()).abs(); }
        assert!(difference > 1.0);
        let phase = wet.lfos[0].phase;
        wet.configure(wet.oscillators.clone(), vec![Lfo { id: "lfo".into(),
            rate: 5.0, depth: 0.5, target: "all".into(), phase: 0.0 }], 0.5);
        assert_eq!(wet.lfos[0].phase, phase);
    }

}
