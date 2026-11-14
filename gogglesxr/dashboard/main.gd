extends Node3D
## GogglesXR dashboard: shows the five-panel interface (dashboard_ui.gd) on a screen floating
## in front of you and turns controller lasers into pointer input.
##
## In the headset:  point with either controller, trigger = click, stick = scroll,
##                  hold grip and move the laser = swipe the panel.
##                  Hold grip on the status bar = move the dashboard; while holding, push the
##                  stick forward or back to send it further away (bigger) or closer (smaller).
##                  Your controllers are drawn as models while the dashboard is open.
##                  Recentre counts down 3-2-1 (look straight ahead), then the runtime makes
##                  where you stand and the way you face the game's new centre.
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
const ControllerModels := preload("res://controller_models.gd")
const DesktopView := preload("res://desktop_view.gd")
const DesktopScreen := preload("res://desktop_screen.gd")
const DesktopInput := preload("res://desktop_input.gd")
const Keyboard := preload("res://keyboard.gd")
const KEYBOARD_WIDTH := 1.05              # metres
const HOME_IMAGE := "res://environments/goggles-home.jpg"
const BIG_SCREEN_WIDTH := 3.0             # metres
const BIG_SCREEN_DISTANCE := 3.2

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
var system_name := ""                     # the headset, as the runtime names it ("Meta Quest 3 on WiVRn")
var countdown_left := 0.0                 # recentre countdown: seconds to go
var countdown_phase := ""                 # "", "count", "wait" (runtime working), "done" (showing the result)
var countdown_root: Node3D                # the countdown's numbers, held in front of your eyes
var countdown_number: Label3D
var countdown_text: Label3D
var prefs := {}                           # settings.json, shared with the desktop app and gogglesxr
var world_env: WorldEnvironment
var home_sky: Sky                         # the home environment, when one is chosen and loaded
var home_shown := false
var game_info := {}                       # the Steam game running, from _poll_game
var headset_info := {}                    # gogglesxr headset --json
var headset_thread: Thread
var headset_wait := 0.0
var desktop: DesktopView
var desktop_panel_wanted := false
var screens: Array = []                  # floating desktop screens (DesktopScreen), one per monitor
var screen_grab: Node3D                   # the screen being carried, or null
var desktop_input: DesktopInput           # the PC's mouse and keyboard
var keyboard_view: SubViewport            # the virtual keyboard: drawn here...
var keyboard_ui: Keyboard
var keyboard_quad: MeshInstance3D         # ...and shown on this
var keyboard_for: Node3D                  # the screen it sits under, or null for the dashboard
var keyboard_pointer := Vector2(-1, -1)
var wheel_wait := 0.0


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
	ui.setting_changed.connect(_on_setting)
	ui.big_screen_toggled.connect(_pop_out_screens)
	ui.keyboard_requested.connect(func(): _show_keyboard(null, not keyboard_quad.visible or keyboard_for != null))
	desktop_input = DesktopInput.new()
	add_child(desktop_input)
	desktop_input.changed.connect(func(): if desktop_input.message != "": ui.say(desktop_input.message))
	desktop = DesktopView.new()
	add_child(desktop)
	desktop.changed.connect(_desktop_changed)
	_load_prefs()
	ui.set_smoothing(smoothing)
	ui.apply_settings(prefs)
	_apply_desktop_options()
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
	world.environment.ambient_light_energy = 1.0
	add_child(world)
	world_env = world
	camera = XRCamera3D.new()
	camera.position = Vector3(0, SCREEN_HEIGHT_ABOVE_FLOOR, 0)
	origin.add_child(camera)
	for side in ["left", "right"]:
		hands[side] = _make_hand(origin, side)
	_make_countdown()

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
		system_name = str(xr.get_system_info().get("XRSystemName", ""))
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
	_load_home()
	_make_keyboard()
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
	var text := file.get_as_text()
	var data: Variant = JSON.parse_string(text) if text.strip_edges() != "" else null
	if data is Dictionary:
		prefs = data
		smoothing = clampf(float(data.get("pointer_smoothing", 60)) / 100.0, 0.0, 1.0)
		animations = bool(data.get("animations", true))


## A choice made on the dashboard: saved for everything that shares settings.json.
func _on_setting(key: String, value: Variant) -> void:
	prefs[key] = value
	_save_setting(key, value)
	match key:
		"environment":
			_load_home()
		"desktop_screen", "desktop_fps":
			_apply_desktop_options()


func _save_setting(key: String, value: Variant) -> void:
	var data := {}
	var file := FileAccess.open(_prefs_path(), FileAccess.READ)
	if file:
		var text := file.get_as_text()
		var old: Variant = JSON.parse_string(text) if text.strip_edges() != "" else null
		if old is Dictionary:
			data = old
		file.close()
	data[key] = value
	DirAccess.make_dir_recursive_absolute(_prefs_path().get_base_dir())
	file = FileAccess.open(_prefs_path(), FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, " "))


func _save_prefs() -> void:
	_save_setting("pointer_smoothing", int(round(smoothing * 100.0)))


# ------------------------------------------------------------------ headset status
## Ask the streaming engine about the headset every few seconds (batteries, ping, stream):
## `gogglesxr headset --json` on a thread.
func _poll_headset(delta: float) -> void:
	if OS.get_environment("GOGGLESXR_SELFTEST") != "":
		return                                # the self-test feeds the strip itself
	if headset_thread and not headset_thread.is_alive():
		var text: String = headset_thread.wait_to_finish()
		headset_thread = null
		var data: Variant = JSON.parse_string(text) if text.begins_with("{") else null
		headset_info = data if data is Dictionary else {}
		ui.set_headset(headset_info)
	headset_wait -= delta
	if headset_wait <= 0.0 and headset_thread == null:
		headset_wait = 5.0
		headset_thread = Thread.new()
		headset_thread.start(func() -> String:
			var out := []
			OS.execute("gogglesxr", ["headset", "--json"], out)
			return str(out[0]).strip_edges().split("\n")[-1] if not out.is_empty() else "")


## Whether a VR game is running: Steam's launcher, GogglesXR's capture layer (refreshed every 2 s
## while a game draws), or an app the runtime reports that isn't an overlay like this one.
func _game_running() -> bool:
	if not game_info.is_empty():
		return true
	var status := _capture_status_path()
	if FileAccess.file_exists(status) and Time.get_unix_time_from_system() - FileAccess.get_modified_time(status) < 6:
		return true
	if overlay:                               # (in normal mode the main app is this dashboard)
		for app in headset_info.get("apps", []):
			if app is Dictionary and app.get("active", false) and not app.get("overlay", false):
				return true
	return false


func _capture_status_path() -> String:
	return OS.get_environment("HOME").path_join(".cache/gogglesxr/capture/game.status")


# ------------------------------------------------------------------ home environment
## A 360° picture around you while no game is running (Settings > Home): Goggles OS's own
## night scene, a picture of your own (chosen in the desktop app), or nothing.
func _load_home() -> void:
	home_sky = null
	var choice := str(prefs.get("environment", "goggles"))
	var path := ""
	if choice == "custom":
		path = str(prefs.get("environment_image", ""))
	elif choice != "none":
		path = ProjectSettings.globalize_path(HOME_IMAGE)
	if path != "":
		var image := Image.load_from_file(path) if FileAccess.file_exists(path) else null
		if image == null and choice == "custom":
			ui.say("Couldn't open your 360° picture; showing Goggles night instead")
			image = Image.load_from_file(ProjectSettings.globalize_path(HOME_IMAGE))
		if image:
			var material := PanoramaSkyMaterial.new()
			material.panorama = ImageTexture.create_from_image(image)
			home_sky = Sky.new()
			home_sky.sky_material = material
	_update_home(true)


func _update_home(force := false) -> void:
	if world_env == null:
		return
	# Over a game (overlay mode) the scene must stay see-through; on its own it is the backdrop
	var show := home_sky != null and (not overlay or not _game_running())
	if show == home_shown and not force:
		return
	home_shown = show
	var environment := world_env.environment
	if show:
		environment.sky = home_sky
		environment.background_mode = Environment.BG_SKY
	else:
		environment.background_mode = Environment.BG_CLEAR_COLOR
	if overlay:
		get_viewport().transparent_bg = not show


# ------------------------------------------------------------------ desktop view
func _desktop_changed() -> void:
	ui.set_desktop(desktop.texture, desktop.message)
	for screen in screens:
		screen.set_texture(desktop.texture)
		screen.visible = desktop.texture != null


## The Desktop panel wants pictures while it is in view; the floating screens while they exist.
func _update_desktop() -> void:
	var wanted := shown and open_amount > 0.5 and ui.current == "desktop" and not ui.is_swiping()
	if wanted != desktop_panel_wanted:
		desktop_panel_wanted = wanted
		desktop.want("panel", wanted)
	# Nothing to control: let go of the PC's mouse and keyboard
	if desktop_input.running() and screens.is_empty() and not wanted and not keyboard_quad.visible:
		desktop_input.stop()


## The PC's monitors, as parts of the desktop picture: [{"name", "region": Rect2 in 0..1}].
## From kscreen-doctor (Plasma's display settings); one entry for the whole desktop if that
## doesn't answer.
func _monitors() -> Array:
	var text := OS.get_environment("GOGGLESXR_MONITORS")
	var found := []
	if text == "":
		var out := []
		if OS.execute("kscreen-doctor", ["-j"], out) == 0 and not out.is_empty():
			text = str(out[0])
	var data: Variant = JSON.parse_string(text) if text.strip_edges().begins_with("{") or text.strip_edges().begins_with("[") else null
	var outputs: Array = data if data is Array else (data.get("outputs", []) if data is Dictionary else [])
	for o in outputs:
		if not o is Dictionary or not o.get("enabled", true) or not o.get("connected", true):
			continue
		var rect := Rect2()
		if o.has("w"):                    # the test format: {"name", "x", "y", "w", "h"}
			rect = Rect2(float(o.x), float(o.y), float(o.w), float(o.h))
		elif o.get("pos") is Dictionary and o.get("size") is Dictionary:
			var scale := maxf(float(o.get("scale", 1.0)), 0.1)
			var w := float(o.size.get("width", 0)) / scale
			var h := float(o.size.get("height", 0)) / scale
			if int(o.get("rotation", 1)) in [2, 8]:      # turned sideways
				var t := w
				w = h
				h = t
			rect = Rect2(float(o.pos.get("x", 0)), float(o.pos.get("y", 0)), w, h)
		if rect.size.x > 0 and rect.size.y > 0:
			found.append({"name": str(o.get("name", "Screen")), "rect": rect})
	if found.size() < 2:
		return [{"name": "Desktop", "region": Rect2(0, 0, 1, 1)}]
	var bounds: Rect2 = found[0].rect
	for m in found:
		bounds = bounds.merge(m.rect)
	found.sort_custom(func(a, b): return a.rect.position.x < b.rect.position.x)
	var result := []
	for m in found:
		var r: Rect2 = m.rect
		result.append({"name": m.name, "region": Rect2((r.position - bounds.position) / bounds.size, r.size / bounds.size)})
	return result


## Floating screens need the whole desktop (they crop their monitor out of it); the panel shows
## what the settings say.
func _apply_desktop_options() -> void:
	var which := "all" if not screens.is_empty() else str(prefs.get("desktop_screen", "all"))
	desktop.set_options(which, int(prefs.get("desktop_fps", 30)))


## Pop the desktop out into floating screens (one per monitor), or put them away.
func _pop_out_screens(on: bool) -> void:
	for screen in screens:
		screen.queue_free()
	screens.clear()
	screen_grab = null
	if keyboard_for != null:
		_show_keyboard(null, false)
	desktop.want("screens", on)
	ui.set_big_screen(on)
	desktop.set_max_width(3840 if on else 1920)       # sharp enough to read on a big screen
	if not on:
		_apply_desktop_options()
		return
	var monitors := _monitors()
	var saved := _load_screens()
	var head := camera.global_transform
	var forward := -head.basis.z
	forward.y = 0
	forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
	var spread := deg_to_rad(38.0)
	for i in monitors.size():
		var floating := DesktopScreen.new(monitors[i].name, monitors[i].region)
		add_child(floating)
		screens.append(floating)
		# one screen: big; several: side by side without overlapping
		floating.width = BIG_SCREEN_WIDTH if monitors.size() == 1 else 2.0 * BIG_SCREEN_DISTANCE * tan(spread / 2.0) * 0.92
		floating.set_texture(desktop.texture)
		floating.visible = desktop.texture != null
		if saved.size() == monitors.size():
			floating.load_state(saved[i])
		else:                             # side by side in an arc in front of you
			var turn := (i - (monitors.size() - 1) / 2.0) * spread
			floating.place(head.origin, forward.rotated(Vector3.UP, -turn), BIG_SCREEN_DISTANCE, 0.35)
	_apply_desktop_options()
	ui.say("Point at a screen to use the PC. Grip moves it; the stick pushes it away or brings it closer.")


func _save_screens() -> void:
	var file := ConfigFile.new()
	file.load(SETTINGS_FILE)
	file.set_value("desktop", "screens", screens.map(func(s): return s.save_state()))
	file.save(SETTINGS_FILE)


func _load_screens() -> Array:
	var file := ConfigFile.new()
	if file.load(SETTINGS_FILE) != OK:
		return []
	var saved: Variant = file.get_value("desktop", "screens", [])
	return saved if saved is Array else []


# ------------------------------------------------------------------ virtual keyboard
func _make_keyboard() -> void:
	keyboard_view = SubViewport.new()
	keyboard_view.size = Vector2i(Keyboard.SIZE)
	keyboard_view.transparent_bg = true
	keyboard_view.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(keyboard_view)
	keyboard_ui = Keyboard.new()
	keyboard_view.add_child(keyboard_ui)
	keyboard_ui.key.connect(func(code, down): desktop_input.key(code, down))
	keyboard_ui.hide_requested.connect(func(): _show_keyboard(null, false))
	keyboard_quad = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(KEYBOARD_WIDTH, KEYBOARD_WIDTH * Keyboard.SIZE.y / Keyboard.SIZE.x)
	keyboard_quad.mesh = quad
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = keyboard_view.get_texture()
	keyboard_quad.material_override = material
	keyboard_quad.visible = false
	add_child(keyboard_quad)


## Show the keyboard under a screen (or under the dashboard, for null), or hide it.
func _show_keyboard(under: Node3D, on: bool) -> void:
	keyboard_for = under
	keyboard_quad.visible = on
	keyboard_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_WHEN_VISIBLE
	if not on:
		keyboard_ui.clear()
		desktop_input.release_all()
		return
	desktop_input.start()
	_place_keyboard()


## Below what it types into, tilted up towards you like a real keyboard.
func _place_keyboard() -> void:
	var anchor: Vector3
	var drop: float
	if keyboard_for != null:
		anchor = keyboard_for.global_position
		drop = keyboard_for.width * keyboard_for.aspect / 2.0 + DesktopScreen.BAR_HEIGHT + 0.22
	else:
		anchor = screen.global_position
		drop = screen.global_transform.basis.y.length() * (screen.mesh as QuadMesh).size.y / 2.0 + 0.18
	var to_anchor := anchor - _head()
	to_anchor.y = 0
	var forward := to_anchor.normalized() if to_anchor.length() > 0.05 else Vector3.FORWARD
	# closer than what it types into, and no further than arm's reach
	var reach := clampf(to_anchor.length() * 0.55, 0.45, 0.75)
	var at := _head() + forward * reach
	at.y = minf(anchor.y - drop, _head().y - 0.35)
	var basis := Basis.looking_at(forward, Vector3.UP).rotated(Basis.looking_at(forward, Vector3.UP).x, deg_to_rad(-35))
	keyboard_quad.global_transform = Transform3D(basis, at)


## Where a ray hits the keyboard, in its pixels, or null.
func _keyboard_pixels(from: Vector3, direction: Vector3) -> Variant:
	if not keyboard_quad.visible:
		return null
	var plane := Plane(keyboard_quad.global_transform.basis.z.normalized(), keyboard_quad.global_position)
	var hit: Variant = plane.intersects_ray(from, direction)
	if hit == null:
		return null
	var local: Vector3 = keyboard_quad.global_transform.affine_inverse() * hit
	var half: Vector2 = (keyboard_quad.mesh as QuadMesh).size / 2.0
	if absf(local.x) > half.x or absf(local.y) > half.y:
		return null
	return Vector2((local.x / half.x + 1.0) / 2.0, (1.0 - local.y / half.y) / 2.0) * Keyboard.SIZE


func _keyboard_world(at: Vector2) -> Vector3:
	var half: Vector2 = (keyboard_quad.mesh as QuadMesh).size / 2.0
	var uv := at / Keyboard.SIZE
	return keyboard_quad.global_transform * Vector3((uv.x * 2.0 - 1.0) * half.x, (1.0 - uv.y * 2.0) * half.y, 0.002)


func _keyboard_motion(at: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = at - keyboard_pointer if keyboard_pointer.x >= 0 else Vector2.ZERO
	keyboard_pointer = at
	keyboard_view.push_input(event, true)


func _keyboard_button(pressed: bool) -> void:
	if keyboard_pointer.x < 0:
		return
	var event := InputEventMouseButton.new()
	event.position = keyboard_pointer
	event.global_position = keyboard_pointer
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	keyboard_view.push_input(event, true)


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
		game_info = _parse_game(game_thread.wait_to_finish())
		ui.set_game(game_info)
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
	if headset_thread:
		headset_thread.wait_to_finish()
	for side in hands:
		if hands[side].loader:
			hands[side].loader.wait_to_finish()
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
			"from": Vector3.ZERO, "dir": Vector3.ZERO, "held": held, "model": null, "model_id": "",
			"loader": null, "responses": [], "side": side}


# ------------------------------------------------------------------ controller models
## Drawn while the dashboard is open, so you can see your hands over the game: the real model
## of your controller (controller_models.gd), with its buttons, trigger and stick moving as you
## press them. If the model files aren't installed, Goggles-styled stand-ins built from simple
## shapes are drawn instead (below), with the pressed buttons lit up.
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


## Give each hand the model for its controller (loaded on a thread, so a frame is never held
## up), and move or light the parts that are pressed.
func _update_models() -> void:
	for side in hands:
		var hand: Dictionary = hands[side]
		var tracker := XRServer.get_tracker(hand.held.tracker) as XRPositionalTracker
		var profile: String = tracker.profile if tracker else ""
		var wanted := ControllerModels.pick(system_name, profile)
		if wanted != "" and wanted != hand.model_id and hand.loader == null:
			hand.model_id = wanted
			var loader := Thread.new()
			loader.set_meta("profile", profile)
			loader.start(ControllerModels.load_model.bind(wanted, side))
			hand.loader = loader
		if hand.loader and not hand.loader.is_alive():
			var loaded: Dictionary = hand.loader.wait_to_finish()
			var for_profile: String = hand.loader.get_meta("profile")
			hand.loader = null
			if hand.model:
				hand.model.queue_free()
			if loaded.is_empty():           # not installed: the simple stand-in
				hand.model = _make_controller_model(_controller_kind(for_profile), side)
				hand.responses = []
			else:
				hand.model = loaded.scene
				hand.responses = loaded.responses
			hand.held.add_child(hand.model)
		var model: Node3D = hand.model
		if model == null:
			continue
		model.visible = shown and open_amount > 0.5 and hand.held.get_has_tracking_data()
		if not model.visible:
			continue
		if not hand.responses.is_empty():
			ControllerModels.animate(hand.responses, ControllerModels.read_inputs(hand.controller))
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
			ui.set_recording(answer.begins_with("Recording started"))
		if job.get_meta("command") == "quit-game":
			game_wait = 0.0                   # look again straight away
		if job.get_meta("command") == "recenter" and countdown_phase == "wait":
			_countdown_finish(answer if answer != "" else "Couldn't recentre")


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


# ------------------------------------------------------------------ recentring
## Recentre: the dashboard steps aside and counts down 3-2-1 so you can stand where you want to
## be and look the way you want to face. Then the runtime makes that the game's new centre and
## "forward" (gogglesxr recenter moves both the seated and the standing/room-scale spaces), and
## the dashboard comes back in front of you. In overlay mode you go straight back to the game.
## Pressing Recentre again, or the menu button, during the countdown cancels it.
const COUNTDOWN_SECONDS := 3.0

func _make_countdown() -> void:
	countdown_root = Node3D.new()
	countdown_root.position = Vector3(0, 0, -1.1)
	countdown_root.visible = false
	camera.add_child(countdown_root)      # follows your head, so it is always in view
	countdown_number = Label3D.new()
	countdown_number.font_size = 220
	countdown_number.pixel_size = 0.001
	countdown_number.outline_size = 36
	countdown_number.modulate = DashboardUI.ACCENT_2
	countdown_number.outline_modulate = Color(0.01, 0.06, 0.05, 0.85)
	countdown_number.no_depth_test = true
	countdown_number.render_priority = 10
	countdown_number.outline_render_priority = 9
	countdown_root.add_child(countdown_number)
	countdown_text = Label3D.new()
	countdown_text.font_size = 44
	countdown_text.pixel_size = 0.001
	countdown_text.outline_size = 14
	countdown_text.position = Vector3(0, -0.17, 0)
	countdown_text.outline_modulate = Color(0.01, 0.06, 0.05, 0.85)
	countdown_text.no_depth_test = true
	countdown_text.render_priority = 10
	countdown_text.outline_render_priority = 9
	countdown_root.add_child(countdown_text)


func _recentre() -> void:
	if countdown_phase == "count":
		_countdown_cancel()
		return
	if countdown_phase != "":
		return                            # already recentring
	countdown_phase = "count"
	countdown_left = COUNTDOWN_SECONDS
	countdown_text.text = "Stand where you want to be and look straight ahead"
	countdown_root.visible = true
	_countdown_show_number(int(ceil(countdown_left)))
	_set_shown(false)                     # out of the way, so you can see where you are facing


func _countdown_show_number(n: int) -> void:
	countdown_number.text = str(n)
	if animations:
		countdown_number.scale = Vector3.ONE * 1.35
		countdown_number.modulate.a = 0.4
		var pop := create_tween().set_parallel()
		pop.tween_property(countdown_number, "scale", Vector3.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		pop.tween_property(countdown_number, "modulate:a", 1.0, 0.2)


func _countdown_cancel() -> void:
	countdown_phase = ""
	countdown_root.visible = false
	_set_shown(true)
	ui.say("Recentre cancelled")


func _countdown_finish(answer: String) -> void:
	countdown_phase = "done"
	countdown_left = 1.4
	countdown_number.text = "✓" if not answer.begins_with("Can") and not answer.begins_with("The VR") else "!"
	countdown_text.text = answer


func _update_countdown(delta: float) -> void:
	if countdown_phase == "":
		return
	countdown_left -= delta
	if countdown_phase == "count":
		var number := int(ceil(countdown_left))
		if countdown_left <= 0.0:
			countdown_phase = "wait"
			countdown_number.text = "…"
			countdown_text.text = "Recentring"
			if xr_active:
				_run_tool("recenter")
			else:
				_countdown_finish("View recentred")    # the desktop preview has no game to move
		elif countdown_number.text != str(number):
			_countdown_show_number(number)
	elif countdown_phase == "done" and countdown_left <= 0.0:
		countdown_phase = ""
		countdown_root.visible = false
		_reset_place()                    # in front of you again, in the recentred space
		_save_place()
		if not overlay:
			_set_shown(true)


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
	_poll_headset(delta)
	_collect_tool_jobs()
	_update_countdown(delta)
	_update_home()
	_update_desktop()
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
			if countdown_phase == "count":
				_countdown_cancel()
			elif countdown_phase == "":
				_set_shown(not shown)
		menu_was_down = menu
		if not shown:
			return
	wheel_wait = maxf(0.0, wheel_wait - delta)
	for side in hands:
		var hand: Dictionary = hands[side]
		var controller: XRController3D = hand.controller
		var tracked := controller.get_has_tracking_data()
		var trigger := tracked and controller.get_float(&"trigger") > 0.6
		var grip := tracked and controller.get_float(&"grip") > 0.6
		var right_click := tracked and controller.is_button_pressed(&"by_button")
		# Whichever hand pressed something last does the pointing
		if (trigger and not hand.trigger) or (grip and not hand.grip):
			if side != active_hand and not ui.is_swiping() and mouse_buttons == 0 and screen_grab == null:
				active_hand = side
		var aim := controller.global_transform
		if tracked:
			_smooth_ray(hand, aim.origin, -aim.basis.z, delta)
		else:
			hand.dir = Vector3.ZERO
		var target: Dictionary = _aim(hand.from, hand.dir) if tracked else {}
		var length: float = target.get("distance", LASER_LENGTH)
		hand.laser.visible = tracked
		if tracked:
			var up := Vector3.UP if absf(hand.dir.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
			# Stretch the beam along its own length (not along the room's axes, which twists it)
			hand.laser.global_transform = Transform3D(Basis.looking_at(hand.dir, up) * Basis.from_scale(Vector3(1, 1, length)), hand.from + hand.dir * length / 2.0)
		hand.dot.visible = not target.is_empty()
		if not target.is_empty():
			hand.dot.global_position = target.point
		if side == active_hand:
			ray_from = hand.from
			ray_dir = hand.dir
			_drive(hand, controller, target, trigger, grip, right_click, delta)
		hand.trigger = trigger
		hand.grip = grip
		hand.right_click = right_click


## What a ray points at, nearest first: {} for nothing, else {"kind", "distance", "point", ...}.
## kind is "dashboard" (with "pixels"), "desktop" (a desktop picture: "uv", and "screen" or
## null for the Desktop panel), "bar" / "keyboard_button" / "close" (a screen's handle bar,
## with "screen") or "keyboard" (with "pixels").
func _aim(from: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	if screen.visible and open_amount > 0.5:
		var pixels: Variant = _ray_to_pixels(from, dir)
		if pixels != null:
			var point := _pixels_to_world(pixels)
			best = {"kind": "dashboard", "distance": from.distance_to(point), "point": point, "pixels": pixels}
			var uv: Variant = ui.desktop_uv(pixels) if ui.current == "desktop" and not ui.is_swiping() and desktop.screen == "all" else null
			if uv != null:
				best.merge({"kind": "desktop", "uv": uv, "screen": null}, true)
	for s in screens:
		var hit: Dictionary = s.hit(from, dir)
		if hit.is_empty() or (not best.is_empty() and hit.distance >= best.distance):
			continue
		var kinds := {"screen": "desktop", "bar": "bar", "keyboard": "keyboard_button", "close": "close"}
		best = {"kind": kinds[hit.part], "distance": hit.distance, "point": hit.point, "uv": hit.uv, "screen": s}
	var keys: Variant = _keyboard_pixels(from, dir)
	if keys != null:
		var point := _keyboard_world(keys)
		if best.is_empty() or from.distance_to(point) < best.distance:
			best = {"kind": "keyboard", "distance": from.distance_to(point), "point": point, "pixels": keys}
	return best


## The active hand's buttons, applied to whatever it points at.
func _drive(hand: Dictionary, controller: XRController3D, target: Dictionary, trigger: bool, grip: bool, right_click: bool, delta: float) -> void:
	var stick := controller.get_vector2(&"primary")
	var kind: String = target.get("kind", "")
	var parts := {"desktop": "screen", "bar": "bar", "keyboard_button": "keyboard", "close": "close"}
	for s in screens:
		s.set_hovered(parts.get(kind, "") if target.get("screen") == s else ("bar" if s == screen_grab else ""))

	# Carrying the dashboard or a screen: nothing else happens until grip is let go
	if moving:
		_move_update(stick.y, delta)
		if not grip:
			_grip(false)
		return
	if screen_grab != null:
		screen_grab.update_grab(hand.from, hand.dir, _head(), stick.y, stick.x, delta)
		if keyboard_for == screen_grab:
			_place_keyboard()
		if not grip:
			screen_grab = null
			_save_screens()
		return
	if ui.is_swiping():
		if target.has("pixels") and kind in ["dashboard", "desktop"] and target.get("screen") == null:
			_send_motion(target.pixels)
			ui.swipe_move(target.pixels - grab_start)
		if not grip:
			_grip(false)
		return

	# Trigger let go: whoever got the press gets the release
	if not trigger and hand.trigger:
		match hand.get("press", ""):
			"dashboard": _send_button(MOUSE_BUTTON_LEFT, false)
			"desktop": desktop_input.button(0, false)
			"keyboard": _keyboard_button(false)
		hand.press = ""
	if not right_click and hand.get("right_click", false):
		desktop_input.button(1, false)
	var pressed: bool = trigger and not hand.trigger
	var gripped: bool = grip and not hand.grip

	match kind:
		"dashboard":
			_send_motion(target.pixels)
			if pressed:
				_send_button(MOUSE_BUTTON_LEFT, true)
				hand.press = "dashboard"
			if absf(stick.y) > 0.5 and scroll_wait == 0.0:
				_scroll(stick.y)
				scroll_wait = 0.12
			if gripped:
				_grip(true)
		"desktop":
			var where: Vector2 = target.uv if target.screen == null else target.screen.desktop_point(target.uv)
			if target.screen == null:
				_send_motion(target.pixels)
			desktop_input.move(where)
			if pressed:
				desktop_input.button(0, true)
				hand.press = "desktop"
			if right_click and not hand.get("right_click", false):
				desktop_input.button(1, true)
			if absf(stick.y) > 0.5 and wheel_wait == 0.0:
				desktop_input.wheel(1 if stick.y > 0 else -1)
				wheel_wait = 0.09
			if gripped:
				if target.screen != null:
					screen_grab = target.screen
					screen_grab.begin_grab(hand.from, target.point)
				else:
					_grip(true)               # the Desktop panel: swipe or move the dashboard
		"bar":
			if gripped or pressed:
				screen_grab = target.screen
				screen_grab.begin_grab(hand.from, target.point)
		"keyboard_button":
			if pressed:
				_show_keyboard(target.screen, not (keyboard_quad.visible and keyboard_for == target.screen))
		"close":
			if pressed:
				_close_screen(target.screen)
		"keyboard":
			_keyboard_motion(target.pixels)
			if pressed:
				_keyboard_button(true)
				hand.press = "keyboard"
		_:
			if pressed:
				hand.press = ""


func _close_screen(which: Node3D) -> void:
	if keyboard_for == which:
		_show_keyboard(null, false)
	screens.erase(which)
	which.queue_free()
	if screens.is_empty():
		_pop_out_screens(false)
	else:
		_save_screens()


func _pixels_to_world(at: Vector2) -> Vector3:
	var half: Vector2 = (screen.mesh as QuadMesh).size / 2.0
	var uv := at / DashboardUI.SIZE
	return screen.to_global(Vector3((uv.x * 2.0 - 1.0) * half.x, (1.0 - uv.y * 2.0) * half.y, 0.002))


## Self-test: point a hand's laser at `at`, from a little in front of `facing` (a node whose
## front is +Z), and say what it hits.
func _test_aim(hand: Dictionary, at: Vector3, facing: Node3D) -> Dictionary:
	hand.from = at + facing.global_transform.basis.z.normalized() * 0.6
	hand.dir = (at - hand.from).normalized()
	return _aim(hand.from, hand.dir)


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
## GOGGLESXR_PANEL=library       open on a given panel (settings:Recording: a section of Settings)
## GOGGLESXR_SHOT=/path/out.png  save a picture of the window after a moment, then quit
## GOGGLESXR_TEST_BG=1           fill the background with a loud colour (to stand in for a game)
## GOGGLESXR_SHOW_MODELS=1       desktop preview: line up every controller model (right hands pressed)
## GOGGLESXR_RECENTRE=1          start the recentre countdown straight away
## GOGGLESXR_POP_OUT=1           pop the desktop out into floating screens, with the keyboard
##                               (=keyboard: just the keyboard, under the dashboard)
## GOGGLESXR_SELFTEST=1          drive the dashboard through its pointer code, print results, quit
## GOGGLESXR_MONITORS=[{"name":"DP-1","x":0,"y":0,"w":1920,"h":1080}, ...]  pretend these are the PC's monitors
## GOGGLESXR_DESKTOP_INPUT=path  the desktop control helper (with GOGGLESXR_DESKTOP_INPUT_PRINT=1: print, don't act)
func _debug_hooks() -> void:
	var start_panel := OS.get_environment("GOGGLESXR_PANEL")    # "settings:Recording" opens a section
	if DashboardUI.POS.has(start_panel.get_slice(":", 0)):
		ui.show_panel(start_panel.get_slice(":", 0), false)
		if start_panel.contains(":"):
			ui.show_settings(start_panel.get_slice(":", 1))
	if OS.get_environment("GOGGLESXR_SHOW_MODELS") != "":
		_show_models()
	if OS.get_environment("GOGGLESXR_TEST_BG") != "":
		RenderingServer.set_default_clear_color(Color(0.75, 0.1, 0.45))
	if OS.get_environment("GOGGLESXR_RECENTRE") != "":
		_recentre.call_deferred()         # after the dashboard's opening animation has started
	if OS.get_environment("GOGGLESXR_POP_OUT") == "keyboard":
		await get_tree().create_timer(0.5).timeout
		_show_keyboard(null, true)
	elif OS.get_environment("GOGGLESXR_POP_OUT") != "":
		_pop_out_screens.call_deferred(true)
		await get_tree().create_timer(0.5).timeout
		_show_keyboard(screens[0] if not screens.is_empty() else null, true)
	if OS.get_environment("GOGGLESXR_SELFTEST") != "":
		_selftest.call_deferred()
	elif OS.get_environment("GOGGLESXR_SHOT") != "":
		await get_tree().create_timer(1.5).timeout
		print("Current Game panel: ", ui.game_title(), " / ", ui.game_state())
		get_viewport().get_texture().get_image().save_png(OS.get_environment("GOGGLESXR_SHOT"))
		get_tree().quit()


func _show_models() -> void:
	screen.visible = false
	# The real models where they are installed (GOGGLESXR_CONTROLLERS points elsewhere for testing),
	# otherwise the stand-ins
	var sets := ["oculus-touch", "oculus-touch-v2", "oculus-touch-v3", "meta-quest-touch-plus", "meta-quest-touch-pro",
			"valve-index", "htc-vive", ControllerModels.GENERIC]
	var stand_in := {"oculus-touch": "touch", "oculus-touch-v2": "touch", "oculus-touch-v3": "touch", "meta-quest-touch-plus": "touch_plus",
			"meta-quest-touch-pro": "touch_plus", "valve-index": "index", "htc-vive": "wand", ControllerModels.GENERIC: "generic"}
	for i in sets.size():
		for side_index in 2:
			var side: String = ["left", "right"][side_index]
			var loaded := ControllerModels.load_model(sets[i], side)
			var model: Node3D = loaded.scene if not loaded.is_empty() else _make_controller_model(stand_in[sets[i]], side)
			add_child(model)
			if not loaded.is_empty() and side == "right":
				# show the pressed look on the right hand: trigger pulled, stick pushed, A pressed
				ControllerModels.animate(loaded.responses, {"trigger": {"button": 1.0, "x": 0.0, "y": 0.0},
						"grip": {"button": 1.0, "x": 0.0, "y": 0.0}, "primary": {"button": 0.0, "x": 1.0, "y": 0.0},
						"ax_button": {"button": 1.0, "x": 0.0, "y": 0.0}})
			# held as you would hold it: pointing away and a little up
			var column := i % 4
			var row := i / 4
			model.transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(35), deg_to_rad(18 - 36 * side_index), 0)),
					camera.position + Vector3(-0.42 + 0.28 * column + (0.055 if side_index else -0.055), 0.09 - 0.2 * row, -0.6))


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

	# Real controller models: which set for which headset, and moving parts
	var picks := {["Meta Quest 3 on WiVRn", "/interaction_profiles/oculus/touch_controller"]: "meta-quest-touch-plus",
			["Meta Quest 3S on WiVRn", ""]: "meta-quest-touch-plus", ["Oculus Quest 2 on WiVRn", ""]: "oculus-touch-v3",
			["Oculus Quest on WiVRn", "/interaction_profiles/oculus/touch_controller"]: "oculus-touch-v2",
			["Meta Quest Pro on WiVRn", ""]: "meta-quest-touch-pro", ["Rift CV1", "/interaction_profiles/oculus/touch_controller"]: "oculus-touch",
			["SteamVR/Monado", "/interaction_profiles/valve/index_controller"]: "valve-index",
			["Vive", "/interaction_profiles/htc/vive_controller"]: "htc-vive", ["Steam Frame on WiVRn", "/interaction_profiles/khr/simple_controller"]: ControllerModels.GENERIC,
			["Unknown", ""]: ""}
	var picked := []
	for key in picks:
		if ControllerModels.pick(key[0], key[1]) != picks[key]:
			picked.append(key[0] + " -> " + ControllerModels.pick(key[0], key[1]))
	check.call("the right controller model for each headset", picked.is_empty(), str(picked))
	check.call("a missing model set is reported, so the stand-in is used", ControllerModels.load_model("no-such-controller", "left").is_empty(), "")
	if DirAccess.dir_exists_absolute(ControllerModels.models_dir().path_join("meta-quest-touch-plus")):
		var real := ControllerModels.load_model("meta-quest-touch-plus", "right")
		var trigger_moves := false
		if not real.is_empty():
			var trigger: Array = real.responses.filter(func(r): return r.input == "trigger" and r.kind == "transform")
			if not trigger.is_empty():
				var none := {"trigger": {"button": 0.0, "x": 0.0, "y": 0.0}}
				ControllerModels.animate(real.responses, none)
				var rest: Transform3D = trigger[0].node.transform
				ControllerModels.animate(real.responses, {"trigger": {"button": 1.0, "x": 0.0, "y": 0.0}})
				var pulled: Transform3D = trigger[0].node.transform
				trigger_moves = rest.is_equal_approx(trigger[0].min) and pulled.is_equal_approx(trigger[0].max) and not rest.is_equal_approx(pulled)
			real.scene.free()
		check.call("the Quest 3 model loads and its trigger moves", trigger_moves, "%d moving parts" % (real.get("responses", []).size()))
	else:
		print("SKIP real controller models aren't installed in " + ControllerModels.models_dir())

	# Recentre: the dashboard steps aside and counts down before anything moves
	_set_shown(true)
	await get_tree().create_timer(0.4).timeout
	_recentre()
	check.call("Recentre starts a countdown", countdown_phase == "count" and countdown_root.visible and countdown_number.text == "3", countdown_number.text)
	await get_tree().create_timer(0.4).timeout
	check.call("the dashboard steps aside for it", not screen.visible, str(screen.visible))
	_recentre()
	check.call("pressing Recentre again cancels it", countdown_phase == "" and not countdown_root.visible, countdown_phase)
	await get_tree().create_timer(0.4).timeout
	_recentre()
	await get_tree().create_timer(1.3).timeout
	check.call("it counts down", countdown_number.text == "2", countdown_number.text)
	await get_tree().create_timer(2.0).timeout
	check.call("then recentres and says so", countdown_phase == "done" and countdown_text.text == "View recentred", countdown_phase + " / " + countdown_text.text)
	await get_tree().create_timer(1.6).timeout
	check.call("and the dashboard comes back", countdown_phase == "" and not countdown_root.visible and screen.visible, str(screen.visible))

	# Status strip: batteries and ping from the engine
	ui.set_headset({"connected": true, "name": "Meta Quest 3", "engine_name": "WiVRn", "ping_ms": 4.4, "connection": "wifi",
			"battery": {"head": {"charge": 82, "charging": true}, "left": {"charge": 15, "charging": false}, "right": {"charge": 60, "charging": false}}})
	var strip := ui.headset_text()
	check.call("the strip shows batteries and ping", strip.contains("HEADSET  + 82%") and strip.contains("LEFT 15%") and strip.contains("PING 4 ms"), strip)
	ui.set_headset({"connected": false})
	check.call("and says when no headset is connected", ui.headset_text() == "HEADSET Not connected", ui.headset_text())

	# Settings chosen on the dashboard are saved for the desktop app and gogglesxr
	var settings_before := FileAccess.get_file_as_string(_prefs_path())
	var nine_sixteen: Button = ui.find_children("", "Button", true, false).filter(func(b): return b.text == "9:16 upright")[0]
	nine_sixteen.pressed.emit()
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(_prefs_path()))
	check.call("a recording choice is saved to settings.json", saved is Dictionary and saved.get("record_aspect") == "9:16", str(saved))
	ui.apply_settings({"record_fps": 60.0, "desktop_screen": "active"})
	check.call("saved settings are shown (numbers too)", ui.choice("record_fps") == 60 and ui.choice("desktop_screen") == "active", str(ui.choice("record_fps")))

	# Home environment: shown around you when no game is running
	prefs["environment"] = "goggles"
	_load_home()
	check.call("the Goggles home environment is shown", home_sky != null and world_env.environment.background_mode == Environment.BG_SKY, "")
	_on_setting("environment", "none")
	check.call("and can be switched off", world_env.environment.background_mode == Environment.BG_CLEAR_COLOR, "")
	_on_setting("environment", "goggles")

	# Desktop view: the panel starts the picture taker (here drawing a test pattern) and shows it
	var helper := OS.get_environment("GOGGLESXR_DESKTOP_GRAB")
	var input_helper := OS.get_environment("GOGGLESXR_DESKTOP_INPUT")
	if helper != "" and FileAccess.file_exists(helper) and FileAccess.file_exists(input_helper) \
			and OS.get_environment("GOGGLESXR_DESKTOP_INPUT_PRINT") != "" and OS.get_environment("GOGGLESXR_MONITORS") != "":
		_on_setting("desktop_screen", "all")
		ui.show_panel("desktop", false)
		await get_tree().create_timer(2.0).timeout
		check.call("the Desktop panel shows the desktop live", desktop.running() and desktop.texture != null and desktop.message == "", desktop.message)
		# Desktop control: the helper in --print mode reports the events it would send
		var view_rect: Rect2 = ui._desktop_view.get_global_rect()
		var middle := view_rect.get_center()
		var uv: Variant = ui.desktop_uv(middle)
		check.call("the panel's picture maps to the desktop", uv is Vector2 and (uv as Vector2).distance_to(Vector2(0.5, 0.5)) < 0.02, str(uv))
		var right_hand: Dictionary = hands["right"]
		var right_controller: XRController3D = right_hand.controller
		var target := _test_aim(right_hand, _pixels_to_world(middle), screen)
		check.call("the laser on the panel's picture aims at the desktop", target.get("kind") == "desktop" and target.get("screen") == null, str(target.get("kind")))
		_drive(right_hand, right_controller, target, true, false, false, 0.016)
		right_hand.trigger = true
		_drive(right_hand, right_controller, target, false, false, false, 0.016)
		right_hand.trigger = false
		await get_tree().create_timer(0.5).timeout
		var events := "\n".join(desktop_input.output())
		check.call("trigger there clicks on the PC", events.contains("pointer type=3 code=0 value=3") and events.contains("pointer type=1 code=272 value=1") and events.contains("pointer type=1 code=272 value=0"), events.right(300))

		# Pop out: one floating screen per monitor, each showing its part of the desktop
		ui.show_panel("game", false)
		var cfg := ConfigFile.new()
		if cfg.load(SETTINGS_FILE) == OK and cfg.has_section_key("desktop", "screens"):
			cfg.erase_section_key("desktop", "screens")           # start from the default arc
			cfg.save(SETTINGS_FILE)
		_pop_out_screens(true)
		check.call("Pop out makes a screen per monitor", screens.size() == 2 and screens[1].region.is_equal_approx(Rect2(0.6, 0, 0.4, 0.8)), str(screens.map(func(x): return x.region)))
		await get_tree().create_timer(0.6).timeout
		check.call("the capture keeps running for the screens, at full width", desktop.running() and desktop.max_width == 3840, "")
		var right_screen: Node3D = screens[1]
		var spot: Vector3 = right_screen.global_transform * Vector3(right_screen.width * 0.25, 0, 0)   # 3/4 across it
		target = _test_aim(right_hand, spot, right_screen)
		check.call("the laser on a screen aims at it", target.get("kind") == "desktop" and target.get("screen") == right_screen, str(target.get("kind")))
		var point: Vector2 = right_screen.desktop_point(target.get("uv", Vector2.ZERO))
		check.call("and at the right spot of the whole desktop", point.distance_to(Vector2(0.9, 0.4)) < 0.02, str(point))
		_drive(right_hand, right_controller, target, false, false, true, 0.016)
		right_hand.right_click = true
		_drive(right_hand, right_controller, target, false, false, false, 0.016)
		right_hand.right_click = false
		await get_tree().create_timer(0.4).timeout
		events = "\n".join(desktop_input.output())
		check.call("B/Y right-clicks", events.contains("pointer type=1 code=273 value=1") and events.contains("pointer type=1 code=273 value=0"), events.right(200))

		# Carry a screen by its bar
		var bar_spot: Vector3 = right_screen.bar.global_position
		target = _test_aim(right_hand, bar_spot, right_screen)
		check.call("the bar under a screen can be aimed at", target.get("kind") == "bar", str(target.get("kind")))
		var before: Vector3 = right_screen.global_position
		_drive(right_hand, right_controller, target, false, true, false, 0.016)
		right_hand.grip = true
		check.call("grip picks it up", screen_grab == right_screen, "")
		right_hand.dir = (bar_spot + Vector3(0.6, 0.3, 0) - right_hand.from).normalized()
		_drive(right_hand, right_controller, {}, false, true, false, 0.016)
		_drive(right_hand, right_controller, {}, false, false, false, 0.016)
		right_hand.grip = false
		check.call("and it follows the laser, then stays", screen_grab == null and right_screen.global_position.distance_to(before) > 0.3, str(right_screen.global_position - before))
		check.call("where it was put is remembered", _load_screens().size() == 2, "")

		# The bar's Keyboard button opens the keyboard under the screen; typing reaches the PC
		var kb_button: Vector3 = right_screen.buttons["keyboard"].global_position
		target = _test_aim(right_hand, kb_button, right_screen)
		_drive(right_hand, right_controller, target, true, false, false, 0.016)
		right_hand.trigger = true
		_drive(right_hand, right_controller, target, false, false, false, 0.016)
		right_hand.trigger = false
		check.call("the bar's Keyboard button opens the keyboard there", keyboard_quad.visible and keyboard_for == right_screen, str(target.get("kind")))
		await get_tree().process_frame
		var key_a: Button = keyboard_ui._buttons[30][0]
		var key_at: Vector2 = key_a.get_global_rect().get_center()
		var key_world := _keyboard_world(key_at)
		target = _test_aim(right_hand, key_world, keyboard_quad)
		check.call("the laser finds keys on the keyboard", target.get("kind") == "keyboard" and (target.pixels as Vector2).distance_to(key_at) < 2.0, str(target.get("pixels")))
		_drive(right_hand, right_controller, target, true, false, false, 0.016)
		right_hand.trigger = true
		await get_tree().process_frame
		_drive(right_hand, right_controller, target, false, false, false, 0.016)
		right_hand.trigger = false
		await get_tree().create_timer(0.4).timeout
		events = "\n".join(desktop_input.output())
		check.call("pressing a key types it on the PC", events.contains("keyboard type=1 code=30 value=1") and events.contains("keyboard type=1 code=30 value=0"), events.right(200))
		keyboard_ui._toggle_modifier(42)
		keyboard_ui._press(30)
		keyboard_ui._release(30)
		await get_tree().create_timer(0.3).timeout
		events = "\n".join(desktop_input.output())
		check.call("Shift applies to the next key only", events.contains("keyboard type=1 code=42 value=1") and keyboard_ui.modifiers.get(42, "") == "", events.right(200))

		# Close one screen, then put the rest away
		var close_at: Vector3 = screens[0].buttons["close"].global_position
		target = _test_aim(right_hand, close_at, screens[0])
		_drive(right_hand, right_controller, target, true, false, false, 0.016)
		right_hand.trigger = true
		_drive(right_hand, right_controller, {}, false, false, false, 0.016)
		right_hand.trigger = false
		check.call("a screen's Close button removes it", screens.size() == 1 and screens[0] == right_screen, str(target.get("kind")))
		_pop_out_screens(false)
		_show_keyboard(null, false)
		await get_tree().create_timer(0.4).timeout
		check.call("and the capture stops when nothing shows it", not desktop.running() and screens.is_empty(), "")
		_update_desktop()
		check.call("desktop control lets go of the PC too", not desktop_input.running(), "")
	else:
		print("SKIP desktop view: set GOGGLESXR_DESKTOP_GRAB and GOGGLESXR_DESKTOP_INPUT to the built helpers, GOGGLESXR_DESKTOP_INPUT_PRINT=1 and GOGGLESXR_MONITORS (see main.gd)")
	if settings_before == "":
		DirAccess.remove_absolute(_prefs_path())
	else:
		var file := FileAccess.open(_prefs_path(), FileAccess.WRITE)
		file.store_string(settings_before)
		file.close()

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
