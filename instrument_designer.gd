extends Control

const Patch = preload("res://instrument_patch.gd")
const Audio = preload("res://instrument_audio.gd")
var patch = Patch.new()
var engine: Node
var routing: Node
var modulation: Node
var layout_edit := false
var held_keys := {}
var drag_control: Control
var drag_data: Dictionary
var drag_offset := Vector2.ZERO
var loading_dialog: FileDialog
const NOTE_KEYS = [KEY_A, KEY_W, KEY_S, KEY_E, KEY_D, KEY_F, KEY_T, KEY_G, KEY_Y, KEY_H, KEY_U, KEY_J, KEY_K]
@onready var modules: VBoxContainer = $Margin/Main/Tabs/Design/Modules
@onready var surface: Control = $Margin/Main/Tabs/Panel/Scroll/Surface
@onready var instrument_name: LineEdit = $Margin/Main/Header/Name
@onready var status: Label = $Margin/Main/Status

func _ready() -> void:
	get_window().min_size = Vector2i(900, 620)
	engine = Audio.new()
	engine.patch = patch
	add_child(engine)
	$Margin/Main/Scope.source = engine
	instrument_name.text = patch.name
	instrument_name.text_changed.connect(func(value): patch.name = value)
	$Margin/Main/Header/Save.pressed.connect(_save)
	$Margin/Main/Header/Load.pressed.connect(_load_dialog)
	routing = preload("res://instrument_routing.tscn").instantiate()
	routing.patch = patch
	$Margin/Main/Tabs.add_child(routing)
	$Margin/Main/Tabs.move_child(routing, 1)
	modulation = preload("res://instrument_modulation.tscn").instantiate()
	modulation.patch = patch
	$Margin/Main/Tabs.add_child(modulation)
	$Margin/Main/Tabs.move_child(modulation, 2)
	routing.structure_changed.connect(func(): _refresh_design(); _refresh_panel(); modulation.refresh())
	$Margin/Main/Tabs.tab_changed.connect(func(tab):
		_stop_notes()
		if tab == 0: _refresh_design()
		_refresh_panel()
		routing.refresh()
		modulation.refresh()
	)
	$Margin/Main/Tabs/Panel/Toolbar/Layout.toggled.connect(func(value): layout_edit = value; _refresh_panel())
	for i in range(13):
		var key := Button.new()
		key.text = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B", "C"][i]
		key.custom_minimum_size.y = 52
		key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		key.focus_mode = Control.FOCUS_NONE
		key.button_down.connect(func(): engine.note_on(60 + i))
		key.button_up.connect(func(): engine.note_off(60 + i))
		$Margin/Main/Keyboard.add_child(key)
	var panic := Button.new()
	panic.text = "Stop"
	panic.pressed.connect(_stop_notes)
	$Margin/Main/Keyboard.add_child(panic)
	OS.open_midi_inputs()
	_refresh_design()
	_refresh_panel()

func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()

func _label(text: String, parent: Node, size := 16) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	parent.add_child(label)
	return label

func _button(text: String, parent: Node, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _card(title: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("192130")
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	modules.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	_label(title, box, 20)
	return box

func _row(parent: Node) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)
	return row

func _range(param: String) -> Array:
	match param:
		"cutoff": return [40.0, 16000.0, 10.0]
		"transpose": return [-24.0, 24.0, 1.0]
		"rate": return [0.05, 20.0, 0.05]
		_: return [0.0, 1.0, 0.01]

func _parameter(parent: Node, target: String, param: String) -> void:
	var row := _row(parent)
	_label(param.capitalize(), row).custom_minimum_size.x = 95
	var spin := SpinBox.new()
	spin.set_meta("target", target)
	spin.set_meta("param", param)
	var limits := _range(param)
	spin.min_value = limits[0]
	spin.max_value = limits[1]
	spin.step = limits[2]
	spin.value = patch.get_parameter(target, param)
	spin.custom_minimum_size.x = 140
	spin.value_changed.connect(func(value): patch.set_parameter(target, param, value))
	row.add_child(spin)
	_button("+ Panel control", row, func(): patch.add_control(target, param); _refresh_panel(); status.text = "Control added to your panel")

func _refresh_design() -> void:
	_clear(modules)
	var heading := _row(modules)
	_label("01  DESIGN YOUR INSTRUMENT", heading, 20).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var add_osc := _button("+ Oscillator", heading, func(): patch.add_oscillator(); _refresh_design())
	add_osc.disabled = patch.oscillators.size() >= 8
	var add_lfo := _button("+ LFO", heading, func(): patch.add_lfo(); _refresh_design())
	add_lfo.disabled = patch.modulators.size() >= 8
	_label("Add modules here → wire them in Routing → assign LFOs in Modulation → play your Panel", modules)
	for osc in patch.oscillators:
		var box := _card(str(osc.name))
		var row := _row(box)
		var wave := OptionButton.new()
		for item in ["Sine", "Saw", "Square"]: wave.add_item(item)
		wave.selected = int(osc.wave)
		wave.item_selected.connect(func(index): osc.wave = index)
		row.add_child(wave)
		_button("Remove oscillator", row, func(): patch.remove_oscillator(osc.id); _refresh_design(); _refresh_panel())
		for param in ["gain", "transpose"]: _parameter(box, osc.id, param)
	var add_filter := _button("+ Filter", modules, func(): patch.add_filter(); _refresh_design())
	add_filter.disabled = patch.filters.size() >= 8
	for filter in patch.filters:
		var box := _card(str(filter.name))
		var row := _row(box)
		var enabled := CheckButton.new()
		enabled.text = "Filter enabled (off = bypass)"
		enabled.button_pressed = filter.enabled
		enabled.toggled.connect(func(value): filter.enabled = value)
		row.add_child(enabled)
		_button("Remove filter", row, func(): patch.remove_filter(filter.id); _refresh_design(); _refresh_panel())
		_parameter(box, filter.id, "cutoff")
	for mod in patch.modulators:
		var box := _card(str(mod.name) + " · sine modulation")
		var row := _row(box)
		_label("Global, free-running · Depth scales all assignments from this LFO", row)
		_button("Remove LFO", row, func(): patch.remove_lfo(mod.id); _refresh_design(); _refresh_panel())
		for param in ["rate", "depth"]: _parameter(box, mod.id, param)
	var master := _card("OUTPUT")
	_parameter(master, "master", "gain")

func _refresh_panel() -> void:
	drag_control = null
	_clear(surface)
	surface.custom_minimum_size.y = maxf(460, ceil(float(patch.controls.size()) / 5.0) * 180 + 180)
	for item in patch.controls:
		surface.custom_minimum_size.y = maxf(surface.custom_minimum_size.y, float(item.y) + 220)
	for data in patch.controls:
		var card: PanelContainer = preload("res://instrument_panel_control.tscn").instantiate()
		card.position = Vector2(float(data.x), float(data.y))
		surface.add_child(card)
		var handle: Label = card.get_node("Content/Handle")
		handle.text = ("↔  " if layout_edit else "") + str(data.label)
		handle.tooltip_text = str(data.label)
		handle.gui_input.connect(func(event): _drag_input(event, card, data))
		var slider: HSlider = card.get_node("Content/Slider")
		var limits := _range(data.param)
		slider.min_value = limits[0]
		slider.max_value = limits[1]
		slider.step = limits[2]
		slider.exp_edit = data.param in ["cutoff", "rate"]
		slider.value = patch.get_parameter(data.target, data.param)
		slider.editable = not layout_edit
		var value_label: Label = card.get_node("Content/Value")
		value_label.text = "%.2f" % slider.value
		slider.value_changed.connect(func(value): patch.set_parameter(data.target, data.param, value); value_label.text = "%.2f" % value)
		var label_edit: LineEdit = card.get_node("Content/LabelEdit")
		label_edit.visible = layout_edit
		label_edit.text = str(data.label)
		label_edit.text_changed.connect(func(value): data.label = value; handle.text = "↔  " + value)
		var remove: Button = card.get_node("Content/Remove")
		remove.visible = layout_edit
		remove.pressed.connect(func(): patch.remove_control(data.id); _refresh_panel())
	if patch.controls.is_empty(): _label("Expose parameters in Design to build your own performance panel.", surface)

func _drag_input(event: InputEvent, card: Control, data: Dictionary) -> void:
	if not layout_edit: return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			drag_control = card
			drag_data = data
			drag_offset = surface.get_local_mouse_position() - card.position
		else: drag_control = null

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and is_instance_valid(drag_control):
		var pos := surface.get_local_mouse_position() - drag_offset
		drag_control.position = Vector2(clampf(pos.x, 0, 824), clampf(pos.y, 0, surface.custom_minimum_size.y - drag_control.size.y)).snapped(Vector2(8, 8))
		drag_data.x = drag_control.position.x
		drag_data.y = drag_control.position.y
	if event is InputEventMouseButton and not event.pressed: drag_control = null
	if event is InputEventMIDI:
		if event.message == MIDI_MESSAGE_NOTE_ON and event.velocity > 0: engine.note_on(event.pitch, float(event.velocity) / 127.0)
		elif event.message == MIDI_MESSAGE_NOTE_OFF or (event.message == MIDI_MESSAGE_NOTE_ON and event.velocity == 0): engine.note_off(event.pitch)
	if event is InputEventKey and not event.echo:
		if is_instance_valid(loading_dialog) and loading_dialog.visible: return
		var index := NOTE_KEYS.find(event.physical_keycode)
		if index < 0: return
		if not event.pressed:
			if held_keys.has(index): engine.note_off(60 + index); held_keys.erase(index)
			return
		var focus := get_viewport().gui_get_focus_owner()
		if get_viewport().gui_get_focus_owner() != null and get_viewport().gui_get_focus_owner().get_window() != get_window(): return
		if focus is LineEdit or focus is TextEdit or event.ctrl_pressed or event.meta_pressed or event.alt_pressed: return
		held_keys[index] = true
		engine.note_on(60 + index)

func _stop_notes() -> void:
	held_keys.clear()
	engine.all_notes_off()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_instance_valid(engine): _stop_notes()

func _save() -> void:
	DirAccess.make_dir_recursive_absolute("user://instruments")
	var filename: String = patch.name.validate_filename().strip_edges()
	if filename.is_empty(): filename = "Untitled"
	var file := FileAccess.open("user://instruments/" + filename + ".json", FileAccess.WRITE)
	if file == null:
		status.text = "Save failed: " + error_string(FileAccess.get_open_error())
		return
	file.store_string(JSON.stringify(patch.to_dict(), "\t"))
	status.text = "Saved: " + filename + ".json"

func _load_dialog() -> void:
	_stop_notes()
	DirAccess.make_dir_recursive_absolute("user://instruments")
	var dialog := FileDialog.new()
	loading_dialog = dialog
	dialog.access = FileDialog.ACCESS_USERDATA
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.filters = PackedStringArray(["*.json ; Instruments"])
	dialog.current_dir = "user://instruments"
	add_child(dialog)
	dialog.file_selected.connect(func(path):
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			status.text = "Could not open instrument"
			dialog.queue_free()
			return
		var data = JSON.parse_string(file.get_as_text())
		if not data is Dictionary or not patch.load_dict(data):
			status.text = patch.last_error
			dialog.queue_free()
			return
		instrument_name.text = patch.name
		_refresh_design()
		_refresh_panel()
		routing.refresh()
		modulation.refresh()
		status.text = "Loaded: " + patch.name
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered(Vector2i(760, 520))
