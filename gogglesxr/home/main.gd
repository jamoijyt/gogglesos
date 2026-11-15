extends Node3D
## Goggles Home: where you are when the headset is on and no game is running.
##
## A normal VR app (the GogglesXR dashboard draws on top of it, as it does over a game). The
## GogglesXR desktop app starts it when a headset connects, and it steps aside by itself: as
## soon as a VR game starts it fades out and quits, so the game gets the headset; the desktop
## app starts it again when the game has gone. It also leaves when the headset disconnects.
##
## Test hooks (environment variables):
## GOGGLESXR_SHOT=/path/out.png  save a picture of the window after a moment, then quit
## GOGGLESXR_LOOK=degrees        desktop preview: turn the camera (0 faces the glass wall)
## GOGGLESXR_SELFTEST=1          check the pieces, print results, quit

const Room := preload("res://room.gd")
const SKY_IMAGE := "res://environments/goggles-home.jpg"
const ACCENT := Color("3ddc84")
const STATE_EVERY := 2.0                  # seconds between asking whether a game has started

var xr_active := false
var origin: XROrigin3D
var camera: XRCamera3D
var room: Room
var world: WorldEnvironment
var hands := {}                           # "left"/"right" -> {"controller", "marker"}
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
	world.environment.ambient_light_color = Color(0.45, 0.62, 0.57)
	world.environment.ambient_light_energy = 0.95
	world.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	add_child(world)
	_load_sky()

	room = Room.new(ACCENT)
	add_child(room)

	origin = XROrigin3D.new()
	add_child(origin)
	camera = XRCamera3D.new()
	camera.position = Vector3(0, 1.65, 0)     # the headset moves it; this is for the preview
	origin.add_child(camera)
	for side in ["left", "right"]:
		hands[side] = _make_hand(side)
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
	_fade_to(0.0, 0.9)
	_heartbeat()

	if OS.get_environment("GOGGLESXR_SELFTEST") != "":
		_selftest.call_deferred()
	elif OS.get_environment("GOGGLESXR_SHOT") != "":
		await get_tree().create_timer(1.6).timeout
		get_viewport().get_texture().get_image().save_png(OS.get_environment("GOGGLESXR_SHOT"))
		get_tree().quit()


## The night grid outside the glass: the same 360° picture the dashboard uses.
func _load_sky() -> void:
	var path := ProjectSettings.globalize_path(SKY_IMAGE)
	var image := Image.load_from_file(path) if FileAccess.file_exists(path) else null
	if image == null:
		world.environment.background_mode = Environment.BG_COLOR
		world.environment.background_color = Color(0.012, 0.043, 0.039)
		return
	var material := PanoramaSkyMaterial.new()
	material.panorama = ImageTexture.create_from_image(image)
	var sky := Sky.new()
	sky.sky_material = material
	world.environment.sky = sky
	world.environment.background_mode = Environment.BG_SKY


## Your hands in the room: a small glowing marker where each controller is. (The dashboard
## draws the real controller models while it is open.)
func _make_hand(side: String) -> Dictionary:
	var controller := XRController3D.new()
	controller.tracker = &"left_hand" if side == "left" else &"right_hand"
	controller.pose = &"grip"
	origin.add_child(controller)
	var marker := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.028
	ball.height = 0.056
	marker.mesh = ball
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow.albedo_color = Color(ACCENT, 0.55)
	marker.material_override = glow
	marker.visible = false
	controller.add_child(marker)
	return {"controller": controller, "marker": marker}


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


func _process(delta: float) -> void:
	for side in hands:
		var controller: XRController3D = hands[side].controller
		hands[side].marker.visible = xr_active and controller.get_has_tracking_data()
	heartbeat_wait -= delta
	if heartbeat_wait <= 0.0:
		_heartbeat()
	if not xr_active or closing or OS.get_environment("GOGGLESXR_SELFTEST") != "":
		return
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


# ------------------------------------------------------------------ self-test
func _selftest() -> void:
	var failed := 0
	var check := func(name: String, ok: bool, detail: String) -> void:
		print(("PASS " if ok else "FAIL ") + name + " -> " + detail)
		if not ok:
			failed += 1
	await get_tree().create_timer(0.5).timeout
	check.call("the room is built", room.parts > 40 and room.get_node_or_null("GameShelf") != null and room.get_node_or_null("Logo") != null, "%d pieces" % room.parts)
	check.call("the game shelf has its boards", room.shelf_boards.size() == 4, str(room.shelf_boards.size()))
	check.call("the night grid shows outside", world.environment.background_mode == Environment.BG_SKY, "")
	check.call("you start inside, at standing height in the preview", absf(camera.position.x) < Room.WIDTH / 2 and camera.position.y > 1.0, str(camera.position))
	check.call("Home says it is here", FileAccess.file_exists(_heartbeat_path()), _heartbeat_path())
	check.call("it stays while nothing else runs", _judge("idle") == "" and _judge("") == "", "")
	check.call("a game starting makes it step aside", _judge("game") == "a game started", "")
	check.call("one missed answer about the headset doesn't close it", _judge("no-headset") == "", "")
	check.call("two in a row do", _judge("no-headset") == "the headset disconnected", "")
	_judge("idle")
	check.call("and the count starts again after a good answer", no_headset == 0, str(no_headset))
	await get_tree().create_timer(1.0).timeout
	check.call("it fades in", not fade.visible, str((fade.material_override as StandardMaterial3D).albedo_color.a))
	_leave("test")
	check.call("leaving removes the sign", not FileAccess.file_exists(_heartbeat_path()), "")
	print("SELFTEST " + ("PASSED" if failed == 0 else "FAILED (%d)" % failed))
	get_tree().quit(1 if failed else 0)
