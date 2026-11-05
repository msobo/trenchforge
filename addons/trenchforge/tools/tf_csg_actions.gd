@tool
class_name TFCSGActions
extends RefCounted
## Editor side of clip and CSG: converts between brush spaces, applies the
## TFCSG results to the scene and records each operation as one undo action.

enum ClipKeep { FRONT, BACK, BOTH }

var ctx: TFEditorContext


func _init(p_ctx: TFEditorContext) -> void:
	ctx = p_ctx


## Clips the brushes by a world-space plane. Returns false if nothing changed.
func clip(brushes: Array[TFBrush], world_plane: Plane, keep: ClipKeep) -> bool:
	var material := ctx.current_material if ctx.clip_uses_current_material else null
	var results: Array = []
	for brush in brushes:
		var parts := clip_parts(brush, world_plane, material)
		if parts[0].is_empty() or parts[1].is_empty():
			# Plane misses the brush; it is kept unless it lies entirely on
			# the discarded side.
			var side := 0 if not parts[0].is_empty() else 1
			if keep == ClipKeep.BOTH or keep == side:
				continue
			results.append([brush, []])
			continue
		match keep:
			ClipKeep.FRONT:
				results.append([brush, [parts[0]]])
			ClipKeep.BACK:
				results.append([brush, [parts[1]]])
			ClipKeep.BOTH:
				results.append([brush, [parts[0], parts[1]]])
	if results.is_empty():
		return false
	_apply(TFI18n.action("Clip"), results, [])
	return true


## [front_faces, back_faces] of a brush cut by a world-space plane, in the
## brush's local space (see TFCSG.clip()).
func clip_parts(brush: TFBrush, world_plane: Plane, material: Material = null) -> Array:
	var local := TFCSG.normalized(brush.global_transform.affine_inverse() * world_plane)
	return TFCSG.clip(brush.faces, local, material)


## Subtract with the active (last selected) brush as cutter: from the other
## selected brushes, or with all_overlapping from every brush of the map.
func subtract_selection(all_overlapping: bool) -> void:
	var selection := ctx.selected_brushes()
	if selection.is_empty():
		toast(TFI18n.t("Subtract: select a cutter brush (last selected brush = cutter)."))
		return
	var cutter: TFBrush = selection[-1]
	var targets: Array[TFBrush] = []
	var cutter_box := cutter.global_transform * cutter.get_local_aabb()
	for brush in (ctx.brushes_in_box(cutter_box) if all_overlapping else selection):
		if brush != cutter:
			targets.append(brush)
	if targets.is_empty():
		toast(TFI18n.t("Subtract: select at least two brushes (last selected = cutter)."))
		return
	var world_faces := TFCSG.transform_faces(cutter.faces, cutter.global_transform)
	var removed: Array = [] if ctx.keep_cutter else [cutter]
	if not subtract(targets, world_faces, ctx.cut_faces_from_target, TFI18n.action("Subtract"), removed):
		toast(TFI18n.t("Subtract: the cutter does not overlap any target brush."))


## Subtracts a cutter (faces in world space) from the targets as one undo
## action that also removes extra_removed. A target split into several
## fragments becomes a compound (unless it already lies in one). Returns
## false if nothing overlaps.
func subtract(targets: Array[TFBrush], world_faces: Array[TFFace], faces_from_target: bool, action_name: String, extra_removed: Array = []) -> bool:
	var results := subtract_results(targets, world_faces, faces_from_target)
	if results.is_empty():
		return false
	_apply(action_name, results, extra_removed, true)
	return true


## [brush, fragments] for every target the world-space cutter overlaps.
func subtract_results(targets: Array[TFBrush], world_faces: Array[TFFace], faces_from_target: bool) -> Array:
	var cutter_box := _faces_aabb(world_faces)
	var min_thickness := ctx.grid_size() * TFConst.MIN_FRAGMENT_GRID_FRACTION
	var results: Array = []
	for target in targets:
		if not target.is_valid():
			continue
		var box := target.global_transform * target.get_local_aabb()
		if not box.intersects(cutter_box):
			continue
		var local := TFCSG.transform_faces(world_faces, target.global_transform.affine_inverse())
		var fragments: Variant = TFCSG.subtract(target.faces, local, faces_from_target, min_thickness)
		if fragments != null:
			results.append([target, fragments])
	return results


## Replaces every selected brush by walls one grid step thick.
func hollow(outward: bool) -> void:
	var results: Array = []
	var failed := 0
	for brush in ctx.selected_brushes():
		var walls := TFCSG.hollow(brush.faces, ctx.grid_size(), outward)
		if walls.is_empty():
			failed += 1
		else:
			results.append([brush, walls])
	if failed > 0:
		toast(TFI18n.t("Hollow: %d brush(es) too thin for wall thickness %s m.") % [failed, TFTool.format_length(ctx.grid_size())])
	if not results.is_empty():
		_apply(TFI18n.action("Hollow"), results, [])


## Merges the selected brushes into their convex hull (kept in the first).
func merge() -> void:
	var selection := ctx.selected_brushes()
	if selection.size() < 2:
		toast(TFI18n.t("Merge: select at least two brushes."))
		return
	var base := selection[0]
	var to_base := base.global_transform.affine_inverse()
	var face_sets: Array = []
	for brush in selection:
		face_sets.append(TFCSG.transform_faces(brush.faces, to_base * brush.global_transform))
	var result := TFCSG.merge(face_sets)
	if result.is_empty():
		toast(TFI18n.t("Merge: no valid hull."))
		return
	if result["added_volume"] > 0.0:
		toast(TFI18n.t("Merge: the hull fills %s m³ that were empty before.") % TFTool.format_length(result["added_volume"]), EditorToaster.SEVERITY_WARNING)
	_apply(TFI18n.action("Merge"), [[base, [result["faces"]]]], selection.slice(1))


## results: Array of [brush, pieces]. The first piece replaces the brush's
## faces, further pieces become new brushes next to it (same parent, mode and
## position), no pieces remove it. With make_compounds, a brush split into
## several pieces outside a compound becomes a compound of them. Selects the
## resulting brushes (or the new compounds).
func _apply(action_name: String, results: Array, extra_removed: Array, make_compounds: bool = false) -> void:
	var changed: Array = []
	var new_faces: Array = []
	var parents: Array = []
	var added: Array = []
	var removed: Array = extra_removed.duplicate()
	var new_compounds: Array = []
	var selection: Array = []
	for entry in results:
		var brush: TFBrush = entry[0]
		var pieces: Array = entry[1]
		if pieces.is_empty():
			if not removed.has(brush):
				removed.append(brush)
			continue
		changed.append(brush)
		new_faces.append(pieces[0])
		var parent := brush.get_parent()
		if make_compounds and pieces.size() > 1 and TFGroups.compound_of(parent) == null:
			parent = TFGroups.new_compound()
			new_compounds.append([parent, brush])
			selection.append(parent)
		else:
			selection.append(brush)
		for i in range(1, pieces.size()):
			var copy := TFUndo.duplicate_brush(brush)
			copy.faces = TFUndo.copy_faces(pieces[i])
			parents.append(parent)
			added.append(copy)
			if parent == brush.get_parent():
				selection.append(copy)
	ctx.clear_selection()
	TFUndo.replace_brushes(ctx.undo_redo(), action_name, changed, new_faces, parents, added, removed, ctx.scene_root(),
		{"new_compounds": new_compounds})
	ctx.select_nodes(selection)


static func _faces_aabb(faces: Array[TFFace]) -> AABB:
	return TFGeometry.planes_to_polyhedron(TFCSG.planes_of(faces)).get_aabb().grow(TFConst.EPSILON)


## Short feedback in the editor's toaster.
func toast(text: String, severity: EditorToaster.Severity = EditorToaster.SEVERITY_INFO) -> void:
	EditorInterface.get_editor_toaster().push_toast("TrenchForge: " + text, severity)
