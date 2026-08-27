//! Godot-facing wrapper around `mna::Mna`. Mirrors the public API of the
//! GDScript `mna_solver.gd` so `bench_mna.gd` can run both and diff them.

use crate::mna::{Mna, RawComp};
use godot::prelude::*;

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct MnaSolverRs {
    inner: Option<Mna>,
    #[allow(dead_code)]
    base: Base<RefCounted>,
}

#[godot_api]
impl MnaSolverRs {
    /// netlist: Array of Dictionaries, each { "type": String,
    /// "nodes": [String, ...], "value"?: float, "name"?: String }.
    #[func]
    fn build(&mut self, netlist: VarArray, ground: GString) {
        let g = ground.to_string();
        let mut entries: Vec<RawComp> = Vec::with_capacity(netlist.len());
        for item in netlist.iter_shared() {
            let dict = item.to::<VarDictionary>();
            let typ = dict.at("type").to::<GString>().to_string();
            let nodes: Vec<String> = dict
                .at("nodes")
                .to::<VarArray>()
                .iter_shared()
                .map(|v| v.to::<GString>().to_string())
                .collect();
            let value = dict.get("value").map(|v| v.to::<f64>());
            let name = dict.get("name").map(|v| v.to::<GString>().to_string());
            entries.push(RawComp { typ, nodes, value, name });
        }
        let mut m = Mna::new();
        m.build(&entries, &g);
        self.inner = Some(m);
    }

    #[func]
    fn set_dt(&mut self, v: f64) {
        if let Some(m) = &mut self.inner {
            m.set_dt(v);
        }
    }

    #[func]
    fn reset_state(&mut self) {
        if let Some(m) = &mut self.inner {
            m.reset_state();
        }
    }

    #[func]
    fn set_source(&mut self, name: GString, value: f64) {
        if let Some(m) = &mut self.inner {
            m.set_source(&name.to_string(), value);
        }
    }

    #[func]
    fn set_value(&mut self, name: GString, value: f64) {
        if let Some(m) = &mut self.inner {
            m.set_value(&name.to_string(), value);
        }
    }

    #[func]
    fn node_voltage(&self, name: GString) -> f64 {
        self.inner
            .as_ref()
            .map_or(0.0, |m| m.node_voltage(&name.to_string()))
    }

    #[func]
    fn step(&mut self) -> i64 {
        self.inner.as_mut().map_or(0, |m| m.step() as i64)
    }

    #[func]
    fn get_n(&self) -> i64 {
        self.inner.as_ref().map_or(0, |m| m.n as i64)
    }

    #[func]
    fn get_last_iters(&self) -> i64 {
        self.inner.as_ref().map_or(0, |m| m.last_iters as i64)
    }

    #[func]
    fn get_nonconverged(&self) -> i64 {
        self.inner.as_ref().map_or(0, |m| m.nonconverged)
    }
}
