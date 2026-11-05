class_name TFBevel
extends RefCounted
## Bevel (chamfer/round) of brush edges and vertices as additional planes.
## Pure functions on face arrays in brush-local space, editor-independent.
##
## A bevel only adds planes, so a convex brush stays one convex brush. The
## original faces stay unchanged (same indices and attributes); the new faces
## are appended. Edges and vertices are given as brush-local positions, not
## indices, so a recalculation from the source faces finds them again.
##
## Parameters (see default_params()):
##   width     offset of the new edges from the old one, measured on the faces
##   segments  new faces across an edge (1 = chamfer)
##   profile   0.25 straight … 0.5 circle … 1 square (superellipse, as Blender)
##   clamp     limit the width so no face vanishes and neighbors don't overlap
##   corners   Corners.PATCH rounds vertices where all edges are bevelled,
##             Corners.CUT lets the edge planes cut each other
##   wrap_uv   new faces continue the texture of their neighbor face around
##             the bevel, else they get world UVs like any new face
##   offset    map offset of the brush (UV wrapping happens in map space)
##   ppm       pixels per meter (UV wrapping)

enum Corners { PATCH, CUT }

## Samples of the profile curve per segment before choosing the points.
const PROFILE_SAMPLES_PER_SEGMENT: int = 32
## With clamp, an invalid result is retried this often with the width
## shrunk by CLAMP_SHRINK (the half-face limit does not cover every shape).
const CLAMP_RETRIES: int = 6
const CLAMP_SHRINK: float = 0.75


static func default_params() -> Dictionary:
	return {
		"width": 0.0,
		"segments": 1,
		"profile": 0.5,
		"clamp": true,
		"corners": Corners.PATCH,
		"wrap_uv": true,
		"offset": Vector3.ZERO,
		"ppm": float(TFConst.DEFAULT_PIXELS_PER_METER),
	}


## Exponent of the superellipse for a profile value (Blender's mapping:
## 0.25 -> 1 straight, 0.5 -> 2 circle, 1 -> infinite square).
static func profile_exponent(profile: float) -> float:
	var p := clampf(profile, TFConst.BEVEL_MIN_PROFILE, TFConst.BEVEL_MAX_PROFILE)
	return -2.0 * log(2.0) / log(p)


# --- edges -------------------------------------------------------------------

## Bevels the edges (Array of [Vector3, Vector3], brush-local endpoints; edges
## that are not edges of the brush are ignored). Returns {} if nothing could
## be bevelled or the result is invalid, otherwise:
## {faces: Array[TFFace], width: float (clamped), clamped: bool, segments:
##  int (after limits), capped: bool (segments reduced for the plane limit),
##  edges: int (bevelled edges), polyhedron: TFPolyhedron of faces}.
static func bevel_edges(faces: Array[TFFace], edges: Array, params: Dictionary) -> Dictionary:
	var p := default_params()
	p.merge(params, true)
	var source := _source(faces)
	if source.is_empty():
		return {}
	var poly: TFPolyhedron = source["poly"]
	var planes: Array[Plane] = source["planes"]
	var edge_faces := edge_face_map(poly)
	var targets: Array = []  # {u, v, a, b, angle}
	var seen := {}
	for edge: Array in edges:
		var u := TFHull.find_point(poly.vertices, edge[0])
		var v := TFHull.find_point(poly.vertices, edge[1])
		var key := Vector2i(mini(u, v), maxi(u, v))
		if u == -1 or v == -1 or u == v or seen.has(key) or not edge_faces.has(key):
			continue
		seen[key] = true
		var pair: PackedInt32Array = edge_faces[key]
		if pair.size() != 2:
			continue
		var a := mini(pair[0], pair[1])
		var b := maxi(pair[0], pair[1])
		var angle := planes[a].normal.angle_to(planes[b].normal)
		if rad_to_deg(angle) < 2.0 * TFConst.BEVEL_MIN_ANGLE:
			continue
		targets.append({"u": key.x, "v": key.y, "a": a, "b": b, "angle": angle})
	if targets.is_empty():
		return {}

	var width: float = p["width"]
	var clamped := false
	if p["clamp"]:
		var limit := INF
		for t: Dictionary in targets:
			var extent := minf(_extent(poly, t["a"], t), _extent(poly, t["b"], t))
			limit = minf(limit, 0.5 * extent - minf(TFConst.BEVEL_CLAMP_MARGIN, 0.1 * extent))
		if width > limit:
			width = maxf(limit, 0.0)
			clamped = true
	if width <= TFConst.EPSILON:
		return {}

	var segments := clampi(int(p["segments"]), 1, TFConst.BEVEL_MAX_SEGMENTS)
	var exponent := profile_exponent(p["profile"])
	var patch: bool = p["corners"] == Corners.PATCH
	for attempt in CLAMP_RETRIES + 1:
		var count := segments
		var built: Dictionary
		while true:
			built = _edge_planes(poly, planes, targets, width, count, exponent, patch)
			if faces.size() + (built["planes"] as Array).size() <= TFConst.BEVEL_MAX_PLANES or count == 1:
				break
			count -= 1
		var result := _finish(faces, source, built["planes"], built["sources"], p)
		if not result.is_empty():
			result["width"] = width
			result["clamped"] = clamped
			result["segments"] = built["segments"]
			result["capped"] = count < segments
			result["edges"] = targets.size()
			return result
		# Clamp: shrink until the result is valid.
		if not p["clamp"]:
			break
		width *= CLAMP_SHRINK
		clamped = true
	return {}


## Edges of the polyhedron whose faces meet at an angle of at least
## limit_degrees (between the face normals, 90 for a box), as pairs of
## positions (like Blender's bevel modifier "Limit: Angle").
static func edges_by_angle(poly: TFPolyhedron, limit_degrees: float) -> Array:
	var normals := _face_normals(poly)
	var result: Array = []
	var edge_faces := edge_face_map(poly)
	for key: Vector2i in edge_faces:
		var pair: PackedInt32Array = edge_faces[key]
		if pair.size() != 2:
			continue
		if rad_to_deg(normals[pair[0]].angle_to(normals[pair[1]])) >= limit_degrees - 1e-3:
			result.append([poly.vertices[key.x], poly.vertices[key.y]])
	return result


## Boundary edges of a set of faces (edges with exactly one adjacent face in
## the set), as pairs of positions.
static func boundary_edges(poly: TFPolyhedron, face_indices: Array) -> Array:
	var result: Array = []
	var edge_faces := edge_face_map(poly)
	for key: Vector2i in edge_faces:
		var inside := 0
		for f in edge_faces[key]:
			if face_indices.has(f):
				inside += 1
		if inside == 1:
			result.append([poly.vertices[key.x], poly.vertices[key.y]])
	return result


## Edge (Vector2i(a, b), a < b) -> indices of the faces at the edge.
static func edge_face_map(poly: TFPolyhedron) -> Dictionary:
	var result := {}
	for f in poly.face_polygons.size():
		var polygon := poly.face_polygons[f]
		var n := polygon.size()
		if n < 3:
			continue
		for k in n:
			var key := Vector2i(mini(polygon[k], polygon[(k + 1) % n]), maxi(polygon[k], polygon[(k + 1) % n]))
			if result.has(key):
				result[key].append(f)
			else:
				result[key] = PackedInt32Array([f])
	return result


# Planes for all target edges plus corner patches: {planes: Array[Plane],
# sources: Array of [face index or -1, previous new plane index or -1],
# segments: largest segment count used}.
static func _edge_planes(poly: TFPolyhedron, planes: Array[Plane], targets: Array, width: float, segments: int, exponent: float, patch: bool) -> Dictionary:
	var new_planes: Array[Plane] = []
	var sources: Array = []
	var used_segments := 1
	var radii := {}  # target index -> r
	for ti in targets.size():
		var t: Dictionary = targets[ti]
		var na := planes[t["a"]].normal
		var nb := planes[t["b"]].normal
		var phi: float = t["angle"]
		var r := width / tan(phi * 0.5)
		radii[ti] = r
		var corner := poly.vertices[t["u"]]
		var center := corner - (na + nb) * (r / (1.0 + cos(phi)))
		var direction := na.cross(nb).normalized()
		var points := _profile_points(center, na, nb, corner, r, phi, segments, exponent)
		if points.size() < 2:
			continue
		used_segments = maxi(used_segments, points.size() - 1)
		# Planes through neighboring profile points, a-side first; the
		# first half takes the attributes of face a (chained for UV
		# wrapping), the second half those of face b.
		var count := points.size() - 1
		var first := new_planes.size()
		for k in count:
			var normal := _chord_normal(points[k], points[k + 1], direction, corner)
			new_planes.append(Plane(normal, normal.dot(points[k])))
			sources.append(null)
		for k in count:
			if 2 * k + 1 <= count:
				sources[first + k] = [t["a"], first + k - 1 if k > 0 else -1]
			else:
				sources[first + k] = [t["b"], first + k + 1 if k < count - 1 else -1]
	if patch:
		_corner_planes(poly, planes, targets, radii, segments, new_planes, sources)
	return {"planes": new_planes, "sources": sources, "segments": used_segments}


# Points of the profile from the tangent point on face a to the one on face b
# (segments + 1 points, fewer if segments would be shorter or flatter than
# the limits). The circle (exponent 2) is exact; other exponents map the
# superellipse x^e + y^e = 1 of the unit square onto the cross-section with
# the projective map that turns the quarter circle into the arc, so straight
# lines stay straight and the circle stays the circle.
static func _profile_points(center: Vector3, na: Vector3, nb: Vector3, corner: Vector3, r: float, phi: float, segments: int, exponent: float) -> PackedVector3Array:
	var points := PackedVector3Array()
	var arc_a := center + na * r
	var arc_b := center + nb * r
	if exponent <= 1.0 + 1e-6:
		points.append(arc_a)
		points.append(arc_b)
		return points
	if absf(exponent - 2.0) < 1e-6:
		var count := mini(segments, _segment_limit(r * phi, phi))
		for k in count + 1:
			points.append(center + _slerp(na, nb, float(k) / count) * r)
		return points

	# 2D frame of the cross-section at the corner.
	var x_axis := na
	var y_axis := (nb - na * na.dot(nb)).normalized()
	var to_2d := func(point: Vector3) -> Vector2:
		return Vector2((point - corner).dot(x_axis), (point - corner).dot(y_axis))
	var mid := center + _slerp(na, nb, 0.5) * r
	var h := _homography(
		[Vector2(1, 0), Vector2(0, 1), Vector2(1, 1), Vector2(sqrt(0.5), sqrt(0.5))],
		[to_2d.call(arc_a), to_2d.call(arc_b), Vector2.ZERO, to_2d.call(mid)])
	if h.is_empty():
		points.append(arc_a)
		points.append(arc_b)
		return points
	# Dense samples (the parametrization x = cos(t)^(2/e), y = sin(t)^(2/e)
	# crowds them where the curve bends), then points at equal steps of the
	# tangent's turning angle: the planes spread evenly over the normals, as
	# with the circle, instead of piling up on the straight parts.
	var samples := PackedVector3Array()
	var sample_count := maxi(segments, 1) * PROFILE_SAMPLES_PER_SEGMENT
	for i in sample_count + 1:
		var angle := 0.5 * PI * float(i) / sample_count
		var q := _apply_homography(h, Vector2(pow(cos(angle), 2.0 / exponent), pow(sin(angle), 2.0 / exponent)))
		samples.append(corner + x_axis * q.x + y_axis * q.y)
	samples[0] = arc_a
	samples[-1] = arc_b
	var turns := PackedFloat64Array([0.0])  # turning before each sample
	var length := 0.0
	var previous := Vector3.ZERO
	for i in sample_count:
		var chord := samples[i + 1] - samples[i]
		length += chord.length()
		if i > 0:
			turns.append(turns[-1] + previous.angle_to(chord))
		previous = chord
	turns.append(turns[-1])
	var total := turns[-1]
	var count := mini(segments, _segment_limit(length, phi))
	points.append(arc_a)
	var j := 1
	for k in range(1, count):
		var target := total * float(k) / count
		while j < sample_count - 1 and turns[j] < target:
			j += 1
		if samples[j] != points[-1]:
			points.append(samples[j])
	points.append(arc_b)
	return _drop_flat_points(points, na, nb, na.cross(nb).normalized(), corner)


# Most segments for an arc of this length and turning angle (radians).
static func _segment_limit(length: float, angle: float) -> int:
	var by_length := int(floor(length / TFConst.BEVEL_MIN_SEGMENT))
	var by_angle := int(floor(rad_to_deg(angle) / TFConst.BEVEL_MIN_ANGLE))
	return maxi(1, mini(by_length, by_angle))


# Removes points where the profile turns by less than BEVEL_MIN_ANGLE,
# flattest first: an inner point merges its two chords, a chord almost in
# the plane of an end face loses its end point (the face covers it). Returns
# no points if the profile is flat altogether.
static func _drop_flat_points(points: PackedVector3Array, na: Vector3, nb: Vector3, direction: Vector3, corner: Vector3) -> PackedVector3Array:
	var limit := deg_to_rad(TFConst.BEVEL_MIN_ANGLE)
	while points.size() >= 2:
		var normals: Array[Vector3] = [na]
		for k in points.size() - 1:
			normals.append(_chord_normal(points[k], points[k + 1], direction, corner))
		normals.append(nb)
		var flattest := -1
		var smallest := limit
		for j in range(1, normals.size()):
			var turn := normals[j - 1].angle_to(normals[j])
			if turn < smallest:
				smallest = turn
				flattest = j - 1
		if flattest == -1:
			return points
		if points.size() == 2:
			break
		points.remove_at(flattest)
	return PackedVector3Array()


# Normal of the plane through a and b along the edge direction, facing the
# corner (outward).
static func _chord_normal(a: Vector3, b: Vector3, direction: Vector3, corner: Vector3) -> Vector3:
	var normal := (b - a).cross(direction).normalized()
	return -normal if normal.dot(corner - a) < 0.0 else normal


# Corner patches at vertices where at least 3 edges are bevelled and every
# edge of the vertex is: normals on the spherical polygon of the face
# normals (fan grid around their mean), tangent to the sphere around the
# least-squares center of the edges' arc centers.
static func _corner_planes(poly: TFPolyhedron, planes: Array[Plane], targets: Array, radii: Dictionary, segments: int, new_planes: Array[Plane], sources: Array) -> void:
	var at_vertex := {}  # vertex -> target indices
	for ti in targets.size():
		for key in ["u", "v"]:
			var vertex: int = targets[ti][key]
			if not at_vertex.has(vertex):
				at_vertex[vertex] = []
			at_vertex[vertex].append(ti)
	var vertex_faces := _vertex_faces(poly)
	for vertex: int in at_vertex:
		var list: Array = at_vertex[vertex]
		var around: PackedInt32Array = vertex_faces.get(vertex, PackedInt32Array())
		if list.size() < 3 or list.size() != around.size():
			continue
		# Least-squares center: on every edge's arc axis (n·K = d - r for
		# both faces of the edge).
		var ata := Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		var atb := Vector3.ZERO
		var radius := 0.0
		var spacing := 0.0
		for ti: int in list:
			var t: Dictionary = targets[ti]
			var r: float = radii[ti]
			radius += r
			spacing += t["angle"] / float(segments)
			for f: int in [t["a"], t["b"]]:
				var n := planes[f].normal
				ata.x += n * n.x
				ata.y += n * n.y
				ata.z += n * n.z
				atb += n * (planes[f].d - r)
		if absf(ata.determinant()) < 1e-9:
			continue
		var center := ata.inverse() * atb
		radius /= list.size()
		spacing /= list.size()
		var consistent := true
		for ti: int in list:
			var t: Dictionary = targets[ti]
			for f: int in [t["a"], t["b"]]:
				var miss := absf(planes[f].distance_to(center) + radii[ti])
				if miss > TFConst.BEVEL_CORNER_TOLERANCE * radii[ti]:
					consistent = false
		if not consistent:
			continue
		var normals := _sorted_normals(planes, around)
		var mean := Vector3.ZERO
		for n in normals:
			mean += n
		mean = mean.normalized()
		var m := maxi(1, ceili(segments / 2.0))
		var kappa := cos(spacing * 0.5)
		var found: Array[Vector3] = []
		for i in normals.size():
			var ni := normals[i]
			var nj := normals[(i + 1) % normals.size()]
			for wc in range(1, m + 1):
				for wi in m - wc + 1:
					var n := (mean * wc + ni * wi + nj * (m - wc - wi)).normalized()
					if not _has_normal(found, n) and _apart_from(normals, n):
						found.append(n)
		for n in found:
			new_planes.append(Plane(n, n.dot(center) + radius * kappa))
			sources.append([_closest_face(planes, around, n), -1])


# --- vertices ----------------------------------------------------------------

## Bevels the vertices (brush-local positions): cuts off the corner (1
## segment, or profile 0.25) or rounds it with segments as a sphere-like
## patch. width is the distance along the edges of the vertex. Returns {} or
## the same dictionary as bevel_edges() ("edges" counts the vertices).
static func bevel_vertices(faces: Array[TFFace], vertices: PackedVector3Array, params: Dictionary) -> Dictionary:
	var p := default_params()
	p.merge(params, true)
	var source := _source(faces)
	if source.is_empty():
		return {}
	var poly: TFPolyhedron = source["poly"]
	var planes: Array[Plane] = source["planes"]
	var vertex_faces := _vertex_faces(poly)
	var neighbors := {}  # vertex -> PackedInt32Array
	for edge in poly.edges:
		for pair in [[edge.x, edge.y], [edge.y, edge.x]]:
			if not neighbors.has(pair[0]):
				neighbors[pair[0]] = PackedInt32Array()
			neighbors[pair[0]].append(pair[1])
	var targets := PackedInt32Array()
	for position in vertices:
		var index := TFHull.find_point(poly.vertices, position)
		if index != -1 and not targets.has(index) and (vertex_faces.get(index, PackedInt32Array()) as PackedInt32Array).size() >= 3:
			targets.append(index)
	if targets.is_empty():
		return {}

	var width: float = p["width"]
	var clamped := false
	if p["clamp"]:
		var limit := INF
		for vertex in targets:
			for other in neighbors[vertex]:
				var length := poly.vertices[vertex].distance_to(poly.vertices[other])
				limit = minf(limit, 0.5 * length - minf(TFConst.BEVEL_CLAMP_MARGIN, 0.1 * length))
		if width > limit:
			width = maxf(limit, 0.0)
			clamped = true
	if width <= TFConst.EPSILON:
		return {}

	var segments := clampi(int(p["segments"]), 1, TFConst.BEVEL_MAX_SEGMENTS)
	if profile_exponent(p["profile"]) <= 1.0 + 1e-6:
		segments = 1
	for attempt in CLAMP_RETRIES + 1:
		var count := segments
		var new_planes: Array[Plane] = []
		var sources: Array = []
		while true:
			new_planes = []
			sources = []
			for vertex in targets:
				_vertex_planes(poly, planes, vertex, vertex_faces[vertex], neighbors[vertex], width, count, new_planes, sources)
			if faces.size() + new_planes.size() <= TFConst.BEVEL_MAX_PLANES or count == 1:
				break
			count -= 1
		var result := _finish(faces, source, new_planes, sources, p)
		if not result.is_empty():
			result["width"] = width
			result["clamped"] = clamped
			result["segments"] = count
			result["capped"] = count < segments
			result["edges"] = targets.size()
			return result
		if not p["clamp"]:
			break
		width *= CLAMP_SHRINK
		clamped = true
	return {}


# Planes of one vertex bevel. With one segment (or not exactly three edges)
# a plane through the points at width along the edges. Rounded: in the
# frame t -> corner + Σ t_i e_i (e_i = the edges, shortened to width) the
# patch is the sphere around (1, 1, 1) with radius √2; it passes through the
# edge points and meets every face in a quarter circle between them (as
# Blender's vertex bevel). Normals are sampled on a grid between the sphere
# normals at the three edge points.
static func _vertex_planes(poly: TFPolyhedron, planes: Array[Plane], vertex: int, around: PackedInt32Array, neighbors: PackedInt32Array, width: float, segments: int, new_planes: Array[Plane], sources: Array) -> void:
	var corner := poly.vertices[vertex]
	var mean := Vector3.ZERO
	for f in around:
		mean += planes[f].normal
	mean = mean.normalized()
	var edges: Array[Vector3] = []
	for other in neighbors:
		edges.append((poly.vertices[other] - corner).normalized() * width)
	var frame := Basis(edges[0], edges[1], edges[2]) if edges.size() == 3 else Basis()
	if segments == 1 or edges.size() != 3 or absf(frame.determinant()) < 1e-9:
		var normal := mean
		if edges.size() == 3:
			normal = (edges[1] - edges[0]).cross(edges[2] - edges[0]).normalized()
			if normal.dot(mean) < 0.0:
				normal = -normal
		var d := 0.0
		for edge in edges:
			d += normal.dot(corner + edge)
		new_planes.append(Plane(normal, d / edges.size()))
		sources.append([_closest_face(planes, around, normal), -1])
		return
	var to_world := frame.inverse().transposed()
	var corners: Array[Vector3] = [Vector3(0, 1, 1) * sqrt(0.5), Vector3(1, 0, 1) * sqrt(0.5), Vector3(1, 1, 0) * sqrt(0.5)]
	var found: Array[Vector3] = []
	for i in segments + 1:
		for j in segments - i + 1:
			var k := segments - i - j
			if i == segments or j == segments or k == segments:
				continue
			var g := (corners[0] * i + corners[1] * j + corners[2] * k).normalized()
			var normal := (to_world * -g).normalized()
			if _has_normal(found, normal):
				continue
			found.append(normal)
			var point := corner + frame * (Vector3.ONE - g * sqrt(2.0))
			new_planes.append(Plane(normal, normal.dot(point)))
			sources.append([_closest_face(planes, around, normal), -1])


# --- shared ------------------------------------------------------------------

# Normalized planes and polyhedron of valid faces, or {}.
static func _source(faces: Array[TFFace]) -> Dictionary:
	if faces.is_empty() or faces.has(null):
		return {}
	var planes := TFCSG.planes_of(faces)
	var poly := TFGeometry.planes_to_polyhedron(planes)
	if not poly.is_valid():
		return {}
	return {"planes": planes, "poly": poly}


# Appends faces for the new planes, checks the result and drops planes that
# cut nothing. Returns {faces, polyhedron} or {}.
static func _finish(faces: Array[TFFace], source: Dictionary, new_planes: Array[Plane], sources: Array, p: Dictionary) -> Dictionary:
	var poly: TFPolyhedron = source["poly"]
	var planes: Array[Plane] = source["planes"]
	# The result must match what the brush will compute from its faces (the
	# constructions may differ on slivers of almost parallel planes): large
	# results clip the incrementally built source at the new planes, the
	# same steps as a rebuild; small ones are rebuilt from plane triples.
	var base := poly
	if planes.size() < TFConst.POLY_INCREMENTAL_THRESHOLD:
		base = TFGeometry.planes_to_polyhedron_incremental(planes)
	var result_poly := TFGeometry.clip_polyhedron(base, planes, new_planes)
	if result_poly.is_valid() and result_poly.face_count() < TFConst.POLY_INCREMENTAL_THRESHOLD:
		var all: Array[Plane] = planes.duplicate()
		all.append_array(new_planes)
		result_poly = TFGeometry.planes_to_polyhedron_triples(all)
	if not result_poly.is_valid():
		return {}
	# Original faces must not vanish (nor shrink below EPSILON if larger).
	for i in planes.size():
		if poly.is_face_used(i) and _area(result_poly, i) <= minf(TFConst.EPSILON, 0.5 * _area(poly, i)):
			return {}
	# Wrapping chains run forward on the a-side and backward on the b-side
	# of an edge, so the faces are created in two passes.
	var new_faces: Array[TFFace] = []
	new_faces.resize(new_planes.size())
	for i in new_planes.size():
		if (sources[i][1] as int) < i:
			new_faces[i] = _new_face(faces, planes, new_planes, new_faces, sources, i, p)
	for i in range(new_planes.size() - 1, -1, -1):
		if new_faces[i] == null:
			new_faces[i] = _new_face(faces, planes, new_planes, new_faces, sources, i, p)
	var result_faces: Array[TFFace] = []
	var polygons: Array[PackedInt32Array] = []
	for i in faces.size():
		result_faces.append(faces[i].copy())
		polygons.append(result_poly.face_polygons[i])
	for i in new_planes.size():
		var polygon := result_poly.face_polygons[planes.size() + i]
		if polygon.size() >= 3:
			result_faces.append(new_faces[i])
			polygons.append(polygon)
	var final_poly := TFPolyhedron.new()
	final_poly.vertices = result_poly.vertices
	final_poly.face_polygons = polygons
	final_poly.edges = result_poly.edges
	return {"faces": result_faces, "polyhedron": final_poly}


# Face for new plane i: material and flags of its neighbor face; UVs wrapped
# around from the previous face of its chain (or the neighbor) or world UVs.
static func _new_face(faces: Array[TFFace], planes: Array[Plane], new_planes: Array[Plane], new_faces: Array[TFFace], sources: Array, i: int, p: Dictionary) -> TFFace:
	var neighbor: int = sources[i][0]
	var previous: int = sources[i][1]
	var origin := faces[neighbor]
	var face := TFFace.create(new_planes[i], origin.material)
	face.flags = origin.flags
	if not p["wrap_uv"]:
		TFUV.copy_attributes(origin, face)
		return face
	var from_face := origin if previous == -1 else new_faces[previous]
	var from_plane := planes[neighbor] if previous == -1 else new_planes[previous]
	var offset: Vector3 = p["offset"]
	TFUV.wrap_attributes(from_face, _to_map(from_plane, offset), face, _to_map(new_planes[i], offset), p["ppm"])
	return face


static func _to_map(plane: Plane, offset: Vector3) -> Plane:
	return Plane(plane.normal, plane.d + plane.normal.dot(offset))


static func _area(poly: TFPolyhedron, face: int) -> float:
	var polygon := poly.face_polygons[face]
	if polygon.size() < 3:
		return 0.0
	var sum := Vector3.ZERO
	var origin := poly.vertices[polygon[0]]
	for k in range(1, polygon.size() - 1):
		sum += (poly.vertices[polygon[k]] - origin).cross(poly.vertices[polygon[k + 1]] - origin)
	return sum.length() * 0.5


# Width of face f across the edge t: largest distance of its vertices from
# the edge line.
static func _extent(poly: TFPolyhedron, f: int, t: Dictionary) -> float:
	var a := poly.vertices[t["u"]]
	var direction := (poly.vertices[t["v"]] - a).normalized()
	var result := 0.0
	for index in poly.face_polygons[f]:
		var offset := poly.vertices[index] - a
		result = maxf(result, (offset - direction * offset.dot(direction)).length())
	return result


# Vertex -> faces containing it.
static func _vertex_faces(poly: TFPolyhedron) -> Dictionary:
	var result := {}
	for f in poly.face_polygons.size():
		for index in poly.face_polygons[f]:
			if not result.has(index):
				result[index] = PackedInt32Array()
			result[index].append(f)
	return result


# Normals of the faces sorted counter-clockwise around their mean.
static func _sorted_normals(planes: Array[Plane], around: PackedInt32Array) -> Array[Vector3]:
	var mean := Vector3.ZERO
	for f in around:
		mean += planes[f].normal
	mean = mean.normalized()
	var axis_u := mean.cross(Vector3.UP if absf(mean.y) < 0.9 else Vector3.RIGHT).normalized()
	var axis_w := mean.cross(axis_u)
	var keyed: Array = []
	for f in around:
		var n := planes[f].normal
		keyed.append([atan2(n.dot(axis_w), n.dot(axis_u)), n])
	keyed.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	var result: Array[Vector3] = []
	for entry in keyed:
		result.append(entry[1])
	return result


static func _closest_face(planes: Array[Plane], around: PackedInt32Array, normal: Vector3) -> int:
	var best := around[0]
	for f in around:
		if planes[f].normal.dot(normal) > planes[best].normal.dot(normal) + TFConst.NORMAL_EPSILON:
			best = f
	return best


static func _has_normal(list: Array[Vector3], n: Vector3) -> bool:
	for other in list:
		if other.dot(n) > 1.0 - TFConst.NORMAL_EPSILON:
			return true
	return false


# True if n is at least BEVEL_MIN_ANGLE away from all the normals.
static func _apart_from(normals: Array[Vector3], n: Vector3) -> bool:
	for other in normals:
		if rad_to_deg(other.angle_to(n)) < TFConst.BEVEL_MIN_ANGLE:
			return false
	return true


static func _face_normals(poly: TFPolyhedron) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for polygon in poly.face_polygons:
		var sum := Vector3.ZERO
		for k in polygon.size():
			var a := poly.vertices[polygon[k]]
			var b := poly.vertices[polygon[(k + 1) % polygon.size()]]
			sum += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
		result.append(sum.normalized())
	return result


static func _slerp(a: Vector3, b: Vector3, t: float) -> Vector3:
	return a.slerp(b, t).normalized()


# 2D projective map sending the four points src onto dst, as 8 coefficients
# (h0..h7, h8 = 1); empty if degenerate.
static func _homography(src: Array, dst: Array) -> PackedFloat64Array:
	var rows: Array = []
	for i in 4:
		var s: Vector2 = src[i]
		var d: Vector2 = dst[i]
		rows.append([s.x, s.y, 1.0, 0.0, 0.0, 0.0, -s.x * d.x, -s.y * d.x, d.x])
		rows.append([0.0, 0.0, 0.0, s.x, s.y, 1.0, -s.x * d.y, -s.y * d.y, d.y])
	# Gaussian elimination with partial pivoting.
	for col in 8:
		var pivot := col
		for row in range(col + 1, 8):
			if absf(rows[row][col]) > absf(rows[pivot][col]):
				pivot = row
		if absf(rows[pivot][col]) < 1e-12:
			return PackedFloat64Array()
		var swap: Array = rows[col]
		rows[col] = rows[pivot]
		rows[pivot] = swap
		for row in 8:
			if row == col:
				continue
			var factor: float = rows[row][col] / rows[col][col]
			for k in range(col, 9):
				rows[row][k] -= factor * rows[col][k]
	var h := PackedFloat64Array()
	for i in 8:
		h.append(rows[i][8] / rows[i][i])
	return h


static func _apply_homography(h: PackedFloat64Array, p: Vector2) -> Vector2:
	var w := h[6] * p.x + h[7] * p.y + 1.0
	return Vector2((h[0] * p.x + h[1] * p.y + h[2]) / w, (h[3] * p.x + h[4] * p.y + h[5]) / w)
