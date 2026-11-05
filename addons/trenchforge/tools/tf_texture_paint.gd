@tool
class_name TFTexturePaint
extends RefCounted
## Anvil-style quick texturing, available in every tool:
##   Alt+LMB        material + UV of the selected source face (drag = paint;
##                  in a compound the whole logical face under the cursor)
##   Ctrl+Alt+LMB   continue the source texture seamlessly (drag paints a chain)
##   Alt+RMB        pick material + UV of the clicked face onto the selection
##   Shift+Alt+RMB  pick UV only, stretched to each selected face
## Without exactly one selected source face, Alt+LMB applies the current
## material. Each gesture is one undo action.

enum Mode { MATERIAL, APPLY, WRAP }

var ctx: TFEditorContext

var _painting := false
var _mode := Mode.MATERIAL
var _source: TFFace
var _source_plane := Plane()
var _snapshots := {}  # TFBrush -> Array[TFFace] before the gesture
var _painted := {}  # face key -> true


func _init(p_ctx: TFEditorContext) -> void:
	ctx = p_ctx


func is_painting() -> bool:
	return _painting


## Returns true if the event was consumed.
func handle_input(camera: Camera3D, event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed and button.alt_pressed and not _painting:
				_begin(camera, button)
				return true
			if not button.pressed and _painting:
				_finish()
				return true
		elif button.button_index == MOUSE_BUTTON_RIGHT and button.alt_pressed:
			if button.pressed:
				_pick(camera, button)
			return true
	elif event is InputEventMouseMotion and _painting:
		var hit := ctx.pick(camera, event.position)
		if not hit.is_empty():
			_paint(hit["brush"], hit["face_index"])
		return true
	return false


## Restores all faces painted in the current gesture.
func cancel() -> void:
	if not _painting:
		return
	for brush: TFBrush in _snapshots:
		if is_instance_valid(brush):
			brush.faces = TFUndo.copy_faces(_snapshots[brush])
	_reset()


func get_hint() -> String:
	if not _painting:
		return ""
	match _mode:
		Mode.APPLY:
			return TFI18n.t("Paint: transfer material + UV")
		Mode.WRAP:
			return TFI18n.t("Paint: continue tiling seamlessly")
	return TFI18n.t("Paint: apply current material")


func _begin(camera: Camera3D, event: InputEventMouseButton) -> void:
	_reset()
	var source := _source_entry()
	if source.is_empty():
		if ctx.current_material == null:
			return
		_mode = Mode.MATERIAL
	else:
		_mode = Mode.WRAP if TFTool.is_ctrl(event) else Mode.APPLY
		_set_source(source[0], source[1])
		# Never paint over the source itself.
		_painted[_key(source[0], source[1])] = true
	_painting = true
	var hit := ctx.pick(camera, event.position)
	if not hit.is_empty():
		_paint(hit["brush"], hit["face_index"])


func _finish() -> void:
	var brushes: Array = []
	var old_faces: Array = []
	var new_faces: Array = []
	for brush: TFBrush in _snapshots:
		if is_instance_valid(brush):
			brushes.append(brush)
			old_faces.append(_snapshots[brush])
			new_faces.append(brush.faces)
	_reset()
	if not brushes.is_empty():
		TFUndo.commit_many_faces(ctx.undo_redo(), TFI18n.action("Texture"), brushes, old_faces, new_faces)


## Paints the logical face under the cursor (all faces of its region in a
## closed compound).
func _paint(brush: TFBrush, face_index: int) -> void:
	if _painted.has(_key(brush, face_index)):
		return
	var painted := false
	for entry in ctx.logical_face(brush, face_index):
		painted = _paint_face(entry[0], entry[1]) or painted
	if painted and _mode == Mode.WRAP:
		# Dragging on continues from the face painted last.
		_set_source(brush, face_index)


## Returns false if the face was painted before in this gesture.
func _paint_face(brush: TFBrush, face_index: int) -> bool:
	var key := _key(brush, face_index)
	if _painted.has(key):
		return false
	_painted[key] = true
	if not _snapshots.has(brush):
		_snapshots[brush] = TFUndo.snapshot_faces(brush)
	var faces := TFUndo.copy_faces(brush.faces)
	var face := faces[face_index]
	match _mode:
		Mode.MATERIAL:
			face.material = ctx.current_material
		Mode.APPLY:
			face.material = _source.material
			TFUV.copy_attributes(_source, face)
		Mode.WRAP:
			face.material = _source.material
			TFUV.wrap_attributes(_source, _source_plane, face, brush.get_face_map_plane(face_index), brush.get_ppm())
	brush.faces = faces
	return true


func _pick(camera: Camera3D, event: InputEventMouseButton) -> void:
	var hit := ctx.pick(camera, event.position)
	if hit.is_empty():
		return
	var brush: TFBrush = hit["brush"]
	var index: int = hit["face_index"]
	var source := brush.faces[index].copy()
	var source_vertices := brush.get_face_map_vertices(index)
	var stretch := event.shift_pressed
	if not stretch and source.material != null:
		ctx.current_material = source.material
	var targets: Array = []
	for entry in ctx.target_faces():
		if entry[0] != brush or entry[1] != index:
			targets.append(entry)
	if stretch:
		ctx.modify_faces(TFI18n.action("Copy UV stretched"), targets, func(face: TFFace, target: TFBrush, target_index: int) -> void:
			TFUV.stretch_attributes(source, source_vertices, face, target.get_face_map_vertices(target_index), target.get_ppm()))
	else:
		ctx.modify_faces(TFI18n.action("Pick material"), targets, func(face: TFFace, _target: TFBrush, _target_index: int) -> void:
			face.material = source.material
			TFUV.copy_attributes(source, face))


## [brush, face_index] if exactly one face is selected (face mode), else [].
func _source_entry() -> Array:
	if not ctx.face_mode:
		return []
	ctx.prune_faces()
	return ctx.selected_faces[0] if ctx.selected_faces.size() == 1 else []


func _set_source(brush: TFBrush, face_index: int) -> void:
	_source = brush.faces[face_index].copy()
	_source_plane = brush.get_face_map_plane(face_index)


func _reset() -> void:
	_painting = false
	_snapshots = {}
	_painted = {}


static func _key(brush: TFBrush, face_index: int) -> String:
	return "%d:%d" % [brush.get_instance_id(), face_index]
