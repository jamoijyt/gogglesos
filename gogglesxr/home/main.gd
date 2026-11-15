extends Node3D
## Goggles Home: where you are when the headset is on and no game is running.
##
## A normal VR app (the GogglesXR dashboard draws on top of it, as it does over a game). The
## GogglesXR desktop app starts it when a headset connects, and it steps aside by itself: as
## soon as a VR game starts it fades out and quits, so the game gets the headset; the desktop
## app starts it again when the game has gone. It also leaves when the headset disconnects.
##
## The house (room.gd) has a living room and, up the stairs, a bedroom. You can:
##   - move: stick forward teleports where you point, stick sideways turns (Settings: smooth
##     walking); the stairs, or the green pads, take you between the floors
##   - open the Home menu with B or Y (home_menu.gd): furniture, gadgets, toys and pets, your
##     own pictures as posters, the look of the house, settings, the tour (tutorial.gd)
##   - pick things up with grip (furniture.gd): furniture slides over the floor and onto other
##     furniture, wall things hang on walls, the stick turns them, A or X removes them; toys
##     can be thrown; gadgets work with the trigger in your hand (gadgets.gd)
##   - use things with the trigger: lamps, light switches, TVs (they show the PC's desktop),
##     the radio, pets, neon signs, arcade machines
##   - play a game: take its VHS tape from the shelf and put it in the VHS player (game_shelf.gd)
## Your hands (hands.gd) follow the controllers' grip and trigger. While the dashboard is open,
## Home leaves the controllers to it. The house is remembered in ~/.config/gogglesxr/home.json.
##
## Test hooks (environment variables):
## GOGGLESXR_SHOT=/path/out.png  save a picture of the window after a moment, then quit
## GOGGLESXR_LOOK=degrees        desktop preview: turn the camera (0 faces the glass wall)
## GOGGLESXR_AT=x,y,z            desktop preview: stand here (y: the floor, 0 or upstairs)
## GOGGLESXR_HOME_MENU=look      desktop preview: open the Home menu on a page
## GOGGLESXR_HOME_GAMES=12       fill the shelf with that many made-up games
## GOGGLESXR_SHOW_HANDS=1       desktop preview: show both hands in front of you
## GOGGLESXR_TOUR=1              start with the tour
## GOGGLESXR_THUMBS=/folder      draw the catalogue's pictures (thumbs/) into a folder, then quit
## GOGGLESXR_SELFTEST=1          check the pieces, print results, quit

const Room := preload("res://room.gd")
const Furniture := preload("res://furniture.gd")
const GameShelf := preload("res://game_shelf.gd")
const HomeMenu := preload("res://home_menu.gd")
const Skies := preload("res://skies.gd")
const Hands := preload("res://hands.gd")
const Tutorial := preload("res://tutorial.gd")
const ACCENT := Color("3ddc84")
const STATE_EVERY := 2.0                  # seconds between asking whether a game has started
const LASER_LENGTH := 8.0
const MENU_WIDTH := 1.3                   # metres
const WALK_SPEED := 2.0                   # metres a second (smooth movement)
const AVATAR_LAYER := 1 << 19             # seen only in mirrors
const DEFAULT_LOOK := {"sky": "grid", "walls": "teal", "floor": "tiles", "accent": "green", "brightness": 50.0,
		"mood0": "bright", "mood1": "warm"}
const DEFAULT_SETTINGS := {"move": "teleport", "turn": 45, "sounds": "on", "hand_style": "ghost", "toured": false}
const U := Room.UP_FLOOR
# What a new home starts with: [id, x, y, z, turn in degrees]
const STARTER := [
	# the living room: a sofa facing the VHS corner, a games corner, toys
	["rugRectangle", 2.3, 0.0, 2.3, 90], ["sofa_02", 1.1, 0.0, 2.35, 90], ["CoffeeTable_01", 2.45, 0.0, 2.35, 90],
	["lampRoundFloor", 1.0, 0.0, 3.25, 0], ["potted_plant_04", 4.1, 0.0, -3.05, 0], ["GreenChair_01", -1.6, 0.0, 2.5, 150],
	["wooden_bookshelf_worn", -0.9, 0.0, 3.2, 180], ["arcade-machine", 3.9, 0.0, -2.75, -60], ["hoop", 2.6, 2.3, 3.49, 180],
	["neon_gameon", -1.9, 2.2, 3.49, 180], ["wall_clock", 4.49, 2.35, 2.75, -90], ["radio", 2.45, 0.43, 2.0, 120],
	["target", -2.6, 0.0, -2.9, 20], ["blaster", 2.45, 0.43, 2.6, 80], ["remote", -0.2, 0.0, -1.6, 0],
	["rc_racer", 0.4, 0.0, -1.6, 0], ["basketball", 2.0, 0.0, 1.2, 0], ["ball", 0.6, 0.0, -0.9, 0],
	["pet_dog", -0.6, 0.0, -0.4, 30], ["marker", 2.3, 0.43, 2.2, 0], ["Ottoman_01", -2.4, 0.0, 1.7, 0],
	# upstairs, the bedroom
	["GothicBed_01", 1.6, U, 2.3, 180], ["sideTableDrawers", 0.2, U, 3.15, 180], ["sideTableDrawers", 3.0, U, 3.15, 180],
	["lampRoundTable", 0.2, U + 0.62, 3.15, 0], ["lampRoundTable", 3.0, U + 0.62, 3.15, 0], ["rugRound", 1.6, U, 0.6, 0],
	["ArmChair_01", -1.2, U, -2.5, 20], ["potted_plant_04", -2.4, U, -3.0, 0], ["tv_modern", 1.6, U + 0.0, -2.9, 0],
	["ornate_mirror_01", 4.49, U + 1.5, 0.4, -90], ["frame", 4.49, U + 1.55, 2.2, -90], ["pet_cat", 0.6, U, 0.0, 200],
	["vintage_grandfather_clock_01", -2.6, U, 3.2, 180], ["neon_heart", -0.6, U + 1.9, 3.49, 180],
]
# Things renamed in this version (the house you made before keeps them)
const RENAMED := {"loungeSofa": "Sofa_01", "loungeSofaLong": "sofa_02", "loungeChair": "GreenChair_01", "loungeChairRelax": "ArmChair_01",
		"loungeDesignChair": "modern_arm_chair_01", "loungeDesignSofa": "sofa_03", "loungeSofaOttoman": "Ottoman_01",
		"chairCushion": "dining_chair_02", "chairModernCushion": "painted_wooden_chair_01", "chairRounded": "chinese_armchair",
		"benchCushion": "wooden_stool_01", "table": "WoodenTable_01", "tableRound": "round_wooden_table_01",
		"tableGlass": "modern_coffee_table_02", "tableCross": "WoodenTable_03", "tableCoffee": "CoffeeTable_01",
		"tableCoffeeGlass": "modern_coffee_table_01", "tableCoffeeSquare": "coffee_table_round_01", "sideTable": "gallinera_table",
		"bookcaseOpen": "wooden_bookshelf_worn", "bookcaseOpenLow": "wooden_display_shelves_01", "bookcaseClosedWide": "modern_wooden_cabinet",
		"bookcaseClosedDoors": "chinese_cabinet", "cabinetTelevisionDoors": "cabinetTelevision", "cabinetBedDrawer": "sideTableDrawers",
		"lampSquareTable": "lampRoundTable", "televisionModern": "tv_modern", "televisionVintage": "Television_01",
		"plantSmall1": "potted_plant_04", "plantSmall2": "potted_plant_04", "plantSmall3": "potted_plant_04", "rugSquare": "rugRectangle",
		"bear": "rubber_duck_toy", "pillow": "throw_pillows_01", "pillowBlue": "throw_pillows_01", "cardboardBoxClosed": "cardboard_box_01"}
const SOUNDS := {"laser": ["laserSmall_000", "laserSmall_002"], "ding": ["impactMetal_000"], "pop": ["impactSoft_heavy_001"],
		"score": ["forceField_000"], "pet": ["impactSoft_medium_000"], "arcade": ["laserRetro_001"], "engine": ["engineCircular_000"],
		"step": ["footstep_wood_000", "footstep_wood_001", "footstep_wood_002"], "thud": ["impactGeneric_light_000", "impactGeneric_light_002"],
		"tape": ["impactPlate_light_000"]}

var xr_active := false
var origin: XROrigin3D
var camera: XRCamera3D
var room: Room
var furniture: Furniture
var shelf: GameShelf
var world: WorldEnvironment
var tour: Tutorial
var menu_view: SubViewport
var menu: HomeMenu
var menu_quad: MeshInstance3D
var menu_pointer := Vector2(-1, -1)
var menu_tween: Tween
var sounds: Node                          # the dashboard's ui_sounds.gd, when it came along
var hands := {}                           # "left"/"right" -> Dictionary (see _make_hand)
var marker: MeshInstance3D                # where a teleport would land
var toast: Label3D
var toast_tween: Tween
var look := DEFAULT_LOOK.duplicate()
var settings := DEFAULT_SETTINGS.duplicate()
var suspended := false                    # the dashboard is open: it has the controllers
var suspend_wait := 0.0
var fade: MeshInstance3D                  # a black veil around your eyes, for fading in and out
var fade_tween: Tween
var state_thread: Thread
var state_wait := 1.0
var no_headset := 0                       # answers in a row saying the headset has gone
var heartbeat_wait := 0.0
var closing := false
var _sound_cache := {}                    # name -> AudioStream
var _voices: Array[AudioStreamPlayer3D] = []
var _next_voice := 0
var _tunes: Array = []                    # [name, AudioStream] for the radio
var _desktop: Node                        # desktop_view.gd for the TVs (when it came along)
var _desktop_users := {}
var _drawings: Node3D
var _avatar: Node3D
var _picture_thread: Thread


func _ready() -> void:
	world = WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_energy = 0.95
	world.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	add_child(world)

	room = Room.new(ACCENT)
	add_child(room)
	furniture = Furniture.new()
	furniture.name = "Furniture"
	furniture.home = self
	add_child(furniture)
	shelf = GameShelf.new()
	shelf.name = "Games"
	add_child(shelf)
	shelf.build_corner(Room.VHS_CORNER, furniture._model("Television_01"))
	shelf.started.connect(func(name): _say(("Starting %s…" % name) if name != "" else "Couldn't start Steam"))
	_drawings = Node3D.new()
	_drawings.name = "Drawings"
	add_child(_drawings)
	if ResourceLoader.exists("res://ui_sounds.gd"):
		sounds = (load("res://ui_sounds.gd") as Script).new()
		add_child(sounds)
	for i in 8:
		var voice := AudioStreamPlayer3D.new()
		voice.unit_size = 3.0
		add_child(voice)
		_voices.append(voice)
	if ResourceLoader.exists("res://desktop_view.gd"):
		_desktop = (load("res://desktop_view.gd") as Script).new("gogglesxr-desktop-home.raw")
		add_child(_desktop)

	origin = XROrigin3D.new()
	add_child(origin)
	camera = XRCamera3D.new()
	camera.position = Vector3(0, 1.65, 0)     # the headset moves it; this is for the preview
	camera.cull_mask = 0xFFFFF & ~AVATAR_LAYER
	origin.add_child(camera)
	for side in ["left", "right"]:
		hands[side] = _make_hand(side)
	_make_marker()
	_make_toast()
	_make_menu()
	_make_fade()
	tour = Tutorial.new(camera)
	tour.finished.connect(func():
		settings.toured = true
		_save_home())
	add_child(tour)

	var xr := XRServer.find_interface("OpenXR")
	xr_active = xr != null and xr.is_initialized()
	if xr_active:
		get_viewport().use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		# the picture is in the headset: keep the desktop window out of the way
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
		var openxr := xr as OpenXRInterface
		if openxr:
			openxr.session_loss_pending.connect(func(): _leave("the VR session ended"))
			openxr.instance_exiting.connect(func(): _leave("the VR runtime stopped"))
	else:
		print("Goggles Home: no headset, so this is a preview window.")
		camera.rotation_degrees.y = -float(OS.get_environment("GOGGLESXR_LOOK"))
		var at := OS.get_environment("GOGGLESXR_AT").split(",")
		if at.size() == 3:
			origin.position = Vector3(float(at[0]), float(at[1]), float(at[2]))

	if OS.get_environment("GOGGLESXR_THUMBS") != "":
		_make_thumbs.call_deferred(OS.get_environment("GOGGLESXR_THUMBS"))
		return
	var testing := OS.get_environment("GOGGLESXR_SELFTEST") != ""
	_load_home(not testing)
	if not testing:
		var pretend := []                     # GOGGLESXR_HOME_GAMES=12: that many made-up games, for pictures
		for i in int(OS.get_environment("GOGGLESXR_HOME_GAMES")):
			pretend.append({"name": "Game %d" % (i + 1), "launch": "", "art": ""})
		shelf.fill(room.shelf_boards, pretend)
		_find_pictures()
	_fade_to(0.0, 0.9)
	_heartbeat()
	if testing:
		_selftest.call_deferred()
		return
	if OS.get_environment("GOGGLESXR_TOUR") != "" or (xr_active and not bool(settings.toured)):
		tour.start.call_deferred()
	if OS.get_environment("GOGGLESXR_SHOW_HANDS") != "":   # preview: both hands in front of you, half closed
		for side in hands:
			var grip_node: XRController3D = hands[side].grip_node
			grip_node.position = Vector3(-0.12 if side == "left" else 0.12, 1.45, -0.4)
			grip_node.rotation_degrees = Vector3(40, 0, 0)
			hands[side].model.visible = true
			hands[side].model.follow(0.4 if side == "left" else 1.0, 0.0 if side == "left" else 0.2, 1.0)
	var page := OS.get_environment("GOGGLESXR_HOME_MENU")
	if page != "":
		_show_menu(true)
		menu.show_tab(page)
	if OS.get_environment("GOGGLESXR_SHOT") != "":
		await get_tree().create_timer(2.5).timeout
		get_viewport().get_texture().get_image().save_png(OS.get_environment("GOGGLESXR_SHOT"))
		get_tree().quit()


# ------------------------------------------------------------------ the house as you left it
func _home_file() -> String:
	var config := OS.get_environment("XDG_CONFIG_HOME")
	if config == "":
		config = OS.get_environment("HOME").path_join(".config")
	return config.path_join("gogglesxr/home.json")


## The 360° picture chosen in the desktop app (settings.json), for the "My picture" sky.
func _own_picture() -> String:
	var text := FileAccess.get_file_as_string(_home_file().get_base_dir().path_join("settings.json"))
	var data: Variant = JSON.parse_string(text) if text.strip_edges() != "" else null
	return str(data.get("environment_image", "")) if data is Dictionary else ""


func _load_home(from_disk := true) -> void:
	var data: Variant = null
	if from_disk and FileAccess.file_exists(_home_file()):
		data = JSON.parse_string(FileAccess.get_file_as_string(_home_file()))
	if data is Dictionary:
		for key in DEFAULT_LOOK:
			if data.get("look") is Dictionary and data.look.has(key):
				look[key] = data.look[key]
		for key in DEFAULT_SETTINGS:
			if data.get("settings") is Dictionary and data.settings.has(key):
				settings[key] = data.settings[key]
		furniture.restore(_upgrade(data.get("items", [])))
	elif from_disk:                           # a new home: a few things to start with
		_furnish()
	for key in look:
		_apply_look(key, look[key])
	if sounds:
		sounds.set_mode(str(settings.sounds))
	for side in hands:
		if hands[side].model:
			hands[side].model.set_style(str(settings.hand_style))
	menu.set_values(look)
	menu.set_values(settings)


func _furnish() -> void:
	for thing in STARTER:
		furniture.spawn(thing[0], Transform3D(Basis(Vector3.UP, deg_to_rad(thing[4])), Vector3(thing[1], thing[2], thing[3])))


## A house saved by an older version: renamed things get their new names, and things that were
## standing where the stairs are now move out of their way.
func _upgrade(items: Variant) -> Array:
	var out := []
	if not items is Array:
		return out
	for entry in items:
		if not entry is Dictionary:
			continue
		var e: Dictionary = entry.duplicate()
		e.id = RENAMED.get(str(e.get("id", "")), str(e.get("id", "")))
		var x := float(e.get("x", 0))
		var z := float(e.get("z", 0))
		if float(e.get("y", 0)) < 1.0 and x < Room.STAIR_X1 + 0.2 and z > Room.STAIR_Z0 - 0.2 and z < Room.STAIR_Z1:
			e.x = Room.STAIR_X1 + 0.6
		out.append(e)
	return out


func _save_home() -> void:
	if OS.get_environment("GOGGLESXR_SELFTEST") != "" and not _home_file().contains("selftest"):
		return                                # tests never touch a real home
	DirAccess.make_dir_recursive_absolute(_home_file().get_base_dir())
	var file := FileAccess.open(_home_file(), FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"look": look, "settings": settings, "items": furniture.save()}, " "))
		file.close()


func _apply_look(key: String, value: Variant) -> void:
	match key:
		"sky":
			var made := Skies.make(str(value), _own_picture())
			world.environment.ambient_light_color = made[1]
			if made[0] == null:
				world.environment.background_mode = Environment.BG_COLOR
				world.environment.background_color = Color(0.012, 0.043, 0.039)
			else:
				world.environment.sky = made[0]
				world.environment.background_mode = Environment.BG_SKY
		"walls":
			room.set_walls(str(value))
		"floor":
			room.set_floor(str(value))
		"accent":
			room.set_accent(str(value))
		"brightness":
			room.set_brightness(float(value))
		"mood0", "mood1":
			room.set_mood(1 if key == "mood1" else 0, str(value))


func _on_look(key: String, value: Variant) -> void:
	look[key] = value
	_apply_look(key, value)
	_save_home()


func _on_setting(key: String, value: Variant) -> void:
	settings[key] = value
	if key == "sounds" and sounds:
		sounds.set_mode(str(value))
	if key == "hand_style":
		for side in hands:
			if hands[side].model:
				hands[side].model.set_style(str(value))
	_save_home()


func _on_action(name: String) -> void:
	match name:
		"close":
			_show_menu(false)
		"clear":
			furniture.clear()
			_save_home()
			_say("The house is empty")
		"erase":
			for stroke in _drawings.get_children():
				stroke.queue_free()
			_say("Drawings erased")
		"tour":
			_show_menu(false)
			tour.start()
		"tidy":                               # toys that rolled away come back in front of you
			var i := 0
			for item in furniture.items():
				if item.get_meta("kind") in ["prop", "held"]:
					var body := item as RigidBody3D
					body.linear_velocity = Vector3.ZERO
					body.angular_velocity = Vector3.ZERO
					body.global_transform = Transform3D(Basis.IDENTITY, _in_front(1.0 + 0.25 * (i % 3), 0.9) + Vector3((i / 3) * 0.3, 0, 0))
					i += 1
			_say("Toys are back" if i > 0 else "There are no toys in the house")


func _play(sound: String, pitch := 1.0) -> void:
	if sounds:
		sounds.play(sound, pitch)


# ------------------------------------------------------------------ for the gadgets (gadgets.gd)
## A sound from sounds/ (Kenney's CC0 packs) at a place in the house. The interface sounds
## ("click", "toggle"...) come from the dashboard's set.
func play_at(name: String, at: Vector3, pitch := 1.0) -> void:
	if settings.sounds == "off":
		return
	if not SOUNDS.has(name):
		_play(name, pitch)
		return
	var stream := sound_stream(name)
	if stream == null:
		return
	var voice := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	voice.stream = stream
	voice.global_position = at
	voice.pitch_scale = pitch
	voice.play()


func sound_stream(name: String) -> AudioStream:
	var files: Array = SOUNDS.get(name, [])
	if files.is_empty():
		return null
	var file: String = files[randi() % files.size()]
	if not _sound_cache.has(file):
		var path := ProjectSettings.globalize_path("res://sounds/%s.ogg" % file)
		_sound_cache[file] = AudioStreamOggVorbis.load_from_file(path) if FileAccess.file_exists(path) else null
	return _sound_cache[file]


## The radio's tunes (Kenney's CC0 music loops): [[name, AudioStream]].
func music() -> Array:
	if _tunes.is_empty():
		var dir := ProjectSettings.globalize_path("res://sounds/music")
		for file in DirAccess.get_files_at(dir) if DirAccess.dir_exists_absolute(dir) else PackedStringArray():
			if file.ends_with(".ogg"):
				var stream := AudioStreamOggVorbis.load_from_file(dir.path_join(file))
				if stream:
					_tunes.append([file.get_basename(), stream])
	return _tunes


## The PC's desktop for a TV (on), or the TV no longer wants it (off). -> the picture, or null.
func desktop_picture(user: Object, on: bool) -> Texture2D:
	if _desktop == null:
		if on:
			_say("The desktop view isn't installed")
		return null
	var key := str(user.get_instance_id())
	_desktop.want(key, on)
	if on and _desktop.message != "" and not _desktop_users.has(key):
		_say(_desktop.message)
	if on:
		_desktop_users[key] = true
	else:
		_desktop_users.erase(key)
	return _desktop.texture


func drawings() -> Node3D:
	return _drawings


func head_position() -> Vector3:
	return _head()


func say(text: String) -> void:
	_say(text)


## A picture for a new poster: one of your games' covers, or the night grid.
func default_picture() -> Image:
	var covers := []
	for case in shelf.cases:
		var art := str(case.get_meta("game").get("art", ""))
		if art != "" and FileAccess.file_exists(art):
			covers.append(art)
	var path: String = covers[randi() % covers.size()] if not covers.is_empty() else ProjectSettings.globalize_path("res://environments/goggles-home.jpg")
	var image := Image.load_from_file(path) if FileAccess.file_exists(path) else null
	if image:
		image.set_meta("path", path)
	return image


## A Goggles head where yours is, seen only in mirrors.
func show_avatar(layer: int) -> void:
	if _avatar:
		return
	_avatar = Node3D.new()
	camera.add_child(_avatar)
	var head := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.11
	ball.height = 0.24
	head.mesh = ball
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.86, 0.9, 0.88)
	skin.roughness = 0.5
	head.material_override = skin
	head.position = Vector3(0, -0.02, 0.06)
	head.layers = layer
	_avatar.add_child(head)
	var glow := StandardMaterial3D.new()
	glow.albedo_color = ACCENT
	glow.emission_enabled = true
	glow.emission = ACCENT
	glow.emission_energy_multiplier = 1.4
	for x in [-0.045, 0.045]:
		var lens := MeshInstance3D.new()
		var ring := TorusMesh.new()
		ring.inner_radius = 0.026
		ring.outer_radius = 0.036
		lens.mesh = ring
		lens.material_override = glow
		lens.rotation.x = PI / 2
		lens.position = Vector3(x, 0.0, -0.045)
		lens.layers = layer
		_avatar.add_child(lens)
	var visor := MeshInstance3D.new()
	var bar := BoxMesh.new()
	bar.size = Vector3(0.22, 0.03, 0.02)
	visor.mesh = bar
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.05, 0.08, 0.08)
	visor.material_override = dark
	visor.position = Vector3(0, 0.0, -0.035)
	visor.layers = layer
	_avatar.add_child(visor)


## A laser bolt from a blaster: it flies to whatever it hits, which feels it.
func fire_bolt(from: Vector3, dir: Vector3, shooter: Node3D) -> void:
	var exclude: Array[RID] = []
	if shooter is CollisionObject3D:
		exclude.append((shooter as CollisionObject3D).get_rid())
	var hit := _ray(from, dir, exclude, 0xFFFF)
	var to: Vector3 = hit.position if not hit.is_empty() else from + dir * LASER_LENGTH
	var bolt := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.008
	capsule.height = 0.22
	bolt.mesh = capsule
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = Color("ff4fa0")
	bolt.material_override = glow
	add_child(bolt)
	bolt.global_transform = Transform3D(Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.98 else Vector3.FORWARD) * Basis(Vector3.RIGHT, PI / 2), from)
	var flight := maxf(from.distance_to(to) / 30.0, 0.02)
	var t := bolt.create_tween()
	t.tween_property(bolt, "global_position", to, flight)
	t.tween_callback(func():
		bolt.queue_free()
		_spark(to)
		if hit.is_empty():
			return
		var node: Node = hit.collider
		if node.has_node("Does"):
			node.get_node("Does").hit(to, dir * 1.2)
		elif node is RigidBody3D and not (node as RigidBody3D).freeze:
			(node as RigidBody3D).apply_impulse(dir * 1.2, to - (node as Node3D).global_position)
			play_at("thud", to))


## A small burst of light where something landed or appeared.
func _spark(at: Vector3, colour := Color("ff8fc8"), amount := 14) -> void:
	var burst := CPUParticles3D.new()
	burst.one_shot = true
	burst.amount = amount
	burst.lifetime = 0.45
	burst.explosiveness = 1.0
	burst.spread = 180.0
	burst.initial_velocity_min = 0.6
	burst.initial_velocity_max = 1.6
	burst.gravity = Vector3(0, -2.5, 0)
	burst.scale_amount_min = 0.5
	burst.scale_amount_max = 1.0
	var dot := SphereMesh.new()
	dot.radius = 0.008
	dot.height = 0.016
	burst.mesh = dot
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = colour
	burst.material_override = glow
	add_child(burst)
	burst.global_position = at
	burst.emitting = true
	get_tree().create_timer(1.0).timeout.connect(burst.queue_free)


# ------------------------------------------------------------------ building blocks
func _make_hand(side: String) -> Dictionary:
	var aim := XRController3D.new()
	aim.tracker = &"left_hand" if side == "left" else &"right_hand"
	aim.pose = &"aim"
	origin.add_child(aim)
	var grip := XRController3D.new()
	grip.tracker = aim.tracker
	grip.pose = &"grip"
	origin.add_child(grip)
	var model := Hands.new(side, str(settings.hand_style))
	model.visible = false
	grip.add_child(model)
	var laser := MeshInstance3D.new()
	var beam := BoxMesh.new()
	beam.size = Vector3(0.003, 0.003, 1.0)
	laser.mesh = beam
	var light := StandardMaterial3D.new()
	light.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	light.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	light.albedo_color = Color(ACCENT, 0.25)
	laser.material_override = light
	laser.visible = false
	add_child(laser)
	var dot := MeshInstance3D.new()
	var dot_ball := SphereMesh.new()
	dot_ball.radius = 0.01
	dot_ball.height = 0.02
	dot.mesh = dot_ball
	var bright := StandardMaterial3D.new()
	bright.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bright.albedo_color = Color("f1ff9c")
	bright.no_depth_test = true
	dot.material_override = bright
	dot.visible = false
	add_child(dot)
	return {"side": side, "aim": aim, "grip_node": grip, "model": model, "laser": laser, "dot": dot,
			"trigger": false, "grip": false, "by": false, "ax": false, "stick": Vector2.ZERO, "ax_time": 0.0,
			"held": null, "hover": null, "press": "", "aiming": false, "landing": null,
			"last_at": Vector3.ZERO, "velocity": Vector3.ZERO, "from": Vector3.ZERO, "dir": Vector3.FORWARD}


func _make_marker() -> void:
	marker = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.22
	ring.outer_radius = 0.27
	marker.mesh = ring
	var paint := StandardMaterial3D.new()
	paint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	paint.albedo_color = Color("f1ff9c")
	marker.material_override = paint
	marker.scale = Vector3(1, 0.15, 1)
	marker.visible = false
	add_child(marker)


func _make_toast() -> void:
	toast = Label3D.new()
	toast.pixel_size = 0.0008
	toast.font_size = 48
	toast.outline_size = 12
	toast.outline_modulate = Color(0, 0, 0, 0.8)
	toast.no_depth_test = true
	toast.render_priority = 20
	toast.position = Vector3(0, -0.16, -0.9)
	toast.visible = false
	camera.add_child(toast)


## A short message low in your view.
func _say(text: String) -> void:
	toast.text = text
	toast.visible = true
	toast.modulate.a = 1.0
	if toast_tween:
		toast_tween.kill()
	toast_tween = create_tween()
	toast_tween.tween_interval(2.2)
	toast_tween.tween_property(toast, "modulate:a", 0.0, 0.5)
	toast_tween.tween_callback(func(): toast.visible = false)


func _make_menu() -> void:
	menu_view = SubViewport.new()
	menu_view.size = Vector2i(HomeMenu.SIZE)
	menu_view.transparent_bg = true
	menu_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(menu_view)
	menu = HomeMenu.new()
	menu_view.add_child(menu)
	menu.spawn_requested.connect(_spawn_in_front)
	menu.poster_requested.connect(func(path, framed): _spawn_in_front("frame" if framed else "poster", {"picture": path}))
	menu.look_changed.connect(_on_look)
	menu.setting_changed.connect(_on_setting)
	menu.action.connect(_on_action)
	menu.pressed_something.connect(func(toggle): _play("toggle" if toggle else "click"))
	menu_quad = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(MENU_WIDTH, MENU_WIDTH * HomeMenu.SIZE.y / HomeMenu.SIZE.x)
	menu_quad.mesh = quad
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = menu_view.get_texture()
	menu_quad.material_override = material
	menu_quad.visible = false
	add_child(menu_quad)


func _make_fade() -> void:
	fade = MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.2
	ball.height = 0.4
	fade.mesh = ball
	var paint := StandardMaterial3D.new()
	paint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	paint.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	paint.cull_mode = BaseMaterial3D.CULL_DISABLED
	paint.no_depth_test = true
	paint.render_priority = 127
	paint.albedo_color = Color(0, 0, 0, 1)    # starts black, fades in
	fade.material_override = paint
	camera.add_child(fade)


func _fade_to(alpha: float, seconds: float) -> Tween:
	if fade_tween:
		fade_tween.kill()
	fade.visible = true
	fade_tween = create_tween()
	fade_tween.tween_property(fade.material_override, "albedo_color:a", alpha, seconds)
	if alpha <= 0.0:
		fade_tween.tween_callback(func(): fade.visible = false)
	return fade_tween


# ------------------------------------------------------------------ your pictures
## Pictures in ~/Pictures (and its folders, one level down), newest first, with small copies
## for the menu: made on a thread.
func _find_pictures() -> void:
	var folder := OS.get_system_dir(OS.SYSTEM_DIR_PICTURES)
	if folder == "" or not DirAccess.dir_exists_absolute(folder):
		folder = OS.get_environment("HOME").path_join("Pictures")
	_picture_thread = Thread.new()
	_picture_thread.start(func() -> Array:
		var found := []
		var dirs := [folder]
		for sub in DirAccess.get_directories_at(folder) if DirAccess.dir_exists_absolute(folder) else PackedStringArray():
			if not sub.begins_with("."):
				dirs.append(folder.path_join(sub))
		for dir in dirs:
			for file in DirAccess.get_files_at(dir):
				if file.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
					var path: String = dir.path_join(file)
					found.append([FileAccess.get_modified_time(path), path])
		found.sort_custom(func(a, b): return a[0] > b[0])
		var list := []
		for entry in found.slice(0, 48):
			var image := Image.load_from_file(entry[1])
			if image == null:
				continue
			var f := 140.0 / maxf(image.get_width(), image.get_height())
			image.resize(maxi(1, int(image.get_width() * f)), maxi(1, int(image.get_height() * f)), Image.INTERPOLATE_BILINEAR)
			list.append({"path": entry[1], "name": entry[1].get_file().get_basename(), "image": image})
		return list)


func _collect_pictures() -> void:
	if _picture_thread == null or _picture_thread.is_alive():
		return
	var list: Array = _picture_thread.wait_to_finish()
	_picture_thread = null
	for entry in list:
		entry["thumb"] = ImageTexture.create_from_image(entry.image)
	menu.set_pictures(list)


# ------------------------------------------------------------------ where things are
func _head() -> Vector3:
	return camera.global_position


## The floor you are standing on (your play space's floor).
func _floor_y() -> float:
	return origin.global_position.y


## Flat direction you are facing.
func _facing() -> Vector3:
	var forward := -camera.global_transform.basis.z
	forward.y = 0
	return forward.normalized() if forward.length() > 0.05 else Vector3.FORWARD


## A point in front of you, kept inside the house, `height` above your floor.
func _in_front(distance: float, height: float) -> Vector3:
	var at := _inside(_head() + _facing() * distance, 0.5)
	at.y = _floor_y() + height
	return at


## The nearest point to `at` that is inside the house, `margin` metres from the walls.
func _inside(at: Vector3, margin: float) -> Vector3:
	return Vector3(clampf(at.x, -Room.WIDTH / 2 + margin, Room.WIDTH / 2 - margin), at.y,
			clampf(at.z, -Room.DEPTH / 2 + margin, Room.DEPTH / 2 - margin))


func _ray(from: Vector3, dir: Vector3, exclude: Array[RID] = [], mask := 0xFFFF) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * LASER_LENGTH, mask, exclude)
	return get_world_3d().direct_space_state.intersect_ray(query)


## What a ray points at, nearest first: {} or {"kind", "point", "distance", ...}.
## kind: "menu" (with "pixels"), "item" (a thing in the house: "node"), "case" (a game: "node"),
## "switch", "pad", "tour" (a tour card button: "node"), "floor" or "wall" (the house itself).
func _aim(from: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var pixels: Variant = _menu_pixels(from, dir)
	if pixels != null:
		var point := _menu_world(pixels)
		best = {"kind": "menu", "point": point, "distance": from.distance_to(point), "pixels": pixels}
	var hit := _ray(from, dir)
	if not hit.is_empty() and (best.is_empty() or from.distance_to(hit.position) < best.distance):
		var node: Node = hit.collider
		var kind := "floor" if hit.normal.y > 0.7 else "wall"
		if node.has_meta("item"):
			kind = "item"
		elif node.has_meta("game"):
			kind = "case"
		elif node.has_meta("switch"):
			kind = "switch"
		elif node.has_meta("pad"):
			kind = "pad"
		elif node.has_meta("tour"):
			kind = "tour"
		best = {"kind": kind, "point": hit.position, "distance": from.distance_to(hit.position), "node": node, "normal": hit.normal}
	return best


# ------------------------------------------------------------------ the Home menu
func _show_menu(on: bool) -> void:
	if menu_tween:
		menu_tween.kill()
	_play("open", 1.0 if on else 0.8)
	var paint := menu_quad.material_override as StandardMaterial3D
	if not on:
		menu_pointer = Vector2(-1, -1)
		menu_tween = create_tween().set_parallel()
		menu_tween.tween_property(menu_quad, "scale", Vector3(0.9, 0.9, 1), 0.14).set_ease(Tween.EASE_IN)
		menu_tween.tween_property(paint, "albedo_color:a", 0.0, 0.14)
		menu_tween.chain().tween_callback(func():
			menu_quad.visible = false
			menu_view.render_target_update_mode = SubViewport.UPDATE_DISABLED)
		return
	menu_quad.visible = true
	menu_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_collect_pictures()
	var at := _head() + _facing() * 1.15
	at.y = _head().y - 0.12
	menu_quad.global_transform = Transform3D(Basis.looking_at(_facing(), Vector3.UP), at)    # its face (+Z) towards you
	# it grows out of a point in front of you
	menu_quad.scale = Vector3(0.75, 0.75, 1)
	paint.albedo_color.a = 0.0
	menu_tween = create_tween().set_parallel()
	menu_tween.tween_property(menu_quad, "scale", Vector3.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	menu_tween.tween_property(paint, "albedo_color:a", 1.0, 0.18)
	tour.did("menu")


func _menu_pixels(from: Vector3, dir: Vector3) -> Variant:
	if not menu_quad.visible or (menu_quad.material_override as StandardMaterial3D).albedo_color.a < 0.5:
		return null
	var plane := Plane(menu_quad.global_transform.basis.z.normalized(), menu_quad.global_position)
	var hit: Variant = plane.intersects_ray(from, dir)
	if hit == null:
		return null
	var local: Vector3 = menu_quad.global_transform.affine_inverse() * hit
	var half: Vector2 = (menu_quad.mesh as QuadMesh).size / 2.0
	if absf(local.x) > half.x or absf(local.y) > half.y:
		return null
	return Vector2((local.x / half.x + 1.0) / 2.0, (1.0 - local.y / half.y) / 2.0) * HomeMenu.SIZE


func _menu_world(at: Vector2) -> Vector3:
	var half: Vector2 = (menu_quad.mesh as QuadMesh).size / 2.0
	var uv := at / HomeMenu.SIZE
	return menu_quad.global_transform * Vector3((uv.x * 2.0 - 1.0) * half.x, (1.0 - uv.y * 2.0) * half.y, 0.002)


func _menu_motion(at: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = at - menu_pointer if menu_pointer.x >= 0 else Vector2.ZERO
	menu_pointer = at
	menu_view.push_input(event, true)


func _menu_button(index: MouseButton, pressed: bool) -> void:
	if menu_pointer.x < 0:
		return
	var event := InputEventMouseButton.new()
	event.position = menu_pointer
	event.global_position = menu_pointer
	event.button_index = index
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed and index == MOUSE_BUTTON_LEFT else 0
	menu_view.push_input(event, true)


## Put a new thing from the catalogue in front of you: it pops into the house with a sparkle.
func _spawn_in_front(id: String, extra := {}) -> Node3D:
	var kind := Furniture.kind_of(id)
	var height := 0.9 if kind in ["prop", "held"] else (1.5 if kind == "wall" else 0.0)
	var at := _in_front(1.7, height)
	if kind == "roam":
		at = _in_front(1.2, 0.05)
	var item := furniture.spawn(id, Transform3D(Basis.looking_at(_facing(), Vector3.UP), at), true, extra)    # facing you
	if item == null:
		_say("The house is full" if furniture.items().size() >= Furniture.MAX_ITEMS else "That one couldn't be loaded")
		return null
	if id == "rc_racer" or id == "rc_truck":  # a car comes with its remote
		furniture.spawn("remote", Transform3D(Basis.IDENTITY, _in_front(1.0, 0.9) + _facing().cross(Vector3.UP) * 0.3))
	if kind == "wall":                        # a wall thing stays in the air until you hang it up
		_say("Hold grip on it and point at a wall to hang it")
	var grow := item.get_node("Model") as Node3D
	grow.scale = Vector3.ONE * 0.05
	create_tween().tween_property(grow, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_spark(item.global_position + Vector3.UP * 0.3, Color("f1ff9c"), 20)
	_play("grab", 1.1)
	tour.did("spawn")
	_save_home()
	return item


# ------------------------------------------------------------------ every frame
func _process(delta: float) -> void:
	heartbeat_wait -= delta
	if heartbeat_wait <= 0.0:
		_heartbeat()
	if menu_quad.visible:
		_collect_pictures()
	if closing or OS.get_environment("GOGGLESXR_SELFTEST") != "":
		return
	_watch_dashboard(delta)
	if xr_active:
		for side in hands:
			_update_hand(hands[side], delta)
		_watch_runtime(delta)


func _physics_process(_delta: float) -> void:
	# a toy that fell out of the world comes back
	for item in furniture.items():
		if item is RigidBody3D and item.global_position.y < -3.0:
			(item as RigidBody3D).linear_velocity = Vector3.ZERO
			item.global_position = Vector3(0, 1.0, -1.0)


## The dashboard says when it is open (a file it keeps fresh); Home then leaves the controllers
## alone, so one press doesn't do two things.
func _watch_dashboard(delta: float) -> void:
	suspend_wait -= delta
	if suspend_wait > 0.0:
		return
	suspend_wait = 0.3
	var sign := OS.get_environment("XDG_RUNTIME_DIR").path_join("gogglesxr-dashboard.status")
	var shown := FileAccess.file_exists(sign) and Time.get_unix_time_from_system() - FileAccess.get_modified_time(sign) < 8 \
			and FileAccess.get_file_as_string(sign).strip_edges() == "shown"
	_set_suspended(shown)


func _set_suspended(on: bool) -> void:
	if on == suspended:
		return
	suspended = on
	if on:
		for side in hands:
			var hand: Dictionary = hands[side]
			_release(hand)
			if hand.press == "menu":
				_menu_button(MOUSE_BUTTON_LEFT, false)
			hand.press = ""
			hand.aiming = false
			hand.laser.visible = false
			hand.dot.visible = false
			hand.model.visible = false
			_set_hover(hand, null)
		marker.visible = false


func _update_hand(hand: Dictionary, delta: float) -> void:
	var aim: XRController3D = hand.aim
	var grip_node: XRController3D = hand.grip_node
	var tracked := aim.get_has_tracking_data()
	if delta > 0.0:
		hand.velocity = hand.velocity.lerp((grip_node.global_position - hand.last_at) / delta, 0.4)
	hand.last_at = grip_node.global_position
	if suspended or not tracked:
		hand.laser.visible = false
		hand.dot.visible = false
		hand.model.visible = false
		if not tracked:
			_release(hand)
		return
	hand.model.visible = true
	hand.from = aim.global_position
	hand.dir = -aim.global_transform.basis.z.normalized()
	var trigger_value := aim.get_float(&"trigger")
	var grip_value := aim.get_float(&"grip")
	hand.model.holding = hand.held != null
	hand.model.follow(grip_value, trigger_value, delta)
	var input := {"trigger": trigger_value > 0.6, "grip": grip_value > 0.6,
			"by": aim.is_button_pressed(&"by_button"), "ax": aim.is_button_pressed(&"ax_button"),
			"stick": aim.get_vector2(&"primary")}
	_drive(hand, input, delta)


## One hand for one frame: what it points at, and what its buttons do. `input` is
## {"trigger", "grip", "by", "ax": bool, "stick": Vector2}.
func _drive(hand: Dictionary, input: Dictionary, delta: float) -> void:
	var pressed: bool = input.trigger and not hand.trigger
	var released: bool = not input.trigger and hand.trigger
	var gripped: bool = input.grip and not hand.grip
	var stick: Vector2 = input.stick
	var target := _aim(hand.from, hand.dir)

	if input.by and not hand.by:
		_show_menu(not menu_quad.visible)

	if hand.held != null and is_instance_valid(hand.held):
		_carry(hand, input, pressed, delta)
		if not input.grip:
			_release(hand)
		target = {}
	else:
		hand.held = null
		var kind: String = target.get("kind", "")
		_set_hover(hand, target.get("node") if kind in ["item", "case"] else null)
		if released and hand.press == "menu":
			_menu_button(MOUSE_BUTTON_LEFT, false)
			hand.press = ""
		match kind:
			"menu":
				_menu_motion(target.pixels)
				if pressed:
					_menu_button(MOUSE_BUTTON_LEFT, true)
					hand.press = "menu"
				if absf(stick.y) > 0.5 and absf(hand.stick.y) <= 0.5:
					var wheel := MOUSE_BUTTON_WHEEL_UP if stick.y > 0 else MOUSE_BUTTON_WHEEL_DOWN
					for i in 3:
						_menu_button(wheel, true)
						_menu_button(wheel, false)
			"item":
				if gripped:
					_grab(hand, target.node)
				elif pressed:
					_use(hand, target.node)
			"case":
				if gripped:
					_grab(hand, target.node)
			"switch":
				if pressed:
					var which: Array = target.node.get_meta("switch")
					room.set_mood(which[0], which[1])
					look["mood%d" % which[0]] = which[1]
					menu.set_values(look)
					_play("toggle", 1.1)
					_say("Lights: " + str(Room.MOODS[which[1]][0]))
					_save_home()
			"pad":
				if pressed:
					_go_to(target.node.get_meta("pad"))
			"tour":
				if pressed:
					_play("click")
					tour.press(str(target.node.get_meta("tour")))
		if kind != "menu" and hand.held == null:
			_move_with(hand, stick, target, delta)

	# the beam: bright on something you can use, faint otherwise
	var length: float = target.get("distance", LASER_LENGTH)
	var useful: bool = target.get("kind", "") in ["menu", "item", "case", "switch", "pad", "tour"] or hand.aiming
	hand.laser.visible = hand.held == null
	if hand.laser.visible:
		var up := Vector3.UP if absf(hand.dir.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
		hand.laser.global_transform = Transform3D(Basis.looking_at(hand.dir, up) * Basis.from_scale(Vector3(1, 1, length)), hand.from + hand.dir * length / 2.0)
		(hand.laser.material_override as StandardMaterial3D).albedo_color.a = 0.85 if useful else 0.18
	hand.dot.visible = useful and not target.is_empty() and hand.held == null
	if hand.dot.visible:
		hand.dot.global_position = target.point
	hand.trigger = input.trigger
	hand.grip = input.grip
	hand.by = input.by
	hand.ax = input.ax
	hand.stick = stick


## The trigger on something in the house: a gadget does its thing, a light switches.
func _use(hand: Dictionary, node: Node3D) -> void:
	if node.has_node("Does") and node.get_node("Does").get_script() != null:
		var does: Node = node.get_node("Does")
		if does.has_method("press"):
			does.press(hand)
	if node.has_node("Light"):
		Furniture.set_lit(node, not Furniture.is_lit(node))
		_play("toggle", 1.12 if Furniture.is_lit(node) else 0.9)
	tour.did("use")
	_save_home()


func _set_hover(hand: Dictionary, node: Variant) -> void:
	var old: Variant = hand.hover
	if old == node:
		return
	if old != null and is_instance_valid(old):
		if (old as Node).has_meta("item"):
			Furniture.highlight(old, false)
		else:
			shelf.point_at(null)
	hand.hover = node
	if node != null:
		_play("hover")
		if (node as Node).has_meta("item"):
			Furniture.highlight(node, true)
		else:
			shelf.point_at(node)


# ------------------------------------------------------------------ picking things up
func _grab(hand: Dictionary, node: Node3D) -> void:
	for side in hands:                        # one hand at a time
		if hands[side].held == node:
			return
	_set_hover(hand, null)
	hand.held = node
	hand.ax_time = 0.0
	_play("grab", 1.1)
	if node is RigidBody3D:
		(node as RigidBody3D).freeze = true
	if node.has_meta("game"):
		shelf.point_at(node, true)
	tour.did("grab")


## The thing in a hand follows it: furniture slides to where the laser lands, wall things hang
## where it meets a wall, toys sit in the hand, gadgets sit in it the way you'd hold them.
func _carry(hand: Dictionary, input: Dictionary, pressed: bool, delta: float) -> void:
	var node: Node3D = hand.held
	var grip_node: XRController3D = hand.grip_node
	if node.has_meta("game"):
		var at: Vector3 = grip_node.global_position + hand.dir * 0.12 + Vector3.UP * 0.06
		var to_head := (_head() - at).normalized()
		node.global_transform = node.global_transform.interpolate_with(Transform3D(Basis.looking_at(-to_head, Vector3.UP), at), 1.0 - pow(0.0001, delta))
		shelf.point_at(node, true)
		var near := shelf.near_slot(node.global_position)
		shelf.show_slot(near)
		if near:                              # it goes in by itself, like a real tape
			hand.held = null
			shelf.point_at(null)
			play_at("tape", node.global_position)
			tour.did("tape")
			shelf.insert(node)
		return
	var kind: String = node.get_meta("kind")
	var does: Node = node.get_node("Does") if node.has_node("Does") else null
	var used := false
	if does and does.has_method("in_hand") and kind in ["held", "prop", "roam"]:
		used = does.in_hand(hand, input, delta)
		if used:
			tour.did("use")
	# A or X: take it out of the house (gadgets that use A or X: hold it for a second)
	if input.ax:
		hand.ax_time += delta
	else:
		hand.ax_time = 0.0
	if (input.ax and not hand.ax and kind != "held") or hand.ax_time > 1.0:
		hand.held = null
		furniture.remove(node, true)
		_play("click", 0.8)
		_save_home()
		return
	match kind:
		"held":
			var hold: Transform3D = does.hold() if does else Transform3D.IDENTITY
			node.global_transform = grip_node.global_transform * hold
		"prop", "roam":
			node.global_transform = Transform3D(node.global_transform.basis, grip_node.global_position + hand.dir * 0.1).orthonormalized()
		"wall":
			_hang(node, hand.from, hand.dir)
		"ceiling":
			_hang_ceiling(node, hand.from, hand.dir)
		_:
			_place(node, hand.from, hand.dir)
	if kind in ["floor", "lamp", "wall", "ceiling"] and absf(input.stick.x) > 0.3:
		if kind == "wall":
			node.rotate_object_local(Vector3.BACK, -input.stick.x * 1.6 * delta)
		else:
			node.rotate_y(-input.stick.x * 2.4 * delta)


## Stand a piece of furniture where a ray lands: on a floor, or on top of other furniture.
func _place(node: Node3D, from: Vector3, dir: Vector3) -> bool:
	var hit := _ray(from, dir, [(node as CollisionObject3D).get_rid()], 1 | Furniture.LAYER_FURNITURE)
	if hit.is_empty() or hit.normal.y < 0.7:
		return false
	var at := _inside(hit.position, 0.08)
	node.global_position = Vector3(at.x, maxf(hit.position.y, 0.0), at.z)
	return true


## Hang a picture (or anything for walls) where a ray meets a wall, facing out of it.
func _hang(node: Node3D, from: Vector3, dir: Vector3) -> bool:
	var hit := _ray(from, dir, [(node as CollisionObject3D).get_rid()], 1)
	if hit.is_empty() or absf(hit.normal.y) > 0.3:
		# no wall there: it floats along the laser, 1.5 m out
		node.global_position = from + dir * 1.5
		return false
	var normal: Vector3 = hit.normal
	var spin := node.global_transform.basis.get_euler().z if absf(node.global_transform.basis.z.normalized().dot(normal)) > 0.9 else 0.0
	node.global_transform = Transform3D(Basis.looking_at(-normal, Vector3.UP).rotated(normal, spin), hit.position + normal * 0.002)
	return true


func _hang_ceiling(node: Node3D, from: Vector3, dir: Vector3) -> bool:
	var hit := _ray(from, dir, [(node as CollisionObject3D).get_rid()], 1)
	if hit.is_empty() or hit.normal.y > -0.7:
		return false
	node.global_position = _inside(hit.position, 0.3)
	return true


func _release(hand: Dictionary) -> void:
	var node: Variant = hand.held
	hand.held = null
	if node == null or not is_instance_valid(node):
		return
	_play("grab", 0.85)
	if (node as Node).has_meta("game"):
		shelf.put_back(node)
		shelf.point_at(null)
		shelf.show_slot(false)
		return
	if node is RigidBody3D:                   # let go: it keeps the hand's speed
		var body := node as RigidBody3D
		body.freeze = false
		body.linear_velocity = (hand.velocity as Vector3).limit_length(12.0)
		if node.get_meta("kind") != "roam":
			body.angular_velocity = Vector3(randf_range(-2, 2), randf_range(-2, 2), randf_range(-2, 2)) * minf((hand.velocity as Vector3).length(), 2.0)
	_save_home()


# ------------------------------------------------------------------ moving around
## Teleport: push the stick forward to aim (a ring shows where), let go to move there.
## Stick sideways turns in steps. With Smooth chosen, the left stick walks instead.
func _move_with(hand: Dictionary, stick: Vector2, target: Dictionary, delta: float) -> void:
	var walking: bool = str(settings.move) == "smooth" and hand.side == "left"
	if walking:
		if stick.length() > 0.2:
			var forward := _facing()
			var right := forward.cross(Vector3.UP)
			_walk((forward * stick.y + right * stick.x) * WALK_SPEED * delta)
		return
	if stick.y > 0.6:
		hand.aiming = true
		match target.get("kind", ""):
			"floor":
				hand.landing = _inside(target.point, 0.35)
			"pad":                            # aiming at a pad: you'll go where it goes
				hand.landing = target.node.get_meta("pad")
			_:
				hand.landing = null
		marker.visible = hand.landing != null
		if hand.landing != null:
			marker.global_position = (target.point if target.get("kind", "") == "pad" else hand.landing as Vector3) + Vector3.UP * 0.02
	elif hand.aiming and stick.y < 0.3:
		hand.aiming = false
		marker.visible = false
		if hand.landing != null:
			_teleport_to(hand.landing)
		hand.landing = null
	var turn := float(settings.turn)
	if turn > 0.0 and not hand.aiming and absf(stick.x) > 0.6 and absf((hand.stick as Vector2).x) <= 0.6:
		_turn(-signf(stick.x) * turn)


## Stand at a point on a floor (or a stair): your play space moves with you.
func _teleport_to(point: Vector3) -> void:
	var head := _head()
	origin.global_position += Vector3(point.x - head.x, 0, point.z - head.z)
	origin.global_position.y = point.y
	play_at("step", point)
	tour.did("teleport")
	if menu_quad.visible:
		_show_menu(true)                      # the menu comes along


## Another floor (a pad): a quick fade, and you are there.
func _go_to(point: Vector3) -> void:
	await _fade_to(1.0, 0.15).finished
	_teleport_to(point)
	_fade_to(0.0, 0.3)
	tour.did("upstairs")


## Smooth walking: along the floor, up and down the stairs, not through walls.
func _walk(step: Vector3) -> void:
	var head := _head()
	var to := _inside(head + step, 0.3)
	# the floor under your next step: no higher than a stair above your feet
	var feet := _floor_y()
	var down := _ray(Vector3(to.x, feet + 0.45, to.z), Vector3.DOWN, [], 1)
	if down.is_empty() or down.position.y > feet + 0.4:
		return
	origin.global_position += Vector3(to.x - head.x, 0, to.z - head.z)
	origin.global_position.y = down.position.y
	if Room.level_at(down.position.y) != Room.level_at(feet):
		tour.did("upstairs")


## Turn on the spot (around where your head is, not the middle of the play space).
func _turn(degrees: float) -> void:
	var head := _head()
	var turned := Transform3D(Basis(Vector3.UP, deg_to_rad(degrees)), Vector3.ZERO)
	var offset := origin.global_position - head
	origin.global_transform = Transform3D(turned.basis * origin.global_transform.basis, head + turned.basis * offset)
	_play("key")
	tour.did("turn")


# ------------------------------------------------------------------ stepping aside
func _watch_runtime(delta: float) -> void:
	if state_thread and not state_thread.is_alive():
		var answer: String = state_thread.wait_to_finish()
		state_thread = null
		var reason := _judge(answer)
		if reason != "":
			_leave(reason)
	state_wait -= delta
	if state_wait <= 0.0 and state_thread == null:
		state_wait = STATE_EVERY
		state_thread = Thread.new()
		state_thread.start(func() -> String:
			var out := []
			OS.execute("gogglesxr", ["vr-state"], out)
			return str(out[0]).strip_edges().split("\n")[-1] if not out.is_empty() else "")


## What `gogglesxr vr-state` said -> why to leave, or "" to stay.
## "game": a VR game is starting or running. "no-headset": the headset disconnected or the
## server stopped (two answers in a row, so a Wi-Fi hiccup doesn't close Home). "idle": stay.
func _judge(answer: String) -> String:
	if answer == "game":
		return "a game started"
	if answer == "no-headset":
		no_headset += 1
		return "the headset disconnected" if no_headset >= 2 else ""
	no_headset = 0
	return ""


## Fade to black and quit, so whatever comes next (a game) has the headset to itself.
func _leave(reason: String) -> void:
	if closing:
		return
	closing = true
	print("Goggles Home: %s, stepping aside." % reason)
	_remove_heartbeat()
	if not is_inside_tree():
		return
	await _fade_to(1.0, 0.35).finished
	get_tree().quit()


# ------------------------------------------------------------------ "Home is here"
## A file the dashboard looks at: while it is fresh, Home is drawing the surroundings, so the
## dashboard (on top) must leave its own background see-through.
func _heartbeat_path() -> String:
	var run := OS.get_environment("XDG_RUNTIME_DIR")
	if run == "" or not DirAccess.dir_exists_absolute(run):
		run = OS.get_user_data_dir()
	return run.path_join("gogglesxr-home.status")


func _heartbeat() -> void:
	heartbeat_wait = 2.0
	if closing:
		return
	var file := FileAccess.open(_heartbeat_path(), FileAccess.WRITE)
	if file:
		file.store_line("xr" if xr_active else "preview")
		file.close()


func _remove_heartbeat() -> void:
	if FileAccess.file_exists(_heartbeat_path()):
		DirAccess.remove_absolute(_heartbeat_path())


func _exit_tree() -> void:
	_remove_heartbeat()
	if state_thread:
		state_thread.wait_to_finish()
	if _picture_thread:
		_picture_thread.wait_to_finish()


# ------------------------------------------------------------------ catalogue pictures
## Draw every catalogue entry on a clear background (thumbs/<id>.png, shown in the Home menu).
func _make_thumbs(folder: String) -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var view := SubViewport.new()
	view.size = Vector2i(192, 192)
	view.transparent_bg = true
	view.own_world_3d = true
	view.msaa_3d = Viewport.MSAA_4X
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(view)
	var eye := Camera3D.new()
	eye.fov = 28
	view.add_child(eye)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.3
	view.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_CLEAR_COLOR
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.8, 0.85, 0.85)
	env.environment.ambient_light_energy = 0.9
	view.add_child(env)
	var stand := Furniture.new()
	view.add_child(stand)
	var made := 0
	var only := OS.get_environment("GOGGLESXR_THUMBS_ONLY").split(",", false)
	for id in Furniture.CATALOGUE:
		if not only.is_empty() and not id in only:
			continue
		var item := stand.spawn(id, Transform3D.IDENTITY)
		if item == null:
			print("no model for ", id)
			continue
		if item is RigidBody3D:
			(item as RigidBody3D).freeze = true
		item.set_process(false)
		item.set_physics_process(false)
		var size: Vector3 = item.get_meta("size")
		var middle := Vector3(0, size.y / 2.0, 0)
		var looking := Vector3(-0.75, 0.6, 1.0)
		match Furniture.kind_of(id):
			"wall":
				middle = Vector3(0, 0, size.z / 2.0)
				looking = Vector3(-0.35, 0.15, 1.0)
			"ceiling":
				middle = Vector3(0, -size.y / 2.0, 0)
		var reach := maxf(size.length(), 0.25) * 1.25
		eye.position = middle + looking.normalized() * reach / tan(deg_to_rad(eye.fov / 2.0)) * 0.5
		eye.look_at(middle)
		for i in 4:
			await get_tree().process_frame
		view.get_texture().get_image().save_png(folder.path_join(id + ".png"))
		stand.remove(item)
		await get_tree().process_frame
		made += 1
	print("made %d pictures in %s" % [made, folder])
	get_tree().quit()


# ------------------------------------------------------------------ self-test
func _selftest() -> void:
	var failed := [0]
	var check := func(name: String, ok: bool, detail: String) -> void:
		print(("PASS " if ok else "FAIL ") + name + " -> " + detail)
		if not ok:
			failed[0] += 1
	var settle := func() -> void:
		for i in 3:
			await get_tree().physics_frame
	var input := func(trigger := false, grip := false, stick := Vector2.ZERO, by := false, ax := false) -> Dictionary:
		return {"trigger": trigger, "grip": grip, "by": by, "ax": ax, "stick": stick}
	var point := func(hand: Dictionary, from: Vector3, at: Vector3) -> void:
		hand.from = from
		hand.dir = (at - from).normalized()
	var hand: Dictionary = hands["right"]
	await get_tree().create_timer(0.5).timeout

	# The house
	check.call("the house is built", room.parts > 120 and room.get_node_or_null("GameShelf") != null and room.get_node_or_null("Logo") != null, "%d pieces" % room.parts)
	check.call("the night grid shows outside", world.environment.background_mode == Environment.BG_SKY, "")
	check.call("Home says it is here", FileAccess.file_exists(_heartbeat_path()), _heartbeat_path())
	var missing := Furniture.CATALOGUE.keys().filter(func(id): return str(Furniture.CATALOGUE[id][3]) != "" and not FileAccess.file_exists(ProjectSettings.globalize_path("res://models/" + str(Furniture.CATALOGUE[id][3]))))
	check.call("every model in the catalogue is there", missing.is_empty(), str(missing))
	var floor_hit := _ray(Vector3(1, Room.UP_FLOOR + 1.0, 0), Vector3.DOWN, [], 1)
	check.call("upstairs has a floor", not floor_hit.is_empty() and absf(floor_hit.position.y - Room.UP_FLOOR) < 0.02, str(floor_hit.get("position")))
	var well := _ray(Vector3((Room.STAIR_X0 + Room.STAIR_X1) / 2, Room.UP_FLOOR + 1.0, Room.STAIR_Z0 + 0.4), Vector3.DOWN, [], 1)
	check.call("with the stairs coming up through it", not well.is_empty() and well.position.y < 1.0 and well.position.y > 0.1, str(well.get("position")))
	var top_step := _ray(Vector3((Room.STAIR_X0 + Room.STAIR_X1) / 2, 5.0, Room.STAIR_Z1 - 0.1), Vector3.DOWN, [], 1)
	check.call("and the top step at the upstairs floor", not top_step.is_empty() and absf(top_step.position.y - Room.UP_FLOOR) < 0.03, str(top_step.get("position")))

	# Hands
	var model: Hands = hand.model
	check.call("the hands are real hands", model.skeleton != null and model.skeleton.get_bone_count() > 20 and not model._closed.is_empty(), str(model.skeleton.get_bone_count() if model.skeleton else 0))
	var thumb := model.skeleton.find_bone("Middle_Proximal_R")
	var open := model.skeleton.get_bone_pose_rotation(thumb)
	model.follow(1.0, 0.0, 1.0)
	var closed := model.skeleton.get_bone_pose_rotation(thumb)
	check.call("grip closes the fingers", open.angle_to(closed) > 0.3, "%.2f rad" % open.angle_to(closed))
	var index := model.skeleton.find_bone("Index_Proximal_R")
	var straight := model.skeleton.get_bone_pose_rotation(index)
	model.follow(1.0, 1.0, 1.0)
	check.call("the trigger curls the index finger", straight.angle_to(model.skeleton.get_bone_pose_rotation(index)) > 0.3, "")
	model.follow(0.0, 0.0, 1.0)
	check.call("the hands are see-through by default", model.mesh.material_override is ShaderMaterial, str(model.mesh.material_override))
	model.set_style("lab")
	check.call("and have other styles", (model.mesh.material_override as StandardMaterial3D).albedo_texture != null, "")
	model.set_style("ghost")

	# Furniture: detailed, textured
	var sofa := furniture.spawn("Sofa_01", Transform3D(Basis.IDENTITY, Vector3(-1, 0, 0)))
	await settle.call()
	var sofa_size: Vector3 = sofa.get_meta("size") if sofa else Vector3.ZERO
	var textured := sofa.find_children("*", "MeshInstance3D", true, false).any(func(m):
		var mat: Material = (m as MeshInstance3D).mesh.surface_get_material(0) if (m as MeshInstance3D).mesh else null
		return mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_texture != null)
	check.call("a Poly Haven sofa comes in at real size, with its textures", sofa_size.x > 1.3 and sofa_size.x < 2.0 and textured, str(sofa_size))
	point.call(hand, Vector3(-1, 1.4, 1.5), sofa.global_position + Vector3.UP * 0.4)
	_drive(hand, input.call(false, true), 0.016)
	check.call("grip picks it up", hand.held == sofa, str(hand.held))
	point.call(hand, Vector3(0, 1.5, 0), Vector3(2, 0, 1))
	_drive(hand, input.call(false, true, Vector2(1, 0)), 0.25)
	check.call("it slides to where the laser lands, the stick turns it", sofa.global_position.distance_to(Vector3(2, 0, 1)) < 0.05 and absf(sofa.rotation.y) > 0.3, str(sofa.global_position))
	_drive(hand, input.call(), 0.016)
	var table := furniture.spawn("WoodenTable_01", Transform3D(Basis.IDENTITY, Vector3(-1.5, 0, -2)))
	var lamp := furniture.spawn("lampRoundTable", Transform3D(Basis.IDENTITY, Vector3(0, 0, 2)))
	await settle.call()
	_place(lamp, Vector3(-1.5, 2.6, -2), Vector3.DOWN)
	var table_top: float = (table.get_meta("size") as Vector3).y
	check.call("a lamp can stand on a table", absf(lamp.global_position.y - table_top) < 0.04, "%.2f on %.2f" % [lamp.global_position.y, table_top])
	await settle.call()
	var bulb: Vector3 = lamp.global_position + Vector3.UP * (lamp.get_meta("size") as Vector3).y * 0.5
	point.call(hand, bulb + Vector3(0, 0.2, 1.2), bulb)
	_drive(hand, input.call(), 0.016)
	_drive(hand, input.call(true), 0.016)
	_drive(hand, input.call(), 0.016)
	check.call("the trigger switches a lamp", not Furniture.is_lit(lamp), "")

	# Wall things
	var painting := furniture.spawn("frame", Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0)), true, {"picture": ProjectSettings.globalize_path("res://environments/goggles-home.jpg")})
	await settle.call()
	point.call(hand, Vector3(0, 1.5, 0), painting.global_position)
	_drive(hand, input.call(false, true), 0.016)
	point.call(hand, Vector3(3.0, 1.6, 0), Vector3(Room.WIDTH / 2, 1.7, 0.3))
	_drive(hand, input.call(false, true), 0.016)
	_drive(hand, input.call(), 0.016)
	var facing := painting.global_transform.basis.z.normalized()
	check.call("a framed picture hangs on the wall, facing out", absf(painting.global_position.x - Room.WIDTH / 2) < 0.02 and facing.dot(Vector3.LEFT) > 0.95, "%s facing %s" % [painting.global_position, facing])
	var face := painting.find_child("Picture", true, false) as MeshInstance3D
	check.call("with your picture in it", face != null and (face.material_override as StandardMaterial3D).albedo_texture != null, "")

	# Gadgets
	var tv := furniture.spawn("tv_modern", Transform3D(Basis.IDENTITY, Vector3(1, 0, -2)))
	await settle.call()
	check.call("a TV has a screen", tv.find_child("Screen", true, false) != null, "")
	var radio := furniture.spawn("radio", Transform3D(Basis.IDENTITY, Vector3(1.5, 0, -2)))
	await settle.call()
	_use(hand, radio)
	var radio_player := radio.get_node("Does").player as AudioStreamPlayer3D
	check.call("the radio plays music", radio_player.stream != null and music().size() >= 5, "%d tunes" % music().size())
	var target := furniture.spawn("target", Transform3D(Basis.IDENTITY, Vector3(-2.2, 0, 2.6)))
	var blaster := furniture.spawn("blaster", Transform3D(Basis.IDENTITY, Vector3(-2.2, 0.9, 0.6)))
	await settle.call()
	point.call(hand, Vector3(-2.2, 1.4, 0.0), blaster.global_position)
	_drive(hand, input.call(false, true), 0.016)
	check.call("the blaster can be picked up", hand.held == blaster, "")
	var aim_at: Vector3 = target.global_position + Vector3.UP * (target.get_meta("size") as Vector3).y * 0.6
	blaster.global_transform = Transform3D(Basis.looking_at((aim_at - blaster.global_position).normalized(), Vector3.UP), blaster.global_position)
	blaster.get_node("Does")._fire()
	await get_tree().create_timer(0.5).timeout
	check.call("its bolt hits the target", target.get_node("Does").hits == 1, str(target.get_node("Does").hits))
	_drive(hand, input.call(), 0.016)
	var marker_pen := furniture.spawn("marker", Transform3D(Basis.IDENTITY, Vector3(0, 0.9, -1)))
	await settle.call()
	point.call(hand, Vector3(0, 1.4, -0.4), marker_pen.global_position)
	_drive(hand, input.call(false, true), 0.016)
	for i in 6:
		hand.grip_node.global_position = Vector3(i * 0.05, 1.2, -0.5)
		_drive(hand, input.call(true, true), 0.016)
	check.call("the marker draws in the air", _drawings.get_child_count() == 1 and (_drawings.get_child(0) as MeshInstance3D).mesh.get_surface_count() == 1, str(_drawings.get_child_count()))
	_drive(hand, input.call(false, true), 0.016)
	_drive(hand, input.call(), 0.016)
	hand.grip_node.position = Vector3.ZERO
	_on_action("erase")
	await get_tree().process_frame
	check.call("and the drawings can be erased", _drawings.get_child_count() == 0, "")
	var car := furniture.spawn("rc_racer", Transform3D(Basis.IDENTITY, Vector3(0.5, 0.05, 0.5)))
	var remote := furniture.spawn("remote", Transform3D(Basis.IDENTITY, Vector3(0, 0.9, 0.5)))
	await get_tree().create_timer(0.4).timeout
	var car_start := car.global_position
	for i in 40:
		remote.get_node("Does").in_hand(hand, input.call(false, true, Vector2(0, 1)), 0.016)
		await get_tree().physics_frame
	check.call("the RC remote drives the car", car.global_position.distance_to(car_start) > 0.15, "%.2f m" % car.global_position.distance_to(car_start))
	var dog := furniture.spawn("pet_dog", Transform3D(Basis.IDENTITY, Vector3(-1, 0.05, 1)))
	await get_tree().create_timer(0.3).timeout
	var toy := furniture.spawn("ball", Transform3D(Basis.IDENTITY, Vector3(1.5, 0.2, 2.5)))
	await get_tree().create_timer(2.5).timeout
	check.call("the dog fetches the ball", dog.get_node("Does").carrying == toy or dog.get_node("Does").chasing == toy or toy.global_position.distance_to(Vector3(1.5, 0, 2.5)) > 0.3, "")
	var hoop := furniture.spawn("hoop", Transform3D(Basis(Vector3.UP, PI), Vector3(0, 2.4, Room.DEPTH / 2 - 0.01)))
	await settle.call()
	var ring: Vector3 = hoop.global_transform * Vector3(0, -0.15, 0.27)
	var shot := furniture.spawn("basketball", Transform3D(Basis.IDENTITY, ring + Vector3(0, 0.5, 0)))
	await get_tree().create_timer(1.2).timeout
	check.call("a ball through the hoop scores", hoop.get_node("Does").score == 1, str(hoop.get_node("Does").score))
	var clock := furniture.spawn("wall_clock", Transform3D(Basis.IDENTITY, Vector3(0, 2, -3)))
	await get_tree().create_timer(0.1).timeout
	check.call("the wall clock tells the time", absf(angle_difference((clock.get_node("Model/Minute") as Node3D).rotation.z, -float(Time.get_time_dict_from_system().minute) / 60.0 * TAU)) < 0.2, "")
	var mirror := furniture.spawn("ornate_mirror_01", Transform3D(Basis.IDENTITY, Vector3(0, 1.5, -2)))
	await get_tree().process_frame
	check.call("a mirror shows the room and a Goggles head", mirror.find_child("Glass", true, false) != null and _avatar != null and not (camera.cull_mask & AVATAR_LAYER), "")

	# VHS tapes and the player
	var games := []
	for name in ["Beat Saber", "Half-Life: Alyx", "Bonelab"]:
		games.append({"name": name, "launch": "", "art": ""})
	shelf.fill(room.shelf_boards, games)
	await settle.call()
	var case: Node3D = shelf.cases[1] if shelf.cases.size() == 3 else null
	check.call("games stand on the shelf as VHS boxes at eye height", case != null and case.global_position.y > 1.3 and case.global_position.y < 1.9, str(case.global_position if case else null))
	point.call(hand, case.global_position + Vector3(-1.2, 0, 0), case.global_position)
	_drive(hand, input.call(), 0.016)
	check.call("pointing at a tape shows its name", hand.hover == case and shelf._label.text == "Half-Life: Alyx", shelf._label.text)
	_drive(hand, input.call(false, true), 0.016)
	check.call("grip takes the tape", hand.held == case, "")
	var started := [""]
	shelf.started.connect(func(n): started[0] = n, CONNECT_ONE_SHOT)
	hand.grip_node.global_position = shelf.slot.global_position + Vector3(0.0, -0.08, 0.0)
	hand.dir = Vector3.LEFT
	for i in 40:
		if hand.held == null:
			break
		_drive(hand, input.call(false, true), 0.05)
	check.call("bringing it to the VHS player puts it in", hand.held == null and shelf._loading, "")
	check.call("and the TV shows what's playing", (shelf.tv_screen.get_parent().get_node("Sign") as Label3D).text.contains("Half-Life"), "")
	hand.grip_node.position = Vector3.ZERO
	_drive(hand, input.call(), 0.016)

	# Moving around, upstairs and down
	_teleport_to(Vector3(2, 0, -1))
	check.call("teleporting puts you on the spot", Vector2(_head().x - 2, _head().z + 1).length() < 0.01, str(_head()))
	var before := _facing()
	_turn(-45)
	check.call("turning is on the spot, 45° at a time", absf(rad_to_deg(before.angle_to(_facing())) - 45) < 0.5, "%.1f°" % rad_to_deg(before.angle_to(_facing())))
	var pad: StaticBody3D = room.pads[0]
	point.call(hand, pad.global_position + Vector3(0.3, 1.5, 0.0), pad.global_position + Vector3.UP * 0.03)
	var at_pad := _aim(hand.from, hand.dir)
	check.call("the laser finds the pad to go upstairs", at_pad.get("kind") == "pad", str(at_pad.get("kind")))
	await _go_to(pad.get_meta("pad"))
	check.call("and it takes you upstairs", absf(_floor_y() - Room.UP_FLOOR) < 0.01, "%.2f" % _floor_y())
	settings.move = "smooth"
	_teleport_to(Vector3((Room.STAIR_X0 + Room.STAIR_X1) / 2, 0.0, Room.STAIR_Z0 - 0.4))
	_turn(0)
	camera.rotation = Vector3.ZERO
	origin.rotation = Vector3(0, PI, 0)          # facing up the stairs (+Z)
	var left: Dictionary = hands["left"]
	point.call(left, _head(), _head() + Vector3.UP)
	for i in 60:
		_drive(left, input.call(false, false, Vector2(0, 1)), 0.05)
	check.call("Smooth: you can walk up the stairs", _floor_y() > Room.UP_FLOOR - 0.3, "%.2f m up" % _floor_y())
	settings.move = "teleport"
	origin.rotation = Vector3.ZERO
	_teleport_to(Vector3(0, 0, 0.5))

	# Light switches
	var switch: StaticBody3D = room.switches.filter(func(b): return b.get_meta("switch") == [0, "night"])[0]
	point.call(hand, switch.global_position + Vector3(0.5, 0, 0), switch.global_position)
	_drive(hand, input.call(), 0.016)
	_drive(hand, input.call(true), 0.016)
	_drive(hand, input.call(), 0.016)
	check.call("a light switch sets the mood", room.mood_of(0) == "night" and look.mood0 == "night" and room.levels[0].lamps[0].light_energy < 0.4, str(room.mood_of(0)))
	room.set_mood(1, "night")
	check.call("night upstairs shows stars on the ceiling", room.levels[1].ceiling.get_shader_parameter("stars") == 1.0, "")
	room.set_mood(0, "bright")

	# The look of the house
	_on_look("walls", "plum")
	_on_look("floor", "wood")
	_on_look("accent", "pink")
	check.call("walls, floor and accent can be changed", room.wall_paint.albedo_color.is_equal_approx(Room.WALLS["plum"][1])
			and (room.floor_paint.get_shader_parameter("tile") as Vector2).is_equal_approx(Vector2(0.2, 1.6)) and room.strip_paint.albedo_color.is_equal_approx(Room.ACCENTS["pink"][1]), "")
	var kinds := []
	for id in Skies.CHOICES:
		_on_look("sky", id)
		kinds.append(world.environment.sky.sky_material.get_class() if world.environment.background_mode == Environment.BG_SKY else "none")
	check.call("every sky can be shown", kinds == ["PanoramaSkyMaterial", "ProceduralSkyMaterial", "ProceduralSkyMaterial", "ShaderMaterial", "PanoramaSkyMaterial"], str(kinds))

	# The menu, spawning, pictures
	_drive(hand, input.call(false, false, Vector2.ZERO, true), 0.016)
	_drive(hand, input.call(), 0.016)
	await get_tree().create_timer(0.4).timeout
	check.call("B or Y opens the Home menu, growing in", menu_quad.visible and menu_quad.scale.distance_to(Vector3.ONE) < 0.01, str(menu_quad.scale))
	var count := furniture.items().size()
	var chair := _spawn_in_front("dining_chair_02")
	check.call("picking something puts it in front of you", furniture.items().size() == count + 1 and chair != null, "")
	await get_tree().create_timer(0.5).timeout
	check.call("it pops in", (chair.get_node("Model") as Node3D).scale.is_equal_approx(Vector3.ONE), "")
	menu.set_pictures([{"path": ProjectSettings.globalize_path("res://environments/goggles-home.jpg"), "name": "night", "thumb": null}])
	count = furniture.items().size()
	menu.poster_requested.emit(ProjectSettings.globalize_path("res://environments/goggles-home.jpg"), false)
	check.call("your pictures become posters", furniture.items().size() == count + 1 and str(furniture.items().back().get_meta("picture", "")).ends_with("goggles-home.jpg"), "")
	menu.setting_changed.emit("hand_style", "dark")
	check.call("hand style can be changed", settings.hand_style == "dark", "")
	menu.action.emit("close")
	await get_tree().create_timer(0.3).timeout
	check.call("Close closes it", not menu_quad.visible, "")

	# Remembering the house (and an older house's things)
	var saved := furniture.save()
	furniture.restore(JSON.parse_string(JSON.stringify(saved)))
	await settle.call()
	check.call("the house is remembered, posters and all", furniture.items().size() == saved.size() and furniture.items().any(func(i): return i.has_meta("picture")), "%d things" % saved.size())
	var old := _upgrade([{"id": "loungeSofa", "x": -4.0, "y": 0, "z": 1.0}, {"id": "tableCoffee", "x": 1, "y": 0, "z": 1}])
	check.call("an older house's things get their new names and leave the stairs", old[0].id == "Sofa_01" and old[0].x > Room.STAIR_X1 and old[1].id == "CoffeeTable_01", str(old))
	furniture.clear()
	await get_tree().process_frame
	_furnish()
	await settle.call()
	check.call("a new house comes furnished on both floors", furniture.items().size() == STARTER.size() and furniture.items().any(func(i): return i.global_position.y > Room.UP_FLOOR - 0.1), "%d things" % furniture.items().size())

	# The tour
	tour.start()
	check.call("the tour starts with a welcome", tour.running() and tour.title.text == "Welcome to Goggles Home", tour.title.text)
	tour.press("next")
	tour.did("teleport")
	check.call("it moves on when you do what it asks", tour.STEPS[tour.step][0] == "turn", str(tour.step))
	tour.press("skip")
	check.call("and can be skipped", not tour.running() and settings.toured, "")

	# The dashboard has the controllers while it is open
	point.call(hand, Vector3(0, 1.4, 0.5), chair.global_position + Vector3.UP * 0.3 if is_instance_valid(chair) else Vector3.ZERO)
	_set_suspended(true)
	check.call("opening the dashboard makes Home let go", suspended and hand.held == null and not hand.model.visible, "")
	_set_suspended(false)

	# Stepping aside
	check.call("it stays while nothing else runs", _judge("idle") == "" and _judge("") == "", "")
	check.call("a game starting makes it step aside", _judge("game") == "a game started", "")
	check.call("one missed answer about the headset doesn't close it", _judge("no-headset") == "", "")
	check.call("two in a row do", _judge("no-headset") == "the headset disconnected", "")
	_leave("test")
	check.call("leaving removes the sign", not FileAccess.file_exists(_heartbeat_path()), "")
	print("SELFTEST " + ("PASSED" if failed[0] == 0 else "FAILED (%d)" % failed[0]))
	get_tree().quit(1 if failed[0] else 0)
