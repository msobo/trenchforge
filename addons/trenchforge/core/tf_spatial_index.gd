class_name TFSpatialIndex
extends RefCounted
## Broad phase for picking and overlap searches: world AABBs of brushes in a
## uniform hash grid. Rebuilt as a whole (cheap) whenever brushes change.

## Cell key of brushes too large for the grid.
const OVERFLOW_CELL := Vector3i(0x7fffffff, 0, 0)

var _brushes: Array[TFBrush] = []
var _boxes: Array[AABB] = []
var _cells := {}  # Vector3i -> PackedInt32Array of brush indices
var _cell_size := TFConst.SPATIAL_CELL_SIZE


func rebuild(brushes: Array[TFBrush], cell_size: float = TFConst.SPATIAL_CELL_SIZE) -> void:
	_brushes = []
	_boxes = []
	_cells = {}
	_cell_size = cell_size
	for brush in brushes:
		if not brush.is_valid():
			continue
		var box := (brush.global_transform * brush.get_local_aabb()).grow(TFConst.EPSILON)
		var index := _brushes.size()
		_brushes.append(brush)
		_boxes.append(box)
		var from := _cell_of(box.position)
		var to := _cell_of(box.end)
		# Huge brushes (skyboxes) would fill thousands of cells; they go
		# into every query through the overflow list instead.
		if _cell_count(from, to) > TFConst.SPATIAL_MAX_CELLS:
			_add_to_cell(OVERFLOW_CELL, index)
			continue
		for x in range(from.x, to.x + 1):
			for y in range(from.y, to.y + 1):
				for z in range(from.z, to.z + 1):
					_add_to_cell(Vector3i(x, y, z), index)


func size() -> int:
	return _brushes.size()


## Brushes whose bounding box the ray hits, nearest box entry first.
func query_ray(origin: Vector3, direction: Vector3) -> Array[TFBrush]:
	var entries: Array = []
	for i in _boxes.size():
		var box := _boxes[i]
		if box.has_point(origin):
			entries.append([0.0, i])
			continue
		var hit: Variant = box.intersects_ray(origin, direction)
		if hit != null:
			entries.append([(hit as Vector3).distance_squared_to(origin), i])
	entries.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var result: Array[TFBrush] = []
	for entry in entries:
		result.append(_brushes[entry[1]])
	return result


## Brushes whose bounding box intersects or touches box (world space).
func query_aabb(box: AABB) -> Array[TFBrush]:
	var grown := box.grow(TFConst.EPSILON)
	var seen := {}
	var result: Array[TFBrush] = []
	var candidates: Array[PackedInt32Array] = []
	var overflow: Variant = _cells.get(OVERFLOW_CELL)
	if overflow != null:
		candidates.append(overflow)
	var from := _cell_of(grown.position)
	var to := _cell_of(grown.end)
	if _cell_count(from, to) > _cells.size():
		# Query larger than the populated grid: test every brush directly.
		candidates.clear()
		candidates.append(PackedInt32Array(range(_brushes.size())))
	else:
		for x in range(from.x, to.x + 1):
			for y in range(from.y, to.y + 1):
				for z in range(from.z, to.z + 1):
					var cell: Variant = _cells.get(Vector3i(x, y, z))
					if cell != null:
						candidates.append(cell)
	for cell in candidates:
		for i in cell:
			if seen.has(i):
				continue
			seen[i] = true
			if boxes_touch(_boxes[i], grown):
				result.append(_brushes[i])
	return result


func _add_to_cell(cell: Vector3i, index: int) -> void:
	if not _cells.has(cell):
		_cells[cell] = PackedInt32Array()
	var list: PackedInt32Array = _cells[cell]
	list.append(index)
	_cells[cell] = list


func _cell_of(point: Vector3) -> Vector3i:
	return Vector3i((point / _cell_size).floor())


static func _cell_count(from: Vector3i, to: Vector3i) -> int:
	var extent := to - from + Vector3i.ONE
	return extent.x * extent.y * extent.z


## AABB.intersects() is strict; boxes sharing a face count as touching here.
static func boxes_touch(a: AABB, b: AABB) -> bool:
	for i in 3:
		if a.position[i] > b.end[i] or b.position[i] > a.end[i]:
			return false
	return true
