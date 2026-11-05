@tool
@icon("res://addons/trenchforge/icons/tf_map.svg")
class_name TFMap
extends Node3D
## Root node of a TrenchForge level. Holds map settings and owns all brushes
## below it (direct children or nested in group nodes).
##
## The level geometry used at runtime is the saved build output below the
## child BUILD_NODE_NAME (see TFMapBuilder). In the editor the map tracks
## whether that output is current and rebuilds it automatically (debounced).
## At runtime nothing is built.

## Emitted whenever brushes or build settings change and when the build
## output was replaced or found to be current.
signal build_state_changed
## Emitted when brushes were hidden or shown in the editor.
signal editor_visibility_changed

## Snapping step; maps that never changed it use the project setting
## trenchforge/default_grid_size.
@export_range(0.0625, 32.0, 0.0625) var grid_size: float = TFConst.get_default_grid_size()

## Pixels per meter for this map; 0 uses the project setting.
@export_range(0, 4096, 1) var ppm_override: int = 0:
	set(value):
		ppm_override = value
		if is_inside_tree():
			rebuild_all()
		_settings_changed()

@export_group("Build")
## Rebuild the output automatically shortly after each change (editor only).
@export var auto_build: bool = true:
	set(value):
		auto_build = value
		if auto_build and _build_dirty:
			_schedule_build()
## Skip faces fully covered by an opposite coplanar face of another brush.
@export var hidden_face_removal: bool = true:
	set(value):
		hidden_face_removal = value
		_settings_changed()
## Merge identical vertices within each surface.
@export var weld_vertices: bool = true:
	set(value):
		weld_vertices = value
		_settings_changed()
## Edge length of spatial mesh chunks in meters; 0 builds one mesh.
@export_range(0.0, 1024.0, 0.5, "or_greater", "suffix:m") var chunk_size: float = 0.0:
	set(value):
		chunk_size = value
		_settings_changed()
## Generate UV2 for LightmapGI (slow on large maps).
@export var generate_uv2: bool = false:
	set(value):
		generate_uv2 = value
		_settings_changed()
@export_range(0.01, 4.0, 0.01, "suffix:m") var lightmap_texel_size: float = TFConst.DEFAULT_LIGHTMAP_TEXEL_SIZE:
	set(value):
		lightmap_texel_size = value
		_settings_changed()
## Generate an OccluderInstance3D from large brushes (occlusion culling).
@export var generate_occluder: bool = false:
	set(value):
		generate_occluder = value
		_settings_changed()
## Brushes whose smallest extent is below this do not occlude.
@export_range(0.0, 64.0, 0.25, "or_greater", "suffix:m") var occluder_min_size: float = 2.0:
	set(value):
		occluder_min_size = value
		_settings_changed()
@export_flags_3d_physics var collision_layer: int = 1:
	set(value):
		collision_layer = value
		_settings_changed()
@export_flags_3d_physics var collision_mask: int = 1:
	set(value):
		collision_mask = value
		_settings_changed()

var _build_dirty := true
var _build_suspended := false
var _build_timer: Timer


func _enter_tree() -> void:
	# A freshly loaded map has to compare its saved output first.
	_build_dirty = true
	_schedule_build()


func _exit_tree() -> void:
	if _build_timer != null:
		_build_timer.stop()


func _notification(what: int) -> void:
	if not Engine.is_editor_hint():
		return
	match what:
		NOTIFICATION_EDITOR_PRE_SAVE:
			# The saved output must be current and visible.
			if _build_dirty and auto_build:
				refresh_build_state()
				if _build_dirty:
					build()
			_set_output_visible(true, true)
		NOTIFICATION_EDITOR_POST_SAVE:
			_update_visibility()


func get_ppm() -> int:
	return ppm_override if ppm_override > 0 else TFConst.get_project_ppm()


func get_brushes() -> Array[TFBrush]:
	var result: Array[TFBrush] = []
	_collect_brushes(self, result)
	return result


## Rebuilds all brush preview meshes.
func rebuild_all() -> void:
	for brush in get_brushes():
		brush.rebuild()


# --- build output ---------------------------------------------------------------

func get_build_root() -> Node3D:
	return get_node_or_null(NodePath(TFConst.BUILD_NODE_NAME)) as Node3D


func has_build() -> bool:
	return get_build_root() != null


## True if brushes or settings changed since the last build (or since the
## saved output was last verified).
func is_build_dirty() -> bool:
	return _build_dirty


## Replaces the build output now.
func build() -> void:
	TFMapBuilder.build(self)
	_build_dirty = false
	if _build_timer != null:
		_build_timer.stop()
	_update_visibility()
	build_state_changed.emit()


## Marks the output current if its stored hash matches the map; returns
## whether it is current.
func refresh_build_state() -> bool:
	var root := get_build_root()
	var current := root != null and String(root.get_meta(TFConst.META_BUILD_HASH, "")) == TFMapBuilder.compute_hash(self)
	if current != not _build_dirty:
		_build_dirty = not current
		_update_visibility()
		build_state_changed.emit()
	return current


## Called by brushes when their geometry, attributes, position or presence
## changes.
func notify_brush_changed() -> void:
	if not _build_dirty:
		_build_dirty = true
		_update_visibility()
	_schedule_build()
	build_state_changed.emit()


## Defers automatic rebuilds while a tool drag is in progress.
func set_build_suspended(value: bool) -> void:
	if _build_suspended == value:
		return
	_build_suspended = value
	if not value and _build_dirty:
		_schedule_build()


func _settings_changed() -> void:
	if is_inside_tree():
		notify_brush_changed()


func _schedule_build() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if _build_timer == null:
		_build_timer = Timer.new()
		_build_timer.name = "_TFBuildTimer"
		_build_timer.one_shot = true
		_build_timer.timeout.connect(_on_build_timer)
		add_child(_build_timer, false, Node.INTERNAL_MODE_BACK)
	_build_timer.start(TFConst.BUILD_DEBOUNCE)


func _on_build_timer() -> void:
	if not _build_dirty:
		return
	if _build_suspended:
		_schedule_build()
		return
	if not refresh_build_state() and auto_build:
		build()


## True if any brush is hidden in the editor (Hide/Isolate).
func has_hidden_brushes() -> bool:
	for brush in get_brushes():
		if brush.is_editor_hidden():
			return true
	return false


## Re-evaluates preview/output visibility after brushes were hidden or shown.
func refresh_visibility() -> void:
	_update_visibility()
	editor_visibility_changed.emit()


## Whether the collision output is visible in the editor viewport (editor
## setting trenchforge/viewport/show_collision). Saved scenes always keep it
## visible. Stored as engine metadata because the editor resets static
## variables when it reloads scripts.
static func is_collision_shown_in_editor() -> bool:
	return Engine.get_meta(TFConst.META_SHOW_COLLISION, true)


static func set_collision_shown_in_editor(value: bool) -> void:
	Engine.set_meta(TFConst.META_SHOW_COLLISION, value)


## Reapplies the editor visibility of output and previews (after a change
## of the collision visibility).
func refresh_editor_visibility() -> void:
	_update_visibility()


## In the editor exactly one representation is visible: the build output
## while it is current and nothing is hidden, otherwise the live brush
## previews (hidden brushes simply have no visible preview).
func _update_visibility() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	var show_output := has_build() and not _build_dirty and not has_hidden_brushes()
	_set_output_visible(show_output, is_collision_shown_in_editor())
	for brush in get_brushes():
		brush.set_full_preview(not show_output)


func _set_output_visible(meshes: bool, collision: bool) -> void:
	var root := get_build_root()
	if root == null:
		return
	for child in root.get_children():
		if child is MeshInstance3D:
			child.visible = meshes
		elif child is StaticBody3D:
			child.visible = collision


func _collect_brushes(node: Node, result: Array[TFBrush]) -> void:
	for child in node.get_children():
		if node == self and child.name == TFConst.BUILD_NODE_NAME:
			continue
		if child is TFBrush:
			result.append(child)
		_collect_brushes(child, result)
