extends Control
## The GogglesXR dashboard's 2D interface: five panels on a plus-shaped layout and a status
## strip underneath. main.gd shows it on a floating screen and sends it pointer input.
##
##                 Quick Settings
##   Full Settings  Current Game   Library
##                    Desktop
##
## Hold grip and swipe to move between panels. The card follows the hand, so sliding it down
## shows the panel above and sliding it left shows the panel on the right.

const SteamLibrary := preload("res://steam_library.gd")

signal recentre_requested
signal resume_requested
signal screenshot_requested
signal record_requested
signal quit_requested
signal smoothing_changed(amount: float)
signal scale_changed(factor: float)
signal setting_changed(key: String, value: Variant)   # saved to settings.json by main.gd
signal big_screen_toggled(on: bool)                  # pop the desktop out into floating screens
signal keyboard_requested
signal quick_changed(key: String, value: Variant)    # a Quick Settings control (main.gd acts on it)

const SIZE := Vector2(1280, 860)
const PANEL_SIZE := Vector2(1280, 736)
const GAP := 36.0
const POS := {
	"game": Vector2i(0, 0), "quick": Vector2i(0, -1), "desktop": Vector2i(0, 1),
	"library": Vector2i(1, 0), "settings": Vector2i(-1, 0),
}
const TITLES := {
	"game": "Current Game", "quick": "Quick Settings", "desktop": "Desktop",
	"library": "Library", "settings": "Settings",
}
const DIRS := {"up": Vector2i(0, -1), "down": Vector2i(0, 1), "left": Vector2i(-1, 0), "right": Vector2i(1, 0)}

const ACCENT := Color("3ddc84")
const ACCENT_2 := Color("f1ff9c")
const INK := Color("e6f3ee")
const MUTED := Color("9fbfb4")
const GLASS := Color(0.047, 0.149, 0.129, 0.9)
const WELL := Color(0, 0, 0, 0.32)
const LINE := Color(1, 1, 1, 0.12)
const VISOR_SHADER := """
shader_type canvas_item;
uniform vec4 base : source_color;
uniform vec4 glint : source_color;
void fragment() {
	float at = fract(TIME * 0.09) * 1.8 - 0.4;
	float shine = smoothstep(0.16, 0.0, abs(UV.x - at));
	float ends = smoothstep(0.0, 0.06, UV.x) * smoothstep(1.0, 0.94, UV.x);
	COLOR = vec4(mix(base.rgb, glint.rgb, shine), ends);
}
"""

var current := "game"
var _track: Control
var _hints := {}
var _map := {}
var _where: Label
var _clock: Label
var _date: Label
var _status: Label
var _toast: Label
# Current Game panel
var _game := {}
var _game_state: Label
var _game_title: Label
var _game_note: Label
var _game_art: TextureRect
var _game_button: Button
var _record_button: Button
var _quit_button: Button
var _quit_armed_until := 0
var _smoothing_slider: HSlider
var _passthrough_toggle: Button
var _quick := {}                          # Quick Settings: key -> Button or HSlider
var _quick_readouts := {}                 # key -> Label next to a slider
var _surroundings := "goggles"           # the environment to go back to when passthrough is turned off
var _choices := {}                        # setting key -> [{value: Button}] (a setting can be shown twice)
var _stats := {}                          # status strip: "head", "left", "right", "ping" -> [title, value]
var _stream_rows: VBoxContainer           # Settings > Streaming
var _desktop_view: TextureRect
var _desktop_note: Label
var _big_button: Button
var _settings_tabs := {}
var _tween: Tween
var sounds: Node                          # ui_sounds.gd (set by main.gd); null = silent
var animate_ui := true                    # hover and press motion (Settings: animations)
var _fonts := {}                          # "body", "body_bold", "head", "head_medium" -> Font
var _slider_dragging := false
# swipe state
var _swiping := false
var _axis := ""
var _offset := Vector2.ZERO
var _swipe_started_ms := 0


func _ready() -> void:
	size = SIZE
	custom_minimum_size = SIZE
	theme = _make_theme()
	_build()
	_wire(self)
	get_tree().node_added.connect(func(node):
		if is_ancestor_of(node):
			_wire(node))
	show_panel("game", false)
	var timer := Timer.new()
	timer.wait_time = 5.0
	timer.autostart = true
	timer.timeout.connect(_tick)
	add_child(timer)
	_tick()


# ------------------------------------------------------------------ navigation
## The panel reached by looking in a direction from `from`, or "" if there is none.
func neighbour(from: String, dir: String) -> String:
	var want: Vector2i = POS[from] + DIRS[dir]
	for id in POS:
		if POS[id] == want:
			return id
	return ""


## Look in a direction ("up" shows the panel above). Returns true if there was a panel there.
func go(dir: String) -> bool:
	var next := neighbour(current, dir)
	if next != "":
		show_panel(next)
	return next != ""


func show_panel(id: String, animate := true) -> void:
	if animate and id != current:
		_play("swipe")
	current = id
	var target := -Vector2(POS[id]) * (PANEL_SIZE + Vector2(GAP, GAP))
	if _tween:
		_tween.kill()
	if animate:
		_tween = create_tween().set_parallel()
		_tween.tween_property(_track, "position", target, 0.42).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
		# the panel arriving brightens as the one leaving dims
		for panel in _track.get_children():
			_tween.tween_property(panel, "modulate:a", 1.0 if panel.name == id else 0.35, 0.3)
	else:
		_track.position = target
		for panel in _track.get_children():
			panel.modulate.a = 1.0 if panel.name == id else 0.35
	for dir in _hints:
		var n := neighbour(id, dir)
		_hints[dir].visible = n != ""
		if n != "":
			_hints[dir].text = _hint_text(dir, TITLES[n])
	for key in _map:
		var dot: ColorRect = _map[key]
		var colour := ACCENT if key == id else Color(1, 1, 1, 0.18)
		if animate:
			create_tween().tween_property(dot, "color", colour, 0.25)
		else:
			dot.color = colour
	_where.text = TITLES[id]


## Grip pressed on the panel: start following the hand.
func swipe_begin() -> void:
	_swiping = true
	_axis = ""
	_offset = Vector2.ZERO
	_swipe_started_ms = Time.get_ticks_msec()
	if _tween:
		_tween.kill()


## `delta` is how far the pointer has moved since swipe_begin, in dashboard pixels.
func swipe_move(delta: Vector2) -> void:
	if not _swiping:
		return
	if _axis == "":
		if delta.length() < 14.0:
			return
		_axis = "x" if absf(delta.x) > absf(delta.y) else "y"
	var d := delta.x if _axis == "x" else delta.y
	if _swipe_target(d) == "":
		d = signf(d) * minf(60.0, absf(d) * 0.22)      # nothing that way: resist
	_offset = Vector2(d, 0) if _axis == "x" else Vector2(0, d)
	_track.position = -Vector2(POS[current]) * (PANEL_SIZE + Vector2(GAP, GAP)) + _offset


## Grip released: settle on the new panel if the card was moved far or flicked, else spring back.
func swipe_end() -> void:
	if not _swiping:
		return
	_swiping = false
	var d := _offset.x if _axis == "x" else _offset.y
	var span := PANEL_SIZE.x if _axis == "x" else PANEL_SIZE.y
	var ms := maxi(1, Time.get_ticks_msec() - _swipe_started_ms)
	var flick := absf(d) / ms > 1.2 and absf(d) > 60.0
	var target := _swipe_target(d) if _axis != "" else ""
	if target != "" and (absf(d) > span * 0.22 or flick):
		show_panel(target)
	else:
		show_panel(current)


func is_swiping() -> bool:
	return _swiping


## Pulling the card right reveals what is on the left, and so on.
func _swipe_target(d: float) -> String:
	if _axis == "x":
		return neighbour(current, "left" if d > 0 else "right")
	return neighbour(current, "up" if d > 0 else "down")


func say(text: String) -> void:
	_toast.text = text
	_toast.visible = true
	_toast.reset_size()
	_toast.pivot_offset = Vector2(_toast.size.x / 2.0, _toast.size.y)
	if _toast.has_meta("tween"):
		(_toast.get_meta("tween") as Tween).kill()
	var t := create_tween()
	_toast.set_meta("tween", t)
	# pops up from the bottom edge, waits, then fades
	_toast.modulate.a = 0.0
	_toast.scale = Vector2(0.9, 0.9)
	t.set_parallel()
	t.tween_property(_toast, "modulate:a", 1.0, 0.18)
	t.tween_property(_toast, "scale", Vector2.ONE, 0.28).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.chain().tween_interval(1.8 + text.length() * 0.02)
	t.chain().tween_property(_toast, "modulate:a", 0.0, 0.4)


func set_status(text: String) -> void:
	_status.text = text


# ------------------------------------------------------------------ building the interface
func _build() -> void:
	var window := Control.new()
	window.name = "Window"
	window.size = PANEL_SIZE
	window.clip_contents = true
	add_child(window)

	_track = Control.new()
	_track.name = "Track"
	_track.size = PANEL_SIZE
	window.add_child(_track)

	_add_panel("game", _build_game)
	_add_panel("quick", _build_quick)
	_add_panel("desktop", _build_desktop)
	_add_panel("library", _build_library)
	_add_panel("settings", _build_settings)

	# Visor line along the top of the window
	var visor := ColorRect.new()
	visor.color = ACCENT
	visor.position = Vector2(34, 0)
	visor.size = Vector2(PANEL_SIZE.x - 68, 3)
	visor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shimmer := ShaderMaterial.new()      # a slow glint travelling along it
	shimmer.shader = Shader.new()
	shimmer.shader.code = VISOR_SHADER
	shimmer.set_shader_parameter("base", ACCENT)
	shimmer.set_shader_parameter("glint", ACCENT_2)
	visor.material = shimmer
	window.add_child(visor)

	for dir in DIRS:
		var hint := Button.new()
		hint.theme_type_variation = &"Hint"
		hint.focus_mode = Control.FOCUS_NONE
		hint.pressed.connect(go.bind(dir))
		window.add_child(hint)
		_hints[dir] = hint
	_hints["up"].set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 10)
	_hints["down"].set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 10)
	_hints["left"].set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE, 10)
	_hints["right"].set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT, Control.PRESET_MODE_MINSIZE, 10)
	for dir in ["up", "down"]:
		_hints[dir].grow_horizontal = Control.GROW_DIRECTION_BOTH
	for dir in ["left", "right"]:
		_hints[dir].grow_vertical = Control.GROW_DIRECTION_BOTH
	_hints["right"].grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_hints["down"].grow_vertical = Control.GROW_DIRECTION_BEGIN

	_toast = Label.new()
	_toast.theme_type_variation = &"Toast"
	_toast.visible = false
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE, 64)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	window.add_child(_toast)

	_build_strip()


func _add_panel(id: String, builder: Callable) -> void:
	var panel := PanelContainer.new()
	panel.name = id
	panel.size = PANEL_SIZE
	panel.position = Vector2(POS[id]) * (PANEL_SIZE + Vector2(GAP, GAP))
	_track.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	panel.add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	var title := Label.new()
	title.text = TITLES[id] if id != "game" else "Now playing"
	title.theme_type_variation = &"Title"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var tag := Label.new()
	tag.text = TITLES[id].to_upper()
	tag.theme_type_variation = &"Eyebrow"
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(tag)
	var body := MarginContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(body)
	builder.call(body)


func _build_game(body: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 26)
	body.add_child(row)
	var art := PanelContainer.new()
	art.theme_type_variation = &"Art"
	art.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	art.clip_contents = true
	row.add_child(art)
	_game_art = TextureRect.new()
	_game_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_game_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_game_art.modulate = Color(0.55, 0.55, 0.55)        # dimmed, so the text over it stays readable
	_game_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.add_child(_game_art)
	var shade := TextureRect.new()          # darker towards the bottom, where the text is
	var fade := GradientTexture2D.new()
	fade.gradient = Gradient.new()
	fade.gradient.set_color(0, Color(0, 0, 0, 0))
	fade.gradient.set_color(1, Color(0.01, 0.05, 0.045, 0.85))
	fade.fill_from = Vector2(0, 0.35)
	fade.fill_to = Vector2(0, 1)
	shade.texture = fade
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.add_child(shade)
	var art_box := VBoxContainer.new()
	art_box.alignment = BoxContainer.ALIGNMENT_END
	art.add_child(art_box)
	_game_state = _label("", &"Eyebrow")
	_game_title = _label("", &"Title", true)
	_game_note = _label("", &"Muted", true)
	_game_note.add_theme_color_override("font_color", INK)
	for label in [_game_state, _game_title, _game_note]:
		art_box.add_child(label)

	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_theme_constant_override("separation", 12)
	row.add_child(side)
	_game_button = _button("", true)
	_game_button.pressed.connect(func():
		if _game.is_empty():
			show_panel("library")
		else:
			resume_requested.emit())
	side.add_child(_game_button)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	side.add_child(grid)
	var recentre := _button("Recentre")
	recentre.pressed.connect(func(): recentre_requested.emit())
	grid.add_child(recentre)
	var shot := _button("Screenshot")
	shot.pressed.connect(func(): screenshot_requested.emit())
	grid.add_child(shot)
	_record_button = _button("Record clip")
	_record_button.pressed.connect(func(): record_requested.emit())
	grid.add_child(_record_button)
	_quit_button = _button("Quit game")
	_quit_button.pressed.connect(_quit_pressed)
	grid.add_child(_quit_button)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(spacer)
	side.add_child(_label("Screenshots and clips of the headset view go to Pictures and Videos (GogglesXR folder). Shape and quality: Settings > Recording.", &"Muted", true))
	var clear_of_hint := Control.new()       # room for the "▼ Desktop" hint
	clear_of_hint.custom_minimum_size = Vector2(0, 26)
	side.add_child(clear_of_hint)
	set_game({})
	set_recording(false)


## Quitting takes two presses, so a stray trigger pull can't close your game.
func _quit_pressed() -> void:
	if Time.get_ticks_msec() < _quit_armed_until:
		_quit_armed_until = 0
		_quit_button.text = "Quit game"
		quit_requested.emit()
		return
	_quit_armed_until = Time.get_ticks_msec() + 3000
	_quit_button.text = "Press again to quit"
	await get_tree().create_timer(3.0).timeout
	if _quit_armed_until != 0 and Time.get_ticks_msec() >= _quit_armed_until:
		_quit_armed_until = 0
		_quit_button.text = "Quit game"


func set_recording(on: bool) -> void:
	_record_button.text = "Stop recording" if on else "Record clip"
	_record_button.theme_type_variation = &"Primary" if on else &""


## Show the running game: {"id", "seconds"} from main.gd, or {} when nothing is running.
func set_game(info: Dictionary) -> void:
	var changed: bool = info.get("id", "") != _game.get("id", "")
	_game = info
	if info.is_empty():
		_game_state.text = "NO GAME RUNNING"
		_game_title.text = "GogglesXR"
		_game_note.text = "Start a game from the Library panel, on the right."
		_game_button.text = "Open library"
		_game_art.texture = null
		_quit_button.disabled = true
		_quit_button.modulate.a = 0.45
		return
	_quit_button.disabled = false
	_quit_button.modulate.a = 1.0
	var seconds := int(info.get("seconds", 0))
	var time := "%d h %d m" % [seconds / 3600, seconds / 60 % 60] if seconds >= 3600 else "%d min" % maxi(1, seconds / 60)
	_game_state.text = "RUNNING  ·  " + time.to_upper()
	_game_button.text = "Resume game"
	if not changed:
		return
	var known := {}
	for game in SteamLibrary.games() + SteamLibrary.all_games():
		if str(game.get("id", "")) == str(info.id):
			known = game
			break
	_game_title.text = str(known.get("name", "Game %s" % info.id))
	_game_note.text = str(known.get("vr", "Running through GogglesXR"))
	_game_art.texture = SteamLibrary.cover(str(known.get("art", "")), Vector2i(560, 560))


func game_title() -> String:
	return _game_title.text


func game_state() -> String:
	return _game_state.text


func set_smoothing(amount: float) -> void:
	if _smoothing_slider:
		_smoothing_slider.set_value_no_signal(amount * 100.0)


func _build_quick(body: Control) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 20)
	body.add_child(box)
	var volume := _slider_row(box, "Volume", 0, 100, _read_volume())
	volume.value_changed.connect(_set_volume)
	var brightness := _slider_row(box, "Brightness", 20, 100, 100)
	brightness.value_changed.connect(func(v): quick_changed.emit("brightness", v))
	_quick["brightness"] = brightness
	var bitrate := _slider_row(box, "Bitrate", 10, 300, 80)
	bitrate.step = 5
	bitrate.editable = false                 # until a stream reports its bitrate
	bitrate.value_changed.connect(func(v):
		if not bitrate.has_meta("syncing"):
			quick_changed.emit("bitrate", v))
	_quick["bitrate"] = bitrate
	_quick_readouts["bitrate"] = bitrate.get_parent().get_child(2)
	_quick_readouts["bitrate"].text = "—"
	var bitrate_note := _label("Mb/s while streaming. Higher is sharper, lower copes better with weak Wi-Fi.", &"Small", true)
	box.add_child(bitrate_note)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(spacer)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	box.add_child(grid)
	_passthrough_toggle = _button("Passthrough")
	_passthrough_toggle.toggle_mode = true
	_passthrough_toggle.theme_type_variation = &"Toggle"
	_passthrough_toggle.toggled.connect(func(on):
		var value := "passthrough" if on else _surroundings
		_select_choice("environment", value)
		setting_changed.emit("environment", value))
	grid.add_child(_passthrough_toggle)
	for item in [["mic_mute", "Mic mute"], ["boundary", "Boundary"], ["dnd", "Do not disturb"],
			["smoothing_on", "Smoothing"], ["stats", "Stats overlay"], ["night_tint", "Night tint"]]:
		var toggle := _button(item[1])
		toggle.toggle_mode = true
		toggle.theme_type_variation = &"Toggle"
		var key: String = item[0]
		toggle.toggled.connect(func(on): quick_changed.emit(key, on))
		grid.add_child(toggle)
		_quick[key] = toggle
	(_quick["smoothing_on"] as Button).set_pressed_no_signal(true)
	var recentre := _button("Recentre")
	recentre.theme_type_variation = &"Toggle"
	recentre.pressed.connect(func(): recentre_requested.emit())
	grid.add_child(recentre)


func _build_desktop(body: Control) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	body.add_child(box)
	var well := PanelContainer.new()
	well.theme_type_variation = &"Well"
	well.size_flags_vertical = Control.SIZE_EXPAND_FILL
	well.clip_contents = true
	box.add_child(well)
	_desktop_view = TextureRect.new()
	_desktop_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_desktop_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_desktop_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	well.add_child(_desktop_view)
	_desktop_note = _label("Starting the desktop view…", &"Muted", true)
	_desktop_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_desktop_note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	well.add_child(_desktop_note)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	for button in _choice_buttons("desktop_screen", [["all", "All screens"], ["active", "Active screen"]]):
		row.add_child(button)
	_big_button = _button("Pop out screens")
	_big_button.toggle_mode = true
	_big_button.theme_type_variation = &"Toggle"
	_big_button.toggled.connect(func(on): big_screen_toggled.emit(on))
	row.add_child(_big_button)
	var keys := _button("Keyboard")
	keys.theme_type_variation = &"Toggle"
	keys.pressed.connect(func(): keyboard_requested.emit())
	row.add_child(keys)
	var note := _label("Point to move the PC's mouse, trigger clicks, B/Y right-clicks, the stick scrolls.", &"Muted", true)
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note.size_flags_stretch_ratio = 1.6
	note.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(note)


## The live picture of the desktop (from main.gd), or a message saying why there is none.
func set_desktop(texture: Texture2D, message := "") -> void:
	_desktop_view.texture = texture
	_desktop_note.visible = texture == null or message != ""
	_desktop_note.text = message if message != "" else "Starting the desktop view…"
	_desktop_view.modulate.a = 0.35 if message != "" else 1.0


## The spot of the desktop picture (0..1) under a point of this interface, or null when the
## point isn't on the picture.
func desktop_uv(at: Vector2) -> Variant:
	if _desktop_view == null or _desktop_view.texture == null or not _desktop_view.is_visible_in_tree():
		return null
	var rect := _desktop_view.get_global_rect()
	var picture := _desktop_view.texture.get_size()
	if picture.x <= 0 or picture.y <= 0 or rect.size.x <= 0 or rect.size.y <= 0:
		return null
	var fit := minf(rect.size.x / picture.x, rect.size.y / picture.y)     # KEEP_ASPECT_CENTERED
	var drawn := Rect2(rect.position + (rect.size - picture * fit) / 2.0, picture * fit)
	if not drawn.has_point(at):
		return null
	return (at - drawn.position) / drawn.size


func set_big_screen(on: bool) -> void:
	_big_button.set_pressed_no_signal(on)


func _build_library(body: Control) -> void:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 5
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	scroll.add_child(grid)
	var games := SteamLibrary.games()
	if games.is_empty():
		grid.columns = 1
		grid.add_child(_label("No VR games were found. Install one in Steam, or check the Library page of the GogglesXR app on the desktop.", &"Muted", true))
		return
	for game in games:
		grid.add_child(_game_card(game))


## A cover-art card: Steam's cover with the name underneath, or a tinted card with the name.
func _game_card(game: Dictionary) -> Control:
	var art_size := Vector2i(216, 300)
	var card := Button.new()
	card.theme_type_variation = &"Card"
	card.focus_mode = Control.FOCUS_NONE
	card.custom_minimum_size = Vector2(art_size.x + 12, art_size.y + 58)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.clip_contents = true
	card.pressed.connect(_launch.bind(game))
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 6)
	card.add_child(box)
	var texture := SteamLibrary.cover(str(game.get("art", "")), art_size)
	if texture:
		var picture := TextureRect.new()
		picture.texture = texture
		picture.custom_minimum_size = Vector2(art_size)
		picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picture.size_flags_vertical = Control.SIZE_EXPAND_FILL
		picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(picture)
	else:
		var blank := PanelContainer.new()
		blank.theme_type_variation = &"Art"
		blank.custom_minimum_size = Vector2(art_size)
		blank.size_flags_vertical = Control.SIZE_EXPAND_FILL
		blank.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var initials := _label("".join(Array(str(game.name).replace(":", " ").split(" ", false)).slice(0, 3).map(func(w): return w[0].to_upper())), &"Clock")
		initials.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		initials.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		blank.add_child(initials)
		box.add_child(blank)
	var title := _label(("★ " if game.get("favourite", false) else "") + str(game.name), &"Muted")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.add_theme_color_override("font_color", INK)
	box.add_child(title)
	return card


func _build_settings(body: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 22)
	body.add_child(row)
	var cats := VBoxContainer.new()
	cats.custom_minimum_size = Vector2(240, 0)
	cats.add_theme_constant_override("separation", 6)
	row.add_child(cats)
	var pages := Control.new()
	pages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(pages)
	var clear_of_hint := Control.new()       # room for the "Current Game ▶" hint on the right edge
	clear_of_hint.custom_minimum_size = Vector2(104, 0)
	row.add_child(clear_of_hint)
	var group := ButtonGroup.new()
	var sections := {
		"Appearance": _settings_appearance, "Controllers": _settings_controllers, "Recording": _settings_recording,
		"Home": _settings_home, "Desktop": _settings_desktop, "Streaming": _settings_streaming, "About": _settings_about,
	}
	for section in sections:
		var page := VBoxContainer.new()
		page.set_anchors_preset(Control.PRESET_FULL_RECT)
		page.add_theme_constant_override("separation", 16)
		page.visible = section == "Appearance"
		pages.add_child(page)
		sections[section].call(page)
		var tab := _button(section)
		tab.theme_type_variation = &"Tab"
		tab.toggle_mode = true
		tab.button_group = group
		tab.button_pressed = section == "Appearance"
		tab.alignment = HORIZONTAL_ALIGNMENT_LEFT
		tab.toggled.connect(func(on): page.visible = on)
		cats.add_child(tab)
		_settings_tabs[section] = tab


## Open a section of the Settings panel ("Recording", "Home"...).
func show_settings(section: String) -> void:
	if _settings_tabs.has(section):
		(_settings_tabs[section] as Button).button_pressed = true


func _settings_appearance(page: Control) -> void:
	var scale_slider := _slider_row(page, "Size", 50, 160, 100)
	scale_slider.value_changed.connect(func(v): scale_changed.emit(v / 100.0))
	_choice_row(page, "Sounds", "ui_sounds", [["on", "On"], ["quiet", "Quiet"], ["off", "Off"]])
	page.add_child(_label("To move the dashboard, hold grip on the status bar under the panel and point where you want it. While holding, push the stick forward to send it further away (bigger) or pull it back to bring it closer (smaller). Recentre puts it back in front of you.", &"Muted", true))


func _settings_controllers(page: Control) -> void:
	_smoothing_slider = _slider_row(page, "Pointer smoothing", 0, 100, 60)
	_smoothing_slider.value_changed.connect(func(v): smoothing_changed.emit(v / 100.0))
	page.add_child(_label("Steadies the laser. Higher values hold the pointer stiller on small buttons; 0 follows your hand exactly. Fast movements are never slowed down.", &"Muted", true))


## Screenshots and clips (the gogglesxr command reads these when you press Record clip)
func _settings_recording(page: Control) -> void:
	page.add_theme_constant_override("separation", 10)
	_choice_row(page, "Shape", "record_aspect", [["16:9", "16:9"], ["9:16", "9:16 upright"], ["1:1", "1:1"], ["4:3", "4:3"]])
	_choice_row(page, "Resolution", "record_resolution", [[1080, "1080p"], [720, "720p"], [1440, "1440p"]])
	_choice_row(page, "Frame rate", "record_fps", [[30, "30"], [60, "60"], [72, "72"], [90, "90"]])
	_choice_row(page, "Quality", "record_bitrate", [[0, "Auto"], [8, "8 Mb/s"], [15, "15"], [30, "30"], [50, "50"]])
	_choice_row(page, "View", "record_view", [["wide", "Wide"], ["normal", "Normal"], ["narrow", "Narrow"]])
	_choice_row(page, "Sound", "record_audio", [["game", "Game"], ["game_mic", "Game + mic"], ["none", "None"]])
	_choice_row(page, "Screenshots", "screenshot_area", [["eye", "Whole view"], ["crop", "Framed like clips"]])
	page.add_child(_label("Encoder and video format are in the GogglesXR app on the desktop.", &"Muted", true))


## What you see around you when no game is running
func _settings_home(page: Control) -> void:
	_choice_row(page, "Surroundings", "environment", [["goggles", "Goggles night"], ["custom", "My picture"], ["passthrough", "Passthrough"], ["none", "Black"]])
	page.add_child(_label("Shown around you while no game is running, and hidden as soon as a game starts. \"My picture\" uses a 360° photo you choose in the GogglesXR app on the desktop (VR settings > Home environment). \"Passthrough\" shows your room through the headset's cameras (Quest 2 and newer).", &"Muted", true))


func _settings_desktop(page: Control) -> void:
	_choice_row(page, "Screen", "desktop_screen", [["all", "All screens"], ["active", "Active screen"]])
	_choice_row(page, "Frame rate", "desktop_fps", [[30, "30"], [15, "15"], [60, "60"]])
	page.add_child(_label("The Desktop panel (below Current Game) shows your PC's desktop. Pop out screens floats each monitor in front of you, also while a game runs: point at one to use it, grip to move it. Higher frame rates use more of the PC's power.", &"Muted", true))


func _settings_streaming(page: Control) -> void:
	_stream_rows = VBoxContainer.new()
	_stream_rows.add_theme_constant_override("separation", 8)
	page.add_child(_stream_rows)
	page.add_child(_label("Change the encoder, codec, connection and paired headsets in the GogglesXR app on the desktop (VR settings).", &"Muted", true))


func _settings_about(page: Control) -> void:
	var version := Engine.get_version_info()
	page.add_child(_label("GogglesXR dashboard 0.1", &"Title"))
	page.add_child(_label("Built with Godot %s.%s" % [version.major, version.minor], &"Muted"))
	_status = _label("", &"Muted", true)
	page.add_child(_status)


func _build_strip() -> void:
	var strip := PanelContainer.new()
	strip.theme_type_variation = &"Strip"
	strip.position = Vector2(0, PANEL_SIZE.y + 20)
	strip.size = Vector2(SIZE.x, SIZE.y - PANEL_SIZE.y - 20)
	add_child(strip)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 26)
	strip.add_child(row)
	var time_box := VBoxContainer.new()
	time_box.add_theme_constant_override("separation", -4)
	row.add_child(time_box)
	_clock = _label("--:--", &"Clock")
	time_box.add_child(_clock)
	_date = _label("", &"Muted")
	time_box.add_child(_date)

	# Five-dot map of the panels
	var map := Control.new()
	map.custom_minimum_size = Vector2(54, 54)
	map.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(map)
	for id in POS:
		var dot := ColorRect.new()
		dot.size = Vector2(14, 14)
		dot.position = Vector2(20, 20) + Vector2(POS[id]) * 19.0
		map.add_child(dot)
		_map[id] = dot
	var where_box := VBoxContainer.new()
	where_box.add_theme_constant_override("separation", -2)
	where_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	where_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(where_box)
	_where = _label("", &"Where")
	where_box.add_child(_where)
	where_box.add_child(_label("Grip + swipe: panels  ·  Grip this bar: move", &"Small"))
	# Headset, controllers and connection
	for key in ["head", "left", "right", "ping"]:
		var stat := VBoxContainer.new()
		stat.add_theme_constant_override("separation", -2)
		stat.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		stat.custom_minimum_size = Vector2(92, 0)
		row.add_child(stat)
		var title := _label("", &"Eyebrow")
		var value := _label("", &"Stat")
		stat.add_child(title)
		stat.add_child(value)
		_stats[key] = [title, value]
	set_headset({})


## The headset's state from `gogglesxr headset --json` (main.gd asks every few seconds): batteries
## and ping on the status strip, and the details on Settings > Streaming.
func set_headset(info: Dictionary) -> void:
	if _stats.is_empty():
		return
	var connected: bool = info.get("connected", false)
	var battery: Dictionary = info.get("battery", {})
	var titles := {"head": "HEADSET", "left": "LEFT", "right": "RIGHT"}
	for key in titles:
		var title: Label = _stats[key][0]
		var value: Label = _stats[key][1]
		var b: Dictionary = battery.get(key, {})
		title.get_parent().visible = connected and (key == "head" or not b.is_empty())
		title.text = titles[key] + ("  +" if b.get("charging", false) else "")
		value.text = ("%d%%" % int(b.charge)) if not b.is_empty() else "On"
		var low: bool = not b.is_empty() and int(b.charge) <= 20 and not b.get("charging", false)
		value.add_theme_color_override("font_color", Color("ff9c8a") if low else INK)
	var ping: Variant = info.get("ping_ms")
	var ping_title: Label = _stats.ping[0]
	var ping_value: Label = _stats.ping[1]
	ping_title.get_parent().visible = connected and ping != null
	ping_title.text = "USB" if info.get("connection") == "usb" else "PING"
	if ping != null:
		ping_value.text = "%d ms" % roundi(float(ping))
		var colour := ACCENT if float(ping) < 20 else (ACCENT_2 if float(ping) < 45 else Color("ff9c8a"))
		ping_value.add_theme_color_override("font_color", colour)
	if not connected:
		_stats.head[0].get_parent().visible = info.has("connected")
		_stats.head[0].text = "HEADSET"
		_stats.head[1].text = "Not connected"
		_stats.head[1].add_theme_color_override("font_color", MUTED)
	_fill_stream_rows(info)


func headset_text() -> String:
	var parts := []
	for key in ["head", "left", "right", "ping"]:
		if (_stats[key][0] as Label).get_parent().visible:
			parts.append((_stats[key][0] as Label).text + " " + (_stats[key][1] as Label).text)
	return ", ".join(parts)


func _fill_stream_rows(info: Dictionary) -> void:
	if _stream_rows == null:
		return
	for child in _stream_rows.get_children():
		child.queue_free()
	var rows := [["Engine", str(info.get("engine_name", "WiVRn"))]]
	if not info.get("connected", false):
		rows.append(["Headset", "Not connected"])
	else:
		rows.append(["Headset", str(info.get("name", "Connected"))])
		if info.get("bitrate_mbps") != null:
			rows.append(["Stream", "%s Mbps" % str(info.bitrate_mbps)])
		if info.get("refresh_rate") != null:
			rows.append(["Refresh rate", "%d Hz" % roundi(float(info.refresh_rate))])
		if info.get("connection") != null:
			rows.append(["Connection", ("USB cable" if info.connection == "usb" else "Wi-Fi / network") +
					("  ·  %d ms" % roundi(float(info.ping_ms)) if info.get("ping_ms") != null else "")])
		var codecs: Array = info.get("codecs", [])
		if not codecs.is_empty():
			rows.append(["Video", ", ".join(codecs.map(func(c): return str(c).to_upper()))])
	for item in rows:
		var line := HBoxContainer.new()
		var name_label := _label(item[0], &"Muted")
		name_label.custom_minimum_size = Vector2(200, 0)
		line.add_child(name_label)
		line.add_child(_label(item[1]))
		_stream_rows.add_child(line)


## Show the saved settings on the choice buttons (from settings.json, by main.gd).
func apply_settings(prefs: Dictionary) -> void:
	for key in _choices:
		if prefs.has(key):
			_select_choice(key, prefs[key])
	if prefs.has("environment"):
		_show_environment(str(prefs.environment))
	for key in ["brightness", "boundary", "dnd", "smoothing_on", "stats", "night_tint"]:
		if prefs.has(key):
			set_quick(key, prefs[key])


## Show a Quick Settings value without acting on it (saved settings, or the system's state).
func set_quick(key: String, value: Variant) -> void:
	var control: Variant = _quick.get(key)
	if control is Button:
		(control as Button).set_pressed_no_signal(bool(value))
	elif control is HSlider:
		var slider := control as HSlider
		slider.set_meta("syncing", true)
		slider.set_value_no_signal(float(value))
		slider.remove_meta("syncing")
		var readout: Label = _quick_readouts.get(key, slider.get_parent().get_child(2))
		readout.text = str(int(slider.value))


func quick(key: String) -> Variant:
	var control: Variant = _quick.get(key)
	if control is Button:
		return (control as Button).button_pressed
	if control is HSlider:
		return (control as HSlider).value
	return null


## The bitrate slider works while a stream reports its bitrate.
func set_bitrate_available(mbps: Variant) -> void:
	var slider: HSlider = _quick["bitrate"]
	slider.editable = mbps != null
	slider.modulate.a = 1.0 if mbps != null else 0.45
	if mbps == null:
		_quick_readouts["bitrate"].text = "—"
	elif not slider.has_meta("dragging"):
		set_quick("bitrate", mbps)


## Keep the Quick Settings Passthrough toggle in step with the chosen surroundings.
func _show_environment(value: String) -> void:
	if value != "passthrough":
		_surroundings = value
	if _passthrough_toggle:
		_passthrough_toggle.set_pressed_no_signal(value == "passthrough")


## The chosen value of a setting's buttons.
func choice(key: String) -> Variant:
	for buttons in _choices.get(key, []):
		for value in buttons:
			if (buttons[value] as Button).button_pressed:
				return value
	return null


# ------------------------------------------------------------------ actions
func _launch(game: Dictionary) -> void:
	say("Starting %s" % game.name if SteamLibrary.launch(str(game.launch)) else "Couldn't start Steam")


func _read_volume() -> float:
	var out := []
	if OS.execute("wpctl", ["get-volume", "@DEFAULT_AUDIO_SINK@"], out) == 0 and not out.is_empty():
		var parts: PackedStringArray = str(out[0]).strip_edges().split(" ")
		if parts.size() >= 2 and parts[1].is_valid_float():
			return clampf(parts[1].to_float() * 100.0, 0, 100)
	return 50


func _set_volume(percent: float) -> void:
	OS.create_process("wpctl", ["set-volume", "@DEFAULT_AUDIO_SINK@", "%d%%" % int(percent)])


func _tick() -> void:
	var now := Time.get_datetime_dict_from_system()
	_clock.text = "%02d:%02d" % [now.hour, now.minute]
	var days := ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	_date.text = "%s %d %s" % [days[now.weekday], now.day, months[now.month - 1]]


# ------------------------------------------------------------------ sound and motion
func _play(name: String, pitch := 1.0) -> void:
	if sounds:
		sounds.play(name, pitch)


## Give buttons and sliders their sounds and hover/press motion (also ones added later).
func _wire(node: Node) -> void:
	if node.has_meta("wired"):
		return
	if node is BaseButton:
		node.set_meta("wired", true)
		var b: BaseButton = node
		b.resized.connect(func(): b.pivot_offset = b.size / 2.0)
		b.pivot_offset = b.size / 2.0
		b.mouse_entered.connect(func():
			if not b.disabled:
				_play("hover")
				_bump(b, 1.025))
		b.mouse_exited.connect(func(): _bump(b, 1.0))
		b.button_down.connect(func(): _bump(b, 0.965, 0.07))
		b.button_up.connect(func(): _bump(b, 1.025 if b.is_hovered() else 1.0, 0.22))
		b.pressed.connect(func():
			if b.theme_type_variation == &"Hint":
				return                    # moving to the panel makes its own sound
			if b.toggle_mode:
				_play("toggle", 1.12 if b.button_pressed else 0.9)
			else:
				_play("click"))
	elif node is Slider:
		node.set_meta("wired", true)
		var slider: Slider = node
		slider.drag_started.connect(func():
			_slider_dragging = true
			slider.set_meta("dragging", true))
		slider.drag_ended.connect(func(_changed):
			_slider_dragging = false
			slider.remove_meta("dragging"))
		slider.value_changed.connect(func(v):
			if _slider_dragging:
				_play("key", 0.8 + 0.5 * inverse_lerp(slider.min_value, slider.max_value, v)))
	for child in node.get_children():
		_wire(child)


## Ease a control's size towards `to` (1 = normal).
func _bump(control: Control, to: float, seconds := 0.16) -> void:
	if control.has_meta("bump"):
		(control.get_meta("bump") as Tween).kill()
	if not animate_ui or not control.is_inside_tree():
		control.scale = Vector2.ONE
		return
	var t := control.create_tween()
	control.set_meta("bump", t)
	t.tween_property(control, "scale", Vector2(to, to), seconds).set_trans(Tween.TRANS_BACK if to > 1.0 else Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


# ------------------------------------------------------------------ small helpers
func _label(text: String, variation := &"", wrap := false) -> Label:
	var label := Label.new()
	label.text = text
	if variation != &"":
		label.theme_type_variation = variation
	if wrap:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _button(text: String, primary := false) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, 64)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if primary:
		button.theme_type_variation = &"Primary"
	return button


## A row of buttons where one is chosen, saved as setting `key` (options: [[value, label]]; the
## first is the default).
func _choice_row(parent: Control, text: String, key: String, options: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	var label := _label(text)
	label.custom_minimum_size = Vector2(170, 0)
	row.add_child(label)
	for button in _choice_buttons(key, options):
		button.custom_minimum_size = Vector2(0, 52)
		row.add_child(button)


func _choice_buttons(key: String, options: Array) -> Array:
	var group := ButtonGroup.new()
	var buttons := []
	var by_value := {}
	if not _choices.has(key):
		_choices[key] = []
	_choices[key].append(by_value)
	for option in options:
		var button := _button(str(option[1]))
		button.toggle_mode = true
		button.button_group = group
		button.theme_type_variation = &"Toggle"
		button.button_pressed = option == options[0]
		var value: Variant = option[0]
		button.pressed.connect(func():
			_select_choice(key, value)        # the same setting shown elsewhere follows
			setting_changed.emit(key, value))
		by_value[value] = button
		buttons.append(button)
	return buttons


func _select_choice(key: String, value: Variant) -> void:
	if key == "environment":
		_show_environment(str(value))
	for buttons in _choices.get(key, []):
		var found := false
		for option in buttons:
			# settings.json numbers come back as floats: 30.0 is the same choice as 30
			var numbers: bool = typeof(option) in [TYPE_INT, TYPE_FLOAT] and typeof(value) in [TYPE_INT, TYPE_FLOAT]
			found = found or option == value or (numbers and float(option) == float(value))
		if not found:
			continue                          # an unknown value: keep what is shown
		for option in buttons:
			var numbers: bool = typeof(option) in [TYPE_INT, TYPE_FLOAT] and typeof(value) in [TYPE_INT, TYPE_FLOAT]
			(buttons[option] as Button).set_pressed_no_signal(option == value or (numbers and float(option) == float(value)))


## Mark a control that doesn't do anything yet.
func _soon(control: Control) -> Control:
	control.modulate.a = 0.45
	control.tooltip_text = "Not connected yet"
	if control is BaseButton:
		control.disabled = true
	elif control is Range:
		control.editable = false
	return control


func _slider_row(parent: Control, text: String, from: float, to: float, value: float) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	parent.add_child(row)
	var label := _label(text)
	label.custom_minimum_size = Vector2(170, 0)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = from
	slider.max_value = to
	slider.value = value
	slider.focus_mode = Control.FOCUS_NONE
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(0, 44)
	row.add_child(slider)
	var readout := _label(str(int(value)), &"Muted")
	readout.custom_minimum_size = Vector2(64, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	slider.value_changed.connect(func(v): readout.text = str(int(v)))
	row.add_child(readout)
	return slider


func _hint_text(dir: String, title: String) -> String:
	match dir:
		"up": return "▲  " + title
		"down": return "▼  " + title
		"left": return "◀  " + title
		_: return title + "  ▶"


## A soft accent-coloured glow around a box.
func _glow(box: StyleBoxFlat, strength: float) -> StyleBoxFlat:
	box.shadow_color = Color(ACCENT, strength)
	box.shadow_size = 12
	return box


## The slider's round handle, drawn here (no image files to ship).
func _knob(diameter: int, lit: bool) -> ImageTexture:
	var image := Image.create(diameter + 8, diameter + 8, false, Image.FORMAT_RGBA8)
	var centre := Vector2(image.get_width(), image.get_height()) / 2.0
	var r := diameter / 2.0
	for y in image.get_height():
		for x in image.get_width():
			var d := Vector2(x + 0.5, y + 0.5).distance_to(centre)
			var c := Color(0, 0, 0, 0)
			if d <= r + 4.0 and lit:
				c = Color(ACCENT, 0.25 * clampf((r + 4.0 - d) / 4.0, 0.0, 1.0))      # halo
			if d <= r:
				var ring := d > r - 4.0
				c = Color.WHITE if ring else ACCENT.lightened(0.1 if lit else 0.0)
				c.a = clampf(r - d + 0.5, 0.0, 1.0)                               # smooth edge
			image.set_pixel(x, y, c)
	return ImageTexture.create_from_image(image)


func _box(color: Color, radius := 18, border := LINE, border_width := 1, margin := 0) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_content_margin_all(margin)
	box.anti_aliasing = true
	return box


## The website's fonts (fonts/README.md), with the system's fonts for any missing characters.
func _load_fonts() -> void:
	var system := SystemFont.new()
	system.font_names = PackedStringArray(["Noto Sans", "Noto Sans Symbols", "Noto Sans Symbols 2", "DejaVu Sans"])
	var files := {"body": "inter-400", "body_bold": "inter-600", "head": "outfit-600", "head_medium": "outfit-500"}
	for key in files:
		var path := ProjectSettings.globalize_path("res://fonts/%s.woff2" % files[key])
		var font := FontFile.new()
		if FileAccess.file_exists(path) and font.load_dynamic_font(path) == OK:
			font.fallbacks = [system]
			font.multichannel_signed_distance_field = false
			font.oversampling = 2.0          # crisp when the panel is near your face
			_fonts[key] = font
	if _fonts.has("body_bold"):
		var spaced := FontVariation.new()   # small capitals with air between the letters
		spaced.base_font = _fonts.body_bold
		spaced.spacing_glyph = 2
		_fonts["eyebrow"] = spaced


func _font(t: Theme, type: String, key: String) -> void:
	if _fonts.has(key):
		t.set_font("font", type, _fonts[key])


func _make_theme() -> Theme:
	_load_fonts()
	var t := Theme.new()
	t.default_font_size = 24
	if _fonts.has("body"):
		t.default_font = _fonts.body
	t.set_color("font_color", "Label", INK)
	var glass := _box(GLASS, 30, Color(ACCENT, 0.24), 1, 34)
	glass.shadow_color = Color(0, 0, 0, 0.35)
	glass.shadow_size = 28
	glass.shadow_offset = Vector2(0, 10)
	t.set_stylebox("panel", "PanelContainer", glass)

	for variation in ["Title", "Eyebrow", "Muted", "Clock", "Where", "Toast", "Small", "Stat"]:
		t.set_type_variation(variation, "Label")
	t.set_font_size("font_size", "Small", 16)
	t.set_color("font_color", "Small", MUTED)
	t.set_font_size("font_size", "Stat", 24)
	t.set_font_size("font_size", "Title", 34)
	t.set_font_size("font_size", "Eyebrow", 17)
	t.set_color("font_color", "Eyebrow", ACCENT)
	t.set_font_size("font_size", "Muted", 20)
	t.set_color("font_color", "Muted", MUTED)
	t.set_font_size("font_size", "Clock", 40)
	t.set_font_size("font_size", "Where", 26)
	t.set_font_size("font_size", "Toast", 22)
	var toast := _box(Color(0.016, 0.07, 0.06, 0.96), 18, Color(ACCENT, 0.45), 1, 16)
	toast.shadow_color = Color(ACCENT, 0.18)
	toast.shadow_size = 16
	t.set_stylebox("normal", "Toast", toast)
	_font(t, "Title", "head")
	_font(t, "Clock", "head_medium")
	_font(t, "Where", "head_medium")
	_font(t, "Stat", "head")
	_font(t, "Eyebrow", "eyebrow")

	for variation in ["Art", "Well", "Strip"]:
		t.set_type_variation(variation, "PanelContainer")
	t.set_stylebox("panel", "Art", _box(Color(0.09, 0.36, 0.33, 0.9), 20, LINE, 1, 26))
	t.set_stylebox("panel", "Well", _box(WELL, 18, LINE, 1, 24))
	t.set_stylebox("panel", "Strip", _box(Color(0.016, 0.07, 0.06, 0.88), 20, LINE, 1, 22))

	# Buttons
	t.set_color("font_color", "Button", INK)
	t.set_color("font_hover_color", "Button", INK)
	t.set_color("font_pressed_color", "Button", INK)
	t.set_color("font_disabled_color", "Button", INK)
	_font(t, "Button", "body_bold")
	t.set_font_size("font_size", "Button", 22)
	t.set_stylebox("normal", "Button", _box(Color(1, 1, 1, 0.06), 16, LINE, 1, 14))
	t.set_stylebox("hover", "Button", _glow(_box(Color(ACCENT, 0.14), 16, ACCENT, 1, 14), 0.22))
	t.set_stylebox("pressed", "Button", _glow(_box(Color(ACCENT, 0.26), 16, ACCENT, 1, 14), 0.3))
	t.set_stylebox("disabled", "Button", _box(Color(1, 1, 1, 0.06), 16, LINE, 1, 14))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())

	for variation in ["Primary", "Toggle", "Card", "Tab", "Hint"]:
		t.set_type_variation(variation, "Button")
	for state in ["font_color", "font_hover_color", "font_pressed_color"]:
		t.set_color(state, "Primary", Color("052012"))
	t.set_stylebox("normal", "Primary", _glow(_box(ACCENT, 16, ACCENT, 0, 14), 0.28))
	t.set_stylebox("hover", "Primary", _glow(_box(ACCENT.lightened(0.18), 16, ACCENT, 0, 14), 0.45))
	t.set_stylebox("pressed", "Primary", _glow(_box(ACCENT.darkened(0.15), 16, ACCENT, 0, 14), 0.2))
	t.set_stylebox("normal", "Toggle", _box(WELL, 16, LINE, 1, 16))
	t.set_stylebox("disabled", "Toggle", _box(WELL, 16, LINE, 1, 16))
	t.set_stylebox("pressed", "Toggle", _glow(_box(Color(ACCENT, 0.22), 16, ACCENT, 2, 16), 0.25))
	t.set_stylebox("normal", "Card", _box(WELL, 18, LINE, 1, 16))
	t.set_stylebox("hover", "Card", _glow(_box(Color(ACCENT, 0.14), 18, ACCENT, 1, 16), 0.25))
	t.set_stylebox("normal", "Tab", _box(Color(0, 0, 0, 0), 12, Color(0, 0, 0, 0), 1, 14))
	t.set_stylebox("pressed", "Tab", _box(Color(ACCENT, 0.16), 12, Color(ACCENT, 0.4), 1, 14))
	t.set_color("font_color", "Tab", MUTED)
	t.set_font_size("font_size", "Hint", 18)
	t.set_color("font_color", "Hint", MUTED)
	t.set_stylebox("normal", "Hint", _box(Color(0.016, 0.07, 0.06, 0.88), 99, Color(ACCENT, 0.3), 1, 10))
	t.set_stylebox("hover", "Hint", _glow(_box(Color(0.016, 0.07, 0.06, 0.95), 99, ACCENT, 1, 10), 0.3))
	t.set_stylebox("pressed", "Hint", _box(Color(ACCENT, 0.25), 99, ACCENT, 1, 10))

	# Sliders
	var groove := _box(Color(1, 1, 1, 0.14), 5, Color(0, 0, 0, 0), 0)
	groove.content_margin_top = 5
	groove.content_margin_bottom = 5
	var fill := _box(ACCENT, 5, Color(0, 0, 0, 0), 0)
	fill.content_margin_top = 5
	fill.content_margin_bottom = 5
	t.set_stylebox("slider", "HSlider", groove)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	t.set_icon("grabber", "HSlider", _knob(30, false))
	t.set_icon("grabber_highlight", "HSlider", _knob(34, true))
	t.set_constant("separation", "HBoxContainer", 12)
	return t
