@tool
class_name TFFaceInspector
extends ScrollContainer
## Shows and edits material and UV attributes of the target faces (face
## selection, or all faces of the selected brushes). Mixed values show "—".
## Every edit is one undo action.

const MIXED := "—"

var ctx: TFEditorContext

var _rng := RandomNumberGenerator.new()
var _content: VBoxContainer
var _title: Label
var _material_picker: EditorResourcePicker
var _material_mixed: Label
var _offset_x: NumberField
var _offset_y: NumberField
var _scale_x: NumberField
var _scale_y: NumberField
var _rotation: NumberField
var _link_scale: Button
var _nodraw: CheckBox
var _brush_mode: OptionButton
var _controls: Array[Control] = []


## LineEdit for one float that can show a mixed state.
class NumberField:
	extends LineEdit

	signal value_committed(value: float)

	var _shown := ""

	func _init() -> void:
		custom_minimum_size.x = 56
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		select_all_on_focus = true
		text_submitted.connect(func(_text: String) -> void: _commit())
		focus_exited.connect(_commit)

	## null shows the mixed marker.
	func show_value(value: Variant) -> void:
		if has_focus():
			return
		_shown = MIXED if value == null else TFTool.format_length(value)
		text = _shown

	func _commit() -> void:
		if text == _shown:
			return
		var value: float
		if text.is_valid_float():
			value = text.to_float()
		else:
			# Simple arithmetic such as "64*3" or "128/2".
			var expression := Expression.new()
			var result: Variant = expression.execute() if expression.parse(text) == OK else null
			if expression.has_execute_failed() or not (result is float or result is int):
				text = _shown
				return
			value = float(result)
		_shown = TFTool.format_length(value)
		text = _shown
		value_committed.emit(value)


func _init() -> void:
	name = "TFFaceInspector"
	# TFI18n translates the texts; keep the editor from translating them again.
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	custom_minimum_size = Vector2(180, 120)
	_rng.randomize()

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_content)

	_title = Label.new()
	_content.add_child(_title)

	_section(TFI18n.t("Material"))
	_material_picker = EditorResourcePicker.new()
	_material_picker.base_type = "Material"
	_material_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_material_picker.resource_changed.connect(_on_material_changed)
	_content.add_child(_material_picker)
	_controls.append(_material_picker)
	_material_mixed = Label.new()
	_material_mixed.text = TFI18n.t("%s (mixed)") % MIXED
	_content.add_child(_material_mixed)
	_nodraw = CheckBox.new()
	_nodraw.text = TFI18n.t("Nodraw")
	_nodraw.tooltip_text = TFI18n.t("The face is not rendered (collision stays)")
	_nodraw.toggled.connect(_set_nodraw)
	_content.add_child(_nodraw)
	_controls.append(_nodraw)

	_section(TFI18n.t("UV"))
	var grid := GridContainer.new()
	grid.columns = 3
	_content.add_child(grid)
	grid.add_child(_label(TFI18n.t("Offset (px)")))
	_offset_x = _field(grid, func(v: float) -> void: _set_component("uv_offset", 0, v))
	_offset_y = _field(grid, func(v: float) -> void: _set_component("uv_offset", 1, v))
	var scale_row := HBoxContainer.new()
	scale_row.add_child(_label(TFI18n.t("Scale")))
	_link_scale = Button.new()
	_link_scale.toggle_mode = true
	_link_scale.button_pressed = true
	_link_scale.flat = true
	_link_scale.text = "⛓"
	_link_scale.tooltip_text = TFI18n.t("Scale X/Y linked")
	scale_row.add_child(_link_scale)
	grid.add_child(scale_row)
	_scale_x = _field(grid, func(v: float) -> void: _set_scale(0, v))
	_scale_y = _field(grid, func(v: float) -> void: _set_scale(1, v))
	grid.add_child(_label(TFI18n.t("Rotation (°)")))
	_rotation = _field(grid, _set_rotation)
	grid.add_child(Control.new())

	var transform_row := _row()
	_button(transform_row, "↺ 90°", TFI18n.t("Rotate texture 90° counterclockwise"), func(face: TFFace, _v: PackedVector3Array, _t: Vector2, _p: float) -> void: TFUV.rotate(face, 90.0))
	_button(transform_row, "↻ 90°", TFI18n.t("Rotate texture 90° clockwise"), func(face: TFFace, _v: PackedVector3Array, _t: Vector2, _p: float) -> void: TFUV.rotate(face, -90.0))
	_button(transform_row, "Flip U", TFI18n.t("Flip horizontally"), func(face: TFFace, v: PackedVector3Array, _t: Vector2, p: float) -> void: TFUV.flip(face, v, p, 0))
	_button(transform_row, "Flip V", TFI18n.t("Flip vertically"), func(face: TFFace, v: PackedVector3Array, _t: Vector2, p: float) -> void: TFUV.flip(face, v, p, 1))

	for axis in 2:
		var row := _row()
		row.add_child(_label(TFI18n.t("Offset %s") % ("U" if axis == 0 else "V")))
		for step: float in [-1.0, -0.5, 0.5, 1.0]:
			var text := ("%+.1f" % step).replace(".0", "").replace("0.5", "½")
			_button(row, text, TFI18n.t("Offset by %s texture width") % text, func(face: TFFace, _v: PackedVector3Array, t: Vector2, _p: float) -> void:
				var delta := Vector2.ZERO
				delta[axis] = t[axis] * step
				TFUV.shift(face, delta, t))
	var random_row := _row()
	_button(random_row, TFI18n.t("Random offset"), TFI18n.t("Random offset per face (breaks up repetition)"), func(face: TFFace, _v: PackedVector3Array, t: Vector2, _p: float) -> void: TFUV.random_offset(face, t, _rng))

	_section(TFI18n.t("Brush"))
	_brush_mode = OptionButton.new()
	_brush_mode.add_item(TFI18n.t("Solid"), TFBrush.Mode.SOLID)
	_brush_mode.add_item(TFI18n.t("No collision (detail)"), TFBrush.Mode.NO_COLLISION)
	_brush_mode.add_item(TFI18n.t("Collision only (clip)"), TFBrush.Mode.COLLISION_ONLY)
	_brush_mode.tooltip_text = TFI18n.t("Render/collision behavior of the selected brushes")
	_brush_mode.item_selected.connect(_set_brush_mode)
	_content.add_child(_brush_mode)
	_controls.append(_brush_mode)

	_section(TFI18n.t("Align"))
	var align_row := _row()
	_button(align_row, TFI18n.t("Reset"), TFI18n.t("Box projection defaults"), func(face: TFFace, _v: PackedVector3Array, _t: Vector2, _p: float) -> void: TFUV.reset(face))
	_button(align_row, TFI18n.t("Fit"), TFI18n.t("Exactly one tile per face"), func(face: TFFace, v: PackedVector3Array, t: Vector2, p: float) -> void: TFUV.fit(face, v, t, p))
	_button(align_row, TFI18n.t("Fit U"), TFI18n.t("One tile horizontally"), func(face: TFFace, v: PackedVector3Array, t: Vector2, p: float) -> void: TFUV.fit(face, v, t, p, true, false))
	_button(align_row, TFI18n.t("Fit V"), TFI18n.t("One tile vertically"), func(face: TFFace, v: PackedVector3Array, t: Vector2, p: float) -> void: TFUV.fit(face, v, t, p, false, true))
	_button(align_row, TFI18n.t("Center"), TFI18n.t("Center the texture on the face"), func(face: TFFace, v: PackedVector3Array, t: Vector2, p: float) -> void: TFUV.center(face, v, t, p))
	_button(align_row, TFI18n.t("To edge"), TFI18n.t("Align the axes to the bottom edge (sloped faces)"), func(face: TFFace, v: PackedVector3Array, _t: Vector2, _p: float) -> void: TFUV.align_to_edge(face, v, TFUV.bottom_edge(v)))
	var snap := Button.new()
	snap.text = "%s (%s)" % [TFShortcuts.label("face_snap"), TFShortcuts.text("face_snap")]
	snap.tooltip_text = TFI18n.t("Interactively lay the texture's bottom edge on a face edge")
	snap.pressed.connect(func() -> void:
		if ctx != null:
			ctx.request_tool("face_snap"))
	align_row.add_child(snap)
	_controls.append(snap)


func setup(p_ctx: TFEditorContext) -> void:
	ctx = p_ctx
	refresh()


func focus_first_field() -> void:
	_offset_x.grab_focus()


func refresh() -> void:
	var targets := ctx.target_faces() if ctx != null and ctx.map != null else []
	var has_targets := not targets.is_empty()
	_title.text = TFI18n.t("%d face(s)") % targets.size() if has_targets else TFI18n.t("No faces selected")
	for control in _controls:
		if control is BaseButton:
			(control as BaseButton).disabled = not has_targets
		elif control is LineEdit:
			(control as LineEdit).editable = has_targets
		elif control is EditorResourcePicker:
			(control as EditorResourcePicker).editable = has_targets
	if not has_targets:
		_nodraw.set_pressed_no_signal(false)
		_brush_mode.select(-1)
		_material_picker.edited_resource = null
		_material_mixed.visible = false
		for field: NumberField in [_offset_x, _offset_y, _scale_x, _scale_y, _rotation]:
			field.show_value(null)
		return
	var faces: Array[TFFace] = []
	for entry in targets:
		faces.append((entry[0] as TFBrush).faces[entry[1]])
	var material: Variant = _common(faces, func(f: TFFace) -> Variant: return f.material)
	var mixed_material := material is String
	_material_mixed.visible = mixed_material
	_material_picker.edited_resource = null if mixed_material else material
	_nodraw.set_pressed_no_signal(faces.all(func(f: TFFace) -> bool: return f.flags & TFFace.FLAG_NODRAW))
	var mode: Variant = _common_brush_mode(targets)
	_brush_mode.select(-1 if mode == null else _brush_mode.get_item_index(mode))
	_offset_x.show_value(_number(faces, func(f: TFFace) -> Variant: return f.uv_offset.x))
	_offset_y.show_value(_number(faces, func(f: TFFace) -> Variant: return f.uv_offset.y))
	_scale_x.show_value(_number(faces, func(f: TFFace) -> Variant: return f.uv_scale.x))
	_scale_y.show_value(_number(faces, func(f: TFFace) -> Variant: return f.uv_scale.y))
	_rotation.show_value(_number(faces, func(f: TFFace) -> Variant: return f.uv_rotation))


# --- edits --------------------------------------------------------------------

func _on_material_changed(resource: Resource) -> void:
	if ctx != null and resource is Material:
		ctx.apply_material(resource)


func _set_nodraw(enabled: bool) -> void:
	_modify(TFI18n.action("Set nodraw"), func(face: TFFace, _brush: TFBrush, _index: int) -> void:
		face.flags = (face.flags | TFFace.FLAG_NODRAW) if enabled else (face.flags & ~TFFace.FLAG_NODRAW))


func _set_brush_mode(index: int) -> void:
	if ctx == null:
		return
	var mode := _brush_mode.get_item_id(index)
	var brushes: Array[TFBrush] = []
	for entry in ctx.target_faces():
		if not brushes.has(entry[0]):
			brushes.append(entry[0])
	if brushes.is_empty():
		return
	var undo_redo := ctx.undo_redo()
	undo_redo.create_action(TFI18n.action("Set brush mode"))
	for brush in brushes:
		undo_redo.add_do_property(brush, &"mode", mode)
		undo_redo.add_undo_property(brush, &"mode", brush.mode)
	undo_redo.commit_action()
	refresh()


func _set_component(property: String, axis: int, value: float) -> void:
	_modify(TFI18n.action("Change UV"), func(face: TFFace, _brush: TFBrush, _index: int) -> void:
		var vector: Vector2 = face.get(property)
		vector[axis] = value
		face.set(property, vector))


func _set_scale(axis: int, value: float) -> void:
	if is_zero_approx(value):
		refresh()
		return
	var linked := _link_scale.button_pressed
	_modify(TFI18n.action("Change UV scale"), func(face: TFFace, _brush: TFBrush, _index: int) -> void:
		var scale := face.uv_scale
		scale[axis] = value
		if linked:
			scale[1 - axis] = value
		face.uv_scale = scale)


func _set_rotation(value: float) -> void:
	_modify(TFI18n.action("Change UV rotation"), func(face: TFFace, _brush: TFBrush, _index: int) -> void:
		face.uv_rotation = wrapf(value, -180.0, 180.0))


## Runs op(face, map_vertices, texture_size, ppm) on all target faces; the
## faces of a logical face (compound) share the vertices of its outline.
func _apply_op(action_name: String, op: Callable) -> void:
	if ctx == null:
		return
	var polygons := {}  # [brush, face_index] -> map-space polygon
	for group in ctx.target_face_groups():
		var polygon := ctx.logical_polygon(group)
		for entry in group:
			polygons[entry] = polygon
	_modify(action_name, func(face: TFFace, brush: TFBrush, index: int) -> void:
		var vertices: PackedVector3Array = polygons.get([brush, index], PackedVector3Array())
		if vertices.size() < 3:
			vertices = brush.get_face_map_vertices(index)
		op.call(face, vertices, TFUV.get_texture_size(face.material), brush.get_ppm()))


func _modify(action_name: String, fn: Callable) -> void:
	if ctx == null:
		return
	ctx.modify_faces(action_name, ctx.target_faces(), fn)
	refresh()


# --- helpers ------------------------------------------------------------------

## The shared value, or the String MIXED if the faces differ.
static func _common(faces: Array[TFFace], getter: Callable) -> Variant:
	var first: Variant = getter.call(faces[0])
	for face in faces:
		if getter.call(face) != first:
			return MIXED
	return first


## The mode shared by all brushes of the targets, or null if mixed.
static func _common_brush_mode(targets: Array) -> Variant:
	var mode: Variant = null
	for entry in targets:
		var brush_mode: int = (entry[0] as TFBrush).mode
		if mode == null:
			mode = brush_mode
		elif mode != brush_mode:
			return null
	return mode


static func _number(faces: Array[TFFace], getter: Callable) -> Variant:
	var first: float = getter.call(faces[0])
	for face in faces:
		if not is_equal_approx(getter.call(face), first):
			return null
	return first


func _section(text: String) -> void:
	var separator := HSeparator.new()
	_content.add_child(separator)
	var label := _label(text)
	label.add_theme_color_override(&"font_color", Color(0.7, 0.8, 1.0))
	_content.add_child(label)


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _row() -> HFlowContainer:
	var row := HFlowContainer.new()
	_content.add_child(row)
	return row


func _field(parent: Control, on_commit: Callable) -> NumberField:
	var field := NumberField.new()
	field.value_committed.connect(on_commit)
	parent.add_child(field)
	_controls.append(field)
	return field


func _button(parent: Control, text: String, tooltip: String, op: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.pressed.connect(func() -> void: _apply_op("TrenchForge: %s" % text, op))
	parent.add_child(button)
	_controls.append(button)
