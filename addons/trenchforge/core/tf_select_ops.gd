class_name TFSelectOps
extends RefCounted
## Selection queries (same material, touching, inside) and the map repair
## used by "Validate Map". Brushes are compared in world space.


## Brushes among candidates with at least one used face of the materials.
static func brushes_with_materials(candidates: Array[TFBrush], materials: Array) -> Array[TFBrush]:
	var result: Array[TFBrush] = []
	for brush in candidates:
		var poly := brush.get_polyhedron()
		for i in brush.faces.size():
			if brush.faces[i] != null and poly.is_face_used(i) and materials.has(brush.faces[i].material):
				result.append(brush)
				break
	return result


## [brush, face_index] of all used faces among candidates with the materials.
static func faces_with_materials(candidates: Array[TFBrush], materials: Array) -> Array:
	var result: Array = []
	for brush in candidates:
		var poly := brush.get_polyhedron()
		for i in brush.faces.size():
			if brush.faces[i] != null and poly.is_face_used(i) and materials.has(brush.faces[i].material):
				result.append([brush, i])
	return result


## True if the volumes of both brushes overlap or touch (shared face, edge
## or vertex).
static func touches(a: TFBrush, b: TFBrush) -> bool:
	if not a.is_valid() or not b.is_valid():
		return false
	var box_a := (a.global_transform * a.get_local_aabb()).grow(TFConst.EPSILON)
	var box_b := (b.global_transform * b.get_local_aabb()).grow(TFConst.EPSILON)
	if not TFSpatialIndex.boxes_touch(box_a, box_b):
		return false
	# Intersection of both volumes in a's space: non-empty if any vertex
	# satisfies all planes (a flat contact still yields vertices).
	var to_a := a.global_transform.affine_inverse() * b.global_transform
	var planes := a.get_planes()
	for plane in b.get_planes():
		planes.append(TFCSG.normalized(to_a * plane))
	return not TFGeometry.planes_to_polyhedron(planes).vertices.is_empty()


## True if every vertex of inner lies inside (or on) outer.
static func contains(outer: TFBrush, inner: TFBrush) -> bool:
	if not outer.is_valid() or not inner.is_valid():
		return false
	var to_outer := outer.global_transform.affine_inverse() * inner.global_transform
	var planes := outer.get_planes()
	for v in inner.get_polyhedron().vertices:
		if not TFGeometry.point_in_brush(planes, to_outer * v):
			return false
	return true


## Candidates (not in volumes) touching any of the volume brushes.
static func touching(volumes: Array[TFBrush], candidates: Array[TFBrush]) -> Array[TFBrush]:
	var result: Array[TFBrush] = []
	for brush in candidates:
		if volumes.has(brush):
			continue
		for volume in volumes:
			if touches(volume, brush):
				result.append(brush)
				break
	return result


## Candidates (not in volumes) lying completely inside one volume brush.
static func inside(volumes: Array[TFBrush], candidates: Array[TFBrush]) -> Array[TFBrush]:
	var result: Array[TFBrush] = []
	for brush in candidates:
		if volumes.has(brush):
			continue
		for volume in volumes:
			if contains(volume, brush):
				result.append(brush)
				break
	return result


## Repair of one brush for "Validate Map". map_offset translates brush-local
## space into map space (the grid lives there). Returns
## {"status": "ok" | "remove" | "fixed", "faces": new faces (fixed only),
## "snapped": number of vertices moved onto the grid}.
## Vertices closer to the grid than grid * VALIDATE_SNAP_GRID_FRACTION are
## snapped (float drift); intentionally off-grid geometry stays.
static func repair_brush(faces: Array[TFFace], map_offset: Vector3, grid: float) -> Dictionary:
	var kept: Array[TFFace] = []
	for face in faces:
		if face != null:
			kept.append(face)
	var poly := TFGeometry.planes_to_polyhedron(TFCSG.planes_of(kept))
	if _has_nan(poly):
		return {"status": "remove", "snapped": 0}
	if not poly.is_valid():
		# Broken topology (almost coplanar planes): rebuild from the vertices.
		var planes := TFHull.compute_planes(poly.vertices)
		if planes.is_empty():
			return {"status": "remove", "snapped": 0}
		var rebuilt := TFHull.faces_for_hull(planes, kept)
		if rebuilt.is_empty():
			return {"status": "remove", "snapped": 0}
		var repaired := repair_brush(rebuilt, map_offset, grid)
		if repaired["status"] == "ok":
			return {"status": "fixed", "faces": rebuilt, "snapped": 0}
		return repaired
	var used := TFCSG.used_faces(kept)
	var tolerance := grid * TFConst.VALIDATE_SNAP_GRID_FRACTION
	var points := PackedVector3Array()
	var snapped := 0
	for v in poly.vertices:
		var p := v + map_offset
		var target := p
		for i in 3:
			var on_grid := snappedf(p[i], grid)
			if absf(on_grid - p[i]) <= tolerance:
				target[i] = on_grid
		if not target.is_equal_approx(p) and target.distance_to(p) > TFConst.EPSILON * 0.01:
			snapped += 1
		points.append(target - map_offset)
	if snapped > 0:
		var planes := TFHull.compute_planes(points)
		var result := TFGeometry.planes_to_polyhedron(planes)
		if result.is_valid():
			var snapped_faces := TFHull.faces_for_hull(planes, used)
			if not snapped_faces.is_empty():
				return {"status": "fixed", "faces": snapped_faces, "snapped": snapped}
		# Snapping would collapse the brush: leave its vertices alone.
		snapped = 0
	if used.size() != faces.size():
		var copies: Array[TFFace] = []
		for face in used:
			copies.append(face.copy())
		return {"status": "fixed", "faces": copies, "snapped": 0}
	return {"status": "ok", "snapped": 0}


static func _has_nan(poly: TFPolyhedron) -> bool:
	for v in poly.vertices:
		if is_nan(v.x) or is_nan(v.y) or is_nan(v.z) or is_inf(v.x) or is_inf(v.y) or is_inf(v.z):
			return true
	return false
