extends Node3D
## GogglesXR dashboard: shows the five-panel interface (dashboard_ui.gd) on a screen floating
## in front of you and turns controller lasers into pointer input.
##
## In the headset:  point with either controller, trigger = click, stick = scroll,
##                  hold grip and move the laser = swipe the panel.
##                  Hold grip on the status bar = move the dashboard; while holding, push the
##                  stick forward or back to send it further away (bigger) or closer (smaller).
##                  Your controllers are drawn as models while the dashboard is open.
## Without a headset it runs in a window for testing: left mouse = trigger,
## right mouse (hold and drag) = grip, mouse wheel = stick, arrow keys = change panel.
## Where you leave the dashboard is remembered (user://dashboard.cfg).
##
## Started with GOGGLESXR_OVERLAY=1 it runs as an overlay: the runtime draws it on top of
## whatever VR game is running (through the small extension in ../overlay-extension, since
## Godot has no overlay support of its own). In that mode the menu button on the left
## controller shows and hides it. Without the variable it is a normal VR app.

const DashboardUI := preload("res://dashboard_ui.gd")
const SteamLibrary := preload("res://steam_library.gd")

const SCREEN_WIDTH := 1.35                # metres, at the reference distance
const REFERENCE_DISTANCE := 1.5           # the dashboard grows and shrinks with distance from here
const MIN_DISTANCE := 0.45
const MAX_DISTANCE := 5.0
const SETTINGS_FILE := "user://dashboard.cfg"
const SCREEN_HEIGHT_ABOVE_FLOOR := 1.3
const LASER_LENGTH := 4.0

var ui: DashboardUI
var viewport: SubViewport
var screen: MeshInstance3D
var camera: XRCamera3D
var xr_active := false
var overlay := false                      # drawn on top of a running game (needs the overlay extension)
var shown := true                         # overlay mode: the menu button shows and hides the dashboard
var open_amount := 1.0                    # 0 = closed, 1 = open; animated when showing and hiding
var open_tween: Tween
var smoothing := 0.6                      # pointer smoothing, 0 (off) to 1 (strongest)
var animations := true
var game_thread: Thread                   # looks up the running game without holding up a frame
var tool_jobs: Array[Thread] = []         # gogglesxr commands started from the dashboard
var game_wait := 0.0
var menu_was_down := false
var centre := Vector3(0, SCREEN_HEIGHT_ABOVE_FLOOR, -REFERENCE_DISTANCE)   # where the dashboard floats
var size_factor := 1.0                    # the Size setting
var moving := false                       # grip held on the status bar
var move_local := Vector3.ZERO            # the grabbed spot, in the screen's own coordinates
var move_reach := 1.0                     # how far along the laser the grabbed spot is
var ray_from := Vector3.ZERO              # the pointing ray of the active hand (or the mouse)
var ray_dir := Vector3.FORWARD
var origin_node: XROrigin3D
var hands := {}                           # "left"/"right" -> {controller, laser, dot, trigger, grip}
var active_hand := "right"
var pointer := Vector2(-1, -1)            # last pointer position on the dashboard, in its pixels
var grab_start := Vector2.ZERO
var mouse_buttons := 0
var scroll_wait := 0.0


func _ready() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(DashboardUI.SIZE)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.gui_embed_subwindows = true
	add_child(viewport)
	ui = DashboardUI.new()
	viewport.add_child(ui)
	ui.recentre_requested.connect(_recentre)
	ui.resume_requested.connect(func(): if overlay: _set_shown(false))
	ui.screenshot_requested.connect(func(): _run_tool("screenshot"))
	ui.record_requested.connect(func(): _run_tool("record"))
	ui.quit_requested.connect(func(): ui.say("Closing the game…"); _run_tool("quit-game"))
	ui.smoothing_changed.connect(func(v): smoothing = v; _save_prefs())
	_load_prefs()
	ui.set_smoothing(smoothing)
	ui.scale_changed.connect(func(f): size_factor = f; _apply_screen(); _save_place())

	var origin := XROrigin3D.new()
	origin_node = origin
	add_child(origin)
	# Light for the controller models (the dashboard and lasers are unshaded and ignore it)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 25, 0)
	sun.light_energy = 1.3
	add_child(sun)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_CLEAR_COLOR
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color(0.55, 0.7, 0.65)
	world.environment.ambient_light_energy = 0.6
	add_child(world)
	camera = XRCamera3D.new()
	camera.position = Vector3(0, SCREEN_HEIGHT_ABOVE_FLOOR, 0)
	origin.add_child(camera)
	for side in ["left", "right"]:
		hands[side] = _make_hand(origin, side)

	screen = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(SCREEN_WIDTH, SCREEN_WIDTH * DashboardUI.SIZE.y / DashboardUI.SIZE.x)
	screen.mesh = quad
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = viewport.get_texture()
	screen.material_override = material
	add_child(screen)

	var xr := XRServer.find_interface("OpenXR")
	xr_active = xr != null and xr.is_initialized()
	if xr_active:
		get_viewport().use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		ui.set_status("Running in the headset through %s." % xr.get_system_info().get("XRRuntimeName", "an OpenXR runtime"))
	else:
		centre = Vector3(0, SCREEN_HEIGHT_ABOVE_FLOOR, -0.8)     # closer, so it fills the preview window
		ui.set_status("No headset found, so this is the desktop preview. Start the runtime (gogglesxr start), connect the headset and run the dashboard again.")
	overlay = OS.get_environment("GOGGLESXR_OVERLAY_ACTIVE") == "1"
	if OS.get_environment("GOGGLESXR_OVERLAY") != "" and not overlay and OS.get_environment("GOGGLESXR_SELFTEST") == "":
		# Asked to sit on top of a game, but there is no headset session to do that in
		push_warning("GogglesXR dashboard: no overlay session (no headset connected, or the runtime lacks XR_EXTX_overlay)")
		get_tree().quit(3)
		return
	print("GogglesXR dashboard: ", "in the headset" if xr_active else "desktop preview", ", as an overlay on top of games" if overlay else "")
	if overlay:
		_setup_overlay()
	if xr_active and animations:
		open_amount = 0.0                 # the dashboard grows into view when it starts
		_set_shown.call_deferred(true)
	if xr_active and not _load_place():
		_reset_place()
	_apply_screen()
	_debug_hooks()


# ------------------------------------------------------------------ overlay
## Make everything except the dashboard see-through, so the game shows around it.
func _setup_overlay() -> void:
	get_viewport().transparent_bg = true
	# Keep our own desktop window out of the way: the game's window stays the active one,
	# which is also what Screenshot captures
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	# Godot only tells the runtime to blend our picture by its transparency when another
	# layer sits underneath it. This one is a single clear pixel behind you.
	var clear_view := SubViewport.new()
	clear_view.size = Vector2i(2, 2)
	clear_view.transparent_bg = true
	clear_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(clear_view)
	var under := OpenXRCompositionLayerQuad.new()
	under.layer_viewport = clear_view
	under.quad_size = Vector2(0.01, 0.01)
	under.sort_order = -1
	under.alpha_blend = true
	under.position = Vector3(0, -50, 50)
	origin_node.add_child(under)
	ui.say("Menu button: show or hide the dashboard")


func _set_shown(on: bool) -> void:
	shown = on
	if not on:
		ui.swipe_end()
		_move_end()
		if mouse_buttons != 0:
			_send_button(MOUSE_BUTTON_LEFT, false)
		for side in hands:
			hands[side].laser.visible = false
			hands[side].dot.visible = false
	if open_tween:
		open_tween.kill()
	if not animations:
		_set_open_amount(1.0 if on else 0.0)
		return
	# Opening: the panel grows out and fades in. Closing: the reverse, a little quicker.
	open_tween = create_tween()
	open_tween.tween_method(_set_open_amount, open_amount, 1.0 if on else 0.0, 0.26 if on else 0.18) \
			.set_trans(Tween.TRANS_BACK if on else Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT if on else Tween.EASE_IN)


func _set_open_amount(amount: float) -> void:
	open_amount = amount
	screen.visible = amount > 0.01
	(screen.material_override as StandardMaterial3D).albedo_color.a = clampf(amount, 0.0, 1.0)
	_apply_screen()


# ------------------------------------------------------------------ pointer smoothing
## Steadies a pointing ray. Hands shake a little, and a laser turns that into a jumpy dot a
## metre and a half away. Slow movement is smoothed a lot and fast movement barely at all, so
## the pointer holds still on a button but keeps up when you swing across the panel.
func _smooth_ray(hand: Dictionary, from: Vector3, dir: Vector3, delta: float) -> void:
	if smoothing <= 0.01 or hand.dir == Vector3.ZERO or delta <= 0.0:
		hand.from = from
		hand.dir = dir
		return
	var speed := rad_to_deg(hand.dir.angle_to(dir)) / delta            # degrees per second
	var slow := pow(1.0 - smoothing, 2.0) * 0.75 + 0.02               # how closely a slow hand is followed
	var follow := lerpf(slow, 1.0, clampf((speed - 8.0) / 80.0, 0.0, 1.0))
	var step := 1.0 - pow(1.0 - follow, delta * 90.0)                  # the same feel at any frame rate
	hand.from = hand.from.lerp(from, step)
	hand.dir = hand.dir.slerp(dir, step).normalized()


func _prefs_path() -> String:
	var config := OS.get_environment("XDG_CONFIG_HOME")
	if config == "":
		config = OS.get_environment("HOME").path_join(".config")
	return config.path_join("gogglesxr/settings.json")


## Settings shared with the GogglesXR desktop app.
func _load_prefs() -> void:
	var file := FileAccess.open(_prefs_path(), FileAccess.READ)
	if file == null:
		return
	var data: Variant = JSON.parse_string(file.get_as_text())
	if data is Dictionary:
		smoothing = clampf(float(data.get("pointer_smoothing", 60)) / 100.0, 0.0, 1.0)
		animations = bool(data.get("animations", true))


func _save_prefs() -> void:
	var data := {}
	var file := FileAccess.open(_prefs_path(), FileAccess.READ)
	if file:
		var old: Variant = JSON.parse_string(file.get_as_text())
		if old is Dictionary:
			data = old
		file.close()
	data["pointer_smoothing"] = int(round(smoothing * 100.0))
	DirAccess.make_dir_recursive_absolute(_prefs_path().get_base_dir())
	file = FileAccess.open(_prefs_path(), FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, " "))


# ------------------------------------------------------------------ running game
## Steam starts every game through a helper whose command line names the game's id.
## Runs on a thread. The commands are kept free of quotes and $ signs because Godot passes
## them through a shell of its own. Returns "<seconds running> <command line>" or "".
func _find_game() -> String:
	var out := []
	# The [d] stops pgrep from matching its own command line
	if OS.execute("pgrep", ["-af", "SteamLaunch AppI[d]="], out) != 0 or out.is_empty():
		return ""
	var line := str(out[0]).split("\n")[0].strip_edges()
	var pid := line.get_slice(" ", 0)
	if not pid.is_valid_int():
		return ""
	var age := []
	OS.execute("ps", ["-o", "etimes=", "-p", pid], age)
	var seconds := str(age[0]).strip_edges() if not age.is_empty() else "0"
	return (seconds if seconds.is_valid_int() else "0") + " " + line.substr(pid.length() + 1)


func _poll_game(delta: float) -> void:
	if OS.get_environment("GOGGLESXR_SELFTEST") != "":
		return                                # the self-test feeds the panel itself
	if game_thread and not game_thread.is_alive():
		ui.set_game(_parse_game(game_thread.wait_to_finish()))
		game_thread = null
	game_wait -= delta
	if game_wait <= 0.0 and game_thread == null:
		game_wait = 3.0
		game_thread = Thread.new()
		game_thread.start(_find_game)


## -> {"id", "seconds"} for the running game, or {} when there is none.
func _parse_game(text: String) -> Dictionary:
	var found := RegEx.new()
	found.compile("^\\s*(\\d+)\\s.*SteamLaunch AppId=(\\d+)")
	for line in text.split("\n"):
		var m := found.search(line)
		if m:
			return {"id": m.get_string(2), "seconds": int(m.get_string(1))}
	return {}


func _exit_tree() -> void:
	if game_thread:
		game_thread.wait_to_finish()
	for job in tool_jobs:
		job.wait_to_finish()


# ------------------------------------------------------------------ scene
# ------------------------------------------------------------------ scene
func _make_hand(origin: XROrigin3D, side: String) -> Dictionary:
	var controller := XRController3D.new()
	controller.tracker = &"left_hand" if side == "left" else &"right_hand"
	controller.pose = &"aim"
	origin.add_child(controller)
	var laser := MeshInstance3D.new()
	var beam := BoxMesh.new()
	beam.size = Vector3(0.004, 0.004, 1.0)
	laser.mesh = beam
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = DashboardUI.ACCENT
	laser.material_override = glow
	laser.visible = false
	add_child(laser)                      # placed along the smoothed pointing ray each frame
	var dot := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.012
	ball.height = 0.024
	dot.mesh = ball
	var bright := StandardMaterial3D.new()
	bright.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bright.albedo_color = DashboardUI.ACCENT_2
	bright.no_depth_test = true
	dot.material_override = bright
	dot.visible = false
	add_child(dot)
	# A second pose for the same hand: where the controller is held, for drawing its model
	var held := XRController3D.new()
	held.tracker = controller.tracker
	held.pose = &"grip"
	origin.add_child(held)
	return {"controller": controller, "laser": laser, "dot": dot, "trigger": false, "grip": false,
			"from": Vector3.ZERO, "dir": Vector3.ZERO, "held": held, "model": null, "profile": "?", "side": side}


# ------------------------------------------------------------------ controller models
## Drawn while the dashboard is open, so you can see your hands over the game. These are
## Goggles-styled stand-ins built from simple shapes, chosen by the kind of controller the
## runtime reports. They are not the manufacturers' own models.
const BODY := Color(0.2, 0.31, 0.28)

func _controller_kind(profile: String) -> String:
	if profile.contains("touch_controller_plus") or profile.contains("touch_plus") or profile.contains("touch_controller_pro") or profile.contains("touch_pro"):
		return "touch_plus"               # Quest 3 / Pro: no tracking ring
	if profile.contains("touch"):
		return "touch"                    # Quest 1 / 2, Rift: tracking ring
	if profile.contains("index"):
		return "index"
	if profile.contains("vive"):
		return "wand"
	return "generic"


func _part(parent: Node3D, mesh: Mesh, at: Vector3, colour: Color, turn := Vector3.ZERO, glow := false) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.position = at
	part.rotation_degrees = turn
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	if glow:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	else:
		material.metallic = 0.2
		material.roughness = 0.55
		material.emission_enabled = true
		material.emission = colour * 0.3       # never fully dark, whatever the lighting
	part.material_override = material
	parent.add_child(part)
	return part


func _capsule(radius: float, length: float) -> CapsuleMesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = length
	return mesh


func _disc(radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	return mesh


func _ring(radius: float, thickness: float) -> TorusMesh:
	var mesh := TorusMesh.new()
	mesh.inner_radius = radius - thickness
	mesh.outer_radius = radius + thickness
	return mesh


func _slab(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh


## In the grip pose the handle runs along Z, with -Z pointing forward out of the hand.
func _make_controller_model(kind: String, side: String) -> Node3D:
	var model := Node3D.new()
	var mirror := -1.0 if side == "left" else 1.0     # buttons sit towards the other hand
	var dim := Color(DashboardUI.ACCENT, 1.0) * 0.35
	var lights := {}
	if kind == "wand":
		_part(model, _capsule(0.019, 0.19), Vector3(0, -0.01, 0.05), BODY, Vector3(90, 0, 0))
		_part(model, _ring(0.05, 0.012), Vector3(0, 0.03, -0.075), BODY, Vector3(-30, 0, 0))
		lights["primary"] = _part(model, _disc(0.021, 0.004), Vector3(0, 0.012, -0.005), dim, Vector3.ZERO, true)
		lights["trigger"] = _part(model, _slab(Vector3(0.018, 0.02, 0.03)), Vector3(0, -0.035, -0.025), dim, Vector3(20, 0, 0), true)
		lights["grip"] = _part(model, _slab(Vector3(0.042, 0.012, 0.035)), Vector3(0, -0.012, 0.07), dim, Vector3.ZERO, true)
	else:
		_part(model, _capsule(0.018, 0.115), Vector3(0, -0.012, 0.035), BODY, Vector3(72, 0, 0))
		var head := _part(model, _disc(0.028, 0.024), Vector3(0, 0.004, -0.026), BODY, Vector3(-18, 0, 0))
		lights["primary"] = _part(head, _disc(0.009, 0.012), Vector3(-0.009 * mirror, 0.014, 0.004), dim, Vector3.ZERO, true)
		lights["ax_button"] = _part(head, _disc(0.0055, 0.004), Vector3(0.012 * mirror, 0.012, 0.008), dim, Vector3.ZERO, true)
		lights["by_button"] = _part(head, _disc(0.0055, 0.004), Vector3(0.007 * mirror, 0.012, -0.008), dim, Vector3.ZERO, true)
		lights["trigger"] = _part(model, _slab(Vector3(0.016, 0.022, 0.026)), Vector3(0, -0.012, -0.052), dim, Vector3(25, 0, 0), true)
		lights["grip"] = _part(model, _slab(Vector3(0.008, 0.02, 0.034)), Vector3(-0.019 * mirror, -0.022, 0.03), dim, Vector3(72, 0, 0), true)
		if kind == "touch":
			_part(model, _ring(0.05, 0.006), Vector3(0, 0.03, -0.05), BODY, Vector3(-60, 0, 0))
		elif kind == "index":
			_part(model, _ring(0.05, 0.005), Vector3(0.012 * mirror, -0.012, 0.035), BODY, Vector3(72, 0, 90))
	# a thin accent band, so it reads as Goggles hardware
	_part(model, _ring(0.0195, 0.0015), Vector3(0, -0.012, 0.035), Color(DashboardUI.ACCENT, 1.0), Vector3(72 + 90, 0, 0), true)
	model.set_meta("lights", lights)
	model.set_meta("dim", dim)
	return model


## Give each hand the model for its controller, and light the buttons that are pressed.
func _update_models() -> void:
	for side in hands:
		var hand: Dictionary = hands[side]
		var tracker := XRServer.get_tracker(hand.held.tracker) as XRPositionalTracker
		var profile: String = tracker.profile if tracker else ""
		if profile != hand.profile:
			hand.profile = profile
			if hand.model:
				hand.model.queue_free()
			hand.model = _make_controller_model(_controller_kind(profile), side)
			hand.held.add_child(hand.model)
		var model: Node3D = hand.model
		model.visible = shown and open_amount > 0.5 and hand.held.get_has_tracking_data()
		if not model.visible:
			continue
		var lights: Dictionary = model.get_meta("lights")
		var dim: Color = model.get_meta("dim")
		for input in lights:
			var pressed := 0.0
			if input == "trigger" or input == "grip":
				pressed = hand.controller.get_float(input)
			elif input == "primary":
				pressed = minf(1.0, hand.controller.get_vector2(&"primary").length() * 1.2)
			else:
				pressed = 1.0 if hand.controller.is_button_pressed(input) else 0.0
			((lights[input] as MeshInstance3D).material_override as StandardMaterial3D).albedo_color = dim.lerp(DashboardUI.ACCENT_2, clampf(pressed, 0.0, 1.0))


# ------------------------------------------------------------------ gogglesxr commands
## Run "gogglesxr <command>" on a thread and show its one-line answer on the dashboard.
func _run_tool(command: String) -> void:
	var job := Thread.new()
	job.set_meta("command", command)
	job.start(func() -> String:
		var out := []
		OS.execute("gogglesxr", [command], out)
		return str(out[0]).strip_edges().split("\n")[-1] if not out.is_empty() else "")
	tool_jobs.append(job)


func _collect_tool_jobs() -> void:
	for job in tool_jobs.duplicate():
		if job.is_alive():
			continue
		var answer: String = job.wait_to_finish()
		tool_jobs.erase(job)
		if answer != "":
			ui.say(answer)
		if job.get_meta("command") == "record":
			ui.set_recording(answer.begins_with("Recording the screen"))
		if job.get_meta("command") == "quit-game":
			game_wait = 0.0                   # look again straight away


func _head() -> Vector3:
	return camera.global_position


## Stand the screen at `centre`, facing the head. Further away means bigger: it scales with its
## distance from the head, so moving it changes how much room it takes, not how readable it is.
func _apply_screen() -> void:
	var to_screen := centre - _head()
	var away := to_screen.length()
	if away < 0.05:
		to_screen = Vector3.FORWARD
		away = 0.05
	var facing := to_screen / away
	var up := Vector3.UP if absf(facing.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
	var factor := size_factor * away / REFERENCE_DISTANCE * lerpf(0.8, 1.0, clampf(open_amount, 0.0, 1.2))
	screen.global_transform = Transform3D(Basis.looking_at(facing, up), centre).scaled_local(Vector3.ONE * factor)


## Default spot: straight ahead of where the head is looking, a little below eye level.
func _reset_place() -> void:
	var head := camera.global_transform
	var forward := -head.basis.z
	forward.y = 0
	forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
	centre = head.origin + forward * REFERENCE_DISTANCE + Vector3.DOWN * 0.15
	_apply_screen()


## Recentre: the runtime makes the way you are facing the new "forward" for the game, and the
## dashboard returns to its place in front of you.
func _recentre() -> void:
	if xr_active:
		_run_tool("recenter")
		await get_tree().create_timer(0.4).timeout    # let the runtime move the world first
	else:
		ui.say("View recentred")
	_reset_place()
	_save_place()


func _save_place() -> void:
	if not xr_active and OS.get_environment("GOGGLESXR_SELFTEST") == "":
		return                                # the preview window's spot isn't worth keeping
	var file := ConfigFile.new()
	file.set_value("dashboard", "centre", centre)
	file.set_value("dashboard", "size", size_factor)
	file.save(SETTINGS_FILE)


func _load_place() -> bool:
	var file := ConfigFile.new()
	if file.load(SETTINGS_FILE) != OK:
		return false
	var saved: Variant = file.get_value("dashboard", "centre", null)
	if not saved is Vector3:
		return false
	centre = saved
	size_factor = clampf(float(file.get_value("dashboard", "size", 1.0)), 0.4, 2.5)
	return true


# ------------------------------------------------------------------ moving the dashboard
## Grip pressed on the status bar: hold the dashboard by that spot.
func _move_begin() -> bool:
	var plane := Plane(screen.global_transform.basis.z.normalized(), screen.global_position)
	var hit: Variant = plane.intersects_ray(ray_from, ray_dir)
	if hit == null:
		return false
	moving = true
	move_local = screen.to_local(hit)
	move_reach = ray_from.distance_to(hit)
	return true


## While held: the grabbed spot stays on the laser. `push` (stick forward/back, -1..1) slides it
## along the laser, further away or closer.
func _move_update(push: float, delta: float) -> void:
	if not moving:
		return
	if absf(push) > 0.25:
		move_reach = clampf(move_reach + push * 1.6 * delta * maxf(move_reach, 0.6), MIN_DISTANCE, MAX_DISTANCE)
	var spot := ray_from + ray_dir * move_reach
	# Where the centre must be for the grabbed spot to sit there (size follows distance, so
	# settle it over a few passes)
	for i in 3:
		var factor := size_factor * maxf(_head().distance_to(centre), 0.05) / REFERENCE_DISTANCE
		centre = spot - screen.global_transform.basis.orthonormalized() * (move_local * factor)
		var away := _head().distance_to(centre)
		if away < MIN_DISTANCE or away > MAX_DISTANCE:
			centre = _head() + (centre - _head()).normalized() * clampf(away, MIN_DISTANCE, MAX_DISTANCE)
		_apply_screen()


func _move_end() -> void:
	if moving:
		moving = false
		_save_place()


# ------------------------------------------------------------------ pointer
## Where a ray hits the screen, in dashboard pixels. Returns null when it misses.
func _ray_to_pixels(from: Vector3, direction: Vector3) -> Variant:
	var plane := Plane(screen.global_transform.basis.z.normalized(), screen.global_position)
	var hit: Variant = plane.intersects_ray(from, direction)
	if hit == null:
		return null
	var local: Vector3 = screen.to_local(hit)
	var half: Vector2 = (screen.mesh as QuadMesh).size / 2.0
	if absf(local.x) > half.x or absf(local.y) > half.y:
		return null
	return Vector2((local.x / half.x + 1.0) / 2.0, (1.0 - local.y / half.y) / 2.0) * DashboardUI.SIZE


func _send_motion(at: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = at - pointer if pointer.x >= 0 else Vector2.ZERO
	event.button_mask = mouse_buttons
	pointer = at
	viewport.push_input(event, true)


func _send_button(button: MouseButton, pressed: bool) -> void:
	if pointer.x < 0:
		return
	if button == MOUSE_BUTTON_LEFT:
		mouse_buttons = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	var event := InputEventMouseButton.new()
	event.position = pointer
	event.global_position = pointer
	event.button_index = button
	event.pressed = pressed
	event.button_mask = mouse_buttons
	viewport.push_input(event, true)


func _scroll(amount: float) -> void:
	var button := MOUSE_BUTTON_WHEEL_UP if amount > 0 else MOUSE_BUTTON_WHEEL_DOWN
	_send_button(button, true)
	_send_button(button, false)


## Grip on a panel swipes it; grip on the status bar underneath moves the whole dashboard.
func _grip(pressed: bool) -> void:
	if not pressed:
		ui.swipe_end()
		_move_end()
		return
	if pointer.x < 0:
		return
	if mouse_buttons != 0:
		_send_button(MOUSE_BUTTON_LEFT, false)
	if pointer.y <= DashboardUI.PANEL_SIZE.y:
		grab_start = pointer
		ui.swipe_begin()
	else:
		_move_begin()


# ------------------------------------------------------------------ headset input
func _process(delta: float) -> void:
	_poll_game(delta)
	_collect_tool_jobs()
	if not xr_active:
		return
	_update_models()
	scroll_wait = maxf(0.0, scroll_wait - delta)
	if overlay:
		var menu := false
		for side in hands:
			var c: XRController3D = hands[side].controller
			menu = menu or (c.get_has_tracking_data() and c.is_button_pressed(&"menu_button"))
		if menu and not menu_was_down:
			_set_shown(not shown)
		menu_was_down = menu
		if not shown:
			return
	for side in hands:
		var hand: Dictionary = hands[side]
		var controller: XRController3D = hand.controller
		var tracked := controller.get_has_tracking_data()
		var trigger := tracked and controller.get_float(&"trigger") > 0.6
		var grip := tracked and controller.get_float(&"grip") > 0.6
		# Whichever hand pressed something last does the pointing
		if (trigger and not hand.trigger) or (grip and not hand.grip):
			if side != active_hand and not ui.is_swiping() and mouse_buttons == 0:
				active_hand = side
		var aim := controller.global_transform
		if tracked:
			_smooth_ray(hand, aim.origin, -aim.basis.z, delta)
		else:
			hand.dir = Vector3.ZERO
		var hit: Variant = _ray_to_pixels(hand.from, hand.dir) if tracked else null
		var length := LASER_LENGTH
		if hit != null:
			length = hand.from.distance_to(_pixels_to_world(hit))
		hand.laser.visible = tracked
		if tracked:
			var up := Vector3.UP if absf(hand.dir.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
			# Stretch the beam along its own length (not along the room's axes, which twists it)
			hand.laser.global_transform = Transform3D(Basis.looking_at(hand.dir, up) * Basis.from_scale(Vector3(1, 1, length)), hand.from + hand.dir * length / 2.0)
		hand.dot.visible = hit != null
		if hit != null:
			hand.dot.global_position = _pixels_to_world(hit)

		if side == active_hand:
			ray_from = hand.from
			ray_dir = hand.dir
			var stick := controller.get_vector2(&"primary")
			if moving:
				_move_update(stick.y, delta)
			else:
				if hit != null:
					_send_motion(hit)
					if ui.is_swiping():
						ui.swipe_move(hit - grab_start)
				if trigger != hand.trigger and not ui.is_swiping():
					_send_button(MOUSE_BUTTON_LEFT, trigger)
				if absf(stick.y) > 0.5 and scroll_wait == 0.0 and hit != null:
					_scroll(stick.y)
					scroll_wait = 0.12
			if grip != hand.grip:
				_grip(grip)
		hand.trigger = trigger
		hand.grip = grip


func _pixels_to_world(at: Vector2) -> Vector3:
	var half: Vector2 = (screen.mesh as QuadMesh).size / 2.0
	var uv := at / DashboardUI.SIZE
	return screen.to_global(Vector3((uv.x * 2.0 - 1.0) * half.x, (1.0 - uv.y * 2.0) * half.y, 0.002))


# ------------------------------------------------------------------ desktop preview input
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		get_tree().quit()
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_UP: ui.go("up")
			KEY_DOWN: ui.go("down")
			KEY_LEFT: ui.go("left")
			KEY_RIGHT: ui.go("right")
	if xr_active or not event is InputEventMouse:
		return
	ray_from = camera.project_ray_origin(event.position)
	ray_dir = camera.project_ray_normal(event.position)
	var hit: Variant = _ray_to_pixels(ray_from, ray_dir)
	if moving:
		_move_update(0.0, 0.0)
	elif hit != null:
		_send_motion(hit)
		if ui.is_swiping():
			ui.swipe_move(hit - grab_start)
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if not ui.is_swiping() and not moving:
					_send_button(MOUSE_BUTTON_LEFT, event.pressed)
			MOUSE_BUTTON_RIGHT: _grip(event.pressed)
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					var up := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
					if moving:
						_move_update(up, 0.25)      # wheel = stick push while holding the bar
					else:
						_scroll(up)


# ------------------------------------------------------------------ testing hooks
## GOGGLESXR_PANEL=library       open on a given panel
## GOGGLESXR_SHOT=/path/out.png  save a picture of the window after a moment, then quit
## GOGGLESXR_TEST_BG=1           fill the background with a loud colour (to stand in for a game)
## GOGGLESXR_SHOW_MODELS=1       desktop preview: line up every controller model, with lasers
## GOGGLESXR_SELFTEST=1          drive the dashboard through its pointer code, print results, quit
func _debug_hooks() -> void:
	var start_panel := OS.get_environment("GOGGLESXR_PANEL")
	if DashboardUI.POS.has(start_panel):
		ui.show_panel(start_panel, false)
	if OS.get_environment("GOGGLESXR_SHOW_MODELS") != "":
		_show_models()
	if OS.get_environment("GOGGLESXR_TEST_BG") != "":
		RenderingServer.set_default_clear_color(Color(0.75, 0.1, 0.45))
	if OS.get_environment("GOGGLESXR_SELFTEST") != "":
		_selftest.call_deferred()
	elif OS.get_environment("GOGGLESXR_SHOT") != "":
		await get_tree().create_timer(1.5).timeout
		print("Current Game panel: ", ui.game_title(), " / ", ui.game_state())
		get_viewport().get_texture().get_image().save_png(OS.get_environment("GOGGLESXR_SHOT"))
		get_tree().quit()


func _show_models() -> void:
	screen.visible = false
	var kinds := ["touch", "touch_plus", "index", "wand", "generic"]
	for i in kinds.size():
		for side_index in 2:
			var model := _make_controller_model(kinds[i], ["left", "right"][side_index])
			add_child(model)
			# held as you would hold it: pointing away and a little up
			model.transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(25), deg_to_rad(18 - 36 * side_index), 0)),
					camera.position + Vector3(-0.56 + 0.28 * i + (0.06 if side_index else -0.06), -0.02, -0.55))
			if kinds[i] == "touch" or kinds[i] == "wand":
				var beam := MeshInstance3D.new()
				var box := BoxMesh.new()
				box.size = Vector3(0.004, 0.004, 1.0)
				beam.mesh = box
				beam.material_override = hands["left"].laser.material_override
				add_child(beam)
				var aim := (-model.transform.basis.z).normalized()
				var beam_up := Vector3.UP if absf(aim.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
				beam.global_transform = Transform3D(Basis.looking_at(aim, beam_up) * Basis.from_scale(Vector3(1, 1, 0.6)), model.position + aim * 0.36)


func _selftest() -> void:
	var fails := [0]
	var grab_at := Vector2(640, 60)
	var swipe := func(by: Vector2, hold_ms: int) -> void:
		_send_motion(grab_at)
		_grip(true)
		for step in range(1, 6):
			_send_motion(grab_at + by * step / 5.0)
			ui.swipe_move(pointer - grab_start)
		await get_tree().create_timer(hold_ms / 1000.0).timeout
		_grip(false)
		await get_tree().create_timer(0.5).timeout
	var expect := func(what: String, want: String) -> void:
		var ok := ui.current == want
		print(("PASS " if ok else "FAIL ") + what + " -> " + ui.current)
		if not ok:
			fails[0] += 1

	await get_tree().create_timer(0.3).timeout
	expect.call("start", "game")
	await swipe.call(Vector2(0, -300), 300)
	expect.call("slide card up", "desktop")
	await swipe.call(Vector2(-400, 0), 300)
	expect.call("slide left on Desktop (nothing there)", "desktop")
	await swipe.call(Vector2(0, 300), 300)
	expect.call("slide top to bottom", "game")
	await swipe.call(Vector2(-400, 0), 300)
	expect.call("slide right to left", "library")
	await swipe.call(Vector2(60, 0), 400)
	expect.call("small slow slide springs back", "library")
	await swipe.call(Vector2(400, 0), 300)
	await swipe.call(Vector2(400, 0), 300)
	expect.call("two slides left to right", "settings")
	ui.show_panel("game", false)

	# Trigger click on "Open library" through the same pointer code the lasers use
	var button: Button = ui.find_children("", "Button", true, false).filter(func(b): return b.text == "Open library")[0]
	_send_motion(button.global_position + button.size / 2.0)
	_send_button(MOUSE_BUTTON_LEFT, true)
	_send_button(MOUSE_BUTTON_LEFT, false)
	await get_tree().create_timer(0.5).timeout
	expect.call("trigger on Open library", "library")

	# A ray from the camera through the middle of the screen lands mid-dashboard
	var hit: Variant = _ray_to_pixels(camera.global_position, (screen.global_position - camera.global_position).normalized())
	var centred: bool = hit != null and (hit as Vector2).distance_to(DashboardUI.SIZE / 2.0) < 2.0
	print(("PASS " if centred else "FAIL ") + "ray to screen centre -> " + str(hit))
	var miss: Variant = _ray_to_pixels(camera.global_position, Vector3.UP)
	print(("PASS " if miss == null else "FAIL ") + "ray pointing away misses")
	if not centred or miss != null:
		fails[0] += 1

	# Move the dashboard: grip on the status bar, swing the laser right, push the stick forward
	var head := _head()
	var bar := _pixels_to_world(Vector2(640, 800))
	var aim_at := func(point: Vector3) -> void:
		ray_from = head + Vector3(0.2, -0.3, 0)
		ray_dir = (point - ray_from).normalized()
		_send_motion(_ray_to_pixels(ray_from, ray_dir))
	var check := func(what: String, ok: bool, detail: String) -> void:
		print(("PASS " if ok else "FAIL ") + what + " -> " + detail)
		if not ok:
			fails[0] += 1
	aim_at.call(bar)
	var start_centre := centre
	var start_width := screen.global_transform.basis.x.length()
	_grip(true)
	check.call("grip on the status bar starts a move, not a swipe", moving and not ui.is_swiping(), str(moving))
	ray_dir = ray_dir.rotated(Vector3.UP, deg_to_rad(-25))
	_move_update(0.0, 0.016)
	check.call("dashboard follows the laser to the right", centre.x > start_centre.x + 0.3, "x %.2f -> %.2f" % [start_centre.x, centre.x])
	var held: Variant = _ray_to_pixels(ray_from, ray_dir)
	check.call("grabbed spot stays under the laser", held != null and (held as Vector2).distance_to(Vector2(640, 800)) < 6.0, str(held))
	var near := head.distance_to(centre)
	for i in 30:
		_move_update(1.0, 0.016)
	var far := head.distance_to(centre)
	var far_width := screen.global_transform.basis.x.length()
	check.call("stick forward sends it further away", far > near + 0.3, "%.2f m -> %.2f m" % [near, far])
	check.call("further away is bigger", far_width > start_width * 1.1, "scale %.2f -> %.2f" % [start_width, far_width])
	for i in 400:
		_move_update(-1.0, 0.016)
	var closest := head.distance_to(centre)
	check.call("stick back brings it closer and smaller, with a limit", closest < near and closest >= MIN_DISTANCE - 0.01 and screen.global_transform.basis.x.length() < start_width, "%.2f m" % closest)
	var facing := screen.global_transform.basis.z.normalized().dot((head - centre).normalized())
	check.call("it still faces you", facing > 0.99, "%.3f" % facing)
	_grip(false)
	var kept := centre
	centre = Vector3.ZERO
	check.call("position is remembered", not moving and _load_place() and centre.distance_to(kept) < 0.001, str(centre))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_FILE))

	# Pointer smoothing: a shaky hand barely moves the ray, a fast swing gets through
	var hand := {"from": Vector3.ZERO, "dir": Vector3.FORWARD}
	smoothing = 0.6
	var wobble := 0.0                 # a hand tremor: a tenth of a degree, ten times a second
	for i in 180:
		_smooth_ray(hand, Vector3.ZERO, Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(0.1 * sin(i / 90.0 * TAU * 10.0))), 1.0 / 90.0)
		if i > 90:
			wobble = maxf(wobble, rad_to_deg(hand.dir.angle_to(Vector3.FORWARD)))
	check.call("smoothing steadies a shaky hand", wobble < 0.03, "0.100 degrees of shake -> %.3f" % wobble)
	var swing := Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(30))
	for i in 12:
		_smooth_ray(hand, Vector3.ZERO, swing, 1.0 / 90.0)
	var behind := rad_to_deg(hand.dir.angle_to(swing))
	check.call("a fast swing is followed quickly", behind < 3.0, "%.2f degrees behind after 0.13 s" % behind)
	smoothing = 0.0
	_smooth_ray(hand, Vector3.ZERO, Vector3.UP, 1.0 / 90.0)
	check.call("smoothing off follows exactly", hand.dir == Vector3.UP, str(hand.dir))

	# Open and close animation
	animations = true
	_set_shown(false)
	await get_tree().create_timer(0.4).timeout
	check.call("closing hides the dashboard", not screen.visible and open_amount < 0.01, "%.2f" % open_amount)
	_set_shown(true)
	await get_tree().create_timer(0.08).timeout
	var mid := open_amount
	await get_tree().create_timer(0.45).timeout
	check.call("opening animates back to full size", mid > 0.0 and mid < 1.1 and screen.visible and absf(open_amount - 1.0) < 0.01, "%.2f on the way, %.2f at the end" % [mid, open_amount])

	# Lasers: the beam must run exactly from the hand to where it points, at any angle
	var beam_ok := true
	for aim_dir in [Vector3(0, 0, -1), Vector3(1, 0.4, -1).normalized(), Vector3(-0.3, -0.8, -0.2).normalized(), Vector3(0, 1, 0)]:
		var beam_up := Vector3.UP if absf(aim_dir.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
		var beam := Transform3D(Basis.looking_at(aim_dir, beam_up) * Basis.from_scale(Vector3(1, 1, 2.5)), Vector3(1, 1, 1) + aim_dir * 1.25)
		var tip := beam * Vector3(0, 0, -0.5)          # the far end of a unit-long box
		var tail := beam * Vector3(0, 0, 0.5)
		beam_ok = beam_ok and tip.distance_to(Vector3(1, 1, 1) + aim_dir * 2.5) < 0.001 and tail.distance_to(Vector3(1, 1, 1)) < 0.001
	check.call("laser beam runs from the hand to its target at any angle", beam_ok, str(beam_ok))

	# Controller models
	var kinds := {"/interaction_profiles/oculus/touch_controller": "touch", "/interaction_profiles/meta/touch_controller_plus": "touch_plus",
			"/interaction_profiles/valve/index_controller": "index", "/interaction_profiles/htc/vive_controller": "wand", "": "generic"}
	var models_ok := true
	for profile in kinds:
		models_ok = models_ok and _controller_kind(profile) == kinds[profile]
		for model_side in ["left", "right"]:
			var built := _make_controller_model(kinds[profile], model_side)
			models_ok = models_ok and built.get_child_count() >= 5 and (built.get_meta("lights") as Dictionary).has("trigger")
			built.free()
	check.call("a controller model is built for each kind of controller", models_ok, str(kinds.values()))

	# Current Game buttons
	var signals := []
	ui.screenshot_requested.connect(func(): signals.append("screenshot"))
	ui.quit_requested.connect(func(): signals.append("quit"))
	ui.set_game({"id": "620980", "seconds": 60})
	var named := func(text: String) -> Button:
		return ui.find_children("", "Button", true, false).filter(func(b): return b.text == text)[0]
	named.call("Screenshot").pressed.emit()
	named.call("Quit game").pressed.emit()
	check.call("Quit game asks for a second press", signals == ["screenshot"] and not named.call("Press again to quit").disabled, str(signals))
	named.call("Press again to quit").pressed.emit()
	check.call("the second press quits", signals == ["screenshot", "quit"], str(signals))
	ui.set_recording(true)
	check.call("Record clip turns into Stop recording", ui.find_children("", "Button", true, false).any(func(b): return b.text == "Stop recording"), "")
	ui.set_recording(false)
	ui.set_game({})
	check.call("Quit game is off when nothing is running", named.call("Quit game").disabled, "")

	# Game status
	var parsed := _parse_game(" 4321 reaper SteamLaunch AppId=620980 -- /usr/bin/game \n")
	check.call("running game is read from Steam's launcher", parsed.get("id") == "620980" and parsed.get("seconds") == 4321, str(parsed))
	check.call("no game running", _parse_game("").is_empty() and _parse_game("12 bash\n").is_empty(), "{}")
	ui.set_game(parsed)
	check.call("Current Game panel shows it", ui.game_title() == "Beat Saber" and ui.game_state().contains("1 H 12 M"), ui.game_title() + " / " + ui.game_state())
	ui.set_game({})
	check.call("and clears when it ends", ui.game_state().contains("NO GAME"), ui.game_state())
	print("games found: ", SteamLibrary.installed_games().size(), ", in the Library panel: ", SteamLibrary.games().size(),
			", with cover art: ", SteamLibrary.games().filter(func(g): return SteamLibrary.cover(str(g.get("art", "")), Vector2i(216, 300)) != null).size())
	print("SELFTEST " + ("OK" if fails[0] == 0 else "FAILED (%d)" % fails[0]))
	get_tree().quit(fails[0])
