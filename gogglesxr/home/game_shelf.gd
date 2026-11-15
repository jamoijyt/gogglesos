extends Node3D
## The game shelf and the VHS corner: every VR game is a VHS tape in its box, standing face out
## on the shelf by the right-hand wall, like a video shop. Point at one to see its name; hold
## grip to take it; put it into the VHS player next to the shelf and the game starts (the TV on
## top shows what's loading). Letting go anywhere else puts it back on the shelf.
##
## The games come from the same list as the dashboard's Library panel (steam_library.gd, which
## `gogglesxr home` brings along from the dashboard).

signal started(name: String)              # a tape went into the player and the game is starting

var SteamLibrary: Script = load("res://steam_library.gd") if ResourceLoader.exists("res://steam_library.gd") else null
const LAYER := 8
const CASE := Vector3(0.15, 0.255, 0.034)   # a VHS box (a bit bigger than a real one, to read from afar)
const TAPE := Vector3(0.187, 0.103, 0.025)  # the tape itself
const GAP := 0.03
const COVER_PIXELS := Vector2i(300, 510)
const SLOT_REACH := 0.22                    # how close to the slot a tape has to come

var cases: Array[StaticBody3D] = []
var _homes := {}                          # case -> Transform3D on the shelf
var _label: Label3D
var _hint: Label3D
var player: Node3D                        # the VHS player
var slot: Node3D                          # its tape slot (front, facing -X)
var tv_screen: MeshInstance3D
var display: Label3D                      # the player's little clock display
var _loading := false
var _noise: ShaderMaterial

const NOISE_SHADER := """
shader_type spatial;
render_mode unshaded;
uniform sampler2D picture : source_color;
uniform float has_picture = 0.0;
uniform float glow = 1.0;
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	vec2 uv = UV;
	// an old TV: scan lines, a little roll, snow when there's nothing to show
	float lines = 0.86 + 0.14 * sin(uv.y * 520.0);
	float snow = hash(floor(uv * vec2(160.0, 120.0)) + floor(TIME * 24.0));
	vec3 tv = mix(vec3(snow * 0.55), texture(picture, uv).rgb, has_picture);
	float edge = smoothstep(0.0, 0.06, uv.x) * smoothstep(1.0, 0.94, uv.x) * smoothstep(0.0, 0.07, uv.y) * smoothstep(1.0, 0.93, uv.y);
	ALBEDO = tv * lines * edge * glow;
}
"""


func _init() -> void:
	_label = Label3D.new()
	_label.pixel_size = 0.0009
	_label.font_size = 56
	_label.outline_size = 12
	_label.outline_modulate = Color(0, 0, 0, 0.8)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.render_priority = 10
	_label.visible = false
	add_child(_label)
	_hint = Label3D.new()
	_hint.pixel_size = 0.0006
	_hint.font_size = 48
	_hint.outline_size = 10
	_hint.outline_modulate = Color(0, 0, 0, 0.8)
	_hint.modulate = Color("9fbfb4")
	_hint.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hint.no_depth_test = true
	_hint.render_priority = 10
	_hint.visible = false
	add_child(_hint)


static func _paint(colour: Color, glow := 0.0, rough := 0.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	m.roughness = rough
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = colour
		m.emission_energy_multiplier = glow
	return m


static func _box(size: Vector3, at: Vector3, paint: Material, parent: Node3D) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = paint
	node.position = at
	parent.add_child(node)
	return node


## Fill the shelf. `boards`: the shelf's boards (bottom first), each a box lying along Z whose
## front faces -X. `games`: [{"name", "launch", "art"}]; the library's when left out.
func fill(boards: Array, games: Array = []) -> void:
	for old in cases:
		old.queue_free()
	cases.clear()
	_homes.clear()
	if games.is_empty() and SteamLibrary:
		games = SteamLibrary.games()
	if boards.is_empty():
		return
	var length: float = ((boards[0] as MeshInstance3D).mesh as BoxMesh).size.z - 0.2
	var per_board := maxi(1, int(floor(length / (CASE.x + GAP))))
	# the board at eye height first, then the one below it, then the top and the bottom
	var order := boards.duplicate()
	if order.size() >= 4:
		order = [boards[2], boards[1], boards[3], boards[0]] + boards.slice(4)
	var index := 0
	for game in games:
		var board_index := index / per_board
		if board_index >= order.size():
			break
		var board: Node3D = order[board_index]
		var slot_index := index % per_board
		var z := -length / 2.0 + CASE.x / 2.0 + slot_index * (CASE.x + GAP)
		var top: float = board.global_position.y + 0.02
		# standing on the board, leaning back a little, cover facing into the room (-X)
		var basis := Basis(Vector3.UP, -PI / 2).rotated(Vector3.BACK, deg_to_rad(-8))
		var spot := Transform3D(basis, Vector3(board.global_position.x - 0.04, top + CASE.y / 2.0, board.global_position.z + z))
		var case := _make_case(game)
		add_child(case)
		case.global_transform = spot
		_homes[case] = spot
		cases.append(case)
		index += 1


## A VHS box: black plastic, the cover in the sleeve, "VHS" on the spine.
func _make_case(game: Dictionary) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = LAYER
	body.set_meta("game", game)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = CASE + Vector3(0.01, 0.01, 0.02)
	shape.shape = box
	body.add_child(shape)
	_box(CASE, Vector3.ZERO, _paint(Color(0.03, 0.03, 0.035), 0.0, 0.3), body)
	# a clear sleeve over the cover: a little shine
	var front := MeshInstance3D.new()
	front.name = "Cover"
	var quad := QuadMesh.new()
	quad.size = Vector2(CASE.x - 0.01, CASE.y - 0.01)
	front.mesh = quad
	front.position.z = CASE.z / 2.0 + 0.0008
	var print_ := StandardMaterial3D.new()
	print_.roughness = 0.18
	print_.metallic_specular = 0.8
	var art: Texture2D = SteamLibrary.cover(str(game.get("art", "")), COVER_PIXELS) if SteamLibrary else null
	if art:
		print_.albedo_texture = art
		print_.emission_enabled = true        # readable in a dim room
		print_.emission_texture = art
		print_.emission_energy_multiplier = 0.3
	else:
		print_.albedo_color = Color(0.09, 0.36, 0.33)
		var title := Label3D.new()            # no picture: the name on the cover
		title.text = str(game.get("name", "Game"))
		title.pixel_size = 0.0005
		title.font_size = 44
		title.width = 260
		title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		title.outline_size = 0
		title.position.z = CASE.z / 2.0 + 0.0015
		body.add_child(title)
	front.material_override = print_
	body.add_child(front)
	# the VHS badge in a corner of the sleeve, and on the spine
	for at in [[Vector3(CASE.x / 2 - 0.022, CASE.y / 2 - 0.014, CASE.z / 2 + 0.0016), 0.0], [Vector3(CASE.x / 2 + 0.0016, CASE.y / 2 - 0.03, 0), PI / 2]]:
		var badge := Label3D.new()
		badge.text = "VHS"
		badge.font_size = 40
		badge.pixel_size = 0.00045
		badge.outline_size = 6
		badge.outline_modulate = Color.BLACK
		badge.modulate = Color.WHITE
		badge.position = at[0]
		badge.rotation.y = at[1]
		body.add_child(badge)
	return body


## Show a game's name over its box (or hide it, for null).
func point_at(case: Node3D, held := false) -> void:
	_label.visible = case != null
	_hint.visible = case != null
	if case == null:
		return
	_label.text = str(case.get_meta("game").get("name", ""))
	_hint.text = "Put it in the VHS player to play  ·  let go: back on the shelf" if held else "Hold grip: take the tape"
	_label.global_position = case.global_position + Vector3.UP * (CASE.y / 2.0 + 0.085)
	_hint.global_position = case.global_position + Vector3.UP * (CASE.y / 2.0 + 0.035)


func home_of(case: Node3D) -> Transform3D:
	return _homes.get(case, case.global_transform)


## Slide a box back to its place.
func put_back(case: Node3D) -> void:
	if not is_instance_valid(case):
		return
	var t := case.create_tween()
	t.tween_property(case, "global_transform", home_of(case), 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func play(case: Node3D) -> bool:
	return SteamLibrary != null and SteamLibrary.launch(str(case.get_meta("game").get("launch", "")))


# ------------------------------------------------------------------ the VHS corner
## A low cabinet with the VHS player on it and an old TV on top, at `at`, facing -X (into the
## room). `tv_model`: a loaded TV model to stand on top (or null for a made one).
func build_corner(at: Vector3, tv_model: Node3D) -> void:
	var corner := StaticBody3D.new()
	corner.name = "VhsCorner"
	corner.collision_layer = 2
	corner.position = at
	corner.rotation.y = -PI / 2               # its front (+Z) faces -X
	add_child(corner)
	var wood := _paint(Color(0.16, 0.11, 0.07), 0.0, 0.55)
	_box(Vector3(0.95, 0.5, 0.48), Vector3(0, 0.25, 0), wood, corner)
	var solid := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.95, 0.6, 0.48)
	solid.shape = box
	solid.position.y = 0.3
	corner.add_child(solid)
	# the player: a silver-black box with a slot, buttons and a green clock
	player = Node3D.new()
	player.name = "VhsPlayer"
	player.position = Vector3(0, 0.5, 0.02)
	corner.add_child(player)
	_box(Vector3(0.43, 0.09, 0.3), Vector3(0, 0.045, 0), _paint(Color(0.13, 0.13, 0.14), 0.0, 0.35), player)
	_box(Vector3(0.43, 0.004, 0.3), Vector3(0, 0.092, 0), _paint(Color(0.22, 0.22, 0.24), 0.0, 0.25), player)
	_box(Vector3(0.21, 0.035, 0.004), Vector3(-0.07, 0.05, 0.151), _paint(Color(0.02, 0.02, 0.02), 0.0, 0.2), player)   # the flap
	slot = Node3D.new()
	slot.name = "Slot"
	slot.position = Vector3(-0.07, 0.05, 0.16)
	player.add_child(slot)
	display = Label3D.new()
	display.text = "12:00"
	display.font_size = 40
	display.pixel_size = 0.0006
	display.modulate = Color("5dff9a")
	display.outline_size = 0
	display.position = Vector3(0.12, 0.05, 0.153)
	player.add_child(display)
	_box(Vector3(0.07, 0.025, 0.003), Vector3(0.12, 0.05, 0.1515), _paint(Color(0.01, 0.03, 0.02)), player)
	for i in 4:
		_box(Vector3(0.022, 0.012, 0.006), Vector3(0.07 + i * 0.03, 0.02, 0.152), _paint(Color(0.3, 0.3, 0.32), 0.0, 0.3), player)
	var badge := Label3D.new()
	badge.text = "VHS  ▶ HiFi STEREO"
	badge.font_size = 24
	badge.pixel_size = 0.0005
	badge.modulate = Color(0.85, 0.85, 0.85)
	badge.outline_size = 0
	badge.position = Vector3(-0.12, 0.078, 0.153)
	player.add_child(badge)
	var power := _box(Vector3(0.008, 0.008, 0.004), Vector3(0.195, 0.075, 0.152), _paint(Color("ff3030"), 2.0), player)
	power.name = "Power"
	# the TV on top
	var tv := Node3D.new()
	tv.name = "Tv"
	tv.position = Vector3(0, 0.6, -0.02)
	corner.add_child(tv)
	var screen_size := Vector2(0.42, 0.32)
	var screen_at := Vector3(0, 0.22, 0.2)
	if tv_model:
		var model := tv_model.duplicate() as Node3D
		tv.add_child(model)
		var bounds := _bounds(model)
		model.position = Vector3(-bounds.get_center().x, -bounds.position.y, -bounds.get_center().z)
		screen_size = Vector2(bounds.size.x * 0.62, bounds.size.y * 0.6)
		screen_at = Vector3(0, bounds.size.y * 0.55, bounds.size.z / 2.0 + 0.004)
	else:
		_box(Vector3(0.6, 0.46, 0.45), Vector3(0, 0.23, 0), _paint(Color(0.18, 0.17, 0.16)), tv)
	tv_screen = MeshInstance3D.new()
	tv_screen.name = "Screen"
	var quad := QuadMesh.new()
	quad.size = screen_size
	tv_screen.mesh = quad
	tv_screen.position = screen_at
	_noise = ShaderMaterial.new()
	_noise.shader = Shader.new()
	_noise.shader.code = NOISE_SHADER
	tv_screen.material_override = _noise
	tv.add_child(tv_screen)
	var sign := Label3D.new()
	sign.text = "INSERT TAPE"
	sign.name = "Sign"
	sign.font_size = 64
	sign.pixel_size = 0.0006
	sign.modulate = Color(0.9, 0.95, 1.0)
	sign.outline_size = 8
	sign.position = screen_at + Vector3(0, 0, 0.004)
	tv.add_child(sign)


static func _bounds(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mesh in node.find_children("*", "MeshInstance3D", true, false):
		var m := mesh as MeshInstance3D
		if m.mesh == null:
			continue
		var to_root := Transform3D.IDENTITY
		var n: Node3D = m
		while n != node and n != null:
			to_root = n.transform * to_root
			n = n.get_parent() as Node3D
		var part := to_root * m.mesh.get_aabb()
		box = part if first else box.merge(part)
		first = false
	return box


func _process(_delta: float) -> void:
	if display and not _loading:
		var now := Time.get_time_dict_from_system()
		display.text = ("%02d:%02d" % [now.hour, now.minute]) if now.second % 2 == 0 else ("%02d %02d" % [now.hour, now.minute])


## Whether a box held at `where` is close enough to go into the player.
func near_slot(where: Vector3) -> bool:
	return slot != null and not _loading and where.distance_to(slot.global_position) < SLOT_REACH


## Light up the slot while a tape is near it.
func show_slot(on: bool) -> void:
	if player:
		(player.get_node("Power") as MeshInstance3D).material_override = _paint(Color("5dff9a") if on else Color("ff3030"), 2.0)


## Push a game's tape into the player: it slides in, the TV shows the game, and it starts.
func insert(case: Node3D) -> void:
	if _loading or slot == null:
		return
	_loading = true
	var game: Dictionary = case.get_meta("game")
	# the tape (black, with a white label and two reels) slides out of the box into the slot
	var tape := Node3D.new()
	add_child(tape)
	_box(TAPE, Vector3.ZERO, _paint(Color(0.04, 0.04, 0.045), 0.0, 0.35), tape)
	_box(Vector3(0.1, 0.045, 0.002), Vector3(0, 0.012, TAPE.z / 2 + 0.001), _paint(Color(0.94, 0.94, 0.9)), tape)
	for x in [-0.045, 0.045]:
		var reel := MeshInstance3D.new()
		var round_mesh := CylinderMesh.new()
		round_mesh.top_radius = 0.016
		round_mesh.bottom_radius = 0.016
		round_mesh.height = 0.003
		reel.mesh = round_mesh
		reel.material_override = _paint(Color(0.85, 0.85, 0.85))
		reel.rotation.x = PI / 2
		reel.position = Vector3(x, -0.022, TAPE.z / 2 + 0.001)
		tape.add_child(reel)
	var into := slot.global_transform
	var flat := Transform3D(into.basis * Basis(Vector3.RIGHT, -PI / 2), into.origin + into.basis.z * 0.12)
	tape.global_transform = flat
	var t := tape.create_tween()
	t.tween_property(tape, "global_transform", Transform3D(flat.basis, into.origin - into.basis.z * 0.12), 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	t.tween_callback(tape.queue_free)
	put_back(case)
	display.text = "PLAY"
	show_slot(false)
	var art: Texture2D = SteamLibrary.cover(str(game.get("art", "")), Vector2i(320, 240)) if SteamLibrary else null
	if art:
		_noise.set_shader_parameter("picture", art)
		_noise.set_shader_parameter("has_picture", 1.0)
	var sign := tv_screen.get_parent().get_node("Sign") as Label3D
	sign.text = "▶ PLAY\n" + str(game.get("name", ""))
	var started_ok := play(case)
	started.emit(str(game.get("name", "")) if started_ok else "")
	await get_tree().create_timer(6.0).timeout
	# still here (the game didn't take over): back to waiting
	_loading = false
	_noise.set_shader_parameter("has_picture", 0.0)
	sign.text = "INSERT TAPE"
