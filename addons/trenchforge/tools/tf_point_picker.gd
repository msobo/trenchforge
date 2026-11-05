@tool
class_name TFPointPicker
extends RefCounted
## Anvil-style point selection shared by all click tools.
##
## Points follow the surface under the cursor; without a hit they land on the
## work plane (default y = 0). The work plane is always horizontal: starting
## a brush on a floor or roof moves it to that height, a wall never does.
## Pressing Ctrl over a surface locks that surface while Ctrl stays held (the
## cursor slides over geometry on it, e.g. to start a roof outside the walls
## at ceiling height); a horizontal surface also stays the work plane after
## Ctrl is released. Ctrl over empty space resets the work plane to y = 0.
## All points are grid-snapped.

## Below this |dot(ray, normal)| a plane counts as edge-on to the camera.
const EDGE_ON_LIMIT: float = 0.05

var work_plane := Plane(Vector3.UP, 0.0)
## Plane used while Ctrl is held; may be vertical (e.g. a wall).
var _lock_plane := Plane(Vector3.UP, 0.0)
var _locked := false
## Last mouse position without Ctrl; its surface becomes the work plane when
## Ctrl goes down.
var _unlocked_pos: Variant = null


## Called once per viewport event before any tool picks. On the Ctrl press
## the surface under the cursor becomes the work plane.
func update_lock(ctx: TFEditorContext, camera: Camera3D, event: InputEvent) -> void:
	if not event is InputEventWithModifiers:
		return
	var locked := TFTool.is_ctrl(event)
	if event is InputEventMouse and not locked:
		_unlocked_pos = event.position
	if locked and not _locked and _unlocked_pos != null:
		var hit := ctx.pick(camera, _unlocked_pos)
		if hit.is_empty():
			work_plane = Plane(Vector3.UP, 0.0)
			_lock_plane = work_plane
		else:
			var axis := TFSnap.dominant_axis(hit["normal"])
			var point := TFSnap.snap_in_plane(hit["position"], axis, ctx.grid_size())
			_lock_plane = Plane(_lock_axis(hit["brush"], point, axis), point)
			adopt_plane(_lock_plane)
	_locked = locked


## Makes plane the work plane if it is horizontal; vertical or slanted planes
## (walls) are ignored so free space keeps drawing floors.
func adopt_plane(plane: Plane) -> void:
	if absf(plane.normal.y) > 1.0 - TFConst.EPSILON:
		work_plane = Plane(Vector3.UP, plane.normal.y * plane.d)


## On a horizontal edge (e.g. a wall's top edge hit from the side) the top or
## bottom face wins: locking there means "stay at this height".
static func _lock_axis(brush: TFBrush, point: Vector3, axis: Vector3) -> Vector3:
	if not is_zero_approx(axis.y):
		return axis
	for local_plane in brush.get_planes():
		var plane := brush.global_transform * local_plane
		var is_horizontal := plane.normal.is_equal_approx(Vector3.UP) or plane.normal.is_equal_approx(Vector3.DOWN)
		if is_horizontal and absf(plane.distance_to(point)) < TFConst.EPSILON:
			return plane.normal
	return axis


## Returns {} if nothing could be picked, otherwise
## {point, normal (signed unit axis), on_surface, brush, face_index}.
func pick(ctx: TFEditorContext, camera: Camera3D, screen_pos: Vector2, lock_plane: bool) -> Dictionary:
	var origin := camera.project_ray_origin(screen_pos)
	var direction := camera.project_ray_normal(screen_pos)
	var grid := ctx.grid_size()

	if not lock_plane:
		var hit := ctx.pick(camera, screen_pos)
		if not hit.is_empty():
			var axis := TFSnap.dominant_axis(hit["normal"])
			return {
				"point": TFSnap.snap_in_plane(hit["position"], axis, grid),
				"normal": axis,
				"on_surface": true,
				"brush": hit["brush"],
				"face_index": hit["face_index"],
			}

	var plane := _lock_plane if lock_plane and _locked else work_plane
	if absf(plane.normal.dot(direction)) < EDGE_ON_LIMIT:
		# Edge-on (e.g. side ortho view): use the plane facing the camera
		# through the work plane's origin point.
		var axis := TFSnap.dominant_axis(-direction)
		plane = Plane(axis, axis.dot(plane.get_center()))
	var point: Variant = plane.intersects_ray(origin, direction)
	if point == null:
		return {}
	var normal := TFSnap.dominant_axis(plane.normal)
	return {
		"point": TFSnap.snap_in_plane(point, normal, grid),
		"normal": normal,
		"on_surface": false,
		"brush": null,
		"face_index": -1,
	}


## Intersects the mouse ray with an explicit plane and snaps the result.
func pick_on_plane(ctx: TFEditorContext, camera: Camera3D, screen_pos: Vector2, plane: Plane) -> Variant:
	var point: Variant = plane.intersects_ray(camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos))
	if point == null:
		return null
	return TFSnap.snap_in_plane(point, TFSnap.dominant_axis(plane.normal), ctx.grid_size())


## Signed distance along axis from base to the point on the line
## (base + axis * t) closest to the mouse ray, snapped to the grid.
static func pick_along_axis(camera: Camera3D, screen_pos: Vector2, base: Vector3, axis: Vector3, grid: float, absolute_snap: bool = false) -> float:
	var t := closest_line_parameter(camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos), base, axis)
	if absolute_snap and TFSnap.is_axis_aligned(axis):
		var i := TFSnap.axis_index(axis)
		var start := base[i]
		var target := TFSnap.snap_value(start + t * axis[i], grid)
		return (target - start) * axis[i]
	return TFSnap.snap_value(t, grid)


## Parameter t of the point on line (base + axis * t) closest to the ray.
static func closest_line_parameter(ray_origin: Vector3, ray_dir: Vector3, base: Vector3, axis: Vector3) -> float:
	var w := base - ray_origin
	var a := axis.dot(axis)
	var b := axis.dot(ray_dir)
	var c := ray_dir.dot(ray_dir)
	var d := axis.dot(w)
	var e := ray_dir.dot(w)
	var denom := a * c - b * b
	if absf(denom) < 1e-8:
		return 0.0
	return (b * e - c * d) / denom
