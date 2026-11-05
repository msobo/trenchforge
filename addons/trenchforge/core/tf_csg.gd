class_name TFCSG
extends RefCounted
## Clip, subtract, hollow and merge on brush faces. Pure functions: all face
## arrays live in one shared brush-local space (see transform_faces()) and
## results are new face arrays, so tools can preview them and record undo.
##
## Face attributes of the results: a plane equal to a source plane keeps that
## face; new cut faces follow the rules documented per operation.


## Copies of the faces with their planes moved by xf (e.g. from one brush's
## local space into another's). UVs live in map space and stay untouched.
static func transform_faces(faces: Array[TFFace], xf: Transform3D) -> Array[TFFace]:
	var result: Array[TFFace] = []
	for face in faces:
		if face == null:
			continue
		var copy := face.copy()
		copy.plane = normalized(xf * face.plane)
		result.append(copy)
	return result


static func normalized(plane: Plane) -> Plane:
	var length := plane.normal.length()
	if length <= 0.0:
		return plane
	return Plane(plane.normal / length, plane.d / length)


## Splits a brush by a plane. Returns [front_faces, back_faces]; a side is an
## empty array if nothing remains there. "Front" is the side the plane's
## normal points to. The new cut face gets cut_material with box-projected
## UVs, or without it the attributes of the neighbor face with the most
## similar normal.
static func clip(faces: Array[TFFace], plane: Plane, cut_material: Material = null) -> Array:
	var split := normalized(plane)
	var parts := TFGeometry.split_polyhedron_by_plane(planes_of(faces), split)
	var sources := used_faces(faces)
	var result := []
	for side in 2:
		var side_planes: Array[Plane] = parts[side]
		var cut := -split if side == 0 else split
		var side_faces: Array[TFFace] = []
		for p in side_planes:
			var exact := _find_face(sources, p)
			if exact != null:
				side_faces.append(exact.copy())
			elif cut_material != null and TFGeometry.planes_equal(p, cut):
				side_faces.append(TFFace.create(p, cut_material))
			else:
				side_faces.append(_transfer(p, sources))
		result.append(side_faces)
	return result


## Subtracts the cutter volume from the target (both in the target's space).
## Returns null if the volumes do not overlap, otherwise the fragments as an
## Array of Array[TFFace] (empty if the cutter swallows the target).
##
## Fragments keep the target's faces. The faces of the opening inherit the
## cutter face they lie on (or, with faces_from_target, the target face with
## the most similar normal). The cutter planes cut in some order (largest
## cut-off piece first); the pieces are re-merged into as few convex brushes
## as possible, then fragments thinner than min_thickness are dropped. If that
## drops volume or leaves many fragments, and at most
## TFConst.SUBTRACT_ORDER_PLANE_LIMIT planes cut, other orders are tried (see
## _alternative_orders()): the one that loses the least volume to dropped
## slivers wins, then the one with the fewest fragments, then the fewest faces.
static func subtract(target: Array[TFFace], cutter: Array[TFFace], faces_from_target: bool = false, min_thickness: float = 0.0) -> Variant:
	var target_planes := planes_of(target)
	var cutter_faces := used_faces(cutter)
	var cutter_planes := planes_of(cutter_faces)
	var combined: Array[Plane] = target_planes.duplicate()
	combined.append_array(cutter_planes)
	if TFGeometry.remove_redundant_planes(combined).is_empty():
		return null

	var target_sources := used_faces(target)
	var by_volume := _volume_order(target_planes, cutter_planes)
	var best := _subtract_in_order(target_planes, cutter_planes, by_volume, target_sources, cutter_faces, faces_from_target, min_thickness)
	# Most cuts are clean in the first order. Cutters with many planes
	# (cylinders) gain little from other orders and would take long.
	var clean: bool = best["score"][0] <= 0.0 and best["score"][1] <= TFConst.SUBTRACT_CLEAN_FRAGMENTS
	if clean or by_volume.size() > TFConst.SUBTRACT_ORDER_PLANE_LIMIT:
		return best["fragments"]
	# Dropped volumes count as equal below the volume of a min_thickness cube.
	var target_volume := TFGeometry.planes_to_polyhedron(target_planes).get_volume()
	var tolerance := maxf(TFConst.MERGE_VOLUME_EPSILON * maxf(1.0, target_volume), pow(min_thickness, 3.0))
	for order in _alternative_orders(target_planes, cutter_planes, by_volume):
		var candidate := _subtract_in_order(target_planes, cutter_planes, order, target_sources, cutter_faces, faces_from_target, min_thickness)
		if _is_better(candidate["score"], best["score"], tolerance):
			best = candidate
	return best["fragments"]


## Replaces a brush by walls of the given thickness around its volume (one
## per face; corners belong to one of the adjacent walls). Inward keeps the
## outer shape, outward keeps the inner one. The cavity faces inherit the
## face they are parallel to. Returns the walls or [] if the brush is too
## thin for the walls.
static func hollow(faces: Array[TFFace], wall: float, outward: bool = false) -> Array:
	var offset := wall if outward else -wall
	var shifted: Array[TFFace] = []
	for face in used_faces(faces):
		var copy := face.copy()
		var plane := normalized(face.plane)
		copy.plane = Plane(plane.normal, plane.d + offset)
		shifted.append(copy)
	var outer := shifted if outward else used_faces(faces)
	var inner := used_faces(faces) if outward else shifted
	if not TFGeometry.planes_to_polyhedron(planes_of(inner)).is_valid():
		return []
	var walls: Variant = subtract(outer, inner)
	return walls if walls != null else []


## Insets one face by width (like Blender's inset): the brush splits into a
## core (the brush inside the prism over the face polygon shrunk by width,
## through the whole brush) and the ring around it: one mitered piece per
## edge of the face polygon (see _ring_planes()), so every inner rim edge is
## a whole edge of one ring brush and the rim forms a closed edge loop.
## The core keeps the face as its cap; side faces of core and ring take the
## brush face with the most similar normal. Returns {} if the face or the
## shrunk polygon is degenerate, otherwise {core: Array[TFFace], core_face:
## index of the cap in core, ring: Array of Array[TFFace]}.
static func inset(faces: Array[TFFace], face_index: int, width: float, min_thickness: float = 0.0) -> Dictionary:
	var poly := _face_poly(faces, face_index)
	if poly == null or width <= TFConst.EPSILON:
		return {}
	var plane := normalized(faces[face_index].plane)
	var sides := TFBrushOps.prism_side_planes(poly, face_index, plane.normal, width)
	var core := intersect(faces, sides)
	var core_face := -1
	for i in core.size():
		if TFGeometry.planes_equal(normalized(core[i].plane), plane):
			core_face = i
	if core_face == -1 or not TFGeometry.planes_to_polyhedron(planes_of(core)).is_valid():
		return {}
	var ring: Array = []
	for i in sides.size():
		var piece := intersect(faces, _ring_planes(sides, i))
		var planes := planes_of(piece)
		var piece_poly := TFGeometry.planes_to_polyhedron(planes)
		if piece.is_empty() or not piece_poly.is_valid() or thickness(piece_poly, planes) < min_thickness:
			continue
		ring.append(piece)
	return {"core": core, "core_face": core_face, "ring": ring}


## Pushes one face into its brush by depth (extrude inward): subtracts the
## prism over the face polygon. The new bottom takes the face's attributes,
## the walls the brush face with the most similar normal. Returns the
## fragments (empty if the brush vanishes), or null for a degenerate face
## or depth <= EPSILON.
static func push_face(faces: Array[TFFace], face_index: int, depth: float, min_thickness: float = 0.0) -> Variant:
	var poly := _face_poly(faces, face_index)
	if poly == null or depth <= TFConst.EPSILON:
		return null
	var plane := normalized(faces[face_index].plane)
	var sides := TFBrushOps.prism_side_planes(poly, face_index, plane.normal)
	return subtract(faces, _prism_cutter(faces[face_index], poly, sides, plane.d + _span(poly), plane.d - depth), true, min_thickness)


## The part of the brush behind all planes (repeated clips). Returns an
## empty array if nothing remains.
static func intersect(faces: Array[TFFace], planes: Array[Plane]) -> Array[TFFace]:
	var result := used_faces(faces)
	for p in planes:
		result = clip(result, p)[1]
		if result.is_empty():
			break
	return result


## Convex hull of all given brushes (face arrays in one shared space) as one
## brush. Returns {} if the hull is invalid, otherwise {faces, added_volume}:
## added_volume > 0 means the hull fills space that no brush filled before
## (exact for brushes that do not overlap); < 0 for disjoint brushes means
## the result lost volume (hull faces of thin slivers merged into one).
static func merge(face_sets: Array) -> Dictionary:
	var points := PackedVector3Array()
	var sources: Array[TFFace] = []
	var volume := 0.0
	for faces: Array[TFFace] in face_sets:
		var poly := TFGeometry.planes_to_polyhedron(planes_of(faces))
		if not poly.is_valid():
			continue
		points.append_array(poly.vertices)
		sources.append_array(used_faces(faces))
		volume += poly.get_volume()
	var planes := TFHull.compute_planes(points)
	var hull := TFGeometry.planes_to_polyhedron(planes)
	if not hull.is_valid():
		return {}
	var faces := TFHull.faces_for_hull(planes, sources)
	if faces.is_empty():
		return {}
	var added := TFGeometry.planes_to_polyhedron(planes_of(faces)).get_volume() - volume
	return {
		"faces": faces,
		"added_volume": added if absf(added) > TFConst.MERGE_VOLUME_EPSILON * maxf(1.0, volume) else 0.0,
	}


## Merges pieces (disjoint face arrays in one space) whose union is convex,
## into as few brushes as possible: up to TFConst.REMERGE_EXACT_LIMIT pieces
## every grouping of touching pieces is considered, beyond that pairs are
## merged greedily. Returns the reduced list.
static func merge_convex_pieces(pieces: Array) -> Array:
	var n := pieces.size()
	if n < 2:
		return pieces.duplicate()
	if n > TFConst.REMERGE_EXACT_LIMIT:
		return _merge_pairs(pieces)
	var points: Array[PackedVector3Array] = []
	var volumes := PackedFloat64Array()
	var boxes: Array[AABB] = []
	for piece: Array[TFFace] in pieces:
		var poly := TFGeometry.planes_to_polyhedron(planes_of(piece))
		points.append(poly.vertices)
		volumes.append(poly.get_volume())
		boxes.append(poly.get_aabb().grow(TFConst.EPSILON))

	# Convex groups (bit masks over the pieces) grow one touching piece at a
	# time from smaller convex groups.
	var convex: Array[int] = []
	var seen := {}
	var frontier: Array[int] = []
	for i in n:
		convex.append(1 << i)
		frontier.append(1 << i)
	while not frontier.is_empty():
		var next: Array[int] = []
		for mask in frontier:
			for i in n:
				var grown := mask | (1 << i)
				if grown == mask or seen.has(grown) or not _touches(mask, i, boxes):
					continue
				seen[grown] = true
				if _is_convex_union(grown, points, volumes):
					convex.append(grown)
					next.append(grown)
		frontier = next
	if convex.size() == n:
		return pieces.duplicate()
	# Larger groups first: among equally short covers the first one found
	# keeps the biggest brushes.
	convex.sort_custom(func(a: int, b: int) -> bool: return _bit_count(a) > _bit_count(b))

	var result: Array = []
	for mask in _min_cover((1 << n) - 1, convex, {}):
		var group: Array = []
		for i in n:
			if mask & (1 << i):
				group.append(pieces[i])
		if group.size() == 1:
			result.append(group[0])
			continue
		var union := merge(group)
		if union.is_empty() or union["added_volume"] != 0.0:
			result.append_array(group)
		else:
			result.append(union["faces"])
	return result


## Smallest extent of the polyhedron across any of its faces (for a box the
## shortest side).
static func thickness(poly: TFPolyhedron, planes: Array[Plane]) -> float:
	var result := INF
	for i in planes.size():
		if not poly.is_face_used(i):
			continue
		var depth := 0.0
		for v in poly.vertices:
			depth = maxf(depth, -planes[i].distance_to(v))
		result = minf(result, depth)
	return result if result != INF else 0.0


## Normalized planes of the faces (null entries are skipped).
static func planes_of(faces: Array[TFFace]) -> Array[Plane]:
	var planes: Array[Plane] = []
	for face in faces:
		if face != null:
			planes.append(normalized(face.plane))
	return planes


## The faces that contribute a polygon (redundant and null faces removed).
static func used_faces(faces: Array[TFFace]) -> Array[TFFace]:
	var result: Array[TFFace] = []
	var valid: Array[TFFace] = []
	for face in faces:
		if face != null:
			valid.append(face)
	var poly := TFGeometry.planes_to_polyhedron(planes_of(valid))
	for i in valid.size():
		if poly.is_face_used(i):
			result.append(valid[i])
	return result


# Faces for a subtract fragment: target planes keep their faces, planes facing
# into the cutter form the opening, the cutter's own planes are hidden
# boundaries between fragments.
static func _subtract_faces(planes: Array[Plane], target: Array[TFFace], cutter: Array[TFFace], faces_from_target: bool) -> Array[TFFace]:
	var result: Array[TFFace] = []
	for p in planes:
		var exact := _find_face(target, p)
		if exact != null:
			result.append(exact.copy())
			continue
		var cutter_face := _find_face(cutter, -p)
		if cutter_face != null and not faces_from_target:
			var face := TFFace.create(p, cutter_face.material)
			face.flags = cutter_face.flags
			TFUV.copy_attributes(cutter_face, face)
			result.append(face)
		else:
			result.append(_transfer(p, target))
	return result


# Polyhedron of the brush if face_index is a used face of it, else null.
static func _face_poly(faces: Array[TFFace], face_index: int) -> TFPolyhedron:
	if face_index < 0 or face_index >= faces.size() or faces.has(null):
		return null
	var poly := TFGeometry.planes_to_polyhedron(planes_of(faces))
	return poly if poly.is_valid() and poly.is_face_used(face_index) else null


# Cutter prism along the face normal between the plane offsets top and
# bottom (n·x = top / n·x = bottom), faces with the face's attributes.
static func _prism_cutter(source: TFFace, poly: TFPolyhedron, sides: Array[Plane], top: float, bottom: float) -> Array[TFFace]:
	var n := normalized(source.plane).normal
	var planes: Array[Plane] = [Plane(n, top), Plane(-n, -bottom)]
	planes.append_array(sides)
	var result: Array[TFFace] = []
	for p in planes:
		var face := source.copy()
		face.plane = p
		result.append(face)
	return result


# Planes of ring piece i of an inset (sides: the shrunk prism side planes,
# normals pointing out): the region outside side i where side i is the
# farthest of all sides. These regions are the mitered wedges of a picture
# frame (seams from the inner to the outer polygon corners) and together
# with the core fill the whole brush.
static func _ring_planes(sides: Array[Plane], i: int) -> Array[Plane]:
	var planes: Array[Plane] = [-sides[i]]
	for j in sides.size():
		var normal := sides[j].normal - sides[i].normal
		if j != i and normal.length() > TFConst.EPSILON:
			planes.append(normalized(Plane(normal, sides[j].d - sides[i].d)))
	return planes


# A distance larger than the brush (cutter caps outside of it).
static func _span(poly: TFPolyhedron) -> float:
	return poly.get_aabb().size.length() + 1.0


static func _transfer(plane: Plane, sources: Array[TFFace]) -> TFFace:
	var planes: Array[Plane] = [plane]
	return TFHull.transfer_faces(planes, sources)[0]


static func _find_face(faces: Array[TFFace], plane: Plane) -> TFFace:
	for face in faces:
		if TFGeometry.planes_equal(normalized(face.plane), plane):
			return face
	return null


# Repeatedly merges the first pair whose convex hull has exactly their
# combined volume (fallback for many pieces).
static func _merge_pairs(pieces: Array) -> Array:
	var result := pieces.duplicate()
	var merged := true
	while merged:
		merged = false
		for i in result.size():
			for j in range(i + 1, result.size()):
				var union := merge([result[i], result[j]])
				if not union.is_empty() and union["added_volume"] == 0.0:
					result[i] = union["faces"]
					result.remove_at(j)
					merged = true
					break
			if merged:
				break
	return result


# Fragments of target minus cutter when the cutter planes cut in the given
# order: {fragments, score} with score = [dropped volume, fragment count,
# face count] (smaller is better).
static func _subtract_in_order(target_planes: Array[Plane], cutter_planes: Array[Plane], order: PackedInt32Array, target_sources: Array[TFFace], cutter_faces: Array[TFFace], faces_from_target: bool, min_thickness: float) -> Dictionary:
	var pieces: Array = []
	var remaining := target_planes
	for index in order:
		var parts := TFGeometry.split_polyhedron_by_plane(remaining, cutter_planes[index])
		var front: Array[Plane] = parts[0]
		if not front.is_empty():
			pieces.append(_subtract_faces(front, target_sources, cutter_faces, faces_from_target))
		remaining = parts[1]
		if remaining.is_empty():
			break
	var kept: Array = []
	var dropped := 0.0
	var face_count := 0
	for piece: Array[TFFace] in merge_convex_pieces(pieces):
		var planes := planes_of(piece)
		var poly := TFGeometry.planes_to_polyhedron(planes)
		if not poly.is_valid():
			continue
		if thickness(poly, planes) < min_thickness:
			dropped += poly.get_volume()
			continue
		kept.append(piece)
		face_count += piece.size()
	return {
		"fragments": kept,
		"score": [dropped, kept.size(), face_count],
	}


# The cutter planes that cut something off the target, largest cut-off piece
# first (keeps the fragment count low in most cases).
static func _volume_order(target_planes: Array[Plane], cutter_planes: Array[Plane]) -> PackedInt32Array:
	var cutting: Array = []  # [volume, index]
	for i in cutter_planes.size():
		var front: Array[Plane] = TFGeometry.split_polyhedron_by_plane(target_planes, cutter_planes[i])[0]
		if not front.is_empty():
			cutting.append([TFGeometry.planes_to_polyhedron(front).get_volume(), i])
	cutting.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var order := PackedInt32Array()
	for entry in cutting:
		order.append(entry[1])
	return order


# Further orders of the planes in by_volume: greedily by the largest piece of
# what remains, and grouped by the dominant axis of the normal (all six axis
# orders; for box cutters these are the slab decompositions). Orders equal to
# by_volume or to each other are left out.
static func _alternative_orders(target_planes: Array[Plane], cutter_planes: Array[Plane], by_volume: PackedInt32Array) -> Array[PackedInt32Array]:
	var orders: Array[PackedInt32Array] = []
	var greedy := PackedInt32Array()
	var open := by_volume.duplicate()
	var remaining := target_planes
	while not open.is_empty() and not remaining.is_empty():
		var best := -1
		var best_volume := -1.0
		for index in open:
			var front: Array[Plane] = TFGeometry.split_polyhedron_by_plane(remaining, cutter_planes[index])[0]
			var volume := TFGeometry.planes_to_polyhedron(front).get_volume() if not front.is_empty() else 0.0
			if volume > best_volume:
				best = index
				best_volume = volume
		greedy.append(best)
		open.remove_at(open.find(best))
		remaining = TFGeometry.split_polyhedron_by_plane(remaining, cutter_planes[best])[1]
	greedy.append_array(open)
	orders.append(greedy)

	for axes in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]:
		var grouped := PackedInt32Array()
		for axis: int in axes:
			for index in by_volume:
				if TFSnap.axis_index(cutter_planes[index].normal) == axis:
					grouped.append(index)
		orders.append(grouped)

	var unique: Array[PackedInt32Array] = []
	for order in orders:
		if order != by_volume and not unique.has(order):
			unique.append(order)
	return unique


# Compares subtract scores: dropped volume (within tolerance), then fragment
# count, then face count.
static func _is_better(a: Array, b: Array, tolerance: float) -> bool:
	if absf(a[0] - b[0]) > tolerance:
		return a[0] < b[0]
	if a[1] != b[1]:
		return a[1] < b[1]
	return a[2] < b[2]


# True if piece i touches (bounding boxes) any piece of the mask.
static func _touches(mask: int, i: int, boxes: Array[AABB]) -> bool:
	for j in boxes.size():
		if mask & (1 << j) and boxes[j].intersects(boxes[i]):
			return true
	return false


# True if the convex hull of the masked pieces has exactly their volume.
static func _is_convex_union(mask: int, points: Array[PackedVector3Array], volumes: PackedFloat64Array) -> bool:
	var all := PackedVector3Array()
	var volume := 0.0
	for i in points.size():
		if mask & (1 << i):
			all.append_array(points[i])
			volume += volumes[i]
	var hull := TFGeometry.planes_to_polyhedron(TFHull.compute_planes(all))
	if not hull.is_valid():
		return false
	return hull.get_volume() - volume <= TFConst.MERGE_VOLUME_EPSILON * maxf(1.0, volume)


# Fewest convex groups covering mask exactly (memoized over masks).
static func _min_cover(mask: int, convex: Array[int], memo: Dictionary) -> Array[int]:
	var result: Array[int] = []
	if mask == 0:
		return result
	if memo.has(mask):
		return memo[mask]
	var lowest := mask & -mask
	var found := false
	for group in convex:
		if (group & lowest) == 0 or (group & mask) != group:
			continue
		var rest := _min_cover(mask & ~group, convex, memo)
		if not found or rest.size() + 1 < result.size():
			result = [group]
			result.append_array(rest)
			found = true
	memo[mask] = result
	return result


static func _bit_count(mask: int) -> int:
	var count := 0
	while mask != 0:
		mask &= mask - 1
		count += 1
	return count
