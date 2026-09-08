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

1. **Design:** start with three oscillators and two LFOs. Add/remove modules,
   choose sine/saw/square waves, change tuning, level, and individual filters.
2. Set each LFO's speed, depth, and destination (one oscillator or all).
3. Use **+ Panel control** next to a parameter to expose it for performance.
4. Open **Panel**. Its controls change the same live instrument. Enable
   **Edit layout** to drag controls by their headers, rename them, or remove them.
5. Play with the on-screen keys, computer keys A W S E D F T G Y H U J K
   (C4–C5), or MIDI note input. **Stop** releases every note.
6. Return to **Design** to revise the instrument. **Save/Load** preserves the
   topology, parameter values, bindings, labels, and layout as JSON under
   `user://instruments/`. Saving the same instrument name replaces its file.

## Current scope

- Up to 8 oscillators, each optionally through its own one-pole low-pass filter,
  summed to the output; 8-note polyphony and a fixed attack/release envelope.
- Up to 8 shared, free-running sine LFOs. They modulate filter cutoff only;
  depth 1 means ±4 octaves. Bypassed filters are unaffected audibly.
- Up to 32 panel controls with one parameter per control. Cutoff and LFO speed
  sliders use logarithmic scaling. Audio is generated in Rust at 44.1 kHz
  with an 80 ms generator buffer; this is a prototype, not a low-latency plugin.
- MSEG, sequencers, arbitrary signal routing, module-internal DSP editing,
  macro mappings, enclosure editing, story content, and VST export are future work.
- Shutdown can report an `AudioStreamGeneratorPlayback` ObjectDB leak on
  Godot 4.4.1; this also occurred in the earlier circuit prototype.

## Edit with Godot

`instrument_designer.tscn` contains the editable screen shell and keyboard area.
`instrument_panel_control.tscn` is the reusable performance-control scene: edit
its layout and style directly in Godot. Repeated module forms are currently
created by `instrument_designer.gd`; instrument data lives in `instrument_patch.gd`.
`instrument_audio.gd` connects the native block engine in `rust/src/instrument.rs`.
The circuit engine remains independent.

## Validation

```sh
cargo test --manifest-path rust/Cargo.toml
godot --headless --audio-driver Dummy --script instrument_selftest.gd
godot --headless --audio-driver Dummy --script circuit4_selftest.gd
godot --headless --script bench_mna.gd
```

The instrument self-test checks JSON roundtrips, invalid document rejection,
module removal, stable identities, panel bindings, native note output/release,
and design/performance synchronization. Optional rendered QA:
`godot --audio-driver Dummy --script instrument_selftest.gd -- --render`
writes `/tmp/instrument-panel.png` and `/tmp/instrument-design.png`.
These checks do not establish physical MIDI compatibility or listening quality.

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
