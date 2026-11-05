class_name TFCompound
extends RefCounted
## Outline and logical faces of a compound (Verbund): convex brushes that
## should look like one object. Editor-independent.
##
## Per plane, the visible parts of the member faces are computed: contact
## areas (coplanar faces of other members pointing the other way) are cut
## away, overlapping coplanar faces count once. Connected visible parts form
## a region (logical face); the boundary of all regions is the outline.
##
## Everything happens with exact convex clipping in a 2D basis of each plane,
## so the visible parts stay convex and need no triangulation. Seams are
## compared with TFConst.EPSILON.

const _NONE: Array = []


## Regions and outline of the members. face_sets[i] is an Array[TFFace],
## transforms[i] the Transform3D from its space into the common space (e.g.
## map space), polyhedra[i] optionally its cached TFPolyhedron. Faces of
## members with own_faces[i] = true never merge with other members' faces
## (they still hide contact areas). Results are in the common space:
## {
##   "regions": Array of {
##       "plane": Plane,
##       "polygons": Array[PackedVector3Array] (outer loops, CCW from outside),
##       "holes": Array[PackedVector3Array],
##       "faces": Array of Vector2i(member, face_index),
##       "pieces": Array[PackedVector3Array] (convex visible parts),
##       "area": float },
##   "outline": Array of [Vector3, Vector3] (each edge once),
##   "face_regions": Dictionary Vector2i(member, face_index) -> Array of region indices,
##   "face_pieces": Dictionary Vector2i(member, face_index) -> Array[PackedVector3Array],
## }
## Faces that are completely covered belong to no region.
static func compute(face_sets: Array, transforms: Array, polyhedra: Array = [], own_faces: Array = []) -> Dictionary:
	var units := _collect_units(face_sets, transforms, polyhedra)
	var result := {
		"regions": [],
		"outline": [],
		"face_regions": {},
		"face_pieces": {},
		"own_faces": own_faces,
	}
	var seen_edges := {}
	for unit: Dictionary in units:
		_process_unit(unit, units, result, seen_edges)
	return result


## Visible area of all regions (sum of the region areas).
static func total_area(data: Dictionary) -> float:
	var sum := 0.0
	for region: Dictionary in data["regions"]:
		sum += region["area"]
	return sum


## Boundary loops (outer loops and holes of the regions, from compute())
## that run along the segment a-b, as Array of {loop: PackedVector3Array,
## region: int, concave: int}. concave counts the loop edges that are not
## convex edges of the solid (the neighbor region in front of the loop's
## plane, or no visible neighbor at all); only convex edges can be bevelled.
## Sorted by concave, so the rim around a recess comes before its walls.
static func edge_loops(data: Dictionary, a: Vector3, b: Vector3) -> Array:
	var result: Array = []
	var regions: Array = data["regions"]
	for region_index in regions.size():
		var region: Dictionary = regions[region_index]
		for loop: PackedVector3Array in region["polygons"] + region["holes"]:
			if not _loop_has_segment(loop, a, b):
				continue
			var concave := 0
			for k in loop.size():
				if not _is_convex_edge(regions, region_index, loop[k], loop[(k + 1) % loop.size()]):
					concave += 1
			result.append({"loop": loop, "region": region_index, "concave": concave})
	result.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x["concave"] < y["concave"])
	return result


## True if point lies on the segment a-b (within TFConst.EPSILON).
static func on_segment(point: Vector3, a: Vector3, b: Vector3) -> bool:
	var ab := b - a
	var t := clampf((point - a).dot(ab) / maxf(ab.length_squared(), TFConst.EPSILON * TFConst.EPSILON), 0.0, 1.0)
	return point.distance_to(a + ab * t) <= TFConst.EPSILON


# True if both ends of a-b lie on one edge of the loop.
static func _loop_has_segment(loop: PackedVector3Array, a: Vector3, b: Vector3) -> bool:
	for k in loop.size():
		var p := loop[k]
		var q := loop[(k + 1) % loop.size()]
		if on_segment(a, p, q) and on_segment(b, p, q):
			return true
	return false


# True if the region on the other side of the loop edge p-q lies behind the
# plane of region_index (a convex edge of the solid).
static func _is_convex_edge(regions: Array, region_index: int, p: Vector3, q: Vector3) -> bool:
	var middle := (p + q) * 0.5
	var plane: Plane = regions[region_index]["plane"]
	for other in regions.size():
		if other == region_index:
			continue
		for piece: PackedVector3Array in regions[other]["pieces"]:
			for k in piece.size():
				if not on_segment(middle, piece[k], piece[(k + 1) % piece.size()]):
					continue
				var center := Vector3.ZERO
				for v in piece:
					center += v
				center /= float(piece.size())
				return plane.distance_to(center) < -TFConst.EPSILON
	return false


# --- units: faces grouped by oriented plane ---------------------------------------

## Array of {plane, u, v, origin, opposite (unit index or -1), faces: Array
## of [member, face_index, PackedVector3Array]}.
static func _collect_units(face_sets: Array, transforms: Array, polyhedra: Array) -> Array:
	var units: Array = []
	var unit_planes: Array[Plane] = []
	for member in face_sets.size():
		var faces: Array = face_sets[member]
		var xf: Transform3D = transforms[member]
		var poly: TFPolyhedron = polyhedra[member] if member < polyhedra.size() and polyhedra[member] != null else null
		if poly == null:
			var planes: Array[Plane] = []
			for face: TFFace in faces:
				planes.append(face.plane if face != null else Plane())
			poly = TFGeometry.planes_to_polyhedron(planes)
		if not poly.is_valid():
			continue
		for face_index in faces.size():
			if faces[face_index] == null or not poly.is_face_used(face_index):
				continue
			var points := PackedVector3Array()
			for v in poly.get_face_vertices(face_index):
				points.append(xf * v)
			var plane := TFCSG.normalized(xf * (faces[face_index] as TFFace).plane)
			var index := _find_plane(unit_planes, plane)
			if index == -1:
				index = units.size()
				units.append(_make_unit(plane))
				unit_planes.append(plane)
			(units[index]["faces"] as Array).append([member, face_index, points])
	for i in units.size():
		if units[i]["opposite"] == -1:
			var opposite := _find_plane(unit_planes, -unit_planes[i])
			units[i]["opposite"] = opposite
			if opposite != -1:
				units[opposite]["opposite"] = i
	return units


static func _find_plane(planes: Array[Plane], plane: Plane) -> int:
	for i in planes.size():
		# Cheap distance test first.
		if absf(planes[i].d - plane.d) <= TFConst.PLANE_EPSILON and TFGeometry.planes_equal(planes[i], plane):
			return i
	return -1


static func _make_unit(plane: Plane) -> Dictionary:
	var normal := plane.normal
	var u := normal.cross(Vector3.UP if absf(normal.y) < 0.9 else Vector3.RIGHT).normalized()
	# u x v = normal: counter-clockwise in (u, v) is counter-clockwise seen
	# from the side the normal points to.
	var v := normal.cross(u)
	return {"plane": plane, "u": u, "v": v, "origin": normal * plane.d, "opposite": -1, "faces": []}


static func _to_2d(unit: Dictionary, points: PackedVector3Array) -> PackedVector2Array:
	var u: Vector3 = unit["u"]
	var v: Vector3 = unit["v"]
	var origin: Vector3 = unit["origin"]
	var result := PackedVector2Array()
	for p in points:
		result.append(Vector2((p - origin).dot(u), (p - origin).dot(v)))
	return result


static func _to_3d(unit: Dictionary, points: PackedVector2Array) -> PackedVector3Array:
	var u: Vector3 = unit["u"]
	var v: Vector3 = unit["v"]
	var origin: Vector3 = unit["origin"]
	var result := PackedVector3Array()
	for p in points:
		result.append(origin + u * p.x + v * p.y)
	return result


# --- regions of one plane ---------------------------------------------------------

static func _process_unit(unit: Dictionary, units: Array, result: Dictionary, seen_edges: Dictionary) -> void:
	var faces: Array = unit["faces"]
	if faces.size() == 1 and unit["opposite"] == -1:
		_add_single_face(unit, faces[0], result, seen_edges)
		return
	# Contact cutters: faces of the opposite plane, counter-clockwise here.
	var cutters: Array = []
	if unit["opposite"] != -1:
		for entry: Array in units[unit["opposite"]]["faces"]:
			var flat := _to_2d(unit, entry[2])
			flat.reverse()
			cutters.append([entry[0], flat, _bounds(flat)])
	# Visible convex pieces: [Vector2i(member, face), PackedVector2Array].
	var pieces: Array = []
	var earlier: Array = []  # [member, polygon, bounds] of faces already handled
	for entry: Array in unit["faces"]:
		var member: int = entry[0]
		var flat := _to_2d(unit, entry[2])
		var bounds := _bounds(flat)
		var parts: Array[PackedVector2Array] = [flat]
		for cutter: Array in cutters:
			if cutter[0] != member and _bounds_overlap(bounds, cutter[2]):
				parts = _subtract_all(parts, cutter[1])
		# Overlapping coplanar faces (overlapping brushes) count once.
		for other: Array in earlier:
			if other[0] != member and _bounds_overlap(bounds, other[2]):
				parts = _subtract_all(parts, other[1])
		earlier.append([member, flat, bounds])
		var key := Vector2i(member, entry[1])
		for part in parts:
			pieces.append([key, part])
	if pieces.is_empty():
		return
	_build_regions(unit, pieces, result, seen_edges)


## A face alone in its plane is a region of its own (fast path).
static func _add_single_face(unit: Dictionary, entry: Array, result: Dictionary, seen_edges: Dictionary) -> void:
	var points: PackedVector3Array = entry[2]
	var key := Vector2i(entry[0], entry[1])
	var regions: Array = result["regions"]
	result["face_regions"][key] = [regions.size()]
	result["face_pieces"][key] = [points]
	var area := Vector3.ZERO
	for k in points.size():
		area += points[k].cross(points[(k + 1) % points.size()])
		_add_outline_edge(result["outline"], seen_edges, points[k], points[(k + 1) % points.size()])
	var polygons: Array[PackedVector3Array] = [points]
	var holes: Array[PackedVector3Array] = []
	var pieces: Array[PackedVector3Array] = [points]
	regions.append({
		"plane": unit["plane"],
		"polygons": polygons,
		"holes": holes,
		"faces": [key],
		"pieces": pieces,
		"area": area.length() * 0.5,
	})


## Boundary edges, connected components and loops of the pieces.
static func _build_regions(unit: Dictionary, pieces: Array, result: Dictionary, seen_edges: Dictionary) -> void:
	# Directed edges of all pieces.
	var edge_piece := PackedInt32Array()
	var edge_a := PackedVector2Array()
	var edge_b := PackedVector2Array()
	for i in pieces.size():
		var polygon: PackedVector2Array = pieces[i][1]
		for k in polygon.size():
			edge_piece.append(i)
			edge_a.append(polygon[k])
			edge_b.append(polygon[(k + 1) % polygon.size()])
	var count := edge_a.size()
	var parent: Array[int] = []
	for i in pieces.size():
		parent.append(i)
	var boundary: Array = []  # [piece, a, b]
	if pieces.size() == 1:
		for ei in count:
			boundary.append([0, edge_a[ei], edge_b[ei]])
	else:
		_cancel_edges(pieces, edge_piece, edge_a, edge_b, result["own_faces"], parent, boundary)
	# One region per connected component.
	var component_of := {}  # root -> region index (local)
	var local_regions: Array = []
	for i in pieces.size():
		var root := _find(parent, i)
		if not component_of.has(root):
			component_of[root] = local_regions.size()
			local_regions.append({"pieces": [], "indices": [], "faces": [], "segments": []})
		var region: Dictionary = local_regions[component_of[root]]
		(region["pieces"] as Array).append(pieces[i][1])
		(region["indices"] as Array).append(i)
		if not (region["faces"] as Array).has(pieces[i][0]):
			(region["faces"] as Array).append(pieces[i][0])
	for segment: Array in boundary:
		var region: Dictionary = local_regions[component_of[_find(parent, segment[0])]]
		(region["segments"] as Array).append([segment[1], segment[2]])
	var regions: Array = result["regions"]
	var face_regions: Dictionary = result["face_regions"]
	var face_pieces: Dictionary = result["face_pieces"]
	var pieces_3d: Array[PackedVector3Array] = []
	for i in pieces.size():
		var key: Vector2i = pieces[i][0]
		if not face_pieces.has(key):
			face_pieces[key] = []
		pieces_3d.append(_to_3d(unit, pieces[i][1]))
		(face_pieces[key] as Array).append(pieces_3d[i])
	for local: Dictionary in local_regions:
		var polygons: Array[PackedVector3Array] = []
		var holes: Array[PackedVector3Array] = []
		var area := 0.0
		for piece: PackedVector2Array in local["pieces"]:
			area += _area(piece)
		var loops: Array[PackedVector2Array] = []
		if (local["pieces"] as Array).size() == 1:
			# A lone piece is its own outline.
			loops.append(_simplify(local["pieces"][0]))
		else:
			loops = _chain(local["segments"])
		for loop in loops:
			var loop_3d := _to_3d(unit, loop)
			if _area(loop) >= 0.0:
				polygons.append(loop_3d)
			else:
				holes.append(loop_3d)
			for k in loop_3d.size():
				_add_outline_edge(result["outline"], seen_edges, loop_3d[k], loop_3d[(k + 1) % loop_3d.size()])
		var region_pieces: Array[PackedVector3Array] = []
		for i: int in local["indices"]:
			region_pieces.append(pieces_3d[i])
		var index := regions.size()
		for key: Vector2i in local["faces"]:
			if not face_regions.has(key):
				face_regions[key] = []
			(face_regions[key] as Array).append(index)
		regions.append({
			"plane": unit["plane"],
			"polygons": polygons,
			"holes": holes,
			"faces": local["faces"],
			"pieces": region_pieces,
			"area": area,
		})


## Edge parts not covered by an opposite edge of another piece are boundary
## (appended as [piece, a, b]); pieces sharing an edge part are joined in
## parent. Pieces of members with own faces only join the same member. Only
## pieces whose bounds touch are compared.
static func _cancel_edges(pieces: Array, edge_piece: PackedInt32Array, edge_a: PackedVector2Array, edge_b: PackedVector2Array, own_faces: Array, parent: Array[int], boundary: Array) -> void:
	var count := edge_a.size()
	var first_edge := PackedInt32Array()  # per piece, plus the end
	for ei in count:
		if ei == 0 or edge_piece[ei] != edge_piece[ei - 1]:
			first_edge.append(ei)
	first_edge.append(count)
	var bounds: Array[Rect2] = []
	for i in pieces.size():
		bounds.append(_bounds(pieces[i][1]).grow(TFConst.EPSILON))
	var dirs := PackedVector2Array()
	var lengths := PackedFloat64Array()
	for ei in count:
		var d := edge_b[ei] - edge_a[ei]
		var length := d.length()
		lengths.append(length)
		dirs.append(d / length if length >= TFConst.EPSILON else Vector2.ZERO)
	var covered: Array = []  # per edge: null or Array[Vector2] of covered spans
	covered.resize(count)
	var check_own := not own_faces.is_empty()
	for i in pieces.size():
		var bounds_i := bounds[i]
		for j in range(i + 1, pieces.size()):
			if not bounds_i.intersects(bounds[j]):
				continue
			if check_own and not _can_join(pieces[i][0].x, pieces[j][0].x, own_faces):
				continue
			for ei in range(first_edge[i], first_edge[i + 1]):
				var dir := dirs[ei]
				var a := edge_a[ei]
				for fi in range(first_edge[j], first_edge[j + 1]):
					# Anti-parallel and on the same line.
					if dir.dot(dirs[fi]) > -0.5:
						continue
					var c := edge_a[fi]
					var g := edge_b[fi]
					if absf(dir.cross(c - a)) > TFConst.EPSILON or absf(dir.cross(g - a)) > TFConst.EPSILON:
						continue
					# f runs backwards: g has the smaller parameter along e.
					var length := lengths[ei]
					var tc := (c - a).dot(dir)
					var t0 := clampf((g - a).dot(dir), 0.0, length)
					var t1 := clampf(tc, 0.0, length)
					if t1 - t0 <= TFConst.EPSILON:
						continue
					_union(parent, i, j)
					_add_span(covered, ei, Vector2(t0, t1))
					var other_length := lengths[fi]
					_add_span(covered, fi, Vector2(clampf(tc - t1, 0.0, other_length), clampf(tc - t0, 0.0, other_length)))
	for ei in count:
		var a := edge_a[ei]
		if covered[ei] == null:
			boundary.append([edge_piece[ei], a, edge_b[ei]])
			continue
		var dir := dirs[ei]
		for span in _uncovered(covered[ei], lengths[ei]):
			boundary.append([edge_piece[ei], a + dir * span.x, a + dir * span.y])


static func _add_span(covered: Array, edge: int, span: Vector2) -> void:
	if covered[edge] == null:
		var spans: Array[Vector2] = []
		covered[edge] = spans
	(covered[edge] as Array[Vector2]).append(span)


static func _can_join(member_a: int, member_b: int, own_faces: Array) -> bool:
	if member_a == member_b:
		return true
	return not (member_a < own_faces.size() and own_faces[member_a]) and not (member_b < own_faces.size() and own_faces[member_b])


## Uncovered sub-intervals of [0, length] as Vector2(start, end).
static func _uncovered(covered: Array[Vector2], length: float) -> Array[Vector2]:
	var result: Array[Vector2] = []
	if covered.size() > 1:
		covered.sort()
	var start := 0.0
	for span in covered:
		if span.x - start > TFConst.EPSILON:
			result.append(Vector2(start, span.x))
		start = maxf(start, span.y)
	if length - start > TFConst.EPSILON:
		result.append(Vector2(start, length))
	return result


## Joins directed segments [a, b] into closed loops without collinear points.
static func _chain(segments: Array) -> Array[PackedVector2Array]:
	var loops: Array[PackedVector2Array] = []
	var used := PackedByteArray()
	used.resize(segments.size())
	var starts := {}  # snapped start point -> segment indices
	for k in segments.size():
		var key := _snap_key(segments[k][0])
		if not starts.has(key):
			starts[key] = []
		(starts[key] as Array).append(k)
	for first in segments.size():
		if used[first]:
			continue
		used[first] = 1
		var loop := PackedVector2Array([segments[first][0]])
		var start: Vector2 = segments[first][0]
		var end: Vector2 = segments[first][1]
		while end.distance_to(start) > TFConst.EPSILON:
			var next := _next_segment(segments, used, starts.get(_snap_key(end), _NONE), end)
			if next == -1:
				# Snapping put the matching start into a neighboring cell.
				next = _next_segment(segments, used, range(segments.size()), end)
			if next == -1:
				break
			used[next] = 1
			loop.append(end)
			end = segments[next][1]
		var cleaned := _simplify(loop)
		if cleaned.size() >= 3:
			loops.append(cleaned)
	return loops


static func _next_segment(segments: Array, used: PackedByteArray, candidates: Array, end: Vector2) -> int:
	var next := -1
	var best := TFConst.EPSILON * 10.0
	for k: int in candidates:
		if used[k]:
			continue
		var distance := (segments[k][0] as Vector2).distance_to(end)
		if distance <= best:
			best = distance
			next = k
	return next


static func _snap_key(p: Vector2) -> Vector2i:
	return Vector2i((p / (TFConst.EPSILON * 10.0)).round())


## Removes duplicate and collinear points of a closed loop.
static func _simplify(loop: PackedVector2Array) -> PackedVector2Array:
	var points := PackedVector2Array()
	for p in loop:
		if not points.is_empty() and p.distance_to(points[points.size() - 1]) <= TFConst.EPSILON:
			continue
		while points.size() >= 2 and _is_between(points[points.size() - 2], points[points.size() - 1], p):
			points.remove_at(points.size() - 1)
		points.append(p)
	# Close the loop: the seam between last and first point.
	var changed := true
	while changed and points.size() >= 3:
		changed = false
		var n := points.size()
		if points[n - 1].distance_to(points[0]) <= TFConst.EPSILON or _is_between(points[n - 2], points[n - 1], points[0]):
			points.remove_at(n - 1)
			changed = true
		elif _is_between(points[n - 1], points[0], points[1]):
			points.remove_at(0)
			changed = true
	return points


## True if point lies on the segment from prev to next (within EPSILON).
static func _is_between(prev: Vector2, point: Vector2, next: Vector2) -> bool:
	var span := next - prev
	var length := span.length()
	if length < TFConst.EPSILON:
		return point.distance_to(prev) <= TFConst.EPSILON
	return absf(span.cross(point - prev)) / length <= TFConst.EPSILON and (point - prev).dot(next - point) >= 0.0


static func _add_outline_edge(outline: Array, seen: Dictionary, a: Vector3, b: Vector3) -> void:
	var ka := _point_key(a)
	var kb := _point_key(b)
	if kb < ka:
		var swap := ka
		ka = kb
		kb = swap
	if not seen.has(ka):
		seen[ka] = {}
	var ends: Dictionary = seen[ka]
	if ends.has(kb):
		return
	ends[kb] = true
	outline.append([a, b])


static func _point_key(p: Vector3) -> Vector3i:
	return Vector3i((p / (TFConst.EPSILON * 10.0)).round())


# --- convex 2D clipping ----------------------------------------------------------------

## Parts of the convex polygons outside the convex cutter (both
## counter-clockwise). The parts stay convex.
static func _subtract_all(parts: Array[PackedVector2Array], cutter: PackedVector2Array) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	for part in parts:
		result.append_array(subtract_convex(part, cutter))
	return result


## Convex pieces of polygon minus cutter (both convex, counter-clockwise):
## the cutter's edges peel off the outside parts one by one, the rest lies
## inside the cutter and is dropped.
static func subtract_convex(polygon: PackedVector2Array, cutter: PackedVector2Array) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	var rest := polygon
	for k in cutter.size():
		var a := cutter[k]
		var d := cutter[(k + 1) % cutter.size()] - a
		var length := d.length()
		if length < TFConst.EPSILON:
			continue
		var outward := Vector2(d.y, -d.x) / length
		var sides := _split(rest, a, outward)
		if not _is_thin(sides[1]):
			result.append(sides[1])
		rest = sides[0]
		if _is_thin(rest):
			return result
	return result


## [inside, outside] of a convex polygon split by the line through point
## with the given unit normal (outside = the side the normal points to).
## Points within EPSILON of the line belong to both sides.
static func _split(polygon: PackedVector2Array, point: Vector2, normal: Vector2) -> Array[PackedVector2Array]:
	var inside := PackedVector2Array()
	var outside := PackedVector2Array()
	var count := polygon.size()
	var distances := PackedFloat64Array()
	distances.resize(count)
	for i in count:
		distances[i] = (polygon[i] - point).dot(normal)
	for i in count:
		var p := polygon[i]
		var dp := distances[i]
		var dq := distances[(i + 1) % count]
		if dp <= TFConst.EPSILON:
			inside.append(p)
		if dp >= -TFConst.EPSILON:
			outside.append(p)
		if (dp < -TFConst.EPSILON and dq > TFConst.EPSILON) or (dp > TFConst.EPSILON and dq < -TFConst.EPSILON):
			var x := p + (polygon[(i + 1) % count] - p) * (dp / (dp - dq))
			inside.append(x)
			outside.append(x)
	return [inside, outside]


## True for polygons without area or thinner than EPSILON.
static func _is_thin(polygon: PackedVector2Array) -> bool:
	if polygon.size() < 3:
		return true
	var perimeter := 0.0
	for i in polygon.size():
		perimeter += polygon[i].distance_to(polygon[(i + 1) % polygon.size()])
	return absf(_area(polygon)) <= TFConst.EPSILON * perimeter * 0.5


## Signed area (positive for counter-clockwise).
static func _area(polygon: PackedVector2Array) -> float:
	var sum := 0.0
	for i in polygon.size():
		sum += polygon[i].cross(polygon[(i + 1) % polygon.size()])
	return sum * 0.5


static func _bounds(polygon: PackedVector2Array) -> Rect2:
	var rect := Rect2(polygon[0], Vector2.ZERO)
	for p in polygon:
		rect = rect.expand(p)
	return rect


static func _bounds_overlap(a: Rect2, b: Rect2) -> bool:
	return a.grow(-TFConst.EPSILON).intersects(b.grow(-TFConst.EPSILON))


# --- union-find -------------------------------------------------------------------

static func _find(parent: Array[int], i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


static func _union(parent: Array[int], a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[maxi(ra, rb)] = mini(ra, rb)
