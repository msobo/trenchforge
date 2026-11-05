class_name TFMapBuilder
extends RefCounted
## Builds the saved runtime output of a TFMap from its brushes:
##
##   _Build (Node3D)
##     Mesh            MeshInstance3D, one surface per material
##                     (Mesh_x_y_z per chunk when chunking is enabled)
##     Collision       StaticBody3D with one ConvexPolygonShape3D per brush
##     Occluder        OccluderInstance3D (optional)
##
## Everything uses Godot standard nodes only and is owned by the scene, so the
## level runs without the addon. Output order follows the brush order in the
## tree; existing output nodes are updated in place and resources get fixed
## ids, which keeps saved scenes deterministic and VCS diffs small.


## Updates the build output of the map and returns its root.
static func build(map: TFMap) -> Node3D:
	var brushes := map.get_brushes()
	var fresh := Node3D.new()
	fresh.name = TFConst.BUILD_NODE_NAME
	fresh.set_meta(TFConst.META_BUILD_HASH, compute_hash(map))
	# Derived geometry: keep it from being picked and moved in the viewport.
	fresh.set_meta(&"_edit_lock_", true)
	for mesh_instance in build_meshes(map, brushes):
		fresh.add_child(mesh_instance)
	var body := build_collision(map, brushes)
	if body != null:
		fresh.add_child(body)
	if map.generate_occluder:
		var occluder := build_occluder(map, brushes)
		if occluder != null:
			fresh.add_child(occluder)

	var scene_owner: Node = map.owner if map.owner != null else map
	var root := map.get_build_root()
	if root == null or root.get_class() != fresh.get_class():
		if root != null:
			map.remove_child(root)
			root.queue_free()
		map.add_child(fresh)
		_set_owner_recursive(fresh, scene_owner)
		return fresh
	_sync_node(root, fresh, scene_owner)
	fresh.free()
	return root


## Render output: one MeshInstance3D per chunk (or one in total).
static func build_meshes(map: TFMap, brushes: Array[TFBrush]) -> Array[MeshInstance3D]:
	var hidden := find_hidden_faces(brushes) if map.hidden_face_removal else {}
	var ppm := float(map.get_ppm())
	# Chunk key (Vector3i, or null without chunking) -> {Material: surface}.
	var chunks := {}
	for brush in brushes:
		if not brush.has_render() or not brush.is_valid():
			continue
		var poly := brush.get_polyhedron()
		var offset := brush.get_map_offset()
		var key: Variant = null
		if map.chunk_size > 0.0:
			var center := poly.get_aabb().get_center() + offset
			key = Vector3i((center / map.chunk_size).floor())
		if not chunks.has(key):
			chunks[key] = {}
		_append_brush_faces(chunks[key], brush, hidden, ppm, offset)

	var keys := chunks.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return a < b)
	var result: Array[MeshInstance3D] = []
	for key in keys:
		var surfaces: Dictionary = chunks[key]
		if surfaces.is_empty():
			continue
		var mesh := _surfaces_to_mesh(map, surfaces)
		var instance := MeshInstance3D.new()
		instance.name = "Mesh" if key == null else "Mesh_%d_%d_%d" % [key.x, key.y, key.z]
		_set_stable_id(mesh, "TF%s" % instance.name.replace("-", "m"))
		instance.mesh = mesh
		instance.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		instance.add_to_group(TFConst.GROUP_WORLD, true)
		result.append(instance)
	return result


## Bakes brushes into a detached, freely editable MeshInstance3D (not owned,
## not part of the build): render faces as in the build (one surface per
## material, hidden faces among the given brushes removed), plus a
## "Collision" StaticBody3D with one convex shape per colliding brush. The
## origin is the bottom center of the brushes' bounds; the node position is
## in map space. Returns null if no brush is valid.
static func bake(map: TFMap, brushes: Array[TFBrush], with_collision: bool = true) -> MeshInstance3D:
	var valid: Array[TFBrush] = []
	var bounds := AABB()
	for brush in brushes:
		if not brush.is_valid():
			continue
		var box := brush.get_polyhedron().get_aabb()
		box.position += brush.get_map_offset()
		bounds = box if valid.is_empty() else bounds.merge(box)
		valid.append(brush)
	if valid.is_empty():
		return null
	var origin := Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)

	var hidden := find_hidden_faces(valid) if map.hidden_face_removal else {}
	var ppm := float(map.get_ppm())
	var surfaces := {}
	for brush in valid:
		if brush.has_render():
			_append_brush_faces(surfaces, brush, hidden, ppm, brush.get_map_offset() - origin)
	var instance := MeshInstance3D.new()
	instance.name = "BakedMesh"
	instance.position = origin
	instance.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	instance.add_to_group(TFConst.GROUP_WORLD, true)
	if not surfaces.is_empty():
		instance.mesh = _surfaces_to_mesh(map, surfaces)
	if with_collision:
		var body := build_collision(map, valid)
		if body != null:
			for collider: CollisionShape3D in body.get_children():
				collider.position -= origin
				# Fresh shapes: the build's fixed ids would clash with the
				# map's own collision shapes in the same scene.
				var shape := ConvexPolygonShape3D.new()
				shape.points = (collider.shape as ConvexPolygonShape3D).points
				collider.shape = shape
			instance.add_child(body)
	return instance


## Collision output: exact convex shapes, one per colliding brush.
static func build_collision(map: TFMap, brushes: Array[TFBrush]) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Collision"
	body.collision_layer = map.collision_layer
	body.collision_mask = map.collision_mask
	body.add_to_group(TFConst.GROUP_WORLD, true)
	for brush in brushes:
		if not brush.has_collision() or not brush.is_valid():
			continue
		var shape := ConvexPolygonShape3D.new()
		shape.points = brush.get_polyhedron().vertices
		var collider := CollisionShape3D.new()
		collider.name = brush.name
		collider.position = brush.get_map_offset()
		collider.shape = shape
		body.add_child(collider, true)
		_set_stable_id(shape, "TFShape_%s" % _id_safe(collider.name))
	if body.get_child_count() == 0:
		body.free()
		return null
	return body


## Occluder from all rendering brushes at least occluder_min_size thick.
static func build_occluder(map: TFMap, brushes: Array[TFBrush]) -> OccluderInstance3D:
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	for brush in brushes:
		if not brush.has_render() or not brush.is_valid():
			continue
		var poly := brush.get_polyhedron()
		var size := poly.get_aabb().size
		if minf(size.x, minf(size.y, size.z)) < map.occluder_min_size:
			continue
		var base := vertices.size()
		var offset := brush.get_map_offset()
		for v in poly.vertices:
			vertices.append(v + offset)
		for polygon in poly.face_polygons:
			for i in range(1, polygon.size() - 1):
				indices.append_array([base + polygon[0], base + polygon[i + 1], base + polygon[i]])
	if indices.is_empty():
		return null
	var occluder := ArrayOccluder3D.new()
	occluder.set_arrays(vertices, indices)
	_set_stable_id(occluder, "TFOccluder")
	var instance := OccluderInstance3D.new()
	instance.name = "Occluder"
	instance.occluder = occluder
	return instance


## Adds the render faces of a brush to surfaces ({Material: surface data}).
## UVs use the brush's map offset, vertices are translated by vertex_offset.
static func _append_brush_faces(surfaces: Dictionary, brush: TFBrush, hidden: Dictionary, ppm: float, vertex_offset: Vector3) -> void:
	var poly := brush.get_polyhedron()
	var offset := brush.get_map_offset()
	for i in brush.faces.size():
		var face := brush.faces[i]
		if not poly.is_face_used(i) or face.is_nodraw() or hidden.has(_face_key(brush, i)):
			continue
		if not surfaces.has(face.material):
			surfaces[face.material] = TFMeshBuilder.new_surface()
		TFMeshBuilder.append_face(surfaces[face.material], poly, i, face, offset, ppm, vertex_offset)


## One ArrayMesh from collected surfaces, welded and UV2-unwrapped as the
## map settings say.
static func _surfaces_to_mesh(map: TFMap, surfaces: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for material in surfaces:
		var data: Dictionary = surfaces[material]
		if map.weld_vertices:
			data = TFMeshBuilder.weld(data)
		TFMeshBuilder.add_surface(mesh, data, material)
	if map.generate_uv2:
		var error := mesh.lightmap_unwrap(Transform3D.IDENTITY, map.lightmap_texel_size)
		if error != OK:
			push_warning("TrenchForge: UV2 unwrap failed (error %d)" % error)
	return mesh


## Faces fully covered by an opposite coplanar face of another rendering
## brush (e.g. between two touching boxes). Returns a set of _face_key().
static func find_hidden_faces(brushes: Array[TFBrush]) -> Dictionary:
	# Quantized map-space plane -> Array of [brush, face_index, polygon, normal].
	var buckets := {}
	for brush in brushes:
		if not brush.has_render() or not brush.is_valid():
			continue
		var poly := brush.get_polyhedron()
		for i in brush.faces.size():
			if not poly.is_face_used(i):
				continue
			var plane := brush.get_face_map_plane(i)
			var key := _plane_key(plane.normal, plane.d)
			if not buckets.has(key):
				buckets[key] = []
			buckets[key].append([brush, i, brush.get_face_map_vertices(i), plane.normal])

	var hidden := {}
	for key in buckets:
		var opposite_key := _plane_key(-(key[0] as Vector3), -(key[1] as float))
		if not buckets.has(opposite_key):
			continue
		for entry in buckets[key]:
			for cover in buckets[opposite_key]:
				if cover[0] != entry[0] and _polygon_inside(entry[2], cover[2], cover[3]):
					hidden[_face_key(entry[0], entry[1])] = true
					break
	return hidden


## Hash of everything the build output depends on. Stored on the output
## root to tell whether a saved build is still current.
static func compute_hash(map: TFMap) -> String:
	var data := [
		map.get_ppm(), map.hidden_face_removal, map.weld_vertices, map.chunk_size,
		map.generate_uv2, map.lightmap_texel_size, map.generate_occluder,
		map.occluder_min_size, map.collision_layer, map.collision_mask,
	]
	# Adding zero turns -0.0 into 0.0: scene files store both as 0, so the
	# hash of a reloaded map would differ otherwise.
	for brush in map.get_brushes():
		data.append_array([String(brush.name), brush.mode, brush.get_map_offset() + Vector3.ZERO])
		for face in brush.faces:
			if face == null:
				data.append(null)
				continue
			data.append_array([Plane(face.plane.normal + Vector3.ZERO, face.plane.d + 0.0), _material_id(face.material),
				face.u_axis + Vector3.ZERO, face.v_axis + Vector3.ZERO, face.uv_offset + Vector2.ZERO,
				face.uv_scale + Vector2.ZERO, face.uv_rotation + 0.0, face.flags])
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(data))
	return context.finish().hex_encode()


## True if every point of polygon lies inside the convex cover polygon
## (CCW around cover_normal).
static func _polygon_inside(polygon: PackedVector3Array, cover: PackedVector3Array, cover_normal: Vector3) -> bool:
	for i in cover.size():
		var a := cover[i]
		var edge := cover[(i + 1) % cover.size()] - a
		for p in polygon:
			if edge.cross(p - a).dot(cover_normal) < -TFConst.EPSILON * edge.length():
				return false
	return true


static func _plane_key(normal: Vector3, d: float) -> Array:
	var step := TFConst.WELD_EPSILON * 10.0
	return [normal.snapped(Vector3.ONE * step), snappedf(d, step)]


static func _face_key(brush: TFBrush, face_index: int) -> String:
	return "%d:%d" % [brush.get_instance_id(), face_index]


## File-based materials are identified by path; embedded ones by instance.
static func _material_id(material: Material) -> String:
	if material == null:
		return ""
	if not material.resource_path.is_empty() and not material.resource_path.contains("::"):
		return material.resource_path
	return "id:%d" % material.get_instance_id()


## Fixed sub-resource ids instead of random ones keep VCS diffs of
## rebuilt scenes small.
static func _set_stable_id(resource: Resource, id: String) -> void:
	resource.set_scene_unique_id(id)


static func _id_safe(text: String) -> String:
	var result := ""
	for c in text:
		result += c if c.is_valid_ascii_identifier() or c.is_valid_int() else "_"
	return result


## Makes target match source (stored properties, groups, children by name
## and class) while keeping existing nodes, so their scene ids stay stable.
static func _sync_node(target: Node, source: Node, scene_owner: Node) -> void:
	for property in source.get_property_list():
		if property["usage"] & PROPERTY_USAGE_STORAGE and property["name"] != "owner" and property["name"] != "name":
			target.set(property["name"], source.get(property["name"]))
	for meta in target.get_meta_list():
		if not source.has_meta(meta):
			target.remove_meta(meta)
	for group in target.get_groups():
		if not source.is_in_group(group):
			target.remove_from_group(group)
	for group in source.get_groups():
		if not target.is_in_group(group):
			target.add_to_group(group, true)

	var sources := source.get_children()
	for child in target.get_children():
		var match := source.get_node_or_null(NodePath(String(child.name)))
		if match == null or match.get_class() != child.get_class():
			# Deferred: a rebuild may run inside viewport input handling.
			target.remove_child(child)
			child.queue_free()
	for i in sources.size():
		var source_child := sources[i]
		var existing := target.get_node_or_null(NodePath(String(source_child.name)))
		if existing != null:
			_sync_node(existing, source_child, scene_owner)
			target.move_child(existing, i)
		else:
			source.remove_child(source_child)
			target.add_child(source_child)
			target.move_child(source_child, i)
			_set_owner_recursive(source_child, scene_owner)


static func _set_owner_recursive(node: Node, scene_owner: Node) -> void:
	node.owner = scene_owner
	for child in node.get_children():
		_set_owner_recursive(child, scene_owner)
