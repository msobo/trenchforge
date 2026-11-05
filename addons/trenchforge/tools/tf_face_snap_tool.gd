@tool
class_name TFFaceSnapTool
extends TFTool
## Face snap (T): puts the bottom of the texture onto a face edge, with live
## preview. The mouse picks the edge nearest to the cursor, W/A/S/D the
## top/left/bottom/right edge on screen, Q/E fit one tile vertically/
## horizontally, R resets the scale. LMB confirms, Esc cancels. The faces of
## a logical face (compound) snap together to an edge of its outline.

var _targets: Array = []  # Logical faces: Array of [TFBrush, face_index]
var _polygons: Array[PackedVector3Array] = []  # Map-space outline per target.
var _edges: Array[int] = []  # Chosen polygon edge per target.
var _snapshots := {}  # TFBrush -> Array[TFFace]
var _fit_u := false
var _fit_v := false
var _reset_scale := false
var _mouse := Vector2.ZERO
## Set by W/A/S/D: the mouse must travel before it picks edges again.
var _key_anchor: Variant = null

## Mouse travel (px) after W/A/S/D before the cursor picks edges again.
const KEY_RELEASE_DISTANCE: float = 24.0


func get_tool_name() -> String:
	return "face_snap"


func activate() -> void:
	_targets = ctx.target_face_groups()
	_polygons = []
	_edges = []
	_snapshots = {}
	_fit_u = false
	_fit_v = false
	_reset_scale = false
	_key_anchor = null
	for group: Array in _targets:
		for entry in group:
			var brush: TFBrush = entry[0]
			if not _snapshots.has(brush):
				_snapshots[brush] = TFUndo.snapshot_faces(brush)
		var polygon := ctx.logical_polygon(group)
		_polygons.append(polygon)
		_edges.append(TFUV.bottom_edge(polygon))
	if _targets.is_empty():
		ctx.request_tool.call_deferred("select")
		return
	_preview()


func cancel() -> void:
	for brush: TFBrush in _snapshots:
		if is_instance_valid(brush):
			brush.faces = TFUndo.copy_faces(_snapshots[brush])
	_targets = []
	_snapshots = {}


func is_busy() -> bool:
	return not _targets.is_empty()


func get_hint() -> String:
	return TFI18n.t("Mouse / %s %s %s %s: edge · %s: fit vertically · %s: fit horizontally · %s: reset scale · LMB: OK · %s: cancel") % [
		keys("snap_up"), keys("snap_left"), keys("snap_down"), keys("snap_right"),
		keys("snap_fit_v"), keys("snap_fit_u"), keys("snap_reset"), keys("cancel")]


func get_info() -> String:
	var flags: Array[String] = []
	if _fit_v:
		flags.append(TFI18n.t("Fit vertically"))
	if _fit_u:
		flags.append(TFI18n.t("Fit horizontally"))
	return TFI18n.t("Face Snap · %d face(s)%s") % [_targets.size(), (" · " + ", ".join(flags)) if not flags.is_empty() else ""]


## World-space outline of a target.
func _world_polygon(target: int) -> PackedVector3Array:
	return ctx.map.global_transform * _polygons[target] if ctx.map != null else _polygons[target]


func handle_input(camera: Camera3D, event: InputEvent) -> bool:
	if event is InputEventMouseMotion:
		_mouse = event.position
		if _key_anchor != null and _mouse.distance_to(_key_anchor) < KEY_RELEASE_DISTANCE:
			return true
		_key_anchor = null
		_pick_nearest(camera, _mouse)
		return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_commit()
			ctx.request_tool("select")
		return true
	if event is InputEventKey and event.pressed and not event.echo:
		if TFShortcuts.matches("cancel", event):
			cancel()
			ctx.request_tool("select")
			return true
		match TFShortcuts.find_action("face_snap", event):
			"snap_up":
				_pick_direction(camera, Vector2.UP)
			"snap_left":
				_pick_direction(camera, Vector2.LEFT)
			"snap_down":
				_pick_direction(camera, Vector2.DOWN)
			"snap_right":
				_pick_direction(camera, Vector2.RIGHT)
			"snap_fit_v":
				_fit_v = not _fit_v
				_preview()
			"snap_fit_u":
				_fit_u = not _fit_u
				_preview()
			"snap_reset":
				_reset_scale = true
				_fit_u = false
				_fit_v = false
				_preview()
			_:
				return false
		return true
	return false


func draw_3d(overlay: TFOverlay3D) -> void:
	for i in _targets.size():
		var polygon := _world_polygon(i)
		if polygon.size() < 3:
			continue
		overlay.add_polygon(polygon, TFEditorContext.COLOR_FACE_HOVER)
		var edge := _edges[i]
		overlay.add_line(polygon[edge], polygon[(edge + 1) % polygon.size()], TFEditorContext.COLOR_SELECTED)


func _preview() -> void:
	var results := {}
	for brush: TFBrush in _snapshots:
		results[brush] = TFUndo.copy_faces(_snapshots[brush])
	for i in _targets.size():
		for entry: Array in _targets[i]:
			var brush: TFBrush = entry[0]
			var face: TFFace = results[brush][entry[1]]
			if _reset_scale:
				face.uv_scale = Vector2(signf(face.uv_scale.x) if face.uv_scale.x != 0.0 else 1.0, signf(face.uv_scale.y) if face.uv_scale.y != 0.0 else 1.0)
			TFUV.snap_to_edge(face, _polygons[i], _edges[i], TFUV.get_texture_size(face.material), brush.get_ppm(), _fit_u, _fit_v)
	for brush: TFBrush in results:
		brush.faces = results[brush]


func _commit() -> void:
	var brushes: Array = []
	var old_faces: Array = []
	var new_faces: Array = []
	for brush: TFBrush in _snapshots:
		if is_instance_valid(brush):
			brushes.append(brush)
			old_faces.append(_snapshots[brush])
			new_faces.append(brush.faces)
	_targets = []
	_snapshots = {}
	if not brushes.is_empty():
		TFUndo.commit_many_faces(ctx.undo_redo(), TFI18n.action("Face Snap"), brushes, old_faces, new_faces)


func _pick_nearest(camera: Camera3D, screen_pos: Vector2) -> void:
	var changed := false
	for i in _targets.size():
		var points := _screen_polygon(camera, i)
		var best := _edges[i]
		var best_distance := INF
		for e in points.size():
			var a := points[e]
			var b := points[(e + 1) % points.size()]
			var closest := Geometry2D.get_closest_point_to_segment(screen_pos, a, b)
			var distance := closest.distance_to(screen_pos)
			if distance < best_distance:
				best_distance = distance
				best = e
		if best != _edges[i]:
			_edges[i] = best
			changed = true
	if changed:
		_preview()


func _pick_direction(camera: Camera3D, direction: Vector2) -> void:
	_key_anchor = _mouse
	for i in _targets.size():
		var points := _screen_polygon(camera, i)
		var center := Vector2.ZERO
		for p in points:
			center += p
		center /= float(maxi(points.size(), 1))
		var best := _edges[i]
		var best_score := -INF
		for e in points.size():
			var middle := (points[e] + points[(e + 1) % points.size()]) * 0.5
			var score := (middle - center).dot(direction)
			if score > best_score:
				best_score = score
				best = e
		_edges[i] = best
	_preview()


func _screen_polygon(camera: Camera3D, target: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	for p in _world_polygon(target):
		result.append(camera.unproject_position(p))
	return result
