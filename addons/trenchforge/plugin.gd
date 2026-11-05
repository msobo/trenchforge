@tool
extends EditorPlugin
## TrenchForge editor plugin: project settings, toolbar, docks, viewport
## input routing to the active tool and overlay drawing.

## Godot shortcuts that start its modal instant transform in the viewport.
## While it runs, every event goes to Godot: the confirming click must not
## reach the select tool, which would change the selection (an empty click
## clears it) and Godot would keep transforming the new selection.
const GODOT_INSTANT_TRANSFORMS: Array[String] = [
	"spatial_editor/instant_translate",
	"spatial_editor/instant_rotate",
	"spatial_editor/instant_scale",
	"spatial_editor/collision_reposition",
]
## Longest RMB press (ms) that still counts as a click (deselect) instead
## of the start of freelook.
const RMB_CLICK_MAX_MSEC: int = 400

var _ctx: TFEditorContext
var _toolbar: TFToolbar
var _paint: TFTexturePaint
var _browser: TFMaterialBrowser
var _browser_dock: EditorDock
var _inspector: TFFaceInspector
var _inspector_dock: EditorDock
var _settings_dock_ui: TFSettingsDock
var _uv_editor: TFUVEditor
var _uv_dock: EditorDock
var _settings_dock: EditorDock
var _csg: TFCSGActions
var _bridge: TFBridgeAction
var _map_actions: TFMapActions
var _gizmo: TFTransformGizmo
var _tools := {}
var _active: TFTool
var _active_name := "select"
## Active in the viewport: Godot edits a handled node (_godot_visible) or
## nothing is selected in a scene with a map (see _idle_map()).
var _visible := false
var _godot_visible := false
var _freelook := false
## Right click tracking: a short RMB press without motion or keys clears
## the selection; holding it stays Godot's freelook.
var _rmb_press_time := 0
var _rmb_motion := 0.0
var _rmb_moved := false
## True while Godot's own modal instant transform (G/R/S, Shift+G) runs.
var _godot_transform := false
var _watched_map: TFMap
## Last grid-snapped point under the mouse (status line), or {}.
var _cursor: Dictionary = {}
var _invalid_count := 0
## "Adjust last bevel" panel, shown in the viewport of _last_camera.
var _bevel_panel: TFBevelPanel
## Parameters of the selected cylinder, stairs, pipe or walls, in the same
## place.
var _shape_panel: TFShapePanel
## Shapes the last panel change rebuilt; further changes to them within
## Godot's merge time join that undo action.
var _shape_merge_target: Array = []
## Camera of the viewport that got the last input event.
var _last_camera: Camera3D


func _enter_tree() -> void:
	TFEditorSettings.register_project()
	var editor_settings := EditorInterface.get_editor_settings()
	TFShortcuts.register(editor_settings)
	TFEditorSettings.register(editor_settings)
	editor_settings.settings_changed.connect(_on_editor_settings_changed)
	_ctx = TFEditorContext.new(self)
	_ctx.bevel = TFBevelOperation.new(_ctx)
	_ctx.bevel.committed.connect(_show_bevel_panel)
	_tools = {
		"select": TFSelectTool.new(_ctx),
		"box": TFBoxTool.new(_ctx),
		"shape": TFShapeTool.new(_ctx),
		"face_snap": TFFaceSnapTool.new(_ctx),
		"vertex": TFVertexTool.new(_ctx),
		"clip": TFClipTool.new(_ctx),
		"cube_cut": TFCubeCutTool.new(_ctx),
	}
	_csg = TFCSGActions.new(_ctx)
	_bridge = TFBridgeAction.new(_ctx)
	_map_actions = TFMapActions.new(_ctx)
	_active = _tools["select"]
	_paint = TFTexturePaint.new(_ctx)
	_gizmo = TFTransformGizmo.new()

	_create_toolbar()
	_create_docks()

	_ctx.changed.connect(_on_context_changed)
	_ctx.tool_requested.connect(set_tool)
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	get_undo_redo().version_changed.connect(_refresh_inspector)
	get_undo_redo().version_changed.connect(_check_bevel_panel)
	get_undo_redo().version_changed.connect(_refresh_shape_panel)
	scene_changed.connect(_on_scene_changed)
	# An empty selection keeps the plugin active without selecting the map
	# (Godot would draw selection boxes around all its children).
	set_input_event_forwarding_always_enabled()
	set_force_draw_over_forwarding_enabled()
	# Shows a gizmo hidden before a restart again (saved with the scene state).
	_update_transform_gizmo.call_deferred()
	_update_visible.call_deferred()


func _create_toolbar() -> void:
	_toolbar = TFToolbar.new()
	_toolbar.tool_selected.connect(set_tool)
	_toolbar.face_mode_toggled.connect(_set_face_mode)
	_toolbar.vertex_mode_selected.connect(set_vertex_mode)
	_toolbar.shape_selected.connect(set_shape)
	_toolbar.linked_toggled.connect(func(on: bool) -> void:
		_tools["vertex"].linked = on
		_refresh_toolbar())
	_toolbar.grid_stepped.connect(_ctx.step_grid)
	_toolbar.grid_visibility_toggled.connect(_ctx.toggle_grid_visible)
	_toolbar.texture_lock_toggled.connect(func(on: bool) -> void: _ctx.texture_lock = on)
	_toolbar.build_requested.connect(build_map)
	_toolbar.csg_requested.connect(run_csg)
	_toolbar.csg_option_toggled.connect(_set_csg_option)
	_toolbar.map_action_requested.connect(run_map_action)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
	_toolbar.visible = _visible


func _create_docks() -> void:
	_browser = TFMaterialBrowser.new()
	_browser.material_chosen.connect(_ctx.apply_material)
	_browser.set_current_material(_ctx.current_material)
	_browser_dock = _make_dock(_browser, TFI18n.t("TF Materials"), "tf_materials", EditorDock.DOCK_SLOT_LEFT_BR, "ImageTexture")
	_inspector = TFFaceInspector.new()
	_inspector_dock = _make_dock(_inspector, TFI18n.t("TF Face"), "tf_face_inspector", EditorDock.DOCK_SLOT_RIGHT_BL, "StandardMaterial3D")
	_inspector.setup(_ctx)
	_settings_dock_ui = TFSettingsDock.new()
	_settings_dock = _make_dock(_settings_dock_ui, "TrenchForge", "tf_settings", EditorDock.DOCK_SLOT_BOTTOM, "Tools")
	_uv_editor = TFUVEditor.new()
	_uv_dock = _make_dock(_uv_editor, TFI18n.t("TF UV"), "tf_uv_editor", EditorDock.DOCK_SLOT_BOTTOM, "Uv")
	_uv_editor.setup(_ctx)
	_create_bevel_panel()
	_create_shape_panel()


## Rebuilds the toolbar and the dock contents in the current language (after
## the language setting changed). The docks keep their place; the settings
## dock stays on its tab.
func _retranslate() -> void:
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
	_toolbar.queue_free()
	_create_toolbar()
	var settings_tab := _settings_dock_ui.current_tab
	var browser := TFMaterialBrowser.new()
	_replace_dock_content(_browser_dock, _browser, browser, TFI18n.t("TF Materials"))
	_browser = browser
	_browser.material_chosen.connect(_ctx.apply_material)
	_browser.set_current_material(_ctx.current_material)
	var inspector := TFFaceInspector.new()
	_replace_dock_content(_inspector_dock, _inspector, inspector, TFI18n.t("TF Face"))
	_inspector = inspector
	_inspector.setup(_ctx)
	var settings := TFSettingsDock.new()
	_replace_dock_content(_settings_dock, _settings_dock_ui, settings, "TrenchForge")
	_settings_dock_ui = settings
	_settings_dock_ui.current_tab = settings_tab
	var uv_editor := TFUVEditor.new()
	uv_editor.set_grid_divisions(_uv_editor.grid_divisions)
	_replace_dock_content(_uv_dock, _uv_editor, uv_editor, TFI18n.t("TF UV"))
	_uv_editor = uv_editor
	_uv_editor.setup(_ctx)
	_create_bevel_panel()
	_create_shape_panel()
	_refresh_toolbar()
	_redraw()


func _replace_dock_content(dock: EditorDock, old: Control, new: Control, title: String) -> void:
	dock.remove_child(old)
	old.queue_free()
	dock.title = title
	dock.add_child(new)


func _exit_tree() -> void:
	EditorInterface.get_editor_settings().settings_changed.disconnect(_on_editor_settings_changed)
	EditorInterface.get_selection().selection_changed.disconnect(_on_selection_changed)
	get_undo_redo().version_changed.disconnect(_refresh_inspector)
	get_undo_redo().version_changed.disconnect(_check_bevel_panel)
	get_undo_redo().version_changed.disconnect(_refresh_shape_panel)
	_bevel_panel.queue_free()
	_shape_panel.queue_free()
	_paint.cancel()
	if _active != null:
		_active.cancel()
	_watch_map(null)
	_gizmo.dispose()
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
	_toolbar.queue_free()
	for dock in [_browser_dock, _inspector_dock, _settings_dock, _uv_dock]:
		remove_dock(dock)
		dock.queue_free()
	_ctx.dispose()
	_tools.clear()
	_active = null


func _handles(object: Object) -> bool:
	if object is TFMap or object is TFBrush:
		return true
	if object is Node:
		return _find_map(object) != null
	# Multi-selection edits a MultiNodeEdit; keep handling if brushes are in it.
	if object != null and object.get_class() == "MultiNodeEdit":
		return not _selected_maps().is_empty()
	return false


func _edit(object: Object) -> void:
	var map: TFMap = null
	if object is Node:
		map = _find_map(object)
	elif object != null:
		var maps := _selected_maps()
		map = maps[0] if not maps.is_empty() else null
	if map != null:
		_ctx.set_map(map)
	_redraw()


func _make_visible(visible: bool) -> void:
	_godot_visible = visible
	_update_visible()


## The map TrenchForge stays active on while nothing is selected: the
## current one, else the first map of the edited scene.
func _idle_map() -> TFMap:
	if not EditorInterface.get_selection().get_selected_nodes().is_empty():
		return null
	var root := EditorInterface.get_edited_scene_root()
	var map := _ctx.map
	if map != null and is_instance_valid(map) and map.is_inside_tree() and root != null and (map == root or root.is_ancestor_of(map)):
		return map
	var maps := _edited_maps()
	return maps[0] if not maps.is_empty() else null


func _update_visible() -> void:
	var visible := _godot_visible
	if not visible:
		var map := _idle_map()
		if map != null:
			if map != _ctx.map:
				_ctx.set_map(map)
			visible = true
	if visible == _visible:
		return
	_visible = visible
	_toolbar.visible = visible
	if not visible:
		_hide_bevel_panel()
		_paint.cancel()
		_active.cancel()
		_freelook = false
		_godot_transform = false
		_update_build_suspension()
	_update_transform_gizmo()
	_refresh_toolbar()
	_refresh_shape_panel()
	_redraw()


func set_tool(tool_name: String) -> void:
	if tool_name == _active_name:
		return
	_hide_bevel_panel()
	_active.deactivate()
	_active_name = tool_name
	_active = _tools.get(tool_name, _tools["select"])
	_active.activate()
	_update_transform_gizmo()
	_refresh_toolbar()
	_refresh_shape_panel()
	_redraw()


## Activates the shape tool with the given TFShapeTool.Shape.
func set_shape(shape: int) -> void:
	_tools["shape"].set_shape(shape)
	set_tool("shape")
	_refresh_toolbar()
	_redraw()


## Activates the vertex tool in the given TFVertexTool.Mode.
func set_vertex_mode(mode: int) -> void:
	_tools["vertex"].mode = mode
	set_tool("vertex")
	_refresh_toolbar()
	_redraw()


## Runs a CSG action by name (toolbar menu and hotkeys): "subtract",
## "subtract_all", "hollow", "hollow_out", "merge", "bevel", "bridge".
func run_csg(action: String) -> void:
	if _ctx.map == null or not is_instance_valid(_ctx.map):
		return
	_active.cancel()
	match action:
		"subtract":
			_csg.subtract_selection(false)
		"subtract_all":
			_csg.subtract_selection(true)
		"hollow":
			_csg.hollow(false)
		"hollow_out":
			_csg.hollow(true)
		"merge":
			_csg.merge()
		"bevel":
			_start_bevel()
		"bridge":
			_start_bridge()
	_redraw()


## Runs an organization command (see TFMapActions.run()), toggles the
## collision visibility (an editor setting, works without an active map) or
## opens the settings dock.
func run_map_action(action: String) -> void:
	if action == "open_settings":
		_settings_dock.make_visible()
		return
	if action == "toggle_collision":
		var setting := TFEditorSettings.PREFIX + "viewport/show_collision"
		var settings := EditorInterface.get_editor_settings()
		# Applied by _on_editor_settings_changed().
		settings.set_setting(setting, not bool(settings.get_setting(setting)))
		return
	if _ctx.map == null or not is_instance_valid(_ctx.map):
		return
	_active.cancel()
	_map_actions.run(action)
	_refresh_toolbar()
	_redraw()


func _set_csg_option(option: String, enabled: bool) -> void:
	_ctx.set(option, enabled)
	_refresh_toolbar()


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if not _visible or _ctx.map == null or not is_instance_valid(_ctx.map):
		return AFTER_GUI_INPUT_PASS
	if _active_name == "off":
		return AFTER_GUI_INPUT_PASS
	if _godot_transform:
		if _ends_godot_transform(event):
			_godot_transform = false
		return AFTER_GUI_INPUT_PASS
	_last_camera = camera
	# Modal operations (bevel) get everything first; only orbiting stays
	# with Godot.
	if _active.wants_all_input() and not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE):
		var handled := _active.handle_input(camera, event)
		if handled and event is InputEventKey:
			_refresh_toolbar()
		_update_build_suspension()
		_redraw()
		return AFTER_GUI_INPUT_STOP if handled else AFTER_GUI_INPUT_PASS
	# Alt + mouse is quick texturing in every tool (except modal face snap).
	if not _freelook and _active_name != "face_snap" and _paint.handle_input(camera, event):
		_redraw()
		return AFTER_GUI_INPUT_STOP
	# Never interfere with Godot's freelook (RMB + WASD) or orbit/pan.
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_freelook = event.pressed
			_track_right_click(event)
		return AFTER_GUI_INPUT_PASS
	if _freelook:
		if event is InputEventKey:
			_rmb_moved = true
			return AFTER_GUI_INPUT_PASS
		if event is InputEventMouseMotion:
			_rmb_motion += event.relative.length()
			_rmb_moved = _rmb_moved or _rmb_motion > TFTool.DRAG_THRESHOLD

	_ctx.picker.update_lock(_ctx, camera, event)
	var consumed := false
	if event is InputEventKey and event.pressed and not event.echo:
		consumed = _handle_global_key(event)
	if not consumed:
		consumed = _active.handle_input(camera, event)
	if not consumed and _starts_godot_transform(event):
		_godot_transform = true
		return AFTER_GUI_INPUT_PASS
	if event is InputEventKey and consumed:
		_refresh_toolbar()
	if event is InputEventMouse:
		_update_grid(camera, event.position)
		_update_cursor(camera, event.position)
	_update_build_suspension()
	_redraw()
	return AFTER_GUI_INPUT_STOP if consumed else AFTER_GUI_INPUT_PASS


## Detects a right click (press and release without moving, keys or
## modifiers) and clears the selection of the active tool.
func _track_right_click(event: InputEventMouseButton) -> void:
	if event.pressed:
		_rmb_press_time = Time.get_ticks_msec()
		_rmb_motion = 0.0
		_rmb_moved = event.alt_pressed or event.shift_pressed or event.ctrl_pressed or event.meta_pressed
		return
	# Godot captures the mouse for freelook while RMB is held, so the release
	# position is unreliable; only the summed motion counts.
	if _rmb_moved:
		return
	if Time.get_ticks_msec() - _rmb_press_time > RMB_CLICK_MAX_MSEC:
		return
	if _active_name == "face_snap" or _active.is_busy():
		return
	_active.deselect()
	_refresh_toolbar()
	_redraw()


func _starts_godot_transform(event: InputEvent) -> bool:
	if not event is InputEventKey or not event.pressed or event.echo or _active.is_busy():
		return false
	if EditorInterface.get_selection().get_top_selected_nodes().is_empty():
		return false
	return _matches_godot_shortcut(GODOT_INSTANT_TRANSFORMS, event)


## Godot confirms with LMB, cancels with RMB or its cancel shortcut (Esc).
func _ends_godot_transform(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		return event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER]:
			return true
		return _matches_godot_shortcut(["spatial_editor/cancel_transform"], event)
	return false


func _matches_godot_shortcut(names: Array[String], event: InputEvent) -> bool:
	var settings := EditorInterface.get_editor_settings()
	for shortcut_name in names:
		if not settings.has_shortcut(shortcut_name):
			continue
		var shortcut := settings.get_shortcut(shortcut_name)
		if shortcut != null and shortcut.matches_event(event):
			return true
	return false


## Starts the modal bevel from the toolbar menu at the mouse position in
## the last used viewport (the select tool unless the vertex tool is active).
func _start_bevel() -> void:
	if _last_camera == null or not is_instance_valid(_last_camera):
		return
	if _active_name != "vertex":
		set_tool("select")
	var mouse := _last_camera.get_viewport().get_mouse_position()
	if _active_name == "vertex":
		_tools["vertex"]._begin_bevel(_last_camera)
	else:
		_ctx.bevel.begin_selection(_last_camera, mouse)
	_redraw()


## Bridges the two selected edge loops in the vertex tool's edge mode, else
## the two selected faces (face mode).
func _start_bridge() -> void:
	var vertex: TFVertexTool = _tools["vertex"]
	if _active_name == "vertex" and vertex.mode == TFVertexTool.Mode.EDGE:
		_bridge.bridge_edges(vertex.selected_edges())
	else:
		_bridge.bridge_faces()


# --- bevel panel ------------------------------------------------------------

func _create_bevel_panel() -> void:
	if _bevel_panel != null:
		_bevel_panel.queue_free()
	_bevel_panel = TFBevelPanel.new()
	_bevel_panel.visible = false
	_bevel_panel.params_changed.connect(_on_bevel_panel_changed)


## Shows the panel for the bevel just committed at the bottom left of its
## viewport, above the status lines.
func _show_bevel_panel() -> void:
	if not _attach_panel(_bevel_panel):
		return
	_hide_shape_panel()
	_bevel_panel.set_values(_ctx.bevel.last_params(), _ctx.bevel.last_by_angle(), _ctx.bevel.last_kind() == TFBevelOperation.Kind.EDGES)
	_bevel_panel.visible = true
	_place_bevel_panel()


func _place_bevel_panel() -> void:
	_place_panel(_bevel_panel)


## Moves a viewport panel into the viewport of the last input (the first
## viewport before any input). False if there is none.
func _attach_panel(panel: Control) -> bool:
	var camera := _last_camera
	if camera == null or not is_instance_valid(camera):
		camera = EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	var host := _viewport_control(camera)
	if host == null:
		return false
	if panel.get_parent() != host:
		if panel.get_parent() != null:
			panel.get_parent().remove_child(panel)
		host.add_child(panel)
	return true


## Bottom left of the viewport, above the status lines.
func _place_panel(panel: Control) -> void:
	var scale := EditorInterface.get_editor_scale()
	var line_height := TFDimensionOverlay.FONT_SIZE * scale + 6.0
	var size := panel.get_combined_minimum_size()
	var bottom := 12.0 + line_height * 3.0 + 8.0 * scale
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.offset_left = 12.0
	panel.offset_right = 12.0 + size.x
	panel.offset_bottom = -bottom
	panel.offset_top = -bottom - size.y


func _hide_bevel_panel() -> void:
	if _bevel_panel != null and _bevel_panel.visible:
		_bevel_panel.visible = false
		_ctx.bevel.forget_last()
		_refresh_shape_panel()


## Any other change of the history (another action, undo, redo) ends the
## adjusting of the last bevel.
func _check_bevel_panel() -> void:
	if _bevel_panel != null and _bevel_panel.visible and not _ctx.bevel.has_last():
		_hide_bevel_panel()


func _on_bevel_panel_changed(params: Dictionary) -> void:
	var state := _ctx.bevel.adjust_last(params)
	if state.is_empty():
		_hide_bevel_panel()
		return
	_bevel_panel.show_state(state)
	_place_bevel_panel()
	_redraw()


# --- shape panel ------------------------------------------------------------

func _create_shape_panel() -> void:
	if _shape_panel != null:
		_shape_panel.queue_free()
	_shape_panel = TFShapePanel.new()
	_shape_panel.visible = false
	_shape_panel.params_changed.connect(_on_shape_panel_changed)


## The selected parametric shapes with their parameters as [[node, params]]:
## one cylinder brush, stairs group, pipe or bridge compound, or any number of wall
## compounds (all selected roots); [] otherwise (also while the bevel panel
## shows).
func _shape_targets() -> Array:
	if not _visible or _active_name == "off" or (_bevel_panel != null and _bevel_panel.visible):
		return []
	var roots := _ctx.selected_roots()
	if roots.is_empty():
		return []
	var walls: Array = []
	for root in roots:
		var wall := TFShapeParams.wall_params(root) if not root is TFBrush else {}
		if wall.is_empty():
			break
		walls.append([root, wall])
	if walls.size() == roots.size():
		return walls
	if roots.size() != 1:
		return []
	var params := TFShapeParams.cylinder_params(roots[0]) if roots[0] is TFBrush else TFShapeParams.stairs_params(roots[0])
	if params.is_empty() and not roots[0] is TFBrush:
		params = TFShapeParams.pipe_params(roots[0])
	if params.is_empty() and not roots[0] is TFBrush:
		params = TFShapeParams.bridge_params(roots[0])
	return [] if params.is_empty() else [[roots[0], params]]


## Shows the shape panel with the current parameters of the selected shape
## (the first wall), or hides it.
func _refresh_shape_panel() -> void:
	if _shape_panel == null:
		return
	var targets := _shape_targets()
	if targets.is_empty() or not _attach_panel(_shape_panel):
		_hide_shape_panel()
		return
	_shape_panel.set_values(targets[0][1], targets.size())
	_shape_panel.visible = true
	_place_panel(_shape_panel)


func _hide_shape_panel() -> void:
	if _shape_panel != null:
		_shape_panel.visible = false


## Rebuilds the selected shapes with the changed parameters as one undo
## action; repeated cylinder and wall changes (dragging a spin box) merge
## into it.
func _on_shape_panel_changed(changes: Dictionary) -> void:
	var targets := _shape_targets()
	if targets.is_empty():
		return
	var node: Node = targets[0][0]
	var params: Dictionary = targets[0][1]
	var undo_redo := get_undo_redo()
	var nodes: Array = targets.map(func(target: Array) -> Node: return target[0])
	var merge := UndoRedo.MERGE_ENDS if nodes == _shape_merge_target else UndoRedo.MERGE_DISABLE
	_shape_merge_target = nodes
	if node is TFBrush:
		var faces := TFShapeParams.rebuild_cylinder(node, changes)
		if faces.is_empty():
			return
		var meta := TFShapeParams.cylinder_meta(params["axis"], changes.get("sides", params["sides"]))
		TFUndo.replace_brushes(undo_redo, TFI18n.action("Change Cylinder"), [node], [faces], [], [], [], _ctx.scene_root(),
			{"meta": [[node, TFConst.META_SHAPE, meta]], "merge_mode": merge})
	elif params["type"] == TFShapeParams.TYPE_WALL:
		# Only the changed field applies, so walls keep their other values.
		var results: Array = []
		for target: Array in targets:
			var result := TFShapeParams.rebuild_wall(target[0], changes)
			if result.is_empty():
				TFTool.toast(TFI18n.t("Wall: a run is too short for the thickness."), EditorToaster.SEVERITY_WARNING)
				_shape_merge_target = []
				_refresh_shape_panel()
				return
			results.append(result)
		# The piece count stays, so dragging a spin box merges.
		_ctx.rebuild_group_shapes(nodes, results, TFI18n.action("Change Wall"), merge)
	elif params["type"] == TFShapeParams.TYPE_STAIRS:
		var result := TFShapeParams.rebuild_stairs(node, changes)
		if result.is_empty():
			return
		_shape_merge_target = []
		var meta := TFShapeParams.stairs_meta(result["up"], result["forward"], result["steps"])
		_ctx.rebuild_group_shape(node, result["sets"], meta, TFI18n.action("Change Stairs"), UndoRedo.MERGE_DISABLE)
	elif params["type"] == TFShapeParams.TYPE_BRIDGE:
		var result := TFShapeParams.rebuild_bridge(node, changes)
		if result.is_empty():
			TFTool.toast(TFBridgeAction.error_text(TFBridge.ERROR_FOLDS), EditorToaster.SEVERITY_WARNING)
			_shape_merge_target = []
			_refresh_shape_panel()
			return
		# Like pipes: piece counts change, so changes never merge.
		_shape_merge_target = []
		TFEditorSettings.store_bridge(changes)
		_ctx.rebuild_group_shape(node, result["sets"], result["meta"], TFI18n.action("Change Bridge"), UndoRedo.MERGE_DISABLE)
	else:
		var result := TFShapeParams.rebuild_pipe(node, changes)
		if result.is_empty():
			TFTool.toast(TFI18n.t("Pipe: a run is too short for the radius."), EditorToaster.SEVERITY_WARNING)
			_refresh_shape_panel()
			return
		# Piece counts change, so pipe changes never merge (added nodes).
		_shape_merge_target = []
		_ctx.rebuild_group_shape(node, result["sets"], result["meta"], TFI18n.action("Change Pipe"), UndoRedo.MERGE_DISABLE)
	_redraw()


## The Node3DEditorViewport control around the camera's viewport.
func _viewport_control(camera: Camera3D) -> Control:
	if camera == null or not is_instance_valid(camera):
		return null
	var container := camera.get_viewport().get_parent()
	return container.get_parent() as Control if container != null else null


## Rebuilds the active map now (Ctrl+B / toolbar).
func build_map() -> void:
	if _ctx.map == null or not is_instance_valid(_ctx.map):
		return
	_deselect_build_output(_ctx.map)
	_ctx.map.build()


## Called before running the project: bring all outdated maps up to date.
func _build() -> bool:
	for map in _edited_maps():
		if map.is_build_dirty() and not map.refresh_build_state():
			_deselect_build_output(map)
			map.build()
	return true


## All maps of the edited scene.
func _edited_maps() -> Array[TFMap]:
	var result: Array[TFMap] = []
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return result
	if root is TFMap:
		result.append(root)
	for node in root.find_children("*", "TFMap", true, false):
		result.append(node as TFMap)
	return result


## Godot calls the forced variant always and the other one only while it
## edits a handled node; draws once either way.
func _forward_3d_force_draw_over_viewport(overlay: Control) -> void:
	if not _godot_visible:
		_forward_3d_draw_over_viewport(overlay)


func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	TFEditorSettings.ensure_loaded()
	if not _visible or _ctx.map == null or not is_instance_valid(_ctx.map) or _active_name == "off":
		return
	_active.draw_2d(overlay)
	var camera := _camera_for(overlay)
	if camera != null and TFEditorSettings.show_dimensions and not _ctx.face_mode:
		TFDimensionOverlay.draw(overlay, camera, _ctx.selected_brushes())
	if TFEditorSettings.show_dimensions:
		TFDimensionOverlay.draw_cursor_label(overlay, _active.get_cursor_label())
	var lines: Array[String] = []
	var info := _active.get_info()
	if not info.is_empty():
		lines.append(info)
	if TFEditorSettings.show_status_line:
		lines.append(_status_line())
	if TFEditorSettings.show_help_line:
		lines.append(_paint.get_hint() if _paint.is_painting() else _active.get_hint())
	TFDimensionOverlay.draw_lines(overlay, lines)


func _status_line() -> String:
	var mode := TFI18n.t("Faces") if _ctx.face_mode else TFI18n.t("Brushes")
	var parts: Array[String] = ["TrenchForge · %s · %s · %s" % [_tool_label(), mode, TFI18n.t("Grid %s m") % TFTool.format_length(_ctx.grid_size())]]
	if TFEditorSettings.show_cursor_position and not _cursor.is_empty():
		var p: Vector3 = _cursor["point"]
		parts.append(TFI18n.t("Cursor %s, %s, %s") % [TFTool.format_length(p.x), TFTool.format_length(p.y), TFTool.format_length(p.z)])
	if _ctx.entered_group != null and is_instance_valid(_ctx.entered_group):
		parts.append(TFI18n.t("in group “%s” (%s: leave)") % [_ctx.entered_group.name, TFShortcuts.text("cancel")])
	var hidden := _map_actions.hidden_count()
	if hidden > 0:
		parts.append(TFI18n.t("%d hidden (%s: show)") % [hidden, TFShortcuts.text("unhide_all")])
	if _invalid_count > 0:
		parts.append(TFI18n.t("⚠ %d invalid brush(es) – Map ▸ Validate Map") % _invalid_count)
	parts.append((TFI18n.t("Build outdated (%s)") % TFShortcuts.text("build")) if _ctx.map.is_build_dirty() else TFI18n.t("Build up to date"))
	return " · ".join(parts)


## Translated name of the active tool for the status line.
func _tool_label() -> String:
	var index := TFToolbar.TOOLS.find_custom(func(entry: Array) -> bool: return entry[0] == _active_name)
	return TFI18n.t(TFToolbar.TOOLS[index][1]) if index != -1 else TFShortcuts.label(_active_name)


## The camera of the editor viewport that owns the overlay control.
func _camera_for(overlay: Control) -> Camera3D:
	for i in 4:
		var viewport := EditorInterface.get_editor_viewport_3d(i)
		if viewport == null:
			continue
		var container := viewport.get_parent()
		var editor_viewport := container.get_parent() if container != null else null
		if editor_viewport != null and editor_viewport.is_ancestor_of(overlay):
			return viewport.get_camera_3d()
	return null


func _handle_global_key(event: InputEventKey) -> bool:
	var action := TFShortcuts.find_action("global", event)
	match action:
		"":
			return false
		"grid_toggle":
			_ctx.toggle_grid_visible()
			return true
		"texture_lock":
			_ctx.texture_lock = not _ctx.texture_lock
			return true
	# Face snap is modal: only grid and texture lock pass through.
	if _active_name == "face_snap":
		return false
	match action:
		"build":
			build_map()
		"csg_subtract":
			run_csg("subtract")
		"csg_hollow":
			run_csg("hollow")
		"csg_merge":
			run_csg("merge")
		"bridge":
			run_csg("bridge")
		"tool_vertex":
			set_vertex_mode(TFVertexTool.Mode.VERTEX)
		"tool_edge":
			set_vertex_mode(TFVertexTool.Mode.EDGE)
		"tool_vertex_face":
			set_vertex_mode(TFVertexTool.Mode.FACE)
		"grid_smaller":
			_ctx.step_grid(false)
		"grid_larger":
			_ctx.step_grid(true)
		"tool_box":
			set_tool("box")
		"tool_shape":
			if _active_name == "shape":
				_tools["shape"].cycle_shape()
				_refresh_toolbar()
			else:
				set_tool("shape")
		"tool_clip":
			set_tool("clip")
		"tool_cube_cut":
			set_tool("cube_cut")
		"face_mode":
			_set_face_mode(not _ctx.face_mode)
		"face_inspector":
			_inspector_dock.make_visible()
			_inspector.focus_first_field()
		"uv_editor_focus":
			_uv_dock.make_visible()
			_uv_editor.focus_canvas()
		"face_snap":
			if _ctx.target_faces().is_empty():
				return false
			set_tool("face_snap")
		_:
			run_map_action(action)
	return true


func _set_face_mode(enabled: bool) -> void:
	_ctx.face_mode = enabled
	if enabled and _active_name != "select":
		set_tool("select")


func _update_grid(camera: Camera3D, screen_pos: Vector2) -> void:
	var overlay := _ctx.overlay()
	if overlay == null:
		return
	if not _ctx.grid_visible:
		overlay.hide_grid()
		return
	var anchor := _active.get_grid_anchor()
	if anchor.is_empty():
		anchor = _ctx.picker.pick(_ctx, camera, screen_pos, true)
	if anchor.is_empty():
		overlay.hide_grid()
	else:
		overlay.show_grid(anchor["point"], anchor["normal"], _ctx.grid_size())


func _update_cursor(camera: Camera3D, screen_pos: Vector2) -> void:
	if not TFEditorSettings.show_cursor_position:
		return
	_cursor = _ctx.picker.pick(_ctx, camera, screen_pos, false)


func _redraw() -> void:
	TFEditorSettings.ensure_loaded()
	var overlay := _ctx.overlay()
	if overlay == null:
		return
	overlay.clear()
	if _visible and _active_name != "off":
		_active.draw_3d(overlay)
		_draw_invalid(overlay)
	else:
		overlay.hide_grid()
	overlay.flush()
	update_overlays()


## Marks degenerate brushes (no volume) with a cross and their remaining
## edges; Validate Map removes them.
func _draw_invalid(overlay: TFOverlay3D) -> void:
	var invalid: Array[TFBrush] = []
	if TFEditorSettings.highlight_invalid_brushes:
		invalid = _map_actions.invalid_brushes()
	_invalid_count = invalid.size()
	for brush: TFBrush in invalid:
		overlay.add_brush_edges(brush, TFEditorContext.COLOR_INVALID)
		var center := brush.global_position
		if not brush.get_polyhedron().vertices.is_empty():
			center = brush.global_transform * brush.get_local_aabb().get_center()
		overlay.add_cross(center, _ctx.grid_size() * 0.5, TFEditorContext.COLOR_INVALID)


func _on_editor_settings_changed() -> void:
	var changed := EditorInterface.get_editor_settings().get_changed_settings()
	TFShortcuts.load_shortcuts()
	if Array(changed).any(func(setting: String) -> bool: return setting.begins_with(TFShortcuts.SETTING_PREFIX)):
		for conflict in TFShortcuts.find_conflicts():
			EditorInterface.get_editor_toaster().push_toast("TrenchForge: " + TFI18n.t("Shortcut conflict %s: %s / %s") % [conflict[2], TFShortcuts.label(conflict[0]), TFShortcuts.label(conflict[1])], EditorToaster.SEVERITY_WARNING)
	var language := TFI18n.language
	_apply_editor_settings()
	if TFI18n.language != language:
		# Deferred: the settings dock that changed the language is rebuilt.
		_retranslate.call_deferred()


func _apply_editor_settings() -> void:
	TFEditorSettings.load_settings()
	for map in _edited_maps():
		map.refresh_editor_visibility()
	_update_transform_gizmo()
	_refresh_toolbar()
	_redraw()


func _refresh_toolbar() -> void:
	if _toolbar != null:
		_toolbar.refresh(_ctx, _active_name, _tools["vertex"], _tools["clip"], _tools["shape"])


func _on_context_changed() -> void:
	_watch_map(_ctx.map)
	_refresh_toolbar()
	_refresh_inspector()
	_browser.set_current_material(_ctx.current_material)
	if not _ctx.grid_visible and _ctx.overlay() != null:
		_ctx.overlay().hide_grid()
	_redraw()


func _on_selection_changed() -> void:
	_update_visible()
	_hide_bevel_panel()
	_refresh_shape_panel()
	_refresh_inspector()
	_update_transform_gizmo()
	if _visible:
		_redraw()


## Godot's transform gizmo is hidden while TrenchForge edits selected brushes
## or groups (editor setting Viewport > Hide Transform Gizmo).
func _update_transform_gizmo() -> void:
	if _gizmo == null:
		return
	var hidden := TFEditorSettings.hide_transform_gizmo and _visible and _active_name != "off"
	if hidden:
		hidden = EditorInterface.get_selection().get_selected_nodes().any(func(node: Node) -> bool:
			var map := _find_map(node)
			return node is TFBrush or (map != null and TFGroups.is_group(node, map)))
	_gizmo.set_hidden(hidden)


## Face inspector and UV editor show the target faces; both follow
## selection, undo/redo and context changes.
func _refresh_inspector() -> void:
	if _inspector != null:
		_inspector.refresh()
	if _uv_editor != null:
		_uv_editor.queue_refresh()


func _make_dock(control: Control, title: String, layout_key: String, slot: EditorDock.DockSlot, icon: StringName) -> EditorDock:
	var dock := EditorDock.new()
	dock.title = title
	dock.layout_key = layout_key
	dock.default_slot = slot
	dock.icon_name = icon
	dock.available_layouts = EditorDock.DOCK_LAYOUT_VERTICAL | EditorDock.DOCK_LAYOUT_HORIZONTAL | EditorDock.DOCK_LAYOUT_FLOATING
	dock.add_child(control)
	add_dock(dock)
	return dock


func _on_scene_changed(_root: Node) -> void:
	_paint.cancel()
	_active.cancel()
	_uv_editor.cancel_drag()
	_update_build_suspension()
	_ctx.set_map(null)
	# The new scene's editor state may bring its own gizmo visibility.
	_update_transform_gizmo.call_deferred()
	_update_visible.call_deferred()


func _watch_map(map: TFMap) -> void:
	if _watched_map == map:
		return
	if _watched_map != null and is_instance_valid(_watched_map):
		_watched_map.build_state_changed.disconnect(_on_build_state_changed)
		_watched_map.set_build_suspended(false)
	_watched_map = map
	if map != null:
		map.build_state_changed.connect(_on_build_state_changed)


func _on_build_state_changed() -> void:
	_refresh_toolbar()
	if _visible:
		update_overlays()


## Automatic rebuilds wait while a tool drag or paint gesture is live.
func _update_build_suspension() -> void:
	if _ctx.map != null and is_instance_valid(_ctx.map):
		_ctx.map.set_build_suspended(_active.is_busy() or _paint.is_painting())


## The build output is replaced by a rebuild; drop it from the selection
## so the inspector does not keep freed nodes.
func _deselect_build_output(map: TFMap) -> void:
	var root := map.get_build_root()
	if root == null:
		return
	var selection := EditorInterface.get_selection()
	for node in selection.get_selected_nodes():
		if node == root or root.is_ancestor_of(node):
			selection.remove_node(node)


func _find_map(node: Node) -> TFMap:
	while node != null:
		if node is TFMap:
			return node
		node = node.get_parent()
	return null


func _selected_maps() -> Array[TFMap]:
	var maps: Array[TFMap] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		var map := _find_map(node)
		if map != null and not maps.has(map):
			maps.append(map)
	return maps

