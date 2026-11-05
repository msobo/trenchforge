@tool
class_name TFToolbar
extends HBoxContainer
## TrenchForge controls in the 3D editor menu bar. Labels in the tables are
## English and translated (TFI18n) when shown; the plugin rebuilds the
## toolbar when the language changes.

signal tool_selected(tool_name: String)
signal face_mode_toggled(enabled: bool)
signal vertex_mode_selected(mode: int)
signal shape_selected(shape: int)
signal linked_toggled(enabled: bool)
signal grid_stepped(increase: bool)
signal grid_visibility_toggled
signal texture_lock_toggled(enabled: bool)
signal build_requested
signal csg_requested(action: String)
signal csg_option_toggled(option: String, enabled: bool)
signal map_action_requested(action: String)

## [tool, label, tooltip, shortcut action ("" = none)]
const TOOLS := [
	["off", "Off", "TrenchForge input off (use Godot's gizmos)", ""],
	["select", "Select", "Select, move, resize", "cancel"],
	["box", "Box", "Draw a box brush", "tool_box"],
	["shape", "Shape", "Draw a cylinder, polygon prism, stairs, pipe or wall", "tool_shape"],
	["vertex", "Vertex", "Move vertices, edges or faces", "tool_vertex"],
	["clip", "Clip", "Cut the selected brushes with a plane", "tool_clip"],
	["cube_cut", "Cube-Cut", "Cube-Cut: punch an opening through all brushes hit", "tool_cube_cut"],
]
## CSG menu: [label, action, shortcut action] for actions, [label, option,
## true] for options (TFEditorContext properties), [] for a separator.
const CSG_ITEMS := [
	["Subtract", "subtract", "csg_subtract"],
	["Subtract from all overlapping brushes", "subtract_all", ""],
	["Hollow inward", "hollow", "csg_hollow"],
	["Hollow outward", "hollow_out", ""],
	["Merge", "merge", "csg_merge"],
	[],
	["Bevel edges / vertices…", "bevel", "bevel"],
	["Bridge faces / edge loops", "bridge", "bridge"],
	[],
	["Keep cutter after subtract", "keep_cutter", true],
	["Texture openings like the cut brush", "cut_faces_from_target", true],
	["Clip face with current material", "clip_uses_current_material", true],
]
## Map menu: [label, TFMapActions action (also the shortcut action)],
## [label, action, true] for a check item (collision visibility), []
## for a separator.
const MAP_ITEMS := [
	["Hide selection", "hide"],
	["Isolate selection", "isolate"],
	["Show all", "unhide_all"],
	[],
	["Group", "group"],
	["Ungroup", "ungroup"],
	["Make compound", "make_compound"],
	["Dissolve compound", "dissolve_compound"],
	[],
	["Select all with same material", "select_same_material"],
	["Select touching brushes", "select_touching"],
	["Select brushes inside", "select_inside"],
	[],
	["Validate Map (repair)", "validate_map"],
	[],
	["Bake to Mesh (replace brushes)", "bake_mesh"],
	["Bake to Mesh (keep brushes hidden)", "bake_mesh_keep"],
	[],
	["Show collision", "toggle_collision", true],
	[],
	["TrenchForge Settings…", "open_settings"],
]
## [label, tooltip, shortcut action]
const VERTEX_MODES := [
	["Points", "Move vertices", "tool_vertex"],
	["Edges", "Move edges", "tool_edge"],
	["Faces", "Move faces freely", "tool_vertex_face"],
]

## [label, tooltip, 16×16 SVG icon] per TFShapeTool.Shape
const SHAPES := [
	["Cylinder", "Fit a cylinder into the drawn box (segments: W/S)",
		'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" fill="none" stroke="#e0e0e0" stroke-width="1.3"><ellipse cx="8" cy="4" rx="5.5" ry="2.2"/><path d="M2.5 4v8c0 1.2 2.5 2.2 5.5 2.2s5.5-1 5.5-2.2V4"/></svg>'],
	["Polygon", "Click points; the polygon is extruded into a prism",
		'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" fill="none" stroke="#e0e0e0" stroke-width="1.3" stroke-linejoin="round"><path d="M3 5.5 8 2l5.5 3.5-1.5 7.5H5z"/><g fill="#e0e0e0" stroke="none"><circle cx="3" cy="5.5" r="1.4"/><circle cx="8" cy="2" r="1.4"/><circle cx="13.5" cy="5.5" r="1.4"/><circle cx="12" cy="13" r="1.4"/><circle cx="5" cy="13" r="1.4"/></g></svg>'],
	["Stairs", "Fit stairs into the drawn box (direction: Q/E, steps: W/S)",
		'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" fill="none" stroke="#e0e0e0" stroke-width="1.3" stroke-linejoin="round"><path d="M1.5 14.5h13v-13h-4v4h-4v4h-4v5z"/></svg>'],
	["Pipe", "Click a right-angled path (Shift: vertical); it becomes a pipe with bends (segments: W/S, radius: Shift+W/S)",
		'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" fill="none" stroke="#e0e0e0" stroke-width="1.3" stroke-linejoin="round"><path d="M1.5 4.5H8a6.5 6.5 0 0 1 6.5 6.5v3.5h-5V11A1.5 1.5 0 0 0 8 9.5H1.5z"/></svg>'],
	["Wall", "Click or drag a path on the floor (right-angled, Shift: diagonal); it becomes walls with mitred corners, the first point closes a room (height: W/S, thickness: Shift+W/S)",
		'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" fill="none" stroke="#e0e0e0" stroke-width="1.3" stroke-linejoin="round"><path d="M1.5 14.5v-12h13v12h-3v-9h-7v9z"/></svg>'],
]

var _tool_buttons := {}
var _shape_box: HBoxContainer
var _shape_menu: MenuButton
var _shape_icons: Array[Texture2D] = []
var _shape_label: Label
var _vertex_box: HBoxContainer
var _vertex_buttons: Array[Button] = []
var _linked_button: Button
var _clip_label: Label
var _csg_menu: MenuButton
var _map_menu: MenuButton
var _brushes_button: Button
var _faces_button: Button
var _grid_label: Label
var _smaller: Button
var _larger: Button
var _grid_button: Button
var _lock_button: Button
var _build_button: Button


func _init() -> void:
	# TFI18n translates the texts; the editor would translate terms like "Cut"
	# or "Linked" on its own.
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	add_child(VSeparator.new())
	var title := Label.new()
	title.text = "TF"
	title.tooltip_text = "TrenchForge"
	add_child(title)

	var group := ButtonGroup.new()
	for entry in TOOLS:
		var button := Button.new()
		button.text = TFI18n.t(entry[1])
		button.toggle_mode = true
		button.button_group = group
		button.flat = true
		button.pressed.connect(func() -> void: tool_selected.emit(entry[0]))
		add_child(button)
		_tool_buttons[entry[0]] = button

	_vertex_box = HBoxContainer.new()
	_vertex_box.add_child(VSeparator.new())
	var mode_group := ButtonGroup.new()
	for i in VERTEX_MODES.size():
		var button := Button.new()
		button.text = TFI18n.t(VERTEX_MODES[i][0])
		button.toggle_mode = true
		button.button_group = mode_group
		button.flat = true
		button.pressed.connect(func() -> void: vertex_mode_selected.emit(i))
		_vertex_box.add_child(button)
		_vertex_buttons.append(button)
	_linked_button = Button.new()
	_linked_button.text = TFI18n.t("Linked")
	_linked_button.tooltip_text = TFI18n.t("Also move shared vertices of unselected neighbor brushes so they stay sealed")
	_linked_button.toggle_mode = true
	_linked_button.flat = true
	_linked_button.toggled.connect(func(on: bool) -> void: linked_toggled.emit(on))
	_vertex_box.add_child(_linked_button)
	add_child(_vertex_box)

	_shape_box = HBoxContainer.new()
	_shape_box.add_child(VSeparator.new())
	# Shape menu: a vertical list with an icon per shape; the button shows
	# the active one.
	_shape_menu = MenuButton.new()
	_shape_menu.flat = true
	var shape_popup := _shape_menu.get_popup()
	for i in SHAPES.size():
		_shape_icons.append(_svg_icon(SHAPES[i][2]))
		shape_popup.add_icon_radio_check_item(_shape_icons[i], TFI18n.t(SHAPES[i][0]), i)
		shape_popup.set_item_tooltip(i, TFI18n.t(SHAPES[i][1]))
	shape_popup.id_pressed.connect(func(id: int) -> void: shape_selected.emit(id))
	_shape_box.add_child(_shape_menu)
	_shape_label = Label.new()
	_shape_box.add_child(_shape_label)
	add_child(_shape_box)

	_clip_label = Label.new()
	_clip_label.tooltip_text = TFI18n.t("Switch clip mode with Q/E")
	add_child(_clip_label)

	_csg_menu = MenuButton.new()
	_csg_menu.text = "CSG"
	_csg_menu.tooltip_text = TFI18n.t("Subtract, Hollow, Merge and CSG options")
	_csg_menu.flat = true
	var popup := _csg_menu.get_popup()
	popup.hide_on_checkable_item_selection = false
	for i in CSG_ITEMS.size():
		var item: Array = CSG_ITEMS[i]
		if item.is_empty():
			popup.add_separator()
		elif item.size() > 2 and item[2] is bool:
			popup.add_check_item(TFI18n.t(item[0]), i)
		else:
			popup.add_item(TFI18n.t(item[0]), i)
	popup.id_pressed.connect(_on_csg_item)
	add_child(_csg_menu)

	_map_menu = MenuButton.new()
	_map_menu.text = "Map"
	_map_menu.tooltip_text = TFI18n.t("Hide/isolate, groups and compounds, selection queries, Validate Map, Bake to Mesh, show collision, settings")
	_map_menu.flat = true
	var map_popup := _map_menu.get_popup()
	for i in MAP_ITEMS.size():
		if MAP_ITEMS[i].is_empty():
			map_popup.add_separator()
		elif MAP_ITEMS[i].size() > 2:
			map_popup.add_check_item(TFI18n.t(MAP_ITEMS[i][0]), i)
		else:
			map_popup.add_item(TFI18n.t(MAP_ITEMS[i][0]), i)
	map_popup.id_pressed.connect(func(id: int) -> void: map_action_requested.emit(MAP_ITEMS[id][1]))
	add_child(_map_menu)

	add_child(VSeparator.new())
	# Brushes | Faces: the active selection mode in its accent color.
	var selection_mode := ButtonGroup.new()
	_brushes_button = _mode_button("Brushes", selection_mode, false)
	_faces_button = _mode_button("Faces", selection_mode, true)

	add_child(VSeparator.new())
	_smaller = Button.new()
	var smaller := _smaller
	smaller.text = "−"
	smaller.flat = true
	smaller.pressed.connect(func() -> void: grid_stepped.emit(false))
	add_child(smaller)
	_grid_label = Label.new()
	add_child(_grid_label)
	_larger = Button.new()
	var larger := _larger
	larger.text = "+"
	larger.flat = true
	larger.pressed.connect(func() -> void: grid_stepped.emit(true))
	add_child(larger)
	_grid_button = Button.new()
	_grid_button.text = "#"
	_grid_button.toggle_mode = true
	_grid_button.flat = true
	_grid_button.pressed.connect(func() -> void: grid_visibility_toggled.emit())
	add_child(_grid_button)

	add_child(VSeparator.new())
	_lock_button = Button.new()
	_lock_button.text = TFI18n.t("Tex-Lock")
	_lock_button.toggle_mode = true
	_lock_button.flat = true
	_lock_button.toggled.connect(func(on: bool) -> void: texture_lock_toggled.emit(on))
	add_child(_lock_button)

	add_child(VSeparator.new())
	_build_button = Button.new()
	_build_button.flat = true
	_build_button.pressed.connect(func() -> void: build_requested.emit())
	add_child(_build_button)


func refresh(ctx: TFEditorContext, active_tool: String, vertex_tool: TFVertexTool, clip_tool: TFClipTool, shape_tool: TFShapeTool) -> void:
	_shape_box.visible = active_tool == "shape"
	var shape_popup := _shape_menu.get_popup()
	for i in SHAPES.size():
		shape_popup.set_item_checked(i, i == shape_tool.shape)
	_shape_menu.text = TFI18n.t(SHAPES[shape_tool.shape][0])
	_shape_menu.icon = _shape_icons[shape_tool.shape]
	_shape_menu.tooltip_text = TFI18n.t(SHAPES[shape_tool.shape][1])
	_shape_label.text = shape_tool.get_option_text()
	_clip_label.visible = active_tool == "clip"
	_clip_label.text = TFI18n.t(TFClipTool.MODE_NAMES[clip_tool.keep])
	var popup := _csg_menu.get_popup()
	for i in CSG_ITEMS.size():
		var item: Array = CSG_ITEMS[i]
		if item.size() > 2 and item[2] is bool:
			popup.set_item_checked(popup.get_item_index(i), bool(ctx.get(item[1])))
		elif item.size() > 2:
			popup.set_item_text(popup.get_item_index(i), _with_keys(item[0], item[2]))
	var map_popup := _map_menu.get_popup()
	for i in MAP_ITEMS.size():
		if not MAP_ITEMS[i].is_empty():
			map_popup.set_item_text(map_popup.get_item_index(i), _with_keys(MAP_ITEMS[i][0], MAP_ITEMS[i][1]))
	map_popup.set_item_checked(map_popup.get_item_index(_map_item("toggle_collision")), TFMap.is_collision_shown_in_editor())
	for entry in TOOLS:
		var button: Button = _tool_buttons[entry[0]]
		button.set_pressed_no_signal(entry[0] == active_tool)
		button.tooltip_text = _with_keys(entry[2], entry[3])
	_vertex_box.visible = active_tool == "vertex"
	for i in _vertex_buttons.size():
		_vertex_buttons[i].set_pressed_no_signal(i == vertex_tool.mode)
		_vertex_buttons[i].tooltip_text = _with_keys(VERTEX_MODES[i][1], VERTEX_MODES[i][2])
	for button in [_brushes_button, _faces_button]:
		button.tooltip_text = _with_keys("Toggle face mode", "face_mode")
	_grid_button.tooltip_text = _with_keys("Grid overlay on/off", "grid_toggle")
	_smaller.tooltip_text = _with_keys("Halve grid", "grid_smaller")
	_larger.tooltip_text = _with_keys("Double grid", "grid_larger")
	_lock_button.tooltip_text = TFI18n.t("%s: textures move along when moving/rotating.\nOff = world-aligned UVs (seamless across brushes).") % _with_keys("Texture Lock", "texture_lock")
	_linked_button.set_pressed_no_signal(vertex_tool.linked)
	_brushes_button.set_pressed_no_signal(not ctx.face_mode)
	_faces_button.set_pressed_no_signal(ctx.face_mode)
	_brushes_button.add_theme_color_override("font_pressed_color", TFEditorContext.COLOR_SELECTED)
	_faces_button.add_theme_color_override("font_pressed_color", TFEditorContext.COLOR_FACE_MODE)
	_grid_button.set_pressed_no_signal(ctx.grid_visible)
	_lock_button.set_pressed_no_signal(ctx.texture_lock)
	_grid_label.text = TFI18n.t("Grid %s m") % TFTool.format_length(ctx.grid_size())
	var dirty := ctx.map != null and is_instance_valid(ctx.map) and ctx.map.is_build_dirty()
	_build_button.text = "Build •" if dirty else "Build"
	_build_button.tooltip_text = "%s\n%s" % [_with_keys("Rebuild map", "build"), TFI18n.t("Build outdated – preview meshes visible") if dirty else TFI18n.t("Build up to date")]
	_build_button.modulate = Color(1.0, 0.75, 0.35) if dirty else Color.WHITE


## Toggle button of the Brushes | Faces switch.
func _mode_button(label: String, group: ButtonGroup, face_mode: bool) -> Button:
	var button := Button.new()
	button.text = TFI18n.t(label)
	button.toggle_mode = true
	button.button_group = group
	button.flat = true
	button.pressed.connect(func() -> void: face_mode_toggled.emit(face_mode))
	add_child(button)
	return button


## Texture from an inline SVG, scaled with the editor UI.
static func _svg_icon(svg: String) -> Texture2D:
	var image := Image.new()
	var scale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0
	image.load_svg_from_string(svg, scale)
	return ImageTexture.create_from_image(image)


## Id (index in MAP_ITEMS) of a map menu action.
static func _map_item(action: String) -> int:
	return MAP_ITEMS.find_custom(func(item: Array) -> bool: return not item.is_empty() and item[1] == action)


## "Translated label (Keys)" for an action with a shortcut.
static func _with_keys(label: String, action: String) -> String:
	var text := TFI18n.t(label)
	if action.is_empty() or TFShortcuts.get_shortcut(action).events.is_empty() or TFShortcuts.ACTIONS.all(func(e: Array) -> bool: return e[0] != action):
		return text
	return "%s (%s)" % [text, TFShortcuts.text(action)]


func _on_csg_item(id: int) -> void:
	var item: Array = CSG_ITEMS[id]
	if item.size() > 2 and item[2] is bool:
		var popup := _csg_menu.get_popup()
		csg_option_toggled.emit(item[1], not popup.is_item_checked(popup.get_item_index(id)))
	else:
		csg_requested.emit(item[1])
