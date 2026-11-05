@tool
class_name TFShortcuts
extends RefCounted
## Central registry of all TrenchForge keyboard shortcuts.
##
## Every shortcut is a Shortcut resource in the editor settings
## (trenchforge/shortcuts/<action>) and can be rebound there. Tools never
## compare keycodes themselves; they ask matches(action, event).
##
## Key specs in ACTIONS: "Ctrl+Shift+S"; Ctrl means Cmd on macOS. A leading
## "~" also matches the physical key position (macOS Option changes the
## produced character, German layouts need Alt for brackets).

const SETTING_PREFIX := "trenchforge/shortcuts/"

## Labels are English and translated by label().
## Contexts: "global" is handled by the plugin before the active tool; tool
## contexts only while that tool is active; "uv_editor" while the UV editor
## tab has focus; modal contexts (MODAL_CONTEXTS) only while that operation
## runs, which then gets every key first.
## [action, context, label, key specs...]
const ACTIONS := [
	["tool_box", "global", "Box tool", "B"],
	["tool_shape", "global", "Shape tool / next shape (cylinder, polygon, stairs, pipe, wall)", "Shift+B"],
	["tool_clip", "global", "Clip tool", "C"],
	["tool_cube_cut", "global", "Cube-Cut tool", "Shift+C"],
	["tool_vertex", "global", "Vertex mode", "V"],
	["tool_edge", "global", "Edge mode", "Shift+V"],
	["tool_vertex_face", "global", "Face move mode", "Ctrl+Shift+V"],
	["face_mode", "global", "Toggle face mode", "Tab"],
	["face_snap", "global", "Face Snap", "T"],
	["face_inspector", "global", "Focus face inspector", "Shift+T"],
	["uv_editor_focus", "global", "Focus UV editor", "Shift+U"],
	["grid_smaller", "global", "Halve grid", "~BracketLeft"],
	["grid_larger", "global", "Double grid", "~BracketRight"],
	["grid_toggle", "global", "Grid overlay on/off", "~Alt+G"],
	["texture_lock", "global", "Texture lock on/off", "~Alt+L"],
	["build", "global", "Build map", "Ctrl+B"],
	["csg_subtract", "global", "Subtract", "Ctrl+Shift+S"],
	["csg_hollow", "global", "Hollow", "Ctrl+Shift+H"],
	["csg_merge", "global", "Merge", "Ctrl+J"],
	["bridge", "global", "Bridge two faces (face mode) / edge loops (edge mode)", "Ctrl+Shift+E"],
	["hide", "global", "Hide selection", "H"],
	["unhide_all", "global", "Show all", "~Alt+H"],
	["isolate", "global", "Isolate selection", "Shift+H"],
	["group", "global", "Group", "Ctrl+G"],
	["ungroup", "global", "Ungroup / dissolve compound", "Ctrl+Shift+G"],
	["make_compound", "global", "Make compound"],
	["dissolve_compound", "global", "Dissolve compound"],
	["select_same_material", "global", "Select same material", "Ctrl+Shift+M"],
	["select_touching", "global", "Select touching", "Ctrl+Shift+T"],
	["select_inside", "global", "Select inside", "Ctrl+Shift+I"],
	["bake_mesh", "global", "Bake to Mesh (replace brushes)"],
	["bake_mesh_keep", "global", "Bake to Mesh (keep brushes)"],
	["open_settings", "global", "Open TrenchForge settings"],
	["cancel", "tool", "Cancel / back to Select", "Escape"],
	["nudge_forward", "tool", "Nudge forward", "Up"],
	["nudge_back", "tool", "Nudge back", "Down"],
	["nudge_left", "tool", "Nudge left", "Left"],
	["nudge_right", "tool", "Nudge right", "Right"],
	["nudge_up", "tool", "Nudge up", "PageUp"],
	["nudge_down", "tool", "Nudge down", "PageDown"],
	["extrude", "select", "Extrude face (new brush) / push in", "E"],
	["inset", "select", "Inset face (rim + core)", "I"],
	["duplicate", "select", "Duplicate", "Ctrl+D"],
	["delete", "select", "Delete", "Delete", "Backspace"],
	["rotate_cw", "select", "Rotate 90°", "Ctrl+R"],
	["rotate_ccw", "select", "Rotate −90°", "Ctrl+Shift+R"],
	["bevel", "select", "Bevel edges (Select) / edges or vertices (Vertex tool)", "Ctrl+Shift+B"],
	["select_loop", "vertex", "Select edge loop under the cursor (edge mode; also double-click)", "L"],
	["bevel_confirm", "bevel", "Bevel: confirm", "Enter", "Kp Enter"],
	["bevel_more", "bevel", "Bevel: more segments (also mouse wheel)", "Plus", "Kp Add", "Equal"],
	["bevel_less", "bevel", "Bevel: fewer segments (also mouse wheel)", "Minus", "Kp Subtract"],
	["bevel_profile", "bevel", "Bevel: mouse changes profile / width", "P"],
	["bevel_clamp", "bevel", "Bevel: clamp overlap on/off", "C"],
	["bevel_corners", "bevel", "Bevel: round or cut corners", "K"],
	["clip_confirm", "clip", "Confirm clip", "Enter", "Kp Enter"],
	["clip_remove_point", "clip", "Remove last clip point", "Backspace"],
	["clip_mode_prev", "clip", "Previous clip mode", "Q"],
	["clip_mode_next", "clip", "Next clip mode", "E"],
	["shape_confirm", "shape", "Close polygon / finish pipe or wall", "Enter", "Kp Enter"],
	["shape_remove_point", "shape", "Remove last polygon / pipe / wall point", "Backspace"],
	["shape_more", "shape", "More segments / steps / wall height", "W"],
	["shape_less", "shape", "Fewer segments / steps / wall height", "S"],
	["shape_rotate_ccw", "shape", "Stairs direction counterclockwise", "Q"],
	["shape_rotate_cw", "shape", "Stairs direction clockwise", "E"],
	["shape_radius_more", "shape", "Pipe: larger radius / wall: thicker", "Shift+W"],
	["shape_radius_less", "shape", "Pipe: smaller radius / wall: thinner", "Shift+S"],
	["shape_bend_more", "shape", "Pipe: more bend segments", "Shift+E"],
	["shape_bend_less", "shape", "Pipe: fewer bend segments (0: mitred)", "Shift+Q"],
	["shape_reset", "shape", "Reset shape options (16 segments, auto steps, pipe and wall defaults)", "R"],
	["snap_up", "face_snap", "Face Snap: top edge", "W"],
	["snap_left", "face_snap", "Face Snap: left edge", "A"],
	["snap_down", "face_snap", "Face Snap: bottom edge", "S"],
	["snap_right", "face_snap", "Face Snap: right edge", "D"],
	["snap_fit_v", "face_snap", "Face Snap: fit vertically", "Q"],
	["snap_fit_u", "face_snap", "Face Snap: fit horizontally", "E"],
	["snap_reset", "face_snap", "Face Snap: reset scale", "R"],
	["uv_flip_h", "uv_editor", "UV editor: flip horizontally", "F"],
	["uv_flip_v", "uv_editor", "UV editor: flip vertically", "Shift+F"],
	["uv_rotate_ccw", "uv_editor", "UV editor: rotate 90° counterclockwise", "Q"],
	["uv_rotate_cw", "uv_editor", "UV editor: rotate 90° clockwise", "E"],
	["uv_reset", "uv_editor", "UV editor: reset to face plane", "R"],
	["uv_fit_view", "uv_editor", "UV editor: fit view", "Home"],
]

## Contexts of modal operations: they get every key while they run, so
## their keys only clash with each other.
const MODAL_CONTEXTS: Array[String] = ["bevel"]

## Nudge actions and their direction keys for TFTool.nudge_direction().
const NUDGE_ACTIONS := {
	"nudge_forward": KEY_UP, "nudge_back": KEY_DOWN,
	"nudge_left": KEY_LEFT, "nudge_right": KEY_RIGHT,
	"nudge_up": KEY_PAGEUP, "nudge_down": KEY_PAGEDOWN,
}

## Godot shortcuts of the 3D editor that TrenchForge overrides while the
## viewport has focus and a map is edited (documented in the README);
## translated where shown.
const GODOT_CONFLICTS := {
	"group": "Godot: Group selected nodes (Ctrl+G)",
	"ungroup": "Godot: Ungroup selected nodes (Ctrl+Shift+G)",
	"csg_subtract": "Godot: Save Scene As (Ctrl+Shift+S)",
	"duplicate": "Godot: Duplicate (Ctrl+D, scene tree)",
	"delete": "Godot: Delete (Del, scene tree)",
	"extrude": "Godot: Rotate mode (E), only over a face",
}

static var _cache := {}  # action -> Shortcut
static var _settings: EditorSettings


## Adds missing settings with their defaults and loads all shortcuts.
static func register(settings: EditorSettings) -> void:
	_settings = settings
	for entry in ACTIONS:
		var setting: String = SETTING_PREFIX + entry[0]
		if not settings.has_setting(setting) or not settings.get_setting(setting) is Shortcut:
			settings.set_setting(setting, make_shortcut(entry.slice(3)))
		settings.set_initial_value(setting, make_shortcut(entry.slice(3)), false)
		settings.add_property_info({
			"name": setting,
			"type": TYPE_OBJECT,
			"hint": PROPERTY_HINT_RESOURCE_TYPE,
			"hint_string": "Shortcut",
		})
	load_shortcuts()


## Re-reads the shortcuts from the editor settings (after a change there).
## Not named reload(): called on the class, that would hit Script.reload()
## and recompile the script instead.
static func load_shortcuts() -> void:
	_cache.clear()
	_ensure_settings()
	if _settings == null:
		return
	for entry in ACTIONS:
		var value: Variant = _settings.get_setting(SETTING_PREFIX + entry[0])
		if value is Shortcut:
			_cache[entry[0]] = value


static func get_shortcut(action: String) -> Shortcut:
	if _settings == null and _ensure_settings():
		load_shortcuts()
	if not _cache.has(action):
		var entry := _entry(action)
		_cache[action] = make_shortcut(entry.slice(3)) if not entry.is_empty() else Shortcut.new()
	return _cache[action]


## True if the key event triggers the action (exact modifiers; Ctrl and Cmd
## are equivalent).
static func matches(action: String, event: InputEvent) -> bool:
	if not event is InputEventKey:
		return false
	for shortcut_event in get_shortcut(action).events:
		if shortcut_event is InputEventKey and event_matches(shortcut_event, event):
			return true
	return false


## The first matching action of the given context, or "".
static func find_action(context: String, event: InputEvent) -> String:
	for entry in ACTIONS:
		if entry[1] == context and matches(entry[0], event):
			return entry[0]
	return ""


static func event_matches(shortcut_event: InputEventKey, event: InputEventKey) -> bool:
	if _has_ctrl(shortcut_event) != _has_ctrl(event):
		return false
	if shortcut_event.shift_pressed != event.shift_pressed or shortcut_event.alt_pressed != event.alt_pressed:
		return false
	if shortcut_event.keycode != KEY_NONE and event.keycode == shortcut_event.keycode:
		return true
	if shortcut_event.physical_keycode != KEY_NONE and event.physical_keycode == shortcut_event.physical_keycode:
		return true
	return shortcut_event.key_label != KEY_NONE and event.key_label == shortcut_event.key_label


## Human-readable keys of the action, e.g. "Ctrl+D" (Cmd on macOS).
static func text(action: String) -> String:
	var parts: PackedStringArray = []
	for shortcut_event in get_shortcut(action).events:
		if shortcut_event is InputEventKey:
			parts.append(event_text(shortcut_event))
	return " / ".join(parts) if not parts.is_empty() else "—"


static func event_text(event: InputEventKey) -> String:
	var parts: PackedStringArray = []
	if _has_ctrl(event):
		parts.append("Cmd" if OS.get_name() == "macOS" else "Ctrl")
	if event.shift_pressed:
		parts.append("Shift")
	if event.alt_pressed:
		parts.append("Option" if OS.get_name() == "macOS" else "Alt")
	var key := event.keycode
	if key == KEY_NONE:
		key = event.physical_keycode if event.physical_keycode != KEY_NONE else event.key_label
	parts.append(_key_name(key))
	return "+".join(parts)


## Translated label of the action.
static func label(action: String) -> String:
	var entry := _entry(action)
	return TFI18n.t(entry[2]) if not entry.is_empty() else action


static func make_shortcut(specs: Array) -> Shortcut:
	var shortcut := Shortcut.new()
	var events: Array = []
	for spec in specs:
		var event := parse(spec)
		if event != null:
			events.append(event)
	shortcut.events = events
	return shortcut


## Parses "Ctrl+Shift+S" (see class docs). Returns null for unknown keys.
static func parse(spec: String) -> InputEventKey:
	var physical := spec.begins_with("~")
	var parts := spec.trim_prefix("~").split("+")
	var event := InputEventKey.new()
	for i in parts.size() - 1:
		match parts[i]:
			"Ctrl":
				event.command_or_control_autoremap = true
			"Shift":
				event.shift_pressed = true
			"Alt":
				event.alt_pressed = true
	var keycode := OS.find_keycode_from_string(parts[-1])
	if keycode == KEY_NONE:
		return null
	event.keycode = keycode
	if physical:
		event.physical_keycode = keycode
	return event


## Pairs of actions sharing a key in contexts that are active together
## (global with everything, tool-wide with every tool, otherwise the same
## context). Returns Array of [action_a, action_b, key text].
static func find_conflicts() -> Array:
	var result: Array = []
	for i in ACTIONS.size():
		for j in range(i + 1, ACTIONS.size()):
			if not _contexts_overlap(ACTIONS[i][1], ACTIONS[j][1]):
				continue
			for a in get_shortcut(ACTIONS[i][0]).events:
				for b in get_shortcut(ACTIONS[j][0]).events:
					if a is InputEventKey and b is InputEventKey and (event_matches(a, _as_pressed(b)) or event_matches(b, _as_pressed(a))):
						result.append([ACTIONS[i][0], ACTIONS[j][0], event_text(a)])
	return result


# Static state is lost when the script is reloaded in the editor; fetch the
# settings again then. Returns true if they became available.
static func _ensure_settings() -> bool:
	if _settings == null and Engine.is_editor_hint():
		_settings = EditorInterface.get_editor_settings()
		return _settings != null
	return false


static func _contexts_overlap(a: String, b: String) -> bool:
	if MODAL_CONTEXTS.has(a) or MODAL_CONTEXTS.has(b):
		return a == b
	return a == b or a == "global" or b == "global" or a == "tool" or b == "tool"


# A shortcut event as if it was typed: keycode and physical key coincide.
static func _as_pressed(event: InputEventKey) -> InputEventKey:
	var copy := event.duplicate() as InputEventKey
	if copy.keycode == KEY_NONE:
		copy.keycode = copy.physical_keycode
	if copy.physical_keycode == KEY_NONE:
		copy.physical_keycode = copy.keycode
	return copy


static func _has_ctrl(event: InputEventWithModifiers) -> bool:
	return event.ctrl_pressed or event.meta_pressed or event.command_or_control_autoremap


static func _key_name(key: Key) -> String:
	match key:
		KEY_BRACKETLEFT:
			return "["
		KEY_BRACKETRIGHT:
			return "]"
		KEY_DELETE:
			return TFI18n.t("Del")
		KEY_ESCAPE:
			return "Esc"
		KEY_PAGEUP:
			return "PgUp"
		KEY_PAGEDOWN:
			return "PgDn"
		KEY_UP:
			return "↑"
		KEY_DOWN:
			return "↓"
		KEY_LEFT:
			return "←"
		KEY_RIGHT:
			return "→"
	return OS.get_keycode_string(key)


static func _entry(action: String) -> Array:
	for entry in ACTIONS:
		if entry[0] == action:
			return entry
	return []
