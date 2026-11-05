@tool
class_name TFEditorContext
extends RefCounted
## Shared editor state for all tools: active map, selection, grid, overlay.

signal changed
signal tool_requested(tool_name: String)

## Overlay colors; configurable in the editor settings (TFEditorSettings).
static var COLOR_HOVER := Color(1.0, 0.85, 0.3, 0.9)
static var COLOR_SELECTED := Color(1.0, 0.35, 0.25, 1.0)
static var COLOR_FACE_SELECTED := Color(1.0, 0.35, 0.25, 0.35)
static var COLOR_FACE_HOVER := Color(1.0, 0.85, 0.3, 0.2)
## Accent of face mode (selected faces, toolbar); brush mode
## uses COLOR_SELECTED.
static var COLOR_FACE_MODE := Color(0.5, 0.45, 1.0, 1.0)
static var COLOR_PREVIEW := Color(0.35, 0.8, 1.0, 1.0)
static var COLOR_CURSOR := Color(0.35, 0.8, 1.0, 1.0)
static var COLOR_GROUP := Color(0.55, 0.9, 0.45, 0.9)
static var COLOR_INVALID := Color(1.0, 0.1, 0.6, 1.0)
static var COLOR_UV_GRID := Color(0.75, 0.75, 0.75, 0.7)
static var COLOR_UV_OUTLINE := Color(1.0, 1.0, 1.0, 1.0)

const META_SECTION := "trenchforge"
const META_CURRENT_MATERIAL := "current_material"

var plugin: EditorPlugin
var map: TFMap
var picker := TFPointPicker.new()
## Material for newly created brushes and Alt+LMB without a source face.
var current_material: Material:
	set(value):
		current_material = value
		var path := value.resource_path if value != null else ""
		if not path.is_empty() or value == null:
			EditorInterface.get_editor_settings().set_project_metadata(META_SECTION, META_CURRENT_MATERIAL, path)
		changed.emit()
## Texture lock (TrenchBroom): textures stick to brushes when moving/rotating.
## Off means world-fixed UVs (Anvil default).
var texture_lock := false:
	set(value):
		texture_lock = value
		changed.emit()
var grid_visible := true
var face_mode := false:
	set(value):
		face_mode = value
		if not face_mode:
			selected_faces.clear()
		face_fill_hidden = false
		changed.emit()
## CSG options (toolbar CSG menu): keep the cutter after Subtract, take the
## faces of the opening from the cut brush instead of the cutter, and give
## new clip faces the current material instead of the neighbor face's.
var keep_cutter := false
var cut_faces_from_target := false
var clip_uses_current_material := false
## Selected faces in face mode: Array of [TFBrush, face_index].
var selected_faces: Array = []
## Hides the fill of selected faces (the outline stays) so a freshly assigned
## material can be judged in context. Set by apply_material(), reset by the
## next change of the face selection.
var face_fill_hidden := false
## Group opened by double click: clicks select its members instead of the
## whole group. null = map level.
var entered_group: Node3D
## Modal bevel shared by the select and the vertex tool (set by the plugin).
var bevel: TFBevelOperation

var _overlay: TFOverlay3D
var _index := TFSpatialIndex.new()
var _index_dirty := true
var _compound_cache := {}  # compound instance id -> compound_data()


static func set_color(color_name: String, value: Color) -> void:
	match color_name:
		"COLOR_HOVER":
			COLOR_HOVER = value
		"COLOR_SELECTED":
			COLOR_SELECTED = value
		"COLOR_FACE_SELECTED":
			COLOR_FACE_SELECTED = value
		"COLOR_FACE_HOVER":
			COLOR_FACE_HOVER = value
		"COLOR_FACE_MODE":
			COLOR_FACE_MODE = value
		"COLOR_PREVIEW":
			COLOR_PREVIEW = value
		"COLOR_CURSOR":
			COLOR_CURSOR = value
		"COLOR_GROUP":
			COLOR_GROUP = value
		"COLOR_INVALID":
			COLOR_INVALID = value
		"COLOR_UV_GRID":
			COLOR_UV_GRID = value
		"COLOR_UV_OUTLINE":
			COLOR_UV_OUTLINE = value


func _init(p_plugin: EditorPlugin) -> void:
	plugin = p_plugin
	var path := String(EditorInterface.get_editor_settings().get_project_metadata(META_SECTION, META_CURRENT_MATERIAL, ""))
	if not path.is_empty() and ResourceLoader.exists(path):
		current_material = ResourceLoader.load(path) as Material


func undo_redo() -> EditorUndoRedoManager:
	return plugin.get_undo_redo()


func scene_root() -> Node:
	return EditorInterface.get_edited_scene_root()


## Replaces the brushes of a stairs group, pipe or wall compound by the plane
## sets (group space) as one undo action: existing pieces keep their node and
## origin, missing ones are added, surplus ones removed.
func rebuild_group_shape(node: Node, sets: Array, meta: Dictionary, action: String, merge: int) -> void:
	rebuild_group_shapes([node], [{"sets": sets, "meta": meta}], action, merge)


## rebuild_group_shape() for several groups at once (results[i] with "sets"
## and "meta" for nodes[i]), as one undo action.
func rebuild_group_shapes(nodes: Array, results: Array, action: String, merge: int) -> void:
	var changed: Array = []
	var new_faces: Array = []
	var parents: Array = []
	var added: Array = []
	var removed: Array = []
	var metas: Array = []
	for n in nodes.size():
		var node: Node = nodes[n]
		var sets: Array = results[n]["sets"]
		var old := TFShapeParams.group_brushes(node)
		var origins: Array = []
		for i in sets.size():
			origins.append(old[i].position if i < old.size() else TFGeometry.planes_to_polyhedron(sets[i]).get_aabb().get_center())
		var old_faces: Array = []
		for brush in old:
			old_faces.append(brush.faces)
		var faces := TFShapeParams.group_faces(sets, origins, old_faces)
		for i in sets.size():
			if i < old.size():
				changed.append(old[i])
				new_faces.append(faces[i])
				continue
			var brush := TFBrush.new()
			brush.name = old[0].name
			brush.mode = old[0].mode
			brush.position = origins[i]
			brush.faces = faces[i]
			added.append(brush)
			parents.append(node)
		removed.append_array(old.slice(sets.size()))
		metas.append([node, TFConst.META_SHAPE, results[n]["meta"]])
	TFUndo.replace_brushes(undo_redo(), action, changed, new_faces, parents, added, removed, scene_root(),
		{"meta": metas, "merge_mode": merge})


## Adds the pieces of a path shape or bridge (local: its points in parent
## space) as one undo action: inside a compound they join it (no longer
## parametric), otherwise a new compound with its origin at the first point
## stores the points relative to itself, so moving it keeps the shape
## editable. sets_for(points) gives the plane sets, meta_for(points) the
## shape metadata. The pieces get the current material, or with sources the
## attributes of the source face with the most similar normal. Returns the
## new compound (null if none).
func create_shape_compound(parent: Node3D, local: PackedVector3Array, group_name: String, sets_for: Callable, meta_for: Callable, action: String, sources: Array[TFFace] = []) -> Node3D:
	if TFGroups.compound_of(parent) != null:
		var pieces := _shape_brushes(sets_for.call(local), sources)
		if not pieces.is_empty():
			var parents: Array = []
			parents.resize(pieces.size())
			parents.fill(parent)
			TFUndo.add_brushes(undo_redo(), action, parents, pieces, scene_root())
			select_brushes(pieces)
		return null
	var origin := local[0]
	for k in local.size():
		local[k] -= origin
	var brushes := _shape_brushes(sets_for.call(local), sources)
	if brushes.is_empty():
		return null
	var group := TFGroups.new_compound()
	group.name = group_name
	group.position = origin
	group.set_meta(TFConst.META_SHAPE, meta_for.call(local))
	for brush in brushes:
		group.add_child(brush, true)
	TFUndo.add_brushes(undo_redo(), action, [parent], [group], scene_root())
	select_nodes([group])
	return group


func _shape_brushes(sets: Array, sources: Array[TFFace]) -> Array[TFBrush]:
	var brushes: Array[TFBrush] = []
	for planes: Array[Plane] in sets:
		var brush := TFShapes.create_brush(planes, current_material)
		if brush == null:
			continue
		if not sources.is_empty():
			brush.faces = TFHull.transfer_faces(brush.get_planes(), sources)
		brushes.append(brush)
	return brushes


func set_map(value: TFMap) -> void:
	if map == value:
		return
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null
	_watch(map, false)
	map = value
	_watch(map, true)
	selected_faces.clear()
	entered_group = null
	_index_dirty = true
	_compound_cache.clear()
	changed.emit()


func overlay() -> TFOverlay3D:
	if map == null:
		return null
	if _overlay == null or not is_instance_valid(_overlay) or _overlay.get_parent() != map:
		_overlay = TFOverlay3D.new()
		map.add_child(_overlay, false, Node.INTERNAL_MODE_BACK)
	return _overlay


func dispose() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null
	_watch(map, false)
	map = null


func _watch(target: TFMap, connect: bool) -> void:
	if target == null or not is_instance_valid(target):
		return
	for sig: Signal in [target.build_state_changed, target.editor_visibility_changed]:
		if connect and not sig.is_connected(invalidate_index):
			sig.connect(invalidate_index)
		elif not connect and sig.is_connected(invalidate_index):
			sig.disconnect(invalidate_index)


# --- grid -------------------------------------------------------------------

func grid_size() -> float:
	return map.grid_size if map != null else TFConst.DEFAULT_GRID_SIZE


func step_grid(increase: bool) -> void:
	if map == null:
		return
	map.grid_size = TFSnap.step_grid(map.grid_size, increase)
	changed.emit()


func toggle_grid_visible() -> void:
	grid_visible = not grid_visible
	changed.emit()


# --- brushes & picking ---------------------------------------------------------

## Editable brushes of the map (hidden brushes excluded).
func brushes() -> Array[TFBrush]:
	var result: Array[TFBrush] = []
	if map == null:
		return result
	for brush in map.get_brushes():
		if not brush.is_editor_hidden():
			result.append(brush)
	return result


## Spatial index over brushes(), rebuilt lazily after changes.
func index() -> TFSpatialIndex:
	if _index_dirty:
		_index.rebuild(brushes())
		_index_dirty = false
	return _index


func invalidate_index() -> void:
	_index_dirty = true


## Editable brushes whose bounds touch the world-space box.
func brushes_in_box(box: AABB) -> Array[TFBrush]:
	return index().query_aabb(box)


func pick(camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(screen_pos)
	var direction := camera.project_ray_normal(screen_pos)
	return TFPicking.pick(index().query_ray(origin, direction), origin, direction)


## Parent for newly created brushes: the entered group, else the map.
func parent_for_new() -> Node3D:
	if entered_group != null and is_instance_valid(entered_group) and entered_group.is_inside_tree():
		return entered_group
	return map


# --- groups -------------------------------------------------------------------

func is_group(node: Node) -> bool:
	return TFGroups.is_group(node, map)


## What a click on the brush selects (brush or outermost closed group).
func selectable_for(brush: TFBrush) -> Node3D:
	_validate_entered()
	return TFGroups.selectable_for(brush, map, entered_group)


func enter_group(group_node: Node3D) -> void:
	entered_group = group_node
	clear_selection()
	changed.emit()


## Leaves the entered group one level and selects it.
func exit_group() -> void:
	_validate_entered()
	if entered_group == null:
		return
	var left := entered_group
	var parent := left.get_parent()
	entered_group = parent as Node3D if is_group(parent) else null
	selected_faces.clear()
	select_nodes([left])
	changed.emit()


func _validate_entered() -> void:
	if entered_group != null and (not is_instance_valid(entered_group) or not entered_group.is_inside_tree() or not is_group(entered_group)):
		entered_group = null


# --- compounds ------------------------------------------------------------------

func is_compound(node: Node) -> bool:
	return TFGroups.is_compound(node) and is_group(node)


## The compound the brush belongs to while it acts as one object (not
## entered), else null.
func closed_compound_of(brush: TFBrush) -> Node3D:
	if brush == null or map == null:
		return null
	_validate_entered()
	var compound := TFGroups.compound_of(brush.get_parent())
	if compound == null or not is_group(compound):
		return null
	if entered_group != null and (entered_group == compound or compound.is_ancestor_of(entered_group)):
		return null
	return compound


## Regions and outline of a compound (TFCompound.compute() in map space)
## plus "members" (its visible, valid brushes), cached until a member
## changes.
func compound_data(compound: Node3D) -> Dictionary:
	var members: Array[TFBrush] = []
	var face_sets: Array = []
	var transforms: Array = []
	var polyhedra: Array = []
	var own_faces: Array = []
	var key: Array = []
	var to_map := map.global_transform.affine_inverse()
	for brush in TFGroups.brushes_of(compound):
		if brush.is_editor_hidden() or not brush.is_valid():
			continue
		var xf := to_map * brush.global_transform
		members.append(brush)
		face_sets.append(brush.faces)
		transforms.append(xf)
		polyhedra.append(brush.get_polyhedron())
		own_faces.append(brush.has_meta(TFConst.META_OWN_FACES))
		key.append_array([brush.get_instance_id(), xf, brush.get_planes(), own_faces[-1]])
	var hash_value := key.hash()
	var id := compound.get_instance_id()
	var cached: Dictionary = _compound_cache.get(id, {})
	if not cached.is_empty() and cached["hash"] == hash_value:
		return cached
	var data := TFCompound.compute(face_sets, transforms, polyhedra, own_faces)
	data["members"] = members
	data["hash"] = hash_value
	_compound_cache[id] = data
	return data


## The logical face of a brush face: all member faces of its region (and of
## regions sharing a face with it) if the brush is in a closed compound,
## else just the face. Array of [TFBrush, face_index].
func logical_face(brush: TFBrush, face_index: int) -> Array:
	var single := [[brush, face_index]]
	var compound := closed_compound_of(brush)
	if compound == null:
		return single
	var data := compound_data(compound)
	var members: Array = data["members"]
	var member := members.find(brush)
	var face_regions: Dictionary = data["face_regions"]
	var start := Vector2i(member, face_index)
	if member == -1 or not face_regions.has(start):
		return single
	var result: Array = []
	var seen_faces := {start: true}
	var queue: Array = [start]
	while not queue.is_empty():
		var key: Vector2i = queue.pop_back()
		result.append([members[key.x], key.y])
		for region_index: int in face_regions[key]:
			for other: Vector2i in data["regions"][region_index]["faces"]:
				if not seen_faces.has(other):
					seen_faces[other] = true
					queue.append(other)
	return result


## Splits face entries into logical faces (entries of one region together).
func face_groups(entries: Array) -> Array:
	var groups: Array = []
	var assigned := {}
	for entry in entries:
		if assigned.has(entry):
			continue
		var group: Array = []
		for member_face in logical_face(entry[0], entry[1]):
			if entries.has(member_face) and not assigned.has(member_face):
				assigned[member_face] = true
				group.append(member_face)
		if not assigned.has(entry):
			assigned[entry] = true
			group.append(entry)
		groups.append(group)
	return groups


## Target faces grouped into logical faces (see face_groups()).
func target_face_groups() -> Array:
	return face_groups(target_faces())


## Map-space outline of a logical face (from face_groups()): the largest
## outer loop of its regions, or the face polygon of a single face outside
## a closed compound. Fit, Center and Face Snap use it as the face polygon.
func logical_polygon(group: Array) -> PackedVector3Array:
	var brush: TFBrush = group[0][0]
	var compound := closed_compound_of(brush)
	if compound == null:
		return brush.get_face_map_vertices(group[0][1])
	var data := compound_data(compound)
	var best := PackedVector3Array()
	var best_area := -1.0
	for region_index in _regions_of(data, group):
		var region: Dictionary = data["regions"][region_index]
		for polygon: PackedVector3Array in region["polygons"]:
			if region["area"] > best_area:
				best = polygon
				best_area = region["area"]
	return best if best.size() >= 3 else brush.get_face_map_vertices(group[0][1])


## World-space polygons to fill for a face: its visible parts in a closed
## compound (contact areas cut away), else the face polygon.
func face_fill_polygons(brush: TFBrush, face_index: int) -> Array[PackedVector3Array]:
	var result: Array[PackedVector3Array] = []
	var compound := closed_compound_of(brush)
	if compound != null:
		var data := compound_data(compound)
		var member := (data["members"] as Array).find(brush)
		var pieces: Array = data["face_pieces"].get(Vector2i(member, face_index), [])
		if member != -1 and not pieces.is_empty():
			var xf := map.global_transform
			for piece: PackedVector3Array in pieces:
				result.append(xf * piece)
			return result
	result.append(TFPicking.face_world_polygon(brush, face_index))
	return result


## World-space boundary lines ([a, b]) of the regions of a logical face in
## a closed compound; empty outside compounds.
func logical_face_lines(group: Array) -> Array:
	var lines: Array = []
	var compound := closed_compound_of(group[0][0])
	if compound == null:
		return lines
	var data := compound_data(compound)
	var xf := map.global_transform
	for region_index in _regions_of(data, group):
		var region: Dictionary = data["regions"][region_index]
		for loop: PackedVector3Array in region["polygons"] + region["holes"]:
			for k in loop.size():
				lines.append([xf * loop[k], xf * loop[(k + 1) % loop.size()]])
	return lines


## Draws the edges of the brushes; brushes of a closed compound whose
## visible members are all given (or any, with whole_compounds) draw the
## compound outline instead.
func draw_brush_outlines(overlay: TFOverlay3D, list: Array[TFBrush], color: Color, whole_compounds: bool = false) -> void:
	var done := {}
	for brush in list:
		var compound := closed_compound_of(brush)
		if compound != null and not done.has(compound):
			done[compound] = whole_compounds or _all_members_in(compound, list)
		if compound == null or not done[compound]:
			overlay.add_brush_edges(brush, color)
	for compound: Node3D in done:
		if done[compound]:
			var xf := map.global_transform
			for edge: Array in compound_data(compound)["outline"]:
				overlay.add_line(xf * (edge[0] as Vector3), xf * (edge[1] as Vector3), color)


func _all_members_in(compound: Node3D, list: Array[TFBrush]) -> bool:
	for brush in TFGroups.brushes_of(compound):
		if not brush.is_editor_hidden() and not list.has(brush):
			return false
	return true


## Region indices of the face entries in compound data.
func _regions_of(data: Dictionary, group: Array) -> Array[int]:
	var result: Array[int] = []
	var members: Array = data["members"]
	for entry in group:
		for region_index: int in data["face_regions"].get(Vector2i(members.find(entry[0]), entry[1]), []):
			if not result.has(region_index):
				result.append(region_index)
	return result


# --- selection --------------------------------------------------------------

## Selected brushes; selected groups contribute all their visible members.
func selected_brushes() -> Array[TFBrush]:
	var result: Array[TFBrush] = []
	for node in selected_roots():
		for brush in TFGroups.brushes_of(node):
			if not brush.is_editor_hidden() and not result.has(brush):
				result.append(brush)
	return result


## Selected brushes and groups of the map, as selected (not expanded).
func selected_roots() -> Array[Node]:
	var result: Array[Node] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		if not node.is_inside_tree() or map == null or not map.is_ancestor_of(node):
			continue
		if node is TFBrush or is_group(node):
			result.append(node)
	return result


## Selected group nodes.
func selected_groups() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for node in selected_roots():
		if not node is TFBrush:
			result.append(node)
	return result


func is_selected(brush: TFBrush) -> bool:
	return selected_brushes().has(brush)


## Replaces the editor selection by brushes and/or groups.
func select_nodes(list: Array) -> void:
	var selection := EditorInterface.get_selection()
	selection.clear()
	for node: Node in list:
		selection.add_node(node)


## Replaces the editor selection. The plugin stays active on an empty
## selection (input forwarding is always enabled).
func select_brushes(list: Array[TFBrush]) -> void:
	var selection := EditorInterface.get_selection()
	selection.clear()
	for brush in list:
		selection.add_node(brush)


## Clears brush and face selection (the map stays selected).
func clear_selection() -> void:
	selected_faces.clear()
	var empty: Array[TFBrush] = []
	select_brushes(empty)


## Adds or removes a brush or group (from a click) to/from the selection.
func toggle_node_selection(node: Node) -> void:
	var list := selected_roots()
	if list.has(node):
		list.erase(node)
	else:
		list.append(node)
	select_nodes(list)


func is_face_selected(brush: TFBrush, face_index: int) -> bool:
	return _face_entry_index(brush, face_index) != -1


## Selects all faces of a logical face (see logical_face()); with add, the
## whole logical face is added, or removed if it is fully selected.
func select_logical_face(brush: TFBrush, face_index: int, add: bool) -> void:
	var entries := logical_face(brush, face_index)
	if not add:
		selected_faces.clear()
	var all_selected := true
	for entry in entries:
		if not is_face_selected(entry[0], entry[1]):
			all_selected = false
	for entry in entries:
		var existing := _face_entry_index(entry[0], entry[1])
		if add and all_selected:
			selected_faces.remove_at(existing)
		elif existing == -1:
			selected_faces.append(entry)
	select_face_brushes()


func select_face(brush: TFBrush, face_index: int, add: bool) -> void:
	if not add:
		selected_faces.clear()
	var existing := _face_entry_index(brush, face_index)
	if existing != -1 and add:
		selected_faces.remove_at(existing)
	elif existing == -1:
		selected_faces.append([brush, face_index])
	select_face_brushes()


func clear_faces() -> void:
	selected_faces.clear()
	select_face_brushes()


## Drops face entries whose brush vanished or whose face no longer exists.
func prune_faces() -> void:
	var kept: Array = []
	for entry in selected_faces:
		var brush: TFBrush = entry[0]
		if is_instance_valid(brush) and brush.is_inside_tree() and entry[1] < brush.faces.size():
			kept.append(entry)
	selected_faces = kept


func _face_entry_index(brush: TFBrush, face_index: int) -> int:
	for i in selected_faces.size():
		if selected_faces[i][0] == brush and selected_faces[i][1] == face_index:
			return i
	return -1


## Keeps the editor selection in sync with the brushes owning selected faces.
func select_face_brushes() -> void:
	face_fill_hidden = false
	var list: Array[TFBrush] = []
	for entry in selected_faces:
		if not list.has(entry[0]):
			list.append(entry[0])
	select_brushes(list)


# --- face editing -----------------------------------------------------------

## Faces that face operations (material, inspector, align) act on: the face
## selection in face mode, otherwise all faces of the selected brushes.
## Array of [TFBrush, face_index], only faces that exist geometrically.
func target_faces() -> Array:
	prune_faces()
	var result: Array = []
	if face_mode:
		for entry in selected_faces:
			if (entry[0] as TFBrush).get_polyhedron().is_face_used(entry[1]):
				result.append(entry)
		return result
	for brush in selected_brushes():
		var poly := brush.get_polyhedron()
		for i in brush.faces.size():
			if brush.faces[i] != null and poly.is_face_used(i):
				result.append([brush, i])
	return result


## Applies fn(face_copy: TFFace, brush: TFBrush, face_index: int) to copies of
## the given faces and records everything as one undo action.
func modify_faces(action_name: String, targets: Array, fn: Callable) -> void:
	if targets.is_empty():
		return
	var brushes: Array = []
	var old_faces: Array = []
	var new_faces: Array = []
	for entry in targets:
		var brush: TFBrush = entry[0]
		var i := brushes.find(brush)
		if i == -1:
			brushes.append(brush)
			old_faces.append(TFUndo.snapshot_faces(brush))
			new_faces.append(TFUndo.copy_faces(brush.faces))
			i = brushes.size() - 1
		fn.call(new_faces[i][entry[1]], brush, entry[1])
	TFUndo.commit_many_faces(undo_redo(), action_name, brushes, old_faces, new_faces)


## Sets the material on the target faces and remembers it for new brushes.
func apply_material(material: Material) -> void:
	face_fill_hidden = face_mode and not selected_faces.is_empty()
	current_material = material
	modify_faces(TFI18n.action("Set material"), target_faces(), func(face: TFFace, _brush: TFBrush, _index: int) -> void:
		face.material = material)


# --- helpers ----------------------------------------------------------------

func request_tool(tool_name: String) -> void:
	tool_requested.emit(tool_name)


func update_overlays() -> void:
	plugin.update_overlays()
