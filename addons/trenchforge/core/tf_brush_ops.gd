class_name TFBrushOps
extends RefCounted
## Pure brush operations that return new face arrays instead of mutating, so
## tools can preview them and record undo snapshots.


## Index of the face whose normal matches the given (brush-local) normal,
## or -1.
static func find_face_by_normal(faces: Array[TFFace], normal: Vector3) -> int:
	var n := normal.normalized()
	for i in faces.size():
		if faces[i] != null and faces[i].plane.normal.normalized().dot(n) > 1.0 - 1e-3:
			return i
	return -1


## Moves one face along its normal by delta. Returns copies of all faces, or
## an empty array if the brush would become invalid.
static func resize_face(faces: Array[TFFace], face_index: int, delta: float) -> Array[TFFace]:
	var result := TFUndo.copy_faces(faces)
	var face := result[face_index]
	face.plane = Plane(face.plane.normal, face.plane.d + delta * face.plane.normal.length())
	var poly := TFGeometry.planes_to_polyhedron(_planes_of(result))
	# The moved face must still exist, otherwise it vanished behind others.
	if not poly.is_valid() or not poly.is_face_used(face_index):
		var empty: Array[TFFace] = []
		return empty
	return result


## Faces of a new brush (same local space) that extrudes one face along its
## normal by distance: a prism over the face polygon. Index 0 is the cap with
## the attributes of the face; side faces continue a coplanar neighbor (same
## UVs) or take the neighbor's attributes with fresh axes. Returns an empty
## array for distance <= EPSILON or an invalid result.
static func extrude_face(faces: Array[TFFace], face_index: int, distance: float) -> Array[TFFace]:
	var empty: Array[TFFace] = []
	if distance <= TFConst.EPSILON or face_index < 0 or face_index >= faces.size() or faces.has(null):
		return empty
	var poly := TFGeometry.planes_to_polyhedron(_planes_of(faces))
	if not poly.is_valid() or not poly.is_face_used(face_index):
		return empty
	var source := faces[face_index]
	var normal := source.plane.normal.normalized()
	var d := source.plane.d / source.plane.normal.length()
	var cap := source.copy()
	cap.plane = Plane(normal, d + distance)
	var back := source.copy()
	back.plane = Plane(-normal, -d)
	back.reset_uv_axes()
	var result: Array[TFFace] = [cap, back]
	var polygon := poly.face_polygons[face_index]
	var sides := prism_side_planes(poly, face_index, normal)
	for i in polygon.size():
		var side := sides[i]
		var neighbor := _face_with_edge(poly, polygon[i], polygon[(i + 1) % polygon.size()], face_index)
		var face := (faces[neighbor] if neighbor != -1 else source).copy()
		var coplanar := neighbor != -1 and TFGeometry.planes_equal(_unit_plane(face.plane), side)
		face.plane = side
		if not coplanar:
			face.reset_uv_axes()
		result.append(face)
	var check := TFGeometry.planes_to_polyhedron(_planes_of(result))
	if not check.is_valid() or check.face_count() != result.size():
		return empty
	return result


## Moves the vertices at the given brush-local positions by delta and rebuilds
## the brush as the convex hull of all vertices (see TFHull). Returns {} if
## nothing moved or the result is invalid, otherwise {faces, lost}: lost counts
## moved vertices that ended up inside the hull and vanished.
static func move_vertices(faces: Array[TFFace], positions: PackedVector3Array, delta: Vector3) -> Dictionary:
	var poly := TFGeometry.planes_to_polyhedron(_planes_of(faces))
	if faces.has(null) or not poly.is_valid():
		return {}
	var points := PackedVector3Array()
	var moved := PackedVector3Array()
	for v in poly.vertices:
		if TFHull.find_point(positions, v) != -1:
			moved.append(TFHull.clean_point(v + delta))
			points.append(moved[-1])
		else:
			points.append(v)
	if moved.is_empty():
		return {}
	var planes := TFHull.compute_planes(points)
	var result := TFGeometry.planes_to_polyhedron(planes)
	if not result.is_valid():
		return {}
	var sources: Array[TFFace] = []
	for i in faces.size():
		if poly.is_face_used(i):
			sources.append(faces[i])
	var lost := 0
	for p in moved:
		if TFHull.find_point(result.vertices, p) == -1:
			lost += 1
	var new_faces := TFHull.faces_for_hull(planes, sources)
	if new_faces.is_empty():
		return {}
	return {"faces": new_faces, "lost": lost}


## Rotates a brush around a pivot (parent space) by a basis. Returns
## [new_faces, new_position]. Plane distances are unchanged because the
## brush origin rotates together with its planes.
##
## With texture_lock the UV axes rotate along and the offset is compensated
## (map_offset translates parent space into map space). Without it the faces
## get box-projection axes for their new normals (world-fixed UVs).
static func rotate_brush(faces: Array[TFFace], position: Vector3, pivot: Vector3, rotation: Basis, texture_lock: bool = true, map_offset: Vector3 = Vector3.ZERO, ppm: float = TFConst.DEFAULT_PIXELS_PER_METER) -> Array:
	var result := TFUndo.copy_faces(faces)
	for face in result:
		if face == null:
			continue
		var old_axes := TFUV.rotated_axes(face)
		face.plane = Plane((rotation * face.plane.normal).normalized(), face.plane.d)
		if texture_lock:
			face.u_axis = rotation * face.u_axis
			face.v_axis = rotation * face.v_axis
			TFUV.lock_rotation(face, old_axes, rotation, pivot + map_offset, ppm)
		else:
			face.reset_uv_axes()
	return [result, pivot + rotation * (position - pivot)]


## Copies of the faces with offsets compensated for a map-space translation
## (texture lock). Without lock nothing changes because UVs are world-fixed.
static func translate_texture_lock(faces: Array[TFFace], map_delta: Vector3, ppm: float) -> Array[TFFace]:
	var result := TFUndo.copy_faces(faces)
	for face in result:
		if face != null:
			TFUV.lock_translation(face, map_delta, ppm)
	return result


## Outward side planes of the prism over a face polygon along its unit
## normal, one per polygon edge in polygon order. inset moves them inward
## (the prism over the polygon shrunk by inset).
static func prism_side_planes(poly: TFPolyhedron, face_index: int, normal: Vector3, inset: float = 0.0) -> Array[Plane]:
	var result: Array[Plane] = []
	var polygon := poly.face_polygons[face_index]
	for i in polygon.size():
		var a := poly.vertices[polygon[i]]
		var b := poly.vertices[polygon[(i + 1) % polygon.size()]]
		# Polygons are counter-clockwise from outside: (b - a) × n points out.
		var side := Plane((b - a).cross(normal).normalized(), a)
		result.append(Plane(side.normal, side.d - inset))
	return result


# Index of the face other than skip whose polygon contains the edge a-b, or -1.
static func _face_with_edge(poly: TFPolyhedron, a: int, b: int, skip: int) -> int:
	for i in poly.face_polygons.size():
		if i != skip and poly.face_polygons[i].has(a) and poly.face_polygons[i].has(b):
			return i
	return -1


static func _unit_plane(plane: Plane) -> Plane:
	var length := plane.normal.length()
	return Plane(plane.normal / length, plane.d / length) if length > 0.0 else plane


static func _planes_of(faces: Array[TFFace]) -> Array[Plane]:
	var planes: Array[Plane] = []
	for face in faces:
		planes.append(face.plane if face != null else Plane())
	return planes
