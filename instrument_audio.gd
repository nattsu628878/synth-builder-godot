class_name InstrumentAudio
extends Node
## Native block synthesis keeps per-sample work outside the scene thread.
var patch: InstrumentPatch
var latest_samples := PackedFloat32Array()
var available := false
var _engine: RefCounted
var _player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback

func _ready() -> void:
	if not ClassDB.class_exists("InstrumentSynthRs"):
		push_error("InstrumentSynthRs is unavailable. Build rust with cargo build and restart Godot.")
		set_process(false)
		return
	_engine = ClassDB.instantiate("InstrumentSynthRs")
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = 44100.0
	generator.buffer_length = 0.08
	_player = AudioStreamPlayer.new()
	_player.stream = generator
	add_child(_player)
	_player.play()
	_playback = _player.get_stream_playback() as AudioStreamGeneratorPlayback
	available = true

func _process(_delta: float) -> void:
	if not available or patch == null:
		return
	_engine.call("configure_graph", patch.oscillators, patch.filters, patch.routes, patch.modulators, patch.assignments, patch.master_gain)
	var count := _playback.get_frames_available()
	if count <= 0:
		return
	var block: PackedVector2Array = _engine.call("render", count)
	_playback.push_buffer(block)
	latest_samples.resize(mini(block.size(), 1024))
	for i in latest_samples.size():
		latest_samples[i] = block[i].x

func note_on(note: int, velocity: float = 1.0) -> void:
	if available:
		_engine.call("note_on", note, velocity)

func note_off(note: int) -> void:
	if available:
		_engine.call("note_off", note)

func all_notes_off() -> void:
	if available:
		_engine.call("all_notes_off")

func _exit_tree() -> void:
	if is_instance_valid(_player):
		_player.stop()
	_playback = null
	_engine = null
	available = false
