class_name TFSnap
extends RefCounted
## Grid snapping and axis helpers.

const MIN_GRID: float = 0.0625
const MAX_GRID: float = 32.0


static func snap_value(value: float, grid: float) -> float:
	return roundf(value / grid) * grid


static func snap(v: Vector3, grid: float) -> Vector3:
	return Vector3(snap_value(v.x, grid), snap_value(v.y, grid), snap_value(v.z, grid))


## Snaps a point lying on a plane with the given axis normal: the two in-plane
## coordinates are snapped, the coordinate along the axis is kept.
static func snap_in_plane(point: Vector3, axis: Vector3, grid: float) -> Vector3:
	var snapped := snap(point, grid)
	var i := axis_index(axis)
	snapped[i] = point[i]
	return snapped


## Index (0 = x, 1 = y, 2 = z) of the largest absolute component.
static func axis_index(v: Vector3) -> int:
	var a := v.abs()
	if a.x >= a.y and a.x >= a.z:
		return 0
	return 1 if a.y >= a.z else 2


## Signed unit axis closest to v.
static func dominant_axis(v: Vector3) -> Vector3:
	var result := Vector3.ZERO
	var i := axis_index(v)
	result[i] = signf(v[i]) if not is_zero_approx(v[i]) else 1.0
	return result


## Dominant horizontal (XZ) axis of v; falls back to -Z for vertical vectors.
static func dominant_horizontal_axis(v: Vector3) -> Vector3:
	var flat := Vector3(v.x, 0.0, v.z)
	if flat.length_squared() < 1e-8:
		return Vector3.FORWARD
	return dominant_axis(flat)


## True if the vector is (almost) parallel to a coordinate axis.
static func is_axis_aligned(v: Vector3) -> bool:
	var n := v.normalized()
	return absf(n[axis_index(n)]) > 1.0 - TFConst.NORMAL_EPSILON


## Halves or doubles the grid size within the allowed range.
static func step_grid(grid: float, increase: bool) -> float:
	return clampf(grid * 2.0 if increase else grid * 0.5, MIN_GRID, MAX_GRID)
