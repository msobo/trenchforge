@tool
class_name TFShapeTool
extends TFBoxTool
## Parametric builders (Anvil): cylinder and stairs are drawn like a box
## (start, base, height) and fitted into it. The polygon builder collects
## points on the base plane and extrudes the polygon in click order; a
## concave polygon is split into convex prisms inside a new compound. Stairs
## become one brush per step inside a new group. A pipe follows a right-angled
## path clicked point by point (Shift: vertical run) and becomes a compound of
## straight runs and bend pieces. A wall follows a path on the floor, clicked
## or dragged run by run (right-angled, Shift: diagonal), and becomes a
## compound of mitred pieces; clicking the first point closes it.

enum Shape { CYLINDER, POLYGON, STAIRS, PIPE, WALL }

## Names per Shape (English, translated when shown).
const SHAPE_NAMES: Array[String] = ["Cylinder", "Polygon", "Stairs", "Pipe", "Wall"]
const STAIRS_GROUP_NAME := "Stairs"
const PIPE_GROUP_NAME := "Pipe"
const WALL_GROUP_NAME := "Wall"

var shape := Shape.CYLINDER
var sides := TFShapes.DEFAULT_SIDES
## Fixed step count; 0 = automatic (steps about one grid step high).
var steps := 0
## Quarter turns (counter-clockwise around the build axis) of the stair
## direction relative to the default (along the longer base side, away from
## the start point).
var stair_turns := 0
var pipe_radius := TFShapes.DEFAULT_PIPE_RADIUS
## Bend radius at the pipe's center line; 0 = mitred corners.
var bend_radius := TFShapes.DEFAULT_PIPE_RADIUS * TFShapes.DEFAULT_BEND_FACTOR
var bend_segments := TFShapes.DEFAULT_BEND_SEGMENTS
var wall_thickness := TFShapes.DEFAULT_WALL_THICKNESS
var wall_height := TFShapes.DEFAULT_WALL_HEIGHT

var _points := PackedVector3Array()
var _camera: Camera3D
## Pipe and wall preview outline, cached per path and parameters.
var _outline: Array = []
var _outline_key := ""
## The press that placed a wall's start point (its release adds no point
## unless it was a drag).
var _wall_start_press := false


func get_tool_name() -> String:
	return "shape"


func cancel() -> void:
	super()
	_points.clear()


func set_shape(value: Shape) -> void:
	cancel()
	shape = value


func cycle_shape() -> void:
	set_shape(((shape + 1) % SHAPE_NAMES.size()) as Shape)


## Option summary for the toolbar, e.g. "16 segments".
func get_option_text() -> String:
	match shape:
		Shape.CYLINDER:
			return TFI18n.t("%d segments") % sides
		Shape.STAIRS:
			return TFI18n.t("Steps: %s") % (TFI18n.t("auto") if steps == 0 else str(steps))
		Shape.PIPE:
			return TFI18n.t("Radius %s m · %d segments · %s") % [format_length(pipe_radius), sides, _bend_text()]
		Shape.WALL:
			return TFI18n.t("Thickness %s m · height %s m") % [format_length(wall_thickness), format_length(wall_height)]
	return ""


func get_hint() -> String:
	var title := TFI18n.t("%s (%s: next shape)") % [TFI18n.t(SHAPE_NAMES[shape]), keys("tool_shape")]
	var options := ""
	match shape:
		Shape.CYLINDER:
			options = TFI18n.t(" · %s/%s: segments") % [keys("shape_more"), keys("shape_less")]
		Shape.STAIRS:
			options = TFI18n.t(" · %s/%s: direction · %s/%s: steps · %s: auto steps") % [
				keys("shape_rotate_ccw"), keys("shape_rotate_cw"), keys("shape_more"), keys("shape_less"), keys("shape_reset")]
	if shape == Shape.WALL:
		options = TFI18n.t(" · %s/%s: height · %s/%s: thickness") % [
			keys("shape_more"), keys("shape_less"), keys("shape_radius_more"), keys("shape_radius_less")]
		if _state == State.IDLE:
			return TFI18n.t("%s · LMB: start point (or drag)%s · Ctrl: lock plane · %s: Select tool") % [title, options, keys("cancel")]
		var invalid := TFI18n.t(" · Run too short for this thickness!") if _wall_invalid() else ""
		return TFI18n.t("%s · LMB/drag: add point · Shift: diagonal · click the first point: close · click the last point / %s: finish · %s: remove last point · %s: cancel%s") % [
			title, keys("shape_confirm"), keys("shape_remove_point"), keys("cancel"), invalid]
	if shape == Shape.PIPE:
		options = TFI18n.t(" · %s/%s: segments · %s/%s: radius · %s/%s: bend segments") % [
			keys("shape_more"), keys("shape_less"), keys("shape_radius_more"), keys("shape_radius_less"), keys("shape_bend_more"), keys("shape_bend_less")]
		if _state == State.IDLE:
			return TFI18n.t("%s · LMB: start point%s · Ctrl: lock plane · %s: Select tool") % [title, options, keys("cancel")]
		var invalid := TFI18n.t(" · Path too short for this radius!") if _pipe_invalid() else ""
		return TFI18n.t("%s · LMB: add point · Shift: vertical · click the last point / %s: finish · %s: remove last point · %s: cancel%s") % [
			title, keys("shape_confirm"), keys("shape_remove_point"), keys("cancel"), invalid]
	match _state:
		State.BASE:
			if shape == Shape.POLYGON:
				var invalid := TFI18n.t(" · Polygon intersects itself!") if _polygon_invalid() else ""
				return TFI18n.t("%s · LMB: add point · click the first point / %s: close · %s: remove last point · %s: cancel%s") % [
					title, keys("shape_confirm"), keys("shape_remove_point"), keys("cancel"), invalid]
			return TFI18n.t("%s · LMB: set base%s · %s: cancel") % [title, options, keys("cancel")]
		State.HEIGHT:
			return TFI18n.t("%s · Mouse: height · LMB: create%s · %s: cancel") % [title, options, keys("cancel")]
	var start := TFI18n.t("LMB: first point") if shape == Shape.POLYGON else TFI18n.t("LMB: start point (or drag)")
	return TFI18n.t("%s · %s%s · Ctrl: lock plane · %s: Select tool") % [title, start, options, keys("cancel")]


func get_cursor_label() -> String:
	if _state == State.IDLE:
		return ""
	if shape == Shape.PIPE or shape == Shape.WALL:
		return "%s m" % format_length(_end.distance_to(_points[_points.size() - 1]))
	var size := _current_box().size
	return "%s × %s × %s m" % [format_length(size.x), format_length(size.y), format_length(size.z)]


func get_info() -> String:
	if _state == State.IDLE:
		return ""
	var dims := get_cursor_label()
	match shape:
		Shape.CYLINDER:
			return TFI18n.t("%d segments · %s") % [sides, dims]
		Shape.POLYGON:
			return TFI18n.t("%d points · %s") % [_points.size(), dims]
		Shape.PIPE:
			return TFI18n.t("%d points · run %s · radius %s m · %s") % [_points.size(), dims, format_length(pipe_radius), _bend_text()]
		Shape.WALL:
			return TFI18n.t("%d points · run %s · thickness %s m · height %s m") % [
				_points.size(), dims, format_length(wall_thickness), format_length(wall_height)]
	var count := _step_count()
	var rise := absf(_height) / float(count)
	var run := _base_box().size[TFSnap.axis_index(_stair_forward())] / float(count)
	return TFI18n.t("%d steps%s · step %s × %s m · %s") % [
		count, " (%s)" % TFI18n.t("auto") if steps == 0 else "", format_length(rise), format_length(run), dims]


func handle_input(camera: Camera3D, event: InputEvent) -> bool:
	_camera = camera
	if event is InputEventKey and event.pressed and _on_key(event):
		return true
	if shape == Shape.PIPE and _state == State.BASE and event is InputEventMouseMotion:
		_end = _pipe_cursor(camera, event.position, event.shift_pressed)
		return false
	if shape == Shape.WALL and _state == State.BASE and event is InputEventMouseMotion:
		_end = _wall_cursor(camera, event.position, event.shift_pressed)
		return false
	return super(camera, event)


func draw_3d(overlay: TFOverlay3D) -> void:
	var color := TFEditorContext.COLOR_PREVIEW
	var faint := Color(color, color.a * 0.4)
	if shape == Shape.PIPE:
		_draw_pipe(overlay, color, faint)
		return
	if shape == Shape.WALL:
		_draw_wall(overlay, color, faint)
		return
	if _state == State.IDLE:
		super(overlay)
		return
	if _state == State.BASE:
		match shape:
			Shape.POLYGON:
				_draw_points(overlay, color, faint)
			Shape.CYLINDER:
				overlay.add_box(_current_box(), faint)
				_draw_loop(overlay, TFShapes.cylinder_polygon(_current_box(), TFSnap.axis_index(_axis), sides), color)
			Shape.STAIRS:
				overlay.add_box(_current_box(), color)
				_draw_arrow(overlay, color)
		return
	var sets := _plane_sets(_current_box())
	if shape == Shape.POLYGON and sets.size() > 1:
		# The parts of a concave polygon show as one shape.
		var face_sets: Array = []
		var transforms: Array = []
		for planes: Array[Plane] in sets:
			var faces: Array[TFFace] = []
			for plane in planes:
				faces.append(TFFace.create(plane))
			face_sets.append(faces)
			transforms.append(Transform3D.IDENTITY)
		for edge: Array in TFCompound.compute(face_sets, transforms)["outline"]:
			overlay.add_line(edge[0], edge[1], color)
	else:
		for planes: Array[Plane] in sets:
			var poly := TFGeometry.planes_to_polyhedron(planes)
			for edge in poly.edges:
				overlay.add_line(poly.vertices[edge.x], poly.vertices[edge.y], color)
	if shape == Shape.STAIRS:
		_draw_arrow(overlay, color)


func _on_key(event: InputEventKey) -> bool:
	match TFShortcuts.find_action("shape", event):
		"shape_confirm":
			if shape == Shape.PIPE and _state == State.BASE and not event.echo:
				_finish_pipe()
				return true
			if shape == Shape.WALL and _state == State.BASE and not event.echo:
				_finish_wall(false)
				return true
			if shape == Shape.POLYGON and _state == State.BASE and not event.echo:
				_finish_base(_camera)
				return true
		"shape_remove_point":
			if shape in [Shape.POLYGON, Shape.PIPE, Shape.WALL] and _state == State.BASE and _points.size() > 1:
				_points.remove_at(_points.size() - 1)
				return true
		"shape_radius_more", "shape_radius_less":
			var more := TFShortcuts.matches("shape_radius_more", event)
			# Half grid steps.
			if shape == Shape.PIPE:
				pipe_radius = _grid_step(pipe_radius, ctx.grid_size() * 0.5, more)
				return true
			if shape == Shape.WALL:
				wall_thickness = _grid_step(wall_thickness, ctx.grid_size() * 0.5, more)
				return true
		"shape_bend_more", "shape_bend_less":
			if shape == Shape.PIPE:
				var delta := 1 if TFShortcuts.matches("shape_bend_more", event) else -1
				bend_segments = clampi(bend_segments + delta, 0, TFShapes.MAX_BEND_SEGMENTS)
				return true
		"shape_more":
			return _change_count(1)
		"shape_less":
			return _change_count(-1)
		"shape_rotate_ccw":
			if shape == Shape.STAIRS and not event.echo:
				stair_turns = (stair_turns + 1) % 4
				return true
		"shape_rotate_cw":
			if shape == Shape.STAIRS and not event.echo:
				stair_turns = (stair_turns + 3) % 4
				return true
		"shape_reset":
			if shape != Shape.POLYGON and not event.echo:
				sides = TFShapes.DEFAULT_SIDES
				steps = 0
				stair_turns = 0
				pipe_radius = TFShapes.DEFAULT_PIPE_RADIUS
				bend_radius = pipe_radius * TFShapes.DEFAULT_BEND_FACTOR
				bend_segments = TFShapes.DEFAULT_BEND_SEGMENTS
				wall_thickness = TFShapes.DEFAULT_WALL_THICKNESS
				wall_height = TFShapes.DEFAULT_WALL_HEIGHT
				return true
	return false


## value one step larger or smaller; below one step it doubles or halves.
func _grid_step(value: float, step: float, more: bool) -> float:
	if more:
		return value + (step if value >= step else value)
	return value - step if value > step + TFConst.EPSILON else maxf(value * 0.5, TFShapeParams.MIN_SIZE)


func _change_count(delta: int) -> bool:
	match shape:
		Shape.CYLINDER, Shape.PIPE:
			sides = clampi(sides + delta, TFShapes.MIN_SIDES, TFShapes.MAX_SIDES)
			return true
		Shape.STAIRS:
			# The first change starts from the automatic count.
			steps = clampi(_step_count() + delta, 1, TFShapes.MAX_STEPS)
			return true
		Shape.WALL:
			wall_height = _grid_step(wall_height, ctx.grid_size(), delta > 0)
			return true
	return false


func _on_press(camera: Camera3D, event: InputEventMouseButton) -> void:
	if shape == Shape.PIPE:
		_on_pipe_press(camera, event)
		return
	if shape == Shape.WALL:
		_on_wall_press(camera, event)
		return
	if shape != Shape.POLYGON or _state == State.HEIGHT:
		super(camera, event)
		return
	if _state == State.IDLE:
		super(camera, event)
		if _state == State.BASE:
			_points = PackedVector3Array([_start])
		return
	# Clicking the first point again closes the polygon.
	if _points.size() >= 3 and _end.is_equal_approx(_points[0]):
		_finish_base(camera)
	elif TFHull.find_point(_points, _end) == -1:
		_points.append(_end)


func _on_release(camera: Camera3D, event: InputEventMouseButton) -> void:
	if shape == Shape.PIPE:
		# Dragging from the start point places the second one on release.
		if _state == State.BASE and _pressed and _points.size() == 1 and event.position.distance_to(_press_pos) > DRAG_THRESHOLD:
			_add_pipe_point()
		_pressed = false
		return
	if shape == Shape.WALL:
		_on_wall_release(event)
		return
	if shape != Shape.POLYGON:
		super(camera, event)
		return
	# Dragging from the first point places the second one on release.
	if _state == State.BASE and _pressed and event.position.distance_to(_press_pos) > DRAG_THRESHOLD and TFHull.find_point(_points, _end) == -1:
		_points.append(_end)
	_pressed = false


func _finish_base(camera: Camera3D) -> void:
	if shape == Shape.POLYGON:
		if _points.size() < 3:
			return
		if TFShapes.simple_polygon(_points, _axis).size() < 3:
			toast(TFI18n.t("Polygon: the edges intersect (or it has no area)."), EditorToaster.SEVERITY_WARNING)
			return
		# Height is picked along the axis through the last point.
		_end = _points[_points.size() - 1]
	super(camera)


func _current_box() -> AABB:
	if shape != Shape.POLYGON:
		return super()
	var box := _base_box()
	if _state == State.HEIGHT:
		box = box.merge(AABB(box.position + _axis * _height, box.size))
	return box


## The drawn base (flat along the axis).
func _base_box() -> AABB:
	var box := AABB(_start, Vector3.ZERO).expand(_end)
	if shape == Shape.POLYGON:
		for p in _points:
			box = box.expand(p)
	return box


func _create(box: AABB) -> void:
	var sets := _plane_sets(box)
	_points.clear()
	if ctx.map == null:
		return
	var parent := ctx.parent_for_new()
	var to_local := parent.global_transform.affine_inverse()
	var brushes: Array[TFBrush] = []
	for planes: Array[Plane] in sets:
		var local: Array[Plane] = []
		for plane in planes:
			local.append(to_local * plane)
		var brush := TFShapes.create_brush(local, ctx.current_material)
		if brush != null:
			brushes.append(brush)
	if brushes.is_empty():
		return
	var action := TFI18n.action("Create %s") % TFI18n.t(SHAPE_NAMES[shape])
	if shape == Shape.CYLINDER:
		brushes[0].set_meta(TFConst.META_SHAPE, TFShapeParams.cylinder_meta(TFSnap.axis_index(to_local.basis * _axis), sides))
	if brushes.size() == 1:
		TFUndo.add_brush(ctx.undo_redo(), action, parent, brushes[0], ctx.scene_root())
		ctx.select_brushes(brushes)
		return
	# Several brushes form a group, selected and moved as a whole: the parts
	# of a concave polygon a compound (unless created inside one), the steps
	# a stairs group.
	var group := Node3D.new()
	group.name = STAIRS_GROUP_NAME
	if shape == Shape.STAIRS:
		var up := _axis * (1.0 if _height >= 0.0 else -1.0)
		group.set_meta(TFConst.META_SHAPE, TFShapeParams.stairs_meta(to_local.basis * up, to_local.basis * _stair_forward(), brushes.size()))
	if shape == Shape.POLYGON:
		if TFGroups.compound_of(parent) != null:
			TFUndo.add_brushes(ctx.undo_redo(), action, _filled(parent, brushes.size()), brushes, ctx.scene_root())
			ctx.select_brushes(brushes)
			return
		group = TFGroups.new_compound()
	for brush in brushes:
		group.add_child(brush, true)
	TFUndo.add_brushes(ctx.undo_redo(), action, [parent], [group], ctx.scene_root())
	ctx.select_nodes([group])


## Plane sets (world space) of the brushes the shape creates in the box.
func _plane_sets(box: AABB) -> Array:
	var sets: Array = []
	match shape:
		Shape.CYLINDER:
			sets.append(TFShapes.cylinder_planes(box, TFSnap.axis_index(_axis), sides))
		Shape.POLYGON:
			sets.append_array(TFShapes.polygon_prisms(_points, _axis, _height))
		Shape.STAIRS:
			var up := _axis * (1.0 if _height >= 0.0 else -1.0)
			for step in TFShapes.stair_boxes(box, up, _stair_forward(), _step_count()):
				sets.append(TFShapes.box_planes(step))
	return sets.filter(func(planes: Array[Plane]) -> bool: return not planes.is_empty())


func _step_count() -> int:
	if steps > 0:
		return steps
	return TFShapes.auto_step_count(_height, ctx.grid_size())


## Direction the stairs climb towards (signed unit axis across the build axis).
func _stair_forward() -> Vector3:
	var base := _base_box()
	var i := TFSnap.axis_index(_axis)
	var u := (i + 1) % 3
	var v := (i + 2) % 3
	var f := u if base.size[u] >= base.size[v] else v
	var forward := Vector3.ZERO
	forward[f] = 1.0 if _end[f] >= _start[f] else -1.0
	var turned := forward.rotated(_axis, float(stair_turns) * PI * 0.5)
	return TFSnap.dominant_axis(turned)


func _draw_arrow(overlay: TFOverlay3D, color: Color) -> void:
	var base := _base_box()
	var forward := _stair_forward()
	var length := base.size[TFSnap.axis_index(forward)]
	if length < TFConst.EPSILON:
		return
	var center := base.get_center()
	var tail := center - forward * length * 0.4
	var head := center + forward * length * 0.4
	var side := _axis.cross(forward) * length * 0.1
	overlay.add_line(tail, head, color)
	overlay.add_line(head, head - forward * length * 0.1 + side, color)
	overlay.add_line(head, head - forward * length * 0.1 - side, color)


## The polygon in click order up to the cursor; red while it intersects
## itself.
func _draw_points(overlay: TFOverlay3D, color: Color, faint: Color) -> void:
	if _polygon_invalid():
		color = TFEditorContext.COLOR_INVALID
		faint = Color(color, color.a * 0.4)
	for k in _points.size():
		overlay.add_point(_points[k], color)
		if k > 0:
			overlay.add_line(_points[k - 1], _points[k], color)
	overlay.add_line(_points[_points.size() - 1], _end, color)
	if _points.size() >= 2:
		overlay.add_line(_end, _points[0], faint)


## True if the polygon so far (with the cursor as next point) intersects
## itself.
func _polygon_invalid() -> bool:
	var points := _points.duplicate()
	if TFHull.find_point(points, _end) == -1:
		points.append(_end)
	if points.size() < 3:
		return false
	return TFShapes.simple_polygon(points, _axis).is_empty() and TFShapes.convex_polygon(points, _axis).size() >= 3


func _filled(value: Variant, count: int) -> Array:
	var result: Array = []
	result.resize(count)
	result.fill(value)
	return result


func _draw_loop(overlay: TFOverlay3D, polygon: PackedVector3Array, color: Color) -> void:
	for k in polygon.size():
		overlay.add_line(polygon[k], polygon[(k + 1) % polygon.size()], color)


# --- pipe -------------------------------------------------------------------

func _on_pipe_press(camera: Camera3D, event: InputEventMouseButton) -> void:
	if _state == State.IDLE:
		var hit := ctx.picker.pick(ctx, camera, event.position, is_ctrl(event))
		if hit.is_empty():
			return
		# The center line lies one radius above the surface.
		_axis = hit["normal"]
		_start = hit["point"] + _axis * pipe_radius
		_end = _start
		_points = PackedVector3Array([_start])
		_state = State.BASE
		_pressed = true
		_press_pos = event.position
		return
	_end = _pipe_cursor(camera, event.position, event.shift_pressed)
	# Clicking the last point again finishes the pipe.
	if _end.distance_to(_points[_points.size() - 1]) < TFConst.EPSILON:
		_finish_pipe()
	else:
		_add_pipe_point()


func _add_pipe_point() -> void:
	var points := _points.duplicate()
	points.append(_end)
	if TFShapes.pipe_path(points).is_empty():
		return
	_points = points


func _finish_pipe() -> void:
	if _points.size() < 2:
		return
	if _pipe_sets(_points).is_empty():
		toast(TFI18n.t("Pipe: a run is too short for the radius."), EditorToaster.SEVERITY_WARNING)
		return
	_state = State.IDLE
	_create_pipe()


## Next path point under the mouse: on the drawing plane through the last
## point (perpendicular to the start surface's normal), moved onto the axis
## of the longer offset; with Shift along the normal instead.
func _pipe_cursor(camera: Camera3D, screen_pos: Vector2, vertical: bool) -> Vector3:
	var last := _points[_points.size() - 1]
	var grid := ctx.grid_size()
	if vertical:
		return last + _axis * TFPointPicker.pick_along_axis(camera, screen_pos, last, _axis, grid)
	var point: Variant = ctx.picker.pick_on_plane(ctx, camera, screen_pos, Plane(_axis, last))
	if point == null:
		return _end
	var offset: Vector3 = point - last
	var direction := TFSnap.dominant_axis(offset)
	return last + direction * TFSnap.snap_value(offset.dot(direction), grid)


## The path so far with the cursor as next point (if it adds a run).
func _pipe_preview_points() -> PackedVector3Array:
	var points := _points.duplicate()
	if _end.distance_to(points[points.size() - 1]) >= TFConst.EPSILON:
		points.append(_end)
	return points


func _pipe_sets(points: PackedVector3Array) -> Array:
	return TFShapes.pipe_sets(points, pipe_radius, sides, bend_radius, bend_segments)


## True if the path with the cursor cannot carry the pipe (runs too short).
func _pipe_invalid() -> bool:
	var points := _pipe_preview_points()
	return points.size() >= 2 and _pipe_sets(points).is_empty()


func _bend_text() -> String:
	if bend_segments == 0:
		return TFI18n.t("mitred")
	return TFI18n.t("bend %s m × %d") % [format_length(bend_radius), bend_segments]


func _create_pipe() -> void:
	var path := TFShapes.pipe_path(_points)
	_points.clear()
	if ctx.map == null or path.is_empty():
		return
	var parent := ctx.parent_for_new()
	var to_local := parent.global_transform.affine_inverse()
	var local := PackedVector3Array()
	for p in path:
		local.append(to_local * p)
	_create_path_compound(parent, local, PIPE_GROUP_NAME, _pipe_sets,
		func(points: PackedVector3Array) -> Dictionary: return TFShapeParams.pipe_meta(points, pipe_radius, sides, bend_radius, bend_segments))


func _create_path_compound(parent: Node3D, local: PackedVector3Array, group_name: String, sets_for: Callable, meta_for: Callable) -> void:
	var action := TFI18n.action("Create %s") % TFI18n.t(SHAPE_NAMES[shape])
	ctx.create_shape_compound(parent, local, group_name, sets_for, meta_for, action)


## Path, cursor and the outline of the pipe so far (red if it does not fit).
func _draw_pipe(overlay: TFOverlay3D, color: Color, faint: Color) -> void:
	if _state == State.IDLE:
		if not _cursor.is_empty():
			overlay.add_cross(_cursor["point"] + _cursor["normal"] * pipe_radius, ctx.grid_size() * 0.5, TFEditorContext.COLOR_CURSOR)
		return
	var points := _pipe_preview_points()
	var sets := _pipe_sets(points) if points.size() >= 2 else []
	if points.size() >= 2 and sets.is_empty():
		color = TFEditorContext.COLOR_INVALID
		faint = Color(color, color.a * 0.4)
	for k in points.size():
		overlay.add_point(points[k], color)
		if k > 0:
			overlay.add_line(points[k - 1], points[k], faint)
	for edge: Array in _pipe_outline_for(points, sets):
		overlay.add_line(edge[0], edge[1], color)


func _pipe_outline_for(points: PackedVector3Array, sets: Array) -> Array:
	return _outline_for("%s|%s|%d|%s|%d" % [points, pipe_radius, sides, bend_radius, bend_segments], sets)


## Compound outline of the pipe or wall pieces; recomputed only when key
## (path and parameters) changes.
func _outline_for(key: String, sets: Array) -> Array:
	if key != _outline_key:
		_outline_key = key
		var face_sets: Array = []
		var transforms: Array = []
		for planes: Array[Plane] in sets:
			var faces: Array[TFFace] = []
			for plane in planes:
				faces.append(TFFace.create(plane))
			face_sets.append(faces)
			transforms.append(Transform3D.IDENTITY)
		_outline = TFCompound.compute(face_sets, transforms)["outline"] if not sets.is_empty() else []
	return _outline


# --- wall -------------------------------------------------------------------

func _on_wall_press(camera: Camera3D, event: InputEventMouseButton) -> void:
	_pressed = true
	_press_pos = event.position
	if _state != State.IDLE:
		_end = _wall_cursor(camera, event.position, event.shift_pressed)
		_wall_start_press = false
		return
	var hit := ctx.picker.pick(ctx, camera, event.position, is_ctrl(event))
	if hit.is_empty():
		_pressed = false
		return
	# The wall stands on the clicked surface; the path stays on its plane.
	_axis = TFSnap.dominant_axis(hit["normal"])
	_start = hit["point"]
	_end = _start
	_points = PackedVector3Array([_start])
	ctx.picker.adopt_plane(Plane(_axis, _start))
	_state = State.BASE
	_wall_start_press = true


## Every release adds the cursor point, so clicking and dragging run by run
## work alike; the release of the start click only if it was a drag. Clicking
## the first point closes the wall, clicking the last one finishes it.
func _on_wall_release(event: InputEventMouseButton) -> void:
	var was_pressed := _pressed
	_pressed = false
	if _state != State.BASE or not was_pressed:
		return
	if _wall_start_press:
		_wall_start_press = false
		if event.position.distance_to(_press_pos) <= DRAG_THRESHOLD:
			return
	if _points.size() >= 3 and _end.distance_to(_points[0]) < TFConst.EPSILON:
		_finish_wall(true)
	elif _end.distance_to(_points[_points.size() - 1]) < TFConst.EPSILON:
		_finish_wall(false)
	else:
		var points := _points.duplicate()
		points.append(_end)
		if not TFShapes.wall_path(points, _axis, false).is_empty():
			_points = points


func _finish_wall(closed: bool) -> void:
	if _points.size() < (3 if closed else 2):
		return
	if _wall_sets(_points, closed).is_empty():
		toast(TFI18n.t("Wall: a run is too short for the thickness."), EditorToaster.SEVERITY_WARNING)
		return
	_state = State.IDLE
	_create_wall(closed)


## Next path point under the mouse on the floor plane through the last point:
## along the axis of the longer offset, with Shift anywhere on the grid.
func _wall_cursor(camera: Camera3D, screen_pos: Vector2, diagonal: bool) -> Vector3:
	var last := _points[_points.size() - 1]
	var point: Variant = ctx.picker.pick_on_plane(ctx, camera, screen_pos, Plane(_axis, last))
	if point == null:
		return _end
	if diagonal:
		return point
	var offset: Vector3 = point - last
	var direction := TFSnap.dominant_axis(offset)
	return last + direction * TFSnap.snap_value(offset.dot(direction), ctx.grid_size())


## The path so far with the cursor as next point, and whether the cursor on
## the first point closes it: [points, closed].
func _wall_preview() -> Array:
	var points := _points.duplicate()
	if points.size() >= 3 and _end.distance_to(points[0]) < TFConst.EPSILON:
		return [points, true]
	if _end.distance_to(points[points.size() - 1]) >= TFConst.EPSILON:
		points.append(_end)
	return [points, false]


func _wall_sets(points: PackedVector3Array, closed: bool) -> Array:
	return TFShapes.wall_sets(points, _axis, closed, wall_thickness, wall_height)


## True if the path with the cursor cannot carry the wall (runs too short,
## corners too sharp).
func _wall_invalid() -> bool:
	var preview := _wall_preview()
	var points: PackedVector3Array = preview[0]
	return points.size() >= 2 and _wall_sets(points, preview[1]).is_empty()


func _create_wall(closed: bool) -> void:
	var path := TFShapes.wall_path(_points, _axis, closed)
	_points.clear()
	if ctx.map == null or path.is_empty():
		return
	var parent := ctx.parent_for_new()
	var to_local := parent.global_transform.affine_inverse()
	var local := PackedVector3Array()
	for p in path:
		local.append(to_local * p)
	var up := (to_local.basis * _axis).normalized()
	_create_path_compound(parent, local, WALL_GROUP_NAME,
		func(points: PackedVector3Array) -> Array: return TFShapes.wall_sets(points, up, closed, wall_thickness, wall_height),
		func(points: PackedVector3Array) -> Dictionary: return TFShapeParams.wall_meta(points, up, wall_thickness, wall_height, closed))


## Path, cursor and the outline of the wall so far (red if it does not fit).
func _draw_wall(overlay: TFOverlay3D, color: Color, faint: Color) -> void:
	if _state == State.IDLE:
		if not _cursor.is_empty():
			overlay.add_cross(_cursor["point"], ctx.grid_size() * 0.5, TFEditorContext.COLOR_CURSOR)
		return
	var preview := _wall_preview()
	var points: PackedVector3Array = preview[0]
	var closed: bool = preview[1]
	var sets := _wall_sets(points, closed) if points.size() >= 2 else []
	if points.size() >= 2 and sets.is_empty():
		color = TFEditorContext.COLOR_INVALID
		faint = Color(color, color.a * 0.4)
	for k in points.size():
		overlay.add_point(points[k], color)
		if k > 0:
			overlay.add_line(points[k - 1], points[k], faint)
	if closed:
		overlay.add_line(points[points.size() - 1], points[0], faint)
	var key := "%s|%s|%s|%s|%s|%s" % [points, closed, _axis, wall_thickness, wall_height, sets.is_empty()]
	for edge: Array in _outline_for(key, sets):
		overlay.add_line(edge[0], edge[1], color)
