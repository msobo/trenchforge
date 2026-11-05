class_name TFHull
extends RefCounted
## Convex hull of a point set as brush planes, plus the face attribute
## transfer used when a brush is rebuilt from new planes (vertex edit, merge).
##
## Brushes have few vertices, so the hull searches its faces directly: every
## point triple spans a candidate plane, which is a hull face if no point lies
## in front of it. Coplanar points form one face polygon, so non-planar faces
## cannot occur (a quad that bends is split into two faces automatically).


## Hull planes (normals outward) of the points, or an empty array if the
## points span no volume. Points closer than EPSILON are merged.
static func compute_planes(points: PackedVector3Array) -> Array[Plane]:
	var result: Array[Plane] = []
	var pts := unique_points(points)
	var n := pts.size()
	if n < 4:
		return result
	var center := Vector3.ZERO
	for p in pts:
		center += p
	center /= float(n)

	var groups: Array[PackedInt32Array] = []
	for i in n:
		for j in range(i + 1, n):
			for k in range(j + 1, n):
				if _in_one_group(groups, i, j, k):
					continue
				var candidate: Variant = _plane_through(pts[i], pts[j], pts[k], center)
				if candidate == null:
					continue
				var on_plane := _support(pts, candidate)
				if on_plane.is_empty():
					continue
				# A thin candidate triangle gives an imprecise normal; refit the
				# plane to the largest triangle of the face and collect again.
				var refined: Variant = _best_plane(pts, on_plane, center)
				if refined == null:
					continue
				on_plane = _support(pts, refined)
				if on_plane.size() < 3 or _is_covered(groups, on_plane):
					continue
				groups.append(on_plane)
				result.append(refined)
	_merge_near_coplanar(result, groups)
	if result.size() < 4 or not TFGeometry.planes_to_polyhedron(result).is_valid():
		result.clear()
	return result


## Faces for hull planes (see transfer_faces()). If keeping the exact source
## planes would make the brush invalid (they are only equal within epsilon),
## the hull planes are used instead. Empty if no valid brush results.
static func faces_for_hull(planes: Array[Plane], sources: Array[TFFace]) -> Array[TFFace]:
	var faces := transfer_faces(planes, sources)
	if TFGeometry.planes_to_polyhedron(TFCSG.planes_of(faces)).is_valid():
		return faces
	for i in faces.size():
		faces[i].plane = planes[i]
	if TFGeometry.planes_to_polyhedron(TFCSG.planes_of(faces)).is_valid():
		return faces
	faces.clear()
	return faces


# Drops the smaller of two (nearly) identical hull faces (in place).
static func _merge_near_coplanar(planes: Array[Plane], groups: Array[PackedInt32Array]) -> void:
	var i := 0
	while i < planes.size():
		var j := i + 1
		while j < planes.size():
			# planes_to_polyhedron() would treat planes_equal() ones as one plane
			# while their faces still diverge slightly.
			var near := 1.0 - planes[i].normal.dot(planes[j].normal) <= TFConst.COPLANAR_NORMAL_EPSILON and absf(planes[i].d - planes[j].d) <= TFConst.COPLANAR_DISTANCE
			if near or TFGeometry.planes_equal(planes[i], planes[j]):
				var drop := j if groups[i].size() >= groups[j].size() else i
				planes.remove_at(drop)
				groups.remove_at(drop)
				if drop == i:
					j = i + 1
					continue
			else:
				j += 1
		i += 1


## Points with near-duplicates (closer than EPSILON) removed, coordinates
## cleaned of float drift (see clean_point()).
static func unique_points(points: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	for p in points:
		var cleaned := clean_point(p)
		if find_point(result, cleaned) == -1:
			result.append(cleaned)
	return result


## Rounds coordinates that lie within EPSILON of a multiple of
## TFConst.VERTEX_CLEAN_STEP onto it; other coordinates stay untouched.
static func clean_point(p: Vector3) -> Vector3:
	var result := p
	for i in 3:
		var rounded := snappedf(p[i], TFConst.VERTEX_CLEAN_STEP)
		if absf(rounded - p[i]) <= TFConst.EPSILON:
			result[i] = rounded
	return result


## Index of the point within EPSILON of p, or -1.
static func find_point(points: PackedVector3Array, p: Vector3) -> int:
	for i in points.size():
		if points[i].distance_squared_to(p) <= TFConst.EPSILON * TFConst.EPSILON:
			return i
	return -1


## New faces for the planes. A plane equal to a source plane keeps that face
## unchanged; any other plane inherits material, flags and UV attributes from
## the source face with the most similar normal (ties: closest distance).
## Box-projected UVs get axes for the new normal, offset and scale stay.
static func transfer_faces(planes: Array[Plane], sources: Array[TFFace]) -> Array[TFFace]:
	var result: Array[TFFace] = []
	for plane in planes:
		var best: TFFace = null
		var best_dot := -INF
		var best_distance := INF
		var exact: TFFace = null
		for source in sources:
			var source_plane := Plane(source.plane.normal.normalized(), source.plane.d / source.plane.normal.length())
			if TFGeometry.planes_equal(source_plane, plane):
				exact = source
				break
			var dot := source_plane.normal.dot(plane.normal)
			var distance := absf(source_plane.d - plane.d)
			if dot > best_dot + TFConst.NORMAL_EPSILON or (dot >= best_dot - TFConst.NORMAL_EPSILON and distance < best_distance):
				best = source
				best_dot = dot
				best_distance = distance
		if exact != null:
			result.append(exact.copy())
		elif best != null:
			var face := TFFace.create(plane, best.material)
			face.flags = best.flags
			TFUV.copy_attributes(best, face)
			result.append(face)
		else:
			result.append(TFFace.create(plane))
	return result


# Plane through a, b, c facing away from center; null if (almost) collinear.
static func _plane_through(a: Vector3, b: Vector3, c: Vector3, center: Vector3) -> Variant:
	var base := b - a
	var normal := base.cross(c - a)
	# |normal| / |base| is the distance of c from the line a-b.
	if normal.length() <= TFConst.EPSILON * base.length():
		return null
	var plane := Plane(normal.normalized(), a)
	if plane.distance_to(center) > 0.0:
		plane = -plane
	return plane


# Indices of the points on the plane, or empty if any point is in front.
static func _support(pts: PackedVector3Array, plane: Plane) -> PackedInt32Array:
	var on_plane := PackedInt32Array()
	for i in pts.size():
		var distance := plane.distance_to(pts[i])
		if distance > TFConst.PLANE_EPSILON:
			return PackedInt32Array()
		if distance >= -TFConst.PLANE_EPSILON:
			on_plane.append(i)
	return on_plane


# Plane through the largest-area triangle of the given points (most stable).
static func _best_plane(pts: PackedVector3Array, indices: PackedInt32Array, center: Vector3) -> Variant:
	var m := indices.size()
	var best_area := -1.0
	var best := [0, 0, 0]
	for a in m:
		for b in range(a + 1, m):
			for c in range(b + 1, m):
				var area := (pts[indices[b]] - pts[indices[a]]).cross(pts[indices[c]] - pts[indices[a]]).length_squared()
				if area > best_area:
					best_area = area
					best = [indices[a], indices[b], indices[c]]
	return _plane_through(pts[best[0]], pts[best[1]], pts[best[2]], center)


static func _in_one_group(groups: Array[PackedInt32Array], i: int, j: int, k: int) -> bool:
	for group in groups:
		if group.has(i) and group.has(j) and group.has(k):
			return true
	return false


# True if an existing face already contains all of the points.
static func _is_covered(groups: Array[PackedInt32Array], indices: PackedInt32Array) -> bool:
	for group in groups:
		var all := true
		for index in indices:
			if not group.has(index):
				all = false
				break
		if all:
			return true
	return false
