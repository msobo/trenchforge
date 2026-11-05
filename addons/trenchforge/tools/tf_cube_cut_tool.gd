@tool
class_name TFCubeCutTool
extends TFBoxTool
## Cube cut (Anvil): drawn like a box brush, but the box is a temporary cutter
## that is subtracted from every brush it overlaps right away. In an
## orthographic view along the box axis the cut goes through everything.
## The faces of the opening continue the cut brushes' faces.

const COLOR_CUT := Color(1.0, 0.35, 0.25, 1.0)
const COLOR_AFFECTED := Color(1.0, 0.6, 0.2, 0.9)

var _actions: TFCSGActions
var _through := false


func _init(p_ctx: TFEditorContext) -> void:
	super(p_ctx)
	_actions = TFCSGActions.new(p_ctx)


func get_tool_name() -> String:
	return "cube_cut"


func get_hint() -> String:
	match _state:
		State.BASE:
			return TFI18n.t("Cube-Cut · LMB: set base (ortho: cuts through everything) · %s: cancel") % keys("cancel")
		State.HEIGHT:
			return TFI18n.t("Cube-Cut · Mouse: depth · LMB: cut · %s: cancel") % keys("cancel")
	return TFI18n.t("Cube-Cut · LMB: start point (or drag) · Ctrl: lock plane · %s: Select tool") % keys("cancel")


func draw_3d(overlay: TFOverlay3D) -> void:
	if _state == State.IDLE:
		super(overlay)
		return
	var box := _current_box()
	overlay.add_box(box, COLOR_CUT)
	# Preview of the brushes the cut will change.
	for brush in ctx.brushes_in_box(box):
		var brush_box := brush.global_transform * brush.get_local_aabb()
		if brush_box.intersects(box):
			overlay.add_brush_edges(brush, COLOR_AFFECTED)


func _commit_ortho() -> void:
	_through = true
	_height = ctx.grid_size()
	_state = State.HEIGHT
	_commit()


func _create(box: AABB) -> void:
	var cutter := box
	if _through:
		_through = false
		cutter = _through_all(box)
	var faces: Array[TFFace] = []
	var center := cutter.get_center()
	for plane in TFGeometry.box_planes(cutter.size):
		faces.append(TFFace.create(Plane(plane.normal, plane.d + plane.normal.dot(center))))
	if not _actions.subtract(ctx.brushes_in_box(cutter), faces, true, TFI18n.action("Cube-Cut")):
		_actions.toast(TFI18n.t("Cube-Cut: no brushes hit."))


## Stretches the box along its axis over all brushes of the map.
func _through_all(box: AABB) -> AABB:
	var brushes := ctx.brushes()
	if brushes.is_empty():
		return box
	var all := TFPicking.brushes_aabb(brushes).grow(ctx.grid_size())
	var i := TFSnap.axis_index(_axis)
	var result := box
	result.position[i] = all.position[i]
	result.size[i] = all.size[i]
	return result
