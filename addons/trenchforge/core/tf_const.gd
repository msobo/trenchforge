class_name TFConst
extends RefCounted
## Central constants for TrenchForge. All geometry tolerances live here.

## General geometric tolerance (meters) for point/vertex comparisons.
const EPSILON: float = 1e-4
## Tolerance for point-vs-plane classification.
const PLANE_EPSILON: float = 1e-4
## Tolerance for comparing plane normals (dot product distance from 1.0).
const NORMAL_EPSILON: float = 1e-5
## Minimum volume (m³) for a brush to count as valid.
const MIN_VOLUME: float = 1e-6
## Hull input coordinates within EPSILON of a multiple of this step are
## rounded onto it, so repeated vertex edits do not accumulate float drift.
const VERTEX_CLEAN_STEP: float = 1.0 / 1024.0
## Hull faces whose normals differ less than this (1 - dot) and whose
## distances differ less than COPLANAR_DISTANCE are merged into one: such
## slivers come from float noise and make the plane topology unstable.
const COPLANAR_NORMAL_EPSILON: float = 1e-6
const COPLANAR_DISTANCE: float = 1e-3
## Relative volume tolerance when checking whether a convex hull adds
## volume (merge warning, fragment re-merge after subtract).
const MERGE_VOLUME_EPSILON: float = 1e-5
## Subtract drops fragments thinner than this fraction of the grid size.
const MIN_FRAGMENT_GRID_FRACTION: float = 1.0 / 16.0
## Up to this many subtract fragments, the re-merge searches every grouping
## for the fewest brushes; beyond it, pairs are merged greedily.
const REMERGE_EXACT_LIMIT: int = 10
## Subtract tries further cut orders only if the first one drops volume or
## leaves more fragments than this.
const SUBTRACT_CLEAN_FRAGMENTS: int = 4
## ... and only if at most this many cutter planes cut the target.
const SUBTRACT_ORDER_PLANE_LIMIT: int = 8
## From this many planes on, polyhedra are built by clipping a start box
## plane by plane (about O(n · V)) instead of intersecting all plane triples
## (O(n⁴)); small brushes keep the exact old construction.
const POLY_INCREMENTAL_THRESHOLD: int = 24
## Half edge length (m) of the start box of the incremental construction:
## POLY_START_MARGIN times the largest plane distance from the origin (plus
## 1 m), at most POLY_START_EXTENT (used again if the result reaches the
## smaller box). Small boxes keep float precision.
const POLY_START_MARGIN: float = 8.0
const POLY_START_EXTENT: float = 65536.0
## Bevel: most segments per edge, most planes per brush (segments are
## reduced to stay below), shortest segment chord (m) and smallest angle
## (degrees) between neighboring segment planes. Shorter chords or flatter
## steps reduce the segment count, so no almost coplanar planes arise.
const BEVEL_MAX_SEGMENTS: int = 32
const BEVEL_MAX_PLANES: int = 384
const BEVEL_MIN_SEGMENT: float = 4e-3
const BEVEL_MIN_ANGLE: float = 1.0
## Clamped bevels keep this much (m) of every face, at most 10 % of it.
const BEVEL_CLAMP_MARGIN: float = 0.01
## Bevel profile range (0.25 = straight chamfer, 0.5 = circle, 1 = square).
const BEVEL_MIN_PROFILE: float = 0.25
const BEVEL_MAX_PROFILE: float = 0.98
## Corner patches whose least-squares center misses an edge's arc center by
## more than this fraction of the radius fall back to cut corners.
const BEVEL_CORNER_TOLERANCE: float = 0.1
## Bridge: most cuts (pieces − 1) and loop points, smallest ring scale of the
## profile, and the least thickness (m) of a piece between its two rings.
const BRIDGE_MAX_CUTS: int = 64
const BRIDGE_MAX_POINTS: int = 64
const BRIDGE_MIN_SCALE: float = 0.05
const BRIDGE_MIN_THICKNESS: float = 1e-3
## Minimum |uv_scale| component; smaller values are treated as this.
const MIN_UV_SCALE: float = 1e-4
## UV editor: smallest scale factor of one drag step (keeps the sign).
const MIN_UV_SCALE_FACTOR: float = 1e-3
## UV editor: shear amounts below this snap to "no shear", above
## MAX_UV_SHEAR they are clamped (one axis tilted by at most ~76°).
const MIN_UV_SHEAR: float = 1e-3
const MAX_UV_SHEAR: float = 4.0
## UV editor: default snap radius (screen pixels) and the angle (degrees)
## within which a rotation snaps onto a face edge.
const DEFAULT_UV_SNAP_RADIUS: int = 8
const UV_ANGLE_SNAP: float = 4.0

const DEFAULT_GRID_SIZE: float = 1.0
const DEFAULT_PIXELS_PER_METER: int = 128
const DEFAULT_TEXTURE_SIZE: Vector2i = Vector2i(128, 128)
## Positions closer than this are welded into one vertex in build output.
const WELD_EPSILON: float = 1e-4
## Seconds after the last change before an automatic map rebuild.
const BUILD_DEBOUNCE: float = 0.3
const DEFAULT_LIGHTMAP_TEXEL_SIZE: float = 0.2
## Validate Map snaps vertices closer to the grid than this grid fraction.
const VALIDATE_SNAP_GRID_FRACTION: float = 1.0 / 16.0
## Edge length (m) of the cells of TFSpatialIndex.
const SPATIAL_CELL_SIZE: float = 8.0
## Brushes covering more cells than this are kept in one overflow list.
const SPATIAL_MAX_CELLS: int = 512

## Name of the saved build output below a TFMap.
const BUILD_NODE_NAME: String = "_Build"
## Group on build output nodes so game code can find the level geometry.
const GROUP_WORLD: StringName = &"tf_world"
const META_BUILD_HASH: String = "tf_build_hash"
## Editor-only hidden flag on brushes (saved, ignored by the build).
const META_HIDDEN: StringName = &"_tf_hidden"
## Engine metadata: collision output visible in the editor viewport.
const META_SHOW_COLLISION: StringName = &"tf_show_collision"
## Default name of new group nodes.
const GROUP_NODE_NAME: String = "Group"
## Groups with this metadata are compounds (Verbünde): shapes split into
## convex brushes that behave like one object (outline, logical faces).
const META_COMPOUND: StringName = &"_tf_compound"
## Default name of new compound nodes.
const COMPOUND_NODE_NAME: String = "Compound"
## Brushes of a compound with this metadata keep their faces as logical
## faces of their own (inset core: the inner rectangle stays visible).
const META_OWN_FACES: StringName = &"_tf_own_faces"
## Builder parameters of a cylinder brush, stairs group or pipe compound,
## editable after creation (saved; see TFShapeParams).
const META_SHAPE: StringName = &"tf_shape"

const MATERIAL_DEFAULT_PATH: String = "res://addons/trenchforge/materials/tf_default.tres"
const MATERIAL_NODRAW_PATH: String = "res://addons/trenchforge/materials/tf_nodraw.tres"
const MATERIAL_CLIP_PATH: String = "res://addons/trenchforge/materials/tf_clip.tres"

enum TextureFilter { LINEAR, NEAREST }

const SETTING_PIXELS_PER_METER: String = "trenchforge/pixels_per_meter"
const SETTING_TEXTURE_ROOTS: String = "trenchforge/texture_roots"
const SETTING_TEXTURE_FILTER: String = "trenchforge/default_texture_filter"
const SETTING_MATERIAL_CACHE_DIR: String = "trenchforge/material_cache_dir"
const SETTING_SHADER_TEXTURE_PARAM: String = "trenchforge/shader_texture_parameter"
const SETTING_DEFAULT_GRID_SIZE: String = "trenchforge/default_grid_size"

const DEFAULT_TEXTURE_ROOTS: PackedStringArray = ["res://textures"]
const DEFAULT_MATERIAL_CACHE_DIR: String = "res://trenchforge_materials"
const DEFAULT_SHADER_TEXTURE_PARAM: String = "albedo_texture"


## Project-wide pixels-per-meter, falling back to the default when unset.
static func get_project_ppm() -> int:
	return int(ProjectSettings.get_setting(SETTING_PIXELS_PER_METER, DEFAULT_PIXELS_PER_METER))


## Grid size of maps that do not set their own (project setting).
static func get_default_grid_size() -> float:
	return float(ProjectSettings.get_setting(SETTING_DEFAULT_GRID_SIZE, DEFAULT_GRID_SIZE))


static func get_texture_roots() -> PackedStringArray:
	return PackedStringArray(ProjectSettings.get_setting(SETTING_TEXTURE_ROOTS, DEFAULT_TEXTURE_ROOTS))


static func get_texture_filter() -> TextureFilter:
	return int(ProjectSettings.get_setting(SETTING_TEXTURE_FILTER, TextureFilter.LINEAR)) as TextureFilter


static func get_material_cache_dir() -> String:
	return String(ProjectSettings.get_setting(SETTING_MATERIAL_CACHE_DIR, DEFAULT_MATERIAL_CACHE_DIR))


static func get_shader_texture_param() -> StringName:
	return StringName(ProjectSettings.get_setting(SETTING_SHADER_TEXTURE_PARAM, DEFAULT_SHADER_TEXTURE_PARAM))
