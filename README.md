# synth-builder-godot

Research-leaning simulation game where the player designs and builds synths.
Design record and rationale live in `nattsu-hub/projects/synth-builder-godot.md`.

This repo is currently a series of throwaway spikes, not the game.

## Spikes

| Scene / file | What it probes |
|---|---|
| `main.tscn` (`main.gd`, `circuit_*.gd`, `oscilloscope.gd`) | Spikes #1–2: does tweaking a value / placing and wiring blocks feel good? RC low-pass + live oscilloscope. |
| `diode_spike.tscn` (`diode_spike.gd`, `diode_circuit.gd`) | Spike #3: hand-stamped audio-rate nonlinear solver (diode clipper) in pure GDScript, with an on-screen perf readout. |
| `mna_solver.gd` | Spike #3 step 2: generic netlist-driven N-node MNA + Newton-Raphson solver in GDScript. The golden reference for the Rust port. |
| `rust/` + `synth_circuit.gdextension` | `MnaSolverRs`: the same solver as a Rust GDExtension — the intended real-time circuit core. |
| `bench.gd`, `bench_mna.gd` | Headless benchmarks / cross-checks. `godot --headless --script bench_mna.gd` |

## Building the Rust GDExtension

Needed before opening the project (Godot loads `MnaSolverRs` from the compiled dylib):

```sh
cargo build            --manifest-path rust/Cargo.toml   # debug
cargo build --release  --manifest-path rust/Cargo.toml   # release
cargo test             --manifest-path rust/Cargo.toml
```

`rust/target/` is git-ignored. The `godot` crate is pinned to the `api-4-4`
feature to load in Godot 4.4.x.
