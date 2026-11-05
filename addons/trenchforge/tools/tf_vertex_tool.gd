@tool
class_name TFVertexTool
extends TFTool
## Vertex edit (V): drags vertices, edge midpoints (Shift+V) or face centers
## (Ctrl+Shift+V) of the selected brushes; Ctrl+Shift+B bevels the selected
## edges or vertices (TFBevelOperation). Each brush is rebuilt as the convex
## hull of its moved vertices (TFBrushOps.move_vertices), so it stays convex.
## In edge mode a double-click (or L) on an edge selects its edge loop.
##
## Handles are world positions; brushes with a vertex at the same position
## move together. With "linked" on, unselected brushes sharing a moved vertex
## move along too, so neighbours stay sealed.

enum Mode { VERTEX, EDGE, FACE }
enum State { IDLE, PRESS, DRAG, BOX }

## Names per Mode (English, translated when shown).
const MODE_NAMES: Array[String] = ["Vertices", "Edges", "Faces"]

## Pick radius around a handle (px, before editor scale).
const HANDLE_RADIUS: float = 8.0
const COLOR_HANDLE := Color(0.9, 0.9, 0.9, 1.0)
const COLOR_EDGE := Color(0.35, 0.8, 1.0, 0.8)
const COLOR_INVALID := Color(1.0, 0.1, 0.1, 1.0)
const COLOR_BOX := Color(0.35, 0.8, 1.0, 0.25)

var mode := Mode.VERTEX:
	set(value):
		if mode != value:
			cancel()
			_selected.clear()
		mode = value
var linked := true

var _state := State.IDLE
## Each handle: {position: Vector3, points: PackedVector3Array (world
## positions of the vertices it moves)}.
var _handles: Array = []
## World positions of the selected handles.
var _selected := PackedVector3Array()
var _hover := -1
var _press_pos := Vector2.ZERO
var _press_handle := -1
var _press_was_selected := false
var _press_hit: Dictionary = {}
var _press_shift := false
var _mouse := Vector2.ZERO

# Drag state: one entry per affected brush, {brush, snapshot, positions
# (brush-local vertices to move)}.
var _entries: Array = []
var _drag_start := Vector3.ZERO
var _drag_plane := Plane(Vector3.UP, 0.0)
var _delta := Vector3.ZERO
var _lost := 0
var _rejected := false


func get_tool_name() -> String:
	return "vertex"


func cancel() -> void:
	ctx.bevel.cancel()
	if _state == State.DRAG:
		_restore()
	_entries = []
	_state = State.IDLE


## Clears the selected handles first; with none selected, the brushes.
func deselect() -> void:
	if _selected.is_empty():
		ctx.clear_selection()
	else:
		_selected.clear()


func is_busy() -> bool:
	return ctx.bevel.is_active() or _state == State.DRAG


func wants_all_input() -> bool:
	return ctx.bevel.is_active()


func get_cursor_label() -> String:
	return ctx.bevel.get_cursor_label() if ctx.bevel.is_active() else ""


func get_hint() -> String:
	if ctx.bevel.is_active():
		return ctx.bevel.get_hint()
	match _state:
		State.DRAG:
			return TFI18n.t("Drag: move · Alt: vertical · %s: cancel") % keys("cancel")
		State.BOX:
			return TFI18n.t("Drag a box · Shift: add")
	if ctx.selected_brushes().is_empty():
		return TFI18n.t("LMB: select brush · %s: Select") % keys("cancel")
	if mode == Mode.EDGE:
		return TFI18n.t("LMB: select/drag · Shift: add · double-click / %s: edge loop · drag a box · Alt: vertical · %s: bevel · %s / %s / %s: mode · %s: Select") % [
			keys("select_loop"), keys("bevel"), keys("tool_vertex"), keys("tool_edge"), keys("tool_vertex_face"), keys("cancel")]
	return TFI18n.t("LMB: select/drag · Shift: add · drag a box · Alt: vertical · Arrows/PgUp/PgDn: 1 grid step · %s: bevel · %s / %s / %s: mode · %s: Select") % [
		keys("bevel"), keys("tool_vertex"), keys("tool_edge"), keys("tool_vertex_face"), keys("cancel")]


func get_info() -> String:
	if ctx.bevel.is_active():
		return ctx.bevel.get_info()
	if _state == State.DRAG:
		var text := "Δ %s, %s, %s m" % [format_length(_delta.x), format_length(_delta.y), format_length(_delta.z)]
		if _rejected:
			text += TFI18n.t(" · Invalid shape – last valid position")
		elif _lost > 0:
			text += TFI18n.t(" · %d vertex/vertices disappear (inside the brush)") % _lost
		return text
	return TFI18n.t("%s · %d selected · %d brush(es) · Linked %s") % [TFI18n.t(MODE_NAMES[mode]), _selected.size(), ctx.selected_brushes().size(), TFI18n.t("on") if linked else TFI18n.t("off")]


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
	_refresh_handles(_state != State.DRAG)
	if ctx.bevel.is_active():
		for brush in ctx.selected_brushes():
			overlay.add_brush_edges(brush, COLOR_EDGE)
		ctx.bevel.draw_3d(overlay)
		return
	var selected := _selected_now()
	for brush in ctx.selected_brushes():
		overlay.add_brush_edges(brush, COLOR_EDGE)
	for entry in _entries:
		if not ctx.is_selected(entry["brush"]):
			overlay.add_brush_edges(entry["brush"], TFEditorContext.COLOR_HOVER)
	for i in _handles.size():
		var handle: Dictionary = _handles[i]
		var is_selected := TFHull.find_point(selected, handle["position"]) != -1
		var color := COLOR_HANDLE
		if is_selected:
			color = COLOR_INVALID if _state == State.DRAG and (_lost > 0 or _rejected) else TFEditorContext.COLOR_SELECTED
		elif i == _hover and _state == State.IDLE:
			color = TFEditorContext.COLOR_HOVER
		overlay.add_point(handle["position"], color)
		if is_selected or (i == _hover and _state == State.IDLE):
			_draw_handle_shape(overlay, handle, color)


func draw_2d(overlay: Control) -> void:
	if _state != State.BOX:
		return
	var rect := Rect2(_press_pos, Vector2.ZERO).expand(_mouse)
	overlay.draw_rect(rect, COLOR_BOX)
	overlay.draw_rect(rect, TFEditorContext.COLOR_CURSOR, false, 1.0)


func get_grid_anchor() -> Dictionary:
	if _state == State.DRAG:
		return {"point": _drag_start + _delta, "normal": _drag_plane.normal}
	return {}


# --- mouse ------------------------------------------------------------------

func _on_motion(camera: Camera3D, event: InputEventMouseMotion) -> bool:
	_mouse = event.position
	match _state:
		State.IDLE:
			_refresh_handles()
			_hover = _handle_at(camera, event.position)
			return false
		State.PRESS:
			if event.position.distance_to(_press_pos) > DRAG_THRESHOLD:
				if _press_handle != -1:
					_begin_drag(camera)
					_update_drag(camera, event.position, event.alt_pressed)
				else:
					_state = State.BOX
			return true
		State.DRAG:
			_update_drag(camera, event.position, event.alt_pressed)
			return true
		State.BOX:
			return true
	return false


func _on_press(camera: Camera3D, event: InputEventMouseButton) -> void:
	if _state != State.IDLE:
		return
	_refresh_handles()
	_press_pos = event.position
	_mouse = event.position
	_press_shift = event.shift_pressed
	_press_handle = _handle_at(camera, event.position)
	if event.double_click and mode == Mode.EDGE and _press_handle != -1:
		_select_loop(camera, _press_handle, _press_shift)
		return
	_press_hit = ctx.pick(camera, event.position) if _press_handle == -1 else {}
	_press_was_selected = false
	if _press_handle != -1:
		var position: Vector3 = _handles[_press_handle]["position"]
		_press_was_selected = TFHull.find_point(_selected, position) != -1
		# Pressing an unselected handle selects it right away, so it can be
		# dragged in the same gesture.
		if not _press_was_selected:
			if not _press_shift:
				_selected.clear()
			_selected.append(position)
	_state = State.PRESS


func _on_release(camera: Camera3D, _event: InputEventMouseButton) -> void:
	match _state:
		State.PRESS:
			_click()
		State.DRAG:
			_commit()
		State.BOX:
			_box_select(camera)
	_state = State.IDLE


func _click() -> void:
	if _press_handle != -1:
		var position: Vector3 = _handles[_press_handle]["position"]
		if _press_shift:
			# A shift-click on a handle that was already selected deselects it.
			if _press_was_selected:
				_selected.remove_at(TFHull.find_point(_selected, position))
		else:
			_selected = PackedVector3Array([position])
		return
	if _press_hit.is_empty():
		if not _press_shift:
			_selected.clear()
		return
	var brush: TFBrush = _press_hit["brush"]
	if _press_shift:
		ctx.toggle_node_selection(brush)
	elif not ctx.is_selected(brush):
		var list: Array[TFBrush] = [brush]
		ctx.select_brushes(list)
		_selected.clear()


func _box_select(camera: Camera3D) -> void:
	var rect := Rect2(_press_pos, Vector2.ZERO).expand(_mouse)
	if not _press_shift:
		_selected.clear()
	for handle in _handles:
		var position: Vector3 = handle["position"]
		if camera.is_position_behind(position) or not rect.has_point(camera.unproject_position(position)):
			continue
		if TFHull.find_point(_selected, position) == -1:
			_selected.append(position)


# --- drag -------------------------------------------------------------------

func _begin_drag(camera: Camera3D) -> void:
	_drag_start = _handles[_press_handle]["position"]
	_drag_plane = Plane(TFSnap.dominant_axis(-camera.global_basis.z), _drag_start)
	_begin_entries()
	_state = State.DRAG if not _entries.is_empty() else State.IDLE


## Collects the brushes affected by moving the selected handles.
func _begin_entries() -> void:
	_entries = []
	_delta = Vector3.ZERO
	_lost = 0
	_rejected = false
	var moved := _moved_points()
	if moved.is_empty():
		return
	var candidates: Array[TFBrush] = ctx.selected_brushes()
	if linked:
		var moved_box := AABB(moved[0], Vector3.ZERO)
		for p in moved:
			moved_box = moved_box.expand(p)
		for brush in ctx.brushes_in_box(moved_box):
			if not candidates.has(brush) and brush.is_visible_in_tree():
				candidates.append(brush)
	for brush in candidates:
		if not brush.is_valid():
			continue
		var positions := PackedVector3Array()
		for v in brush.get_polyhedron().vertices:
			if TFHull.find_point(moved, brush.global_transform * v) != -1:
				positions.append(v)
		if positions.is_empty():
			continue
		_entries.append({
			"brush": brush,
			"snapshot": TFUndo.snapshot_faces(brush),
			"positions": positions,
			"inverse_basis": brush.global_basis.inverse(),
		})


func _update_drag(camera: Camera3D, screen_pos: Vector2, vertical: bool) -> void:
	var delta: Vector3
	if vertical:
		delta = Vector3(0.0, TFPointPicker.pick_along_axis(camera, screen_pos, _drag_start, Vector3.UP, ctx.grid_size(), true), 0.0)
	else:
		var point: Variant = _drag_plane.intersects_ray(camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos))
		if point == null:
			return
		var axis := TFSnap.dominant_axis(_drag_plane.normal)
		delta = TFSnap.snap_in_plane(point, axis, ctx.grid_size()) - _drag_start
		delta[TFSnap.axis_index(axis)] = 0.0
	if delta.is_equal_approx(_delta):
		return
	_apply(delta)


## Previews the entries moved by delta; keeps the last valid state if any
## brush would become invalid.
func _apply(delta: Vector3) -> bool:
	if delta.is_zero_approx():
		_restore()
		_delta = Vector3.ZERO
		_lost = 0
		_rejected = false
		return true
	var results: Array = []
	var lost := 0
	for entry in _entries:
		var result := TFBrushOps.move_vertices(entry["snapshot"], entry["positions"], entry["inverse_basis"] * delta)
		if result.is_empty():
			_rejected = true
			return false
		results.append(result["faces"])
		lost += result["lost"]
	for i in _entries.size():
		_entries[i]["brush"].faces = results[i]
	_delta = delta
	_lost = lost
	_rejected = false
	return true


func _restore() -> void:
	for entry in _entries:
		if is_instance_valid(entry["brush"]):
			entry["brush"].faces = TFUndo.copy_faces(entry["snapshot"])


func _commit() -> void:
	if _delta.is_zero_approx():
		_entries = []
		return
	var brushes: Array = []
	var old_faces: Array = []
	var new_faces: Array = []
	for entry in _entries:
		brushes.append(entry["brush"])
		old_faces.append(entry["snapshot"])
		new_faces.append(entry["brush"].faces)
	TFUndo.commit_many_faces(ctx.undo_redo(), TFI18n.action("Move %s") % TFI18n.t(MODE_NAMES[mode]), brushes, old_faces, new_faces)
	var moved := PackedVector3Array()
	for p in _selected:
		moved.append(p + _delta)
	_selected = moved
	_entries = []
	_refresh_handles()


# --- keyboard ---------------------------------------------------------------

func _on_key(camera: Camera3D, event: InputEventKey) -> bool:
	if TFShortcuts.matches("cancel", event):
		if _state == State.IDLE:
			ctx.request_tool("select")
		else:
			cancel()
		return true
	if _state != State.IDLE:
		return false
	if not event.echo and TFShortcuts.matches("bevel", event):
		_begin_bevel(camera)
		return true
	if not event.echo and mode == Mode.EDGE and TFShortcuts.matches("select_loop", event):
		_refresh_handles()
		var index := _handle_at(camera, _mouse)
		if index != -1:
			_select_loop(camera, index, true)
		return true
	var direction := nudge_direction_for(camera, event)
	if direction == Vector3.ZERO:
		return false
	_refresh_handles()
	if _selected.is_empty():
		return true
	_begin_entries()
	if not _entries.is_empty() and _apply(direction * ctx.grid_size()):
		_commit()
	else:
		_restore()
		_entries = []
	return true


# --- bevel ------------------------------------------------------------------

## Bevels the selected edges (edge mode) or vertices (vertex mode).
func _begin_bevel(camera: Camera3D) -> void:
	_refresh_handles()
	if mode == Mode.FACE:
		toast(TFI18n.t("Bevel works on edges and vertices: switch to edge (%s) or vertex mode (%s), or bevel faces in the Select tool's face mode.") % [keys("tool_edge"), keys("tool_vertex")])
		return
	var edges: Array = []
	var vertices := PackedVector3Array()
	for p in _selected:
		var index := _find_handle(p)
		if index == -1:
			continue
		var points: PackedVector3Array = _handles[index]["points"]
		if mode == Mode.EDGE and points.size() >= 2:
			edges.append([points[0], points[1]])
		elif mode == Mode.VERTEX:
			vertices.append(p)
	var kind := TFBevelOperation.Kind.VERTICES if mode == Mode.VERTEX else TFBevelOperation.Kind.EDGES
	ctx.bevel.begin_points(camera, _mouse, kind, edges, vertices)


## The selected edges as world-space [a, b] pairs (edge mode; bridge).
func selected_edges() -> Array:
	_refresh_handles()
	var edges: Array = []
	if mode != Mode.EDGE:
		return edges
	for p in _selected:
		var index := _find_handle(p)
		if index == -1:
			continue
		var points: PackedVector3Array = _handles[index]["points"]
		if points.size() >= 2:
			edges.append([points[0], points[1]])
	return edges


# --- edge loop --------------------------------------------------------------

## Selects the edge loop through an edge handle: a boundary loop of a logical
## face along that edge (TFCompound.edge_loops(); in a compound across its
## members, entered or not). Loops of convex edges win, so a rim around a
## recess beats the recess walls; ties go to the face under the cursor.
## Brushes with whole edges on the loop join the brush selection; loop parts
## that are no whole brush edge (pieces of longer edges) are reported.
func _select_loop(camera: Camera3D, index: int, add: bool) -> void:
	var points: PackedVector3Array = _handles[index]["points"]
	var brush := _brush_with_edge(points)
	if brush == null:
		return
	var to_map := ctx.map.global_transform.affine_inverse()
	var compound := TFGroups.compound_of(brush.get_parent())
	var data: Dictionary
	var members: Array
	if compound != null:
		data = ctx.compound_data(compound)
		members = data["members"]
	else:
		data = TFCompound.compute([brush.faces], [to_map * brush.global_transform], [brush.get_polyhedron()])
		members = [brush]
	var loops := TFCompound.edge_loops(data, to_map * points[0], to_map * points[1])
	if loops.is_empty():
		toast(TFI18n.t("No edge loop through this edge."))
		return
	var loop: PackedVector3Array = ctx.map.global_transform * (_preferred_loop(camera, loops, data, members)["loop"] as PackedVector3Array)

	# Whole brush edges on the loop, and how much of each loop edge they cover.
	var midpoints := PackedVector3Array()
	var owners: Array[TFBrush] = []
	var covered := PackedFloat64Array()
	covered.resize(loop.size())
	for member: TFBrush in members:
		if member.is_editor_hidden() or not member.is_valid():
			continue
		var poly := member.get_polyhedron()
		var xf := member.global_transform
		for edge in poly.edges:
			var a := xf * poly.vertices[edge.x]
			var b := xf * poly.vertices[edge.y]
			for k in loop.size():
				var p := loop[k]
				var q := loop[(k + 1) % loop.size()]
				if not TFCompound.on_segment(a, p, q) or not TFCompound.on_segment(b, p, q):
					continue
				if TFHull.find_point(midpoints, (a + b) * 0.5) == -1:
					midpoints.append((a + b) * 0.5)
					covered[k] += a.distance_to(b)
				if not owners.has(member):
					owners.append(member)
				break
	var missing := 0
	for k in loop.size():
		if covered[k] < loop[k].distance_to(loop[(k + 1) % loop.size()]) - TFConst.EPSILON:
			missing += 1

	var selection := ctx.selected_brushes()
	if owners.any(func(owner: TFBrush) -> bool: return not selection.has(owner)):
		for owner in owners:
			if not selection.has(owner):
				selection.append(owner)
		ctx.select_brushes(selection)
	_refresh_handles(false)
	if not add:
		_selected.clear()
	for p in midpoints:
		if _find_handle(p) != -1 and TFHull.find_point(_selected, p) == -1:
			_selected.append(p)
	if missing > 0:
		toast(TFI18n.t("%d edge(s) of the loop are only parts of longer brush edges and were skipped.") % missing)


# Loop with the fewest concave edges; among equals the one of the region
# under the cursor, else the first.
func _preferred_loop(camera: Camera3D, loops: Array, data: Dictionary, members: Array) -> Dictionary:
	var best: Array = loops.filter(func(entry: Dictionary) -> bool: return entry["concave"] == loops[0]["concave"])
	var hit := ctx.pick(camera, _mouse)
	if best.size() > 1 and not hit.is_empty():
		var regions: Array = data["face_regions"].get(Vector2i(members.find(hit["brush"]), hit["face_index"]), [])
		for entry: Dictionary in best:
			if regions.has(entry["region"]):
				return entry
	return best[0]


# A selected brush with the edge between the first two points (world), or null.
func _brush_with_edge(points: PackedVector3Array) -> TFBrush:
	if points.size() < 2:
		return null
	for brush in ctx.selected_brushes():
		var poly := brush.get_polyhedron()
		var xf := brush.global_transform
		for edge in poly.edges:
			var ends := PackedVector3Array([xf * poly.vertices[edge.x], xf * poly.vertices[edge.y]])
			if TFHull.find_point(ends, points[0]) != -1 and TFHull.find_point(ends, points[1]) != -1:
				return brush
	return null


# --- handles ----------------------------------------------------------------

## Rebuilds the handles of the selected brushes. With prune, selected
## positions that no longer exist (e.g. after undo) are dropped.
func _refresh_handles(prune: bool = true) -> void:
	_handles = []
	for brush in ctx.selected_brushes():
		if not brush.is_valid():
			continue
		var poly := brush.get_polyhedron()
		var xf := brush.global_transform
		match mode:
			Mode.VERTEX:
				for v in poly.vertices:
					_add_handle(xf * v, PackedVector3Array([xf * v]))
			Mode.EDGE:
				for edge in poly.edges:
					var a := xf * poly.vertices[edge.x]
					var b := xf * poly.vertices[edge.y]
					_add_handle((a + b) * 0.5, PackedVector3Array([a, b]))
			Mode.FACE:
				for i in poly.face_polygons.size():
					if not poly.is_face_used(i):
						continue
					var points := PackedVector3Array()
					var center := Vector3.ZERO
					for v in poly.get_face_vertices(i):
						points.append(xf * v)
						center += xf * v
					_add_handle(center / float(points.size()), points)
	if prune:
		var kept := PackedVector3Array()
		for p in _selected:
			if _find_handle(p) != -1:
				kept.append(p)
		_selected = kept
	if _hover >= _handles.size():
		_hover = -1


func _add_handle(position: Vector3, points: PackedVector3Array) -> void:
	var index := _find_handle(position)
	if index == -1:
		_handles.append({"position": position, "points": points})
		return
	var merged: PackedVector3Array = _handles[index]["points"]
	for p in points:
		if TFHull.find_point(merged, p) == -1:
			merged.append(p)
	_handles[index]["points"] = merged


func _find_handle(position: Vector3) -> int:
	for i in _handles.size():
		if (_handles[i]["position"] as Vector3).distance_squared_to(position) <= TFConst.EPSILON * TFConst.EPSILON:
			return i
	return -1


## Handle nearest to the cursor within the pick radius (ties: nearest to the
## camera), or -1.
func _handle_at(camera: Camera3D, screen_pos: Vector2) -> int:
	var radius := HANDLE_RADIUS * EditorInterface.get_editor_scale()
	var best := -1
	var best_score := INF
	for i in _handles.size():
		var position: Vector3 = _handles[i]["position"]
		if camera.is_position_behind(position):
			continue
		var distance := camera.unproject_position(position).distance_to(screen_pos)
		if distance > radius:
			continue
		var score := distance + camera.global_position.distance_to(position) * 1e-3
		if score < best_score:
			best_score = score
			best = i
	return best


## World vertex positions moved by the selected handles.
func _moved_points() -> PackedVector3Array:
	var result := PackedVector3Array()
	for p in _selected:
		var index := _find_handle(p)
		if index == -1:
			continue
		for point in _handles[index]["points"]:
			if TFHull.find_point(result, point) == -1:
				result.append(point)
	return result


## Selected handle positions, shifted by the live drag delta.
func _selected_now() -> PackedVector3Array:
	var result := PackedVector3Array()
	for p in _selected:
		result.append(p + _delta if _state == State.DRAG else p)
	return result


func _draw_handle_shape(overlay: TFOverlay3D, handle: Dictionary, color: Color) -> void:
	var points: PackedVector3Array = handle["points"]
	match mode:
		Mode.EDGE:
			if points.size() >= 2:
				overlay.add_line(points[0], points[1], color)
		Mode.FACE:
			var fill := color
			fill.a = 0.3
			overlay.add_polygon(points, fill)
