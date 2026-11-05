@tool
class_name TFBevelOperation
extends RefCounted
## Modal bevel (Ctrl+Shift+B), shared by the select tool (edges of the
## selected brushes from the angle limit, or the boundary edges of the
## selected faces) and the vertex tool (selected edges or vertices).
##
## The width follows the mouse distance from the targets' center on screen,
## the wheel or +/- change the segments, P switches the mouse to the profile,
## C toggles clamping, K the corners. The preview is drawn in the overlay;
## LMB/Enter commits one undo action, RMB/Esc cancels. Afterwards
## adjust_last() recomputes the last bevel from its source faces with new
## parameters and replaces its result in the same undo action (panel).
##
## In a closed compound only outline edges whose two faces are visible there
## are bevelled; seams between members and concave outline edges are skipped.

## The last bevel was committed (the adjust panel can show).
signal committed

enum Kind { EDGES, VERTICES }

const COLOR_CLAMPED := Color(1.0, 0.6, 0.15, 1.0)
const COLOR_REJECTED := Color(1.0, 0.15, 0.1, 1.0)
## Without Ctrl the width snaps to this fraction of the grid.
const WIDTH_SNAP_FRACTION: float = 0.125
## Without Ctrl the profile snaps to this step.
const PROFILE_STEP: float = 0.05
## Mouse pixels for a profile change of 1.
const PROFILE_PIXELS: float = 400.0
## Points closer than this (m) to an outline segment lie on it.
const OUTLINE_TOLERANCE: float = 1e-3

var ctx: TFEditorContext
## Current parameters: TFBevel parameters plus "angle" (brush mode limit).
var params := {}

var _active := false
var _kind := Kind.EDGES
## Per brush: {brush, faces (snapshot), items (edges [a, b] or vertices,
## brush-local), candidates (brush mode: [a, b, angle] of all bevelable
## edges, items follow the angle limit)}.
var _targets: Array = []
var _results: Array = []  # TFBevel result per target ({} if invalid)
var _computed := {}  # params of _results
var _skipped := 0
var _by_angle := false
var _pivot := Vector3.ZERO
var _scale := 0.01  # world meters per screen pixel at the pivot
var _width_origin := 0.0  # mouse distance of width 0
var _profile_mode := false
var _profile_origin := 0.0  # mouse distance where the profile mode began
var _profile_start := 0.5
var _distance := 0.0
## Last commit for adjust_last(): {kind, targets, by_angle, brushes,
## applied (face arrays of the undo action), params, version, history}.
var _last := {}


func _init(p_ctx: TFEditorContext) -> void:
	ctx = p_ctx


func is_active() -> bool:
	return _active


# --- start -------------------------------------------------------------------------

## Starts bevelling the select tool's targets: the boundary edges of the
## selected faces in face mode, else all edges of the selected brushes from
## the angle limit. Returns false (with a toast) if there is nothing to bevel.
func begin_selection(camera: Camera3D, mouse: Vector2) -> bool:
	var targets: Array = []
	var skipped := 0
	if ctx.face_mode:
		var by_brush := {}
		for entry in ctx.target_faces():
			if not by_brush.has(entry[0]):
				by_brush[entry[0]] = []
			by_brush[entry[0]].append(entry[1])
		for brush: TFBrush in by_brush:
			var boundary := TFBevel.boundary_edges(brush.get_polyhedron(), by_brush[brush])
			var candidates := _candidates(brush, boundary)
			var items: Array = []
			for candidate: Array in candidates:
				if candidate[3]:
					items.append([candidate[0], candidate[1]])
				else:
					skipped += 1
			if not items.is_empty():
				targets.append({"brush": brush, "faces": TFUndo.snapshot_faces(brush), "items": items})
	else:
		for brush in ctx.selected_brushes():
			if not brush.is_valid():
				continue
			targets.append({"brush": brush, "faces": TFUndo.snapshot_faces(brush), "candidates": _candidates(brush, []), "items": []})
	return _begin(camera, mouse, Kind.EDGES, targets, skipped, not ctx.face_mode)


## Starts bevelling in the vertex tool: the edges (pairs of world points) or
## vertices (world points) of the selected brushes at the given positions.
func begin_points(camera: Camera3D, mouse: Vector2, kind: Kind, edges: Array, vertices: PackedVector3Array) -> bool:
	var targets: Array = []
	for brush in ctx.selected_brushes():
		if not brush.is_valid():
			continue
		var poly := brush.get_polyhedron()
		var to_local := brush.global_transform.affine_inverse()
		var items: Array = []
		if kind == Kind.VERTICES:
			for point in vertices:
				var local := to_local * point
				if TFHull.find_point(poly.vertices, local) != -1:
					items.append(local)
		else:
			for edge in poly.edges:
				var a := poly.vertices[edge.x]
				var b := poly.vertices[edge.y]
				for pair: Array in edges:
					if _same_edge(to_local * (pair[0] as Vector3), to_local * (pair[1] as Vector3), a, b):
						items.append([a, b])
						break
		if not items.is_empty():
			targets.append({"brush": brush, "faces": TFUndo.snapshot_faces(brush), "items": items})
	return _begin(camera, mouse, kind, targets, 0, false)


func _begin(camera: Camera3D, mouse: Vector2, kind: Kind, targets: Array, skipped: int, by_angle: bool) -> bool:
	cancel()
	_kind = kind
	_targets = targets
	_skipped = skipped
	_by_angle = by_angle
	params = TFEditorSettings.bevel_defaults()
	params["width"] = 0.0
	if by_angle:
		_skipped = _apply_angle(_targets, params["angle"])
	if _item_count() == 0:
		_targets = []
		TFTool.toast(TFI18n.t("Nothing to bevel: select brushes, faces, edges or vertices.") if _skipped == 0 else
			TFI18n.t("Nothing to bevel: %d edge(s) skipped (across brushes or concave).") % _skipped)
		return false
	_pivot = _center()
	var center := camera.unproject_position(_pivot)
	_distance = mouse.distance_to(center)
	_width_origin = _distance
	var depth := maxf((_pivot - camera.global_position).dot(-camera.global_basis.z), camera.near + 0.01)
	_scale = camera.project_position(center, depth).distance_to(camera.project_position(center + Vector2(1, 0), depth))
	_profile_mode = false
	_results = []
	_computed = {}
	_active = true
	_refresh()
	return true


# --- modal input ------------------------------------------------------------------

## Handles every viewport event while active (mouse wheel, RMB included).
func handle_input(camera: Camera3D, event: InputEvent) -> bool:
	if not _active:
		return false
	if event is InputEventMouseMotion:
		_on_mouse(camera, event.position, TFTool.is_ctrl(event))
		return true
	if event is InputEventMouseButton:
		if not event.pressed:
			return event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_step_segments(1)
				return true
			MOUSE_BUTTON_WHEEL_DOWN:
				_step_segments(-1)
				return true
			MOUSE_BUTTON_LEFT:
				commit()
				return true
			MOUSE_BUTTON_RIGHT:
				cancel()
				return true
		return false
	if event is InputEventKey and event.pressed:
		if TFShortcuts.matches("cancel", event):
			cancel()
			return true
		match TFShortcuts.find_action("bevel", event):
			"bevel_confirm":
				commit()
			"bevel_more":
				_step_segments(1)
			"bevel_less":
				_step_segments(-1)
			"bevel_profile":
				if not event.echo:
					_toggle_profile_mode()
			"bevel_clamp":
				if not event.echo:
					params["clamp"] = not params["clamp"]
			"bevel_corners":
				if not event.echo:
					params["corners"] = TFBevel.Corners.CUT if params["corners"] == TFBevel.Corners.PATCH else TFBevel.Corners.PATCH
			_:
				return false
		_refresh()
		return true
	return false


func _on_mouse(camera: Camera3D, mouse: Vector2, free: bool) -> void:
	_distance = mouse.distance_to(camera.unproject_position(_pivot))
	if _profile_mode:
		var profile := _profile_start + (_distance - _profile_origin) / PROFILE_PIXELS
		if not free:
			profile = snappedf(profile, PROFILE_STEP)
		params["profile"] = clampf(profile, TFConst.BEVEL_MIN_PROFILE, 1.0)
	else:
		var width := maxf(0.0, (_distance - _width_origin) * _scale)
		if not free:
			width = snappedf(width, ctx.grid_size() * WIDTH_SNAP_FRACTION)
		params["width"] = width
	_refresh()


func _toggle_profile_mode() -> void:
	_profile_mode = not _profile_mode
	if _profile_mode:
		_profile_origin = _distance
		_profile_start = params["profile"]
	else:
		# The width continues from its current value.
		_width_origin = _distance - params["width"] / maxf(_scale, 1e-9)


func _step_segments(step: int) -> void:
	params["segments"] = clampi(int(params["segments"]) + step, 1, TFConst.BEVEL_MAX_SEGMENTS)
	_refresh()


## Aborts the modal bevel; nothing was changed.
func cancel() -> void:
	_active = false
	_targets = []
	_results = []
	_computed = {}


## Applies the preview as one undo action. A preview with invalid brushes
## is rejected (the modal bevel continues); width 0 just ends it.
func commit() -> void:
	if not _active:
		return
	_refresh()
	if params["width"] <= TFConst.EPSILON or _item_count() == 0:
		cancel()
		return
	if _invalid_count() > 0:
		TFTool.toast(TFI18n.t("Bevel not possible with this width (clamp is off). Press %s to clamp it.") % TFShortcuts.text("bevel_clamp"), EditorToaster.SEVERITY_WARNING)
		return
	var brushes: Array = []
	var old_faces: Array = []
	var new_faces: Array = []
	for i in _targets.size():
		if (_results[i] as Dictionary).is_empty():
			continue
		brushes.append(_targets[i]["brush"])
		old_faces.append(_targets[i]["faces"])
		new_faces.append(_results[i]["faces"])
	var applied := TFUndo.commit_replaceable_faces(ctx.undo_redo(), TFI18n.action("Bevel"), brushes, old_faces, new_faces)
	TFEditorSettings.store_bevel(params)
	_last = {
		"kind": _kind,
		"targets": _targets.filter(func(target: Dictionary) -> bool: return brushes.has(target["brush"])),
		"by_angle": _by_angle,
		"brushes": brushes,
		"applied": applied,
		"params": params.duplicate(),
		"history": _history(brushes[0]),
	}
	_last["version"] = (_last["history"] as UndoRedo).get_version() if _last["history"] != null else -1
	_active = false
	_targets = []
	_results = []
	committed.emit()


# --- adjusting the last bevel ----------------------------------------------------

## True while the last bevel is still the latest undo action of its scene.
func has_last() -> bool:
	if _last.is_empty():
		return false
	for brush in _last["brushes"]:
		if not is_instance_valid(brush) or not (brush as Node).is_inside_tree():
			return false
	var history: UndoRedo = _last["history"]
	return history != null and history.get_version() == _last["version"]


## Parameters, kind and angle mode of the last bevel (for the panel).
func last_params() -> Dictionary:
	return (_last.get("params", {}) as Dictionary).duplicate()


func last_by_angle() -> bool:
	return _last.get("by_angle", false)


func last_kind() -> Kind:
	return _last.get("kind", Kind.EDGES)


## Recomputes the last bevel from its source faces with new parameters and
## replaces its result in the same undo action. Returns the state for the
## panel: {width (after clamping), segments, clamped, capped, invalid}, or
## {} if the last bevel can no longer be changed.
func adjust_last(new_params: Dictionary) -> Dictionary:
	if not has_last():
		return {}
	var p: Dictionary = _last["params"].duplicate()
	p.merge(new_params, true)
	var targets: Array = _last["targets"]
	if _last["by_angle"]:
		_apply_angle(targets, p["angle"])
	var results := _compute(targets, p, _last["kind"])
	var state := _state(results, p)
	if state["invalid"] > 0 or p["width"] <= TFConst.EPSILON:
		state["invalid"] = maxi(state["invalid"], 1)
		return state
	var faces: Array = []
	for result: Dictionary in results:
		faces.append(result["faces"])
	TFUndo.replace_committed_faces(_last["brushes"], _last["applied"], faces)
	_last["params"] = p
	TFEditorSettings.store_bevel(p)
	return state


## Forgets the last bevel (the panel closes).
func forget_last() -> void:
	_last = {}


# --- overlay and texts ------------------------------------------------------------

func draw_3d(overlay: TFOverlay3D) -> void:
	if not _active:
		return
	for i in _targets.size():
		var target: Dictionary = _targets[i]
		var brush: TFBrush = target["brush"]
		if not is_instance_valid(brush):
			continue
		var xf := brush.global_transform
		for item in target["items"]:
			if _kind == Kind.VERTICES:
				overlay.add_point(xf * (item as Vector3), TFEditorContext.COLOR_SELECTED)
			else:
				overlay.add_line(xf * (item[0] as Vector3), xf * (item[1] as Vector3), TFEditorContext.COLOR_SELECTED)
		var result: Dictionary = _results[i] if i < _results.size() else {}
		if result.is_empty():
			if params["width"] > TFConst.EPSILON and not (target["items"] as Array).is_empty():
				overlay.add_brush_edges(brush, COLOR_REJECTED)
			continue
		var color := COLOR_CLAMPED if result["clamped"] else TFEditorContext.COLOR_PREVIEW
		overlay.add_polyhedron_fill(result["polyhedron"], xf, Color(color, 0.2))
		overlay.add_polyhedron_edges(result["polyhedron"], xf, color)


func get_hint() -> String:
	return TFI18n.t("Mouse: %s · Wheel / %s / %s: segments · %s: profile · %s: clamp · %s: corners · LMB / %s: apply · RMB / %s: cancel") % [
		TFI18n.t("profile") if _profile_mode else TFI18n.t("width"), keys("bevel_more"), keys("bevel_less"), keys("bevel_profile"),
		keys("bevel_clamp"), keys("bevel_corners"), keys("bevel_confirm"), keys("cancel")]


func get_info() -> String:
	var state := _state(_results, params)
	var count := _item_count()
	var parts: Array[String] = [
		TFI18n.t("Bevel %s m") % TFTool.format_length(state["width"]),
		TFI18n.t("%d segment(s)") % state["segments"],
		TFI18n.t("Profile %.2f") % params["profile"],
		(TFI18n.t("%d vertex/vertices") if _kind == Kind.VERTICES else TFI18n.t("%d edge(s)")) % count,
	]
	if _by_angle:
		parts.append(TFI18n.t("from %s°") % TFTool.format_length(params["angle"]))
	parts.append(TFI18n.t("Clamp on") if params["clamp"] else TFI18n.t("Clamp off"))
	if _kind == Kind.EDGES:
		parts.append(TFI18n.t("round corners") if params["corners"] == TFBevel.Corners.PATCH else TFI18n.t("cut corners"))
	if state["clamped"]:
		parts.append(TFI18n.t("width clamped"))
	if state["capped"]:
		parts.append(TFI18n.t("segments reduced (plane limit)"))
	if state["invalid"] > 0:
		parts.append(TFI18n.t("⚠ invalid for %d brush(es)") % state["invalid"])
	if _skipped > 0:
		parts.append(TFI18n.t("%d edge(s) skipped: across brushes/concave") % _skipped)
	return " · ".join(parts)


## Short label next to the cursor.
func get_cursor_label() -> String:
	if _profile_mode:
		return TFI18n.t("Profile %.2f") % params["profile"]
	return "%s m · %d" % [TFTool.format_length(params["width"]), params["segments"]]


static func keys(action: String) -> String:
	return TFShortcuts.text(action)


# --- computation ------------------------------------------------------------------

func _refresh() -> void:
	if not _active or params == _computed:
		return
	_results = _compute(_targets, params, _kind)
	_computed = params.duplicate()


func _compute(targets: Array, p: Dictionary, kind: Kind) -> Array:
	var results: Array = []
	for target: Dictionary in targets:
		var brush: TFBrush = target["brush"]
		var bevel_params := p.duplicate()
		bevel_params["offset"] = brush.get_map_offset()
		bevel_params["ppm"] = brush.get_ppm()
		var items: Array = target["items"]
		var result := {}
		if p["width"] > TFConst.EPSILON and not items.is_empty():
			if kind == Kind.VERTICES:
				result = TFBevel.bevel_vertices(target["faces"], PackedVector3Array(items), bevel_params)
			else:
				result = TFBevel.bevel_edges(target["faces"], items, bevel_params)
		results.append(result)
	return results


# {width, segments, clamped, capped, invalid} of results.
func _state(results: Array, p: Dictionary) -> Dictionary:
	var state := {"width": p["width"], "segments": p["segments"], "clamped": false, "capped": false, "invalid": 0}
	var width := INF
	var segments := 0
	for result: Dictionary in results:
		if result.is_empty():
			if p["width"] > TFConst.EPSILON:
				state["invalid"] += 1
			continue
		width = minf(width, result["width"])
		segments = maxi(segments, result["segments"])
		state["clamped"] = state["clamped"] or result["clamped"]
		state["capped"] = state["capped"] or result["capped"]
	if width != INF:
		state["width"] = width
		state["segments"] = segments
	return state


func _invalid_count() -> int:
	return _state(_results, params)["invalid"]


func _item_count() -> int:
	var count := 0
	for target: Dictionary in _targets:
		count += (target["items"] as Array).size()
	return count


# Brush mode: the items are the candidates at or above the angle limit.
# Returns how many of them the outline filter skips.
static func _apply_angle(targets: Array, limit: float) -> int:
	var skipped := 0
	for target: Dictionary in targets:
		if not target.has("candidates"):
			continue
		var items: Array = []
		for candidate: Array in target["candidates"]:
			if candidate[2] < limit - 1e-3:
				continue
			if candidate[3]:
				items.append([candidate[0], candidate[1]])
			else:
				skipped += 1
		target["items"] = items
	return skipped


func _center() -> Vector3:
	var sum := Vector3.ZERO
	var count := 0
	for target: Dictionary in _targets:
		var xf := (target["brush"] as TFBrush).global_transform
		for item in target["items"]:
			sum += xf * ((item as Vector3) if _kind == Kind.VERTICES else ((item[0] as Vector3) + (item[1] as Vector3)) * 0.5)
			count += 1
	return sum / maxf(count, 1)


func _history(brush: TFBrush) -> UndoRedo:
	var manager := ctx.undo_redo()
	if manager == null:
		return null
	return manager.get_history_undo_redo(manager.get_object_history_id(brush))


# --- edges ------------------------------------------------------------------------

# Edges of a brush as [a, b, angle (degrees between the face normals),
# allowed] in brush-local space, all of them or those in only. allowed is
# false for edges of a closed compound that are not on its outline or where
# a face of the brush is hidden (seams, concave outline edges).
func _candidates(brush: TFBrush, only: Array) -> Array:
	var result: Array = []
	var poly := brush.get_polyhedron()
	var planes := TFCSG.planes_of(brush.faces)
	var compound := ctx.closed_compound_of(brush)
	var data := {}
	var member := -1
	var to_map := Transform3D()
	if compound != null:
		data = ctx.compound_data(compound)
		member = (data["members"] as Array).find(brush)
		to_map = ctx.map.global_transform.affine_inverse() * brush.global_transform
	var edge_faces := TFBevel.edge_face_map(poly)
	for key: Vector2i in edge_faces:
		var pair: PackedInt32Array = edge_faces[key]
		if pair.size() != 2:
			continue
		var a := poly.vertices[key.x]
		var b := poly.vertices[key.y]
		if not only.is_empty() and not only.any(func(edge: Array) -> bool: return _same_edge(edge[0], edge[1], a, b)):
			continue
		var angle := rad_to_deg(planes[pair[0]].normal.angle_to(planes[pair[1]].normal))
		var allowed := compound == null or (member != -1 and _visible_outline_edge(data, member, to_map * a, to_map * b, pair))
		result.append([a, b, angle, allowed])
	return result


# True if the map-space edge lies on the compound outline and both faces of
# the member are visible along it.
static func _visible_outline_edge(data: Dictionary, member: int, a: Vector3, b: Vector3, faces: PackedInt32Array) -> bool:
	var outline: Array = data["outline"]
	for t: float in [0.1, 0.5, 0.9]:
		var point := a.lerp(b, t)
		if not outline.any(func(segment: Array) -> bool: return _on_segment(point, segment[0], segment[1])):
			return false
	var middle := (a + b) * 0.5
	for f in faces:
		var pieces: Array = data["face_pieces"].get(Vector2i(member, f), [])
		var visible := false
		for piece: PackedVector3Array in pieces:
			for k in piece.size():
				if _on_segment(middle, piece[k], piece[(k + 1) % piece.size()]):
					visible = true
					break
			if visible:
				break
		if not visible:
			return false
	return true


static func _on_segment(point: Vector3, a: Vector3, b: Vector3) -> bool:
	var ab := b - a
	var t := clampf((point - a).dot(ab) / maxf(ab.length_squared(), 1e-12), 0.0, 1.0)
	return point.distance_to(a + ab * t) <= OUTLINE_TOLERANCE


static func _same_edge(p: Vector3, q: Vector3, a: Vector3, b: Vector3) -> bool:
	var eps := TFConst.EPSILON * TFConst.EPSILON
	return (p.distance_squared_to(a) <= eps and q.distance_squared_to(b) <= eps) or (p.distance_squared_to(b) <= eps and q.distance_squared_to(a) <= eps)
