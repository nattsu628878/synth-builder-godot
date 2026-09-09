extends VBoxContainer
var patch: InstrumentPatch
@onready var rows: VBoxContainer = $Scroll/Rows
func _ready() -> void:
	$Toolbar/Add.pressed.connect(func():
		var targets := patch.modulation_targets()
		if not patch.modulators.is_empty() and not targets.is_empty():
			patch.add_assignment(patch.modulators[0].id, targets[0].target, targets[0].param)
			refresh()
	)
	refresh()
func refresh() -> void:
	if not is_node_ready() or patch == null: return
	for child in rows.get_children():
		rows.remove_child(child)
		child.queue_free()
	$Toolbar/Add.disabled = patch.modulators.is_empty() or patch.assignments.size() >= 64
	if patch.modulators.is_empty():
		var empty := Label.new()
		empty.text = "Add an LFO in Design, then assign it here."
		rows.add_child(empty)
	var targets := patch.modulation_targets()
	for assignment in patch.assignments:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		rows.add_child(row)
		var source := OptionButton.new()
		source.custom_minimum_size.x = 120
		for m in patch.modulators: source.add_item(m.name)
		for i in patch.modulators.size():
			if patch.modulators[i].id == assignment.source: source.selected = i
		source.item_selected.connect(func(i): assignment.source = patch.modulators[i].id)
		row.add_child(source)
		var target := OptionButton.new()
		target.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for t in targets: target.add_item(t.label)
		for i in targets.size():
			if targets[i].target == assignment.target and targets[i].param == assignment.param: target.selected = i
		row.add_child(target)
		var amount := SpinBox.new()
		amount.min_value = -1.0
		amount.max_value = 1.0
		amount.step = 0.01
		amount.value = assignment.amount
		amount.tooltip_text = "Signed amount: -1 to +1. Zero disables this assignment."
		amount.custom_minimum_size.x = 150
		amount.value_changed.connect(func(v): assignment.amount = v)
		row.add_child(amount)
		var units := Label.new()
		units.custom_minimum_size.x = 135
		units.text = _units(assignment.param)
		row.add_child(units)
		target.item_selected.connect(func(i):
			assignment.target = targets[i].target
			assignment.param = targets[i].param
			units.text = _units(assignment.param)
		)
		var remove := Button.new()
		remove.text = "Remove"
		remove.pressed.connect(func(): patch.remove_assignment(assignment.id); refresh())
		row.add_child(remove)
func _units(param: String) -> String:
	match param:
		"cutoff": return "× 4 octaves"
		"transpose": return "× 12 semitones"
		_: return "× 1 gain"
