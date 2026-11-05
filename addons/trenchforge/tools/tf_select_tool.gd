@tool
class_name TFSelectTool
extends TFTool
## Selection (brush or face mode), drag-move, Shift-drag face resize (a
## parametric pipe stretches its path instead, TFShapeParams.stretch_pipe()), face
## extrude (E modal or Ctrl+Shift-drag; negative depth pushes the face in),
## inset (I modal), bevel (Ctrl+Shift+B modal, TFBevelOperation) and the
## keyboard transform commands (nudge, duplicate, delete, rotate). A click on a grouped brush selects the
## group; a double click enters it. Compounds (Verbünde) show their outline;
## in face mode a click selects a whole logical face until the compound is
## entered.

enum State { IDLE, PRESS, MOVE, RESIZE, EXTRUDE, INSET }

var _state := State.IDLE
var _hover: Dictionary = {}
var _press_pos := Vector2.ZERO
var _press_hit: Dictionary = {}
var _press_shift := false
var _press_alt := false
var _press_ctrl := false
var _press_double := false
var _mouse_pos := Vector2.ZERO

# Move state.
var _move_brushes: Array[TFBrush] = []
var _move_origins: Array = []
var _move_snapshots: Array = []  # Faces before the move (texture lock only).
var _move_plane := Plane(Vector3.UP, 0.0)
var _move_start := Vector3.ZERO
var _move_delta := Vector3.ZERO

# Resize state.
var _resize_brushes: Array[TFBrush] = []
var _resize_face_indices: Array[int] = []
var _resize_snapshots: Array = []
var _resize_normal := Vector3.UP
var _resize_point := Vector3.ZERO
var _resize_delta := 0.0
# Pipe stretch (resize of a parametric pipe): the compound, its parameters
# before the drag, the dragged axis
# and face coordinate (compound-local), the last valid stretch_pipe() result
# and, while its piece count differs from the pipe's, its outline (compound
# space) as the preview.
var _stretch_pipe: Node3D = null
var _stretch_params: Dictionary = {}
var _stretch_axis := Vector3.ZERO
var _stretch_at := 0.0
var _stretch_result: Dictionary = {}
var _stretch_outline: Array = []

# Extrude state: one new brush per target face, previewed in the overlay.
var _extrude_targets: Array = []  # [brush, face_index]
var _extrude_results: Array = []  # Array[TFFace] per target, empty if invalid
var _extrude_normal := Vector3.UP
var _extrude_point := Vector3.ZERO
var _extrude_start := 0.0
var _extrude_distance := 0.0
var _extrude_modal := false
var _push_results: Array = []  # TFCSG.push_face() per target, null if invalid

# Inset state: one face per brush, split into core and ring on commit.
var _inset_targets: Array = []  # [brush, face_index]
var _inset_results: Array = []  # TFCSG.inset() per target
var _inset_plane := Plane(Vector3.UP, 0.0)
var _inset_center := Vector3.ZERO
var _inset_start := 0.0
var _inset_width := 0.0


func get_tool_name() -> String:
	return "select"


func cancel() -> void:
	ctx.bevel.cancel()
	match _state:
		State.MOVE:
			for i in _move_brushes.size():
				_move_brushes[i].position = _move_origins[i]
				if not _move_snapshots.is_empty():
					_move_brushes[i].faces = TFUndo.copy_faces(_move_snapshots[i])
		State.RESIZE:
			for i in _resize_brushes.size():
				_resize_brushes[i].faces = TFUndo.copy_faces(_resize_snapshots[i])
			_stretch_pipe = null
			_stretch_outline = []
		State.EXTRUDE:
			_extrude_results = []
			_push_results = []
		State.INSET:
			_inset_results = []
	_state = State.IDLE


func is_busy() -> bool:
	return ctx.bevel.is_active() or _state == State.MOVE or _state == State.RESIZE or _state == State.EXTRUDE or _state == State.INSET


func wants_all_input() -> bool:
	return ctx.bevel.is_active()


func get_cursor_label() -> String:
	return ctx.bevel.get_cursor_label() if ctx.bevel.is_active() else ""


func get_hint() -> String:
	if ctx.bevel.is_active():
		return ctx.bevel.get_hint()
	match _state:
		State.MOVE:
			return TFI18n.t("Drag: move · Alt: vertical · %s: cancel") % keys("cancel")
		State.RESIZE:
			return TFI18n.t("Drag: move face · %s: cancel") % keys("cancel")
		State.EXTRUDE:
			if _extrude_modal:
				return TFI18n.t("Mouse: depth · LMB: extrude · %s: cancel") % keys("cancel")
			return TFI18n.t("Drag: depth · %s: cancel") % keys("cancel")
		State.INSET:
			return TFI18n.t("Mouse toward center: rim width · LMB: inset · %s: cancel") % keys("cancel")
	if ctx.face_mode:
		return TFI18n.t("LMB: select face · Shift: add · %s: extrude · %s: inset · %s: bevel edges · %s: brush mode · %s: box") % [keys("extrude"), keys("inset"), keys("bevel"), keys("face_mode"), keys("tool_box")]
	var group := TFI18n.t(" · Double-click: enter group") if ctx.entered_group == null else TFI18n.t(" · %s: leave group") % keys("cancel")
	return TFI18n.t("LMB: select/drag · Shift+drag: resize · %s: extrude · %s: inset · %s: bevel · Arrows/PgUp/PgDn: nudge · %s: duplicate · %s: delete · %s: rotate · %s: face mode%s") % [
		keys("extrude"), keys("inset"), keys("bevel"), keys("duplicate"), keys("delete"), keys("rotate_cw"), keys("face_mode"), group]


func get_info() -> String:
	if ctx.bevel.is_active():
		return ctx.bevel.get_info()
	match _state:
		State.MOVE:
			return "Δ %s, %s, %s m" % [format_length(_move_delta.x), format_length(_move_delta.y), format_length(_move_delta.z)]
		State.RESIZE:
			return "Δ %s m" % format_length(_resize_delta)
		State.EXTRUDE:
			if _extrude_distance < 0.0:
				return TFI18n.t("Push in %s m · %d face(s)") % [format_length(_extrude_distance), _extrude_targets.size()]
			return TFI18n.t("Extrude %s m · %d face(s)") % [format_length(_extrude_distance), _extrude_targets.size()]
		State.INSET:
			return TFI18n.t("Inset %s m · %d face(s)") % [format_length(_inset_width), _inset_targets.size()]
	var selection := ctx.selected_brushes()
	if selection.is_empty():
		return ""
	var size := TFPicking.brushes_aabb(selection).size
	return TFI18n.t("%d brush(es) · %s × %s × %s m") % [selection.size(), format_length(size.x), format_length(size.y), format_length(size.z)]


func handle_input(camera: Camera3D, event: InputEvent) -> bool:
	if ctx.bevel.is_active():
		return ctx.bevel.handle_input(camera, event)
	if event is InputEventMouseMotion:
		return _on_motion(camera, event)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_on_press(camera, event)
		else:
			_on_release(camera, event)
		return true
	if event is InputEventKey and event.pressed:
		return _on_key(camera, event)
	return false


func draw_3d(overlay: TFOverlay3D) -> void:
	ctx.prune_faces()
	ctx.bevel.draw_3d(overlay)
	# The hovered brush may be gone since the last mouse motion (deleted,
	# undone, replaced by a CSG operation).
	if not _hover.is_empty() and (not is_instance_valid(_hover["brush"]) or not (_hover["brush"] as Node).is_inside_tree()):
		_hover = {}
	if ctx.face_mode:
		for entry in ctx.selected_faces:
			if not ctx.face_fill_hidden:
				for polygon in ctx.face_fill_polygons(entry[0], entry[1]):
					overlay.add_polygon(polygon, Color(TFEditorContext.COLOR_FACE_MODE, 0.35))
			_draw_face_outline(overlay, entry[0], entry[1], TFEditorContext.COLOR_FACE_MODE)
		# The hover stays on the last face when the mouse moves to the material
		# browser; it must not tint the face whose new material is on display.
		var hover_hidden := not _hover.is_empty() and ctx.face_fill_hidden and ctx.is_face_selected(_hover["brush"], _hover["face_index"])
		if not _hover.is_empty() and _state == State.IDLE and not hover_hidden:
			var hovered := ctx.logical_face(_hover["brush"], _hover["face_index"])
			for entry in hovered:
				for polygon in ctx.face_fill_polygons(entry[0], entry[1]):
					overlay.add_polygon(polygon, TFEditorContext.COLOR_FACE_HOVER)
			for line: Array in ctx.logical_face_lines(hovered):
				overlay.add_line(line[0], line[1], TFEditorContext.COLOR_HOVER)
	elif not _hover.is_empty() and _state == State.IDLE and not ctx.is_selected(_hover["brush"]):
		ctx.draw_brush_outlines(overlay, TFGroups.brushes_of(ctx.selectable_for(_hover["brush"])), TFEditorContext.COLOR_HOVER)
	# Face mode: brushes with selected faces show their whole compound, dimmed
	# in the face mode accent so the faces stand out.
	var outline_color := Color(TFEditorContext.COLOR_FACE_MODE, 0.35) if ctx.face_mode else TFEditorContext.COLOR_SELECTED
	ctx.draw_brush_outlines(overlay, ctx.selected_brushes(), outline_color, ctx.face_mode)
	for group_node in ctx.selected_groups():
		var members := TFGroups.brushes_of(group_node)
		if not members.is_empty() and not ctx.is_compound(group_node):
			overlay.add_box(TFPicking.brushes_aabb(members).grow(ctx.grid_size() * 0.0625), TFEditorContext.COLOR_GROUP)
	if ctx.entered_group != null and is_instance_valid(ctx.entered_group):
		var members := TFGroups.brushes_of(ctx.entered_group)
		if ctx.is_compound(ctx.entered_group):
			# Inside a compound its brushes show faintly as they are.
			for brush in members:
				if not brush.is_editor_hidden():
					overlay.add_brush_edges(brush, Color(TFEditorContext.COLOR_GROUP, 0.35))
		elif not members.is_empty():
			overlay.add_box(TFPicking.brushes_aabb(members).grow(ctx.grid_size() * 0.125), Color(TFEditorContext.COLOR_GROUP, 0.4))
	if _state == State.RESIZE and _stretch_pipe != null:
		for edge: Array in _stretch_outline:
			overlay.add_line(_stretch_pipe.global_transform * (edge[0] as Vector3), _stretch_pipe.global_transform * (edge[1] as Vector3), TFEditorContext.COLOR_PREVIEW)
	elif _state == State.RESIZE:
		for i in _resize_brushes.size():
			overlay.add_polygon(TFPicking.face_world_polygon(_resize_brushes[i], _resize_face_indices[i]), TFEditorContext.COLOR_FACE_SELECTED)
	if _state == State.EXTRUDE:
		for i in _extrude_targets.size():
			var brush: TFBrush = _extrude_targets[i][0]
			overlay.add_polygon(TFPicking.face_world_polygon(brush, _extrude_targets[i][1]), TFEditorContext.COLOR_FACE_SELECTED)
			if i < _extrude_results.size() and not (_extrude_results[i] as Array).is_empty():
				overlay.add_faces_fill(_extrude_results[i], brush.global_transform, Color(TFEditorContext.COLOR_PREVIEW, 0.2))
				overlay.add_faces_edges(_extrude_results[i], brush.global_transform, TFEditorContext.COLOR_PREVIEW)
			if i < _push_results.size() and _push_results[i] != null:
				var bottom := TFPicking.face_world_polygon(brush, _extrude_targets[i][1])
				var normal := (brush.global_basis * brush.faces[_extrude_targets[i][1]].plane.normal).normalized()
				for j in bottom.size():
					bottom[j] += normal * _extrude_distance
				overlay.add_polygon(bottom, Color(TFEditorContext.COLOR_PREVIEW, 0.3))
				if (_push_results[i] as Array).is_empty():
					overlay.add_brush_edges(brush, TFEditorContext.COLOR_SELECTED)
				for fragment: Array[TFFace] in _push_results[i]:
					overlay.add_faces_edges(fragment, brush.global_transform, TFEditorContext.COLOR_PREVIEW)
	if _state == State.INSET:
		for i in _inset_targets.size():
			var brush: TFBrush = _inset_targets[i][0]
			overlay.add_polygon(TFPicking.face_world_polygon(brush, _inset_targets[i][1]), TFEditorContext.COLOR_FACE_SELECTED)
			if i < _inset_results.size() and not (_inset_results[i] as Dictionary).is_empty():
				var result: Dictionary = _inset_results[i]
				overlay.add_faces_fill(result["core"], brush.global_transform, Color(TFEditorContext.COLOR_PREVIEW, 0.2))
				overlay.add_faces_edges(result["core"], brush.global_transform, TFEditorContext.COLOR_PREVIEW)
				for fragment: Array[TFFace] in result["ring"]:
					overlay.add_faces_edges(fragment, brush.global_transform, Color(TFEditorContext.COLOR_PREVIEW, 0.5))


# --- mouse ------------------------------------------------------------------

## Outline of a selected face: its logical face's outline inside a closed
## compound, else the face polygon.
func _draw_face_outline(overlay: TFOverlay3D, brush: TFBrush, face_index: int, color: Color) -> void:
	if ctx.closed_compound_of(brush) != null:
		for line: Array in ctx.logical_face_lines([[brush, face_index]]):
			overlay.add_line(line[0], line[1], color)
		return
	var polygon := TFPicking.face_world_polygon(brush, face_index)
	for k in polygon.size():
		overlay.add_line(polygon[k], polygon[(k + 1) % polygon.size()], color)


func _on_motion(camera: Camera3D, event: InputEventMouseMotion) -> bool:
	_mouse_pos = event.position
	match _state:
		State.IDLE:
			_hover = ctx.pick(camera, event.position)
			return false
		State.PRESS:
			if event.position.distance_to(_press_pos) > DRAG_THRESHOLD:
				_begin_drag(camera)
				# Apply this motion right away so fast drags are not lost.
				if _state == State.MOVE:
					_update_move(camera, event.position, event.alt_pressed)
				elif _state == State.RESIZE:
					_update_resize(camera, event.position)
				elif _state == State.EXTRUDE:
					_update_extrude(camera, event.position)
			return true
		State.MOVE:
			_update_move(camera, event.position, event.alt_pressed)
			return true
		State.RESIZE:
			_update_resize(camera, event.position)
			return true
		State.EXTRUDE:
			_update_extrude(camera, event.position)
			return true
		State.INSET:
			_update_inset(camera, event.position)
			return true
	return false


func _on_press(camera: Camera3D, event: InputEventMouseButton) -> void:
	if _state == State.EXTRUDE and _extrude_modal:
		# The release that follows finds the tool idle and does nothing.
		_commit_extrude()
		_state = State.IDLE
		return
	if _state == State.INSET:
		_commit_inset()
		_state = State.IDLE
		return
	if _state != State.IDLE:
		return
	_press_pos = event.position
	_press_hit = ctx.pick(camera, event.position)
	_press_shift = event.shift_pressed
	_press_alt = event.alt_pressed
	_press_ctrl = is_ctrl(event)
	_press_double = event.double_click
	_state = State.PRESS


func _on_release(_camera: Camera3D, _event: InputEventMouseButton) -> void:
	match _state:
		State.PRESS:
			_click_select()
		State.MOVE:
			_commit_move()
		State.RESIZE:
			_commit_resize()
		State.EXTRUDE:
			if _extrude_modal:
				return
			_commit_extrude()
		State.INSET:
			return
	_state = State.IDLE


func _click_select() -> void:
	if _press_hit.is_empty():
		if not _press_shift:
			ctx.clear_selection()
		return
	var brush: TFBrush = _press_hit["brush"]
	if ctx.entered_group != null and (not is_instance_valid(ctx.entered_group) or not ctx.entered_group.is_ancestor_of(brush)):
		ctx.entered_group = null
	if ctx.face_mode:
		# A double click enters the compound and picks the single face.
		var compound := ctx.closed_compound_of(brush)
		if _press_double and not _press_shift and compound != null:
			ctx.enter_group(compound)
			ctx.select_face(brush, _press_hit["face_index"], false)
		else:
			ctx.select_logical_face(brush, _press_hit["face_index"], _press_shift)
		return
	var node := ctx.selectable_for(brush)
	if _press_double and not _press_shift and ctx.is_group(node):
		ctx.enter_group(node)
		node = ctx.selectable_for(brush)
	if _press_shift:
		ctx.toggle_node_selection(node)
	else:
		ctx.select_nodes([node])


func _begin_drag(camera: Camera3D) -> void:
	if _press_hit.is_empty():
		_state = State.IDLE
		return
	var brush: TFBrush = _press_hit["brush"]
	if _press_shift and _press_ctrl:
		if not _begin_extrude(camera, _press_pos, _press_hit, false):
			_state = State.IDLE
		return
	if _press_shift and not ctx.face_mode:
		if not ctx.is_selected(brush):
			ctx.select_nodes([ctx.selectable_for(brush)])
		_begin_resize()
		return
	if not ctx.is_selected(brush):
		ctx.select_nodes([ctx.selectable_for(brush)])
	_begin_move(camera)


# --- move -------------------------------------------------------------------

func _begin_move(camera: Camera3D) -> void:
	_move_brushes = ctx.selected_brushes()
	_move_origins = []
	_move_snapshots = []
	for brush in _move_brushes:
		_move_origins.append(brush.position)
		if ctx.texture_lock:
			_move_snapshots.append(TFUndo.snapshot_faces(brush))
	_move_start = _press_hit["position"]
	_move_delta = Vector3.ZERO
	var forward := -camera.global_basis.z
	if absf(forward.y) < 0.1:
		# Looking horizontally (side ortho view): move in the view plane.
		_move_plane = Plane(TFSnap.dominant_axis(-forward), _move_start)
	else:
		_move_plane = Plane(Vector3.UP, _move_start)
	_state = State.MOVE


func _update_move(camera: Camera3D, screen_pos: Vector2, vertical: bool) -> void:
	var delta: Vector3
	if vertical:
		var t := TFPointPicker.pick_along_axis(camera, screen_pos, _move_start, Vector3.UP, ctx.grid_size())
		delta = Vector3(0.0, t, 0.0)
	else:
		var point: Variant = _move_plane.intersects_ray(camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos))
		if point == null:
			return
		delta = TFSnap.snap((point as Vector3) - _move_start, ctx.grid_size())
		delta[TFSnap.axis_index(_move_plane.normal)] = 0.0
	if delta.is_equal_approx(_move_delta):
		return
	_move_delta = delta
	for i in _move_brushes.size():
		_move_brushes[i].position = _move_origins[i] + _to_parent(_move_brushes[i], delta)
		if not _move_snapshots.is_empty():
			_move_brushes[i].faces = TFBrushOps.translate_texture_lock(_move_snapshots[i], _to_map(delta), _move_brushes[i].get_ppm())


func _commit_move() -> void:
	if _move_delta.is_zero_approx():
		return
	var new_positions: Array = []
	var new_faces: Array = []
	for brush in _move_brushes:
		new_positions.append(brush.position)
		new_faces.append(brush.faces)
	if _move_snapshots.is_empty():
		TFUndo.move_brushes(ctx.undo_redo(), TFI18n.action("Move"), _move_brushes, _move_origins, new_positions)
	else:
		TFUndo.transform_brushes(ctx.undo_redo(), TFI18n.action("Move"), _move_brushes, _move_snapshots, new_faces, _move_origins, new_positions)


# --- resize -----------------------------------------------------------------

func _begin_resize() -> void:
	var hit_brush: TFBrush = _press_hit["brush"]
	_resize_normal = _press_hit["normal"]
	_resize_point = _press_hit["position"]
	_resize_delta = 0.0
	_resize_brushes = []
	_resize_face_indices = []
	_resize_snapshots = []
	_stretch_pipe = _selected_pipe(hit_brush)
	if _stretch_pipe != null:
		_begin_stretch()
		return
	for brush in ctx.selected_brushes():
		var local_normal := brush.global_basis.inverse() * _resize_normal
		var index: int = _press_hit["face_index"] if brush == hit_brush else TFBrushOps.find_face_by_normal(brush.faces, local_normal)
		if index == -1:
			continue
		_resize_brushes.append(brush)
		_resize_face_indices.append(index)
		_resize_snapshots.append(TFUndo.snapshot_faces(brush))
	_state = State.RESIZE if not _resize_brushes.is_empty() else State.IDLE


func _update_resize(camera: Camera3D, screen_pos: Vector2) -> void:
	var delta := TFPointPicker.pick_along_axis(camera, screen_pos, _resize_point, _resize_normal, ctx.grid_size(), true)
	if is_equal_approx(delta, _resize_delta):
		return
	if _stretch_pipe != null:
		_update_stretch(delta)
		return
	var results: Array = []
	for i in _resize_brushes.size():
		var faces := TFBrushOps.resize_face(_resize_snapshots[i], _resize_face_indices[i], delta)
		if faces.is_empty():
			return  # Keep the last valid size.
		results.append(faces)
	_resize_delta = delta
	for i in _resize_brushes.size():
		_resize_brushes[i].faces = results[i]


func _commit_resize() -> void:
	if _stretch_pipe != null:
		_commit_stretch()
		return
	if is_zero_approx(_resize_delta):
		return
	var new_faces: Array = []
	for brush in _resize_brushes:
		new_faces.append(brush.faces)
	TFUndo.commit_many_faces(ctx.undo_redo(), TFI18n.action("Resize"), _resize_brushes, _resize_snapshots, new_faces)


# --- pipe stretch -----------------------------------------------------------

## The selected parametric pipe compound if the hit brush is one of its
## pieces, else null.
func _selected_pipe(hit_brush: TFBrush) -> Node3D:
	var roots := ctx.selected_roots()
	if roots.size() != 1 or roots[0] is TFBrush or hit_brush.get_parent() != roots[0]:
		return null
	return roots[0] if not TFShapeParams.pipe_params(roots[0]).is_empty() else null


## Starts stretching the pipe along the hit face's axis; slanted faces (bends,
## mitres, diagonal sides) have no axis to stretch along.
func _begin_stretch() -> void:
	var local_normal := _stretch_pipe.global_basis.inverse() * _resize_normal
	if not TFSnap.is_axis_aligned(local_normal):
		toast(TFI18n.t("Pipe: Shift+drag a straight face (end cap or axis-aligned side) to stretch it."), EditorToaster.SEVERITY_WARNING)
		_stretch_pipe = null
		_state = State.IDLE
		return
	_stretch_params = TFShapeParams.pipe_params(_stretch_pipe)
	_stretch_axis = TFSnap.dominant_axis(local_normal)
	_stretch_at = _stretch_axis.dot(_stretch_pipe.to_local(_resize_point))
	_stretch_result = {}
	_stretch_outline = []
	for brush in TFShapeParams.group_brushes(_stretch_pipe):
		_resize_brushes.append(brush)
		_resize_snapshots.append(TFUndo.snapshot_faces(brush))
	_state = State.RESIZE


## Previews the stretch: live faces while the piece count stays, else the
## pipe as it was plus the new outline. Keeps the last valid length.
func _update_stretch(delta: float) -> void:
	var local_delta := delta * _stretch_axis.dot(_stretch_pipe.global_basis.inverse() * _resize_normal)
	var result := TFShapeParams.stretch_pipe(_stretch_params, _stretch_axis, _stretch_at, local_delta) if not is_zero_approx(delta) else {}
	if result.is_empty() and not is_zero_approx(delta):
		return
	_resize_delta = delta
	_stretch_result = result
	_stretch_outline = []
	var sets: Array = result.get("sets", [])
	if sets.size() == _resize_brushes.size():
		var origins: Array = []
		for brush in _resize_brushes:
			origins.append(brush.position)
		var faces := TFShapeParams.group_faces(sets, origins, _resize_snapshots)
		for i in _resize_brushes.size():
			_resize_brushes[i].faces = faces[i]
		return
	for i in _resize_brushes.size():
		_resize_brushes[i].faces = TFUndo.copy_faces(_resize_snapshots[i])
	if sets.is_empty():
		return
	var face_sets: Array = []
	var transforms: Array = []
	for planes: Array[Plane] in sets:
		var faces: Array[TFFace] = []
		for plane in planes:
			faces.append(TFFace.create(plane))
		face_sets.append(faces)
		transforms.append(Transform3D.IDENTITY)
	_stretch_outline = TFCompound.compute(face_sets, transforms)["outline"]


## Rebuilds the pipe from the stretched path as one undo action.
func _commit_stretch() -> void:
	var pipe := _stretch_pipe
	_stretch_pipe = null
	_stretch_outline = []
	for i in _resize_brushes.size():
		_resize_brushes[i].faces = TFUndo.copy_faces(_resize_snapshots[i])
	if _stretch_result.is_empty() or is_zero_approx(_resize_delta):
		return
	ctx.rebuild_group_shape(pipe, _stretch_result["sets"], _stretch_result["meta"], TFI18n.action("Stretch Pipe"), UndoRedo.MERGE_DISABLE)


# --- extrude ----------------------------------------------------------------

## Faces to extrude for a pick: the selected faces in face mode (unless the
## cursor is on another face), else the (logical) face under the cursor plus
## the faces with the same normal of the other selected brushes (like
## resize).
func _extrude_targets_for(hit: Dictionary) -> Array:
	if ctx.face_mode:
		var selected := ctx.target_faces()
		if not selected.is_empty() and (hit.is_empty() or ctx.is_face_selected(hit["brush"], hit["face_index"])):
			return selected
	if hit.is_empty():
		return []
	var hit_brush: TFBrush = hit["brush"]
	var result := ctx.logical_face(hit_brush, hit["face_index"])
	if ctx.face_mode or not ctx.is_selected(hit_brush):
		return result
	var compound := ctx.closed_compound_of(hit_brush)
	for brush in ctx.selected_brushes():
		if brush == hit_brush or (compound != null and ctx.closed_compound_of(brush) == compound):
			continue
		var index := TFBrushOps.find_face_by_normal(brush.faces, brush.global_basis.inverse() * (hit["normal"] as Vector3))
		if index != -1:
			result.append([brush, index])
	return result


## Starts extruding; the depth follows the mouse along the normal of the
## picked face (or of the first target). Returns false if nothing to extrude.
func _begin_extrude(camera: Camera3D, screen_pos: Vector2, hit: Dictionary, modal: bool) -> bool:
	var targets := _extrude_targets_for(hit)
	if targets.is_empty():
		return false
	if not hit.is_empty() and targets.has([hit["brush"], hit["face_index"]]):
		_extrude_point = hit["position"]
		_extrude_normal = hit["normal"]
	else:
		var brush: TFBrush = targets[0][0]
		var polygon := TFPicking.face_world_polygon(brush, targets[0][1])
		_extrude_point = Vector3.ZERO
		for p in polygon:
			_extrude_point += p
		_extrude_point /= float(polygon.size())
		_extrude_normal = (brush.global_basis * brush.faces[targets[0][1]].plane.normal).normalized()
	_extrude_start = TFPointPicker.closest_line_parameter(camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos), _extrude_point, _extrude_normal)
	_extrude_targets = targets
	_extrude_results = []
	_extrude_distance = 0.0
	_extrude_modal = modal
	_state = State.EXTRUDE
	return true


func _update_extrude(camera: Camera3D, screen_pos: Vector2) -> void:
	var t := TFPointPicker.closest_line_parameter(camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos), _extrude_point, _extrude_normal) - _extrude_start
	var grid := ctx.grid_size()
	var distance := TFSnap.snap_value(t, grid)
	if TFSnap.is_axis_aligned(_extrude_normal):
		# Snap the cap onto the grid, not the depth (faces off the grid).
		var i := TFSnap.axis_index(_extrude_normal)
		var start := _extrude_point[i]
		distance = (TFSnap.snap_value(start + t * _extrude_normal[i], grid) - start) * _extrude_normal[i]
	if is_equal_approx(distance, _extrude_distance):
		return
	_extrude_distance = distance
	_extrude_results = []
	_push_results = []
	# Pushing in carves the source brush: one face per brush.
	var pushed := {}
	for entry in _extrude_targets:
		var brush: TFBrush = entry[0]
		if distance >= 0.0:
			_extrude_results.append(TFBrushOps.extrude_face(brush.faces, entry[1], distance))
		elif pushed.has(brush):
			_push_results.append(null)
		else:
			pushed[brush] = true
			_push_results.append(TFCSG.push_face(brush.faces, entry[1], -distance, _min_fragment()))


## Adds the previewed prisms as new brushes next to their sources (same
## parent and mode) and selects them, or their caps in face mode so the next
## extrude continues from there. A negative depth pushes the faces in.
func _commit_extrude() -> void:
	if _extrude_distance < 0.0:
		_commit_push()
		return
	var parents: Array = []
	var added: Array[TFBrush] = []
	for i in _extrude_results.size():
		var faces: Array[TFFace] = _extrude_results[i]
		if faces.is_empty():
			continue
		var source: TFBrush = _extrude_targets[i][0]
		var brush := TFBrush.new()
		brush.name = "Brush"
		brush.position = source.position
		brush.mode = source.mode
		brush.faces = faces
		parents.append(source.get_parent())
		added.append(brush)
	_extrude_results = []
	if added.is_empty():
		return
	TFUndo.add_brushes(ctx.undo_redo(), TFI18n.action("Extrude"), parents, added, ctx.scene_root())
	if ctx.face_mode:
		for i in added.size():
			ctx.select_face(added[i], 0, i > 0)
	else:
		ctx.select_brushes(added)


## Replaces the pushed brushes by their fragments (a brush pushed through
## vanishes) and selects them, or the new bottoms in face mode.
func _commit_push() -> void:
	var changed: Array = []
	var new_faces: Array = []
	var parents: Array = []
	var added: Array = []
	var removed: Array = []
	var bottoms: Array = []  # [brush, face_index]
	for i in _push_results.size():
		if _push_results[i] == null:
			continue
		var source: TFBrush = _extrude_targets[i][0]
		var fragments: Array = _push_results[i]
		if fragments.is_empty():
			removed.append(source)
			continue
		var face_plane := TFCSG.normalized(source.faces[_extrude_targets[i][1]].plane)
		var bottom := Plane(face_plane.normal, face_plane.d + _extrude_distance)
		for j in fragments.size():
			var brush := source
			if j == 0:
				changed.append(source)
				new_faces.append(fragments[0])
			else:
				brush = TFUndo.duplicate_brush(source)
				brush.faces = TFUndo.copy_faces(fragments[j])
				parents.append(source.get_parent())
				added.append(brush)
			for k in (fragments[j] as Array).size():
				if TFGeometry.planes_equal(TFCSG.normalized(fragments[j][k].plane), bottom):
					bottoms.append([brush, k])
	_push_results = []
	if changed.is_empty() and removed.is_empty():
		return
	ctx.clear_selection()
	TFUndo.replace_brushes(ctx.undo_redo(), TFI18n.action("Push in"), changed, new_faces, parents, added, removed, ctx.scene_root())
	if ctx.face_mode:
		for i in bottoms.size():
			ctx.select_face(bottoms[i][0], bottoms[i][1], i > 0)
	else:
		var selection: Array[TFBrush] = []
		for brush in changed + added:
			selection.append(brush)
		ctx.select_brushes(selection)


# --- inset ------------------------------------------------------------------

## Starts insetting the extrude targets (one face per brush); the width
## follows the mouse towards the center of the picked face (or the first
## target) in its plane. Returns false if nothing to inset.
func _begin_inset(camera: Camera3D, screen_pos: Vector2, hit: Dictionary) -> bool:
	var candidates := _extrude_targets_for(hit)
	for group in ctx.face_groups(candidates):
		if group.size() > 1:
			toast(TFI18n.t("Inset across several brushes of a logical face is not possible yet (outlook). Enter the compound (double-click) and select a single face."))
			return true
	var targets: Array = []
	var seen := {}
	for entry in candidates:
		if not seen.has(entry[0]):
			seen[entry[0]] = true
			targets.append(entry)
	if targets.is_empty():
		return false
	var reference: Array = targets[0]
	if not hit.is_empty() and targets.has([hit["brush"], hit["face_index"]]):
		reference = [hit["brush"], hit["face_index"]]
	var brush: TFBrush = reference[0]
	var polygon := TFPicking.face_world_polygon(brush, reference[1])
	_inset_center = Vector3.ZERO
	for p in polygon:
		_inset_center += p
	_inset_center /= float(polygon.size())
	_inset_plane = Plane((brush.global_basis * brush.faces[reference[1]].plane.normal).normalized(), _inset_center)
	var start: Variant = _inset_plane.intersects_ray(camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos))
	if start == null:
		return false
	_inset_start = (start as Vector3).distance_to(_inset_center)
	_inset_targets = targets
	_inset_results = []
	_inset_width = 0.0
	_state = State.INSET
	return true


func _update_inset(camera: Camera3D, screen_pos: Vector2) -> void:
	var point: Variant = _inset_plane.intersects_ray(camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos))
	if point == null:
		return
	var width := maxf(0.0, TFSnap.snap_value(_inset_start - (point as Vector3).distance_to(_inset_center), ctx.grid_size()))
	if is_equal_approx(width, _inset_width):
		return
	var results: Array = []
	if width > 0.0:
		for entry in _inset_targets:
			var result := TFCSG.inset((entry[0] as TFBrush).faces, entry[1], width, _min_fragment())
			if result.is_empty():
				return  # Keep the last valid width.
			results.append(result)
	_inset_width = width
	_inset_results = results


## Splits each target brush into its core (the source brush keeps it) and
## the ring brushes, and selects the cores, or their caps in face mode so
## extrude continues from there. Core and ring form a compound (or stay in
## the source's); the core keeps its faces as logical faces of their own.
func _commit_inset() -> void:
	var changed: Array = []
	var new_faces: Array = []
	var parents: Array = []
	var added: Array = []
	var caps: Array[int] = []
	var new_compounds: Array = []
	var meta: Array = []
	for i in _inset_results.size():
		var result: Dictionary = _inset_results[i]
		var source: TFBrush = _inset_targets[i][0]
		changed.append(source)
		new_faces.append(result["core"])
		caps.append(result["core_face"])
		meta.append([source, TFConst.META_OWN_FACES, true])
		var parent := source.get_parent()
		if TFGroups.compound_of(parent) == null:
			parent = TFGroups.new_compound()
			new_compounds.append([parent, source])
		for fragment: Array[TFFace] in result["ring"]:
			var copy := TFUndo.duplicate_brush(source)
			copy.faces = TFUndo.copy_faces(fragment)
			copy.remove_meta(TFConst.META_OWN_FACES)
			parents.append(parent)
			added.append(copy)
	_inset_results = []
	if changed.is_empty():
		return
	ctx.clear_selection()
	TFUndo.replace_brushes(ctx.undo_redo(), TFI18n.action("Inset"), changed, new_faces, parents, added, [], ctx.scene_root(),
		{"new_compounds": new_compounds, "meta": meta})
	if ctx.face_mode:
		for i in changed.size():
			ctx.select_face(changed[i], caps[i], i > 0)
	else:
		var selection: Array[TFBrush] = []
		for brush in changed:
			selection.append(brush)
		ctx.select_brushes(selection)


## Subtract fragments thinner than this are dropped (as in CSG actions).
func _min_fragment() -> float:
	return ctx.grid_size() * TFConst.MIN_FRAGMENT_GRID_FRACTION


# --- keyboard ---------------------------------------------------------------

func _on_key(camera: Camera3D, event: InputEventKey) -> bool:
	if _state != State.IDLE:
		if TFShortcuts.matches("cancel", event):
			cancel()
			return true
		return false
	if TFShortcuts.matches("cancel", event) and ctx.entered_group != null:
		ctx.exit_group()
		return true
	# Without a face to extrude, E stays Godot's rotate mode.
	if not event.echo and TFShortcuts.matches("extrude", event):
		return _begin_extrude(camera, _mouse_pos, ctx.pick(camera, _mouse_pos), true)
	if not event.echo and TFShortcuts.matches("inset", event):
		return _begin_inset(camera, _mouse_pos, ctx.pick(camera, _mouse_pos))
	if not event.echo and TFShortcuts.matches("bevel", event):
		ctx.bevel.begin_selection(camera, _mouse_pos)
		return true
	var selection := ctx.selected_brushes()
	if selection.is_empty():
		return false
	var grid := ctx.grid_size()
	var direction := nudge_direction_for(camera, event)
	if direction != Vector3.ZERO:
		_nudge(selection, direction * grid)
		return true
	if event.echo:
		return false
	if TFShortcuts.matches("duplicate", event):
		_duplicate(TFSnap.dominant_horizontal_axis(camera.global_basis.x) * grid)
		return true
	if TFShortcuts.matches("delete", event):
		var roots := ctx.selected_roots()
		ctx.clear_selection()
		TFUndo.remove_brushes(ctx.undo_redo(), TFI18n.action("Delete"), roots)
		return true
	if TFShortcuts.matches("rotate_cw", event) or TFShortcuts.matches("rotate_ccw", event):
		_rotate(selection, -PI * 0.5 if TFShortcuts.matches("rotate_ccw", event) else PI * 0.5)
		return true
	return false


func _nudge(selection: Array[TFBrush], delta: Vector3) -> void:
	var old_positions: Array = []
	var new_positions: Array = []
	var old_faces: Array = []
	var new_faces: Array = []
	for brush in selection:
		old_positions.append(brush.position)
		new_positions.append(brush.position + _to_parent(brush, delta))
		old_faces.append(TFUndo.snapshot_faces(brush))
		new_faces.append(TFBrushOps.translate_texture_lock(brush.faces, _to_map(delta), brush.get_ppm()))
	if ctx.texture_lock:
		TFUndo.transform_brushes(ctx.undo_redo(), TFI18n.action("Nudge"), selection, old_faces, new_faces, old_positions, new_positions)
	else:
		TFUndo.move_brushes(ctx.undo_redo(), TFI18n.action("Nudge"), selection, old_positions, new_positions)


## Duplicates the selected brushes and groups (groups as a whole).
func _duplicate(offset: Vector3) -> void:
	var parents: Array = []
	var copies: Array = []
	var ppm := float(ctx.map.get_ppm())
	for node in ctx.selected_roots():
		var copy := TFGroups.duplicate_node(node) as Node3D
		copy.position += _to_parent(node, offset)
		if ctx.texture_lock:
			for brush in TFGroups.brushes_of(copy):
				brush.faces = TFBrushOps.translate_texture_lock(brush.faces, _to_map(offset), ppm)
		parents.append(node.get_parent())
		copies.append(copy)
	TFUndo.add_brushes(ctx.undo_redo(), TFI18n.action("Duplicate"), parents, copies, ctx.scene_root())
	ctx.select_nodes(copies)


func _rotate(selection: Array[TFBrush], angle: float) -> void:
	var rotation := Basis(Vector3.UP, angle)
	var pivot_world := TFSnap.snap(TFPicking.brushes_aabb(selection).get_center(), ctx.grid_size())
	var old_faces: Array = []
	var new_faces: Array = []
	var old_positions: Array = []
	var new_positions: Array = []
	for brush in selection:
		var parent := brush.get_parent() as Node3D
		var pivot := parent.global_transform.affine_inverse() * pivot_world if parent != null else pivot_world
		var map_offset := brush.get_map_offset() - brush.position
		var result := TFBrushOps.rotate_brush(brush.faces, brush.position, pivot, rotation, ctx.texture_lock, map_offset, brush.get_ppm())
		old_faces.append(TFUndo.snapshot_faces(brush))
		new_faces.append(result[0])
		old_positions.append(brush.position)
		new_positions.append(result[1])
	TFUndo.transform_brushes(ctx.undo_redo(), TFI18n.action("Rotate"), selection, old_faces, new_faces, old_positions, new_positions)


## Converts a world-space offset into map space.
func _to_map(world_delta: Vector3) -> Vector3:
	if ctx.map == null:
		return world_delta
	return ctx.map.global_basis.inverse() * world_delta


## Converts a world-space offset into the node parent's space.
func _to_parent(node: Node, world_delta: Vector3) -> Vector3:
	var parent := node.get_parent() as Node3D
	if parent == null:
		return world_delta
	return parent.global_basis.inverse() * world_delta
