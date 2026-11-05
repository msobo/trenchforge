@tool
class_name TFClipTool
extends TFTool
## Clip tool: cuts the selected brushes by a plane. Two points define the
## plane together with the view direction (orthographic views) or the normal
## of the surface under the first point (Anvil); a third point tilts it
## freely (TrenchBroom). Points stay draggable until the clip is confirmed.
## An arrow shows the plane normal, i.e. the front side: green if that side is
## kept, red if it is removed.

## Screen distance (px, before editor scale) to grab a placed point.
const HANDLE_RADIUS: float = 10.0
const COLOR_REMOVED := Color(1.0, 0.2, 0.15, 0.3)
const COLOR_PLANE := Color(1.0, 0.85, 0.3, 0.8)
const COLOR_KEPT_SIDE := Color(0.35, 0.95, 0.45, 1.0)
const COLOR_REMOVED_SIDE := Color(1.0, 0.3, 0.2, 1.0)
## Length of the normal arrow relative to the selection size, and its limits
## in grid steps.
const NORMAL_ARROW_FRACTION: float = 0.4
const NORMAL_ARROW_MIN_GRID: float = 2.0
const NORMAL_ARROW_MAX_GRID: float = 8.0
## Names per keep mode (English, translated when shown).
const MODE_NAMES := ["Keep front", "Keep back", "Keep both (split)"]

var keep := TFCSGActions.ClipKeep.FRONT
var _actions: TFCSGActions
var _points := PackedVector3Array()
## Direction the plane contains when only two points exist.
var _view_axis := Vector3.UP
var _cursor: Dictionary = {}
var _hover_index := -1
var _drag_index := -1
var _drag_origin := Vector3.ZERO


func _init(p_ctx: TFEditorContext) -> void:
	super(p_ctx)
	_actions = TFCSGActions.new(p_ctx)


func get_tool_name() -> String:
	return "clip"


func cancel() -> void:
	if _drag_index != -1:
		_points[_drag_index] = _drag_origin
		_drag_index = -1
		return
	_points.clear()
	_hover_index = -1


func get_hint() -> String:
	if ctx.selected_brushes().is_empty():
		return TFI18n.t("Clip: select brushes first (%s: Select tool)") % keys("cancel")
	if _points.size() < 2:
		return TFI18n.t("LMB: set point %d · Ctrl: lock plane · %s: cancel") % [_points.size() + 1, keys("cancel")]
	var extra := TFI18n.t("LMB: 3rd point (tilt)") if _points.size() == 2 else TFI18n.t("LMB: clip")
	return TFI18n.t("%s · drag points · %s/%s: mode · %s: clip · %s: last point · %s: cancel") % [
		extra, keys("clip_mode_prev"), keys("clip_mode_next"), keys("clip_confirm"), keys("clip_remove_point"), keys("cancel")]


func get_info() -> String:
	var plane: Variant = clip_plane()
	if plane == null:
		return "Clip · %s" % TFI18n.t(MODE_NAMES[keep])
	var n: Vector3 = (plane as Plane).normal
	return TFI18n.t("Clip · %s · normal %.2f, %.2f, %.2f") % [TFI18n.t(MODE_NAMES[keep]), n.x, n.y, n.z]


func get_grid_anchor() -> Dictionary:
	return _cursor


func handle_input(camera: Camera3D, event: InputEvent) -> bool:
	if event is InputEventMouseMotion:
		return _on_motion(camera, event)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_on_press(camera, event)
		elif _drag_index != -1:
			_drag_index = -1
		return true
	if event is InputEventKey and event.pressed:
		return _on_key(event)
	return false


func draw_3d(overlay: TFOverlay3D) -> void:
	var selection := ctx.selected_brushes()
	var plane: Variant = clip_plane()
	for brush in selection:
		if plane == null:
			overlay.add_brush_edges(brush, TFEditorContext.COLOR_SELECTED)
			continue
		var parts := _actions.clip_parts(brush, plane)
		var xf := brush.global_transform
		for side in 2:
			var removed: bool = keep != TFCSGActions.ClipKeep.BOTH and side != keep
			if removed:
				overlay.add_faces_fill(parts[side], xf, COLOR_REMOVED)
			else:
				overlay.add_faces_edges(parts[side], xf, TFEditorContext.COLOR_SELECTED)
	if plane != null and not selection.is_empty():
		var box := TFPicking.brushes_aabb(selection)
		overlay.add_plane_patch(plane, box.get_center(), box.size.length() * 0.5 + ctx.grid_size(), ctx.grid_size(), COLOR_PLANE)
		_draw_normal(overlay, plane, box)
	for i in _points.size():
		overlay.add_point(_points[i], TFEditorContext.COLOR_HOVER if i == _hover_index or i == _drag_index else TFEditorContext.COLOR_CURSOR)
	if _points.size() >= 2:
		overlay.add_line(_points[0], _points[1], COLOR_PLANE)
	if _points.size() == 3:
		overlay.add_line(_points[1], _points[2], COLOR_PLANE)
		overlay.add_line(_points[2], _points[0], COLOR_PLANE)
	if _drag_index == -1 and _hover_index == -1 and not _cursor.is_empty() and _points.size() < 3:
		overlay.add_cross(_cursor["point"], ctx.grid_size() * 0.5, TFEditorContext.COLOR_CURSOR)


## Arrow along the plane normal from the middle of the clip points (projected
## onto the plane, where the user looks), colored by the fate of the front
## side.
func _draw_normal(overlay: TFOverlay3D, plane: Plane, box: AABB) -> void:
	var center := Vector3.ZERO
	for p in _points:
		center += p
	center = plane.project(center / float(_points.size()))
	var grid := ctx.grid_size()
	var length := clampf(box.size.length() * NORMAL_ARROW_FRACTION, grid * NORMAL_ARROW_MIN_GRID, grid * NORMAL_ARROW_MAX_GRID)
	var color := COLOR_REMOVED_SIDE if keep == TFCSGActions.ClipKeep.BACK else COLOR_KEPT_SIDE
	overlay.add_arrow(center, plane.normal, length, color)
	# A screen-sized dot marks the tip, the thin lines alone are easy to miss.
	overlay.add_point(center + plane.normal * length, color)


## World-space clip plane, or null while it is undefined.
func clip_plane() -> Variant:
	if _points.size() < 2:
		return null
	var normal: Vector3
	if _points.size() == 3:
		normal = (_points[1] - _points[0]).cross(_points[2] - _points[0])
	else:
		normal = (_points[1] - _points[0]).cross(_view_axis)
	if normal.length() <= TFConst.EPSILON:
		return null
	return Plane(normal.normalized(), _points[0])


## Applies the clip to the selection and starts over.
func commit() -> bool:
	var plane: Variant = clip_plane()
	var selection := ctx.selected_brushes()
	if plane == null or selection.is_empty():
		return false
	var done := _actions.clip(selection, plane, keep)
	_points.clear()
	_hover_index = -1
	return done


func cycle_mode(step: int) -> void:
	keep = posmod(keep + step, 3) as TFCSGActions.ClipKeep


func _on_motion(camera: Camera3D, event: InputEventMouseMotion) -> bool:
	if _drag_index != -1:
		var hit := ctx.picker.pick(ctx, camera, event.position, is_ctrl(event))
		if not hit.is_empty():
			_points[_drag_index] = hit["point"]
		return true
	_cursor = ctx.picker.pick(ctx, camera, event.position, is_ctrl(event))
	_hover_index = _handle_at(camera, event.position)
	return false


func _on_press(camera: Camera3D, event: InputEventMouseButton) -> void:
	var index := _handle_at(camera, event.position)
	if index != -1:
		_drag_index = index
		_drag_origin = _points[index]
		return
	if _points.size() == 3:
		commit()
		return
	var hit := ctx.picker.pick(ctx, camera, event.position, is_ctrl(event))
	if hit.is_empty():
		return
	if _points.is_empty():
		var forward := -camera.global_basis.z
		_view_axis = TFSnap.dominant_axis(forward) if camera.projection == Camera3D.PROJECTION_ORTHOGONAL else hit["normal"]
		ctx.picker.adopt_plane(Plane(hit["normal"], hit["point"]))
	if TFHull.find_point(_points, hit["point"]) == -1:
		_points.append(hit["point"])


func _on_key(event: InputEventKey) -> bool:
	if event.echo:
		return false
	if TFShortcuts.matches("cancel", event):
		if _drag_index == -1 and _points.is_empty():
			ctx.request_tool("select")
		else:
			cancel()
		return true
	match TFShortcuts.find_action("clip", event):
		"clip_confirm":
			commit()
			return true
		"clip_remove_point":
			if not _points.is_empty() and _drag_index == -1:
				_points.remove_at(_points.size() - 1)
				return true
		"clip_mode_prev":
			cycle_mode(-1)
			return true
		"clip_mode_next":
			cycle_mode(1)
			return true
	return false


func _handle_at(camera: Camera3D, screen_pos: Vector2) -> int:
	var radius := HANDLE_RADIUS * EditorInterface.get_editor_scale()
	for i in _points.size():
		if camera.is_position_behind(_points[i]):
			continue
		if camera.unproject_position(_points[i]).distance_to(screen_pos) <= radius:
			return i
	return -1
