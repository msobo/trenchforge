@tool
@icon("res://addons/trenchforge/icons/tf_brush.svg")
class_name TFBrush
extends Node3D
## A convex brush defined by its bounding planes (brush-local space).
##
## The node transform is a pure translation; rotations are baked into the
## planes. The preview mesh is an internal child that is never saved; the
## saved level geometry is produced by the map build (TFMapBuilder).
##
## At runtime no preview is built unless the map has no build output (e.g.
## brushes created by code).

signal geometry_changed

## SOLID renders and collides, NO_COLLISION is render-only decoration,
## COLLISION_ONLY is an invisible collider (player clip).
enum Mode { SOLID, NO_COLLISION, COLLISION_ONLY }

@export var faces: Array[TFFace] = []:
	set(value):
		_disconnect_faces()
		faces = value
		_connect_faces()
		_mark_dirty()

@export var mode: Mode = Mode.SOLID:
	set(value):
		mode = value
		_queue_rebuild()
		_notify_map()

## Headless tests set this to get editor behavior (hidden flag) at runtime.
static var simulate_editor := false

var _polyhedron: TFPolyhedron
var _mesh_instance: MeshInstance3D
var _dirty := true
var _rebuild_queued := false
var _full_preview := true
## Map offset at the last transform notification; moving a parent group
## (e.g. with Godot's instant transform) changes it without a local change.
var _last_map_offset := Vector3.ZERO


## Creates a box brush covering the given AABB (map space). The brush origin
## is placed at the box center.
static func create_box(box: AABB, material: Material = null) -> TFBrush:
	var brush := TFBrush.new()
	brush.name = "Brush"
	brush.position = box.get_center()
	var new_faces: Array[TFFace] = []
	for plane in TFGeometry.box_planes(box.size):
		new_faces.append(TFFace.create(plane, material))
	brush.faces = new_faces
	return brush


func _enter_tree() -> void:
	set_notify_local_transform(true)
	set_notify_transform(true)
	_last_map_offset = get_map_offset()
	_mark_dirty()


func _exit_tree() -> void:
	_rebuild_queued = false
	_notify_map()


func _notification(what: int) -> void:
	# World-aligned UVs depend on the position, so moving needs a rebuild.
	# Local notifications arrive at once; the (deferred) global ones also
	# cover moving a parent group. Moving the map itself keeps the offset
	# and needs nothing.
	if what == NOTIFICATION_LOCAL_TRANSFORM_CHANGED or what == NOTIFICATION_TRANSFORM_CHANGED:
		var offset := get_map_offset()
		if offset.is_equal_approx(_last_map_offset):
			return
		_last_map_offset = offset
		_queue_rebuild()
		_notify_map()


## Hidden in the editor only (Hide/Isolate); never affects build or runtime.
func is_editor_hidden() -> bool:
	return (Engine.is_editor_hint() or simulate_editor) and bool(get_meta(TFConst.META_HIDDEN, false))


func set_editor_hidden(value: bool) -> void:
	if value:
		set_meta(TFConst.META_HIDDEN, true)
	elif has_meta(TFConst.META_HIDDEN):
		remove_meta(TFConst.META_HIDDEN)
	if _mesh_instance != null and is_instance_valid(_mesh_instance):
		_mesh_instance.visible = not is_editor_hidden()
	var map := get_map()
	if map != null:
		map.refresh_visibility()


func has_render() -> bool:
	return mode != Mode.COLLISION_ONLY


func has_collision() -> bool:
	return mode != Mode.NO_COLLISION


func get_planes() -> Array[Plane]:
	var planes: Array[Plane] = []
	for face in faces:
		planes.append(face.plane if face != null else Plane())
	return planes


func get_polyhedron() -> TFPolyhedron:
	if _dirty or _polyhedron == null:
		_polyhedron = TFGeometry.planes_to_polyhedron(get_planes())
		_dirty = false
	return _polyhedron


func is_valid() -> bool:
	return not faces.has(null) and get_polyhedron().is_valid()


## Brush AABB in brush-local space.
func get_local_aabb() -> AABB:
	return get_polyhedron().get_aabb()


func get_map() -> TFMap:
	var node := get_parent()
	while node != null:
		if node is TFMap:
			return node
		node = node.get_parent()
	return null


## Translation from brush-local space into the owning map's space.
func get_map_offset() -> Vector3:
	var map := get_map()
	if map == null or not is_inside_tree():
		return position
	return (map.global_transform.affine_inverse() * global_transform).origin


## Polygon of a face in map space (empty if the face is unused).
func get_face_map_vertices(face_index: int) -> PackedVector3Array:
	var poly := get_polyhedron()
	var result := PackedVector3Array()
	if not poly.is_face_used(face_index):
		return result
	var offset := get_map_offset()
	for v in poly.get_face_vertices(face_index):
		result.append(v + offset)
	return result


## Plane of a face in map space.
func get_face_map_plane(face_index: int) -> Plane:
	var plane := faces[face_index].plane
	var normal := plane.normal.normalized()
	return Plane(normal, plane.d / plane.normal.length() + normal.dot(get_map_offset()))


func get_ppm() -> float:
	var map := get_map()
	return float(map.get_ppm() if map != null else TFConst.get_project_ppm())


## Rebuilds the preview mesh immediately.
func rebuild() -> void:
	_rebuild_queued = false
	if not _wants_preview():
		_free_mesh_instance()
		geometry_changed.emit()
		return
	_ensure_mesh_instance()
	_mesh_instance.visible = not is_editor_hidden()
	var poly := get_polyhedron()
	if faces.has(null) or not poly.is_valid():
		_mesh_instance.mesh = null
	else:
		# Next to a current build only what the build lacks stays visible:
		# clip brushes and nodraw faces.
		var nodraw_only := not _full_preview and has_render()
		_mesh_instance.mesh = TFMeshBuilder.build_brush_mesh(poly, faces, get_map_offset(), get_ppm(), nodraw_only)
	# Clip brushes show the translucent clip material on every face.
	_mesh_instance.material_override = null if has_render() else load(TFConst.MATERIAL_CLIP_PATH) as Material
	geometry_changed.emit()


## Shows the full preview, or only clip brushes and nodraw faces (the map
## reduces previews while its build output is current).
func set_full_preview(value: bool) -> void:
	if _full_preview == value:
		return
	_full_preview = value
	_queue_rebuild()


func get_preview_instance() -> MeshInstance3D:
	return _mesh_instance if _mesh_instance != null and is_instance_valid(_mesh_instance) else null


func _wants_preview() -> bool:
	if Engine.is_editor_hint():
		return true
	var map := get_map()
	return map == null or not map.has_build()


func _ensure_mesh_instance() -> void:
	if _mesh_instance != null and is_instance_valid(_mesh_instance):
		return
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "_TFPreview"
	# Internal children are not shown in the scene dock and never saved.
	add_child(_mesh_instance, false, Node.INTERNAL_MODE_FRONT)


func _free_mesh_instance() -> void:
	if _mesh_instance != null and is_instance_valid(_mesh_instance):
		_mesh_instance.queue_free()
	_mesh_instance = null


func _mark_dirty() -> void:
	_dirty = true
	_queue_rebuild()
	_notify_map()


func _notify_map() -> void:
	if not is_inside_tree():
		return
	var map := get_map()
	if map != null:
		map.notify_brush_changed()


func _queue_rebuild() -> void:
	if _rebuild_queued or not is_inside_tree():
		return
	_rebuild_queued = true
	rebuild.call_deferred()


func _on_face_changed() -> void:
	_mark_dirty()


func _connect_faces() -> void:
	for face in faces:
		if face != null and not face.changed.is_connected(_on_face_changed):
			face.changed.connect(_on_face_changed)


func _disconnect_faces() -> void:
	for face in faces:
		if face != null and face.changed.is_connected(_on_face_changed):
			face.changed.disconnect(_on_face_changed)
