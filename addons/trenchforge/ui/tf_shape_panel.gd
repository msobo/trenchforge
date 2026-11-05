@tool
class_name TFShapePanel
extends PanelContainer
## Parameters of the selected builder shape (TFShapeParams): radius, height
## and segments of a cylinder, step count and direction of stairs, radius,
## segments and bends of a pipe, thickness and height of walls, cuts, twist,
## interpolation and profile of a bridge. The plugin
## shows it at the bottom left of the 3D viewport while one parametric shape
## (or any number of walls) is selected; every change rebuilds the shapes as
## an undo action.

## Changed parameters only, e.g. {"sides": 12} or {"turns": 1}.
signal params_changed(changes: Dictionary)

var _title: Label
var _radius: SpinBox
var _height: SpinBox
var _sides: SpinBox
var _steps: SpinBox
var _bend_radius: SpinBox
var _bend_segments: SpinBox
var _thickness: SpinBox
var _cuts: SpinBox
var _twist: SpinBox
var _smoothness: SpinBox
var _profile_factor: SpinBox
var _rows := {}  # parameter -> [label, editor]
var _type := ""
var _updating := false


func _init() -> void:
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	mouse_filter = Control.MOUSE_FILTER_STOP
	var box := VBoxContainer.new()
	add_child(box)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 15)
	box.add_child(_title)
	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	_radius = _spin(grid, "radius", TFI18n.t("Radius (m)"), TFShapeParams.MIN_SIZE, 1000.0, 0.001)
	_radius.allow_greater = true
	_thickness = _spin(grid, "thickness", TFI18n.t("Thickness (m)"), TFShapeParams.MIN_SIZE, 1000.0, 0.001)
	_thickness.allow_greater = true
	_height = _spin(grid, "height", TFI18n.t("Height (m)"), TFShapeParams.MIN_SIZE, 1000.0, 0.001)
	_height.allow_greater = true
	_sides = _spin(grid, "sides", TFI18n.t("Segments"), TFShapes.MIN_SIDES, TFShapes.MAX_SIDES, 1)
	_steps = _spin(grid, "steps", TFI18n.t("Steps"), 1, TFShapes.MAX_STEPS, 1)
	var turn := HBoxContainer.new()
	turn.add_child(_turn_button("⟲", TFI18n.t("Turn counter-clockwise"), 1))
	turn.add_child(_turn_button("⟳", TFI18n.t("Turn clockwise"), -1))
	_add_row(grid, "turns", TFI18n.t("Direction"), turn)
	_bend_radius = _spin(grid, "bend_radius", TFI18n.t("Bend radius (m)"), 0.0, 1000.0, 0.001)
	_bend_radius.allow_greater = true
	_bend_segments = _spin(grid, "bend_segments", TFI18n.t("Bend segments"), 0, TFShapes.MAX_BEND_SEGMENTS, 1)
	_bend_segments.tooltip_text = TFI18n.t("0: mitred corners")
	_bend_radius.tooltip_text = _bend_segments.tooltip_text
	_cuts = _spin(grid, "cuts", TFI18n.t("Cuts"), 0, TFConst.BRIDGE_MAX_CUTS, 1)
	_twist = _spin(grid, "twist", TFI18n.t("Twist"), -TFConst.BRIDGE_MAX_POINTS, TFConst.BRIDGE_MAX_POINTS, 1)
	_option(grid, "interpolation", TFI18n.t("Interpolation"), [TFI18n.t("Linear"), TFI18n.t("Blend path")])
	_smoothness = _spin(grid, "smoothness", TFI18n.t("Smoothness"), 0.0, 10.0, 0.01)
	_profile_factor = _spin(grid, "profile_factor", TFI18n.t("Profile factor"), -1.0, 10.0, 0.01)
	_option(grid, "profile_shape", TFI18n.t("Profile shape"), [TFI18n.t("Smooth"), TFI18n.t("Sphere"), TFI18n.t("Linear")])


## Fills the fields from TFShapeParams.cylinder_params()/stairs_params()/
## pipe_params()/wall_params()/bridge_params() without emitting params_changed and shows the
## rows of the shape type; count is the number of selected shapes (walls).
func set_values(params: Dictionary, count: int = 1) -> void:
	_updating = true
	_type = params["type"]
	var rows: Array = []
	match _type:
		TFShapeParams.TYPE_CYLINDER:
			_title.text = TFI18n.t("Cylinder")
			rows = ["radius", "height", "sides"]
		TFShapeParams.TYPE_STAIRS:
			_title.text = TFI18n.t("Stairs")
			rows = ["steps", "turns"]
		TFShapeParams.TYPE_PIPE:
			_title.text = TFI18n.t("Pipe")
			rows = ["radius", "sides", "bend_radius", "bend_segments"]
		TFShapeParams.TYPE_WALL:
			_title.text = TFI18n.t("Wall") if count == 1 else TFI18n.t("Walls (%d)") % count
			rows = ["thickness", "height"]
		TFShapeParams.TYPE_BRIDGE:
			_title.text = TFI18n.t("Bridge")
			rows = ["cuts", "twist", "interpolation", "smoothness", "profile_factor", "profile_shape"]
	for key: String in rows:
		var editor: Control = _rows[key][1]
		if editor is SpinBox:
			(editor as SpinBox).value = params[key]
		elif editor is OptionButton:
			(editor as OptionButton).selected = int(params[key])
	_updating = false
	for key: String in _rows:
		for control: Control in _rows[key]:
			control.visible = key in rows
	reset_size()


func _emit(changes: Dictionary) -> void:
	if not _updating:
		params_changed.emit(changes)


func _spin(grid: GridContainer, key: String, text: String, min_value: float, max_value: float, step: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.select_all_on_focus = true
	spin.custom_minimum_size.x = 96
	spin.value_changed.connect(func(value: float) -> void: _emit({key: int(value) if step == 1 else value}))
	_add_row(grid, key, text, spin)
	return spin


func _option(grid: GridContainer, key: String, text: String, items: Array) -> OptionButton:
	var option := OptionButton.new()
	for item: String in items:
		option.add_item(item)
	option.item_selected.connect(func(index: int) -> void: _emit({key: index}))
	_add_row(grid, key, text, option)
	return option


func _turn_button(text: String, tooltip: String, turns: int) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.pressed.connect(func() -> void: _emit({"turns": turns}))
	return button


func _add_row(grid: GridContainer, key: String, text: String, editor: Control) -> void:
	var label := Label.new()
	label.text = text
	grid.add_child(label)
	grid.add_child(editor)
	_rows[key] = [label, editor]
