# synth-builder-godot

Research-leaning simulation game where the player designs and builds synths.
Design record and rationale live in `nattsu-hub/projects/synth-builder-godot.md`.

The current playable prototype is `game.tscn` (the project's main scene).
Build and wire a circuit, adjust component knobs, and match the live target
waveform. Hold at least 92% agreement for about 0.7 seconds to solve a challenge.
The four challenges cover RC low-pass, diode soft clipping, half-wave
rectification, and an OTA two-pole low-pass VCF.

## Run and develop

Use Godot 4.4.1 and build the Rust extension below, then run `godot --path .`
from this directory, or open `project.godot` in the editor and press F6 with
`game.tscn` open. `circuit4.tscn` is the development workbench with JSON patch
save/load; `game.tscn` shares its circuit host and omits the patch bar.

- Add components from the palette and click terminals to wire them.
- Drag component knobs to adjust values; Shift-drag gives finer control.
- Use the mouse wheel over a knob, or double-click it to enter a value such as `4.7k` or `10n`.
- Select a part and press Delete to remove it.
- Choose a target for a challenge, or `off` for free experimentation.

Validation commands (the self-test writes a `selftest` patch under Godot's user data):

```sh
cargo test --manifest-path rust/Cargo.toml
godot --headless --audio-driver Dummy --script circuit4_selftest.gd
godot --headless --script bench_mna.gd
```

The self-test checks wiring, save/load, capacitor-state carryover, BJT/OTA
behavior, all four reference matches, and game controls. The benchmark compares
Rust and GDScript solver outputs and measures circuit processing costs.
These checks do not establish visual quality, sound quality, or playing feel.

## Earlier spikes and solver references

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
