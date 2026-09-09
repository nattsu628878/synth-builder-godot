# synth-builder-godot

Research-leaning simulation game where the player designs and builds synths.
Design record and rationale live in `nattsu-hub/projects/synth-builder-godot.md`.

The main scene is now `instrument_designer.tscn`: a first software-instrument
builder. Choose the instrument's modules, expose parameters on your own
performance panel, then play and return to the design to refine it.
The earlier circuit waveform-matching game is preserved in `game.tscn`.

## Run and try it

Use Godot 4.4.1. Build the native engine first (restart an already-open Godot
editor after rebuilding):

```sh
cargo build --manifest-path rust/Cargo.toml
godot --path .
```

Or open `project.godot` in Godot and press F5.

1. **Design:** add/remove oscillators, independent low-pass filters, and LFOs.
   Set waveforms, tuning, levels, filter cutoff/bypass, and LFO speed/depth here.
2. **Routing:** drag an output port to a filter or OUTPUT input. Multiple inputs
   are summed; outputs can branch. Filters can be shared or connected in series.
   Right-click a wire to remove it. Drag block headers to rearrange them;
   **Arrange** resets their positions. A new module is initially disconnected.
3. **Modulation:** add assignments with an LFO source, target parameter, and signed
   amount. One LFO can drive many targets, and several LFOs can drive one target.
4. **+ Panel control** in Design exposes a parameter. **Panel** plays the same
   instrument; **Edit layout** lets you drag headers, rename, or remove controls.
5. Play using on-screen keys, A W S E D F T G Y H U J K (C4–C5), or MIDI notes.
   **Stop** releases notes; return to any editor to refine the instrument.
6. **Save/Load** stores topology, values, modulation, panel bindings and positions,
   and graph positions in JSON under `user://instruments/`. Same-name saves replace
   the file. Version 1 instruments migrate automatically to version 2 on load;
   their per-oscillator filters become explicit nodes and panel bindings follow.

To try a **shared filter**, remove the OSC 2 → FILTER 2 and OSC 3 → FILTER 3
connections, then connect both oscillators to FILTER 1 instead. To add a second
filter stage, replace FILTER 1 → OUTPUT with FILTER 1 → FILTER 2 → OUTPUT.
Unused filters may remain disconnected or be removed in Design/Routing.

## Current scope

- Up to 8 oscillators and 8 independent one-pole low-pass filters, with 8-note
  polyphony and a fixed attack/release envelope. Audio wiring must be acyclic;
  feedback, duplicate wires, and invalid endpoints are rejected without changing
  the previous graph. Filters run per note, so a shared filter combines that
  note's oscillators. Bypassing preserves its wiring.
- Up to 8 global, free-running sine LFOs and 64 modulation assignments. Each
  assignment's signed amount multiplies the source LFO depth. Contributions sum:
  cutoff spans ±4 octaves at full depth, pitch ±12 semitones, gain ±1.
  Effective gain is clamped to 0–1 and cutoff to 20–18000 Hz. LFO rate/depth can
  be exposed on the panel but are not themselves modulation destinations yet.
- Up to 32 panel controls. Cutoff and LFO speed sliders use logarithmic scaling.
  Rust generates 44.1 kHz audio through an 80 ms Godot generator buffer.
- MSEG, sequencers, module-internal DSP editing, macros, feedback audio graphs,
  enclosure editing, story content, and VST export remain future work.
- Shutdown can report an `AudioStreamGeneratorPlayback` ObjectDB leak on
  Godot 4.4.1; this also occurred in the earlier circuit prototype.

## Edit with Godot

`instrument_designer.tscn` contains the editable screen shell and keyboard area.
`instrument_panel_control.tscn` is the reusable performance-control scene: edit
its layout and style directly in Godot. Repeated module forms are currently
created by `instrument_designer.gd`; instrument data lives in `instrument_patch.gd`.
`instrument_audio.gd` connects the native block engine in `rust/src/instrument.rs`.
The circuit engine remains independent. `instrument_routing.tscn` and
`instrument_modulation.tscn` are editable tab scenes added to the existing shell;
GraphNodes and assignment rows are generated from the instrument definition.

## Validation

```sh
cargo test --manifest-path rust/Cargo.toml
godot --headless --audio-driver Dummy --script instrument_selftest.gd
godot --headless --audio-driver Dummy --script circuit4_selftest.gd
godot --headless --script bench_mna.gd
godot --headless --audio-driver Dummy --script instrument_bench.gd
```

The instrument self-test checks JSON roundtrips, invalid document rejection,
module removal, stable identities, panel bindings, native note output/release,
design/performance synchronization, graph connection signals, cycle rejection,
assignment cleanup, and v1 migration. Migration sound comparison uses the new
engine’s legacy compatibility path, not the previous binary. Optional rendered QA:
`godot --audio-driver Dummy --script instrument_selftest.gd -- --render`
writes `/tmp/instrument-panel.png`, `/tmp/instrument-design.png`,
`/tmp/instrument-routing.png`, and `/tmp/instrument-modulation.png`.
These checks do not establish physical pointer/MIDI compatibility or listening quality.
The density benchmark measures 4096 frames with 8 voices, 8 OSC, 8 filters,
8 LFOs, 100 audio connections, and 64 assignments. On this M2 debug build,
the measured render time dropped from about 237 ms to 55 ms after compiling
outgoing adjacency and sharing filter coefficient calculation across voices
(the audio duration is 92.88 ms; actual end-to-end latency is separate).

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
