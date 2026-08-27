//! GDExtension entry point for the synth-builder-godot circuit core.
//! See nattsu-hub/projects/synth-builder-godot.md (spike #3 -> Rust port).

use godot::prelude::*;

mod godot_api;
mod mna;

struct SynthCircuit;

#[gdextension]
unsafe impl ExtensionLibrary for SynthCircuit {}
