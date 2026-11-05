class_name TFUV
extends RefCounted
## The single place where TrenchForge's UV formula lives, plus every UV
## operation that has to solve it (align, fit, texture lock, transfer).
##
##   px = (p · u_axis) * ppm / scale.x + offset.x      (texture pixels)
##   py = (p · v_axis) * ppm / scale.y + offset.y
##   uv = (px, py) / texture_size
##
## p is in map space, offset is in pixels and the axes are rotated around the
## face normal by uv_rotation. Operations mutate the face they get (callers
## pass copies for undo) and take polygon vertices / planes in map space
## (see TFBrush.get_face_map_vertices()).

## Source axes count as usable on another face if they deviate at most this
## much (dot with the target normal) from the target plane.
const AXIS_IN_PLANE_LIMIT: float = 0.1


## Box-projection default axes [u_axis, v_axis] for a face normal. Wall
## textures stay upright (v points down) and are not mirrored from outside.
static func default_axes(normal: Vector3) -> Array[Vector3]:
	var ax := absf(normal.x)
	var ay := absf(normal.y)
	var az := absf(normal.z)
	var u: Vector3
	var v: Vector3
	if ay >= ax and ay >= az:
		u = Vector3.RIGHT
		v = Vector3.BACK if normal.y > 0.0 else Vector3.FORWARD
	elif ax >= az:
		u = Vector3.FORWARD if normal.x > 0.0 else Vector3.BACK
		v = Vector3.DOWN
	else:
		u = Vector3.RIGHT if normal.z > 0.0 else Vector3.LEFT
		v = Vector3.DOWN
	var axes: Array[Vector3] = [u, v]
	return axes


## Returns the UV axes after applying the face rotation.
static func rotated_axes(face: TFFace) -> Array[Vector3]:
	var u := face.u_axis
	var v := face.v_axis
	if not is_zero_approx(face.uv_rotation):
		var normal := face.plane.normal.normalized()
		var angle := deg_to_rad(face.uv_rotation)
		u = u.rotated(normal, angle)
		v = v.rotated(normal, angle)
	var axes: Array[Vector3] = [u, v]
	return axes


## uv_scale with (near) zero components replaced by 1.
static func safe_scale(face: TFFace) -> Vector2:
	var scale := face.uv_scale
	if absf(scale.x) < TFConst.MIN_UV_SCALE:
		scale.x = 1.0
	if absf(scale.y) < TFConst.MIN_UV_SCALE:
		scale.y = 1.0
	return scale


## Texture pixel coordinate of a map-space point (the UV formula).
static func pixel_coord(face: TFFace, axes: Array[Vector3], map_point: Vector3, ppm: float) -> Vector2:
	var scale := safe_scale(face)
	return Vector2(
		map_point.dot(axes[0]) * ppm / scale.x + face.uv_offset.x,
		map_point.dot(axes[1]) * ppm / scale.y + face.uv_offset.y,
	)


static func compute_uv(face: TFFace, axes: Array[Vector3], map_point: Vector3, texture_size: Vector2, ppm: float) -> Vector2:
	return pixel_coord(face, axes, map_point, ppm) / texture_size


## The texture a material displays (albedo; ShaderMaterials use the
## parameter named in the project settings), or null without one.
static func get_texture(material: Material) -> Texture2D:
	var texture: Texture2D = null
	if material is BaseMaterial3D:
		texture = (material as BaseMaterial3D).albedo_texture
	elif material is ShaderMaterial:
		var value: Variant = (material as ShaderMaterial).get_shader_parameter(TFConst.get_shader_texture_param())
		if value is Texture2D:
			texture = value
	if texture != null and texture.get_width() > 0 and texture.get_height() > 0:
		return texture
	return null


## Pixel size of the texture a material displays; falls back to the default.
static func get_texture_size(material: Material) -> Vector2:
	var texture := get_texture(material)
	return Vector2(texture.get_size()) if texture != null else Vector2(TFConst.DEFAULT_TEXTURE_SIZE)


# --- basic adjustments ---------------------------------------------------------

## Box-projection defaults: axes from the normal, no offset/scale/rotation.
static func reset(face: TFFace) -> void:
	face.reset_uv_axes()
	face.uv_offset = Vector2.ZERO
	face.uv_scale = Vector2.ONE
	face.uv_rotation = 0.0


## Like reset(), but the axes lie in the face plane (plane_axes()) instead
## of being box-projected: no distortion on sloped faces.
static func reset_to_plane(face: TFFace) -> void:
	var axes := plane_axes(face.plane.normal)
	face.u_axis = axes[0]
	face.v_axis = axes[1]
	face.uv_offset = Vector2.ZERO
	face.uv_scale = Vector2.ONE
	face.uv_rotation = 0.0


## Orthonormal axes [u, v] in the plane: u is the box-projection u axis
## projected into the plane, v = u × normal (same handedness as
## default_axes(), so the texture is not mirrored from outside).
static func plane_axes(normal: Vector3) -> Array[Vector3]:
	var n := normal.normalized()
	var defaults := default_axes(n)
	var u := defaults[0] - n * defaults[0].dot(n)
	if u.length() < TFConst.EPSILON:
		return defaults
	u = u.normalized()
	var axes: Array[Vector3] = [u, u.cross(n)]
	return axes


static func rotate(face: TFFace, degrees: float) -> void:
	face.uv_rotation = wrapf(face.uv_rotation + degrees, -180.0, 180.0)


## Mirrors the texture along one axis (0 = u, 1 = v) around the face center.
static func flip(face: TFFace, vertices: PackedVector3Array, ppm: float, axis: int) -> void:
	var axes := rotated_axes(face)
	var center := _range(vertices, axes[axis])
	var c := (center.x + center.y) * 0.5
	var scale := safe_scale(face)
	var before := c * ppm / scale[axis] + face.uv_offset[axis]
	scale[axis] = -scale[axis]
	face.uv_scale = scale
	var offset := face.uv_offset
	offset[axis] = before - c * ppm / scale[axis]
	face.uv_offset = offset


## Shifts the offset by delta pixels and wraps it into one texture tile.
static func shift(face: TFFace, delta: Vector2, texture_size: Vector2) -> void:
	face.uv_offset += delta
	wrap_offset(face, texture_size)


static func random_offset(face: TFFace, texture_size: Vector2, rng: RandomNumberGenerator) -> void:
	face.uv_offset = Vector2(
		rng.randi_range(0, maxi(int(texture_size.x) - 1, 0)),
		rng.randi_range(0, maxi(int(texture_size.y) - 1, 0)),
	)


## Wraps the offset into [0, texture_size); shifting by whole tiles is invisible.
static func wrap_offset(face: TFFace, texture_size: Vector2) -> void:
	face.uv_offset = Vector2(fposmod(face.uv_offset.x, texture_size.x), fposmod(face.uv_offset.y, texture_size.y))


# --- align ---------------------------------------------------------------------

## Exactly one tile across the face along u and/or v (flips are kept).
static func fit(face: TFFace, vertices: PackedVector3Array, texture_size: Vector2, ppm: float, fit_u: bool = true, fit_v: bool = true) -> void:
	if fit_u:
		_fit_axis(face, vertices, texture_size, ppm, 0)
	if fit_v:
		_fit_axis(face, vertices, texture_size, ppm, 1)


## Puts the texture center onto the face center, keeping scale and rotation.
static func center(face: TFFace, vertices: PackedVector3Array, texture_size: Vector2, ppm: float) -> void:
	var axes := rotated_axes(face)
	var scale := safe_scale(face)
	var offset := face.uv_offset
	for i in 2:
		var extent := _range(vertices, axes[i])
		var c := (extent.x + extent.y) * 0.5
		offset[i] = texture_size[i] * 0.5 - c * ppm / scale[i]
	face.uv_offset = offset
	wrap_offset(face, texture_size)


## Aligns the axes to the polygon edge vertices[edge] -> vertices[edge + 1]:
## u runs along the edge, v points from the face interior towards the edge
## (texture bottom faces the edge). Offset and scale are kept.
static func align_to_edge(face: TFFace, vertices: PackedVector3Array, edge: int) -> void:
	var a := vertices[edge]
	var b := vertices[(edge + 1) % vertices.size()]
	var normal := face.plane.normal.normalized()
	var u := (b - a).normalized()
	var v := normal.cross(u)
	if v.dot(_centroid(vertices) - a) > 0.0:
		v = -v
	# Not mirrored when seen from outside (same handedness as default_axes).
	if u.cross(v).dot(normal) > 0.0:
		u = -u
	face.u_axis = u
	face.v_axis = v
	face.uv_rotation = 0.0


## Face snap: aligns to an edge and snaps the offset so a tile's bottom sits
## on the edge and starts at its first corner. fit_u/fit_v fit one tile.
static func snap_to_edge(face: TFFace, vertices: PackedVector3Array, edge: int, texture_size: Vector2, ppm: float, fit_u: bool = false, fit_v: bool = false) -> void:
	align_to_edge(face, vertices, edge)
	var axes := rotated_axes(face)
	var a := vertices[edge]
	var b := vertices[(edge + 1) % vertices.size()]
	var scale := safe_scale(face)
	var offset := face.uv_offset
	offset.x = -minf(a.dot(axes[0]), b.dot(axes[0])) * ppm / scale.x
	offset.y = -a.dot(axes[1]) * ppm / scale.y
	face.uv_offset = offset
	wrap_offset(face, texture_size)
	fit(face, vertices, texture_size, ppm, fit_u, fit_v)


## Index of the lowest edge (by midpoint height); ties go to the longest.
## Floors and ceilings therefore use their longest edge.
static func bottom_edge(vertices: PackedVector3Array) -> int:
	var best := -1
	var best_y := INF
	var best_length := 0.0
	for i in vertices.size():
		var a := vertices[i]
		var b := vertices[(i + 1) % vertices.size()]
		var y := (a.y + b.y) * 0.5
		var length := a.distance_to(b)
		if y < best_y - TFConst.EPSILON or (absf(y - best_y) <= TFConst.EPSILON and length > best_length):
			best = i
			best_y = y
			best_length = length
	return best


# --- texture lock --------------------------------------------------------------

## Compensates the offset for a map-space translation so the texture sticks
## to the face.
static func lock_translation(face: TFFace, map_delta: Vector3, ppm: float) -> void:
	var axes := rotated_axes(face)
	var scale := safe_scale(face)
	face.uv_offset -= Vector2(map_delta.dot(axes[0]) * ppm / scale.x, map_delta.dot(axes[1]) * ppm / scale.y)


## Compensates the offset of a face whose axes were already rotated by
## rotation around map_pivot. old_axes are the rotated axes before.
static func lock_rotation(face: TFFace, old_axes: Array[Vector3], rotation: Basis, map_pivot: Vector3, ppm: float) -> void:
	var scale := safe_scale(face)
	var offset := face.uv_offset
	for i in 2:
		offset[i] += (old_axes[i].dot(map_pivot) - (rotation * old_axes[i]).dot(map_pivot)) * ppm / scale[i]
	face.uv_offset = offset


# --- transfer between faces ----------------------------------------------------

## Copies the UV attributes of source onto target. Box-projected axes stay
## box-projected; custom axes are kept if they fit the target plane.
static func copy_attributes(source: TFFace, target: TFFace) -> void:
	var target_normal := target.plane.normal.normalized()
	var source_default := default_axes(source.plane.normal)
	var is_default := source.u_axis.is_equal_approx(source_default[0]) and source.v_axis.is_equal_approx(source_default[1])
	var fits := absf(source.u_axis.normalized().dot(target_normal)) < AXIS_IN_PLANE_LIMIT \
		and absf(source.v_axis.normalized().dot(target_normal)) < AXIS_IN_PLANE_LIMIT
	if is_default or not fits:
		target.reset_uv_axes()
	else:
		target.u_axis = source.u_axis
		target.v_axis = source.v_axis
	target.uv_offset = source.uv_offset
	target.uv_scale = source.uv_scale
	target.uv_rotation = source.uv_rotation


## Seamless continuation: the source projection is folded around the line
## where both planes meet, so the texture runs on across the edge without a
## seam. Planes are in map space. Copies scale; rotation is baked into axes.
static func wrap_attributes(source: TFFace, source_plane: Plane, target: TFFace, target_plane: Plane, ppm: float) -> void:
	var ns := source_plane.normal.normalized()
	var nt := target_plane.normal.normalized()
	var dot := ns.dot(nt)
	if dot > 1.0 - TFConst.NORMAL_EPSILON:
		# Coplanar or parallel: world-fixed UVs already continue seamlessly.
		target.u_axis = source.u_axis
		target.v_axis = source.v_axis
		target.uv_offset = source.uv_offset
		target.uv_scale = source.uv_scale
		target.uv_rotation = source.uv_rotation
		return
	if dot < -1.0 + TFConst.NORMAL_EPSILON:
		copy_attributes(source, target)
		return
	var hinge := ns.cross(nt).normalized()
	var rotation := Basis(hinge, ns.signed_angle_to(nt, hinge))
	var point: Variant = source_plane.intersect_3(target_plane, Plane(hinge, 0.0))
	var on_hinge: Vector3 = point if point != null else Vector3.ZERO
	var axes := rotated_axes(source)
	var scale := safe_scale(source)
	target.u_axis = rotation * axes[0]
	target.v_axis = rotation * axes[1]
	target.uv_rotation = 0.0
	target.uv_scale = source.uv_scale
	var offset := source.uv_offset
	for i in 2:
		offset[i] += (axes[i].dot(on_hinge) - (rotation * axes[i]).dot(on_hinge)) * ppm / scale[i]
	target.uv_offset = offset


## Copies the UV attributes and stretches them so the target shows the same
## number of tiles as the source, starting at the same texture position.
static func stretch_attributes(source: TFFace, source_vertices: PackedVector3Array, target: TFFace, target_vertices: PackedVector3Array, ppm: float) -> void:
	copy_attributes(source, target)
	var source_axes := rotated_axes(source)
	var target_axes := rotated_axes(target)
	var source_scale := safe_scale(source)
	var scale := safe_scale(target)
	var offset := target.uv_offset
	for i in 2:
		var s := _range(source_vertices, source_axes[i])
		var t := _range(target_vertices, target_axes[i])
		if s.y - s.x > TFConst.EPSILON and t.y - t.x > TFConst.EPSILON:
			scale[i] = source_scale[i] * (t.y - t.x) / (s.y - s.x)
		var source_start := s.x if source_scale[i] > 0.0 else s.y
		var target_start := t.x if scale[i] > 0.0 else t.y
		var start_px := source_start * ppm / source_scale[i] + source.uv_offset[i]
		offset[i] = start_px - target_start * ppm / scale[i]
	target.uv_scale = scale
	target.uv_offset = offset


# --- UV editor (pixel space) ---------------------------------------------------
# The UV editor works in texture pixels: every map point is mapped with
# pixel_coord(). Scale, rotation and shear happen around an origin (pixels)
# whose face point stays where it is. Shear is expressed by non-orthogonal
# u/v axes; align_to_edge(), snap_to_edge() and both resets remove it.

## Face polygon (map space) in texture pixels.
static func to_uv_space(face: TFFace, vertices: PackedVector3Array, ppm: float) -> PackedVector2Array:
	var axes := rotated_axes(face)
	var result := PackedVector2Array()
	for v in vertices:
		result.append(pixel_coord(face, axes, v, ppm))
	return result


## Affine map from plane coordinates (meters along basis[0] / basis[1],
## measured from plane_point) to texture pixels.
static func face_transform(face: TFFace, plane_point: Vector3, basis: Array[Vector3], ppm: float) -> Transform2D:
	var axes := rotated_axes(face)
	var origin := pixel_coord(face, axes, plane_point, ppm)
	return Transform2D(
		pixel_coord(face, axes, plane_point + basis[0], ppm) - origin,
		pixel_coord(face, axes, plane_point + basis[1], ppm) - origin,
		origin,
	)


## Map-space point of the face plane (through vertices[0]) that is shown at
## the pixel, or null if the axes are degenerate.
static func unproject(face: TFFace, pixel: Vector2, vertices: PackedVector3Array, ppm: float) -> Variant:
	if vertices.is_empty():
		return null
	var normal := face.plane.normal.normalized()
	var axes := _pixel_axes(face, ppm)
	var rows := Basis(axes[0], axes[1], normal).transposed()
	if absf(rows.determinant()) < TFConst.EPSILON:
		return null
	return rows.inverse() * Vector3(pixel.x - face.uv_offset.x, pixel.y - face.uv_offset.y, normal.dot(vertices[0]))


## Moves the texture by delta pixels (no wrap; see wrap_offset()).
static func translate_uv(face: TFFace, delta_px: Vector2) -> void:
	face.uv_offset += delta_px


## Scales the texture around the origin: pixel distances from the origin
## grow by factor per axis. Flips are kept, MIN_UV_SCALE is respected.
static func scale_about(face: TFFace, origin_px: Vector2, factor: Vector2) -> void:
	var scale := safe_scale(face)
	var f := Vector2(maxf(factor.x, TFConst.MIN_UV_SCALE_FACTOR), maxf(factor.y, TFConst.MIN_UV_SCALE_FACTOR))
	var new_scale := scale / f
	for i in 2:
		if absf(new_scale[i]) < TFConst.MIN_UV_SCALE:
			new_scale[i] = signf(scale[i]) * TFConst.MIN_UV_SCALE
			f[i] = scale[i] / new_scale[i]
	face.uv_scale = new_scale
	face.uv_offset = origin_px + (face.uv_offset - origin_px) * f


## Rotates the texture by degrees (counterclockwise seen from outside, like
## rotate()) around the origin; vertices give the face plane.
static func rotate_about(face: TFFace, origin_px: Vector2, degrees: float, vertices: PackedVector3Array, ppm: float) -> void:
	var point: Variant = unproject(face, origin_px, vertices, ppm)
	rotate(face, degrees)
	if point != null:
		face.uv_offset += origin_px - pixel_coord(face, rotated_axes(face), point, ppm)


## Shears the texture around the origin: x pixels move by shear.x times the
## y distance from the origin, y pixels by shear.y times the x distance.
## Axes stay unit length (uv_scale absorbs the stretch); rotation is kept.
static func shear_about(face: TFFace, origin_px: Vector2, shear: Vector2, ppm: float) -> void:
	if 1.0 - shear.x * shear.y < TFConst.MIN_UV_SHEAR:
		return
	var axes := _pixel_axes(face, ppm)
	var offset := face.uv_offset
	if not _set_pixel_axes(face, axes[0] + axes[1] * shear.x, axes[1] + axes[0] * shear.y, ppm):
		return
	face.uv_offset = Vector2(offset.x + shear.x * (offset.y - origin_px.y), offset.y + shear.y * (offset.x - origin_px.x))


## Shear of the texture: the cosine of the angle between the in-plane axes
## (0 = orthogonal, unsheared).
static func shear_amount(face: TFFace) -> float:
	var u := face.u_axis.normalized()
	var v := face.v_axis.normalized()
	return u.dot(v)


## The candidate nearest to the point within radius, or null.
static func snap_point(point_px: Vector2, candidates_px: PackedVector2Array, radius_px: float) -> Variant:
	var best: Variant = null
	var best_distance := radius_px
	for candidate in candidates_px:
		var distance := point_px.distance_to(candidate)
		if distance <= best_distance:
			best = candidate
			best_distance = distance
	return best


## One-dimensional snap_point() (grid lines, origin axes).
static func snap_line(value: float, candidates: PackedFloat32Array, radius: float) -> Variant:
	var best: Variant = null
	var best_distance := radius
	for candidate in candidates:
		var distance := absf(value - candidate)
		if distance <= best_distance:
			best = candidate
			best_distance = distance
	return best


## Offset delta (see translate_uv()) that puts the polygon point nearest to
## a grid corner (multiples of cell) onto that corner; ZERO if none is
## within radius.
static func snap_offset(polygon_px: PackedVector2Array, cell: Vector2, radius_px: float) -> Vector2:
	var best := Vector2.ZERO
	var best_distance := radius_px
	for p in polygon_px:
		var corner := (p / cell).round() * cell
		var distance := p.distance_to(corner)
		if distance <= best_distance:
			best = corner - p
			best_distance = distance
	return best


## Angles (radians, as Vector2.angle()) of the polygon edges.
static func edge_angles(polygon_px: PackedVector2Array) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	for i in polygon_px.size():
		var edge := polygon_px[(i + 1) % polygon_px.size()] - polygon_px[i]
		if edge.length() > TFConst.EPSILON:
			result.append(edge.angle())
	return result


## Smallest angle change (radians) that turns one of the edge angles onto a
## texture axis (multiple of 90°) if it is within limit_degrees, else null.
static func snap_angle(angles: PackedFloat32Array, limit_degrees: float) -> Variant:
	var best: Variant = null
	for angle in angles:
		var delta := snappedf(angle, PI * 0.5) - angle
		if absf(delta) <= deg_to_rad(limit_degrees) and (best == null or absf(delta) < absf(best)):
			best = delta
	return best


## Positions of the grid lines (multiples of cell) between from and to; at
## most about max_lines, thinned to every n-th line if there are more.
static func grid_lines(from: float, to: float, cell: float, max_lines: int) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	if cell <= TFConst.EPSILON or to < from or max_lines < 1:
		return result
	var first := floori(from / cell)
	var last := ceili(to / cell)
	var step := maxi(1, ceili(float(last - first + 1) / float(max_lines)))
	first = floori(float(first) / float(step)) * step
	for k in range(first, last + 1, step):
		result.append(k * cell)
	return result


# --- helpers -------------------------------------------------------------------

## Pixels per map meter along the rotated axes: px = p · a_u + offset.x.
static func _pixel_axes(face: TFFace, ppm: float) -> Array[Vector3]:
	var axes := rotated_axes(face)
	var scale := safe_scale(face)
	var result: Array[Vector3] = [axes[0] * ppm / scale.x, axes[1] * ppm / scale.y]
	return result


## Inverse of _pixel_axes(): unit axes and uv_scale (signs and rotation
## kept) for new pixel axes. False if one of them is degenerate.
static func _set_pixel_axes(face: TFFace, a_u: Vector3, a_v: Vector3, ppm: float) -> bool:
	if a_u.length() < TFConst.EPSILON or a_v.length() < TFConst.EPSILON:
		return false
	var scale := safe_scale(face)
	var new_scale := Vector2(signf(scale.x) * ppm / a_u.length(), signf(scale.y) * ppm / a_v.length())
	var normal := face.plane.normal.normalized()
	var angle := -deg_to_rad(face.uv_rotation)
	face.u_axis = (a_u * new_scale.x / ppm).rotated(normal, angle)
	face.v_axis = (a_v * new_scale.y / ppm).rotated(normal, angle)
	face.uv_scale = new_scale
	return true


static func _fit_axis(face: TFFace, vertices: PackedVector3Array, texture_size: Vector2, ppm: float, i: int) -> void:
	var axes := rotated_axes(face)
	var extent := _range(vertices, axes[i])
	var length := extent.y - extent.x
	if length < TFConst.EPSILON:
		return
	var scale := safe_scale(face)
	var flipped := scale[i] < 0.0
	scale[i] = (-1.0 if flipped else 1.0) * length * ppm / texture_size[i]
	face.uv_scale = scale
	var offset := face.uv_offset
	offset[i] = -(extent.y if flipped else extent.x) * ppm / scale[i]
	face.uv_offset = offset


## Min and max of the vertices projected onto axis (meters).
static func _range(vertices: PackedVector3Array, axis: Vector3) -> Vector2:
	var result := Vector2(INF, -INF)
	for v in vertices:
		var d := v.dot(axis)
		result.x = minf(result.x, d)
		result.y = maxf(result.y, d)
	return result


static func _centroid(vertices: PackedVector3Array) -> Vector3:
	var sum := Vector3.ZERO
	for v in vertices:
		sum += v
	return sum / float(maxi(vertices.size(), 1))
