class_name TFMeshBuilder
extends RefCounted
## Builds render meshes from brush polyhedra: flat shaded, fan triangulated,
## one surface per material.

static var _fallback_material: StandardMaterial3D


## Builds an ArrayMesh for one brush. map_offset translates brush-local
## points into map space for world-aligned UVs. With nodraw_only, only nodraw
## faces are included (editor overlay next to the build output). Faces with
## the nodraw flag use the tf_nodraw material. Returns null if empty.
static func build_brush_mesh(poly: TFPolyhedron, faces: Array[TFFace], map_offset: Vector3, ppm: float, nodraw_only: bool = false) -> ArrayMesh:
	# Material (or null) -> surface arrays being collected.
	var surfaces := {}
	for face_index in faces.size():
		if not poly.is_face_used(face_index):
			continue
		var face := faces[face_index]
		if nodraw_only and not face.is_nodraw():
			continue
		var key: Material = face.material
		if face.flags & TFFace.FLAG_NODRAW:
			key = load(TFConst.MATERIAL_NODRAW_PATH)
		if not surfaces.has(key):
			surfaces[key] = new_surface()
		append_face(surfaces[key], poly, face_index, face, map_offset, ppm)
	if surfaces.is_empty():
		return null
	var mesh := ArrayMesh.new()
	for key in surfaces:
		add_surface(mesh, surfaces[key], key)
	return mesh


## Empty arrays for one surface, filled by append_face().
static func new_surface() -> Dictionary:
	return {
		"vertices": PackedVector3Array(),
		"normals": PackedVector3Array(),
		"tangents": PackedFloat32Array(),
		"uvs": PackedVector2Array(),
		"indices": PackedInt32Array(),
	}


## Adds the collected arrays as a surface; a null material uses the fallback.
static func add_surface(mesh: ArrayMesh, data: Dictionary, material: Material) -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data["vertices"]
	arrays[Mesh.ARRAY_NORMAL] = data["normals"]
	arrays[Mesh.ARRAY_TANGENT] = data["tangents"]
	arrays[Mesh.ARRAY_TEX_UV] = data["uvs"]
	arrays[Mesh.ARRAY_INDEX] = data["indices"]
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(mesh.get_surface_count() - 1, material if material != null else get_fallback_material())


## Appends one face polygon (fan triangulated). UVs use map_offset; vertices
## are translated by vertex_offset (zero for brush-local preview meshes).
static func append_face(data: Dictionary, poly: TFPolyhedron, face_index: int, face: TFFace, map_offset: Vector3, ppm: float, vertex_offset: Vector3 = Vector3.ZERO) -> void:
	var vertices: PackedVector3Array = data["vertices"]
	var normals: PackedVector3Array = data["normals"]
	var tangents: PackedFloat32Array = data["tangents"]
	var uvs: PackedVector2Array = data["uvs"]
	var indices: PackedInt32Array = data["indices"]

	var normal := face.plane.normal.normalized()
	var axes := TFUV.rotated_axes(face)
	var texture_size := TFUV.get_texture_size(face.material)
	var tangent := (axes[0] - normal * normal.dot(axes[0])).normalized()
	var bitangent_sign := -1.0 if normal.cross(tangent).dot(axes[1]) < 0.0 else 1.0

	var base := vertices.size()
	var polygon := poly.face_polygons[face_index]
	for index in polygon:
		var p := poly.vertices[index]
		vertices.append(p + vertex_offset)
		normals.append(normal)
		tangents.append_array([tangent.x, tangent.y, tangent.z, bitangent_sign])
		uvs.append(TFUV.compute_uv(face, axes, p + map_offset, texture_size, ppm))

	# Polygons are CCW from outside; Godot treats clockwise as front-facing.
	for i in range(1, polygon.size() - 1):
		indices.append_array([base, base + i + 1, base + i])

	data["vertices"] = vertices
	data["normals"] = normals
	data["tangents"] = tangents
	data["uvs"] = uvs
	data["indices"] = indices


## Merges vertices that agree in position, normal, tangent and UV (within
## TFConst.WELD_EPSILON). Returns new surface data.
static func weld(data: Dictionary) -> Dictionary:
	var vertices: PackedVector3Array = data["vertices"]
	var normals: PackedVector3Array = data["normals"]
	var tangents: PackedFloat32Array = data["tangents"]
	var uvs: PackedVector2Array = data["uvs"]
	var result := new_surface()
	var out_vertices: PackedVector3Array = result["vertices"]
	var out_normals: PackedVector3Array = result["normals"]
	var out_tangents: PackedFloat32Array = result["tangents"]
	var out_uvs: PackedVector2Array = result["uvs"]
	var remap := PackedInt32Array()
	remap.resize(vertices.size())
	var seen := {}
	var step := TFConst.WELD_EPSILON
	for i in vertices.size():
		var tangent := Vector4(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2], tangents[i * 4 + 3])
		var key := [vertices[i].snapped(Vector3.ONE * step), normals[i].snapped(Vector3.ONE * step), uvs[i].snapped(Vector2.ONE * step), tangent.snapped(Vector4.ONE * step)]
		if seen.has(key):
			remap[i] = seen[key]
			continue
		remap[i] = out_vertices.size()
		seen[key] = remap[i]
		out_vertices.append(vertices[i])
		out_normals.append(normals[i])
		out_tangents.append_array([tangent.x, tangent.y, tangent.z, tangent.w])
		out_uvs.append(uvs[i])
	var out_indices := PackedInt32Array()
	for index in data["indices"]:
		out_indices.append(remap[index])
	result["vertices"] = out_vertices
	result["normals"] = out_normals
	result["tangents"] = out_tangents
	result["uvs"] = out_uvs
	result["indices"] = out_indices
	return result


## Grey checker material used for faces without a material.
## Loads the shipped tf_default material; generates it if the file is
## missing (it is never embedded into scenes when the file exists).
static func get_fallback_material() -> StandardMaterial3D:
	if _fallback_material != null:
		return _fallback_material
	if ResourceLoader.exists(TFConst.MATERIAL_DEFAULT_PATH):
		_fallback_material = load(TFConst.MATERIAL_DEFAULT_PATH) as StandardMaterial3D
		if _fallback_material != null:
			return _fallback_material
	_fallback_material = create_fallback_material()
	return _fallback_material


static func create_fallback_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.resource_name = "TFFallback"
	material.albedo_texture = ImageTexture.create_from_image(create_fallback_image())
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return material


static func create_fallback_image() -> Image:
	var size := TFConst.DEFAULT_TEXTURE_SIZE
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGB8)
	var half := Vector2i(size.x / 2, size.y / 2)
	var light := Color(0.62, 0.62, 0.62)
	var dark := Color(0.48, 0.48, 0.48)
	image.fill(light)
	image.fill_rect(Rect2i(Vector2i.ZERO, half), dark)
	image.fill_rect(Rect2i(half, half), dark)
	var line := Color(0.35, 0.35, 0.35)
	image.fill_rect(Rect2i(0, 0, size.x, 1), line)
	image.fill_rect(Rect2i(0, 0, 1, size.y), line)
	image.generate_mipmaps()
	return image
