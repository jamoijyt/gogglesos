extends Node3D
## Goggles Home: where you are when the headset is on and no game is running.
##
## A normal VR app (the GogglesXR dashboard draws on top of it, as it does over a game). The
## GogglesXR desktop app starts it when a headset connects, and it steps aside by itself: as
## soon as a VR game starts it fades out and quits, so the game gets the headset; the desktop
## app starts it again when the game has gone. It also leaves when the headset disconnects.
##
## In the room (room.gd) you can:
##   - move: stick forward teleports where you point, stick sideways turns (Settings: smooth)
##   - open the Home menu with B or Y (home_menu.gd): furniture, the room's look, settings
##   - pick things up with grip (furniture.gd): furniture slides over the floor and onto other
##     furniture, the stick turns it, A or X removes it; toys can be carried and thrown
##   - switch lamps with the trigger
##   - take a game from the shelf with grip and start it with the trigger (game_shelf.gd)
## While the dashboard is open, Home leaves the controllers to it.
## The room is remembered in ~/.config/gogglesxr/home.json.
##
## Test hooks (environment variables):
## GOGGLESXR_SHOT=/path/out.png  save a picture of the window after a moment, then quit
## GOGGLESXR_LOOK=degrees        desktop preview: turn the camera (0 faces the glass wall)
## GOGGLESXR_HOME_MENU=look      desktop preview: open the Home menu on a page
## GOGGLESXR_HOME_GAMES=12       fill the shelf with that many made-up games
## GOGGLESXR_THUMBS=/folder      draw the catalogue's pictures (thumbs/) into a folder, then quit
## GOGGLESXR_SELFTEST=1          check the pieces, print results, quit

const Room := preload("res://room.gd")
const Furniture := preload("res://furniture.gd")
const GameShelf := preload("res://game_shelf.gd")
const HomeMenu := preload("res://home_menu.gd")
const Skies := preload("res://skies.gd")
const ACCENT := Color("3ddc84")
const STATE_EVERY := 2.0                  # seconds between asking whether a game has started
const LASER_LENGTH := 6.0
const MENU_WIDTH := 1.3                   # metres
const WALK_SPEED := 2.0                   # metres a second (smooth movement)
const DEFAULT_LOOK := {"sky": "grid", "walls": "teal", "floor": "tiles", "accent": "green", "brightness": 50.0}
const DEFAULT_SETTINGS := {"move": "teleport", "turn": 45, "sounds": "on"}
# What a new home starts with: [id, x, z, turn in degrees, height]
const STARTER := [["rugRectangle", -2.6, 0.5, 0, 0], ["loungeSofa", -2.6, 1.9, 180, 0], ["tableCoffee", -2.6, 0.5, 0, 0],
		["loungeChair", -4.0, 0.4, 90, 0], ["pottedPlant", -4.05, 3.05, 0, 0], ["lampRoundFloor", -1.2, 3.0, 0, 0],
		["bookcaseOpen", 1.2, 3.25, 180, 0], ["plantSmall1", -2.6, 0.5, 0, 0.5], ["ball", 1.2, -1.6, 0, 0.6], ["block", 1.6, -1.9, 20, 0.3]]

var xr_active := false
var origin: XROrigin3D
var camera: XRCamera3D
var room: Room
var furniture: Furniture
var shelf: GameShelf
var world: WorldEnvironment
var menu_view: SubViewport
var menu: HomeMenu
var menu_quad: MeshInstance3D
var menu_pointer := Vector2(-1, -1)
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
	add_child(furniture)
	shelf = GameShelf.new()
	shelf.name = "Games"
	add_child(shelf)
	if ResourceLoader.exists("res://ui_sounds.gd"):
		sounds = (load("res://ui_sounds.gd") as Script).new()
		add_child(sounds)

	origin = XROrigin3D.new()
	add_child(origin)
	camera = XRCamera3D.new()
	camera.position = Vector3(0, 1.65, 0)     # the headset moves it; this is for the preview
	origin.add_child(camera)
	for side in ["left", "right"]:
		hands[side] = _make_hand(side)
	_make_marker()
	_make_toast()
	_make_menu()
	_make_fade()

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
	_fade_to(0.0, 0.9)
	_heartbeat()
	if testing:
		_selftest.call_deferred()
		return
	var page := OS.get_environment("GOGGLESXR_HOME_MENU")
	if page != "":
		_show_menu(true)
		menu.show_tab(page)
	if OS.get_environment("GOGGLESXR_SHOT") != "":
		await get_tree().create_timer(2.0).timeout
		get_viewport().get_texture().get_image().save_png(OS.get_environment("GOGGLESXR_SHOT"))
		get_tree().quit()


# ------------------------------------------------------------------ the room as you left it
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
		furniture.restore(data.get("items", []))
	elif from_disk:                           # a new home: a few things to start with
		for thing in STARTER:
			furniture.spawn(thing[0], Transform3D(Basis(Vector3.UP, deg_to_rad(thing[3])), Vector3(thing[1], thing[4], thing[2])))
	for key in look:
		_apply_look(key, look[key])
	if sounds:
		sounds.set_mode(str(settings.sounds))
	menu.set_values(look)
	menu.set_values(settings)


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


func _on_look(key: String, value: Variant) -> void:
	look[key] = value
	_apply_look(key, value)
	_save_home()


func _on_setting(key: String, value: Variant) -> void:
	settings[key] = value
	if key == "sounds" and sounds:
		sounds.set_mode(str(value))
	_save_home()


func _on_action(name: String) -> void:
	match name:
		"close":
			_show_menu(false)
		"clear":
			furniture.clear()
			_save_home()
			_say("The room is empty")
		"tidy":                               # toys that rolled away come back in front of you
			var i := 0
			for item in furniture.items():
				if item.get_meta("kind") == "prop":
					var body := item as RigidBody3D
					body.linear_velocity = Vector3.ZERO
					body.angular_velocity = Vector3.ZERO
					body.global_transform = Transform3D(Basis.IDENTITY, _in_front(1.0 + 0.25 * (i % 3), 0.9) + Vector3((i / 3) * 0.3, 0, 0))
					i += 1
			_say("Toys are back" if i > 0 else "There are no toys in the room")


func _play(sound: String, pitch := 1.0) -> void:
	if sounds:
		sounds.play(sound, pitch)


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
	var ball_node := MeshInstance3D.new()     # your hand: a small glowing marker
	var ball := SphereMesh.new()
	ball.radius = 0.028
	ball.height = 0.056
	ball_node.mesh = ball
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow.albedo_color = Color(ACCENT, 0.55)
	ball_node.material_override = glow
	ball_node.visible = false
	grip.add_child(ball_node)
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
	return {"side": side, "aim": aim, "grip_node": grip, "marker": ball_node, "laser": laser, "dot": dot,
			"trigger": false, "grip": false, "by": false, "ax": false, "stick": Vector2.ZERO,
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


# ------------------------------------------------------------------ where things are
func _head() -> Vector3:
	return camera.global_position


## Flat direction you are facing.
func _facing() -> Vector3:
	var forward := -camera.global_transform.basis.z
	forward.y = 0
	return forward.normalized() if forward.length() > 0.05 else Vector3.FORWARD


## A point in front of you, kept inside the room.
func _in_front(distance: float, height: float) -> Vector3:
	var at := _inside(_head() + _facing() * distance, 0.5)
	at.y = height
	return at


## The nearest point to `at` that is inside the room, `margin` metres from the walls.
func _inside(at: Vector3, margin: float) -> Vector3:
	return Vector3(clampf(at.x, -Room.WIDTH / 2 + margin, Room.WIDTH / 2 - margin), at.y,
			clampf(at.z, -Room.DEPTH / 2 + margin, Room.DEPTH / 2 - margin))


func _ray(from: Vector3, dir: Vector3, exclude: Array[RID] = [], mask := 0xFFFF) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * LASER_LENGTH, mask, exclude)
	return get_world_3d().direct_space_state.intersect_ray(query)


## What a ray points at, nearest first: {} or {"kind", "point", "distance", ...}.
## kind: "menu" (with "pixels"), "item" (furniture or a toy: "node"), "case" (a game: "node"),
## "floor" or "wall" (the room itself).
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
		best = {"kind": kind, "point": hit.position, "distance": from.distance_to(hit.position), "node": node, "normal": hit.normal}
	return best


# ------------------------------------------------------------------ the Home menu
func _show_menu(on: bool) -> void:
	menu_quad.visible = on
	menu_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	_play("open", 1.0 if on else 0.8)
	if not on:
		menu_pointer = Vector2(-1, -1)
		return
	var at := _head() + _facing() * 1.15
	at.y = _head().y - 0.12
	menu_quad.global_transform = Transform3D(Basis.looking_at(_facing(), Vector3.UP), at)    # its face (+Z) towards you


func _menu_pixels(from: Vector3, dir: Vector3) -> Variant:
	if not menu_quad.visible:
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


## Put a new thing from the catalogue in front of you.
func _spawn_in_front(id: String) -> Node3D:
	var toy := Furniture.kind_of(id) == "prop"
	var at := _in_front(1.7, 0.9 if toy else 0.0)
	var item := furniture.spawn(id, Transform3D(Basis.looking_at(_facing(), Vector3.UP), at))    # facing you
	if item == null:
		_say("The room is full" if furniture.items().size() >= Furniture.MAX_ITEMS else "That one couldn't be loaded")
		return null
	_play("grab", 1.1)
	_save_home()
	return item


# ------------------------------------------------------------------ every frame
func _process(delta: float) -> void:
	heartbeat_wait -= delta
	if heartbeat_wait <= 0.0:
		_heartbeat()
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
			hand.marker.visible = false
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
		hand.marker.visible = false
		if not tracked:
			_release(hand)
		return
	hand.marker.visible = hand.held == null
	hand.from = aim.global_position
	hand.dir = -aim.global_transform.basis.z.normalized()
	var input := {"trigger": aim.get_float(&"trigger") > 0.6, "grip": aim.get_float(&"grip") > 0.6,
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
				elif pressed and target.node.get_meta("kind") == "lamp":
					Furniture.set_lit(target.node, not Furniture.is_lit(target.node))
					_play("toggle", 1.12 if Furniture.is_lit(target.node) else 0.9)
					_save_home()
			"case":
				if gripped:
					_grab(hand, target.node)
		if kind != "menu" and hand.held == null:
			_move_with(hand, stick, target, delta)

	# the beam: bright on something you can use, faint otherwise
	var length: float = target.get("distance", LASER_LENGTH)
	var useful: bool = target.get("kind", "") in ["menu", "item", "case"] or hand.aiming
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
	_play("grab", 1.1)
	if node is RigidBody3D:
		(node as RigidBody3D).freeze = true
	if node.has_meta("game"):
		shelf.point_at(node, true)


## The thing in a hand follows it: furniture slides to where the laser lands, toys and games
## sit in the hand.
func _carry(hand: Dictionary, input: Dictionary, pressed: bool, delta: float) -> void:
	var node: Node3D = hand.held
	var grip_node: XRController3D = hand.grip_node
	if node.has_meta("game"):
		var at: Vector3 = grip_node.global_position + hand.dir * 0.12 + Vector3.UP * 0.06
		var to_head := (_head() - at).normalized()
		node.global_transform = node.global_transform.interpolate_with(Transform3D(Basis.looking_at(-to_head, Vector3.UP), at), 1.0 - pow(0.0001, delta))
		shelf.point_at(node, true)
		if pressed:
			_start_game(hand)
		return
	if input.ax and not hand.ax:                # A or X: take it out of the room
		hand.held = null
		furniture.remove(node)
		_play("click", 0.8)
		_save_home()
		return
	if node.get_meta("kind") == "prop":
		node.global_transform = Transform3D(node.global_transform.basis, grip_node.global_position + hand.dir * 0.1).orthonormalized()
		return
	_place(node, hand.from, hand.dir)
	if absf(input.stick.x) > 0.3:
		node.rotate_y(-input.stick.x * 2.4 * delta)


## Stand a piece of furniture where a ray lands: on the floor, or on top of other furniture.
func _place(node: Node3D, from: Vector3, dir: Vector3) -> bool:
	var hit := _ray(from, dir, [(node as CollisionObject3D).get_rid()], 1 | Furniture.LAYER_FURNITURE)
	if hit.is_empty() or hit.normal.y < 0.7:
		return false
	var at := _inside(hit.position, 0.08)
	node.global_position = Vector3(at.x, maxf(hit.position.y, 0.0), at.z)
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
		return
	if node is RigidBody3D:                   # let go: it keeps the hand's speed
		var body := node as RigidBody3D
		body.freeze = false
		body.linear_velocity = (hand.velocity as Vector3).limit_length(12.0)
		body.angular_velocity = Vector3(randf_range(-2, 2), randf_range(-2, 2), randf_range(-2, 2)) * minf((hand.velocity as Vector3).length(), 2.0)
	_save_home()


func _start_game(hand: Dictionary) -> void:
	var case: Node3D = hand.held
	var name := str(case.get_meta("game").get("name", "the game"))
	hand.held = null
	if shelf.play(case):
		_say("Starting %s…" % name)
		_play("open")
	else:
		_say("Couldn't start Steam")
	shelf.put_back(case)
	shelf.point_at(null)


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
		hand.landing = _inside(target.point, 0.35) if target.get("kind", "") == "floor" else null
		marker.visible = hand.landing != null
		if hand.landing != null:
			marker.global_position = (hand.landing as Vector3) + Vector3.UP * 0.02
	elif hand.aiming and stick.y < 0.3:
		hand.aiming = false
		marker.visible = false
		if hand.landing != null:
			_teleport_to(hand.landing)
		hand.landing = null
	var turn := float(settings.turn)
	if turn > 0.0 and not hand.aiming and absf(stick.x) > 0.6 and absf((hand.stick as Vector2).x) <= 0.6:
		_turn(-signf(stick.x) * turn)


## Stand at a point on the floor (your play space moves with you).
func _teleport_to(point: Vector3) -> void:
	var head := _head()
	origin.global_position += Vector3(point.x - head.x, 0, point.z - head.z)
	_play("swipe")
	if menu_quad.visible:
		_show_menu(true)                      # the menu comes along


func _walk(step: Vector3) -> void:
	var head := _head()
	var to := _inside(head + step, 0.3)
	origin.global_position += Vector3(to.x - head.x, 0, to.z - head.z)


## Turn on the spot (around where your head is, not the middle of the play space).
func _turn(degrees: float) -> void:
	var head := _head()
	var turned := Transform3D(Basis(Vector3.UP, deg_to_rad(degrees)), Vector3.ZERO)
	var offset := origin.global_position - head
	origin.global_transform = Transform3D(turned.basis * origin.global_transform.basis, head + turned.basis * offset)
	_play("key")


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
	for id in Furniture.CATALOGUE:
		var item := stand.spawn(id, Transform3D.IDENTITY)
		if item == null:
			print("no model for ", id)
			continue
		if item is RigidBody3D:
			(item as RigidBody3D).freeze = true
		var size: Vector3 = item.get_meta("size")
		var middle := Vector3(0, size.y / 2.0, 0)
		var reach := maxf(size.length(), 0.25) * 1.25
		eye.position = middle + Vector3(-0.75, 0.6, 1.0).normalized() * reach / tan(deg_to_rad(eye.fov / 2.0)) * 0.5
		eye.look_at(middle)
		for i in 3:
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

	check.call("the room is built", room.parts > 40 and room.get_node_or_null("GameShelf") != null and room.get_node_or_null("Logo") != null, "%d pieces" % room.parts)
	check.call("the night grid shows outside", world.environment.background_mode == Environment.BG_SKY, "")
	check.call("Home says it is here", FileAccess.file_exists(_heartbeat_path()), _heartbeat_path())
	check.call("the catalogue's models are all there", Furniture.CATALOGUE.keys().all(func(id): return id in ["ball", "block"] or FileAccess.file_exists(ProjectSettings.globalize_path("res://models/%s.glb" % id))), str(Furniture.CATALOGUE.size()))

	# Furniture
	var sofa := furniture.spawn("loungeSofa", Transform3D(Basis.IDENTITY, Vector3(-2, 0, 0)))
	await settle.call()
	var sofa_size: Vector3 = sofa.get_meta("size") if sofa else Vector3.ZERO
	check.call("a sofa can be put in the room, at real size", sofa is StaticBody3D and sofa_size.x > 1.5 and sofa_size.x < 2.4 and sofa_size.y > 0.6, str(sofa_size))
	var seen := _aim(Vector3(-2, 2.5, 0), Vector3.DOWN)
	check.call("the laser finds it", seen.get("kind") == "item" and seen.get("node") == sofa, str(seen.get("kind")))
	check.call("and the floor beside it", _aim(Vector3(1, 2, 1), Vector3.DOWN).get("kind") == "floor", "")
	check.call("and the walls", _aim(Vector3(0, 1.5, 0), Vector3.BACK).get("kind") == "wall", "")
	point.call(hand, Vector3(-2, 1.4, 1.5), sofa.global_position + Vector3.UP * 0.4)
	_drive(hand, input.call(false, true), 0.016)
	check.call("grip picks it up", hand.held == sofa, str(hand.held))
	point.call(hand, Vector3(0, 1.5, 0), Vector3(2, 0, 1))
	_drive(hand, input.call(false, true, Vector2(1, 0)), 0.25)
	check.call("it slides to where the laser lands", sofa.global_position.distance_to(Vector3(2, 0, 1)) < 0.05, str(sofa.global_position))
	check.call("and the stick turns it", absf(sofa.rotation.y) > 0.3, str(sofa.rotation.y))
	point.call(hand, Vector3(0, 1.5, 0), Vector3(30, 0, 1))
	_drive(hand, input.call(false, true), 0.016)
	check.call("it can't leave the room", absf(sofa.global_position.x) <= Room.WIDTH / 2, str(sofa.global_position))
	_drive(hand, input.call(), 0.016)
	check.call("letting go leaves it there", hand.held == null and is_instance_valid(sofa), "")

	var table := furniture.spawn("table", Transform3D(Basis.IDENTITY, Vector3(-3, 0, -2)))
	var lamp := furniture.spawn("lampRoundTable", Transform3D(Basis.IDENTITY, Vector3(0, 0, 2)))
	await settle.call()
	var table_top: float = (table.get_meta("size") as Vector3).y
	_place(lamp, Vector3(-3, 2.6, -2), Vector3.DOWN)
	check.call("a lamp can stand on a table", absf(lamp.global_position.y - table_top) < 0.03 and table_top > 0.4, "%.2f on %.2f" % [lamp.global_position.y, table_top])
	await settle.call()
	var bulb: Vector3 = lamp.global_position + Vector3.UP * (lamp.get_meta("size") as Vector3).y * 0.5
	point.call(hand, bulb + Vector3(0, 0, 1.2), bulb)
	_drive(hand, input.call(), 0.016)
	check.call("pointing at something lights it up", hand.hover == lamp, str(hand.hover))
	_drive(hand, input.call(true), 0.016)
	check.call("the trigger switches a lamp off", not Furniture.is_lit(lamp) and not lamp.get_node("Light").visible, "")
	_drive(hand, input.call(), 0.016)
	_drive(hand, input.call(true), 0.016)
	_drive(hand, input.call(), 0.016)
	check.call("and on again", Furniture.is_lit(lamp), "")
	var count := furniture.items().size()
	_drive(hand, input.call(false, true), 0.016)
	_drive(hand, input.call(false, true, Vector2.ZERO, false, true), 0.016)
	await get_tree().process_frame
	check.call("A or X removes what you hold", furniture.items().size() == count - 1 and hand.held == null, str(furniture.items().size()))
	_drive(hand, input.call(), 0.016)

	# Toys
	var ball := furniture.spawn("ball", Transform3D(Basis.IDENTITY, Vector3(0.5, 1.2, -1.5))) as RigidBody3D
	await get_tree().create_timer(1.2).timeout
	check.call("a ball falls and lands on the floor", ball.global_position.y < 0.6 and ball.global_position.y > -0.05, str(ball.global_position.y))
	point.call(hand, ball.global_position + Vector3(0, 0.6, 0.8), ball.global_position + Vector3.UP * 0.1)
	_drive(hand, input.call(false, true), 0.016)
	check.call("it can be picked up", hand.held == ball and ball.freeze, str(hand.held))
	hand.velocity = Vector3(0, 2, -3)
	_drive(hand, input.call(), 0.016)
	check.call("and thrown", not ball.freeze and ball.linear_velocity.distance_to(Vector3(0, 2, -3)) < 0.1, str(ball.linear_velocity))

	# Remembering the room
	var saved := furniture.save()
	var where: Vector3 = sofa.global_position
	furniture.restore(JSON.parse_string(JSON.stringify(saved)))
	await settle.call()
	var again := furniture.items().filter(func(i): return i.get_meta("item") == "loungeSofa")
	check.call("the room is remembered", furniture.items().size() == saved.size() and again.size() == 1 and (again[0] as Node3D).global_position.distance_to(where) < 0.01, "%d things" % saved.size())

	# The look of the room
	_on_look("walls", "plum")
	_on_look("floor", "wood")
	_on_look("accent", "pink")
	_on_look("brightness", 100.0)
	check.call("walls, floor, accent and lights can be changed", room.wall_paint.albedo_color.is_equal_approx(Room.WALLS["plum"][1])
			and (room.floor_paint.get_shader_parameter("tile") as Vector2).is_equal_approx(Vector2(0.2, 1.6))
			and room.strip_paint.albedo_color.is_equal_approx(Room.ACCENTS["pink"][1]) and is_equal_approx(room.main_light.light_energy, 3.0), "")
	var kinds := []
	for id in Skies.CHOICES:
		_on_look("sky", id)
		kinds.append(world.environment.sky.sky_material.get_class() if world.environment.background_mode == Environment.BG_SKY else "none")
	check.call("every sky can be shown", kinds == ["PanoramaSkyMaterial", "ProceduralSkyMaterial", "ProceduralSkyMaterial", "ShaderMaterial", "PanoramaSkyMaterial"], str(kinds))

	# The game shelf
	var games := []
	for name in ["Beat Saber", "Half-Life: Alyx", "Bonelab"]:
		games.append({"name": name, "launch": "steam://rungameid/1", "art": ""})
	shelf.fill(room.shelf_boards, games)
	await settle.call()
	var case: Node3D = shelf.cases[1] if shelf.cases.size() == 3 else null
	check.call("games stand on the shelf at eye height", case != null and case.global_position.y > 1.3 and case.global_position.y < 1.9, str(case.global_position if case else null))
	point.call(hand, case.global_position + Vector3(-1.2, 0, 0), case.global_position)
	_drive(hand, input.call(), 0.016)
	check.call("pointing at a case shows its name", hand.hover == case and shelf._label.visible and shelf._label.text == "Half-Life: Alyx", shelf._label.text)
	_drive(hand, input.call(false, true), 0.016)
	_drive(hand, input.call(false, true), 0.2)
	check.call("grip takes it off the shelf", hand.held == case and case.global_position.distance_to(shelf.home_of(case).origin) > 0.3, "")
	_drive(hand, input.call(), 0.016)
	await get_tree().create_timer(0.5).timeout
	check.call("letting go puts it back", case.global_position.distance_to(shelf.home_of(case).origin) < 0.01, "")

	# Moving around
	_teleport_to(Vector3(2, 0, -1))
	check.call("teleporting puts you on the spot", Vector2(_head().x - 2, _head().z + 1).length() < 0.01, str(_head()))
	var before := _facing()
	_turn(-45)
	check.call("turning is on the spot, 45° at a time", absf(rad_to_deg(before.angle_to(_facing())) - 45) < 0.5 and Vector2(_head().x - 2, _head().z + 1).length() < 0.01, "%.1f°" % rad_to_deg(before.angle_to(_facing())))
	point.call(hand, _head(), Vector3(-1, 0, 2.5))
	_drive(hand, input.call(false, false, Vector2(0, 1)), 0.016)
	check.call("stick forward shows where you would land", marker.visible and marker.global_position.distance_to(Vector3(-1, 0, 2.5)) < 0.1, str(marker.global_position))
	_drive(hand, input.call(), 0.016)
	check.call("and letting go takes you there", Vector2(_head().x + 1, _head().z - 2.5).length() < 0.05 and not marker.visible, str(_head()))
	settings.move = "smooth"
	var left: Dictionary = hands["left"]
	point.call(left, _head(), _head() + Vector3.UP)
	var start := _head()
	var ahead := _facing()
	_drive(left, input.call(false, false, Vector2(0, 1)), 0.25)
	check.call("Smooth: the left stick walks", (_head() - start).dot(ahead) > 0.3 or (_head() - start).length() < 0.6, str(_head() - start))
	for i in 40:
		_drive(left, input.call(false, false, Vector2(0, 1)), 0.25)
	check.call("but not through the walls", absf(_head().x) < Room.WIDTH / 2 and absf(_head().z) < Room.DEPTH / 2, str(_head()))
	settings.move = "teleport"
	_teleport_to(Vector3(0, 0, 0.5))

	# The Home menu
	_drive(hand, input.call(false, false, Vector2.ZERO, true), 0.016)
	_drive(hand, input.call(), 0.016)
	check.call("B or Y opens the Home menu in front of you", menu_quad.visible and absf(menu_quad.global_position.distance_to(_head()) - 1.15) < 0.2, str(menu_quad.global_position))
	await get_tree().process_frame
	point.call(hand, _head(), menu_quad.global_position)
	var on_menu := _aim(hand.from, hand.dir)
	check.call("the laser reaches it", on_menu.get("kind") == "menu" and (on_menu.pixels as Vector2).distance_to(HomeMenu.SIZE / 2) < 4, str(on_menu.get("pixels")))
	count = furniture.items().size()
	menu.spawn_requested.emit("chairDesk")
	check.call("picking something puts it in front of you", furniture.items().size() == count + 1, "")
	menu.look_changed.emit("walls", "sand")
	menu.setting_changed.emit("turn", 30)
	check.call("its choices take effect", room.wall_paint.albedo_color.is_equal_approx(Room.WALLS["sand"][1]) and int(settings.turn) == 30, "")
	var toy := furniture.spawn("block", Transform3D(Basis.IDENTITY, Vector3(-4, 0.5, -3)))
	menu.action.emit("tidy")
	check.call("toys can be brought back", toy.global_position.distance_to(_head()) < 2.0, str(toy.global_position))
	menu.action.emit("clear")
	await get_tree().process_frame
	check.call("and the room emptied", furniture.items().is_empty(), str(furniture.items().size()))
	menu.action.emit("close")
	check.call("Close closes it", not menu_quad.visible, "")

	# The dashboard has the controllers while it is open
	var chair := furniture.spawn("chairDesk", Transform3D(Basis.IDENTITY, Vector3(0, 0, -1)))
	await settle.call()
	point.call(hand, Vector3(0, 1.4, 0.5), chair.global_position + Vector3.UP * 0.3)
	_drive(hand, input.call(false, true), 0.016)
	_set_suspended(true)
	check.call("opening the dashboard makes Home let go", suspended and hand.held == null, "")
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
