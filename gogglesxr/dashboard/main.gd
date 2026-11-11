extends Node3D
## GogglesXR dashboard: shows the five-panel interface (dashboard_ui.gd) on a screen floating
## in front of you and turns controller lasers into pointer input.
##
## In the headset:  point with either controller, trigger = click, stick = scroll,
##                  hold grip and move the laser = swipe the panel.
##                  Hold grip on the status bar = move the dashboard; while holding, push the
##                  stick forward or back to send it further away (bigger) or closer (smaller).
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
	ui.scale_changed.connect(func(f): size_factor = f; _apply_screen(); _save_place())

	var origin := XROrigin3D.new()
	origin_node = origin
	add_child(origin)
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
	if xr_active and not _load_place():
		_reset_place()
	_apply_screen()
	_debug_hooks()


# ------------------------------------------------------------------ overlay
## Make everything except the dashboard see-through, so the game shows around it.
func _setup_overlay() -> void:
	get_viewport().transparent_bg = true
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
	screen.visible = on
	if not on:
		ui.swipe_end()
		_move_end()
		if mouse_buttons != 0:
			_send_button(MOUSE_BUTTON_LEFT, false)
		for side in hands:
			hands[side].laser.visible = false
			hands[side].dot.visible = false


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
	controller.add_child(laser)
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
	return {"controller": controller, "laser": laser, "dot": dot, "trigger": false, "grip": false}


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
	var factor := size_factor * away / REFERENCE_DISTANCE
	screen.global_transform = Transform3D(Basis.looking_at(facing, up), centre).scaled_local(Vector3.ONE * factor)


## Default spot: straight ahead of where the head is looking, a little below eye level.
func _reset_place() -> void:
	var head := camera.global_transform
	var forward := -head.basis.z
	forward.y = 0
	forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
	centre = head.origin + forward * REFERENCE_DISTANCE + Vector3.DOWN * 0.15
	_apply_screen()


func _recentre() -> void:
	if xr_active:
		XRServer.center_on_hmd(XRServer.RESET_BUT_KEEP_TILT, true)
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
	if not xr_active:
		return
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
		var hit: Variant = _ray_to_pixels(aim.origin, -aim.basis.z) if tracked else null
		var length := LASER_LENGTH
		if hit != null:
			length = aim.origin.distance_to(_pixels_to_world(hit))
		hand.laser.visible = tracked
		hand.laser.scale = Vector3(1, 1, length)
		hand.laser.position = Vector3(0, 0, -length / 2.0)
		hand.dot.visible = hit != null
		if hit != null:
			hand.dot.global_position = _pixels_to_world(hit)

		if side == active_hand:
			ray_from = aim.origin
			ray_dir = -aim.basis.z
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
## GOGGLESXR_SELFTEST=1          drive the dashboard through its pointer code, print results, quit
func _debug_hooks() -> void:
	var start_panel := OS.get_environment("GOGGLESXR_PANEL")
	if DashboardUI.POS.has(start_panel):
		ui.show_panel(start_panel, false)
	if OS.get_environment("GOGGLESXR_TEST_BG") != "":
		RenderingServer.set_default_clear_color(Color(0.75, 0.1, 0.45))
	if OS.get_environment("GOGGLESXR_SELFTEST") != "":
		_selftest.call_deferred()
	elif OS.get_environment("GOGGLESXR_SHOT") != "":
		await get_tree().create_timer(1.0).timeout
		get_viewport().get_texture().get_image().save_png(OS.get_environment("GOGGLESXR_SHOT"))
		get_tree().quit()


func _selftest() -> void:
	var failures := 0
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
			failures += 1

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
		failures += 1

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
			failures += 1
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
	print("games found: ", SteamLibrary.installed_games().size(), ", in the Library panel: ", SteamLibrary.games().size(),
			", with cover art: ", SteamLibrary.games().filter(func(g): return SteamLibrary.cover(str(g.get("art", "")), Vector2i(216, 300)) != null).size())
	print("SELFTEST " + ("OK" if failures == 0 else "FAILED (%d)" % failures))
	get_tree().quit(failures)
