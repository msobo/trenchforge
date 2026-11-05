@tool
class_name TFSettingsDock
extends TabContainer
## Bottom-panel dock with all TrenchForge settings in one place: project
## settings (TFEditorSettings.project_settings()), per-user editor settings
## (overlays, viewport, colors) and the shortcuts (TFShortcuts).
##
## The dock stores nothing itself: every edit is written straight to
## ProjectSettings / EditorSettings, and changes made there (Godot's dialogs,
## Map menu) show up here. Each row has a reset button next to its value.
## Texts are translated when the dock is built; the plugin rebuilds it when
## the language changes.

const CONTEXT_LABELS := {
	"global": "Global",
	"tool": "All tools",
	"select": "Select",
	"vertex": "Vertex",
	"clip": "Clip",
	"shape": "Shape",
	"face_snap": "Face Snap",
	"bevel": "While bevelling",
	"uv_editor": "UV editor",
}
const MODIFIER_KEYS: Array[Key] = [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]

enum Capture { NONE, REPLACE, ADD }

## One refresh callable per row: reads the setting into its widget.
var _refreshers: Array[Callable] = []
var _refresh_queued := false
var _dir_dialog: EditorFileDialog
var _dir_target: Callable

var _shortcut_filter: LineEdit
var _shortcut_tree: Tree
var _capture_button: Button
var _add_button: Button
var _clear_button: Button
var _reset_button: Button
var _reset_all_dialog: ConfirmationDialog
var _capture := Capture.NONE
var _conflict_label: Label


func _init() -> void:
	name = "TFSettingsDock"
	# TFI18n translates the texts; keep the editor from translating them again.
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	custom_minimum_size = Vector2(240, 160)


func _ready() -> void:
	_build_project_tab()
	_build_editor_tab()
	_build_shortcut_tab()
	_dir_dialog = EditorFileDialog.new()
	_dir_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_dir_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_dir_dialog.dir_selected.connect(func(path: String) -> void:
		if _dir_target.is_valid():
			_dir_target.call(path))
	add_child(_dir_dialog)
	set_process_input(false)
	ProjectSettings.settings_changed.connect(_queue_refresh)
	EditorInterface.get_editor_settings().settings_changed.connect(_queue_refresh)
	refresh()


func _exit_tree() -> void:
	if ProjectSettings.settings_changed.is_connected(_queue_refresh):
		ProjectSettings.settings_changed.disconnect(_queue_refresh)
	var settings := EditorInterface.get_editor_settings()
	if settings.settings_changed.is_connected(_queue_refresh):
		settings.settings_changed.disconnect(_queue_refresh)


## Re-reads every setting into its widget.
func refresh() -> void:
	_refresh_queued = false
	for refresher in _refreshers:
		refresher.call()
	_refresh_shortcuts()


func _queue_refresh() -> void:
	if not _refresh_queued:
		_refresh_queued = true
		refresh.call_deferred()


# --- project tab -------------------------------------------------------------

func _build_project_tab() -> void:
	var columns := _tab(TFI18n.t("Project"))
	var general := _section(columns, TFI18n.t("General"), TFI18n.t("Project Settings → TrenchForge, shared by the whole team"))
	var textures := _section(columns, TFI18n.t("Textures & materials"), "")
	for entry in TFEditorSettings.project_settings():
		var setting: String = entry[0]
		var target := textures if setting in [TFConst.SETTING_TEXTURE_ROOTS, TFConst.SETTING_MATERIAL_CACHE_DIR, TFConst.SETTING_SHADER_TEXTURE_PARAM, TFConst.SETTING_TEXTURE_FILTER] else general
		var getter := func() -> Variant: return ProjectSettings.get_setting(setting, entry[1])
		var setter := func(value: Variant) -> void: _set_project(setting, value)
		_add_row(target, TFI18n.t(entry[5]), _make_editor(entry[2], entry[3], entry[4], getter, setter), getter, setter, entry[1])


func _set_project(setting: String, value: Variant) -> void:
	if ProjectSettings.get_setting(setting) == value:
		return
	ProjectSettings.set_setting(setting, value)
	ProjectSettings.save()


# --- editor tab --------------------------------------------------------------

func _build_editor_tab() -> void:
	var columns := _tab(TFI18n.t("Editor"))
	var interface := _section(columns, TFI18n.t("Interface"), TFI18n.t("Editor Settings → TrenchForge, just for you"))
	_add_editor_row(interface, TFEditorSettings.LANGUAGE, TFI18n.t("Language"), TFI18n.DEFAULT_LANGUAGE, TYPE_STRING,
		PROPERTY_HINT_ENUM, ",".join(TFI18n.LANGUAGES.keys().map(func(code: String) -> String: return "%s:%s" % [TFI18n.LANGUAGES[code], code])))
	var overlay := _section(columns, TFI18n.t("Overlays & viewport"), "")
	for entry in TFEditorSettings.OPTIONS:
		_add_editor_row(overlay, entry[0], TFI18n.t(entry[2]), entry[1], TYPE_BOOL)
	for entry in TFEditorSettings.NUMBERS:
		_add_editor_row(overlay, entry[0], TFI18n.t(entry[2]), entry[1], TYPE_INT, PROPERTY_HINT_RANGE, entry[3])
	var bevel := _section(columns, TFI18n.t("Bevel"), TFI18n.t("Last used options, the panel after a bevel changes them"))
	_add_option_rows(bevel, TFEditorSettings.BEVEL)
	var bridge := _section(columns, TFI18n.t("Bridge"), TFI18n.t("Options for new bridges, the shape panel changes a bridge afterwards"))
	_add_option_rows(bridge, TFEditorSettings.BRIDGE)
	var colors := _section(columns, TFI18n.t("Colors"), "", 2)
	for entry in TFEditorSettings.COLORS:
		_add_editor_row(colors, entry[0], TFI18n.t(entry[3]), entry[2], TYPE_COLOR)


# Rows of a TFEditorSettings option table (BEVEL, BRIDGE).
func _add_option_rows(grid: GridContainer, table: Array) -> void:
	for entry in table:
		var hint_string: String = entry[6]
		if entry[5] == PROPERTY_HINT_ENUM:
			hint_string = ",".join(Array(hint_string.split(",")).map(func(option: String) -> String: return TFI18n.t(option)))
		_add_editor_row(grid, entry[0], TFI18n.t(entry[3]), entry[2], entry[4], entry[5], hint_string)


func _add_editor_row(grid: GridContainer, key: String, label: String, default_value: Variant, type: int, hint := PROPERTY_HINT_NONE, hint_string := "") -> void:
	var setting := TFEditorSettings.PREFIX + key
	var getter := func() -> Variant: return EditorInterface.get_editor_settings().get_setting(setting)
	var setter := func(value: Variant) -> void:
		var settings := EditorInterface.get_editor_settings()
		if settings.get_setting(setting) != value:
			settings.set_setting(setting, value)
			settings.mark_setting_changed(setting)
	_add_row(grid, label, _make_editor(type, hint, hint_string, getter, setter), getter, setter, default_value)


# --- shortcut tab ------------------------------------------------------------

func _build_shortcut_tab() -> void:
	var root := HBoxContainer.new()
	root.name = "Shortcuts"
	add_child(root)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(left)
	_shortcut_filter = LineEdit.new()
	_shortcut_filter.placeholder_text = TFI18n.t("Filter by action or key")
	_shortcut_filter.clear_button_enabled = true
	_shortcut_filter.text_changed.connect(func(_text: String) -> void: _refresh_shortcuts())
	left.add_child(_shortcut_filter)
	_shortcut_tree = Tree.new()
	_shortcut_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_shortcut_tree.columns = 3
	_shortcut_tree.column_titles_visible = true
	_shortcut_tree.set_column_title(0, TFI18n.t("Action"))
	_shortcut_tree.set_column_title(1, TFI18n.t("Context"))
	_shortcut_tree.set_column_title(2, TFI18n.t("Keys"))
	_shortcut_tree.set_column_expand(0, true)
	_shortcut_tree.set_column_expand_ratio(0, 3)
	_shortcut_tree.set_column_expand(1, true)
	_shortcut_tree.set_column_expand(2, true)
	_shortcut_tree.set_column_expand_ratio(2, 2)
	_shortcut_tree.hide_root = true
	_shortcut_tree.select_mode = Tree.SELECT_ROW
	_shortcut_tree.item_selected.connect(_update_shortcut_buttons)
	_shortcut_tree.item_activated.connect(func() -> void: _start_capture(Capture.REPLACE))
	left.add_child(_shortcut_tree)
	_conflict_label = Label.new()
	_conflict_label.add_theme_color_override("font_color", get_theme_color("warning_color", "Editor"))
	_conflict_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(_conflict_label)

	var buttons := VBoxContainer.new()
	buttons.custom_minimum_size.x = 150
	root.add_child(buttons)
	_capture_button = _shortcut_button(buttons, TFI18n.t("Assign…"), TFI18n.t("The next key pressed replaces the binding (or double-click the row). Click again to cancel."))
	_capture_button.toggle_mode = true
	_capture_button.toggled.connect(func(on: bool) -> void:
		if on:
			_start_capture(Capture.REPLACE)
		else:
			_stop_capture())
	_add_button = _shortcut_button(buttons, TFI18n.t("Add key…"), TFI18n.t("The next key pressed is added as another binding."))
	_add_button.toggle_mode = true
	_add_button.toggled.connect(func(on: bool) -> void:
		if on:
			_start_capture(Capture.ADD)
		else:
			_stop_capture())
	_clear_button = _shortcut_button(buttons, TFI18n.t("Clear"), TFI18n.t("Action without a key (still available in the menus)."))
	_clear_button.pressed.connect(func() -> void: _write_shortcut(_selected_action(), Shortcut.new()))
	_reset_button = _shortcut_button(buttons, TFI18n.t("Reset"), TFI18n.t("Default binding of this action."))
	_reset_button.pressed.connect(func() -> void:
		var action := _selected_action()
		_write_shortcut(action, _default_shortcut(action)))
	buttons.add_child(HSeparator.new())
	var reset_all := _shortcut_button(buttons, TFI18n.t("Reset all…"), TFI18n.t("All TrenchForge shortcuts back to their defaults."))
	reset_all.disabled = false
	_reset_all_dialog = ConfirmationDialog.new()
	_reset_all_dialog.title = "TrenchForge"
	_reset_all_dialog.dialog_text = TFI18n.t("Reset all TrenchForge shortcuts to their default bindings?")
	_reset_all_dialog.confirmed.connect(_reset_all_shortcuts)
	add_child(_reset_all_dialog)
	reset_all.pressed.connect(_reset_all_dialog.popup_centered)
	_update_shortcut_buttons()


func _shortcut_button(parent: Control, text: String, tooltip: String) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.disabled = true
	parent.add_child(button)
	return button


func _refresh_shortcuts() -> void:
	if _shortcut_tree == null:
		return
	var selected := _selected_action()
	var conflicts := TFShortcuts.find_conflicts()
	var conflicting := {}
	for conflict in conflicts:
		conflicting[conflict[0]] = true
		conflicting[conflict[1]] = true
	var filter := _shortcut_filter.text.strip_edges().to_lower()
	_shortcut_tree.clear()
	var root := _shortcut_tree.create_item()
	var warning := get_theme_color("warning_color", "Editor")
	var modified := get_theme_color("accent_color", "Editor")
	for entry in TFShortcuts.ACTIONS:
		var action: String = entry[0]
		var keys := TFShortcuts.text(action)
		var context := TFI18n.t(CONTEXT_LABELS.get(entry[1], entry[1]))
		var haystack := ("%s %s %s %s" % [TFShortcuts.label(action), action, context, keys]).to_lower()
		if not filter.is_empty() and not haystack.contains(filter):
			continue
		var item := root.create_child()
		item.set_text(0, TFShortcuts.label(action))
		item.set_tooltip_text(0, "%s%s" % [action, ("\n" + TFI18n.t("Overrides %s") % TFI18n.t(TFShortcuts.GODOT_CONFLICTS[action])) if TFShortcuts.GODOT_CONFLICTS.has(action) else ""])
		item.set_metadata(0, action)
		item.set_text(1, context)
		item.set_text(2, keys)
		if conflicting.has(action):
			item.set_custom_color(2, warning)
			item.set_tooltip_text(2, TFI18n.t("Conflicts with another action in the same context"))
		elif not _is_default_shortcut(action):
			item.set_custom_color(2, modified)
			item.set_tooltip_text(2, TFI18n.t("Changed (default: %s)") % _shortcut_text(_default_shortcut(action)))
		if action == selected:
			item.select(0)
	var lines: PackedStringArray = []
	for conflict in conflicts:
		lines.append("⚠ %s: %s / %s" % [conflict[2], TFShortcuts.label(conflict[0]), TFShortcuts.label(conflict[1])])
	_conflict_label.text = "\n".join(lines)
	_conflict_label.visible = not lines.is_empty()
	_update_shortcut_buttons()


func _selected_action() -> String:
	if _shortcut_tree == null:
		return ""
	var item := _shortcut_tree.get_selected()
	return String(item.get_metadata(0)) if item != null else ""


func _update_shortcut_buttons() -> void:
	var action := _selected_action()
	var none := action.is_empty()
	for button in [_capture_button, _add_button, _clear_button]:
		button.disabled = none
	_reset_button.disabled = none or _is_default_shortcut(action)
	_capture_button.set_pressed_no_signal(_capture == Capture.REPLACE)
	_add_button.set_pressed_no_signal(_capture == Capture.ADD)
	_capture_button.text = TFI18n.t("Press a key…") if _capture == Capture.REPLACE else TFI18n.t("Assign…")
	_add_button.text = TFI18n.t("Press a key…") if _capture == Capture.ADD else TFI18n.t("Add key…")


func _start_capture(mode: Capture) -> void:
	if _selected_action().is_empty():
		_stop_capture()
		return
	_capture = mode
	set_process_input(true)
	_update_shortcut_buttons()


func _stop_capture() -> void:
	_capture = Capture.NONE
	set_process_input(false)
	_update_shortcut_buttons()


## While capturing, the next key press (with modifiers) becomes the binding;
## a mouse click anywhere cancels.
func _input(event: InputEvent) -> void:
	if _capture == Capture.NONE:
		return
	if event is InputEventMouseButton and event.pressed:
		# The capture buttons stop capturing themselves (toggled off).
		var position: Vector2 = event.global_position
		if not _capture_button.get_global_rect().has_point(position) and not _add_button.get_global_rect().has_point(position):
			_stop_capture()
		return
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var key_event := event as InputEventKey
	if key_event.keycode in MODIFIER_KEYS:
		return
	get_viewport().set_input_as_handled()
	var action := _selected_action()
	var shortcut := Shortcut.new()
	var events: Array = []
	if _capture == Capture.ADD:
		events = TFShortcuts.get_shortcut(action).events.duplicate()
	var binding := captured_event(key_event)
	if not events.any(func(existing: InputEvent) -> bool: return existing is InputEventKey and TFShortcuts.event_matches(existing, binding)):
		events.append(binding)
	shortcut.events = events
	_stop_capture()
	_write_shortcut(action, shortcut)


## A shortcut event for a pressed key: Ctrl and Cmd both become "Ctrl" of
## TFShortcuts (command_or_control_autoremap), and the physical key position
## matches too (macOS Option and German layouts change the character).
static func captured_event(event: InputEventKey) -> InputEventKey:
	var binding := InputEventKey.new()
	binding.keycode = event.keycode if event.keycode != KEY_NONE else event.physical_keycode
	binding.physical_keycode = event.physical_keycode if event.physical_keycode != KEY_NONE else binding.keycode
	binding.command_or_control_autoremap = event.ctrl_pressed or event.meta_pressed or event.command_or_control_autoremap
	binding.shift_pressed = event.shift_pressed
	binding.alt_pressed = event.alt_pressed
	return binding


func _write_shortcut(action: String, shortcut: Shortcut) -> void:
	if action.is_empty():
		return
	var settings := EditorInterface.get_editor_settings()
	var setting := TFShortcuts.SETTING_PREFIX + action
	settings.set_setting(setting, shortcut)
	# Lets the plugin report conflicts (it checks the changed settings).
	settings.mark_setting_changed(setting)
	TFShortcuts.load_shortcuts()
	_refresh_shortcuts()


func _reset_all_shortcuts() -> void:
	var settings := EditorInterface.get_editor_settings()
	for entry in TFShortcuts.ACTIONS:
		var setting: String = TFShortcuts.SETTING_PREFIX + entry[0]
		if not _is_default_shortcut(entry[0]):
			settings.set_setting(setting, _default_shortcut(entry[0]))
			settings.mark_setting_changed(setting)
	TFShortcuts.load_shortcuts()
	_refresh_shortcuts()


func _default_shortcut(action: String) -> Shortcut:
	for entry in TFShortcuts.ACTIONS:
		if entry[0] == action:
			return TFShortcuts.make_shortcut(entry.slice(3))
	return Shortcut.new()


func _is_default_shortcut(action: String) -> bool:
	return _shortcut_text(TFShortcuts.get_shortcut(action)) == _shortcut_text(_default_shortcut(action))


static func _shortcut_text(shortcut: Shortcut) -> String:
	var parts: PackedStringArray = []
	for event in shortcut.events:
		if event is InputEventKey:
			parts.append(TFShortcuts.event_text(event))
	return " / ".join(parts) if not parts.is_empty() else "—"


# --- rows and widgets --------------------------------------------------------

## A scrollable tab whose sections sit side by side.
func _tab(title: String) -> HBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(scroll)
	var columns := HBoxContainer.new()
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 24)
	scroll.add_child(columns)
	return columns


## Heading plus a grid of label | value | reset rows, per_row of them side
## by side.
func _section(columns: HBoxContainer, title: String, hint: String, per_row := 1) -> GridContainer:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(box)
	var heading := Label.new()
	heading.text = title
	heading.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
	box.add_child(heading)
	if not hint.is_empty():
		var hint_label := Label.new()
		hint_label.text = hint
		hint_label.modulate = Color(1, 1, 1, 0.6)
		box.add_child(hint_label)
	var grid := GridContainer.new()
	grid.columns = 3 * per_row
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(grid)
	return grid


func _add_row(grid: GridContainer, text: String, editor: Control, getter: Callable, setter: Callable, default_value: Variant) -> void:
	var label := Label.new()
	label.text = text
	label.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	grid.add_child(label)
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.custom_minimum_size.x = maxf(editor.custom_minimum_size.x, 140)
	grid.add_child(editor)
	var reset := Button.new()
	reset.flat = true
	reset.icon = _editor_icon("Reload")
	reset.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	reset.tooltip_text = TFI18n.t("Reset to default (%s)") % _value_text(default_value)
	reset.pressed.connect(func() -> void: setter.call(default_value))
	grid.add_child(reset)
	_refreshers.append(func() -> void:
		editor.call(&"show_value", getter.call())
		var is_default := _values_equal(getter.call(), default_value)
		reset.disabled = is_default
		reset.self_modulate.a = 0.0 if is_default else 1.0)


## A widget for one value type; it gets a show_value(value) method through
## a small wrapper so rows can refresh it uniformly.
func _make_editor(type: int, hint: int, hint_string: String, getter: Callable, setter: Callable) -> Control:
	match type:
		TYPE_BOOL:
			var check := ValueEditor.new()
			var box := CheckBox.new()
			box.toggled.connect(func(on: bool) -> void: setter.call(on))
			check.setup(box, func(value: Variant) -> void: box.set_pressed_no_signal(bool(value)))
			return check
		TYPE_COLOR:
			var color := ValueEditor.new()
			var picker := ColorPickerButton.new()
			picker.edit_alpha = true
			picker.custom_minimum_size = Vector2(80, 24)
			picker.color_changed.connect(func(value: Color) -> void: setter.call(value))
			color.setup(picker, func(value: Variant) -> void: picker.color = value)
			return color
		TYPE_INT when hint == PROPERTY_HINT_ENUM:
			var options := ValueEditor.new()
			var button := OptionButton.new()
			for option in hint_string.split(","):
				button.add_item(option)
			button.item_selected.connect(func(index: int) -> void: setter.call(index))
			options.setup(button, func(value: Variant) -> void: button.select(int(value)))
			return options
		TYPE_STRING when hint == PROPERTY_HINT_ENUM:
			# Options "Label:value"; the setting stores the value.
			var choices := ValueEditor.new()
			var button := OptionButton.new()
			var values: PackedStringArray = []
			for option in hint_string.split(","):
				button.add_item(option.get_slice(":", 0))
				values.append(option.get_slice(":", 1) if option.contains(":") else option)
			button.item_selected.connect(func(index: int) -> void: setter.call(values[index]))
			choices.setup(button, func(value: Variant) -> void: button.select(values.find(String(value))))
			return choices
		TYPE_INT, TYPE_FLOAT:
			var number := ValueEditor.new()
			var spin := SpinBox.new()
			var range_parts := hint_string.split(",")
			spin.min_value = float(range_parts[0])
			spin.max_value = float(range_parts[1])
			spin.step = float(range_parts[2]) if range_parts.size() > 2 else 1.0
			spin.rounded = type == TYPE_INT
			spin.select_all_on_focus = true
			spin.value_changed.connect(func(value: float) -> void: setter.call(int(value) if type == TYPE_INT else value))
			number.setup(spin, func(value: Variant) -> void: spin.set_value_no_signal(float(value)))
			return number
		TYPE_PACKED_STRING_ARRAY:
			return _make_dir_list(getter, setter)
	# Strings, optionally folders.
	var text := ValueEditor.new()
	var row := HBoxContainer.new()
	var line := LineEdit.new()
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.text_submitted.connect(func(value: String) -> void: setter.call(value.strip_edges()))
	line.focus_exited.connect(func() -> void: setter.call(line.text.strip_edges()))
	row.add_child(line)
	if hint == PROPERTY_HINT_DIR:
		row.add_child(_folder_button(func(path: String) -> void: setter.call(path)))
	text.setup(row, func(value: Variant) -> void:
		if not line.has_focus():
			line.text = String(value))
	return text


## Editable list of folders (texture roots): one row per folder plus "add".
func _make_dir_list(getter: Callable, setter: Callable) -> Control:
	var editor := ValueEditor.new()
	var list := VBoxContainer.new()
	editor.setup(list, func(value: Variant) -> void:
		var dirs := PackedStringArray(value)
		for child in list.get_children():
			list.remove_child(child)
			child.queue_free()
		for i in dirs.size():
			var row := HBoxContainer.new()
			var line := LineEdit.new()
			line.text = dirs[i]
			line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var commit := func(path: String) -> void:
				var current := PackedStringArray(getter.call())
				if i < current.size() and current[i] != path.strip_edges():
					current[i] = path.strip_edges()
					setter.call(current)
			line.text_submitted.connect(commit)
			line.focus_exited.connect(func() -> void: commit.call(line.text))
			row.add_child(line)
			row.add_child(_folder_button(commit))
			var remove := Button.new()
			remove.flat = true
			remove.icon = _editor_icon("Remove")
			remove.tooltip_text = TFI18n.t("Remove folder")
			remove.pressed.connect(func() -> void:
				var current := PackedStringArray(getter.call())
				if i < current.size():
					current.remove_at(i)
					setter.call(current))
			row.add_child(remove)
			list.add_child(row)
		var add := Button.new()
		add.text = TFI18n.t("Add folder…")
		add.icon = _editor_icon("Add")
		add.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		add.pressed.connect(func() -> void:
			_pick_dir(func(path: String) -> void:
				var current := PackedStringArray(getter.call())
				if not current.has(path):
					current.append(path)
					setter.call(current)))
		list.add_child(add))
	return editor


func _folder_button(on_picked: Callable) -> Button:
	var button := Button.new()
	button.flat = true
	button.icon = _editor_icon("Folder")
	button.tooltip_text = TFI18n.t("Choose folder")
	button.pressed.connect(func() -> void: _pick_dir(on_picked))
	return button


func _pick_dir(on_picked: Callable) -> void:
	_dir_target = on_picked
	_dir_dialog.popup_file_dialog()


static func _values_equal(a: Variant, b: Variant) -> bool:
	if a is Color and b is Color:
		return (a as Color).is_equal_approx(b)
	if (a is float or a is int) and (b is float or b is int):
		return is_equal_approx(float(a), float(b))
	return typeof(a) == typeof(b) and a == b


static func _value_text(value: Variant) -> String:
	if value is bool:
		return TFI18n.t("on") if value else TFI18n.t("off")
	if value is Color:
		return "#" + (value as Color).to_html()
	if value is PackedStringArray:
		return ", ".join(value)
	return str(value)


func _editor_icon(icon_name: String) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon(icon_name, &"EditorIcons"):
		return theme.get_icon(icon_name, &"EditorIcons")
	return null


## Holds one widget and knows how to show a value in it.
class ValueEditor:
	extends MarginContainer

	var _show: Callable

	func setup(widget: Control, show: Callable) -> void:
		add_child(widget)
		_show = show

	func show_value(value: Variant) -> void:
		_show.call(value)
