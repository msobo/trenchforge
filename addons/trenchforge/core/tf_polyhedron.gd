class_name TFPolyhedron
extends RefCounted
## Derived boundary representation of a convex brush.
##
## Built from planes by TFGeometry.planes_to_polyhedron(). Never serialized.

## Unique vertices in brush-local space.
var vertices: PackedVector3Array = PackedVector3Array()
## Per input plane: vertex indices of its polygon, counter-clockwise when
## viewed from outside. Empty for redundant planes.
var face_polygons: Array[PackedInt32Array] = []
## Unique edges as pairs of vertex indices (Vector2i(a, b) with a < b).
var edges: Array[Vector2i] = []


func face_count() -> int:
	var count := 0
	for polygon in face_polygons:
		if polygon.size() >= 3:
			count += 1
	return count


func is_face_used(plane_index: int) -> bool:
	return plane_index < face_polygons.size() and face_polygons[plane_index].size() >= 3


func get_face_vertices(plane_index: int) -> PackedVector3Array:
	var result := PackedVector3Array()
	for index in face_polygons[plane_index]:
		result.append(vertices[index])
	return result


func get_aabb() -> AABB:
	if vertices.is_empty():
		return AABB()
	var box := AABB(vertices[0], Vector3.ZERO)
	for v in vertices:
		box = box.expand(v)
	return box


## Volume as pyramids from the vertex centroid over every face. Relative to
## an interior point, small topology errors from float noise (near-duplicate
## vertices of almost coplanar planes) only cause small volume errors; the
## plain divergence sum around the origin would amplify them with the
## distance from the origin.
func get_volume() -> float:
	if vertices.is_empty():
		return 0.0
	var center := Vector3.ZERO
	for v in vertices:
		center += v
	center /= float(vertices.size())
	var volume := 0.0
	for polygon in face_polygons:
		if polygon.size() < 3:
			continue
		var a := vertices[polygon[0]] - center
		for i in range(1, polygon.size() - 1):
			volume += absf(a.dot((vertices[polygon[i]] - center).cross(vertices[polygon[i + 1]] - center)))
	return volume / 6.0


func is_valid() -> bool:
	return face_count() >= 4 and get_volume() > TFConst.MIN_VOLUME
