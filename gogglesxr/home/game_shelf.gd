extends Node3D
## The game shelf: every VR game as a case with its Steam cover on the front, standing on the
## shelf by the right-hand wall. Point at one to see its name; hold grip to take it in your
## hand; pull the trigger while holding it to start the game; let go to put it back.
##
## The games come from the same list as the dashboard's Library panel (steam_library.gd, which
## `gogglesxr home` brings along from the dashboard).

var SteamLibrary: Script = load("res://steam_library.gd") if ResourceLoader.exists("res://steam_library.gd") else null
const LAYER := 8
const CASE := Vector3(0.19, 0.27, 0.026)    # width, height, thickness: bigger than a real case, to read from across the room
const GAP := 0.028
const COVER_PIXELS := Vector2i(300, 426)

var cases: Array[StaticBody3D] = []
var _homes := {}                          # case -> Transform3D on the shelf (local to this node)
var _label: Label3D
var _hint: Label3D


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
		var slot := index % per_board
		var z := -length / 2.0 + CASE.x / 2.0 + slot * (CASE.x + GAP)
		var top: float = board.global_position.y + 0.02
		# standing on the board, leaning back a little, cover facing into the room (-X)
		var basis := Basis(Vector3.UP, -PI / 2).rotated(Vector3.BACK, deg_to_rad(-8))
		var home := Transform3D(basis, Vector3(board.global_position.x - 0.04, top + CASE.y / 2.0, board.global_position.z + z))
		var case := _make_case(game)
		add_child(case)
		case.global_transform = home
		_homes[case] = home
		cases.append(case)
		index += 1


func _make_case(game: Dictionary) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = LAYER
	body.set_meta("game", game)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = CASE + Vector3(0.01, 0.01, 0.02)
	shape.shape = box
	body.add_child(shape)
	var shell := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = CASE
	shell.mesh = mesh
	var plastic := StandardMaterial3D.new()
	plastic.albedo_color = Color(0.05, 0.1, 0.09)
	plastic.roughness = 0.35
	shell.material_override = plastic
	body.add_child(shell)
	var front := MeshInstance3D.new()
	front.name = "Cover"
	var quad := QuadMesh.new()
	quad.size = Vector2(CASE.x - 0.008, CASE.y - 0.008)
	front.mesh = quad
	front.position.z = CASE.z / 2.0 + 0.0006
	var print_ := StandardMaterial3D.new()
	print_.roughness = 0.45
	var art: Texture2D = SteamLibrary.cover(str(game.get("art", "")), COVER_PIXELS) if SteamLibrary else null
	if art:
		print_.albedo_texture = art
		print_.emission_enabled = true        # readable in a dim room
		print_.emission_texture = art
		print_.emission_energy_multiplier = 0.35
	else:
		print_.albedo_color = Color(0.09, 0.36, 0.33)
		var title := Label3D.new()            # no picture: the name on the cover
		title.text = str(game.get("name", "Game"))
		title.pixel_size = 0.0005
		title.font_size = 40
		title.width = 250
		title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		title.outline_size = 0
		title.position.z = CASE.z / 2.0 + 0.0015
		body.add_child(title)
	front.material_override = print_
	body.add_child(front)
	return body


## Show a game's name over its case (or hide it, for null).
func point_at(case: Node3D, held := false) -> void:
	_label.visible = case != null
	_hint.visible = case != null
	if case == null:
		return
	_label.text = str(case.get_meta("game").get("name", ""))
	_hint.text = "Trigger: play  ·  let go: put back" if held else "Hold grip: pick up"
	_label.global_position = case.global_position + Vector3.UP * (CASE.y / 2.0 + 0.085)
	_hint.global_position = case.global_position + Vector3.UP * (CASE.y / 2.0 + 0.03)


func home_of(case: Node3D) -> Transform3D:
	return _homes.get(case, case.global_transform)


## Slide a case back to its place.
func put_back(case: Node3D) -> void:
	if not is_instance_valid(case):
		return
	var t := case.create_tween()
	t.tween_property(case, "global_transform", home_of(case), 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func play(case: Node3D) -> bool:
	return SteamLibrary != null and SteamLibrary.launch(str(case.get_meta("game").get("launch", "")))
