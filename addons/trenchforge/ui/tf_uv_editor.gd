@tool
class_name TFUVEditor
extends VBoxContainer
## Bottom-panel tab "TF UV": graphical editor for offset, scale, rotation
## and shear of exactly one (logical) face, like TrenchBroom's UV editor.
##
## The view shows texture pixels (TFUV.pixel_coord()) through a pan/zoom
## transform. The face stays put on screen and the texture moves under it:
## after every change the view is compensated by the change of the face's
## plane-to-pixel transform. Origin, zoom and grid subdivision are editor
## state. Drags preview directly on the faces and are committed as one undo
## action; all UV math lives in TFUV.

enum Drag { NONE, PAN, TRANSLATE, ORIGIN, ORIGIN_X, ORIGIN_Y, ROTATE, SCALE_X, SCALE_Y, SHEAR_X, SHEAR_Y }

## Screen sizes (pixels) of handles and hit tests.
const ORIGIN_RADIUS := 5.0
const ROTATE_RADIUS := 56.0
const HIT_DISTANCE := 5.0
const AXIS_LENGTH := 40.0
## Margin around the face when fitting the view (fraction of its size).
const FIT_MARGIN := 0.2
## Fallback size while the tab has not been laid out yet.
const FALLBACK_SIZE := Vector2(512, 320)
## Grid lines drawn per direction at most; more are thinned.
const MAX_GRID_LINES := 96
## Subdivision lines closer than this on screen are hidden (and not grabbed).
const MIN_LINE_SPACING := 6.0
const ZOOM_STEP := 1.15
const MIN_ZOOM := 0.005
const MAX_ZOOM := 64.0
const COLOR_BACKGROUND := Color(0.11, 0.11, 0.12)
const COLOR_ORIGIN := Color(1.0, 0.85, 0.2)
const COLOR_ORIGIN_AXES := Color(1.0, 0.3, 0.25, 0.85)
const COLOR_U := Color(1.0, 0.3, 0.25)
const COLOR_V := Color(0.35, 0.9, 0.35)
const COLOR_HIGHLIGHT := Color(0.35, 0.8, 1.0)
const CURSORS := {
	Drag.PAN: Control.CURSOR_DRAG,
	Drag.TRANSLATE: Control.CURSOR_MOVE,
	Drag.ORIGIN: Control.CURSOR_CROSS,
	Drag.ORIGIN_X: Control.CURSOR_HSIZE,
	Drag.ORIGIN_Y: Control.CURSOR_VSIZE,
	Drag.ROTATE: Control.CURSOR_POINTING_HAND,
	Drag.SCALE_X: Control.CURSOR_HSIZE,
	Drag.SCALE_Y: Control.CURSOR_VSIZE,
	Drag.SHEAR_X: Control.CURSOR_BDIAGSIZE,
	Drag.SHEAR_Y: Control.CURSOR_FDIAGSIZE,
}

static var _checker: Texture2D

var ctx: TFEditorContext
## Subdivision of a tile by the grid (Grid X/Y spin boxes).
var grid_divisions := Vector2i.ONE

var _canvas: Canvas
var _hint: Label
var _info: Label
var _grid_x: SpinBox
var _grid_y: SpinBox
var _buttons: Array[Button] = []

# The edited logical face.
var _group: Array = []  # [TFBrush, face_index] entries
var _key := ""
var _polygon := PackedVector3Array()  # map-space outline
var _normal := Vector3.ZERO
var _plane_point := Vector3.ZERO
var _basis: Array[Vector3] = []
var _face_xf := Transform2D()  # plane coordinates -> pixels (lead face)
var _view := Transform2D()  # pixels -> screen
var _origin := Vector2.ZERO  # pixels
var _fit_pending := false
## The view follows canvas resizes until the user zooms or pans.
var _auto_fit := false
var _watched: Array[TFFace] = []
var _refresh_queued := false

# Drag state; drags are computed from the state at their start.
var _drag := Drag.NONE
var _drag_start := Vector2.ZERO  # screen
var _drag_view := Transform2D()
var _drag_xf := Transform2D()
var _drag_origin := Vector2.ZERO
var _drag_faces: Array[TFFace] = []  # copies, parallel to _group
var _drag_line := 0.0  # grabbed grid line (pixels)
var _hover := Drag.NONE
var _hover_line := 0.0


## The drawing area; forwards drawing and input to the editor.
class Canvas:
	extends Control

	var editor: TFUVEditor
	## Duration of the last _draw() in microseconds (performance checks).
	var last_draw_usec := 0

	func _draw() -> void:
		var start := Time.get_ticks_usec()
		editor._draw_canvas(self)
		last_draw_usec = Time.get_ticks_usec() - start

	func _gui_input(event: InputEvent) -> void:
		if editor._canvas_input(event):
			accept_event()


func _init() -> void:
	name = "TFUVEditor"
	# TFI18n translates the texts; keep the editor from translating them again.
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	custom_minimum_size = Vector2(240, 180)

	_canvas = Canvas.new()
	_canvas.editor = self
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.clip_contents = true
	_canvas.focus_mode = Control.FOCUS_ALL
	_canvas.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	_canvas.tooltip_text = TFI18n.t("Drag: move texture · grid line: scale · Alt+grid line: shear · circle or Ctrl: rotate · yellow point / red lines: origin · Shift: no snapping · Esc / RMB: cancel · wheel: zoom · MMB: pan")
	_canvas.resized.connect(func() -> void:
		if _auto_fit:
			fit_view()
		_canvas.queue_redraw())
	add_child(_canvas)
	_hint = Label.new()
	_hint.text = TFI18n.t("Select exactly one face")
	_hint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_hint)

	var bar := HFlowContainer.new()
	add_child(bar)
	_button(bar, TFI18n.t("Reset (plane)"), TFI18n.t("Axes in the face plane, no offset/scale/rotation (removes shear)"), _reset_to_plane)
	_button(bar, TFI18n.t("Reset (world)"), TFI18n.t("Box projection defaults (removes shear)"), _reset_world)
	_button(bar, "Flip H", TFI18n.t("Flip horizontally"), _flip.bind(0))
	_button(bar, "Flip V", TFI18n.t("Flip vertically"), _flip.bind(1))
	_button(bar, "↺ 90°", TFI18n.t("Rotate texture 90° counterclockwise around the origin"), _rotate.bind(90.0))
	_button(bar, "↻ 90°", TFI18n.t("Rotate texture 90° clockwise around the origin"), _rotate.bind(-90.0))
	_button(bar, TFI18n.t("Fit view"), TFI18n.t("Show the whole face"), fit_view)
	var grid_label := Label.new()
	grid_label.text = TFI18n.t("Grid")
	bar.add_child(grid_label)
	_grid_x = _grid_spin(bar, TFI18n.t("Grid X: lines per tile horizontally (trim sheets)"), 0)
	_grid_y = _grid_spin(bar, TFI18n.t("Grid Y: lines per tile vertically (trim sheets)"), 1)
	_info = Label.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_info.add_theme_color_override(&"font_color", Color(0.7, 0.7, 0.7))
	bar.add_child(_info)


func setup(p_ctx: TFEditorContext) -> void:
	ctx = p_ctx
	refresh()


func _exit_tree() -> void:
	cancel_drag()
	_watch([])


func focus_canvas() -> void:
	_canvas.grab_focus()


func set_grid_divisions(value: Vector2i) -> void:
	grid_divisions = value
	_grid_x.set_value_no_signal(value.x)
	_grid_y.set_value_no_signal(value.y)
	_canvas.queue_redraw()


## Refreshes once at the end of the frame (selection, undo, face changes).
func queue_refresh() -> void:
	if not _refresh_queued:
		_refresh_queued = true
		refresh.call_deferred()


func refresh() -> void:
	_refresh_queued = false
	var group := _current_group()
	if group.is_empty():
		if _drag != Drag.NONE:
			_drag = Drag.NONE
			_set_build_suspended(false)
		_group = []
		_key = ""
		_watch([])
		_update_ui()
		return
	var brush: TFBrush = group[0][0]
	var index: int = group[0][1]
	var plane := brush.get_face_map_plane(index)
	var key := _group_key(group)
	var is_new := key != _key or not plane.normal.is_equal_approx(_normal)
	if is_new and _drag != Drag.NONE:
		cancel_drag()
	_group = group
	_key = key
	_normal = plane.normal
	_plane_point = plane.normal * plane.d
	_basis = TFUV.plane_axes(_normal)
	_polygon = ctx.logical_polygon(group)
	var xf := TFUV.face_transform(_lead(), _plane_point, _basis, _ppm())
	if is_new or absf(xf.determinant()) < TFConst.EPSILON or absf(_face_xf.determinant()) < TFConst.EPSILON:
		_face_xf = xf
		_origin = _initial_origin()
		_view = Transform2D()
		fit_view()
		_auto_fit = true
	else:
		# Keep the face where it is on screen; the texture moves instead.
		_view = _view * _face_xf * xf.affine_inverse()
		_face_xf = xf
	var faces: Array[TFFace] = []
	for entry in _group:
		faces.append((entry[0] as TFBrush).faces[entry[1]])
	_watch(faces)
	_update_ui()


## Scales and moves the view so the face fills the canvas (keeps the
## texture orientation on screen).
func fit_view() -> void:
	if _group.is_empty():
		return
	var size := _canvas.size
	_fit_pending = size.x < 1.0 or size.y < 1.0
	if _fit_pending:
		size = FALLBACK_SIZE
	var bounds := _screen_bounds(_view * _face_xf, _plane_polygon())
	if bounds.size.x < TFConst.EPSILON and bounds.size.y < TFConst.EPSILON:
		return
	var zoom := minf(size.x / maxf(bounds.size.x * (1.0 + FIT_MARGIN * 2.0), TFConst.EPSILON), size.y / maxf(bounds.size.y * (1.0 + FIT_MARGIN * 2.0), TFConst.EPSILON))
	var fit := Transform2D(Vector2(zoom, 0), Vector2(0, zoom), size * 0.5 - bounds.get_center() * zoom)
	_view = fit * _view
	_canvas.queue_redraw()


func is_dragging() -> bool:
	return _drag != Drag.NONE and _drag != Drag.PAN


## Restores the state before the drag (Esc, RMB); no undo entry.
func cancel_drag() -> void:
	if _drag == Drag.NONE:
		return
	var mode := _drag
	_drag = Drag.NONE
	if mode == Drag.PAN:
		return
	_origin = _drag_origin
	_restore_drag_faces()
	_set_build_suspended(false)
	refresh()


# --- input -------------------------------------------------------------------

func _canvas_input(event: InputEvent) -> bool:
	if _group.is_empty() or not _group_valid():
		return false
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		match button.button_index:
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed:
					_zoom(button.position, ZOOM_STEP if button.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / ZOOM_STEP)
				return true
			MOUSE_BUTTON_MIDDLE:
				if button.pressed and _drag == Drag.NONE:
					_drag = Drag.PAN
				elif not button.pressed and _drag == Drag.PAN:
					_drag = Drag.NONE
				_update_cursor()
				return true
			MOUSE_BUTTON_RIGHT:
				if button.pressed and is_dragging():
					cancel_drag()
					return true
			MOUSE_BUTTON_LEFT:
				if button.pressed:
					_canvas.grab_focus()
					if _drag == Drag.NONE:
						_begin_drag(_hit(button.position, button.ctrl_pressed or button.meta_pressed, button.alt_pressed), button.position)
				elif is_dragging():
					_end_drag()
				return true
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _drag == Drag.PAN:
			_view = Transform2D(_view.x, _view.y, _view.origin + motion.relative)
			_fit_pending = false
			_auto_fit = false
			_canvas.queue_redraw()
		elif _drag != Drag.NONE:
			_update_drag(motion.position, not motion.shift_pressed)
		else:
			var hover := _hit(motion.position, motion.ctrl_pressed or motion.meta_pressed, motion.alt_pressed)
			if hover != _hover:
				_hover = hover
				_update_cursor()
				_canvas.queue_redraw()
			elif hover in [Drag.SCALE_X, Drag.SCALE_Y, Drag.SHEAR_X, Drag.SHEAR_Y]:
				_canvas.queue_redraw()
		return true
	elif event is InputEventKey and event.pressed:
		if is_dragging() and TFShortcuts.matches("cancel", event):
			cancel_drag()
			return true
		if event.echo or _drag != Drag.NONE:
			return false
		match TFShortcuts.find_action("uv_editor", event):
			"uv_flip_h":
				_flip(0)
			"uv_flip_v":
				_flip(1)
			"uv_rotate_ccw":
				_rotate(90.0)
			"uv_rotate_cw":
				_rotate(-90.0)
			"uv_reset":
				_reset_to_plane()
			"uv_fit_view":
				fit_view()
			_:
				return false
		return true
	return false


## What a press at the screen position would drag (order of the spec).
func _hit(screen: Vector2, ctrl: bool, alt: bool) -> Drag:
	var origin := _view * _origin
	if screen.distance_to(origin) <= ORIGIN_RADIUS + 2.0:
		return Drag.ORIGIN
	if _line_distance(screen, origin, _view.y) <= HIT_DISTANCE:
		return Drag.ORIGIN_X
	if _line_distance(screen, origin, _view.x) <= HIT_DISTANCE:
		return Drag.ORIGIN_Y
	if ctrl or absf(screen.distance_to(origin) - ROTATE_RADIUS) <= HIT_DISTANCE:
		return Drag.ROTATE
	var pixel := _view.affine_inverse() * screen
	var cell := _cell()
	var line_x := roundf(pixel.x / cell.x) * cell.x
	var line_y := roundf(pixel.y / cell.y) * cell.y
	var distance_x := _line_distance(screen, _view * Vector2(line_x, pixel.y), _view.y)
	var distance_y := _line_distance(screen, _view * Vector2(pixel.x, line_y), _view.x)
	if minf(distance_x, distance_y) <= HIT_DISTANCE:
		if distance_x <= distance_y:
			_hover_line = line_x
			return Drag.SHEAR_X if alt else Drag.SCALE_X
		_hover_line = line_y
		return Drag.SHEAR_Y if alt else Drag.SCALE_Y
	return Drag.TRANSLATE


func _begin_drag(mode: Drag, screen: Vector2) -> void:
	if mode == Drag.NONE:
		return
	_drag = mode
	_drag_start = screen
	_drag_view = _view
	_drag_xf = _face_xf
	_drag_origin = _origin
	_drag_line = _hover_line
	_drag_faces.clear()
	for entry in _group:
		_drag_faces.append((entry[0] as TFBrush).faces[entry[1]].copy())
	if mode in [Drag.SCALE_X, Drag.SCALE_Y, Drag.SHEAR_X, Drag.SHEAR_Y]:
		_hit(screen, false, mode in [Drag.SHEAR_X, Drag.SHEAR_Y])
		_drag_line = _hover_line
	_set_build_suspended(true)
	_update_cursor()


## Applies the drag from its start state to the mouse position.
func _update_drag(screen: Vector2, snap: bool) -> void:
	var to_pixel := _drag_view.affine_inverse()
	# The face does not move on screen: these are its start pixels.
	var start := to_pixel * _drag_start
	var current := to_pixel * screen
	var radius := (float(TFEditorSettings.uv_snap_radius) / _zoom_of(_drag_view)) if snap else -1.0
	var lead: TFFace = _drag_faces[0]
	var ppm := _ppm()
	var polygon := TFUV.to_uv_space(lead, _polygon, ppm)
	match _drag:
		Drag.ORIGIN, Drag.ORIGIN_X, Drag.ORIGIN_Y:
			var target := _drag_origin + current - start
			var candidates := polygon.duplicate()
			candidates.append(_average(polygon))
			if _drag == Drag.ORIGIN:
				var snapped: Variant = TFUV.snap_point(target, candidates, radius)
				_origin = snapped if snapped != null else target
			else:
				var axis := 0 if _drag == Drag.ORIGIN_X else 1
				var values := PackedFloat32Array()
				for p in candidates:
					values.append(p[axis])
				var snapped_value: Variant = TFUV.snap_line(target[axis], values, radius)
				_origin = _drag_origin
				_origin[axis] = snapped_value if snapped_value != null else target[axis]
			_canvas.queue_redraw()
			return
		Drag.TRANSLATE:
			var delta := start - current
			var moved := PackedVector2Array()
			for p in polygon:
				moved.append(p + delta)
			delta += TFUV.snap_offset(moved, _cell(), radius)
			_apply_drag(func(face: TFFace) -> void: TFUV.translate_uv(face, delta))
		Drag.ROTATE:
			var center := _drag_view * _drag_origin
			var turned := angle_difference((_drag_start - center).angle(), (screen - center).angle())
			# Screen and pixel space may be mirrored against each other.
			var orientation := signf((_drag_view * _drag_xf).determinant())
			var degrees := -rad_to_deg(turned) * orientation
			if snap:
				degrees = _snap_rotation(lead, degrees, ppm)
			_apply_drag(func(face: TFFace) -> void: TFUV.rotate_about(face, _drag_origin, degrees, _polygon, ppm))
		Drag.SCALE_X, Drag.SCALE_Y:
			var axis := 0 if _drag == Drag.SCALE_X else 1
			var value := current[axis]
			if snap:
				var values := PackedFloat32Array()
				for p in polygon:
					values.append(p[axis])
				var snapped: Variant = TFUV.snap_line(value, values, radius)
				if snapped != null:
					value = snapped
			var from_origin := value - _drag_origin[axis]
			var line_from_origin := _drag_line - _drag_origin[axis]
			if absf(from_origin) < TFConst.EPSILON or absf(line_from_origin) < TFConst.EPSILON:
				return
			var factor := Vector2.ONE
			factor[axis] = line_from_origin / from_origin
			_apply_drag(func(face: TFFace) -> void: TFUV.scale_about(face, _drag_origin, factor))
		Drag.SHEAR_X, Drag.SHEAR_Y:
			var axis := 0 if _drag == Drag.SHEAR_X else 1
			var point := current
			if snap:
				var snapped: Variant = TFUV.snap_point(current, polygon, radius)
				if snapped != null:
					point = snapped
			var lever := point[1 - axis] - _drag_origin[1 - axis]
			if absf(lever) < TFConst.EPSILON:
				return
			var amount := clampf((_drag_line - point[axis]) / lever, -TFConst.MAX_UV_SHEAR, TFConst.MAX_UV_SHEAR)
			if absf(amount) < TFConst.MIN_UV_SHEAR:
				amount = 0.0
			var shear := Vector2.ZERO
			shear[axis] = amount
			_apply_drag(func(face: TFFace) -> void: TFUV.shear_about(face, _drag_origin, shear, ppm))


## Snaps a rotation so a face edge lines up with a texture axis.
func _snap_rotation(lead: TFFace, degrees: float, ppm: float) -> float:
	# rotate_about() turns edges by +degrees in pixel space unless the
	# texture is mirrored against the face (negative determinant).
	var orientation := signf(_drag_xf.determinant())
	# Two steps: with non-uniform scale an edge does not turn exactly by the angle.
	for i in 2:
		var trial := lead.copy()
		TFUV.rotate_about(trial, _drag_origin, degrees, _polygon, ppm)
		var correction: Variant = TFUV.snap_angle(TFUV.edge_angles(TFUV.to_uv_space(trial, _polygon, ppm)), TFConst.UV_ANGLE_SNAP)
		if correction == null or is_zero_approx(correction):
			break
		degrees += rad_to_deg(correction) * orientation
	return degrees


## Live preview: op on a fresh copy of every start face, written to the faces.
func _apply_drag(op: Callable) -> void:
	for i in _group.size():
		var face := _drag_faces[i].copy()
		op.call(face)
		_assign((_group[i][0] as TFBrush).faces[_group[i][1]], face)
	refresh()


## Commits the previewed faces as one undo action (offsets wrapped).
func _end_drag() -> void:
	var mode := _drag
	_drag = Drag.NONE
	_update_cursor()
	if mode in [Drag.ORIGIN, Drag.ORIGIN_X, Drag.ORIGIN_Y]:
		_set_build_suspended(false)
		return
	var finals: Array[TFFace] = []
	var changed := false
	for i in _group.size():
		var face := (_group[i][0] as TFBrush).faces[_group[i][1]].copy()
		var unwrapped := face.uv_offset
		TFUV.wrap_offset(face, TFUV.get_texture_size(face.material))
		if i == 0:
			# The origin sticks to the texture; wrapping moves both.
			_origin += face.uv_offset - unwrapped
		changed = changed or not _same_uv(face, _drag_faces[i])
		finals.append(face)
	_restore_drag_faces()
	_set_build_suspended(false)
	if changed:
		_modify(_action_name(mode), func(face: TFFace, k: int) -> void: _assign(face, finals[k]))
	refresh()


static func _action_name(mode: Drag) -> String:
	match mode:
		Drag.TRANSLATE:
			return TFI18n.action("Move texture")
		Drag.ROTATE:
			return TFI18n.action("Rotate texture")
		Drag.SHEAR_X, Drag.SHEAR_Y:
			return TFI18n.action("Shear texture")
	return TFI18n.action("Scale texture")


func _zoom(screen: Vector2, factor: float) -> void:
	var zoom := _zoom_of(_view)
	factor = clampf(zoom * factor, MIN_ZOOM, MAX_ZOOM) / zoom
	_view = Transform2D(Vector2(factor, 0), Vector2(0, factor), screen - screen * factor) * _view
	_fit_pending = false
	_auto_fit = false
	_canvas.queue_redraw()


func _update_cursor() -> void:
	var mode := _drag if _drag != Drag.NONE else _hover
	_canvas.mouse_default_cursor_shape = CURSORS.get(mode, Control.CURSOR_ARROW)


# --- toolbar -----------------------------------------------------------------

func _reset_to_plane() -> void:
	_run(TFI18n.action("Reset texture to face plane"), func(face: TFFace, _v: PackedVector3Array, _p: float) -> void: TFUV.reset_to_plane(face))


func _reset_world() -> void:
	_run(TFI18n.action("Reset texture"), func(face: TFFace, _v: PackedVector3Array, _p: float) -> void: TFUV.reset(face))


func _flip(axis: int) -> void:
	_run(TFI18n.action("Flip texture"), func(face: TFFace, v: PackedVector3Array, p: float) -> void: TFUV.flip(face, v, p, axis))


func _rotate(degrees: float) -> void:
	var origin := _origin
	_run(TFI18n.action("Rotate texture"), func(face: TFFace, v: PackedVector3Array, p: float) -> void: TFUV.rotate_about(face, origin, degrees, v, p))


## Runs op(face, outline, ppm) on all faces of the logical face (one undo action).
func _run(action_name: String, op: Callable) -> void:
	if _group.is_empty() or is_dragging():
		return
	var polygon := _polygon
	_modify(action_name, func(face: TFFace, k: int) -> void: op.call(face, polygon, (_group[k][0] as TFBrush).get_ppm()))
	refresh()


## ctx.modify_faces() over the group; fn(face_copy, group_index).
func _modify(action_name: String, fn: Callable) -> void:
	var group := _group
	ctx.modify_faces(action_name, group, func(face: TFFace, brush: TFBrush, index: int) -> void:
		for k in group.size():
			if group[k][0] == brush and group[k][1] == index:
				fn.call(face, k)
				return)


# --- drawing -----------------------------------------------------------------

func _draw_canvas(canvas: Control) -> void:
	canvas.draw_rect(Rect2(Vector2.ZERO, canvas.size), COLOR_BACKGROUND)
	if _group.is_empty() or not _group_valid():
		return
	if _fit_pending and canvas.size.x >= 1.0 and canvas.size.y >= 1.0:
		fit_view()
	var to_pixel := _view.affine_inverse()
	var rect := Rect2(Vector2.ZERO, canvas.size)
	var visible := _screen_bounds(to_pixel, PackedVector2Array([rect.position, Vector2(rect.end.x, 0), rect.end, Vector2(0, rect.end.y)]))
	var lead := _lead()
	var tile := TFUV.get_texture_size(lead.material)

	# Tiled texture (checkerboard without one), aligned to the tile grid.
	var texture := TFUV.get_texture(lead.material)
	if texture == null:
		texture = _checker_texture()
	var tiles_from := (visible.position / tile).floor() * tile
	var tiles_to := (visible.end / tile).ceil() * tile
	canvas.draw_set_transform_matrix(_view)
	canvas.draw_texture_rect(texture, Rect2(tiles_from, tiles_to - tiles_from), true, Color(1, 1, 1, 0.8))
	canvas.draw_set_transform_matrix(Transform2D())

	# UV grid: tile edges plus the Grid X/Y subdivision.
	var cell := _cell()
	for axis in 2:
		var direction := _view.y if axis == 0 else _view.x
		var lines := TFUV.grid_lines(visible.position[axis], visible.end[axis], cell[axis], MAX_GRID_LINES)
		for value in lines:
			var on_tile := absf(value / tile[axis] - roundf(value / tile[axis])) < 1e-4
			var color := TFEditorContext.COLOR_UV_GRID if on_tile else Color(TFEditorContext.COLOR_UV_GRID, TFEditorContext.COLOR_UV_GRID.a * 0.4)
			var hovered := _drag == Drag.NONE and _hover in ([Drag.SCALE_X, Drag.SHEAR_X] if axis == 0 else [Drag.SCALE_Y, Drag.SHEAR_Y]) and is_equal_approx(value, _hover_line)
			hovered = hovered or (_drag in ([Drag.SCALE_X, Drag.SHEAR_X] if axis == 0 else [Drag.SCALE_Y, Drag.SHEAR_Y]) and is_equal_approx(value, _drag_line))
			var point := Vector2(value, visible.position.y) if axis == 0 else Vector2(visible.position.x, value)
			_draw_infinite_line(canvas, _view * point, direction, COLOR_HIGHLIGHT if hovered else color, 2.0 if hovered else 1.0)

	# Face outline and UV axes at its center.
	var ppm := _ppm()
	var polygon := TFUV.to_uv_space(lead, _polygon, ppm)
	var screen_polygon := _view * polygon
	if screen_polygon.size() >= 2:
		screen_polygon.append(screen_polygon[0])
		canvas.draw_polyline(screen_polygon, TFEditorContext.COLOR_UV_OUTLINE, 2.0, true)
	for p in screen_polygon:
		canvas.draw_circle(p, 2.5, TFEditorContext.COLOR_UV_OUTLINE)
	var center := _view * _average(polygon)
	_draw_arrow(canvas, center, _view.x.normalized() * signf(lead.uv_scale.x if lead.uv_scale.x != 0.0 else 1.0), COLOR_U)
	_draw_arrow(canvas, center, _view.y.normalized() * signf(lead.uv_scale.y if lead.uv_scale.y != 0.0 else 1.0), COLOR_V)

	# Origin, its axes and the rotation handle.
	var origin := _view * _origin
	var axis_x_hot := _active(Drag.ORIGIN_X)
	var axis_y_hot := _active(Drag.ORIGIN_Y)
	_draw_infinite_line(canvas, origin, _view.y, COLOR_HIGHLIGHT if axis_x_hot else COLOR_ORIGIN_AXES, 2.0 if axis_x_hot else 1.5)
	_draw_infinite_line(canvas, origin, _view.x, COLOR_HIGHLIGHT if axis_y_hot else COLOR_ORIGIN_AXES, 2.0 if axis_y_hot else 1.5)
	var rotate_hot := _active(Drag.ROTATE)
	canvas.draw_arc(origin, ROTATE_RADIUS, 0.0, TAU, 64, COLOR_HIGHLIGHT if rotate_hot else COLOR_ORIGIN, 2.5 if rotate_hot else 1.5, true)
	canvas.draw_circle(origin, ORIGIN_RADIUS, COLOR_HIGHLIGHT if _active(Drag.ORIGIN) else COLOR_ORIGIN)


func _draw_infinite_line(canvas: Control, through: Vector2, direction: Vector2, color: Color, width: float) -> void:
	if direction.length() < TFConst.EPSILON:
		return
	var reach := direction.normalized() * (canvas.size.length() * 2.0 + through.length())
	canvas.draw_line(through - reach, through + reach, color, width)


func _draw_arrow(canvas: Control, from: Vector2, direction: Vector2, color: Color) -> void:
	var to := from + direction * AXIS_LENGTH
	canvas.draw_line(from, to, color, 2.0, true)
	var side := direction.orthogonal() * 4.0
	canvas.draw_colored_polygon(PackedVector2Array([to + direction * 6.0, to + side, to - side]), color)


func _active(mode: Drag) -> bool:
	return _drag == mode or (_drag == Drag.NONE and _hover == mode)


static func _checker_texture() -> Texture2D:
	if _checker == null:
		var size := TFConst.DEFAULT_TEXTURE_SIZE
		var image := Image.create(size.x, size.y, false, Image.FORMAT_RGB8)
		var square := maxi(size.x / 8, 1)
		for y in size.y:
			for x in size.x:
				image.set_pixel(x, y, Color(0.42, 0.42, 0.45) if (x / square + y / square) % 2 == 0 else Color(0.3, 0.3, 0.33))
		_checker = ImageTexture.create_from_image(image)
	return _checker


# --- helpers -----------------------------------------------------------------

## The one logical face of the targets, or [] (none or several).
func _current_group() -> Array:
	if ctx == null or ctx.map == null or not is_instance_valid(ctx.map):
		return []
	var groups := ctx.target_face_groups()
	return groups[0] if groups.size() == 1 else []


func _group_valid() -> bool:
	for entry in _group:
		var brush: TFBrush = entry[0]
		if not is_instance_valid(brush) or entry[1] >= brush.faces.size() or brush.faces[entry[1]] == null:
			return false
	return true


static func _group_key(group: Array) -> String:
	var parts: PackedStringArray = []
	for entry in group:
		parts.append("%d:%d" % [(entry[0] as TFBrush).get_instance_id(), entry[1]])
	parts.sort()
	return ",".join(parts)


func _lead() -> TFFace:
	return (_group[0][0] as TFBrush).faces[_group[0][1]]


func _ppm() -> float:
	return (_group[0][0] as TFBrush).get_ppm()


## Grid cell in pixels: a tile divided by Grid X/Y; whole tiles when the
## subdivision lines would be too dense on screen.
func _cell() -> Vector2:
	var tile := TFUV.get_texture_size(_lead().material)
	var cell := tile / Vector2(grid_divisions)
	var zoom := _zoom_of(_view)
	for axis in 2:
		if cell[axis] * zoom < MIN_LINE_SPACING:
			cell[axis] = tile[axis]
	return cell


## Start value of the origin: the tile corner nearest to the face center.
func _initial_origin() -> Vector2:
	var tile := TFUV.get_texture_size(_lead().material)
	return (_average(TFUV.to_uv_space(_lead(), _polygon, _ppm())) / tile).round() * tile


## The outline in plane coordinates (for _face_xf).
func _plane_polygon() -> PackedVector2Array:
	var result := PackedVector2Array()
	for p in _polygon:
		var d := p - _plane_point
		result.append(Vector2(d.dot(_basis[0]), d.dot(_basis[1])))
	return result


static func _screen_bounds(xf: Transform2D, points: PackedVector2Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var rect := Rect2(xf * points[0], Vector2.ZERO)
	for p in points:
		rect = rect.expand(xf * p)
	return rect


static func _average(points: PackedVector2Array) -> Vector2:
	var sum := Vector2.ZERO
	for p in points:
		sum += p
	return sum / float(maxi(points.size(), 1))


static func _zoom_of(xf: Transform2D) -> float:
	return sqrt(maxf(absf(xf.determinant()), TFConst.EPSILON))


static func _line_distance(point: Vector2, through: Vector2, direction: Vector2) -> float:
	if direction.length() < TFConst.EPSILON:
		return INF
	return absf((point - through).cross(direction.normalized()))


static func _assign(target: TFFace, source: TFFace) -> void:
	target.u_axis = source.u_axis
	target.v_axis = source.v_axis
	target.uv_offset = source.uv_offset
	target.uv_scale = source.uv_scale
	target.uv_rotation = source.uv_rotation


static func _same_uv(a: TFFace, b: TFFace) -> bool:
	return a.u_axis.is_equal_approx(b.u_axis) and a.v_axis.is_equal_approx(b.v_axis) and a.uv_offset.is_equal_approx(b.uv_offset) \
		and a.uv_scale.is_equal_approx(b.uv_scale) and is_equal_approx(a.uv_rotation, b.uv_rotation)


func _restore_drag_faces() -> void:
	for i in mini(_group.size(), _drag_faces.size()):
		var brush: TFBrush = _group[i][0]
		if is_instance_valid(brush) and _group[i][1] < brush.faces.size():
			_assign(brush.faces[_group[i][1]], _drag_faces[i])


func _set_build_suspended(suspended: bool) -> void:
	if ctx != null and ctx.map != null and is_instance_valid(ctx.map):
		ctx.map.set_build_suspended(suspended)


func _watch(faces: Array[TFFace]) -> void:
	for face in _watched:
		if is_instance_valid(face) and face.changed.is_connected(queue_refresh):
			face.changed.disconnect(queue_refresh)
	_watched = faces
	for face in _watched:
		if not face.changed.is_connected(queue_refresh):
			face.changed.connect(queue_refresh)


func _update_ui() -> void:
	var has_face := not _group.is_empty()
	_hint.visible = not has_face
	for button in _buttons:
		button.disabled = not has_face
	if has_face:
		var face := _lead()
		var shear := rad_to_deg(asin(clampf(TFUV.shear_amount(face), -1.0, 1.0)))
		_info.text = TFI18n.t("Offset %s, %s · Scale %s, %s · Rotation %s° · Shear %s°") % [
			TFTool.format_length(face.uv_offset.x), TFTool.format_length(face.uv_offset.y),
			TFTool.format_length(face.uv_scale.x), TFTool.format_length(face.uv_scale.y),
			TFTool.format_length(face.uv_rotation), TFTool.format_length(shear)]
		if _group.size() > 1:
			_info.text = (TFI18n.t("%d faces") % _group.size()) + " · " + _info.text
	else:
		_info.text = ""
	_canvas.queue_redraw()


func _button(parent: Control, text: String, tooltip: String, on_pressed: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.pressed.connect(on_pressed)
	parent.add_child(button)
	_buttons.append(button)


func _grid_spin(parent: Control, tooltip: String, axis: int) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = 1
	spin.max_value = 16
	spin.step = 1
	spin.rounded = true
	spin.value = grid_divisions[axis]
	spin.tooltip_text = tooltip
	spin.select_all_on_focus = true
	spin.value_changed.connect(func(value: float) -> void:
		grid_divisions[axis] = int(value)
		_canvas.queue_redraw())
	parent.add_child(spin)
	return spin
