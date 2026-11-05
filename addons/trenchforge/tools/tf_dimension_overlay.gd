@tool
class_name TFDimensionOverlay
extends RefCounted
## 2D viewport overlay helpers: dimension labels (width × height × depth) at
## the selection's bounding box and the status/help text lines.

const COLOR_DIMENSION := Color(1.0, 1.0, 1.0, 0.95)
const COLOR_SHADOW := Color(0.0, 0.0, 0.0, 0.8)
const FONT_SIZE: float = 13.0
## Labels shorter than this on screen (px) are skipped.
const MIN_EDGE_PIXELS: float = 24.0


## Labels the three bounding-box edges nearest to the camera.
static func draw(overlay: Control, camera: Camera3D, brushes: Array[TFBrush]) -> void:
	if brushes.is_empty():
		return
	var box := TFPicking.brushes_aabb(brushes)
	var eye := camera.global_position
	var center := box.get_center()
	# Corner on the camera side in x and z, at the bottom.
	var near := Vector3(
		box.end.x if eye.x > center.x else box.position.x,
		box.position.y,
		box.end.z if eye.z > center.z else box.position.z)
	var far_x := box.position.x if near.x == box.end.x else box.end.x
	var far_z := box.position.z if near.z == box.end.z else box.end.z
	_label(overlay, camera, near, Vector3(far_x, near.y, near.z), box.size.x)
	_label(overlay, camera, near, Vector3(near.x, near.y, far_z), box.size.z)
	_label(overlay, camera, near, Vector3(near.x, box.end.y, near.z), box.size.y)


static func _label(overlay: Control, camera: Camera3D, a: Vector3, b: Vector3, length: float) -> void:
	if camera.is_position_behind(a) or camera.is_position_behind(b) or is_zero_approx(length):
		return
	var pa := camera.unproject_position(a)
	var pb := camera.unproject_position(b)
	if pa.distance_to(pb) < MIN_EDGE_PIXELS * EditorInterface.get_editor_scale():
		return
	var font := ThemeDB.fallback_font
	var size := int(FONT_SIZE * EditorInterface.get_editor_scale())
	var text := "%s m" % TFTool.format_length(length)
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	var pos := (pa + pb) * 0.5 - Vector2(text_size.x * 0.5, -size * 0.35)
	overlay.draw_rect(Rect2(pos - Vector2(4, size), text_size + Vector2(8, 6)), Color(0, 0, 0, 0.55))
	overlay.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, COLOR_DIMENSION)


## Label next to the mouse cursor (below right of the pointer).
static func draw_cursor_label(overlay: Control, text: String) -> void:
	if text.is_empty():
		return
	var scale := EditorInterface.get_editor_scale()
	var font := ThemeDB.fallback_font
	var size := int(FONT_SIZE * scale)
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	var pos := overlay.get_local_mouse_position() + Vector2(18, 28) * scale
	# Keep the label inside the viewport.
	pos.x = minf(pos.x, overlay.size.x - text_size.x - 8.0)
	pos.y = minf(pos.y, overlay.size.y - 8.0)
	overlay.draw_rect(Rect2(pos - Vector2(4, size), text_size + Vector2(8, 6)), Color(0, 0, 0, 0.55))
	overlay.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, COLOR_DIMENSION)


## Text lines at the bottom left of the viewport (info, status, help).
static func draw_lines(overlay: Control, lines: Array[String]) -> void:
	var font := ThemeDB.fallback_font
	var size := int(FONT_SIZE * EditorInterface.get_editor_scale())
	var line_height := size + 6
	var y := overlay.size.y - 12.0 - line_height * (lines.size() - 1)
	for line in lines:
		var pos := Vector2(12, y)
		overlay.draw_string(font, pos + Vector2(1, 1), line, HORIZONTAL_ALIGNMENT_LEFT, -1, size, COLOR_SHADOW)
		overlay.draw_string(font, pos, line, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(1, 1, 1, 0.9))
		y += line_height
