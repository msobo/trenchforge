class_name TFShapeParams
extends RefCounted
## Editable parameters of builder shapes after creation. The shape tool stores
## what the geometry cannot tell (TFConst.META_SHAPE): the cylinder axis and
## side count on the brush, the stair directions and step count on the stairs
## group, the path (group-local), radius and bends on the pipe compound. The
## box of cylinders and stairs is not stored, it is the bounds of the shape;
## so moving and resizing keep a shape editable. A pipe's path follows its
## pieces (the select tool moves them, not the compound) and resizing a pipe
## stretches its path (stretch_pipe()); a wall's path follows its pieces the
## same way. A shape only counts as parametric while
## rebuilding it from its parameters and bounds gives exactly its planes; any
## other edit (vertex edit, clip, bevel, moving a single step) turns it into
## plain brushes again, whatever the metadata says.

const TYPE_CYLINDER := "cylinder"
const TYPE_STAIRS := "stairs"
const TYPE_PIPE := "pipe"
const TYPE_WALL := "wall"
const TYPE_BRIDGE := "bridge"
## Smallest radius and height the parameters accept.
const MIN_SIZE: float = 0.01


static func cylinder_meta(axis_index: int, sides: int) -> Dictionary:
	return {"type": TYPE_CYLINDER, "axis": axis_index, "sides": sides}


static func stairs_meta(up: Vector3, forward: Vector3, steps: int) -> Dictionary:
	return {"type": TYPE_STAIRS, "up": up, "forward": forward, "steps": steps}


static func pipe_meta(points: PackedVector3Array, radius: float, sides: int, bend_radius: float, bend_segments: int) -> Dictionary:
	return {"type": TYPE_PIPE, "points": points, "radius": radius, "sides": sides,
		"bend_radius": bend_radius, "bend_segments": bend_segments}


static func wall_meta(points: PackedVector3Array, up: Vector3, thickness: float, height: float, closed: bool) -> Dictionary:
	return {"type": TYPE_WALL, "points": points, "up": up, "thickness": thickness, "height": height, "closed": closed}


## Bridge metadata: both loops as one point list ("points", loop A first,
## "count_a" points), their normals and the TFBridge parameters.
static func bridge_meta(loop_a: PackedVector3Array, normal_a: Vector3, loop_b: PackedVector3Array, normal_b: Vector3, params: Dictionary) -> Dictionary:
	var meta := TFBridge.normalized_params(params)
	meta["type"] = TYPE_BRIDGE
	meta["points"] = loop_a + loop_b
	meta["count_a"] = loop_a.size()
	meta["normal_a"] = normal_a
	meta["normal_b"] = normal_b
	return meta


## Plane sets of a bridge from its metadata (or bridge_params()); empty if
## it cannot be built.
static func bridge_sets(meta: Dictionary) -> Array:
	var points: PackedVector3Array = meta["points"]
	var count_a: int = meta["count_a"]
	var result := TFBridge.bridge(points.slice(0, count_a), meta["normal_a"], points.slice(count_a), meta["normal_b"], meta)
	return result.get("sets", [])


## Parameters of a parametric cylinder brush: the metadata plus "box" (brush-
## local bounds), "radius" (half the larger extent across the axis) and
## "height". Empty if the brush is no (longer a) cylinder.
static func cylinder_params(brush: TFBrush) -> Dictionary:
	var meta := _meta(brush, TYPE_CYLINDER)
	if meta.is_empty() or not brush.is_valid():
		return {}
	var axis_index: int = meta.get("axis", -1)
	var sides: int = meta.get("sides", 0)
	if axis_index < 0 or axis_index > 2 or sides < TFShapes.MIN_SIDES or sides > TFShapes.MAX_SIDES:
		return {}
	var box := brush.get_local_aabb()
	if not planes_match(TFShapes.cylinder_planes(box, axis_index, sides), brush.get_planes()):
		return {}
	var u := (axis_index + 1) % 3
	var v := (axis_index + 2) % 3
	return {
		"type": TYPE_CYLINDER,
		"axis": axis_index,
		"sides": sides,
		"box": box,
		"radius": maxf(box.size[u], box.size[v]) * 0.5,
		"height": box.size[axis_index],
	}


## New faces (brush-local) of the cylinder with the changed parameters
## ("radius", "height", "sides"; missing ones stay). Radius and height scale
## the box around its center, an elliptic base keeps its aspect ratio.
## Material and UVs carry over (TFHull.transfer_faces()). Empty if the brush
## is not parametric.
static func rebuild_cylinder(brush: TFBrush, changes: Dictionary) -> Array[TFFace]:
	var result: Array[TFFace] = []
	var params := cylinder_params(brush)
	if params.is_empty():
		return result
	var axis_index: int = params["axis"]
	var box: AABB = params["box"]
	var center := box.get_center()
	var size := box.size
	var scale := maxf(float(changes.get("radius", params["radius"])), MIN_SIZE) / float(params["radius"])
	for k in 3:
		if k != axis_index:
			size[k] *= scale
	size[axis_index] = maxf(float(changes.get("height", params["height"])), MIN_SIZE)
	var sides := clampi(int(changes.get("sides", params["sides"])), TFShapes.MIN_SIDES, TFShapes.MAX_SIDES)
	var planes := TFShapes.cylinder_planes(AABB(center - size * 0.5, size), axis_index, sides)
	if planes.is_empty():
		return result
	return TFHull.transfer_faces(planes, brush.faces)


## Brushes of a stairs group, pipe or wall compound (direct children).
static func group_brushes(group: Node) -> Array[TFBrush]:
	var result: Array[TFBrush] = []
	for child in group.get_children():
		if child is TFBrush:
			result.append(child)
	return result


## Parameters of a parametric stairs group: the metadata plus "box" (group-
## local bounds of all steps). Empty if the group is no (longer a) staircase
## built from them: every child must be a brush and the steps must match
## TFShapes.stair_boxes() exactly.
static func stairs_params(group: Node) -> Dictionary:
	var meta := _meta(group, TYPE_STAIRS)
	if meta.is_empty() or not group is Node3D:
		return {}
	var up: Vector3 = meta.get("up", Vector3.ZERO)
	var forward: Vector3 = meta.get("forward", Vector3.ZERO)
	var steps: int = meta.get("steps", 0)
	var brushes := group_brushes(group)
	if steps < 1 or brushes.size() != steps or group.get_child_count() != steps:
		return {}
	if not TFSnap.is_axis_aligned(up) or not TFSnap.is_axis_aligned(forward) or TFSnap.axis_index(up) == TFSnap.axis_index(forward):
		return {}
	var box := AABB()
	for i in brushes.size():
		if not brushes[i].is_valid():
			return {}
		var bounds := brushes[i].get_local_aabb()
		bounds.position += brushes[i].position
		box = bounds if i == 0 else box.merge(bounds)
	var sets: Array = []
	for step in TFShapes.stair_boxes(box, up, forward, steps):
		sets.append(TFShapes.box_planes(step))
	if not _sets_match(sets, brushes):
		return {}
	return {"type": TYPE_STAIRS, "up": up, "forward": forward, "steps": steps, "box": box}


## Plane sets (group-local) of the steps with the changed parameters
## ("steps"; "turns": quarter turns of the climbing direction around up,
## counter-clockwise), plus "forward" (the new direction). Empty if the
## group is not parametric.
static func rebuild_stairs(group: Node, changes: Dictionary) -> Dictionary:
	var params := stairs_params(group)
	if params.is_empty():
		return {}
	var up: Vector3 = params["up"]
	var forward: Vector3 = params["forward"]
	var turns := posmod(int(changes.get("turns", 0)), 4)
	if turns != 0:
		forward = TFSnap.dominant_axis(forward.rotated(up, float(turns) * PI * 0.5))
	var steps := clampi(int(changes.get("steps", params["steps"])), 1, TFShapes.MAX_STEPS)
	var sets: Array = []
	for step in TFShapes.stair_boxes(params["box"], up, forward, steps):
		sets.append(TFShapes.box_planes(step))
	return {"sets": sets, "forward": forward, "steps": steps, "up": up}


## Parameters of a parametric pipe compound: its metadata, with the path
## moved along with the pieces (moving them leaves the compound and its
## metadata behind). Empty if the compound is no (longer a) pipe: every child
## must be a brush and each piece of TFShapes.pipe_sets() must be one of them.
static func pipe_params(group: Node) -> Dictionary:
	var meta := _meta(group, TYPE_PIPE)
	if meta.is_empty() or not group is Node3D:
		return {}
	var points: Variant = meta.get("points")
	if not points is PackedVector3Array:
		return {}
	var brushes := group_brushes(group)
	if brushes.is_empty() or brushes.size() != group.get_child_count():
		return {}
	var params := {
		"type": TYPE_PIPE,
		"points": points,
		"radius": float(meta.get("radius", 0.0)),
		"sides": int(meta.get("sides", 0)),
		"bend_radius": float(meta.get("bend_radius", 0.0)),
		"bend_segments": int(meta.get("bend_segments", 0)),
	}
	return _follow_pieces(params, _pipe_sets(params), brushes)


## Plane sets (group-local) of the pipe with the changed parameters
## ("radius", "sides", "bend_radius", "bend_segments"), plus "meta" (the new
## metadata). Empty if the group is not parametric or the pipe no longer fits
## its path (e.g. a radius too large for a short run).
static func rebuild_pipe(group: Node, changes: Dictionary) -> Dictionary:
	var params := pipe_params(group)
	if params.is_empty():
		return {}
	params["radius"] = maxf(float(changes.get("radius", params["radius"])), MIN_SIZE)
	params["sides"] = clampi(int(changes.get("sides", params["sides"])), TFShapes.MIN_SIDES, TFShapes.MAX_SIDES)
	params["bend_radius"] = maxf(float(changes.get("bend_radius", params["bend_radius"])), 0.0)
	params["bend_segments"] = clampi(int(changes.get("bend_segments", params["bend_segments"])), 0, TFShapes.MAX_BEND_SEGMENTS)
	return _pipe_result(params)


## Plane sets (group-local) and "meta" of the pipe stretched like a resized
## face: every path point at or beyond the face at coordinate at along axis
## (a group-local unit axis; points within one radius before it count, so a
## side face takes its run along) moves by delta along axis. Dragging an end
## cap changes the length of the end run, dragging a side moves the run and
## stretches its neighbors. params is pipe_params() of the pipe before the
## drag (a live preview changes the pieces). Empty if nothing or everything
## would move, a run would vanish or flip, or the path no longer carries the
## pipe (a run too short for its corners).
static func stretch_pipe(params: Dictionary, axis: Vector3, at: float, delta: float) -> Dictionary:
	params = params.duplicate()
	var old: PackedVector3Array = params["points"]
	var points := old.duplicate()
	var limit := at - float(params["radius"]) - TFConst.EPSILON
	var moved := 0
	for k in points.size():
		if axis.dot(points[k]) >= limit:
			points[k] += axis * delta
			moved += 1
	if moved == 0 or moved == points.size():
		return {}
	# A run must keep its direction (no collapsing or flipping past a corner).
	for k in points.size() - 1:
		if (points[k + 1] - points[k]).dot((old[k + 1] - old[k]).normalized()) < TFConst.EPSILON:
			return {}
	params["points"] = TFShapes.pipe_path(points)
	return _pipe_result(params)


## Parameters of a parametric wall compound: its metadata, with the path
## moved along with the pieces. Empty if the compound is no (longer a) wall:
## every child must be a brush and each piece of TFShapes.wall_sets() must be
## one of them.
static func wall_params(group: Node) -> Dictionary:
	var meta := _meta(group, TYPE_WALL)
	if meta.is_empty() or not group is Node3D:
		return {}
	var points: Variant = meta.get("points")
	var up: Variant = meta.get("up")
	if not points is PackedVector3Array or not up is Vector3:
		return {}
	var brushes := group_brushes(group)
	if brushes.is_empty() or brushes.size() != group.get_child_count():
		return {}
	var params := {
		"type": TYPE_WALL,
		"points": points,
		"up": up,
		"thickness": float(meta.get("thickness", 0.0)),
		"height": float(meta.get("height", 0.0)),
		"closed": bool(meta.get("closed", false)),
	}
	return _follow_pieces(params, _wall_sets(params), brushes)


## Plane sets (group-local) of the wall with the changed parameters
## ("thickness", "height"), plus "meta" (the new metadata). The piece count
## stays the same. Empty if the group is not parametric or a run is too short
## for the new thickness.
static func rebuild_wall(group: Node, changes: Dictionary) -> Dictionary:
	var params := wall_params(group)
	if params.is_empty():
		return {}
	params["thickness"] = maxf(float(changes.get("thickness", params["thickness"])), MIN_SIZE)
	params["height"] = maxf(float(changes.get("height", params["height"])), MIN_SIZE)
	var sets := _wall_sets(params)
	if sets.is_empty():
		return {}
	return {"sets": sets, "meta": wall_meta(params["points"], params["up"], params["thickness"], params["height"], params["closed"])}


## Parameters of a parametric bridge compound: its metadata, with the loops
## moved along with the pieces. Empty if the compound is no (longer a)
## bridge: every child must be a brush and each piece one of them.
static func bridge_params(group: Node) -> Dictionary:
	var meta := _meta(group, TYPE_BRIDGE)
	if meta.is_empty() or not group is Node3D:
		return {}
	var points: Variant = meta.get("points")
	var count_a: int = meta.get("count_a", 0)
	if not points is PackedVector3Array or count_a < 3 or (points as PackedVector3Array).size() - count_a < 3:
		return {}
	if not meta.get("normal_a") is Vector3 or not meta.get("normal_b") is Vector3:
		return {}
	var brushes := group_brushes(group)
	if brushes.is_empty() or brushes.size() != group.get_child_count():
		return {}
	var params := TFBridge.normalized_params(meta)
	params["type"] = TYPE_BRIDGE
	params["points"] = points
	params["count_a"] = count_a
	params["normal_a"] = meta["normal_a"]
	params["normal_b"] = meta["normal_b"]
	return _follow_pieces(params, bridge_sets(params), brushes)


## Plane sets (group-local) of the bridge with the changed parameters (keys
## of TFBridge.DEFAULTS), plus "meta" (the new metadata). Empty if the group
## is not parametric or the bridge folds with the new parameters.
static func rebuild_bridge(group: Node, changes: Dictionary) -> Dictionary:
	var params := bridge_params(group)
	if params.is_empty():
		return {}
	for key: String in TFBridge.DEFAULTS:
		if changes.has(key):
			params[key] = changes[key]
	params = TFBridge.normalized_params(params)
	var sets := bridge_sets(params)
	if sets.is_empty():
		return {}
	var points: PackedVector3Array = params["points"]
	var count_a: int = params["count_a"]
	return {"sets": sets, "meta": bridge_meta(points.slice(0, count_a), params["normal_a"], points.slice(count_a), params["normal_b"], params)}


static func _wall_sets(params: Dictionary) -> Array:
	return TFShapes.wall_sets(params["points"], params["up"], params["closed"], params["thickness"], params["height"])


## params (with "points") if the plane sets, moved like the brushes were
## moved (bounds offset), are exactly the brushes; the points move along.
## Empty otherwise.
static func _follow_pieces(params: Dictionary, sets: Array, brushes: Array[TFBrush]) -> Dictionary:
	if sets.is_empty():
		return {}
	var box := AABB()
	for i in brushes.size():
		if not brushes[i].is_valid():
			return {}
		var bounds := brushes[i].get_local_aabb()
		bounds.position += brushes[i].position
		box = bounds if i == 0 else box.merge(bounds)
	var offset := box.position - _sets_bounds(sets).position
	if not offset.is_zero_approx():
		var moved := PackedVector3Array()
		for p: Vector3 in params["points"]:
			moved.append(p + offset)
		params["points"] = moved
		for i in sets.size():
			sets[i] = _offset_planes(sets[i], offset)
	if not _sets_match(sets, brushes):
		return {}
	return params


static func _pipe_result(params: Dictionary) -> Dictionary:
	var sets := _pipe_sets(params)
	if sets.is_empty():
		return {}
	return {"sets": sets, "meta": pipe_meta(params["points"], params["radius"], params["sides"], params["bend_radius"], params["bend_segments"])}


static func _pipe_sets(params: Dictionary) -> Array:
	return TFShapes.pipe_sets(params["points"], params["radius"], params["sides"], params["bend_radius"], params["bend_segments"])


## Bounds of plane sets (all in the same space).
static func _sets_bounds(sets: Array) -> AABB:
	var box := AABB()
	for i in sets.size():
		var bounds := TFGeometry.planes_to_polyhedron(sets[i]).get_aabb()
		box = bounds if i == 0 else box.merge(bounds)
	return box


## True if every plane set (group space) is one of the brushes (any order)
## and no brush is left over.
static func _sets_match(sets: Array, brushes: Array[TFBrush]) -> bool:
	if sets.size() != brushes.size() or sets.is_empty():
		return false
	var unmatched := brushes.duplicate()
	for planes: Array[Plane] in sets:
		var found: TFBrush = null
		for brush: TFBrush in unmatched:
			if brush.is_valid() and planes_match(_offset_planes(planes, -brush.position), brush.get_planes()):
				found = brush
				break
		if found == null:
			return false
		unmatched.erase(found)
	return true


## Faces for the pieces of rebuild_stairs()/rebuild_pipe()/rebuild_wall()
## (planes in group space) relative to origins[i]; piece i inherits material
## and UVs from the old faces with the same index (the last ones for added
## pieces).
static func group_faces(sets: Array, origins: Array, old_faces: Array) -> Array:
	var result: Array = []
	for i in sets.size():
		var planes := _offset_planes(sets[i], -origins[i])
		var source: Array[TFFace] = old_faces[mini(i, old_faces.size() - 1)]
		result.append(TFHull.transfer_faces(planes, source))
	return result


## True if both plane sets contain the same planes (any order, normals of
## any length).
static func planes_match(a: Array[Plane], b: Array[Plane]) -> bool:
	if a.size() != b.size() or a.is_empty():
		return false
	var unmatched: Array[Plane] = []
	for plane in b:
		unmatched.append(_normalized(plane))
	for plane in a:
		var found := -1
		var normalized := _normalized(plane)
		for k in unmatched.size():
			if TFGeometry.planes_equal(normalized, unmatched[k]):
				found = k
				break
		if found == -1:
			return false
		unmatched.remove_at(found)
	return true


static func _meta(node: Node, type: String) -> Dictionary:
	if node == null or not node.has_meta(TFConst.META_SHAPE):
		return {}
	var meta: Variant = node.get_meta(TFConst.META_SHAPE)
	if not meta is Dictionary or (meta as Dictionary).get("type", "") != type:
		return {}
	return meta


static func _normalized(plane: Plane) -> Plane:
	var length := plane.normal.length()
	return Plane(plane.normal / length, plane.d / length) if length > 0.0 else plane


## The planes moved by offset.
static func _offset_planes(planes: Array[Plane], offset: Vector3) -> Array[Plane]:
	var result: Array[Plane] = []
	for plane in planes:
		result.append(Plane(plane.normal, plane.d + plane.normal.dot(offset)))
	return result
