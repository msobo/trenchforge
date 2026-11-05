@tool
class_name TFFace
extends Resource
## One bounding plane of a TFBrush plus its material and UV attributes.
##
## The plane is stored in brush-local space with its normal pointing outward.
## UV axes are Valve-220 style and refer to map space (see TFUV).

## Face produces no render geometry (collision is unaffected).
const FLAG_NODRAW: int = 1

@export var plane: Plane = Plane(Vector3.UP, 0.0):
	set(value):
		plane = value
		emit_changed()

@export var material: Material:
	set(value):
		material = value
		emit_changed()

@export var u_axis: Vector3 = Vector3.RIGHT:
	set(value):
		u_axis = value
		emit_changed()

@export var v_axis: Vector3 = Vector3.DOWN:
	set(value):
		v_axis = value
		emit_changed()

## Texture offset in pixels.
@export var uv_offset: Vector2 = Vector2.ZERO:
	set(value):
		uv_offset = value
		emit_changed()

@export var uv_scale: Vector2 = Vector2.ONE:
	set(value):
		uv_scale = value
		emit_changed()

## Rotation of the UV axes around the face normal, in degrees.
@export var uv_rotation: float = 0.0:
	set(value):
		uv_rotation = value
		emit_changed()

## Bit flags, see FLAG_*.
@export_flags("Nodraw") var flags: int = 0:
	set(value):
		flags = value
		emit_changed()


static func create(p_plane: Plane, p_material: Material = null) -> TFFace:
	var face := TFFace.new()
	face.plane = p_plane
	face.material = p_material
	face.reset_uv_axes()
	return face


## Resets the UV axes to the box-projection defaults for the current normal.
func reset_uv_axes() -> void:
	var axes := TFUV.default_axes(plane.normal)
	u_axis = axes[0]
	v_axis = axes[1]


## True if the face is skipped in render output: nodraw flag or one of the
## special materials tf_nodraw / tf_clip.
func is_nodraw() -> bool:
	if flags & FLAG_NODRAW:
		return true
	return material != null and is_special_material(material)


static func is_special_material(value: Material) -> bool:
	return value.resource_path == TFConst.MATERIAL_NODRAW_PATH or value.resource_path == TFConst.MATERIAL_CLIP_PATH


func copy() -> TFFace:
	return duplicate(false) as TFFace
