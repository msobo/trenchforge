class_name TFGeometry
extends RefCounted
## Stateless geometry helpers for convex brushes (planes in brush-local space,
## normals pointing outward). Editor-independent.


## Builds the convex boundary representation of the planes. Redundant or
## duplicate planes end up with an empty polygon. From
## TFConst.POLY_INCREMENTAL_THRESHOLD planes on, a start box is clipped plane
## by plane; below, all plane triples are intersected.
static func planes_to_polyhedron(planes: Array[Plane]) -> TFPolyhedron:
	if planes.size() >= TFConst.POLY_INCREMENTAL_THRESHOLD:
		return planes_to_polyhedron_incremental(planes)
	return planes_to_polyhedron_triples(planes)


## planes_to_polyhedron() by clipping a start box at every plane in order: about O(n · V). A plane that cuts nothing gets no
## polygon (so of two equal planes the first wins); an unbounded set gives an
## empty polyhedron.
static func planes_to_polyhedron_incremental(planes: Array[Plane]) -> TFPolyhedron:
	# A start box just around the planes keeps float precision (vertices of
	# a huge box are coarse); if the result reaches it, again with the
	# largest box.
	var reach := 0.0
	for plane in planes:
		reach = maxf(reach, absf(plane.d))
	var extent := clampf(TFConst.POLY_START_MARGIN * (reach + 1.0), 0.0, TFConst.POLY_START_EXTENT)
	while true:
		var solid := _Solid.new()
		solid.init_box(extent)
		var empty := false
		for i in planes.size():
			if not solid.clip(planes[i], i):
				empty = true
				break
		if empty:
			return _empty_polyhedron(planes.size())
		if not solid.has_box_faces():
			return solid.to_polyhedron(planes.size())
		if extent >= TFConst.POLY_START_EXTENT:
			return _empty_polyhedron(planes.size())
		extent = TFConst.POLY_START_EXTENT
	return null


## The polyhedron of planes + extra, built by clipping poly (the polyhedron
## of planes) at the extra planes instead of from scratch (live previews).
## The extra planes get the indices after the planes.
static func clip_polyhedron(poly: TFPolyhedron, planes: Array[Plane], extra: Array[Plane]) -> TFPolyhedron:
	var all: Array[Plane] = planes.duplicate()
	all.append_array(extra)
	if not poly.is_valid() or poly.face_polygons.size() != planes.size():
		return planes_to_polyhedron(all)
	var solid := _Solid.new()
	solid.init_polyhedron(poly, planes)
	for i in extra.size():
		if not solid.clip(extra[i], planes.size() + i):
			return _empty_polyhedron(all.size())
	return solid.to_polyhedron(all.size())


static func _empty_polyhedron(count: int) -> TFPolyhedron:
	var poly := TFPolyhedron.new()
	poly.face_polygons.resize(count)
	for i in count:
		poly.face_polygons[i] = PackedInt32Array()
	return poly


## Intersects all plane triples (the exact construction for small brushes).
static func planes_to_polyhedron_triples(planes: Array[Plane]) -> TFPolyhedron:
	var poly := TFPolyhedron.new()
	var count := planes.size()
	poly.face_polygons.resize(count)
	for i in count:
		poly.face_polygons[i] = PackedInt32Array()
	if count < 4:
		return poly

	var duplicate_of := _find_duplicate_planes(planes)

	for i in count:
		if duplicate_of[i] != -1:
			continue
		for j in range(i + 1, count):
			if duplicate_of[j] != -1:
				continue
			for k in range(j + 1, count):
				if duplicate_of[k] != -1:
					continue
				var point: Variant = planes[i].intersect_3(planes[j], planes[k])
				if point == null:
					continue
				if _is_inside_all(planes, point, duplicate_of):
					_add_unique_vertex(poly.vertices, point)

	for plane_index in count:
		if duplicate_of[plane_index] != -1:
			continue
		var on_plane := PackedInt32Array()
		for vertex_index in poly.vertices.size():
			if absf(planes[plane_index].distance_to(poly.vertices[vertex_index])) <= TFConst.PLANE_EPSILON:
				on_plane.append(vertex_index)
		if on_plane.size() >= 3:
			poly.face_polygons[plane_index] = _sort_polygon(poly.vertices, on_plane, planes[plane_index].normal)

	_build_edges(poly)
	return poly


## Ray test against the brush volume. Only front faces count, so a ray that
## starts inside the brush misses it (backface culling for interior picking).
## Returns {} on miss, otherwise {t, position, normal, face_index}.
static func ray_intersect_brush(planes: Array[Plane], origin: Vector3, direction: Vector3) -> Dictionary:
	var t_enter := -INF
	var t_exit := INF
	var enter_index := -1
	for i in planes.size():
		var plane := planes[i]
		var denom := plane.normal.dot(direction)
		var dist := plane.distance_to(origin)
		if absf(denom) < TFConst.NORMAL_EPSILON:
			if dist > TFConst.PLANE_EPSILON:
				return {}
			continue
		var t := -dist / denom
		if denom < 0.0:
			if t > t_enter:
				t_enter = t
				enter_index = i
		else:
			t_exit = minf(t_exit, t)
		if t_enter > t_exit + TFConst.EPSILON:
			return {}
	if enter_index == -1 or t_enter < 0.0:
		return {}
	return {
		"t": t_enter,
		"position": origin + direction * t_enter,
		"normal": planes[enter_index].normal,
		"face_index": enter_index,
	}


static func point_in_brush(planes: Array[Plane], point: Vector3, epsilon: float = TFConst.PLANE_EPSILON) -> bool:
	for plane in planes:
		if plane.distance_to(point) > epsilon:
			return false
	return true


## Splits a brush by a plane. Returns [front_planes, back_planes]; a side is an
## empty array if nothing valid remains there. "Front" is the side the split
## plane's normal points to.
static func split_polyhedron_by_plane(planes: Array[Plane], split: Plane) -> Array:
	var back: Array[Plane] = planes.duplicate()
	back.append(split)
	var front: Array[Plane] = planes.duplicate()
	front.append(-split)
	return [
		remove_redundant_planes(front),
		remove_redundant_planes(back),
	]


## Returns only the planes that contribute a face; empty if the result is invalid.
static func remove_redundant_planes(planes: Array[Plane]) -> Array[Plane]:
	var result: Array[Plane] = []
	var poly := planes_to_polyhedron(planes)
	if not poly.is_valid():
		return result
	for i in planes.size():
		if poly.is_face_used(i):
			result.append(planes[i])
	# Near-coplanar planes can share a face; dropping one of them may leave a
	# set without volume.
	if result.size() < planes.size() and not planes_to_polyhedron(result).is_valid():
		result.clear()
	return result


static func box_planes(size: Vector3) -> Array[Plane]:
	var half := size * 0.5
	var planes: Array[Plane] = [
		Plane(Vector3.RIGHT, half.x),
		Plane(Vector3.LEFT, half.x),
		Plane(Vector3.UP, half.y),
		Plane(Vector3.DOWN, half.y),
		Plane(Vector3.BACK, half.z),
		Plane(Vector3.FORWARD, half.z),
	]
	return planes


static func _find_duplicate_planes(planes: Array[Plane]) -> PackedInt32Array:
	var duplicate_of := PackedInt32Array()
	duplicate_of.resize(planes.size())
	duplicate_of.fill(-1)
	for i in planes.size():
		if duplicate_of[i] != -1:
			continue
		for j in range(i + 1, planes.size()):
			if planes_equal(planes[i], planes[j]):
				duplicate_of[j] = i
	return duplicate_of


## True if both planes (unit normals) match within the tolerances.
static func planes_equal(a: Plane, b: Plane) -> bool:
	return 1.0 - a.normal.dot(b.normal) <= TFConst.NORMAL_EPSILON and absf(a.d - b.d) <= TFConst.PLANE_EPSILON


static func _is_inside_all(planes: Array[Plane], point: Vector3, duplicate_of: PackedInt32Array) -> bool:
	for i in planes.size():
		if duplicate_of[i] == -1 and planes[i].distance_to(point) > TFConst.PLANE_EPSILON:
			return false
	return true


static func _add_unique_vertex(vertices: PackedVector3Array, point: Vector3) -> void:
	for v in vertices:
		if v.distance_squared_to(point) <= TFConst.EPSILON * TFConst.EPSILON:
			return
	vertices.append(point)


## Sorts the vertex indices counter-clockwise around the polygon centroid as
## seen from the side the normal points to.
static func _sort_polygon(vertices: PackedVector3Array, indices: PackedInt32Array, normal: Vector3) -> PackedInt32Array:
	var center := Vector3.ZERO
	for index in indices:
		center += vertices[index]
	center /= float(indices.size())

	var axis_u := normal.cross(Vector3.UP if absf(normal.y) < 0.9 else Vector3.RIGHT).normalized()
	var axis_w := normal.cross(axis_u)

	var keyed: Array = []
	for index in indices:
		var d := vertices[index] - center
		keyed.append([atan2(d.dot(axis_w), d.dot(axis_u)), index])
	keyed.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])

	# u × w must equal the normal for increasing angles to be CCW from outside.
	var ccw := axis_u.cross(axis_w).dot(normal) > 0.0
	var result := PackedInt32Array()
	for entry in keyed:
		result.append(entry[1])
	if not ccw:
		result.reverse()
	return result


static func _build_edges(poly: TFPolyhedron) -> void:
	var seen := {}
	for polygon in poly.face_polygons:
		var n := polygon.size()
		if n < 3:
			continue
		for i in n:
			var a := polygon[i]
			var b := polygon[(i + 1) % n]
			var edge := Vector2i(mini(a, b), maxi(a, b))
			if not seen.has(edge):
				seen[edge] = true
				poly.edges.append(edge)


# Convex solid as face loops for the incremental construction. Every face
# keeps the index of its input plane (-1 for the start box). A clip only
# visits the part of the solid in front of the plane: a hill climb along the
# vertex graph finds the farthest vertex, a search from there the vertices
# in front of (or on) the plane; all others lie behind it (convexity).
class _Solid:
	## Smallest |triple product| of three unit normals for which their
	## intersection point is computed directly.
	const WELL_CONDITIONED: float = 0.05

	var vertices := PackedVector3Array()
	var alive := PackedByteArray()
	var vertex_faces: Array[PackedInt32Array] = []  # may list dead faces
	var faces: Array[PackedInt32Array] = []
	var face_alive := PackedByteArray()
	var face_planes: Array[Plane] = []
	var face_indices := PackedInt32Array()
	var _face_count := 0
	var _start := 0
	var _clip_id := 0
	var _stamp := PackedInt32Array()
	var _dist := PackedFloat64Array()
	var _side_stamp := PackedInt32Array()
	var _side := PackedInt32Array()
	var _seen := PackedInt32Array()

	func init_box(extent: float) -> void:
		for i in 8:
			_add_vertex(Vector3(extent if i & 1 else -extent, extent if i & 2 else -extent, extent if i & 4 else -extent))
		# Loops counter-clockwise seen from outside.
		_add_face(Plane(Vector3.RIGHT, extent), PackedInt32Array([1, 3, 7, 5]), -1)
		_add_face(Plane(Vector3.LEFT, extent), PackedInt32Array([0, 4, 6, 2]), -1)
		_add_face(Plane(Vector3.UP, extent), PackedInt32Array([2, 6, 7, 3]), -1)
		_add_face(Plane(Vector3.DOWN, extent), PackedInt32Array([0, 1, 5, 4]), -1)
		_add_face(Plane(Vector3.BACK, extent), PackedInt32Array([4, 5, 7, 6]), -1)
		_add_face(Plane(Vector3.FORWARD, extent), PackedInt32Array([0, 2, 3, 1]), -1)

	func init_polyhedron(poly: TFPolyhedron, planes: Array[Plane]) -> void:
		for v in poly.vertices:
			_add_vertex(v)
		for i in poly.face_polygons.size():
			if poly.face_polygons[i].size() >= 3:
				_add_face(planes[i], poly.face_polygons[i].duplicate(), i)

	func has_box_faces() -> bool:
		for f in faces.size():
			if face_alive[f] == 1 and face_indices[f] == -1:
				return true
		return false

	## Keeps the part behind the plane. Returns false if nothing remains.
	func clip(plane: Plane, plane_index: int) -> bool:
		_clip_id += 1
		var top := _start if alive[_start] == 1 else alive.find(1)
		var best := plane.distance_to(vertices[top])
		_stamp[top] = _clip_id
		_dist[top] = best
		var climbing := true
		while climbing:
			climbing = false
			var from := top
			for f in vertex_faces[from]:
				if face_alive[f] == 0:
					continue
				var loop := faces[f]
				var k := loop.find(from)
				if k == -1:
					continue
				var w := loop[(k + 1) % loop.size()]
				if _stamp[w] != _clip_id:
					_stamp[w] = _clip_id
					_dist[w] = plane.distance_to(vertices[w])
				if _dist[w] > best:
					best = _dist[w]
					top = w
					climbing = true
		if best <= TFConst.PLANE_EPSILON:
			# Welded vertices make the solid slightly non-convex, the climb
			# may stop on a local maximum: make sure nothing is in front.
			for i in vertices.size():
				if alive[i] == 1:
					var d := plane.distance_to(vertices[i])
					if d > best:
						best = d
						top = i
			if best <= TFConst.PLANE_EPSILON:
				return true
			_stamp[top] = _clip_id
			_dist[top] = best

		# Vertices in front of (out) and on (cap) the plane.
		var out := PackedInt32Array()
		var cap := PackedInt32Array()
		_seen[top] = _clip_id
		var queue := PackedInt32Array([top])
		var behind := false
		var head := 0
		while head < queue.size():
			var u := queue[head]
			head += 1
			if _dist[u] > TFConst.PLANE_EPSILON:
				out.append(u)
			else:
				cap.append(u)
			# Both loop neighbors: robust against faces that disagree about
			# an edge after vertices were welded.
			for f in vertex_faces[u]:
				if face_alive[f] == 0:
					continue
				var loop := faces[f]
				var n := loop.size()
				var k := loop.find(u)
				if k == -1:
					continue
				for w in [loop[(k + 1) % n], loop[(k - 1 + n) % n]]:
					if _seen[w] == _clip_id:
						continue
					_seen[w] = _clip_id
					if _stamp[w] != _clip_id:
						_stamp[w] = _clip_id
						_dist[w] = plane.distance_to(vertices[w])
					if _dist[w] >= -TFConst.PLANE_EPSILON:
						queue.append(w)
					else:
						behind = true
		if not behind:
			return false

		# Faces that lose vertices.
		for u in out:
			_side_stamp[u] = _clip_id
			_side[u] = 1
		for u in cap:
			_side_stamp[u] = _clip_id
			_side[u] = 0
		var affected := {}  # face -> its vertices in front
		for u in out:
			for f in vertex_faces[u]:
				if face_alive[f] == 1:
					if affected.has(f):
						affected[f].append(u)
					else:
						affected[f] = PackedInt32Array([u])

		# Clipped loops: the run of vertices in front is replaced by the
		# points where the plane enters and leaves the face. On convex
		# faces that run is contiguous; the cap face continues from the exit
		# to the entry of every face.
		var count := vertices.size()
		var edge_vertex := {}
		var cap_next := {}
		for f: int in affected:
			var loop := faces[f]
			var n := loop.size()
			var run: PackedInt32Array = affected[f]
			var first := -1
			for u in run:
				var k := loop.find(u)
				var before := loop[(k - 1 + n) % n]
				if _side_stamp[before] != _clip_id or _side[before] != 1:
					if first != -1:
						first = -2  # not contiguous
						break
					first = k
			var result: PackedInt32Array
			if first < 0:
				result = _clip_loop(plane, f, loop, count, edge_vertex, cap)
			else:
				var last := (first + run.size() - 1) % n
				var prev := loop[(first - 1 + n) % n]
				var next := loop[(last + 1) % n]
				var entry := prev
				if _side_stamp[prev] != _clip_id:
					entry = _crossing(plane, prev, loop[first], f, count, edge_vertex, cap)
				var exit := next
				if _side_stamp[next] != _clip_id:
					exit = _crossing(plane, loop[last], next, f, count, edge_vertex, cap)
				var keep := last + 1
				if keep >= n:
					result = loop.slice(0, first)
				elif keep <= first:
					result = loop.slice(keep, first)
				else:
					result = loop.slice(keep)
					result.append_array(loop.slice(0, first))
				# result runs from next to prev; close it over the cut.
				if entry != prev:
					result.append(entry)
					_link(entry, f)
				if exit != next and exit != entry:
					result.append(exit)
					_link(exit, f)
				if entry != exit:
					cap_next[exit] = entry
			if result.size() > 1 and result[0] == result[-1]:
				result.remove_at(result.size() - 1)
			faces[f] = result
			if result.size() < 3:
				face_alive[f] = 0
				_face_count -= 1

		for u in out:
			alive[u] = 0
		if cap.size() >= 3:
			_add_face(plane, _cap_loop(cap, cap_next, plane), plane_index)
		if not cap.is_empty():
			_start = cap[0]
		return _face_count >= 4

	func to_polyhedron(plane_count: int) -> TFPolyhedron:
		var poly := TFPolyhedron.new()
		poly.face_polygons.resize(plane_count)
		for i in plane_count:
			poly.face_polygons[i] = PackedInt32Array()
		var remap := PackedInt32Array()
		remap.resize(vertices.size())
		remap.fill(-1)
		for f in faces.size():
			if face_alive[f] == 0 or face_indices[f] < 0:
				continue
			var loop := faces[f].duplicate()
			for k in loop.size():
				if remap[loop[k]] == -1:
					remap[loop[k]] = poly.vertices.size()
					poly.vertices.append(vertices[loop[k]])
				loop[k] = remap[loop[k]]
			poly.face_polygons[face_indices[f]] = loop
		TFGeometry._build_edges(poly)
		return poly

	func _add_vertex(point: Vector3) -> int:
		vertices.append(point)
		alive.append(1)
		vertex_faces.append(PackedInt32Array())
		_stamp.append(0)
		_dist.append(0.0)
		_side_stamp.append(0)
		_side.append(0)
		_seen.append(0)
		return vertices.size() - 1

	func _add_face(plane: Plane, loop: PackedInt32Array, index: int) -> void:
		var f := faces.size()
		faces.append(loop)
		face_alive.append(1)
		face_planes.append(plane)
		face_indices.append(index)
		_face_count += 1
		for v in loop:
			_link(v, f)

	func _link(v: int, f: int) -> void:
		var list := vertex_faces[v]
		if not list.has(f):
			list.append(f)
			vertex_faces[v] = list

	# Vertex where the plane crosses the edge u-v (cached per edge).
	func _crossing(plane: Plane, u: int, v: int, f: int, count: int, edge_vertex: Dictionary, cap: PackedInt32Array) -> int:
		var key := mini(u, v) * count + maxi(u, v)
		var w: int = edge_vertex.get(key, -1)
		if w == -1:
			w = _edge_vertex(plane, u, v, f, cap)
			edge_vertex[key] = w
		return w

	# Clipped loop by walking all edges (fallback for faces whose vertices in
	# front are not contiguous due to float noise).
	func _clip_loop(plane: Plane, f: int, loop: PackedInt32Array, count: int, edge_vertex: Dictionary, cap: PackedInt32Array) -> PackedInt32Array:
		var n := loop.size()
		var result := PackedInt32Array()
		for k in n:
			var u := loop[k]
			var v := loop[(k + 1) % n]
			var su: int = _side[u] if _side_stamp[u] == _clip_id else -1
			var sv: int = _side[v] if _side_stamp[v] == _clip_id else -1
			if su <= 0 and (result.is_empty() or result[-1] != u):
				result.append(u)
			if su * sv < 0:
				var w := _crossing(plane, u, v, f, count, edge_vertex, cap)
				if result.is_empty() or result[-1] != w:
					result.append(w)
				_link(w, f)
		return result

	# The cap loop chained from the face cuts; sorted by angle if the chain
	# does not cover the cap (planes through existing edges).
	func _cap_loop(cap: PackedInt32Array, cap_next: Dictionary, plane: Plane) -> PackedInt32Array:
		var loop := PackedInt32Array()
		if cap_next.size() == cap.size():
			var v: int = cap_next.keys()[0]
			for i in cap.size():
				loop.append(v)
				v = cap_next.get(v, -1)
				if v == -1:
					break
			if v == loop[0] and loop.size() == cap.size():
				return loop
		return TFGeometry._sort_polygon(vertices, cap, plane.normal)

	# The vertex where the plane crosses the edge u-v of face f, or the cap
	# vertex within EPSILON of it. Well-conditioned: the exact intersection
	# of the plane with both faces at the edge (edges of the huge start box
	# would lose precision in a lerp). Almost parallel planes: interpolated
	# along the edge in double precision; a point between two vertices inside
	# all earlier planes stays inside them.
	func _edge_vertex(plane: Plane, u: int, v: int, f: int, cap: PackedInt32Array) -> int:
		var a := vertices[u]
		var b := vertices[v]
		var point: Variant = null
		for g in vertex_faces[u]:
			if g != f and face_alive[g] == 1 and faces[g].has(v):
				var det := plane.normal.dot(face_planes[f].normal.cross(face_planes[g].normal))
				if absf(det) >= WELL_CONDITIONED:
					point = plane.intersect_3(face_planes[f], face_planes[g])
					if point != null and _off_segment(point, a, b):
						point = null
				break
		if point == null:
			var n := plane.normal
			var da := n.x * a.x + n.y * a.y + n.z * a.z - plane.d
			var db := n.x * b.x + n.y * b.y + n.z * b.z - plane.d
			var t := clampf(da / (da - db) if da != db else 0.5, 0.0, 1.0)
			point = Vector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
		for i in cap:
			if vertices[i].distance_squared_to(point) <= TFConst.EPSILON * TFConst.EPSILON:
				return i
		var index := _add_vertex(point)
		cap.append(index)
		return index

	# Sanity check of a three-plane intersection (almost parallel planes):
	# the point must lie on the edge, within float precision of its length.
	static func _off_segment(point: Vector3, a: Vector3, b: Vector3) -> bool:
		var ab := b - a
		var length_squared := ab.length_squared()
		var t := (point - a).dot(ab) / maxf(length_squared, 1e-30)
		var slack := (TFConst.EPSILON + sqrt(length_squared) * 1e-5) / maxf(sqrt(length_squared), 1e-30)
		return t < -slack or t > 1.0 + slack or point.distance_squared_to(a + ab * t) > 1e-4 * maxf(length_squared, 1.0)
