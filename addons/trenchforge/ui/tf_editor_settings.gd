@tool
class_name TFEditorSettings
extends RefCounted
## Per-user TrenchForge preferences in the editor settings (Editor >
## Editor Settings > TrenchForge): UI language, overlay colors, overlay and
## viewport options, UV editor snap radius, last used bevel and bridge options.
## Project-wide settings (PPM, default grid, texture folders) live in the
## project settings (PROJECT), shortcuts in TFShortcuts. The settings dock
## (TFSettingsDock) edits all of them in place.

const PREFIX := "trenchforge/"
## UI language (a TFI18n.LANGUAGES code).
const LANGUAGE := "interface/language"

## [setting, TFEditorContext color variable, default, label]
const COLORS := [
	["colors/selection", "COLOR_SELECTED", Color(1.0, 0.35, 0.25, 1.0), "Selection"],
	["colors/hover", "COLOR_HOVER", Color(1.0, 0.85, 0.3, 0.9), "Hover"],
	["colors/face_selection", "COLOR_FACE_SELECTED", Color(1.0, 0.35, 0.25, 0.35), "Face selection"],
	["colors/face_hover", "COLOR_FACE_HOVER", Color(1.0, 0.85, 0.3, 0.2), "Face hover"],
	["colors/face_mode", "COLOR_FACE_MODE", Color(0.5, 0.45, 1.0, 1.0), "Face mode"],
	["colors/preview_and_handles", "COLOR_PREVIEW", Color(0.35, 0.8, 1.0, 1.0), "Preview & handles"],
	["colors/cursor", "COLOR_CURSOR", Color(0.35, 0.8, 1.0, 1.0), "Cursor"],
	["colors/group", "COLOR_GROUP", Color(0.55, 0.9, 0.45, 0.9), "Groups"],
	["colors/invalid_brush", "COLOR_INVALID", Color(1.0, 0.1, 0.6, 1.0), "Invalid brushes"],
	["colors/uv_grid", "COLOR_UV_GRID", Color(0.75, 0.75, 0.75, 0.7), "UV editor grid"],
	["colors/uv_outline", "COLOR_UV_OUTLINE", Color(1.0, 1.0, 1.0, 1.0), "UV editor face outline"],
]
## [setting, default, label]
const OPTIONS := [
	["overlay/show_status_line", true, "Status line"],
	["overlay/show_help_line", true, "Help line"],
	["overlay/show_dimensions", true, "Dimensions"],
	["overlay/show_cursor_position", true, "Cursor coordinates"],
	["overlay/highlight_invalid_brushes", true, "Highlight invalid brushes"],
	["viewport/show_collision", true, "Show collision"],
	["viewport/hide_transform_gizmo", true, "Hide Godot's transform gizmo"],
]
## Integer options: [setting, default, label, range hint "min,max,step"]
const NUMBERS := [
	["uv_editor/snap_radius", TFConst.DEFAULT_UV_SNAP_RADIUS, "UV editor snap radius (px)", "1,32,1"],
]
## Last used bevel options (the width always starts at 0):
## [setting, TFBevelOperation parameter, default, label, type, hint, hint string]
const BEVEL := [
	["bevel/segments", "segments", 1, "Segments", TYPE_INT, PROPERTY_HINT_RANGE, "1,%d,1" % TFConst.BEVEL_MAX_SEGMENTS],
	["bevel/profile", "profile", 0.5, "Profile (0.25 chamfer, 0.5 round)", TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.25,1,0.05"],
	["bevel/angle_limit", "angle", 30.0, "Angle limit in brush mode (°)", TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,180,1"],
	["bevel/clamp", "clamp", true, "Clamp overlap", TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["bevel/corners", "corners", 0, "Corners", TYPE_INT, PROPERTY_HINT_ENUM, "Patch,Cut"],
	["bevel/wrap_uv", "wrap_uv", true, "Wrap texture around the bevel", TYPE_BOOL, PROPERTY_HINT_NONE, ""],
]
## Options for new bridges (the shape panel changes a bridge afterwards):
## [setting, TFBridge parameter, default, label, type, hint, hint string]
const BRIDGE := [
	["bridge/cuts", "cuts", 0, "Cuts", TYPE_INT, PROPERTY_HINT_RANGE, "0,%d,1" % TFConst.BRIDGE_MAX_CUTS],
	["bridge/interpolation", "interpolation", 0, "Interpolation", TYPE_INT, PROPERTY_HINT_ENUM, "Linear,Blend path"],
	["bridge/smoothness", "smoothness", 1.0, "Smoothness", TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,10,0.05"],
	["bridge/profile_factor", "profile_factor", 0.0, "Profile factor", TYPE_FLOAT, PROPERTY_HINT_RANGE, "-1,10,0.05"],
	["bridge/profile_shape", "profile_shape", 0, "Profile shape", TYPE_INT, PROPERTY_HINT_ENUM, "Smooth,Sphere,Linear"],
]

static var show_status_line := true
static var show_help_line := true
static var show_dimensions := true
static var show_cursor_position := true
static var highlight_invalid_brushes := true
static var hide_transform_gizmo := true
static var uv_snap_radius := TFConst.DEFAULT_UV_SNAP_RADIUS
## Last used bevel options by TFBevelOperation parameter name (see BEVEL).
static var bevel := {}
## Options for new bridges by TFBridge parameter name (see BRIDGE).
static var bridge := {}

static var _settings: EditorSettings


## Project settings: [setting, default, type, hint, hint string, label].
static func project_settings() -> Array:
	return [
		[TFConst.SETTING_PIXELS_PER_METER, TFConst.DEFAULT_PIXELS_PER_METER, TYPE_INT, PROPERTY_HINT_RANGE, "1,4096,1", "Pixels per meter"],
		[TFConst.SETTING_DEFAULT_GRID_SIZE, TFConst.DEFAULT_GRID_SIZE, TYPE_FLOAT, PROPERTY_HINT_RANGE, "%s,%s,0.0625" % [TFSnap.MIN_GRID, TFSnap.MAX_GRID], "Default grid of new maps (m)"],
		[TFConst.SETTING_TEXTURE_ROOTS, TFConst.DEFAULT_TEXTURE_ROOTS, TYPE_PACKED_STRING_ARRAY, PROPERTY_HINT_TYPE_STRING, "%d/%d:" % [TYPE_STRING, PROPERTY_HINT_DIR], "Texture roots"],
		[TFConst.SETTING_TEXTURE_FILTER, TFConst.TextureFilter.LINEAR, TYPE_INT, PROPERTY_HINT_ENUM, "Linear,Nearest", "Texture filter"],
		[TFConst.SETTING_MATERIAL_CACHE_DIR, TFConst.DEFAULT_MATERIAL_CACHE_DIR, TYPE_STRING, PROPERTY_HINT_DIR, "", "Material cache folder"],
		[TFConst.SETTING_SHADER_TEXTURE_PARAM, TFConst.DEFAULT_SHADER_TEXTURE_PARAM, TYPE_STRING, PROPERTY_HINT_NONE, "", "Shader texture parameter"],
	]


## Adds missing project settings with their defaults.
static func register_project() -> void:
	for entry in project_settings():
		var setting: String = entry[0]
		if not ProjectSettings.has_setting(setting):
			ProjectSettings.set_setting(setting, entry[1])
		ProjectSettings.set_initial_value(setting, entry[1])
		ProjectSettings.add_property_info({
			"name": setting,
			"type": entry[2],
			"hint": entry[3],
			"hint_string": entry[4],
		})
		ProjectSettings.set_as_basic(setting, true)


static func register(settings: EditorSettings) -> void:
	_settings = settings
	if not settings.has_setting(PREFIX + LANGUAGE) or not TFI18n.LANGUAGES.has(settings.get_setting(PREFIX + LANGUAGE)):
		settings.set_setting(PREFIX + LANGUAGE, TFI18n.DEFAULT_LANGUAGE)
	settings.set_initial_value(PREFIX + LANGUAGE, TFI18n.DEFAULT_LANGUAGE, false)
	settings.add_property_info({
		"name": PREFIX + LANGUAGE,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": ",".join(TFI18n.LANGUAGES.keys()),
	})
	for entry in COLORS:
		_add(PREFIX + entry[0], entry[2], TYPE_COLOR)
	for entry in OPTIONS:
		_add(PREFIX + entry[0], entry[1], TYPE_BOOL)
	for entry in NUMBERS:
		_add(PREFIX + entry[0], entry[1], TYPE_INT, PROPERTY_HINT_RANGE, entry[3])
	for entry in BEVEL + BRIDGE:
		_add(PREFIX + entry[0], entry[2], entry[4], entry[5], entry[6])
	load_settings()


## Loads the settings once more if the script was reloaded (static state
## lost); cheap to call before every draw.
static func ensure_loaded() -> void:
	if _settings == null and Engine.is_editor_hint():
		_settings = EditorInterface.get_editor_settings()
		load_settings()


## Applies the current editor settings (after a change there). Not named
## reload(): called on the class, that would hit Script.reload() and
## recompile the script (resetting all static state) instead.
static func load_settings() -> void:
	# Static state is lost when the editor reloads this script.
	if _settings == null and Engine.is_editor_hint():
		_settings = EditorInterface.get_editor_settings()
	if _settings == null:
		return
	TFI18n.set_language(String(_settings.get_setting(PREFIX + LANGUAGE)))
	for entry in COLORS:
		TFEditorContext.set_color(entry[1], _settings.get_setting(PREFIX + entry[0]))
	show_status_line = _settings.get_setting(PREFIX + "overlay/show_status_line")
	show_help_line = _settings.get_setting(PREFIX + "overlay/show_help_line")
	show_dimensions = _settings.get_setting(PREFIX + "overlay/show_dimensions")
	show_cursor_position = _settings.get_setting(PREFIX + "overlay/show_cursor_position")
	highlight_invalid_brushes = _settings.get_setting(PREFIX + "overlay/highlight_invalid_brushes")
	hide_transform_gizmo = _settings.get_setting(PREFIX + "viewport/hide_transform_gizmo")
	uv_snap_radius = _settings.get_setting(PREFIX + "uv_editor/snap_radius")
	for entry in BEVEL:
		bevel[entry[1]] = _settings.get_setting(PREFIX + entry[0])
	for entry in BRIDGE:
		bridge[entry[1]] = _settings.get_setting(PREFIX + entry[0])
	TFMap.set_collision_shown_in_editor(_settings.get_setting(PREFIX + "viewport/show_collision"))


## Remembers the bevel options of params (TFBevelOperation parameters).
static func store_bevel(params: Dictionary) -> void:
	_store(BEVEL, bevel, params)


## Bevel options for a new bevel: the remembered ones (defaults without
## editor settings, e.g. headless).
static func bevel_defaults() -> Dictionary:
	return _defaults(BEVEL, bevel)


## Remembers the bridge options of params (TFBridge parameters).
static func store_bridge(params: Dictionary) -> void:
	_store(BRIDGE, bridge, params)


## Options for a new bridge (see bevel_defaults()).
static func bridge_defaults() -> Dictionary:
	return _defaults(BRIDGE, bridge)


static func _store(table: Array, cache: Dictionary, params: Dictionary) -> void:
	ensure_loaded()
	for entry in table:
		if not params.has(entry[1]):
			continue
		var value: Variant = params[entry[1]]
		value = int(value) if entry[4] == TYPE_INT else (float(value) if entry[4] == TYPE_FLOAT else bool(value))
		cache[entry[1]] = value
		if _settings != null and _settings.get_setting(PREFIX + entry[0]) != value:
			_settings.set_setting(PREFIX + entry[0], value)


static func _defaults(table: Array, cache: Dictionary) -> Dictionary:
	ensure_loaded()
	var result := {}
	for entry in table:
		result[entry[1]] = cache.get(entry[1], entry[2])
	return result


static func _add(setting: String, default_value: Variant, type: int, hint := PROPERTY_HINT_NONE, hint_string := "") -> void:
	if not _settings.has_setting(setting) or typeof(_settings.get_setting(setting)) != type:
		_settings.set_setting(setting, default_value)
	_settings.set_initial_value(setting, default_value, false)
	_settings.add_property_info({"name": setting, "type": type, "hint": hint, "hint_string": hint_string})
