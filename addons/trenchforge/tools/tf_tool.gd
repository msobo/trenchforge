@tool
class_name TFTool
extends RefCounted
## Base class for viewport tools. Exactly one tool is active at a time.

## Pixels the mouse has to travel before a press counts as a drag.
const DRAG_THRESHOLD: float = 4.0

var ctx: TFEditorContext


func _init(p_ctx: TFEditorContext) -> void:
	ctx = p_ctx


func get_tool_name() -> String:
	return ""


func activate() -> void:
	pass


func deactivate() -> void:
	cancel()


## Aborts any operation in progress and restores the previous state.
func cancel() -> void:
	pass


## Clears the selection (a right click in the viewport).
func deselect() -> void:
	ctx.clear_selection()


## Returns true if the event was consumed.
func handle_input(_camera: Camera3D, _event: InputEvent) -> bool:
	return false


## True while a live-preview operation (drag) is in progress; automatic map
## rebuilds wait until it is committed or cancelled.
func is_busy() -> bool:
	return false


## True while a modal operation runs that gets every viewport event first
## (keys before the global shortcuts, RMB and the mouse wheel included).
func wants_all_input() -> bool:
	return false


## Rebuilds the tool's 3D overlay primitives (called after clear()).
func draw_3d(_overlay: TFOverlay3D) -> void:
	pass


## Where the grid overlay should be drawn: {point, normal} or {} to use the
## work plane under the cursor.
func get_grid_anchor() -> Dictionary:
	return {}


## Draws 2D overlay content (screen space, e.g. a selection rectangle).
func draw_2d(_overlay: Control) -> void:
	pass


## Short label drawn next to the mouse cursor (e.g. the size of a box
## being drawn); empty for none.
func get_cursor_label() -> String:
	return ""


## Short help line shown in the viewport status bar.
func get_hint() -> String:
	return ""


## Additional overlay text (e.g. dimensions) or "" for none.
func get_info() -> String:
	return ""


static func is_ctrl(event: InputEventWithModifiers) -> bool:
	return event.ctrl_pressed or event.meta_pressed


## Key text of a TFShortcuts action for hints, e.g. "Ctrl+D".
static func keys(action: String) -> String:
	return TFShortcuts.text(action)


## Nudge direction of the nudge shortcut the event triggers, else zero.
static func nudge_direction_for(camera: Camera3D, event: InputEventKey) -> Vector3:
	for action: String in TFShortcuts.NUDGE_ACTIONS:
		if TFShortcuts.matches(action, event):
			return nudge_direction(camera, TFShortcuts.NUDGE_ACTIONS[action])
	return Vector3.ZERO


## World direction for the nudge keys: arrows follow the camera's dominant
## horizontal axes, PgUp/PgDn move vertically. Zero for other keys.
static func nudge_direction(camera: Camera3D, keycode: Key) -> Vector3:
	match keycode:
		KEY_UP:
			return TFSnap.dominant_horizontal_axis(-camera.global_basis.z)
		KEY_DOWN:
			return -TFSnap.dominant_horizontal_axis(-camera.global_basis.z)
		KEY_RIGHT:
			return TFSnap.dominant_horizontal_axis(camera.global_basis.x)
		KEY_LEFT:
			return -TFSnap.dominant_horizontal_axis(camera.global_basis.x)
		KEY_PAGEUP:
			return Vector3.UP
		KEY_PAGEDOWN:
			return Vector3.DOWN
	return Vector3.ZERO


static func format_length(value: float) -> String:
	return ("%.3f" % value).rstrip("0").rstrip(".")


## Short feedback in the editor's toaster.
static func toast(text: String, severity: EditorToaster.Severity = EditorToaster.SEVERITY_INFO) -> void:
	EditorInterface.get_editor_toaster().push_toast("TrenchForge: " + text, severity)
