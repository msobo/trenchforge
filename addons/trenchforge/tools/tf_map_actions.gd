@tool
class_name TFMapActions
extends RefCounted
## Organization commands (hotkeys and the toolbar "Map" menu): hide/isolate,
## groups and compounds, selection queries, Validate Map and Bake to Mesh.
## Every change is one undo action.

var ctx: TFEditorContext


func _init(p_ctx: TFEditorContext) -> void:
	ctx = p_ctx


## Runs a command by name; returns false for unknown names.
func run(action: String) -> bool:
	if ctx.map == null or not is_instance_valid(ctx.map):
		return false
	match action:
		"hide":
			hide_selection()
		"isolate":
			isolate()
		"unhide_all":
			unhide_all()
		"group":
			group_selection()
		"ungroup":
			ungroup_selection()
		"make_compound":
			make_compound()
		"dissolve_compound":
			dissolve_compound()
		"select_same_material":
			select_same_material()
		"select_touching":
			select_touching()
		"select_inside":
			select_inside()
		"validate_map":
			validate_map()
		"bake_mesh":
			bake_mesh(false)
		"bake_mesh_keep":
			bake_mesh(true)
		_:
			return false
	return true


# --- visibility ---------------------------------------------------------------

func hide_selection() -> void:
	var selection := ctx.selected_brushes()
	if selection.is_empty():
		return
	ctx.clear_selection()
	TFUndo.set_hidden(ctx.undo_redo(), TFI18n.action("Hide"), selection, true)


## Hides every brush that is not selected.
func isolate() -> void:
	var selection := ctx.selected_brushes()
	if selection.is_empty():
		return
	var others: Array[TFBrush] = []
	for brush in ctx.brushes():
		if not selection.has(brush):
			others.append(brush)
	if not others.is_empty():
		TFUndo.set_hidden(ctx.undo_redo(), TFI18n.action("Isolate"), others, true)


func unhide_all() -> void:
	var hidden: Array[TFBrush] = []
	for brush in ctx.map.get_brushes():
		if brush.is_editor_hidden():
			hidden.append(brush)
	if not hidden.is_empty():
		TFUndo.set_hidden(ctx.undo_redo(), TFI18n.action("Show all"), hidden, false)


func hidden_count() -> int:
	var count := 0
	for brush in ctx.map.get_brushes():
		if brush.is_editor_hidden():
			count += 1
	return count


# --- groups -------------------------------------------------------------------

func group_selection() -> void:
	var roots := ctx.selected_roots()
	if roots.is_empty():
		return
	var parent := TFGroups.common_parent(roots, ctx.parent_for_new())
	var new_group := TFGroups.group(ctx.undo_redo(), TFI18n.action("Group"), roots, parent, ctx.scene_root())
	ctx.select_nodes([new_group])


func ungroup_selection() -> void:
	var groups := ctx.selected_groups()
	if groups.is_empty():
		toast(TFI18n.t("Ungroup: select a group."))
		return
	if ctx.entered_group != null and groups.has(ctx.entered_group):
		ctx.entered_group = null
	ctx.clear_selection()
	ctx.select_nodes(TFGroups.ungroup(ctx.undo_redo(), TFI18n.action("Ungroup"), groups))


## Turns the selection into a compound: a selected group (or the entered
## group without selection) becomes one, otherwise the selected brushes and
## groups are grouped into a new one. Compounds are never nested.
func make_compound() -> void:
	var roots := ctx.selected_roots()
	var groups := ctx.selected_groups()
	if roots.is_empty() and ctx.entered_group != null and is_instance_valid(ctx.entered_group):
		roots = [ctx.entered_group]
		groups = [ctx.entered_group]
	if roots.size() == 1 and groups.size() == 1:
		var group_node: Node3D = groups[0]
		if ctx.is_compound(group_node):
			toast(TFI18n.t("Make compound: “%s” is already a compound.") % group_node.name)
			return
		if TFGroups.compound_of(group_node.get_parent()) != null:
			toast(TFI18n.t("Make compound: already inside a compound (compounds are not nested)."))
			return
		if TFGroups.brushes_of(group_node).size() < 2:
			toast(TFI18n.t("Make compound: at least two brushes needed."))
			return
		TFGroups.mark_compound(ctx.undo_redo(), TFI18n.action("Make compound"), group_node)
		if ctx.entered_group == group_node:
			ctx.exit_group()
		ctx.select_nodes([group_node])
		return
	var count := 0
	for node in roots:
		count += TFGroups.brushes_of(node).size()
	if count < 2:
		toast(TFI18n.t("Make compound: select at least two brushes or a group."))
		return
	var parent := TFGroups.common_parent(roots, ctx.parent_for_new())
	if TFGroups.compound_of(parent) != null:
		toast(TFI18n.t("Make compound: already inside a compound (compounds are not nested)."))
		return
	var compound := TFGroups.make_compound(ctx.undo_redo(), TFI18n.action("Make compound"), roots, parent, ctx.scene_root())
	ctx.select_nodes([compound])


## Dissolves the selected compounds (or the entered one, or the compound of
## the selected brushes) into their brushes.
func dissolve_compound() -> void:
	var compounds: Array[Node3D] = []
	for node in ctx.selected_roots():
		var compound := TFGroups.compound_of(node)
		if compound != null and ctx.is_compound(compound) and not compounds.has(compound):
			compounds.append(compound)
	if compounds.is_empty() and ctx.entered_group != null and ctx.is_compound(ctx.entered_group):
		compounds.append(ctx.entered_group)
	if compounds.is_empty():
		toast(TFI18n.t("Dissolve compound: select a compound."))
		return
	for compound in compounds:
		if ctx.entered_group != null and is_instance_valid(ctx.entered_group) and (compound == ctx.entered_group or compound.is_ancestor_of(ctx.entered_group)):
			ctx.entered_group = null
	ctx.clear_selection()
	ctx.select_nodes(TFGroups.ungroup(ctx.undo_redo(), TFI18n.action("Dissolve compound"), compounds))


# --- selection queries ------------------------------------------------------------

## Face mode: all faces with a material of the selected faces; brush mode:
## all brushes using a material of the selected brushes.
func select_same_material() -> void:
	var materials: Array = []
	for entry in ctx.target_faces():
		var material: Material = (entry[0] as TFBrush).faces[entry[1]].material
		if not materials.has(material):
			materials.append(material)
	if materials.is_empty():
		return
	if ctx.face_mode:
		ctx.selected_faces = TFSelectOps.faces_with_materials(ctx.brushes(), materials)
		ctx.select_face_brushes()
	else:
		ctx.select_brushes(TFSelectOps.brushes_with_materials(ctx.brushes(), materials))


## Selects the brushes touching the selection (the selection is the query
## volume and gets deselected).
func select_touching() -> void:
	var volumes := ctx.selected_brushes()
	if volumes.is_empty():
		return
	ctx.select_brushes(TFSelectOps.touching(volumes, ctx.brushes_in_box(TFPicking.brushes_aabb(volumes))))


## Selects the brushes completely inside a selected brush.
func select_inside() -> void:
	var volumes := ctx.selected_brushes()
	if volumes.is_empty():
		return
	ctx.select_brushes(TFSelectOps.inside(volumes, ctx.brushes_in_box(TFPicking.brushes_aabb(volumes))))


# --- validate -----------------------------------------------------------------

## Removes degenerate brushes and empty groups, dissolves compounds with at
## most one brush, drops unused planes and snaps vertices with float drift
## onto the grid. One undo action.
func validate_map() -> void:
	var changed: Array = []
	var new_faces: Array = []
	var removed: Array = []
	var snapped := 0
	for brush in ctx.map.get_brushes():
		var result := TFSelectOps.repair_brush(brush.faces, brush.get_map_offset(), ctx.grid_size())
		match result["status"]:
			"remove":
				removed.append(brush)
			"fixed":
				changed.append(brush)
				new_faces.append(result["faces"])
				snapped += result["snapped"]
	var empty_groups := _empty_groups(ctx.map)
	removed.append_array(empty_groups)
	var dissolved := TFUndo.compound_dissolves([], [], removed, _compounds(ctx.map)).size()
	if changed.is_empty() and removed.is_empty() and dissolved == 0:
		toast(TFI18n.t("Validate Map: no problems found."))
		return
	ctx.clear_selection()
	TFUndo.replace_brushes(ctx.undo_redo(), TFI18n.action("Validate Map"), changed, new_faces, [], [], removed, ctx.scene_root(),
		{"extra_compounds": _compounds(ctx.map)})
	toast(TFI18n.t("Validate Map: %d brush(es) removed, %d repaired (%d vertices snapped to the grid), %d empty group(s) removed, %d compound(s) dissolved.") % [
		removed.size() - empty_groups.size(), changed.size(), snapped, empty_groups.size(), dissolved])


# --- bake to mesh ------------------------------------------------------------

## Replaces the selected brushes (all visible ones without a selection) by a
## plain MeshInstance3D with collision next to the map, for free editing as
## a Godot mesh. With keep_brushes the brushes stay and get hidden. One undo
## action; selects the baked node.
func bake_mesh(keep_brushes: bool) -> void:
	var brushes := ctx.selected_brushes()
	if brushes.is_empty():
		brushes = ctx.brushes()
	var baked := TFMapBuilder.bake(ctx.map, brushes)
	if baked == null:
		toast(TFI18n.t("Bake to Mesh: no valid brushes."))
		return
	# Outside the map, so it is neither a brush group nor part of the build;
	# a map that is the scene root keeps it as a child.
	var parent: Node = ctx.map.get_parent()
	var map_to_parent := ctx.map.transform
	if ctx.map == ctx.scene_root() or not parent is Node3D:
		parent = ctx.map
		map_to_parent = Transform3D.IDENTITY
	baked.transform = map_to_parent * Transform3D(Basis.IDENTITY, baked.position)
	# Both brush sources skip hidden brushes, so keep_brushes hides them all.
	var removed: Array = []
	var hidden: Array = []
	if keep_brushes:
		hidden.assign(brushes)
	else:
		removed.assign(brushes)
	ctx.clear_selection()
	TFUndo.bake_nodes(ctx.undo_redo(), TFI18n.action("Bake to Mesh"), parent, baked, removed, hidden, ctx.scene_root())
	ctx.select_nodes([baked])
	var surfaces := baked.mesh.get_surface_count() if baked.mesh != null else 0
	toast(TFI18n.t("Bake to Mesh: %d brush(es) → %s (%d material(s))%s.") % [brushes.size(), baked.name, surfaces,
		TFI18n.t(", brushes hidden") if keep_brushes else ""])


## Number of brushes the overlay marks as invalid.
func invalid_brushes() -> Array[TFBrush]:
	var result: Array[TFBrush] = []
	for brush in ctx.brushes():
		if not brush.is_valid():
			result.append(brush)
	return result


# All compounds below the node.
func _compounds(node: Node) -> Array:
	var result: Array = []
	for child in node.get_children():
		if ctx.is_group(child):
			if ctx.is_compound(child):
				result.append(child)
			result.append_array(_compounds(child))
	return result


# Outermost groups without any brush (nested empty groups go with them).
func _empty_groups(node: Node) -> Array:
	var result: Array = []
	for child in node.get_children():
		if not ctx.is_group(child):
			continue
		if TFGroups.brushes_of(child).is_empty() and child.get_child_count() == _group_child_count(child):
			result.append(child)
		else:
			result.append_array(_empty_groups(child))
	return result


# Children that are (possibly nested, empty) groups.
func _group_child_count(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		if ctx.is_group(child) and child.get_child_count() == _group_child_count(child):
			count += 1
	return count


func toast(text: String, severity: EditorToaster.Severity = EditorToaster.SEVERITY_INFO) -> void:
	EditorInterface.get_editor_toaster().push_toast("TrenchForge: " + text, severity)
