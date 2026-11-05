class_name TFMaterialCache
extends RefCounted
## Turns image files into StandardMaterial3D resources stored in a cache
## folder that mirrors the image paths. Files are only written when missing,
## so opening the editor never produces VCS diffs.

const IMAGE_EXTENSIONS: PackedStringArray = ["png", "jpg", "jpeg", "webp", "tga", "bmp", "svg", "exr", "hdr"]
const PLACEHOLDER_SIZE: int = 128


static func is_image_path(path: String) -> bool:
	return IMAGE_EXTENSIONS.has(path.get_extension().to_lower())


## Cache file for an image, e.g. res://textures/a/brick.png ->
## <cache_dir>/textures/a/brick.png.tres (keeps brick.png and brick.jpg apart).
static func cache_path(image_path: String, cache_dir: String) -> String:
	return cache_dir.path_join(image_path.trim_prefix("res://") + ".tres")


## Returns the cached material for an image, creating and saving it first if
## needed. Returns null if the image cannot be loaded as a texture.
static func material_for_image(image_path: String, cache_dir: String = TFConst.get_material_cache_dir(), filter: TFConst.TextureFilter = TFConst.get_texture_filter()) -> Material:
	var path := cache_path(image_path, cache_dir)
	if ResourceLoader.exists(path):
		var existing := ResourceLoader.load(path) as Material
		if existing != null:
			return existing
	var texture := ResourceLoader.load(image_path) as Texture2D
	if texture == null:
		return null
	var material := create_material(texture, filter)
	material.resource_name = image_path.get_file().get_basename()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := ResourceSaver.save(material, path)
	if error != OK:
		push_warning("TrenchForge: could not write material cache %s (error %d)" % [path, error])
		return material
	# Scenes must reference the file instead of embedding the material.
	material.take_over_path(path)
	return material


static func create_material(texture: Texture2D, filter: TFConst.TextureFilter) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	material.roughness = 1.0
	if filter == TFConst.TextureFilter.NEAREST:
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	else:
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return material


## Blockout placeholder: checker tiles, a border and an "F" in the top-left
## corner that reveals rotation and mirroring at a glance.
static func create_placeholder_image(color: Color, size: int = PLACEHOLDER_SIZE) -> Image:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var half := size / 2
	image.fill(color)
	var checker := color.darkened(0.12)
	image.fill_rect(Rect2i(half, 0, half, half), checker)
	image.fill_rect(Rect2i(0, half, half, half), checker)
	var line := color.darkened(0.35)
	var border := maxi(size / 64, 1)
	image.fill_rect(Rect2i(0, 0, size, border), line)
	image.fill_rect(Rect2i(0, 0, border, size), line)
	image.fill_rect(Rect2i(0, size - border, size, border), line)
	image.fill_rect(Rect2i(size - border, 0, border, size), line)
	var glyph := color.lightened(0.45)
	var unit := maxi(size / 32, 1)
	var origin := Vector2i(unit * 4, unit * 4)
	image.fill_rect(Rect2i(origin, Vector2i(unit * 2, unit * 8)), glyph)
	image.fill_rect(Rect2i(origin, Vector2i(unit * 6, unit * 2)), glyph)
	image.fill_rect(Rect2i(origin + Vector2i(0, unit * 3), Vector2i(unit * 4, unit * 2)), glyph)
	return image
