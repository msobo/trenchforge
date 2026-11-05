class_name TFPicking
extends RefCounted
## Ray picking against brushes (world space). Backfaces are ignored, so rays
## starting inside a brush pass through it.


## Returns {} on miss, otherwise {brush, face_index, t, position, normal}
## with position and normal in world space.
static func pick(brushes: Array[TFBrush], origin: Vector3, direction: Vector3) -> Dictionary:
	var best := {}
	var best_t := INF
	for brush in brushes:
		if not brush.is_visible_in_tree() or brush.is_editor_hidden() or not brush.is_valid():
			continue
		var xf := brush.global_transform
		var inverse := xf.affine_inverse()
		var local_origin := inverse * origin
		# Untransformed parameter t stays valid because the direction is
		# transformed linearly (not normalized).
		var local_direction := inverse.basis * direction
		var box := brush.get_local_aabb().grow(TFConst.EPSILON)
		if not box.has_point(local_origin) and box.intersects_ray(local_origin, local_direction) == null:
			continue
		var hit := TFGeometry.ray_intersect_brush(brush.get_planes(), local_origin, local_direction)
		if hit.is_empty() or hit["t"] >= best_t:
			continue
		best_t = hit["t"]
		var local_normal: Vector3 = hit["normal"]
		best = {
			"brush": brush,
			"face_index": hit["face_index"],
			"t": best_t,
			"position": origin + direction * best_t,
			"normal": (xf.basis.inverse().transposed() * local_normal).normalized(),
		}
	return best


## World-space polygon of a brush face.
static func face_world_polygon(brush: TFBrush, face_index: int) -> PackedVector3Array:
	var poly := brush.get_polyhedron()
	var result := PackedVector3Array()
	if not poly.is_face_used(face_index):
		return result
	var xf := brush.global_transform
	for v in poly.get_face_vertices(face_index):
		result.append(xf * v)
	return result


## World-space AABB enclosing all given brushes.
static func brushes_aabb(brushes: Array[TFBrush]) -> AABB:
	var result := AABB()
	var first := true
	for brush in brushes:
		var box := brush.global_transform * brush.get_local_aabb()
		if first:
			result = box
			first = false
		else:
			result = result.merge(box)
	return result
