class_name TFShapes
extends RefCounted
## Parametric builder shapes (cylinder, polygon prisms, stairs, pipes, walls) as pure
## functions. Shapes are returned as plane sets in the space of their input
## (usually world space); create_brush() turns a plane set into a brush
## centered on its volume.

const MIN_SIDES: int = 3
const MAX_SIDES: int = 64
const DEFAULT_SIDES: int = 16
const MAX_STEPS: int = 256
const DEFAULT_PIPE_RADIUS: float = 0.25
## Default bend radius of a pipe as a multiple of its radius.
const DEFAULT_BEND_FACTOR: float = 2.0
const DEFAULT_BEND_SEGMENTS: int = 4
const MAX_BEND_SEGMENTS: int = 32
const DEFAULT_WALL_THICKNESS: float = 0.2
const DEFAULT_WALL_HEIGHT: float = 3.0
## Sharpest turn (degrees) between two wall runs; sharper mitres would reach
## far beyond the corner.
const MAX_WALL_TURN: float = 150.0


## Planes of an n-sided cylinder fitted into the box: the polygon spans the
## full box extent across the axis (index axis_index), flat sides face the
## box axes when the side count allows it (multiples of 4 touch all four box
## sides). Empty if the box is flat.
static func cylinder_planes(box: AABB, axis_index: int, sides: int) -> Array[Plane]:
	var polygon := cylinder_polygon(box, axis_index, sides)
	if polygon.is_empty() or box.size[axis_index] < TFConst.EPSILON:
		var empty: Array[Plane] = []
		return empty
	var axis := Vector3.ZERO
	axis[axis_index] = 1.0
	return prism_planes(polygon, axis, box.size[axis_index])


## Base outline of cylinder_planes() at the low end of the box along the
## axis. Empty if the box has no area across the axis.
static func cylinder_polygon(box: AABB, axis_index: int, sides: int) -> PackedVector3Array:
	var polygon := PackedVector3Array()
	sides = clampi(sides, MIN_SIDES, MAX_SIDES)
	var u := (axis_index + 1) % 3
	var v := (axis_index + 2) % 3
	if box.size[u] < TFConst.EPSILON or box.size[v] < TFConst.EPSILON:
		return polygon
	for p in _unit_polygon(sides):
		var t := (p + Vector2.ONE) * 0.5
		var point := box.position
		point[u] += t.x * box.size[u]
		point[v] += t.y * box.size[v]
		polygon.append(point)
	return polygon


## Regular polygon with an edge (not a vertex) facing +x, stretched so its
## bounds are exactly [-1, 1]² (multiples of 4 touch all four sides).
static func _unit_polygon(sides: int) -> PackedVector2Array:
	var unit := PackedVector2Array()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for k in sides:
		var angle := (2.0 * k + 1.0) * PI / float(sides)
		var p := Vector2(cos(angle), sin(angle))
		unit.append(p)
		lo = lo.min(p)
		hi = hi.max(p)
	var result := PackedVector2Array()
	for p in unit:
		result.append((p - lo) / (hi - lo) * 2.0 - Vector2.ONE)
	return result


## Planes of the prism over the convex hull of the points, extruded by height
## along axis (unit vector; a negative height extrudes backwards). The points
## should lie in one plane perpendicular to axis; the first point defines the
## base level. Empty if the hull has no area or the height is zero.
static func prism_planes(points: PackedVector3Array, axis: Vector3, height: float) -> Array[Plane]:
	var result: Array[Plane] = []
	if absf(height) < TFConst.EPSILON or points.is_empty():
		return result
	var hull := convex_polygon(points, axis)
	if hull.size() < 3:
		return result
	var center := Vector3.ZERO
	for p in hull:
		center += p
	center /= float(hull.size())
	for k in hull.size():
		var a := hull[k]
		var b := hull[(k + 1) % hull.size()]
		var normal := (b - a).cross(axis).normalized()
		if normal.dot(center - a) > 0.0:
			normal = -normal
		result.append(Plane(normal, a))
	var base := axis.dot(points[0])
	var top := base + height
	result.append(Plane(axis, maxf(base, top)))
	result.append(Plane(-axis, -minf(base, top)))
	return result


## Convex hull of the points projected onto the plane perpendicular to axis
## (through the first point), counter-clockwise around axis. Coincident and
## collinear points are dropped; fewer than 3 points means no area.
static func convex_polygon(points: PackedVector3Array, axis: Vector3) -> PackedVector3Array:
	var result := PackedVector3Array()
	if points.is_empty():
		return result
	var u := axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT).normalized()
	var v := axis.cross(u)
	var origin := points[0]
	var flat := PackedVector2Array()
	for p in points:
		flat.append(Vector2(u.dot(p - origin), v.dot(p - origin)))
	var hull := Geometry2D.convex_hull(flat)
	# The hull repeats its first point at the end.
	if hull.size() > 1 and hull[0].is_equal_approx(hull[-1]):
		hull.remove_at(hull.size() - 1)
	var cleaned := PackedVector2Array()
	for k in hull.size():
		var prev := hull[(k - 1 + hull.size()) % hull.size()]
		var next := hull[(k + 1) % hull.size()]
		if hull[k].distance_to(prev) < TFConst.EPSILON:
			continue
		if absf((hull[k] - prev).cross(next - hull[k])) < TFConst.EPSILON * TFConst.EPSILON:
			continue
		cleaned.append(hull[k])
	if cleaned.size() < 3:
		return result
	# Godot's hull orientation depends on the handedness of (u, v); make it
	# counter-clockwise around axis.
	var area := 0.0
	for k in cleaned.size():
		area += cleaned[k].cross(cleaned[(k + 1) % cleaned.size()])
	if area < 0.0:
		cleaned.reverse()
	for p in cleaned:
		result.append(origin + u * p.x + v * p.y)
	return result


## The polygon of the points in their order (click order), projected onto
## the plane perpendicular to axis through the first point, counter-clockwise
## around axis. Coincident and collinear points are dropped. Empty if fewer
## than 3 points remain or the polygon intersects itself.
static func simple_polygon(points: PackedVector3Array, axis: Vector3) -> PackedVector3Array:
	var result := PackedVector3Array()
	if points.is_empty():
		return result
	var basis := _plane_basis(axis)
	var origin := points[0]
	var flat := _clean_loop(_flatten(points, origin, basis))
	if flat.size() < 3 or is_self_intersecting(flat):
		return result
	if _signed_area(flat) < 0.0:
		flat.reverse()
	return _unflatten(flat, origin, basis)


## True if two non-adjacent edges of the closed polygon touch or cross, or
## two adjacent edges overlap.
static func is_self_intersecting(polygon: PackedVector2Array) -> bool:
	var n := polygon.size()
	for i in n:
		var a := polygon[i]
		var b := polygon[(i + 1) % n]
		for j in range(i + 1, n):
			var c := polygon[j]
			var d := polygon[(j + 1) % n]
			if j == i + 1 or (i == 0 and j == n - 1):
				# Adjacent edges share a point; they must not fold back.
				var shared := b if j == i + 1 else a
				var p := a if j == i + 1 else b
				var q := d if j == i + 1 else c
				if absf((p - shared).cross(q - shared)) <= TFConst.EPSILON * TFConst.EPSILON and (p - shared).dot(q - shared) > 0.0:
					return true
				continue
			if Geometry2D.segment_intersects_segment(a, b, c, d) != null:
				return true
			# Touching within EPSILON counts as well.
			for point in [c, d]:
				if Geometry2D.get_closest_point_to_segment(point, a, b).distance_to(point) <= TFConst.EPSILON:
					return true
			for point in [a, b]:
				if Geometry2D.get_closest_point_to_segment(point, c, d).distance_to(point) <= TFConst.EPSILON:
					return true
	return false


## True if the polygon (any orientation) has no reflex corner.
static func is_convex(polygon: PackedVector2Array) -> bool:
	var n := polygon.size()
	var sign := 0.0
	for i in n:
		var turn := (polygon[(i + 1) % n] - polygon[i]).cross(polygon[(i + 2) % n] - polygon[(i + 1) % n])
		if absf(turn) <= TFConst.EPSILON * TFConst.EPSILON:
			continue
		if sign == 0.0:
			sign = signf(turn)
		elif signf(turn) != sign:
			return false
	return true


## Convex parts of a polygon from simple_polygon(): the polygon itself if it
## is convex, else Godot's convex decomposition with neighboring parts merged
## again wherever their union stays convex. Parts are counter-clockwise
## around axis and share their corners exactly.
static func convex_parts(polygon: PackedVector3Array, axis: Vector3) -> Array[PackedVector3Array]:
	var result: Array[PackedVector3Array] = []
	if polygon.size() < 3:
		return result
	var basis := _plane_basis(axis)
	var origin := polygon[0]
	var flat := _flatten(polygon, origin, basis)
	if is_convex(flat):
		result.append(polygon)
		return result
	var parts: Array[PackedVector2Array] = []
	for part in Geometry2D.decompose_polygon_in_convex(flat):
		var cleaned := _clean_loop(part)
		if cleaned.size() >= 3:
			if _signed_area(cleaned) < 0.0:
				cleaned.reverse()
			parts.append(cleaned)
	parts = _merge_convex_parts(parts)
	for part in parts:
		result.append(_unflatten(part, origin, basis))
	return result


## Plane sets of the prisms over the convex parts of the polygon through the
## points (click order), extruded by height along axis (see prism_planes()).
## Empty if the polygon is invalid (see simple_polygon()).
static func polygon_prisms(points: PackedVector3Array, axis: Vector3, height: float) -> Array:
	var sets: Array = []
	for part in convex_parts(simple_polygon(points, axis), axis):
		var planes := prism_planes(part, axis, height)
		if not planes.is_empty():
			sets.append(planes)
	return sets


## Greedily merges parts sharing an edge while the union stays convex.
static func _merge_convex_parts(parts: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var merged := true
	while merged:
		merged = false
		for i in parts.size():
			for j in range(i + 1, parts.size()):
				var union := _union_on_shared_edge(parts[i], parts[j])
				if union.size() >= 3 and is_convex(union):
					parts[i] = union
					parts.remove_at(j)
					merged = true
					break
			if merged:
				break
	return parts


## Union of two counter-clockwise polygons sharing an edge (a -> b in the
## first, b -> a in the second), without collinear points; empty if they
## share no edge.
static func _union_on_shared_edge(first: PackedVector2Array, second: PackedVector2Array) -> PackedVector2Array:
	var n := first.size()
	var m := second.size()
	for i in n:
		var a := first[i]
		var b := first[(i + 1) % n]
		for j in m:
			if second[j].distance_to(b) <= TFConst.EPSILON and second[(j + 1) % m].distance_to(a) <= TFConst.EPSILON:
				var union := PackedVector2Array()
				# first from b around to a, then second's points between a and b.
				for k in n:
					union.append(first[(i + 1 + k) % n])
				for k in range(2, m):
					union.append(second[(j + k) % m])
				return _clean_loop(union)
	return PackedVector2Array()


## Drops coincident and collinear points of a closed loop.
static func _clean_loop(loop: PackedVector2Array) -> PackedVector2Array:
	var points := loop.duplicate()
	var changed := true
	while changed and points.size() >= 3:
		changed = false
		for k in points.size():
			var prev := points[(k - 1 + points.size()) % points.size()]
			var next := points[(k + 1) % points.size()]
			if points[k].distance_to(prev) < TFConst.EPSILON or absf((points[k] - prev).cross(next - points[k])) < TFConst.EPSILON * TFConst.EPSILON and (points[k] - prev).dot(next - points[k]) > 0.0:
				points.remove_at(k)
				changed = true
				break
	return points


## [u, v] spanning the plane perpendicular to axis, u x v = axis.
static func _plane_basis(axis: Vector3) -> Array[Vector3]:
	var u := axis.cross(Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT).normalized()
	return [u, axis.cross(u)]


static func _flatten(points: PackedVector3Array, origin: Vector3, basis: Array[Vector3]) -> PackedVector2Array:
	var result := PackedVector2Array()
	for p in points:
		result.append(Vector2(basis[0].dot(p - origin), basis[1].dot(p - origin)))
	return result


static func _unflatten(points: PackedVector2Array, origin: Vector3, basis: Array[Vector3]) -> PackedVector3Array:
	var result := PackedVector3Array()
	for p in points:
		result.append(origin + basis[0] * p.x + basis[1] * p.y)
	return result


static func _signed_area(polygon: PackedVector2Array) -> float:
	var sum := 0.0
	for i in polygon.size():
		sum += polygon[i].cross(polygon[(i + 1) % polygon.size()])
	return sum * 0.5


## Boxes of a solid staircase filling the box: count steps rising along up
## (signed unit axis) and climbing towards forward (signed unit axis,
## perpendicular to up). Every step reaches down to the base, so the boxes
## touch but never overlap. Empty if the directions are not perpendicular.
static func stair_boxes(box: AABB, up: Vector3, forward: Vector3, count: int) -> Array[AABB]:
	var result: Array[AABB] = []
	var i := TFSnap.axis_index(up)
	var f := TFSnap.axis_index(forward)
	if i == f or count < 1:
		return result
	count = mini(count, MAX_STEPS)
	var depth := box.size[f] / float(count)
	for k in count:
		var step := box
		var rise := box.size[i] * float(k + 1) / float(count)
		step.size[i] = rise
		if up[i] < 0.0:
			step.position[i] = box.end[i] - rise
		step.size[f] = depth
		var slot := k if forward[f] > 0.0 else count - 1 - k
		step.position[f] = box.position[f] + depth * float(slot)
		result.append(step)
	return result


## Number of steps for a staircase of the given height when every step should
## be about step_height high (at least one).
static func auto_step_count(height: float, step_height: float) -> int:
	if step_height < TFConst.EPSILON:
		return 1
	return clampi(roundi(absf(height) / step_height), 1, MAX_STEPS)


## Path of a pipe: the points without duplicates and without points in the
## middle of a straight run. Empty if fewer than two points remain, a run is
## not axis-aligned or the path turns back on itself.
static func pipe_path(points: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	var empty := PackedVector3Array()
	for p in points:
		if result.is_empty() or p.distance_to(result[result.size() - 1]) >= TFConst.EPSILON:
			result.append(p)
	if result.size() < 2:
		return empty
	for i in result.size() - 1:
		if not TFSnap.is_axis_aligned(result[i + 1] - result[i]):
			return empty
	var k := 1
	while k < result.size() - 1:
		var turn := (result[k] - result[k - 1]).normalized().dot((result[k + 1] - result[k]).normalized())
		if turn < -1.0 + TFConst.NORMAL_EPSILON:
			return empty
		if turn > 1.0 - TFConst.NORMAL_EPSILON:
			result.remove_at(k)
		else:
			k += 1
	return result


## Plane sets of a solid pipe along the path (see pipe_path()): one prism per
## straight run with an n-sided cross-section (bounds 2 radius × 2 radius,
## edges facing the frame axes like cylinder_polygon()) and bend_segments
## pieces around each corner, with bend_radius at the center line. A corner
## is mitred at 45° if bend_radius or bend_segments is 0 or the bend does not
## fit (it may take a whole end run or half an inner run, and must exceed the
## cross-section's circumradius). The frame starts with an edge facing up
## (right for a vertical first run) and turns with every corner, so
## neighboring pieces share their cap planes exactly. Empty if the path is
## invalid or a run is too short for its corners.
static func pipe_sets(points: PackedVector3Array, radius: float, sides: int, bend_radius: float, bend_segments: int) -> Array:
	var sets: Array = []
	var path := pipe_path(points)
	if path.size() < 2 or radius < TFConst.EPSILON:
		return sets
	var section := _unit_polygon(clampi(sides, MIN_SIDES, MAX_SIDES))
	bend_segments = clampi(bend_segments, 0, MAX_BEND_SEGMENTS)
	var circumradius := 0.0
	for p in section:
		circumradius = maxf(circumradius, p.length() * radius)
	var count := path.size() - 1
	var dirs: Array[Vector3] = []
	var lengths: Array[float] = []
	for i in count:
		dirs.append(TFSnap.dominant_axis(path[i + 1] - path[i]))
		lengths.append(path[i].distance_to(path[i + 1]))
	# Bend radius per path point (0 = mitre; the ends have none).
	var bends: Array[float] = []
	bends.resize(path.size())
	bends.fill(0.0)
	for k in range(1, count):
		var bend := bend_radius if bend_segments > 0 else 0.0
		bend = minf(bend, lengths[k - 1] * (1.0 if k == 1 else 0.5))
		bend = minf(bend, lengths[k] * (1.0 if k == count - 1 else 0.5))
		bends[k] = bend if bend > circumradius + TFConst.EPSILON else 0.0
	# A mitre reaches back one radius into both runs.
	for i in count:
		var need := 0.0
		for k in [i, i + 1]:
			if k > 0 and k < count:
				need += bends[k] if bends[k] > 0.0 else radius
		if lengths[i] < need - TFConst.EPSILON:
			return sets
	var frame := Vector3.UP if absf(dirs[0].y) < 0.5 else Vector3.RIGHT
	for i in count:
		var d := dirs[i]
		var offsets := _pipe_section(section, frame, d.cross(frame), radius)
		var start_cap: Plane
		if i == 0 or bends[i] > 0.0:
			start_cap = Plane(-d, path[i] + d * bends[i])
		else:
			start_cap = Plane(-(dirs[i - 1] + d).normalized(), path[i])
		var end_cap: Plane
		if i == count - 1 or bends[i + 1] > 0.0:
			end_cap = Plane(d, path[i + 1] - d * bends[i + 1])
		else:
			end_cap = Plane((d + dirs[i + 1]).normalized(), path[i + 1])
		# Bends may use up a whole run.
		if lengths[i] - bends[i] - bends[i + 1] > TFConst.EPSILON:
			var planes: Array[Plane] = []
			for j in offsets.size():
				var edge := offsets[(j + 1) % offsets.size()] - offsets[j]
				var normal := edge.cross(d).normalized()
				if normal.dot(offsets[j]) < 0.0:
					normal = -normal
				planes.append(Plane(normal, path[i] + offsets[j]))
			planes.append(start_cap)
			planes.append(end_cap)
			sets.append(planes)
		if i == count - 1:
			break
		var d_out := dirs[i + 1]
		if bends[i + 1] > 0.0:
			sets.append_array(_bend_sets(path[i + 1], d, d_out, bends[i + 1], offsets, bend_segments))
		frame = TFSnap.dominant_axis(frame.rotated(d.cross(d_out), PI * 0.5))
	return sets


## Cross-section offsets (around the center line) of a pipe: the unit polygon
## along u and v, scaled by radius.
static func _pipe_section(section: PackedVector2Array, u: Vector3, v: Vector3, radius: float) -> PackedVector3Array:
	var result := PackedVector3Array()
	for p in section:
		result.append((u * p.x + v * p.y) * radius)
	return result


## Plane sets of the pieces bending a pipe around the corner from d_in to
## d_out. Each piece lies between two planes through the bend axis; its side
## faces join the rotated cross-sections (rotating a point within such a
## plane equals mirroring it at the bisector, so the four corners of each
## side are coplanar).
static func _bend_sets(corner: Vector3, d_in: Vector3, d_out: Vector3, bend: float, offsets: PackedVector3Array, segments: int) -> Array:
	var sets: Array = []
	var center := corner + (d_out - d_in) * bend
	var axis := d_in.cross(d_out)
	var start := corner - d_in * bend
	for s in segments:
		var a0 := PI * 0.5 * float(s) / float(segments)
		var a1 := PI * 0.5 * float(s + 1) / float(segments)
		var ring0 := PackedVector3Array()
		var ring1 := PackedVector3Array()
		var mid := Vector3.ZERO
		for offset in offsets:
			ring0.append(center + (start + offset - center).rotated(axis, a0))
			ring1.append(center + (start + offset - center).rotated(axis, a1))
			mid += ring0[ring0.size() - 1] + ring1[ring1.size() - 1]
		mid /= float(offsets.size() * 2)
		var planes: Array[Plane] = []
		for j in offsets.size():
			var a := ring0[j]
			var normal := (ring0[(j + 1) % offsets.size()] - a).cross(ring1[j] - a).normalized()
			if normal.dot(a - mid) < 0.0:
				normal = -normal
			planes.append(Plane(normal, a))
		# The outer caps match the straight runs exactly.
		var tangent0 := d_in if s == 0 else d_in * cos(a0) + d_out * sin(a0)
		var tangent1 := d_out if s == segments - 1 else d_in * cos(a1) + d_out * sin(a1)
		planes.append(Plane(-tangent0, center))
		planes.append(Plane(tangent1, center))
		sets.append(planes)
	return sets


## Path of a wall: the points moved onto the floor plane (perpendicular to
## up through the first point), without duplicates and without points in the
## middle of a straight run. A closed path does not repeat its first point.
## Runs may point anywhere on the floor. Empty if fewer than two points (three
## when closed) remain or the path turns sharper than MAX_WALL_TURN.
static func wall_path(points: PackedVector3Array, up: Vector3, closed: bool) -> PackedVector3Array:
	var empty := PackedVector3Array()
	if points.is_empty() or up.is_zero_approx():
		return empty
	up = up.normalized()
	var origin := points[0]
	var result := PackedVector3Array()
	for p in points:
		p -= up * up.dot(p - origin)
		if result.is_empty() or p.distance_to(result[result.size() - 1]) >= TFConst.EPSILON:
			result.append(p)
	if closed and result.size() > 1 and result[0].distance_to(result[result.size() - 1]) < TFConst.EPSILON:
		result.remove_at(result.size() - 1)
	var limit := cos(deg_to_rad(MAX_WALL_TURN))
	var k := 0 if closed else 1
	while result.size() >= (3 if closed else 2) and k < result.size() - (0 if closed else 1):
		var n := result.size()
		var before := result[posmod(k - 1, n)]
		var after := result[(k + 1) % n]
		var turn := (result[k] - before).normalized().dot((after - result[k]).normalized())
		if turn < limit:
			return empty
		if turn > 1.0 - TFConst.NORMAL_EPSILON:
			result.remove_at(k)
		else:
			k += 1
	if result.size() < (3 if closed else 2):
		return empty
	return result


## Plane sets of a wall along the path (see wall_path()): one prism per run,
## thickness wide around the path and height high above it (along up). Runs
## meet in mitres (planes through the corner along the bisector), so
## neighboring pieces share their cap planes exactly; a closed path is
## mitred at its first point as well. Empty if the path is invalid or a run
## is too short for the mitres at its ends.
static func wall_sets(points: PackedVector3Array, up: Vector3, closed: bool, thickness: float, height: float) -> Array:
	var sets: Array = []
	var path := wall_path(points, up, closed)
	if path.is_empty() or thickness < TFConst.EPSILON or height < TFConst.EPSILON:
		return sets
	up = up.normalized()
	var n := path.size()
	var count := n if closed else n - 1
	var dirs: Array[Vector3] = []
	var lengths: Array[float] = []
	for i in count:
		var offset := path[(i + 1) % n] - path[i]
		dirs.append(offset.normalized())
		lengths.append(offset.length())
	# Mitre setback per path point (how far the corner reaches back into a
	# run's side); -1 = open end.
	var setbacks: Array[float] = []
	for k in n:
		if not closed and (k == 0 or k == n - 1):
			setbacks.append(-1.0)
			continue
		var d_in := dirs[posmod(k - 1, count)]
		var d_out := dirs[k % count]
		setbacks.append(thickness * 0.5 * d_in.cross(d_out).length() / (1.0 + d_in.dot(d_out)))
	for i in count:
		var a := i
		var b := (i + 1) % n
		if lengths[i] - maxf(setbacks[a], 0.0) - maxf(setbacks[b], 0.0) < TFConst.EPSILON:
			return []
	for i in count:
		var a := i
		var b := (i + 1) % n
		var d := dirs[i]
		var side := up.cross(d).normalized()
		var planes: Array[Plane] = [
			Plane(side, path[a] + side * thickness * 0.5),
			Plane(-side, path[a] - side * thickness * 0.5),
			Plane(-up, path[a]),
			Plane(up, path[a] + up * height),
		]
		if setbacks[a] < 0.0:
			planes.append(Plane(-d, path[a]))
		else:
			planes.append(Plane(-(dirs[posmod(i - 1, count)] + d).normalized(), path[a]))
		if setbacks[b] < 0.0:
			planes.append(Plane(d, path[b]))
		else:
			planes.append(Plane((d + dirs[(i + 1) % count]).normalized(), path[b]))
		sets.append(planes)
	return sets


## The six planes of an AABB in the space of the box.
static func box_planes(box: AABB) -> Array[Plane]:
	var result: Array[Plane] = []
	var center := box.get_center()
	for plane in TFGeometry.box_planes(box.size):
		result.append(Plane(plane.normal, plane.d + plane.normal.dot(center)))
	return result


## Brush for a plane set: positioned at the center of its bounds, planes
## converted to brush-local space, one face per plane with the material.
## Returns null if the planes enclose no valid volume.
static func create_brush(planes: Array[Plane], material: Material = null) -> TFBrush:
	var poly := TFGeometry.planes_to_polyhedron(planes)
	if not poly.is_valid():
		return null
	var center := poly.get_aabb().get_center()
	var brush := TFBrush.new()
	brush.name = "Brush"
	brush.position = center
	var faces: Array[TFFace] = []
	for plane in planes:
		faces.append(TFFace.create(Plane(plane.normal, plane.d - plane.normal.dot(center)), material))
	brush.faces = faces
	return brush
