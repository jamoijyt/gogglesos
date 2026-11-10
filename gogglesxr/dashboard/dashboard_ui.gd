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
signal scale_changed(factor: float)

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

var current := "game"
var _track: Control
var _hints := {}
var _map := {}
var _where: Label
var _clock: Label
var _date: Label
var _status: Label
var _toast: Label
var _tween: Tween
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
	current = id
	var target := -Vector2(POS[id]) * (PANEL_SIZE + Vector2(GAP, GAP))
	if _tween:
		_tween.kill()
	if animate:
		_tween = create_tween()
		_tween.tween_property(_track, "position", target, 0.38).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	else:
		_track.position = target
	# Panels outside the window are clipped, so only the one in view can be seen or clicked
	for panel in _track.get_children():
		panel.modulate.a = 1.0 if panel.name == id else 0.5
	for dir in _hints:
		var n := neighbour(id, dir)
		_hints[dir].visible = n != ""
		if n != "":
			_hints[dir].text = _hint_text(dir, TITLES[n])
	for key in _map:
		_map[key].color = ACCENT if key == id else Color(1, 1, 1, 0.18)
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
	_toast.modulate.a = 1.0
	var t := create_tween()
	t.tween_interval(1.6)
	t.tween_property(_toast, "modulate:a", 0.0, 0.4)


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
	row.add_child(art)
	var art_box := VBoxContainer.new()
	art_box.alignment = BoxContainer.ALIGNMENT_END
	art.add_child(art_box)
	art_box.add_child(_label("NO GAME RUNNING", &"Eyebrow"))
	art_box.add_child(_label("GogglesXR", &"Title"))
	art_box.add_child(_label("Start a game from the Library panel, on the right.", &"Muted"))

	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_theme_constant_override("separation", 12)
	row.add_child(side)
	var library := _button("Open library", true)
	library.pressed.connect(show_panel.bind("library"))
	side.add_child(library)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	side.add_child(grid)
	var recentre := _button("Recentre")
	recentre.pressed.connect(func(): recentre_requested.emit(); say("View recentred"))
	grid.add_child(recentre)
	for text in ["Screenshot", "Record clip", "Quit game"]:
		grid.add_child(_soon(_button(text)))
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(spacer)
	side.add_child(_label("Game details, screenshots and live performance arrive when the dashboard can run on top of a game.", &"Muted", true))


func _build_quick(body: Control) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 20)
	body.add_child(box)
	var volume := _slider_row(box, "Volume", 0, 100, _read_volume())
	volume.value_changed.connect(_set_volume)
	_soon(_slider_row(box, "Brightness", 0, 100, 80))
	_soon(_slider_row(box, "Render scale", 50, 150, 100))
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(spacer)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	box.add_child(grid)
	for text in ["Mic mute", "Passthrough", "Boundary", "Do not disturb", "Smoothing", "Stats overlay", "Night tint"]:
		var toggle := _button(text)
		toggle.toggle_mode = true
		toggle.theme_type_variation = &"Toggle"
		grid.add_child(_soon(toggle))
	var recentre := _button("Recentre")
	recentre.theme_type_variation = &"Toggle"
	recentre.pressed.connect(func(): recentre_requested.emit(); say("View recentred"))
	grid.add_child(recentre)


func _build_desktop(body: Control) -> void:
	var well := PanelContainer.new()
	well.theme_type_variation = &"Well"
	body.add_child(well)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	well.add_child(box)
	var title := _label("Your desktop will appear here", &"Title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var note := _label("The laser will work as the mouse: trigger to click, stick to scroll.", &"Muted")
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(note)


func _build_library(body: Control) -> void:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	scroll.add_child(grid)
	var games := SteamLibrary.installed_games()
	if games.is_empty():
		grid.columns = 1
		grid.add_child(_label("No installed Steam games were found.", &"Muted"))
		return
	for game in games:
		var card := _button(game.name)
		card.theme_type_variation = &"Card"
		card.custom_minimum_size = Vector2(0, 96)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.clip_text = true
		card.pressed.connect(_launch.bind(game))
		grid.add_child(card)


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
	var group := ButtonGroup.new()
	var sections := {
		"Appearance": _settings_appearance, "Display": _settings_soon, "Streaming": _settings_soon,
		"Audio": _settings_soon, "Controllers": _settings_soon, "Play area": _settings_soon, "About": _settings_about,
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


func _settings_appearance(page: Control) -> void:
	var scale_slider := _slider_row(page, "Size", 50, 160, 100)
	scale_slider.value_changed.connect(func(v): scale_changed.emit(v / 100.0))
	page.add_child(_label("To move the dashboard, hold grip on the status bar under the panel and point where you want it. While holding, push the stick forward to send it further away (bigger) or pull it back to bring it closer (smaller). Recentre puts it back in front of you.", &"Muted", true))


func _settings_soon(page: Control) -> void:
	page.add_child(_label("These settings arrive with GogglesXR's own runtime.", &"Muted", true))


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
	_where = _label("", &"Where")
	_where.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_where.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_where)
	var help := _label("Grip + swipe: change panel    Grip this bar: move    Trigger: select", &"Muted")
	help.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(help)


# ------------------------------------------------------------------ actions
func _launch(game: Dictionary) -> void:
	say("Starting %s" % game.name if SteamLibrary.launch(game.id) else "Couldn't start Steam")


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


func _box(color: Color, radius := 18, border := LINE, border_width := 1, margin := 0) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_content_margin_all(margin)
	box.anti_aliasing = true
	return box


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 24
	t.set_color("font_color", "Label", INK)
	t.set_stylebox("panel", "PanelContainer", _box(GLASS, 26, Color(ACCENT, 0.3), 1, 34))

	for variation in ["Title", "Eyebrow", "Muted", "Clock", "Where", "Toast"]:
		t.set_type_variation(variation, "Label")
	t.set_font_size("font_size", "Title", 34)
	t.set_font_size("font_size", "Eyebrow", 17)
	t.set_color("font_color", "Eyebrow", ACCENT)
	t.set_font_size("font_size", "Muted", 20)
	t.set_color("font_color", "Muted", MUTED)
	t.set_font_size("font_size", "Clock", 40)
	t.set_font_size("font_size", "Where", 26)
	t.set_font_size("font_size", "Toast", 22)
	t.set_stylebox("normal", "Toast", _box(Color(0.016, 0.07, 0.06, 0.96), 14, Color(ACCENT, 0.4), 1, 14))

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
	t.set_stylebox("normal", "Button", _box(Color(1, 1, 1, 0.06), 14, LINE, 1, 14))
	t.set_stylebox("hover", "Button", _box(Color(ACCENT, 0.14), 14, ACCENT, 1, 14))
	t.set_stylebox("pressed", "Button", _box(Color(ACCENT, 0.26), 14, ACCENT, 1, 14))
	t.set_stylebox("disabled", "Button", _box(Color(1, 1, 1, 0.06), 14, LINE, 1, 14))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())

	for variation in ["Primary", "Toggle", "Card", "Tab", "Hint"]:
		t.set_type_variation(variation, "Button")
	for state in ["font_color", "font_hover_color", "font_pressed_color"]:
		t.set_color(state, "Primary", Color("052012"))
	t.set_stylebox("normal", "Primary", _box(ACCENT, 14, ACCENT, 0, 14))
	t.set_stylebox("hover", "Primary", _box(ACCENT.lightened(0.18), 14, ACCENT, 0, 14))
	t.set_stylebox("pressed", "Primary", _box(ACCENT.darkened(0.15), 14, ACCENT, 0, 14))
	t.set_stylebox("normal", "Toggle", _box(WELL, 16, LINE, 1, 16))
	t.set_stylebox("disabled", "Toggle", _box(WELL, 16, LINE, 1, 16))
	t.set_stylebox("pressed", "Toggle", _box(Color(ACCENT, 0.2), 16, ACCENT, 2, 16))
	t.set_stylebox("normal", "Card", _box(WELL, 16, LINE, 1, 16))
	t.set_stylebox("hover", "Card", _box(Color(ACCENT, 0.14), 16, ACCENT, 1, 16))
	t.set_stylebox("normal", "Tab", _box(Color(0, 0, 0, 0), 12, Color(0, 0, 0, 0), 1, 14))
	t.set_stylebox("pressed", "Tab", _box(Color(ACCENT, 0.16), 12, Color(ACCENT, 0.4), 1, 14))
	t.set_color("font_color", "Tab", MUTED)
	t.set_font_size("font_size", "Hint", 18)
	t.set_color("font_color", "Hint", MUTED)
	t.set_stylebox("normal", "Hint", _box(Color(0.016, 0.07, 0.06, 0.88), 16, Color(ACCENT, 0.3), 1, 8))
	t.set_stylebox("hover", "Hint", _box(Color(0.016, 0.07, 0.06, 0.95), 16, ACCENT, 1, 8))
	t.set_stylebox("pressed", "Hint", _box(Color(ACCENT, 0.25), 16, ACCENT, 1, 8))

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
	t.set_constant("separation", "HBoxContainer", 12)
	return t
