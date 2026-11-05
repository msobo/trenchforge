@tool
class_name TFMaterialBrowser
extends VBoxContainer
## Material palette (Anvil style): image folders and material resources below
## the texture roots (project setting). Clicking an entry emits
## material_chosen; images are turned into cached materials on first use.

signal material_chosen(material: Material)

enum TypeFilter { ALL, IMAGES, MATERIALS }
enum Kind { FOLDER, IMAGE, MATERIAL }

const META_SECTION := "trenchforge"
const META_FAVORITES := "favorite_folders"
const META_ICON_SIZE := "browser_icon_size"
const DEFAULT_ICON_SIZE: int = 80
## [name (file name dev_<name>.png, translated in the menu), color]
const PLACEHOLDER_COLORS := [
	["grey", Color(0.55, 0.55, 0.55)],
	["orange", Color(0.85, 0.5, 0.2)],
	["blue", Color(0.3, 0.5, 0.8)],
	["green", Color(0.35, 0.65, 0.35)],
	["red", Color(0.75, 0.3, 0.3)],
	["yellow", Color(0.85, 0.75, 0.3)],
	["purple", Color(0.55, 0.4, 0.75)],
]
const MENU_TOGGLE_FAVORITE: int = 0
const MENU_FAVORITE_BASE: int = 100
const MENU_SHOW_IN_FILESYSTEM: int = 0
const MENU_ITEM_FAVORITE: int = 1

## "" is the virtual root listing all texture roots (only with several roots).
var _current_dir := ""
var _history: Array[String] = []
var _history_index := -1
var _favorites := PackedStringArray()
var _current_material_path := ""
var _refresh_queued := false
## Increases with every listing so late previews of old listings are dropped.
var _generation := 0
var _item_by_path := {}

var _back_button: Button
var _forward_button: Button
var _up_button: Button
var _breadcrumb: HBoxContainer
var _favorites_button: MenuButton
var _filter_edit: LineEdit
var _type_option: OptionButton
var _size_slider: HSlider
var _placeholder_button: MenuButton
var _list: ItemList
var _status: Label
var _context_menu: PopupMenu
var _context_path := ""


func _init() -> void:
	name = "TFMaterialBrowser"
	# TFI18n translates the texts; keep the editor from translating them again.
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(200, 160)

	# Wraps in narrow docks, stays one row in the wide bottom panel.
	var nav := HFlowContainer.new()
	add_child(nav)
	_back_button = _make_icon_button(TFI18n.t("Back (mouse button 4)"), _go_back)
	nav.add_child(_back_button)
	_forward_button = _make_icon_button(TFI18n.t("Forward (mouse button 5)"), _go_forward)
	nav.add_child(_forward_button)
	_up_button = _make_icon_button(TFI18n.t("Parent folder"), _go_up)
	nav.add_child(_up_button)
	var crumb_scroll := ScrollContainer.new()
	crumb_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	crumb_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	crumb_scroll.custom_minimum_size = Vector2(140, 28)
	nav.add_child(crumb_scroll)
	_breadcrumb = HBoxContainer.new()
	crumb_scroll.add_child(_breadcrumb)
	_favorites_button = MenuButton.new()
	_favorites_button.text = "★"
	_favorites_button.tooltip_text = TFI18n.t("Favorite folders")
	_favorites_button.flat = true
	_favorites_button.about_to_popup.connect(_fill_favorites_menu)
	_favorites_button.get_popup().id_pressed.connect(_on_favorites_menu)
	nav.add_child(_favorites_button)

	_filter_edit = LineEdit.new()
	_filter_edit.placeholder_text = TFI18n.t("Filter")
	_filter_edit.clear_button_enabled = true
	_filter_edit.custom_minimum_size.x = 120
	_filter_edit.text_changed.connect(func(_text: String) -> void: _refresh())
	nav.add_child(_filter_edit)
	_type_option = OptionButton.new()
	_type_option.add_item(TFI18n.t("All"), TypeFilter.ALL)
	_type_option.add_item(TFI18n.t("Images"), TypeFilter.IMAGES)
	_type_option.add_item(TFI18n.t("Materials"), TypeFilter.MATERIALS)
	_type_option.tooltip_text = TFI18n.t("Type filter")
	_type_option.item_selected.connect(func(_index: int) -> void: _refresh())
	nav.add_child(_type_option)
	_size_slider = HSlider.new()
	_size_slider.min_value = 32
	_size_slider.max_value = 256
	_size_slider.step = 8
	_size_slider.value = DEFAULT_ICON_SIZE
	_size_slider.custom_minimum_size.x = 80
	_size_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_size_slider.tooltip_text = TFI18n.t("Thumbnail size")
	_size_slider.value_changed.connect(_on_size_changed)
	nav.add_child(_size_slider)
	_placeholder_button = MenuButton.new()
	_placeholder_button.text = "+"
	_placeholder_button.tooltip_text = TFI18n.t("Create a placeholder texture in the current folder")
	_placeholder_button.flat = true
	for i in PLACEHOLDER_COLORS.size():
		_placeholder_button.get_popup().add_item(TFI18n.t("Placeholder %s") % TFI18n.t(PLACEHOLDER_COLORS[i][0]), i)
	_placeholder_button.get_popup().id_pressed.connect(_create_placeholder)
	nav.add_child(_placeholder_button)

	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.custom_minimum_size.y = 100
	_list.icon_mode = ItemList.ICON_MODE_TOP
	_list.max_columns = 0
	_list.same_column_width = true
	_list.max_text_lines = 2
	_list.allow_rmb_select = true
	_list.item_clicked.connect(_on_item_clicked)
	_list.gui_input.connect(_on_gui_input)
	add_child(_list)

	_status = Label.new()
	_status.clip_text = true
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_status)

	_context_menu = PopupMenu.new()
	_context_menu.id_pressed.connect(_on_context_menu)
	add_child(_context_menu)
	gui_input.connect(_on_gui_input)


func _ready() -> void:
	_back_button.icon = _editor_icon("Back")
	_forward_button.icon = _editor_icon("Forward")
	_up_button.icon = _editor_icon("MoveUp")
	_placeholder_button.icon = _editor_icon("Add")
	_placeholder_button.text = ""
	var settings := EditorInterface.get_editor_settings()
	_favorites = PackedStringArray(settings.get_project_metadata(META_SECTION, META_FAVORITES, PackedStringArray()))
	_size_slider.set_value_no_signal(int(settings.get_project_metadata(META_SECTION, META_ICON_SIZE, DEFAULT_ICON_SIZE)))
	_apply_icon_size()
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_queue_refresh)
	ProjectSettings.settings_changed.connect(_on_project_settings_changed)
	var roots := TFConst.get_texture_roots()
	navigate(roots[0] if roots.size() == 1 else "")


func _exit_tree() -> void:
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem.filesystem_changed.is_connected(_queue_refresh):
		filesystem.filesystem_changed.disconnect(_queue_refresh)
	if ProjectSettings.settings_changed.is_connected(_on_project_settings_changed):
		ProjectSettings.settings_changed.disconnect(_on_project_settings_changed)


## Highlights the entry that produces this material.
func set_current_material(material: Material) -> void:
	var path := material.resource_path if material != null else ""
	if path == _current_material_path:
		return
	_current_material_path = path
	_highlight_current()
	_update_status()


# --- navigation ---------------------------------------------------------------

func navigate(dir: String, record: bool = true) -> void:
	if record:
		_history.resize(_history_index + 1)
		if _history.is_empty() or _history[-1] != dir:
			_history.append(dir)
		_history_index = _history.size() - 1
	_current_dir = dir
	_rebuild_breadcrumb()
	_refresh()


func _go_back() -> void:
	if _history_index > 0:
		_history_index -= 1
		navigate(_history[_history_index], false)


func _go_forward() -> void:
	if _history_index < _history.size() - 1:
		_history_index += 1
		navigate(_history[_history_index], false)


func _go_up() -> void:
	var parent := _parent_dir(_current_dir)
	if parent != _current_dir:
		navigate(parent)


## Parent inside the texture roots; roots lead to the virtual root.
func _parent_dir(dir: String) -> String:
	if dir.is_empty():
		return dir
	var roots := TFConst.get_texture_roots()
	if roots.has(dir):
		return "" if roots.size() > 1 else dir
	return dir.get_base_dir()


func _root_of(dir: String) -> String:
	for root in TFConst.get_texture_roots():
		if dir == root or dir.begins_with(root.trim_suffix("/") + "/"):
			return root
	return ""


func _rebuild_breadcrumb() -> void:
	for child in _breadcrumb.get_children():
		child.queue_free()
	var roots := TFConst.get_texture_roots()
	if roots.size() > 1:
		_add_crumb(TFI18n.t("Roots"), "")
	var root := _root_of(_current_dir)
	if root.is_empty():
		if not _current_dir.is_empty():
			_add_crumb(_current_dir, _current_dir)
	else:
		_add_crumb(root.trim_prefix("res://"), root)
		var path := root
		for part in _current_dir.substr(root.length()).split("/", false):
			path = path.path_join(part)
			_breadcrumb.add_child(_make_label("›"))
			_add_crumb(part, path)
	_back_button.disabled = _history_index <= 0
	_forward_button.disabled = _history_index >= _history.size() - 1
	_up_button.disabled = _parent_dir(_current_dir) == _current_dir


func _add_crumb(text: String, dir: String) -> void:
	var button := Button.new()
	button.text = text
	button.flat = true
	button.pressed.connect(navigate.bind(dir))
	_breadcrumb.add_child(button)


# --- listing ------------------------------------------------------------------

func _queue_refresh() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	_refresh.call_deferred()


func _refresh() -> void:
	_refresh_queued = false
	_generation += 1
	_item_by_path.clear()
	_list.clear()
	if _current_dir.is_empty():
		for root in TFConst.get_texture_roots():
			_add_folder_item(root.trim_prefix("res://"), root)
		_update_status()
		return

	var dir := EditorInterface.get_resource_filesystem().get_filesystem_path(_current_dir)
	if dir == null:
		_status.text = TFI18n.t("%s does not exist · “+” creates placeholder textures there (folders: project setting %s)") % [_current_dir, TFConst.SETTING_TEXTURE_ROOTS]
		return
	var filter := _filter_edit.text.strip_edges().to_lower()
	var type_filter := _type_option.get_selected_id()
	var cache_dir := TFConst.get_material_cache_dir().trim_suffix("/")
	for i in dir.get_subdir_count():
		var sub := dir.get_subdir(i)
		if sub.get_path().trim_suffix("/") == cache_dir:
			continue
		_add_folder_item(sub.get_name(), sub.get_path().trim_suffix("/"))
	if _is_texture_root(_current_dir) and type_filter != TypeFilter.IMAGES:
		_add_special_materials(filter)
	for i in dir.get_file_count():
		var path := dir.get_file_path(i)
		var type := String(dir.get_file_type(i))
		var kind := -1
		if ClassDB.is_parent_class(type, &"Texture2D") and TFMaterialCache.is_image_path(path):
			kind = Kind.IMAGE
		elif ClassDB.is_parent_class(type, &"Material"):
			kind = Kind.MATERIAL
		if kind == -1:
			continue
		if type_filter == TypeFilter.IMAGES and kind != Kind.IMAGE:
			continue
		if type_filter == TypeFilter.MATERIALS and kind != Kind.MATERIAL:
			continue
		var file_name := path.get_file()
		if not filter.is_empty() and not file_name.to_lower().contains(filter):
			continue
		var index := _list.add_item(file_name.get_basename(), _editor_icon(type))
		_list.set_item_metadata(index, {"kind": kind, "path": path})
		_list.set_item_tooltip(index, path)
		_item_by_path[path] = index
		EditorInterface.get_resource_previewer().queue_resource_preview(path, self, &"_on_preview", [_generation, path])
	_highlight_current()
	_update_status()


## Addon materials tf_nodraw / tf_clip, listed at the top of each root.
func _add_special_materials(filter: String) -> void:
	for path in [TFConst.MATERIAL_NODRAW_PATH, TFConst.MATERIAL_CLIP_PATH]:
		var file_name: String = path.get_file()
		if not filter.is_empty() and not file_name.to_lower().contains(filter):
			continue
		var index := _list.add_item(file_name.get_basename(), _editor_icon("StandardMaterial3D"))
		_list.set_item_metadata(index, {"kind": Kind.MATERIAL, "path": path})
		_list.set_item_tooltip(index, "%s\n%s" % [path, TFI18n.t("Special material: the face is not rendered (collision stays)")])
		_item_by_path[path] = index
		EditorInterface.get_resource_previewer().queue_resource_preview(path, self, &"_on_preview", [_generation, path])


func _is_texture_root(dir: String) -> bool:
	for root in TFConst.get_texture_roots():
		if root.trim_suffix("/") == dir.trim_suffix("/"):
			return true
	return false


func _add_folder_item(text: String, path: String) -> void:
	var index := _list.add_item(text, _editor_icon("Folder"))
	_list.set_item_metadata(index, {"kind": Kind.FOLDER, "path": path})
	_list.set_item_tooltip(index, path)
	_list.set_item_icon_modulate(index, Color(0.65, 0.8, 1.0))


func _on_preview(_path: String, preview: Texture2D, _thumbnail: Texture2D, userdata: Variant) -> void:
	var data: Array = userdata
	if data[0] != _generation or preview == null or not _item_by_path.has(data[1]):
		return
	_list.set_item_icon(_item_by_path[data[1]], preview)


func _highlight_current() -> void:
	_list.deselect_all()
	if _current_material_path.is_empty():
		return
	for i in _list.item_count:
		var meta: Dictionary = _list.get_item_metadata(i)
		var path: String = meta["path"]
		if meta["kind"] == Kind.IMAGE:
			path = TFMaterialCache.cache_path(path, TFConst.get_material_cache_dir())
		if path == _current_material_path:
			_list.select(i)
			_list.ensure_current_is_visible()
			return


func _update_status() -> void:
	var current := _current_material_path.get_file() if not _current_material_path.is_empty() else "—"
	_status.text = TFI18n.t("%d entries · Current material: %s") % [_list.item_count, current]


# --- interaction --------------------------------------------------------------

func _on_item_clicked(index: int, at_position: Vector2, mouse_button: int) -> void:
	var meta: Dictionary = _list.get_item_metadata(index)
	if mouse_button == MOUSE_BUTTON_RIGHT:
		_open_context_menu(meta, _list.get_screen_position() + at_position)
		return
	if mouse_button != MOUSE_BUTTON_LEFT:
		return
	match meta["kind"]:
		Kind.FOLDER:
			navigate.call_deferred(meta["path"])
		Kind.IMAGE:
			_choose(_material_for_image(meta["path"]))
		Kind.MATERIAL:
			_choose(ResourceLoader.load(meta["path"]) as Material)


func _choose(material: Material) -> void:
	if material == null:
		return
	_current_material_path = material.resource_path
	_update_status()
	material_chosen.emit(material)


func _material_for_image(path: String) -> Material:
	var cache_path := TFMaterialCache.cache_path(path, TFConst.get_material_cache_dir())
	var existed := ResourceLoader.exists(cache_path)
	var material := TFMaterialCache.material_for_image(path)
	if material != null and not existed:
		EditorInterface.get_resource_filesystem().update_file(cache_path)
	return material


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_XBUTTON1:
			_go_back()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_XBUTTON2:
			_go_forward()
			accept_event()


func _open_context_menu(meta: Dictionary, screen_position: Vector2) -> void:
	_context_path = meta["path"]
	_context_menu.clear()
	_context_menu.add_item(TFI18n.t("Show in FileSystem"), MENU_SHOW_IN_FILESYSTEM)
	if meta["kind"] == Kind.FOLDER:
		_context_menu.add_item(TFI18n.t("Remove favorite") if _favorites.has(_context_path) else TFI18n.t("Add to favorites"), MENU_ITEM_FAVORITE)
	_context_menu.position = Vector2i(screen_position)
	_context_menu.reset_size()
	_context_menu.popup()


func _on_context_menu(id: int) -> void:
	match id:
		MENU_SHOW_IN_FILESYSTEM:
			EditorInterface.select_file(_context_path)
		MENU_ITEM_FAVORITE:
			_toggle_favorite(_context_path)


func _on_size_changed(value: float) -> void:
	_apply_icon_size()
	EditorInterface.get_editor_settings().set_project_metadata(META_SECTION, META_ICON_SIZE, int(value))


func _apply_icon_size() -> void:
	var size := int(_size_slider.value * EditorInterface.get_editor_scale())
	_list.fixed_icon_size = Vector2i(size, size)
	_list.fixed_column_width = size + 16


func _on_project_settings_changed() -> void:
	if not _current_dir.is_empty() and _root_of(_current_dir).is_empty():
		var roots := TFConst.get_texture_roots()
		navigate(roots[0] if roots.size() == 1 else "")
	else:
		_queue_refresh()


# --- favorites ----------------------------------------------------------------

func _fill_favorites_menu() -> void:
	var popup := _favorites_button.get_popup()
	popup.clear()
	if not _current_dir.is_empty():
		popup.add_item(TFI18n.t("Remove current folder") if _favorites.has(_current_dir) else TFI18n.t("Add current folder"), MENU_TOGGLE_FAVORITE)
		popup.add_separator()
	if _favorites.is_empty():
		popup.add_item(TFI18n.t("No favorites"), -1)
		popup.set_item_disabled(popup.item_count - 1, true)
	for i in _favorites.size():
		popup.add_item(_favorites[i].trim_prefix("res://"), MENU_FAVORITE_BASE + i)


func _on_favorites_menu(id: int) -> void:
	if id == MENU_TOGGLE_FAVORITE:
		_toggle_favorite(_current_dir)
	elif id >= MENU_FAVORITE_BASE and id - MENU_FAVORITE_BASE < _favorites.size():
		navigate(_favorites[id - MENU_FAVORITE_BASE])


func _toggle_favorite(dir: String) -> void:
	if _favorites.has(dir):
		_favorites.remove_at(_favorites.find(dir))
	else:
		_favorites.append(dir)
	EditorInterface.get_editor_settings().set_project_metadata(META_SECTION, META_FAVORITES, _favorites)


# --- placeholders -------------------------------------------------------------

func _create_placeholder(id: int) -> void:
	var dir := _current_dir if not _current_dir.is_empty() else TFConst.get_texture_roots()[0]
	DirAccess.make_dir_recursive_absolute(dir)
	var base := "dev_%s" % PLACEHOLDER_COLORS[id][0]
	var path := dir.path_join(base + ".png")
	var n := 2
	while FileAccess.file_exists(path):
		path = dir.path_join("%s_%d.png" % [base, n])
		n += 1
	var error := TFMaterialCache.create_placeholder_image(PLACEHOLDER_COLORS[id][1]).save_png(path)
	if error != OK:
		push_warning("TrenchForge: could not write %s (error %d)" % [path, error])
		return
	EditorInterface.get_resource_filesystem().scan()
	if _current_dir.is_empty() or _current_dir != dir:
		navigate(dir)


# --- helpers ------------------------------------------------------------------

func _make_icon_button(tooltip: String, callback: Callable) -> Button:
	var button := Button.new()
	button.flat = true
	button.tooltip_text = tooltip
	button.pressed.connect(callback)
	return button


func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _editor_icon(icon_name: String) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon(icon_name, &"EditorIcons"):
		return theme.get_icon(icon_name, &"EditorIcons")
	if theme != null:
		return theme.get_icon(&"File", &"EditorIcons")
	return null
