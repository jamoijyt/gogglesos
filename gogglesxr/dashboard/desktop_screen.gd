extends Node3D
## One floating screen of the PC's desktop: a monitor (or the whole desktop) hanging in the air
## wherever you put it, with a handle bar underneath.
##
## Point the laser at the picture to use it: the PC's pointer follows, trigger clicks, the B/Y
## button right-clicks and the stick scrolls (main.gd does that through desktop_input.gd).
## Hold grip on the screen or its bar to carry it; while carrying, push the stick forward or
## back to send it further away or closer, and left or right to make it smaller or bigger.
## The bar's buttons open the keyboard under this screen, and close the screen.

const BAR_HEIGHT := 0.1                   # metres
const BAR_GAP := 0.02
const MIN_WIDTH := 0.5
const MAX_WIDTH := 6.0
const ACCENT := Color("3ddc84")
const INK := Color("e6f3ee")

var title := "Desktop"
var region := Rect2(0, 0, 1, 1)           # which part of the desktop picture, in 0..1
var width := 2.4                          # metres
var aspect := 9.0 / 16.0                  # height / width of this part of the desktop
var quad: MeshInstance3D
var frame: MeshInstance3D
var bar: MeshInstance3D
var label: Label3D
var buttons := {}                         # "keyboard" / "close" -> MeshInstance3D
var _material: StandardMaterial3D
var _grab_local := Vector3.ZERO
var _grab_reach := 1.0
var hovered := ""                         # what the laser is on: "", "screen", "bar", "keyboard", "close"


func _init(screen_title := "Desktop", screen_region := Rect2(0, 0, 1, 1)) -> void:
	title = screen_title
	region = screen_region
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.uv1_scale = Vector3(region.size.x, region.size.y, 1)
	_material.uv1_offset = Vector3(region.position.x, region.position.y, 0)
	_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	quad = MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.material_override = _material
	add_child(quad)
	# a thin glowing frame behind the picture
	frame = MeshInstance3D.new()
	frame.mesh = QuadMesh.new()
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow.albedo_color = Color(ACCENT, 0.35)
	frame.material_override = glow
	frame.position.z = -0.004
	add_child(frame)
	bar = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1, BAR_HEIGHT, 0.01)
	bar.mesh = box
	var dark := StandardMaterial3D.new()
	dark.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dark.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dark.albedo_color = Color(0.016, 0.07, 0.06, 0.92)
	bar.material_override = dark
	add_child(bar)
	label = Label3D.new()
	label.pixel_size = 0.0009
	label.font_size = 64
	label.outline_size = 0
	label.modulate = INK
	label.text = "⠿  " + title
	add_child(label)
	for id in ["keyboard", "close"]:
		var button := MeshInstance3D.new()
		var face := QuadMesh.new()
		face.size = Vector2(BAR_HEIGHT * 2.6, BAR_HEIGHT * 0.78)
		button.mesh = face
		var paint := StandardMaterial3D.new()
		paint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		paint.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		paint.albedo_color = Color(1, 1, 1, 0.08)
		button.material_override = paint
		var text := Label3D.new()
		text.pixel_size = 0.0007
		text.font_size = 52
		text.outline_size = 0
		text.modulate = INK
		text.text = "Keyboard" if id == "keyboard" else "Close"
		text.position.z = 0.002
		button.add_child(text)
		add_child(button)
		buttons[id] = button
	_layout()


func set_texture(texture: Texture2D) -> void:
	_material.albedo_texture = texture
	if texture:
		var size := texture.get_size() * region.size
		if size.x > 0:
			aspect = size.y / size.x
	_layout()


func _layout() -> void:
	var height := width * aspect
	(quad.mesh as QuadMesh).size = Vector2(width, height)
	(frame.mesh as QuadMesh).size = Vector2(width + 0.024, height + 0.024)
	(bar.mesh as BoxMesh).size = Vector3(width, BAR_HEIGHT, 0.01)
	bar.position = Vector3(0, -height / 2.0 - BAR_GAP - BAR_HEIGHT / 2.0, 0)
	label.position = Vector3(-width / 4.0, bar.position.y, 0.007)    # Label3D centres its text here
	var x := width / 2.0 - 0.02
	for id in ["close", "keyboard"]:
		var button: MeshInstance3D = buttons[id]
		var w: float = (button.mesh as QuadMesh).size.x
		button.position = Vector3(x - w / 2.0, bar.position.y, 0.007)
		x -= w + 0.015


## Where a ray meets this screen: {} if it misses, else {"distance", "point", "part", "uv"}.
## uv is the spot on the picture (0..1, top-left origin) when part is "screen".
func hit(from: Vector3, dir: Vector3) -> Dictionary:
	if not visible:
		return {}
	var plane := Plane(global_transform.basis.z.normalized(), global_position)
	var point: Variant = plane.intersects_ray(from, dir)
	if point == null:
		return {}
	var local: Vector3 = global_transform.affine_inverse() * point
	var height := width * aspect
	var result := {"distance": from.distance_to(point), "point": point, "part": "", "uv": Vector2.ZERO}
	if absf(local.x) <= width / 2.0 and absf(local.y) <= height / 2.0:
		result.part = "screen"
		result.uv = Vector2(local.x / width + 0.5, 0.5 - local.y / height)
		return result
	var bar_y := bar.position.y
	if absf(local.x) <= width / 2.0 and absf(local.y - bar_y) <= BAR_HEIGHT / 2.0:
		result.part = "bar"
		for id in buttons:
			var button: MeshInstance3D = buttons[id]
			var half: Vector2 = (button.mesh as QuadMesh).size / 2.0
			if absf(local.x - button.position.x) <= half.x and absf(local.y - button.position.y) <= half.y:
				result.part = id
		return result
	return {}


## The point of the whole desktop (0..1) under a spot of this screen's picture.
func desktop_point(uv: Vector2) -> Vector2:
	return region.position + uv * region.size


## Highlight what the laser is on.
func set_hovered(part: String) -> void:
	if part == hovered:
		return
	hovered = part
	for id in buttons:
		((buttons[id] as MeshInstance3D).material_override as StandardMaterial3D).albedo_color = \
				Color(ACCENT, 0.45) if id == part else Color(1, 1, 1, 0.08)
	(frame.material_override as StandardMaterial3D).albedo_color = Color(ACCENT, 0.7 if part != "" else 0.35)


# ------------------------------------------------------------------ carrying it
func begin_grab(from: Vector3, point: Vector3) -> void:
	_grab_local = global_transform.affine_inverse() * point
	_grab_reach = from.distance_to(point)


## Keep the grabbed spot on the laser, facing the head. `push` (stick y) moves it along the
## laser; `grow` (stick x) changes its size.
func update_grab(from: Vector3, dir: Vector3, head: Vector3, push: float, grow: float, delta: float) -> void:
	if absf(push) > 0.25:
		_grab_reach = clampf(_grab_reach + push * 1.6 * delta * maxf(_grab_reach, 0.6), 0.5, 8.0)
	if absf(grow) > 0.4:
		var before := width
		width = clampf(width * (1.0 + grow * 0.8 * delta), MIN_WIDTH, MAX_WIDTH)
		_grab_local *= width / before
		_layout()
	var spot := from + dir * _grab_reach
	for i in 2:                           # facing depends on where it ends up: settle it
		var facing := global_position - head
		if facing.length() < 0.05:
			facing = Vector3.FORWARD
		facing = facing.normalized()
		var up := Vector3.UP if absf(facing.dot(Vector3.UP)) < 0.95 else Vector3.BACK
		var basis := Basis.looking_at(facing, up)
		global_transform = Transform3D(basis, spot - basis * _grab_local)


## Stand `distance` metres away from `head` in direction `forward`, `lift` metres higher.
func place(head: Vector3, forward: Vector3, distance: float, lift := 0.0) -> void:
	var at := head + forward.normalized() * distance + Vector3.UP * lift
	global_transform = Transform3D(Basis.looking_at(forward.normalized(), Vector3.UP), at)


func save_state() -> Dictionary:
	return {"transform": global_transform, "width": width}


func load_state(state: Dictionary) -> void:
	if state.get("transform") is Transform3D:
		global_transform = state.transform
	width = clampf(float(state.get("width", width)), MIN_WIDTH, MAX_WIDTH)
	_layout()
