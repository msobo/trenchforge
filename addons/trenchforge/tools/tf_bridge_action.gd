@tool
class_name TFBridgeAction
extends RefCounted
## Bridge (Ctrl+Shift+E, like Blender's Bridge Edge Loops): fills the space
## between two selected faces (select tool, face mode; logical faces of a
## compound bridge their outline) or two selected edge loops (vertex tool,
## edge mode) with convex pieces (TFBridge). The pieces form a new compound
## "Bridge" that stays parametric: the shape panel changes cuts, twist,
## interpolation, smoothness and profile afterwards. New bridges use the
## options of the editor settings (TFEditorSettings.BRIDGE).

const GROUP_NAME := "Bridge"

var ctx: TFEditorContext


func _init(p_ctx: TFEditorContext) -> void:
	ctx = p_ctx


## Bridges the two selected (logical) faces. False (with a toast) if there
## are not exactly two or they cannot be bridged.
func bridge_faces() -> bool:
	var groups := ctx.target_face_groups()
	if groups.size() != 2:
		toast(TFI18n.t("Bridge: select exactly two faces (face mode) or two edge loops (edge mode)."))
		return false
	var loops: Array[PackedVector3Array] = []
	var normals: Array[Vector3] = []
	var sources: Array[TFFace] = []
	for group: Array in groups:
		var brush: TFBrush = group[0][0]
		loops.append(ctx.logical_polygon(group))
		normals.append(brush.get_face_map_plane(group[0][1]).normal.normalized())
		sources.append(brush.faces[group[0][1]])
	return _create(loops, normals, sources)


## Bridges two edge loops given as world-space edges ([a, b]) of the
## selected brushes. Each loop takes the normal and attributes of a selected
## brush face it lies on (the one facing the other loop if several do).
func bridge_edges(edges: Array) -> bool:
	var to_map := ctx.map.global_transform.affine_inverse()
	var segments: Array = []
	for edge: Array in edges:
		segments.append([to_map * (edge[0] as Vector3), to_map * (edge[1] as Vector3)])
	var loops := TFBridge.chain_loops(segments)
	if loops.size() != 2:
		toast(TFI18n.t("Bridge: select exactly two faces (face mode) or two edge loops (edge mode)."))
		return false
	var centers: Array[Vector3] = [_center(loops[0]), _center(loops[1])]
	var normals: Array[Vector3] = []
	var sources: Array[TFFace] = []
	for k in 2:
		var towards := centers[1 - k] - centers[k]
		var normal := TFBridge.loop_normal(loops[k])
		if normal.dot(towards) < 0.0:
			normal = -normal
		var source: TFFace = null
		for brush in ctx.selected_brushes():
			var poly := brush.get_polyhedron()
			for i in brush.faces.size():
				if not poly.is_face_used(i):
					continue
				var plane := brush.get_face_map_plane(i)
				if not _on_plane(loops[k], plane):
					continue
				if source == null or plane.normal.dot(towards) > normal.dot(towards):
					source = brush.faces[i]
					normal = plane.normal.normalized()
		normals.append(normal)
		if source != null:
			sources.append(source)
	return _create(loops, normals, sources)


# Creates the bridge compound (map-space loops) as one undo action.
func _create(loops: Array[PackedVector3Array], normals: Array[Vector3], sources: Array[TFFace]) -> bool:
	var params := TFEditorSettings.bridge_defaults()
	var result := TFBridge.bridge(loops[0], normals[0], loops[1], normals[1], params)
	if result.has("error"):
		toast(error_text(result["error"]), EditorToaster.SEVERITY_WARNING)
		return false
	var parent := ctx.parent_for_new()
	var to_parent := parent.global_transform.affine_inverse() * ctx.map.global_transform
	var local := to_parent * loops[0] + to_parent * loops[1]
	var count_a := loops[0].size()
	var normal_a := (to_parent.basis * normals[0]).normalized()
	var normal_b := (to_parent.basis * normals[1]).normalized()
	var meta_for := func(points: PackedVector3Array) -> Dictionary:
		return TFShapeParams.bridge_meta(points.slice(0, count_a), normal_a, points.slice(count_a), normal_b, params)
	var sets_for := func(points: PackedVector3Array) -> Array:
		return TFShapeParams.bridge_sets(meta_for.call(points))
	ctx.create_shape_compound(parent, local, GROUP_NAME, sets_for, meta_for, TFI18n.action("Bridge"), sources)
	return true


## Status text for a TFBridge error code.
static func error_text(code: String) -> String:
	match code:
		TFBridge.ERROR_PLANAR:
			return TFI18n.t("Bridge: a loop is not planar.")
		TFBridge.ERROR_CONCAVE:
			return TFI18n.t("Bridge: concave loops cannot be bridged (convex brushes only).")
		TFBridge.ERROR_TOO_MANY:
			return TFI18n.t("Bridge: a loop has too many points.")
		TFBridge.ERROR_FOLDS:
			return TFI18n.t("Bridge: the bridge would fold or run into a source brush; try more cuts, Blend path or less smoothness.")
	return TFI18n.t("Bridge: a loop has no area.")


func toast(text: String, severity: EditorToaster.Severity = EditorToaster.SEVERITY_INFO) -> void:
	TFTool.toast(text, severity)


static func _on_plane(loop: PackedVector3Array, plane: Plane) -> bool:
	for p in loop:
		if absf(plane.distance_to(p)) > TFConst.PLANE_EPSILON:
			return false
	return true


static func _center(points: PackedVector3Array) -> Vector3:
	var sum := Vector3.ZERO
	for p in points:
		sum += p
	return sum / float(maxi(points.size(), 1))
