class_name TFBridge
extends RefCounted
## Bridge between two convex loops (like Blender's Bridge Edge Loops): the
## space between them is filled by cuts + 1 convex pieces, one per pair of
## neighboring rings. Ring 0 is loop A, the last ring loop B; the rings in
## between follow the path between the loop centers (straight or a Bézier
## along the loop normals) and turn from the plane of A to the plane of B.
##
## Every ring is the offsets of A (and of B turned into the plane of A),
## blended, scaled by the profile and turned by the interpolated rotation,
## so each ring is exactly planar and neighboring pieces share it as their
## cap. A piece is the convex hull of its two rings; it is rejected if a
## ring is no cap of it (the bridge folds: more cuts or less smoothness).
##
## Normals point out of the source brushes (towards the bridge). Loops are
## convex polygons in one space (any winding); the results are in that space.

enum Interpolation { LINEAR, PATH }
enum ProfileShape { SMOOTH, SPHERE, LINEAR }

## Error codes of bridge() and loop_error() (translated by the caller).
const ERROR_LOOP := "loop"  # fewer than 3 points or no area
const ERROR_PLANAR := "planar"
const ERROR_CONCAVE := "concave"
const ERROR_TOO_MANY := "too_many"
const ERROR_FOLDS := "folds"  # a piece is no valid convex bridge piece

const DEFAULTS := {
	"cuts": 0,
	"twist": 0,
	"interpolation": Interpolation.LINEAR,
	"smoothness": 1.0,
	"profile_factor": 0.0,
	"profile_shape": ProfileShape.SMOOTH,
}


## The parameters with defaults filled in and values clamped.
static func normalized_params(params: Dictionary) -> Dictionary:
	var result := DEFAULTS.duplicate()
	result.merge(params, true)
	result["cuts"] = clampi(int(result["cuts"]), 0, TFConst.BRIDGE_MAX_CUTS)
	result["twist"] = int(result["twist"])
	result["interpolation"] = clampi(int(result["interpolation"]), 0, Interpolation.size() - 1)
	result["smoothness"] = clampf(float(result["smoothness"]), 0.0, 10.0)
	result["profile_factor"] = clampf(float(result["profile_factor"]), -1.0, 10.0)
	result["profile_shape"] = clampi(int(result["profile_shape"]), 0, ProfileShape.size() - 1)
	return result


## Bridge from loop_a (normal n_a) to loop_b (normal n_b): {"sets": plane
## sets of the pieces, "rings": the rings from A to B (matched points)}, or
## {"error": code} (ERROR_*).
static func bridge(loop_a: PackedVector3Array, n_a: Vector3, loop_b: PackedVector3Array, n_b: Vector3, params: Dictionary) -> Dictionary:
	var p := normalized_params(params)
	for loop in [loop_a, loop_b]:
		var error := loop_error(loop)
		if not error.is_empty():
			return {"error": error}
	n_a = n_a.normalized()
	n_b = n_b.normalized()
	var rings := _rings(loop_a, n_a, loop_b, n_b, p)
	if rings.is_empty():
		return {"error": ERROR_TOO_MANY}
	var sets: Array = []
	for k in rings.size() - 1:
		var cap_from := Plane(-(rings[k]["normal"] as Vector3), rings[k]["center"])
		var cap_to := Plane(rings[k + 1]["normal"], rings[k + 1]["center"])
		var planes := piece_planes(rings[k]["points"], cap_from, rings[k + 1]["points"], cap_to)
		if planes.is_empty():
			return {"error": ERROR_FOLDS}
		sets.append(planes)
	var points: Array[PackedVector3Array] = []
	for ring: Dictionary in rings:
		points.append(ring["points"])
	return {"sets": sets, "rings": points}


## "" if the loop can be bridged, else ERROR_LOOP, ERROR_PLANAR,
## ERROR_CONCAVE or ERROR_TOO_MANY.
static func loop_error(loop: PackedVector3Array) -> String:
	var points := _clean_loop(loop)
	if points.size() < 3:
		return ERROR_LOOP
	if points.size() > TFConst.BRIDGE_MAX_POINTS:
		return ERROR_TOO_MANY
	var normal := loop_normal(points)
	if normal == Vector3.ZERO:
		return ERROR_LOOP
	var center := _center(points)
	for q in points:
		if absf((q - center).dot(normal)) > TFConst.PLANE_EPSILON:
			return ERROR_PLANAR
	var n := points.size()
	for k in n:
		var e1 := points[k] - points[(k + n - 1) % n]
		var e2 := points[(k + 1) % n] - points[k]
		if e1.cross(e2).dot(normal) < -TFConst.EPSILON * e1.length() * e2.length():
			return ERROR_CONCAVE
	return ""


## Unit normal of the loop by Newell's method (counter-clockwise winding
## seen from its tip), or ZERO if the loop has no area.
static func loop_normal(loop: PackedVector3Array) -> Vector3:
	var normal := Vector3.ZERO
	var n := loop.size()
	for k in n:
		var a := loop[k]
		var b := loop[(k + 1) % n]
		normal += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
	return normal.normalized() if normal.length() > TFConst.EPSILON * TFConst.EPSILON else Vector3.ZERO


## Closed loops chained from segments ([a, b] pairs): every point must join
## exactly two segments. Empty if the segments do not form closed loops.
static func chain_loops(segments: Array) -> Array[PackedVector3Array]:
	var result: Array[PackedVector3Array] = []
	var points := PackedVector3Array()
	var links: Array = []  # per point: indices of the joined points
	for segment: Array in segments:
		var ends: Array[int] = []
		for q: Vector3 in segment:
			var index := TFHull.find_point(points, q)
			if index == -1:
				points.append(q)
				links.append([])
				index = points.size() - 1
			ends.append(index)
		if ends[0] == ends[1] or (links[ends[0]] as Array).has(ends[1]):
			continue
		links[ends[0]].append(ends[1])
		links[ends[1]].append(ends[0])
	for link: Array in links:
		if link.size() != 2:
			return []
	var used := PackedByteArray()
	used.resize(points.size())
	for start in points.size():
		if used[start]:
			continue
		var loop := PackedVector3Array()
		var previous := -1
		var current := start
		while not used[current]:
			used[current] = 1
			loop.append(points[current])
			var next: int = links[current][0] if links[current][0] != previous else links[current][1]
			previous = current
			current = next
		result.append(loop)
	return result


## Planes of the convex piece between two rings with the same point count
## (matched by index) and their caps (cap_from: outward plane at ring
## from, cap_to: at ring to). Empty if a ring is no cap of the hull or the
## piece is thinner than TFConst.BRIDGE_MIN_THICKNESS.
static func piece_planes(from: PackedVector3Array, cap_from: Plane, to: PackedVector3Array, cap_to: Plane) -> Array[Plane]:
	var result: Array[Plane] = []
	var thickness := -INF
	for q in to:
		thickness = maxf(thickness, cap_from.distance_to(q))
	for q in from:
		thickness = maxf(thickness, cap_to.distance_to(q))
	if thickness > -TFConst.BRIDGE_MIN_THICKNESS:
		return result
	var all := from + to
	var center := _center(all)
	var sides: Array[Plane] = []
	var n := from.size()
	var direct := true
	for i in n:
		var quad := [from[i], from[(i + 1) % n], to[(i + 1) % n], to[i]]
		if not _add_quad(sides, quad, center):
			direct = false
			break
	if direct:
		for plane in sides:
			for q in all:
				if plane.distance_to(q) > TFConst.PLANE_EPSILON:
					direct = false
					break
			if not direct:
				break
	if not direct:
		# Twisted or degenerate sides: the hull decides, the caps must stay.
		sides.clear()
		var found := 0
		for plane in TFHull.compute_planes(all):
			if TFGeometry.planes_equal(plane, cap_from) or TFGeometry.planes_equal(plane, cap_to):
				found += 1
			else:
				sides.append(plane)
		if found != 2:
			return result
	result.append(cap_from)
	result.append(cap_to)
	for plane in sides:
		if not result.any(func(other: Plane) -> bool: return TFGeometry.planes_equal(other, plane)):
			result.append(plane)
	if not TFGeometry.planes_to_polyhedron(result).is_valid():
		result.clear()
	return result


# Rings from A to B: {"points", "center", "normal" (travel direction, the
# ring's plane normal)}; empty if the loops need too many points.
static func _rings(loop_a: PackedVector3Array, n_a: Vector3, loop_b: PackedVector3Array, n_b: Vector3, p: Dictionary) -> Array:
	# Wind both loops the same way along the travel direction (n_a at A,
	# -n_b at B).
	var a := _wound(_clean_loop(loop_a), n_a)
	var b := _wound(_clean_loop(loop_b), -n_b)
	var count := maxi(a.size(), b.size())
	if count > TFConst.BRIDGE_MAX_POINTS:
		return []
	var c_a := _center(a)
	var c_b := _center(b)
	var turn := _rotation(n_a, -n_b, c_b - c_a)
	a = _resample(a, count)
	b = _resample(b, count)
	var off_a := PackedVector3Array()
	var off_b := PackedVector3Array()
	for i in count:
		off_a.append(a[i] - c_a)
		var o := turn.inverse() * (b[i] - c_b)
		off_b.append(o - n_a * o.dot(n_a))
	var shift := posmod(_best_shift(off_a, off_b) + int(p["twist"]), count)
	b = _shifted(b, shift)
	off_b = _shifted(off_b, shift)

	var cuts: int = p["cuts"]
	var distance := c_a.distance_to(c_b)
	var handle := float(p["smoothness"]) * distance / 3.0
	var rings: Array = []
	for k in cuts + 2:
		var t := float(k) / float(cuts + 1)
		# Axis and angle, not slerp: slerp takes the shorter way round and
		# would turn a half turn away from the other loop.
		var rotation := Quaternion(turn.get_axis(), turn.get_angle() * t) if turn.get_angle() > TFConst.NORMAL_EPSILON else Quaternion.IDENTITY
		var normal := (rotation * n_a).normalized()
		var points := PackedVector3Array()
		var center: Vector3
		if k == 0:
			points = a
			center = c_a
		elif k == cuts + 1:
			points = b
			center = c_b
		else:
			if p["interpolation"] == Interpolation.PATH:
				center = c_a.bezier_interpolate(c_a + n_a * handle, c_b + n_b * handle, c_b, t)
			else:
				center = c_a.lerp(c_b, t)
			var scale := maxf(1.0 + float(p["profile_factor"]) * _profile(p["profile_shape"], t), TFConst.BRIDGE_MIN_SCALE)
			for i in count:
				points.append(center + rotation * (off_a[i].lerp(off_b[i], t) * scale))
		# The end rings keep the exact source planes.
		if k == 0:
			normal = n_a
		elif k == cuts + 1:
			normal = -n_b
		rings.append({"points": points, "center": center, "normal": normal})
	return rings


static func _profile(shape: int, t: float) -> float:
	match shape:
		ProfileShape.SPHERE:
			return sqrt(maxf(1.0 - pow(2.0 * t - 1.0, 2.0), 0.0))
		ProfileShape.LINEAR:
			return 1.0 - absf(2.0 * t - 1.0)
	return sin(PI * t)


# Minimal rotation turning from onto to; opposite vectors turn half around
# an axis across side (so a U-turn bends towards the other loop).
static func _rotation(from: Vector3, to: Vector3, side: Vector3) -> Quaternion:
	var dot := from.dot(to)
	if dot >= 1.0 - TFConst.NORMAL_EPSILON:
		return Quaternion.IDENTITY
	if dot <= -1.0 + TFConst.NORMAL_EPSILON:
		var axis := from.cross(side)
		if axis.length() <= TFConst.EPSILON:
			axis = from.cross(Vector3.UP if absf(from.y) < 0.9 else Vector3.RIGHT)
		return Quaternion(axis.normalized(), PI)
	return Quaternion(from, to)


# Offset of b's indices matching a best (smallest sum of squared distances).
static func _best_shift(a: PackedVector3Array, b: PackedVector3Array) -> int:
	var best := 0
	var best_sum := INF
	for shift in a.size():
		var sum := 0.0
		for i in a.size():
			sum += a[i].distance_squared_to(b[(i + shift) % b.size()])
		if sum < best_sum - TFConst.EPSILON:
			best_sum = sum
			best = shift
	return best


static func _shifted(points: PackedVector3Array, shift: int) -> PackedVector3Array:
	var result := PackedVector3Array()
	for i in points.size():
		result.append(points[(i + shift) % points.size()])
	return result


# The loop with count points: extra points split the longest edges evenly.
static func _resample(loop: PackedVector3Array, count: int) -> PackedVector3Array:
	var n := loop.size()
	if count <= n:
		return loop
	var splits := PackedInt32Array()
	splits.resize(n)
	for extra in count - n:
		var best := 0
		var best_length := -1.0
		for k in n:
			var length := loop[k].distance_to(loop[(k + 1) % n]) / float(splits[k] + 1)
			if length > best_length + TFConst.EPSILON:
				best_length = length
				best = k
		splits[best] += 1
	var result := PackedVector3Array()
	for k in n:
		var next := loop[(k + 1) % n]
		for j in splits[k] + 1:
			result.append(loop[k].lerp(next, float(j) / float(splits[k] + 1)))
	return result


# The loop wound counter-clockwise around normal.
static func _wound(loop: PackedVector3Array, normal: Vector3) -> PackedVector3Array:
	if loop_normal(loop).dot(normal) >= 0.0:
		return loop
	var result := loop.duplicate()
	result.reverse()
	return result


# Adds the side planes of a quad [p0, p1, p2, p3] (one plane if planar, else
# two triangles split along the convex diagonal). False if degenerate.
static func _add_quad(planes: Array[Plane], quad: Array, center: Vector3) -> bool:
	var first: Variant = _plane_through(quad[0], quad[1], quad[2], center)
	if first == null:
		first = _plane_through(quad[0], quad[2], quad[3], center)
		if first == null:
			return false
		planes.append(first)
		return true
	var side := (first as Plane).distance_to(quad[3])
	if absf(side) <= TFConst.PLANE_EPSILON:
		planes.append(first)
		return true
	var pair: Array = [first, _plane_through(quad[0], quad[2], quad[3], center)] if side < 0.0 \
		else [_plane_through(quad[0], quad[1], quad[3], center), _plane_through(quad[1], quad[2], quad[3], center)]
	for plane: Variant in pair:
		if plane == null:
			return false
		planes.append(plane)
	return true


# Plane through a, b, c facing away from center; null if (almost) collinear.
static func _plane_through(a: Vector3, b: Vector3, c: Vector3, center: Vector3) -> Variant:
	var normal := (b - a).cross(c - a)
	if normal.length() <= TFConst.EPSILON * maxf((b - a).length(), (c - a).length()):
		return null
	var plane := Plane(normal.normalized(), a)
	if plane.distance_to(center) > 0.0:
		plane = -plane
	return plane


# The loop without repeated points (also first = last).
static func _clean_loop(loop: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	for q in loop:
		if result.is_empty() or result[-1].distance_to(q) > TFConst.EPSILON:
			result.append(q)
	if result.size() > 1 and result[0].distance_to(result[-1]) <= TFConst.EPSILON:
		result.remove_at(result.size() - 1)
	return result


static func _center(points: PackedVector3Array) -> Vector3:
	var sum := Vector3.ZERO
	for q in points:
		sum += q
	return sum / float(maxi(points.size(), 1))
