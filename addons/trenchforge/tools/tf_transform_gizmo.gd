@tool
class_name TFTransformGizmo
extends RefCounted
## Hides Godot's transform gizmo (move/rotate/scale arrows) in the 3D
## viewports while TrenchForge edits brushes: it covers the vertex handles and
## grabs clicks meant for the tools. Godot has no scripting API for it, so the
## per-viewport menu item "View Transform Gizmo" is toggled; Godot's instant
## transform (G/R/S) keeps working.
##
## Godot saves that menu state with the scene's editor state, so a gizmo
## hidden while switching scenes or quitting comes back hidden. Project
## metadata therefore remembers the viewports TrenchForge manages, and
## set_hidden(false) shows the gizmo there again whenever it finds it off.
## Toggling the menu item by hand hands that viewport back to the user.

const GODOT_SHORTCUT := "spatial_editor/view_transform_gizmo"
const METADATA_SECTION := "trenchforge"
const METADATA_KEY := "transform_gizmo_viewports"

## Viewport index -> [PopupMenu, item index] of "View Transform Gizmo".
var _items := {}
## Viewports the user toggled by hand in this session (left alone).
var _user_owned := PackedInt32Array()
var _toggling := false


func _init() -> void:
	_connect()


## Shows the gizmo again and disconnects from the viewport menus.
func dispose() -> void:
	set_hidden(false)
	for viewport: int in _items:
		var popup: PopupMenu = _items[viewport][0]
		if is_instance_valid(popup) and popup.id_pressed.is_connected(_on_id_pressed):
			popup.id_pressed.disconnect(_on_id_pressed)
	_items.clear()


## Hides the transform gizmo in all 3D viewports (except those the user
## toggled by hand), or shows it again where TrenchForge hid it.
func set_hidden(hidden: bool) -> void:
	if _items.is_empty():
		_connect()
	var managed := _managed()
	var changed := false
	for viewport: int in _items:
		if _user_owned.has(viewport):
			continue
		var popup: PopupMenu = _items[viewport][0]
		var index: int = _items[viewport][1]
		if not is_instance_valid(popup):
			continue
		var checked := popup.is_item_checked(index)
		if hidden and checked:
			_toggle(popup, index)
			if not managed.has(viewport):
				managed.append(viewport)
				changed = true
		elif not hidden and not checked and managed.has(viewport):
			_toggle(popup, index)
	if changed:
		_set_managed(managed)


## True if the transform gizmo is switched off in every 3D viewport.
func is_hidden() -> bool:
	for viewport: int in _items:
		if (_items[viewport][0] as PopupMenu).is_item_checked(_items[viewport][1]):
			return false
	return not _items.is_empty()


func _connect() -> void:
	_items = _find_menu_items()
	for viewport: int in _items:
		var popup: PopupMenu = _items[viewport][0]
		popup.id_pressed.connect(_on_id_pressed.bind(viewport))


func _toggle(popup: PopupMenu, index: int) -> void:
	_toggling = true
	# Runs the viewport's own menu handler (toggles the check).
	popup.id_pressed.emit(popup.get_item_id(index))
	_toggling = false


func _on_id_pressed(id: int, viewport: int) -> void:
	if _toggling:
		return
	var popup: PopupMenu = _items[viewport][0]
	if id != popup.get_item_id(_items[viewport][1]):
		return
	if not _user_owned.has(viewport):
		_user_owned.append(viewport)
	var managed := _managed()
	if managed.has(viewport):
		managed.remove_at(managed.find(viewport))
		_set_managed(managed)


func _managed() -> PackedInt32Array:
	var settings := EditorInterface.get_editor_settings()
	return PackedInt32Array(settings.get_project_metadata(METADATA_SECTION, METADATA_KEY, PackedInt32Array()))


func _set_managed(viewports: PackedInt32Array) -> void:
	EditorInterface.get_editor_settings().set_project_metadata(METADATA_SECTION, METADATA_KEY, viewports)


# Finds the menu item by Godot's shortcut (independent of the editor
# language and of the item order).
static func _find_menu_items() -> Dictionary:
	var result := {}
	var shortcut: Shortcut = EditorInterface.get_editor_settings().get_shortcut(GODOT_SHORTCUT)
	if shortcut == null:
		return result
	for i in 4:
		var viewport := EditorInterface.get_editor_viewport_3d(i)
		if viewport == null or viewport.get_parent() == null:
			continue
		var editor_viewport := viewport.get_parent().get_parent()
		if editor_viewport == null:
			continue
		for button: MenuButton in editor_viewport.find_children("*", "MenuButton", true, false):
			var popup := button.get_popup()
			for index in popup.item_count:
				if popup.get_item_shortcut(index) == shortcut:
					result[i] = [popup, index]
	return result
