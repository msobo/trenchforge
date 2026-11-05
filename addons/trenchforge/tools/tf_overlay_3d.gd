@tool
class_name TFOverlay3D
extends Node3D
## Editor-only 3D helper geometry: lines, translucent polygons and the grid
## plane. Lives as an internal, unsaved child of the active TFMap and uses
## world coordinates (top_level).
##
## All geometry is drawn through bare RenderingServer instances, not child
## nodes: Godot's selection box of the TFMap includes all visible child meshes
## (even top_level ones), so the grid plane would stretch it to the horizon and
## the tool previews (e.g. the Box tool's cursor cross) to the mouse cursor.

const GRID_SHADER := preload("res://addons/trenchforge/tools/tf_grid.gdshader")
const GRID_EXTENT: float = 512.0
## Offset along the plane normal to avoid z-fighting with coplanar faces.
const GRID_OFFSET: float = 0.002
## Screen size (px, before editor scale) of point handles.
const POINT_SIZE: float = 9.0
## Grid lines per direction and side on a plane patch (clip plane preview).
const PLANE_PATCH_MAX_LINES: int = 16
## Arrowhead length as a fraction of the arrow length.
const ARROW_HEAD_FRACTION: float = 0.25

var _lines: Array = []  # [Vector3 a, Vector3 b, Color]
var _polygons: Array = []  # [PackedVector3Array, Color]
var _points: Array = []  # [Vector3, Color]
var _line_mesh := ImmediateMesh.new()
var _fill_mesh := ImmediateMesh.new()
var _point_mesh := ImmediateMesh.new()
var _materials: Array[StandardMaterial3D] = []  # Keeps the override materials alive.
var _mesh_rids: Array[RID] = []  # Line, fill and point instances.
var _grid_rid: RID
var _grid_mesh: PlaneMesh
var _grid_material: ShaderMaterial
var _grid_shown := false


func _init() -> void:
	name = "_TFOverlay"
	top_level = true

	_make_instance(_fill_mesh)
	_make_instance(_line_mesh)
	var point_material := _make_instance(_point_mesh)
	point_material.use_point_size = true
	point_material.point_size = POINT_SIZE * EditorInterface.get_editor_scale()

	_grid_material = ShaderMaterial.new()
	_grid_material.shader = GRID_SHADER
	_grid_mesh = PlaneMesh.new()
	_grid_mesh.size = Vector2(GRID_EXTENT, GRID_EXTENT)
	_grid_mesh.material = _grid_material
	_grid_rid = RenderingServer.instance_create2(_grid_mesh.get_rid(), RID())
	RenderingServer.instance_geometry_set_cast_shadows_setting(
		_grid_rid, RenderingServer.SHADOW_CASTING_SETTING_OFF)
	RenderingServer.instance_set_visible(_grid_rid, false)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_ENTER_WORLD:
			for rid in _all_rids():
				RenderingServer.instance_set_scenario(rid, get_world_3d().scenario)
		NOTIFICATION_EXIT_WORLD:
			for rid in _all_rids():
				RenderingServer.instance_set_scenario(rid, RID())
		NOTIFICATION_VISIBILITY_CHANGED:
			for rid in _mesh_rids:
				RenderingServer.instance_set_visible(rid, is_visible_in_tree())
			_update_grid_visibility()
		NOTIFICATION_PREDELETE:
			# Arrives before EXIT_WORLD, so the handlers above must skip freed RIDs.
			for rid in _all_rids():
				RenderingServer.free_rid(rid)
			_mesh_rids.clear()
			_grid_rid = RID()


func clear() -> void:
	_lines.clear()
	_polygons.clear()
	_points.clear()


func add_line(a: Vector3, b: Vector3, color: Color) -> void:
	_lines.append([a, b, color])


func add_polygon(points: PackedVector3Array, color: Color) -> void:
	if points.size() >= 3:
		_polygons.append([points, color])


## Screen-sized square handle (vertex, edge or face handle).
func add_point(point: Vector3, color: Color) -> void:
	_points.append([point, color])


## Draws all edges of a brush.
func add_brush_edges(brush: TFBrush, color: Color) -> void:
	var poly := brush.get_polyhedron()
	var xf := brush.global_transform
	for edge in poly.edges:
		add_line(xf * poly.vertices[edge.x], xf * poly.vertices[edge.y], color)


## Draws the edges of the convex volume of the faces (local space of xf).
func add_faces_edges(faces: Array[TFFace], xf: Transform3D, color: Color) -> void:
	var poly := TFGeometry.planes_to_polyhedron(TFCSG.planes_of(faces))
	for edge in poly.edges:
		add_line(xf * poly.vertices[edge.x], xf * poly.vertices[edge.y], color)


## Fills all polygons of the convex volume of the faces (local space of xf).
func add_faces_fill(faces: Array[TFFace], xf: Transform3D, color: Color) -> void:
	var poly := TFGeometry.planes_to_polyhedron(TFCSG.planes_of(faces))
	for i in poly.face_polygons.size():
		var points := PackedVector3Array()
		for v in poly.get_face_vertices(i):
			points.append(xf * v)
		add_polygon(points, color)


## Draws the edges of an already built polyhedron (local space of xf).
func add_polyhedron_edges(poly: TFPolyhedron, xf: Transform3D, color: Color) -> void:
	for edge in poly.edges:
		add_line(xf * poly.vertices[edge.x], xf * poly.vertices[edge.y], color)


## Fills the polygons of an already built polyhedron (local space of xf).
func add_polyhedron_fill(poly: TFPolyhedron, xf: Transform3D, color: Color) -> void:
	for i in poly.face_polygons.size():
		var points := PackedVector3Array()
		for v in poly.get_face_vertices(i):
			points.append(xf * v)
		add_polygon(points, color)


## Square patch of a plane around center with grid lines every step.
func add_plane_patch(plane: Plane, center: Vector3, half_size: float, step: float, color: Color) -> void:
	var normal := plane.normal
	var u := normal.cross(Vector3.UP if absf(normal.y) < 0.9 else Vector3.RIGHT).normalized()
	var v := normal.cross(u)
	var origin := plane.project(center)
	var corners := PackedVector3Array([
		origin + (-u - v) * half_size, origin + (u - v) * half_size,
		origin + (u + v) * half_size, origin + (-u + v) * half_size,
	])
	add_polygon(corners, Color(color, color.a * 0.15))
	for i in 4:
		add_line(corners[i], corners[(i + 1) % 4], color)
	var lines := mini(int(half_size / maxf(step, TFConst.EPSILON)), PLANE_PATCH_MAX_LINES)
	var faint := Color(color, color.a * 0.4)
	for i in range(-lines, lines + 1):
		var offset := float(i) * half_size / float(maxi(lines, 1))
		add_line(origin + u * offset - v * half_size, origin + u * offset + v * half_size, faint)
		add_line(origin + v * offset - u * half_size, origin + v * offset + u * half_size, faint)


## Line from origin along direction (normalized) with a four-sided arrowhead.
func add_arrow(origin: Vector3, direction: Vector3, length: float, color: Color) -> void:
	var tip := origin + direction * length
	add_line(origin, tip, color)
	var u := direction.cross(Vector3.UP if absf(direction.y) < 0.9 else Vector3.RIGHT).normalized()
	var v := direction.cross(u)
	var head := length * ARROW_HEAD_FRACTION
	var base := tip - direction * head
	for side: Vector3 in [u, -u, v, -v]:
		add_line(tip, base + side * head * 0.5, color)


func add_box(box: AABB, color: Color) -> void:
	var p := box.position
	var s := box.size
	var corners: Array[Vector3] = []
	for i in 8:
		corners.append(p + Vector3(s.x if i & 1 else 0.0, s.y if i & 2 else 0.0, s.z if i & 4 else 0.0))
	for pair in [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]:
		add_line(corners[pair[0]], corners[pair[1]], color)


func add_cross(point: Vector3, size: float, color: Color) -> void:
	add_line(point - Vector3(size, 0, 0), point + Vector3(size, 0, 0), color)
	add_line(point - Vector3(0, size, 0), point + Vector3(0, size, 0), color)
	add_line(point - Vector3(0, 0, size), point + Vector3(0, 0, size), color)


## Uploads the collected primitives.
func flush() -> void:
	_line_mesh.clear_surfaces()
	if not _lines.is_empty():
		_line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		for line in _lines:
			_line_mesh.surface_set_color(line[2])
			_line_mesh.surface_add_vertex(line[0])
			_line_mesh.surface_add_vertex(line[1])
		_line_mesh.surface_end()

	_point_mesh.clear_surfaces()
	if not _points.is_empty():
		_point_mesh.surface_begin(Mesh.PRIMITIVE_POINTS)
		for point in _points:
			_point_mesh.surface_set_color(point[1])
			_point_mesh.surface_add_vertex(point[0])
		_point_mesh.surface_end()

	_fill_mesh.clear_surfaces()
	if not _polygons.is_empty():
		_fill_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		for entry in _polygons:
			var points: PackedVector3Array = entry[0]
			_fill_mesh.surface_set_color(entry[1])
			for i in range(1, points.size() - 1):
				_fill_mesh.surface_add_vertex(points[0])
				_fill_mesh.surface_add_vertex(points[i + 1])
				_fill_mesh.surface_add_vertex(points[i])
		_fill_mesh.surface_end()


## Shows the grid on an axis-aligned plane through point, fading out around it.
func show_grid(point: Vector3, axis: Vector3, grid_size: float) -> void:
	var i := TFSnap.axis_index(axis)
	var basis := Basis.IDENTITY
	if i == 0:
		basis = Basis(Vector3.BACK, PI * 0.5)
	elif i == 2:
		basis = Basis(Vector3.RIGHT, PI * 0.5)
	var origin := TFSnap.snap(point, grid_size * 8.0)
	origin[i] = point[i] + GRID_OFFSET * signf(axis[i] if axis[i] != 0.0 else 1.0)
	RenderingServer.instance_set_transform(_grid_rid, Transform3D(basis, origin))
	_grid_material.set_shader_parameter("axis", i)
	_grid_material.set_shader_parameter("grid_size", grid_size)
	_grid_material.set_shader_parameter("center", point)
	_grid_material.set_shader_parameter("fade_radius", clampf(grid_size * 32.0, 8.0, 256.0))
	_grid_shown = true
	_update_grid_visibility()


func hide_grid() -> void:
	_grid_shown = false
	_update_grid_visibility()


func _update_grid_visibility() -> void:
	if _grid_rid.is_valid():
		RenderingServer.instance_set_visible(_grid_rid, _grid_shown and is_visible_in_tree())


func _all_rids() -> Array[RID]:
	var rids := _mesh_rids.duplicate()
	if _grid_rid.is_valid():
		rids.append(_grid_rid)
	return rids


## Creates a world-space instance of mesh and returns its override material.
func _make_instance(mesh: Mesh) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = 10
	var rid := RenderingServer.instance_create2(mesh.get_rid(), RID())
	RenderingServer.instance_geometry_set_material_override(rid, material.get_rid())
	RenderingServer.instance_geometry_set_cast_shadows_setting(
		rid, RenderingServer.SHADOW_CASTING_SETTING_OFF)
	_materials.append(material)
	_mesh_rids.append(rid)
	return material
