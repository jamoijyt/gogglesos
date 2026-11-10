extends Node3D
## GogglesXR dashboard: shows the five-panel interface (dashboard_ui.gd) on a screen floating
## in front of you and turns controller lasers into pointer input.
##
## In the headset:  point with either controller, trigger = click, stick = scroll,
##                  hold grip and move the laser = swipe the panel.
## Without a headset it runs in a window for testing: left mouse = trigger,
## right mouse (hold and drag) = grip, mouse wheel = stick, arrow keys = change panel.
##
## This first version is a normal VR app. Running on top of a game needs the OpenXR overlay
## extension, which Godot doesn't have yet; that is the next step.

const DashboardUI := preload("res://dashboard_ui.gd")
const SteamLibrary := preload("res://steam_library.gd")

const SCREEN_WIDTH := 1.7                 # metres
const SCREEN_HEIGHT_ABOVE_FLOOR := 1.3
const LASER_LENGTH := 4.0

var ui: DashboardUI
var viewport: SubViewport
var screen: MeshInstance3D
var camera: XRCamera3D
var xr_active := false
var distance := 1.5
var screen_scale := 1.0
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
	ui.distance_changed.connect(func(m): distance = m; _place_screen())
	ui.scale_changed.connect(func(f): screen_scale = f; _place_screen())

	var origin := XROrigin3D.new()
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
	_place_screen()

	var xr := XRServer.find_interface("OpenXR")
	xr_active = xr != null and xr.is_initialized()
	if xr_active:
		get_viewport().use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		ui.set_status("Running in the headset through %s." % xr.get_system_info().get("XRRuntimeName", "an OpenXR runtime"))
	else:
		distance = 0.95                    # closer, so it fills the preview window
		_place_screen()
		ui.set_status("No headset found, so this is the desktop preview. Start the runtime (gogglesxr start), connect the headset and run the dashboard again.")
	_debug_hooks()


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


## Put the screen `distance` metres in front of where the head is looking (level, facing you).
func _place_screen() -> void:
	var head := camera.global_transform
	var forward := -head.basis.z
	forward.y = 0
	forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
	var centre := Vector3(head.origin.x, SCREEN_HEIGHT_ABOVE_FLOOR, head.origin.z) + forward * distance
	screen.global_transform = Transform3D(Basis.looking_at(forward, Vector3.UP), centre).scaled_local(Vector3.ONE * screen_scale)


func _recentre() -> void:
	if xr_active:
		XRServer.center_on_hmd(XRServer.RESET_BUT_KEEP_TILT, true)
	_place_screen()


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


func _grip(pressed: bool) -> void:
	if pressed and pointer.x >= 0 and pointer.y <= DashboardUI.PANEL_SIZE.y:
		if mouse_buttons != 0:
			_send_button(MOUSE_BUTTON_LEFT, false)
		grab_start = pointer
		ui.swipe_begin()
	elif not pressed:
		ui.swipe_end()


# ------------------------------------------------------------------ headset input
func _process(delta: float) -> void:
	if not xr_active:
		return
	scroll_wait = maxf(0.0, scroll_wait - delta)
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
			if hit != null:
				_send_motion(hit)
				if ui.is_swiping():
					ui.swipe_move(hit - grab_start)
			if trigger != hand.trigger and not ui.is_swiping():
				_send_button(MOUSE_BUTTON_LEFT, trigger)
			if grip != hand.grip:
				_grip(grip)
			var stick := controller.get_vector2(&"primary")
			if absf(stick.y) > 0.5 and scroll_wait == 0.0 and hit != null:
				_scroll(stick.y)
				scroll_wait = 0.12
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
	var hit: Variant = _ray_to_pixels(camera.project_ray_origin(event.position), camera.project_ray_normal(event.position))
	if hit != null:
		_send_motion(hit)
		if ui.is_swiping():
			ui.swipe_move(hit - grab_start)
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if not ui.is_swiping():
					_send_button(MOUSE_BUTTON_LEFT, event.pressed)
			MOUSE_BUTTON_RIGHT: _grip(event.pressed)
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_scroll(1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0)


# ------------------------------------------------------------------ testing hooks
## GOGGLESXR_PANEL=library       open on a given panel
## GOGGLESXR_SHOT=/path/out.png  save a picture of the window after a moment, then quit
## GOGGLESXR_SELFTEST=1          drive the dashboard through its pointer code, print results, quit
func _debug_hooks() -> void:
	var start_panel := OS.get_environment("GOGGLESXR_PANEL")
	if DashboardUI.POS.has(start_panel):
		ui.show_panel(start_panel, false)
	if OS.get_environment("GOGGLESXR_SELFTEST") != "":
		_selftest.call_deferred()
	elif OS.get_environment("GOGGLESXR_SHOT") != "":
		await get_tree().create_timer(1.0).timeout
		get_viewport().get_texture().get_image().save_png(OS.get_environment("GOGGLESXR_SHOT"))
		get_tree().quit()


func _selftest() -> void:
	var failures := 0
	var centre := Vector2(640, 60)
	var swipe := func(by: Vector2, hold_ms: int) -> void:
		_send_motion(centre)
		_grip(true)
		for step in range(1, 6):
			_send_motion(centre + by * step / 5.0)
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
	print("games found: ", SteamLibrary.installed_games().size())
	print("SELFTEST " + ("OK" if failures == 0 else "FAILED (%d)" % failures))
	get_tree().quit(failures)
