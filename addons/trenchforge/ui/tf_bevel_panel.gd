@tool
class_name TFBevelPanel
extends PanelContainer
## "Adjust last operation" panel of the bevel (like Blender's F9 panel). The
## plugin shows it at the bottom left of the 3D viewport after a bevel; every
## change recomputes the bevel from its source faces and replaces the result
## in the same undo action (TFBevelOperation.adjust_last()).

signal params_changed(params: Dictionary)

var _width: SpinBox
var _segments: SpinBox
var _profile: SpinBox
var _angle: SpinBox
var _clamp: CheckBox
var _corners: OptionButton
var _wrap: CheckBox
var _status: Label
var _rows := {}  # parameter -> [label, editor]
var _updating := false


func _init() -> void:
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	mouse_filter = Control.MOUSE_FILTER_STOP
	var box := VBoxContainer.new()
	add_child(box)
	var title := Label.new()
	title.text = TFI18n.t("Bevel")
	title.add_theme_font_size_override("font_size", 15)
	box.add_child(title)
	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	_width = _spin(grid, "width", TFI18n.t("Width (m)"), 0.0, 1000.0, 0.001)
	_width.allow_greater = true
	_segments = _spin(grid, "segments", TFI18n.t("Segments"), 1, TFConst.BEVEL_MAX_SEGMENTS, 1)
	_profile = _spin(grid, "profile", TFI18n.t("Profile"), TFConst.BEVEL_MIN_PROFILE, 1.0, 0.01)
	_profile.tooltip_text = TFI18n.t("0.25 straight chamfer · 0.5 round · 1 almost square")
	_angle = _spin(grid, "angle", TFI18n.t("Angle limit (°)"), 0.0, 180.0, 1.0)
	_angle.tooltip_text = TFI18n.t("Only edges whose faces meet at least at this angle")
	_clamp = _check(grid, "clamp", TFI18n.t("Clamp overlap"))
	_corners = OptionButton.new()
	_corners.add_item(TFI18n.t("Patch"))
	_corners.add_item(TFI18n.t("Cut"))
	_corners.tooltip_text = TFI18n.t("Patch: round corners where all edges are bevelled · Cut: the edge bevels cut each other")
	_corners.item_selected.connect(func(_index: int) -> void: _emit())
	_add_row(grid, "corners", TFI18n.t("Corners"), _corners)
	_wrap = _check(grid, "wrap_uv", TFI18n.t("Wrap texture around"))
	_status = Label.new()
	_status.add_theme_color_override("font_color", TFBevelOperation.COLOR_CLAMPED)
	_status.visible = false
	box.add_child(_status)


## Fills the fields without emitting params_changed. The angle limit only
## shows for brush-mode bevels, the corners only for edge bevels.
func set_values(params: Dictionary, by_angle: bool, edges: bool) -> void:
	_updating = true
	_width.value = params["width"]
	_segments.value = params["segments"]
	_profile.value = params["profile"]
	_angle.value = params["angle"]
	_clamp.button_pressed = params["clamp"]
	_corners.select(params["corners"])
	_wrap.button_pressed = params["wrap_uv"]
	_updating = false
	for control: Control in _rows["angle"]:
		control.visible = by_angle
	for control: Control in _rows["corners"]:
		control.visible = edges
	show_state({})
	reset_size()


## Shows the outcome of the last change (from adjust_last()).
func show_state(state: Dictionary) -> void:
	var lines: Array[String] = []
	if state.get("invalid", 0) > 0:
		lines.append(TFI18n.t("Not possible with these values (kept the last valid bevel)"))
	if state.get("clamped", false):
		lines.append(TFI18n.t("Width clamped to %s m") % TFTool.format_length(state["width"]))
	if state.get("capped", false):
		lines.append(TFI18n.t("Segments reduced to %d (plane limit)") % state["segments"])
	_status.text = "\n".join(lines)
	_status.visible = not lines.is_empty()
	_status.add_theme_color_override("font_color", TFBevelOperation.COLOR_REJECTED if state.get("invalid", 0) > 0 else TFBevelOperation.COLOR_CLAMPED)
	reset_size()


func get_params() -> Dictionary:
	return {
		"width": _width.value,
		"segments": int(_segments.value),
		"profile": _profile.value,
		"angle": _angle.value,
		"clamp": _clamp.button_pressed,
		"corners": _corners.selected,
		"wrap_uv": _wrap.button_pressed,
	}


func _emit() -> void:
	if not _updating:
		params_changed.emit(get_params())


func _spin(grid: GridContainer, key: String, text: String, min_value: float, max_value: float, step: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.select_all_on_focus = true
	spin.custom_minimum_size.x = 96
	spin.value_changed.connect(func(_value: float) -> void: _emit())
	_add_row(grid, key, text, spin)
	return spin


func _check(grid: GridContainer, key: String, text: String) -> CheckBox:
	var check := CheckBox.new()
	check.toggled.connect(func(_on: bool) -> void: _emit())
	_add_row(grid, key, text, check)
	return check


func _add_row(grid: GridContainer, key: String, text: String, editor: Control) -> void:
	var label := Label.new()
	label.text = text
	grid.add_child(label)
	grid.add_child(editor)
	_rows[key] = [label, editor]
