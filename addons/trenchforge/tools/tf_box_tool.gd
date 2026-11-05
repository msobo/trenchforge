@tool
class_name TFBoxTool
extends TFTool
## Box builder: Anvil-style three clicks (start, base, height) or
## TrenchBroom-style drag for the base followed by a height click.

enum State { IDLE, BASE, HEIGHT }

var _state := State.IDLE
var _cursor: Dictionary = {}
var _start := Vector3.ZERO
var _end := Vector3.ZERO
var _axis := Vector3.UP
var _base_plane := Plane(Vector3.UP, 0.0)
var _height := 0.0
var _last_depth := 0.0
var _press_pos := Vector2.ZERO
var _pressed := false


func get_tool_name() -> String:
	return "box"


func cancel() -> void:
	_state = State.IDLE
	_pressed = false


func get_hint() -> String:
	match _state:
		State.BASE:
			return TFI18n.t("LMB: set base · %s: cancel") % keys("cancel")
		State.HEIGHT:
			return TFI18n.t("Mouse: height · LMB: create brush · %s: cancel") % keys("cancel")
	return TFI18n.t("LMB: start point (or drag) · Ctrl: lock plane · %s: Select tool") % keys("cancel")


func get_info() -> String:
	return get_cursor_label()


func get_cursor_label() -> String:
	if _state == State.IDLE:
		return ""
	var size := _current_box().size
	return "%s × %s × %s m" % [format_length(size.x), format_length(size.y), format_length(size.z)]


func get_grid_anchor() -> Dictionary:
	if _state != State.IDLE:
		return {"point": _end, "normal": _axis}
	return _cursor


func handle_input(camera: Camera3D, event: InputEvent) -> bool:
	if event is InputEventMouseMotion:
		_on_motion(camera, event)
		return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_on_press(camera, event)
		else:
			_on_release(camera, event)
		return true
	if event is InputEventKey and event.pressed and TFShortcuts.matches("cancel", event):
		if _state == State.IDLE:
			ctx.request_tool("select")
		else:
			cancel()
		return true
	return false


func draw_3d(overlay: TFOverlay3D) -> void:
	match _state:
		State.IDLE:
			if not _cursor.is_empty():
				overlay.add_cross(_cursor["point"], ctx.grid_size() * 0.5, TFEditorContext.COLOR_CURSOR)
		State.BASE, State.HEIGHT:
			overlay.add_box(_current_box(), TFEditorContext.COLOR_PREVIEW)


func _on_motion(camera: Camera3D, event: InputEventMouseMotion) -> void:
	match _state:
		State.IDLE:
			_cursor = ctx.picker.pick(ctx, camera, event.position, is_ctrl(event))
		State.BASE:
			var point: Variant = ctx.picker.pick_on_plane(ctx, camera, event.position, _base_plane)
			if point != null:
				_end = point
		State.HEIGHT:
			_height = TFPointPicker.pick_along_axis(camera, event.position, _end, _axis, ctx.grid_size(), true)


func _on_press(camera: Camera3D, event: InputEventMouseButton) -> void:
	match _state:
		State.IDLE:
			var hit := ctx.picker.pick(ctx, camera, event.position, is_ctrl(event))
			if hit.is_empty():
				return
			_start = hit["point"]
			_end = _start
			_axis = hit["normal"]
			_base_plane = Plane(_axis, _start)
			ctx.picker.adopt_plane(_base_plane)
			_state = State.BASE
			_pressed = true
			_press_pos = event.position
		State.BASE:
			_finish_base(camera)
		State.HEIGHT:
			_commit()


func _on_release(camera: Camera3D, event: InputEventMouseButton) -> void:
	if _state == State.BASE and _pressed and event.position.distance_to(_press_pos) > DRAG_THRESHOLD:
		_finish_base(camera)
	_pressed = false


func _finish_base(camera: Camera3D) -> void:
	_pressed = false
	if _start.is_equal_approx(_end):
		return
	# In an orthographic view looking along the extrusion axis the height
	# cannot be dragged, so reuse the last depth (or one grid step).
	var forward := -camera.global_basis.z
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL and absf(forward.dot(_axis)) > 0.99:
		_commit_ortho()
		return
	_height = 0.0
	_state = State.HEIGHT


## Commit in an orthographic view along the axis, where no height can be
## dragged.
func _commit_ortho() -> void:
	_height = _last_depth if _last_depth > 0.0 else ctx.grid_size()
	_state = State.HEIGHT
	_commit()


func _current_box() -> AABB:
	var box := AABB(_start, Vector3.ZERO).expand(_end)
	if _state == State.HEIGHT:
		box = box.expand(_end + _axis * _height)
	return box


func _commit() -> void:
	if is_zero_approx(_height):
		return
	var box := _current_box()
	# A line-shaped base becomes a wall one grid step thick.
	var grid := ctx.grid_size()
	for i in 3:
		if is_zero_approx(box.size[i]):
			box.size[i] = grid
	_last_depth = absf(_height)
	_state = State.IDLE
	_create(box)


## Creates the brush for the finished box (world space).
func _create(box: AABB) -> void:
	if ctx.map == null:
		return
	var parent := ctx.parent_for_new()
	var local_box := parent.global_transform.affine_inverse() * box
	var brush := TFBrush.create_box(local_box, ctx.current_material)
	TFUndo.add_brush(ctx.undo_redo(), TFI18n.action("Create brush"), parent, brush, ctx.scene_root())
	var selection: Array[TFBrush] = [brush]
	ctx.select_brushes(selection)
