extends Control
## The Home menu: a panel that floats in front of you (B or Y opens and closes it).
##   Furniture   pick something and it appears in front of you (gadgets, toys and pets too)
##   Pictures    your own pictures (~/Pictures): pick one and it appears as a poster
##   Look        the sky outside, walls, floor, accent colour, the lights on each floor
##   Settings    moving and turning, hands, the tour, tidying up, and what the buttons do
## main.gd shows it on a quad, points the laser at it and acts on its signals.

const Furniture := preload("res://furniture.gd")
const Room := preload("res://room.gd")
const Skies := preload("res://skies.gd")
const Hands := preload("res://hands.gd")

signal spawn_requested(id: String)
signal poster_requested(path: String, framed: bool)
signal look_changed(key: String, value: Variant)
signal setting_changed(key: String, value: Variant)
signal action(name: String)                # "tidy", "clear", "close", "tour", "erase"
signal pressed_something(toggle: bool)     # for the click sounds

const SIZE := Vector2(1100, 740)
const ACCENT := Color("3ddc84")
const INK := Color("e6f3ee")
const MUTED := Color("9fbfb4")

var _tabs := {}                           # name -> [Button, page]
var _choices := {}                        # key -> {value: Button}
var _sliders := {}
var _category_pages := {}
var _clear_armed_until := 0
var _clear_button: Button
var _fonts := {}
var _pictures: GridContainer
var _picture_note: Label
var _framed: CheckButton


func _ready() -> void:
	size = SIZE
	custom_minimum_size = SIZE
	theme = _make_theme()
	var back := PanelContainer.new()
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(back)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	back.add_child(box)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	box.add_child(head)
	var title := Label.new()
	title.text = "Goggles Home"
	title.theme_type_variation = &"Title"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var pages := Control.new()
	pages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var group := ButtonGroup.new()
	for name in ["Furniture", "Pictures", "Look", "Settings"]:
		var page := VBoxContainer.new()
		page.set_anchors_preset(Control.PRESET_FULL_RECT)
		page.add_theme_constant_override("separation", 14)
		page.visible = name == "Furniture"
		pages.add_child(page)
		var tab := _button(name)
		tab.toggle_mode = true
		tab.button_group = group
		tab.button_pressed = name == "Furniture"
		tab.custom_minimum_size = Vector2(130, 52)
		tab.toggled.connect(func(on):
			page.visible = on
			if on:
				_appear(page))
		head.add_child(tab)
		_tabs[name] = [tab, page]
	var close := _button("Close")
	close.custom_minimum_size = Vector2(110, 52)
	close.pressed.connect(func(): action.emit("close"))
	head.add_child(close)
	box.add_child(pages)
	_build_furniture(_tabs["Furniture"][1])
	_build_pictures(_tabs["Pictures"][1])
	_build_look(_tabs["Look"][1])
	_build_settings(_tabs["Settings"][1])


## Things on a page pop in one after another.
func _appear(page: Control) -> void:
	var i := 0
	for node in page.find_children("*", "Button", true, false):
		var b := node as Button
		if not b.is_visible_in_tree() or i > 40:
			continue
		b.pivot_offset = b.size / 2.0
		b.scale = Vector2(0.85, 0.85)
		b.modulate.a = 0.0
		var t := b.create_tween().set_parallel()
		t.tween_property(b, "scale", Vector2.ONE, 0.22).set_delay(i * 0.012).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_property(b, "modulate:a", 1.0, 0.15).set_delay(i * 0.012)
		i += 1


func show_tab(name: String) -> void:
	for key in _tabs:
		if key.to_lower() == name.to_lower():
			(_tabs[key][0] as Button).button_pressed = true


# ------------------------------------------------------------------ Furniture
func _build_furniture(page: VBoxContainer) -> void:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 8)
	row.add_theme_constant_override("v_separation", 8)
	page.add_child(row)
	var holder := Control.new()
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var group := ButtonGroup.new()
	for category in Furniture.CATEGORIES:
		var scroll := ScrollContainer.new()
		scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.visible = category == Furniture.CATEGORIES[0]
		holder.add_child(scroll)
		var grid := GridContainer.new()
		grid.columns = 6
		grid.add_theme_constant_override("h_separation", 10)
		grid.add_theme_constant_override("v_separation", 10)
		scroll.add_child(grid)
		for id in Furniture.CATALOGUE:
			if Furniture.CATALOGUE[id][1] == category:
				grid.add_child(_thing_button(id))
		var tab := _button(category)
		tab.theme_type_variation = &"Chip"
		tab.toggle_mode = true
		tab.button_group = group
		tab.button_pressed = scroll.visible
		tab.toggled.connect(func(on):
			scroll.visible = on
			if on:
				_appear(grid))
		row.add_child(tab)
		_category_pages[category] = scroll
	page.add_child(holder)
	var help := Label.new()
	help.theme_type_variation = &"Muted"
	help.text = "Pick something and it appears in front of you. Hold grip on it to move it; while holding, the stick turns it and A or X removes it. Gadgets: pick them up and pull the trigger."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(help)


func _thing_button(id: String) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.theme_type_variation = &"Thing"
	b.custom_minimum_size = Vector2(160, 140)
	b.text = str(Furniture.CATALOGUE[id][0])
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	b.expand_icon = true
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var picture := ProjectSettings.globalize_path("res://thumbs/%s.png" % id)
	if FileAccess.file_exists(picture):
		var image := Image.load_from_file(picture)
		if image:
			b.icon = ImageTexture.create_from_image(image)
			b.add_theme_constant_override("icon_max_width", 104)
	b.pressed.connect(func():
		pressed_something.emit(false)
		spawn_requested.emit(id))
	return b


# ------------------------------------------------------------------ Pictures
func _build_pictures(page: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	page.add_child(row)
	_picture_note = Label.new()
	_picture_note.theme_type_variation = &"Muted"
	_picture_note.text = "Looking for pictures…"
	_picture_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picture_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(_picture_note)
	_framed = CheckButton.new()
	_framed.text = "In a frame"
	_framed.focus_mode = Control.FOCUS_NONE
	row.add_child(_framed)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(scroll)
	_pictures = GridContainer.new()
	_pictures.columns = 6
	_pictures.add_theme_constant_override("h_separation", 10)
	_pictures.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_pictures)


## Your pictures: [{"path", "name", "thumb": Texture2D}].
func set_pictures(list: Array) -> void:
	for child in _pictures.get_children():
		child.queue_free()
	_picture_note.text = ("Pick a picture: it appears in front of you as a poster. Hold grip on it to hang it on a wall."
			if not list.is_empty() else "No pictures yet. Put some in your Pictures folder on the PC (screenshots of the headset view go there too).")
	for entry in list:
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.theme_type_variation = &"Thing"
		b.custom_minimum_size = Vector2(160, 150)
		b.text = str(entry.name).left(18)
		b.icon = entry.thumb
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		b.add_theme_constant_override("icon_max_width", 140)
		var path: String = entry.path
		b.pressed.connect(func():
			pressed_something.emit(false)
			poster_requested.emit(path, _framed.button_pressed))
		_pictures.add_child(b)


# ------------------------------------------------------------------ Look
func _build_look(page: VBoxContainer) -> void:
	var skies := []
	for id in Skies.CHOICES:
		skies.append([id, Skies.CHOICES[id]])
	_choice_row(page, "Outside", "sky", skies, look_changed)
	_choice_row(page, "Walls", "walls", _named(Room.WALLS), look_changed, true)
	_choice_row(page, "Floor", "floor", _named(Room.FLOORS), look_changed, true)
	_choice_row(page, "Accent", "accent", _named(Room.ACCENTS), look_changed, true)
	var moods := []
	for id in Room.MOOD_ORDER:
		moods.append([id, Room.MOODS[id][0]])
	_choice_row(page, "Downstairs", "mood0", moods, look_changed)
	_choice_row(page, "Upstairs", "mood1", moods, look_changed)
	_slider_row(page, "Light strength", "brightness", 0, 100, 50, look_changed)
	var note := Label.new()
	note.theme_type_variation = &"Muted"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.text = "\"My picture\" is the 360° photo chosen in the GogglesXR app on the desktop (VR settings > Home environment)."
	page.add_child(note)


func _named(table: Dictionary) -> Array:
	var list := []
	for id in table:
		list.append([id, table[id][0], table[id][1]])
	return list


# ------------------------------------------------------------------ Settings
func _build_settings(page: VBoxContainer) -> void:
	_choice_row(page, "Moving", "move", [["teleport", "Teleport"], ["smooth", "Smooth"]], setting_changed)
	_choice_row(page, "Turning", "turn", [[45, "45° steps"], [30, "30° steps"], [0, "Off"]], setting_changed)
	_choice_row(page, "Sounds", "sounds", [["on", "On"], ["off", "Off"]], setting_changed)
	var styles := []
	for id in Hands.STYLES:
		styles.append([id, Hands.STYLES[id][0]])
	_choice_row(page, "Hands", "hand_style", styles, setting_changed)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	page.add_child(row)
	var spacer := Label.new()
	spacer.text = "Tidy up"
	spacer.custom_minimum_size = Vector2(170, 0)
	row.add_child(spacer)
	var tidy := _button("Bring toys back")
	tidy.pressed.connect(func():
		pressed_something.emit(false)
		action.emit("tidy"))
	row.add_child(tidy)
	_clear_button = _button("Empty the room")
	_clear_button.pressed.connect(func():
		pressed_something.emit(false)
		if Time.get_ticks_msec() < _clear_armed_until:
			_clear_armed_until = 0
			_clear_button.text = "Empty the room"
			action.emit("clear")
		else:                                  # two presses, so a stray click can't empty it
			_clear_armed_until = Time.get_ticks_msec() + 3000
			_clear_button.text = "Press again to empty")
	row.add_child(_clear_button)
	var erase := _button("Erase drawings")
	erase.pressed.connect(func():
		pressed_something.emit(false)
		action.emit("erase"))
	row.add_child(erase)
	var tour := _button("Show the tour")
	tour.pressed.connect(func():
		pressed_something.emit(false)
		action.emit("tour"))
	row.add_child(tour)
	var help := Label.new()
	help.theme_type_variation = &"Muted"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.text = "B or Y: this menu.   Stick forward: teleport where you point (Smooth: left stick walks).   Stick left or right: turn.\nGrip: pick up furniture, toys, gadgets and tapes.   Trigger: lamps, TVs, the radio, pets, light switches, and gadgets in your hand.\nPlay a game: put its tape into the VHS player.   The menu button (left hand) opens the GogglesXR dashboard."
	page.add_child(help)


# ------------------------------------------------------------------ rows
func _choice_row(parent: Control, text: String, key: String, options: Array, emit_to: Signal, swatches := false) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	parent.add_child(row)
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(170, 0)
	row.add_child(label)
	var group := ButtonGroup.new()
	_choices[key] = {}
	for option in options:
		var b := _button(str(option[1]))
		b.toggle_mode = true
		b.button_group = group
		b.theme_type_variation = &"Chip"
		b.button_pressed = option == options[0]
		if swatches and option.size() > 2:
			var dot := Image.create(22, 22, false, Image.FORMAT_RGBA8)
			for y in 22:
				for x in 22:
					var d := Vector2(x - 10.5, y - 10.5).length()
					dot.set_pixel(x, y, Color(option[2], clampf(10.5 - d, 0.0, 1.0)))
			b.icon = ImageTexture.create_from_image(dot)
		var value: Variant = option[0]
		b.pressed.connect(func():
			pressed_something.emit(true)
			emit_to.emit(key, value))
		row.add_child(b)
		_choices[key][value] = b


func _slider_row(parent: Control, text: String, key: String, from: float, to: float, value: float, emit_to: Signal) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	parent.add_child(row)
	var label := Label.new()
	label.text = text
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
	slider.value_changed.connect(func(v): emit_to.emit(key, v))
	row.add_child(slider)
	_sliders[key] = slider


## Show saved values (look and settings together) without acting on them.
func set_values(values: Dictionary) -> void:
	for key in values:
		if _choices.has(key):
			for option in _choices[key]:
				var same: bool = str(option) == str(values[key]) or (typeof(option) in [TYPE_INT, TYPE_FLOAT] and typeof(values[key]) in [TYPE_INT, TYPE_FLOAT] and float(option) == float(values[key]))
				(_choices[key][option] as Button).set_pressed_no_signal(same)
		elif _sliders.has(key):
			(_sliders[key] as HSlider).set_value_no_signal(float(values[key]))


func chosen(key: String) -> Variant:
	for option in _choices.get(key, {}):
		if (_choices[key][option] as Button).button_pressed:
			return option
	return null


func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 54)
	return b


# ------------------------------------------------------------------ look of the menu itself
func _box(colour: Color, radius: int, border: Color, margin := 12) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = colour
	s.set_corner_radius_all(radius)
	s.border_color = border
	s.set_border_width_all(1)
	s.set_content_margin_all(margin)
	s.anti_aliasing = true
	return s


func _make_theme() -> Theme:
	var t := Theme.new()
	var system := SystemFont.new()
	system.font_names = PackedStringArray(["Noto Sans", "DejaVu Sans"])
	for key in {"body": "inter-400", "bold": "inter-600", "head": "outfit-600"}:
		var path := ProjectSettings.globalize_path("res://fonts/%s.woff2" % {"body": "inter-400", "bold": "inter-600", "head": "outfit-600"}[key])
		var font := FontFile.new()
		if FileAccess.file_exists(path) and font.load_dynamic_font(path) == OK:
			font.fallbacks = [system]
			_fonts[key] = font
	t.default_font_size = 22
	if _fonts.has("body"):
		t.default_font = _fonts.body
	t.set_color("font_color", "Label", INK)
	t.set_stylebox("panel", "PanelContainer", _box(Color(0.047, 0.149, 0.129, 0.94), 28, Color(ACCENT, 0.3), 28))
	for variation in ["Title", "Muted"]:
		t.set_type_variation(variation, "Label")
	t.set_font_size("font_size", "Title", 34)
	if _fonts.has("head"):
		t.set_font("font", "Title", _fonts.head)
	t.set_font_size("font_size", "Muted", 19)
	t.set_color("font_color", "Muted", MUTED)
	if _fonts.has("bold"):
		t.set_font("font", "Button", _fonts.bold)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		t.set_color(state, "Button", INK)
	t.set_font_size("font_size", "Button", 21)
	t.set_stylebox("normal", "Button", _box(Color(1, 1, 1, 0.06), 14, Color(1, 1, 1, 0.12)))
	t.set_stylebox("hover", "Button", _box(Color(ACCENT, 0.16), 14, ACCENT))
	t.set_stylebox("pressed", "Button", _box(Color(ACCENT, 0.3), 14, ACCENT))
	t.set_stylebox("hover_pressed", "Button", _box(Color(ACCENT, 0.36), 14, ACCENT))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	for variation in ["Chip", "Thing"]:
		t.set_type_variation(variation, "Button")
	t.set_stylebox("normal", "Chip", _box(Color(0, 0, 0, 0.3), 14, Color(1, 1, 1, 0.12)))
	t.set_stylebox("normal", "Thing", _box(Color(0, 0, 0, 0.3), 16, Color(1, 1, 1, 0.1), 8))
	t.set_stylebox("hover", "Thing", _box(Color(ACCENT, 0.16), 16, ACCENT, 8))
	t.set_stylebox("pressed", "Thing", _box(Color(ACCENT, 0.3), 16, ACCENT, 8))
	t.set_font_size("font_size", "Thing", 17)
	var groove := _box(Color(1, 1, 1, 0.14), 5, Color(0, 0, 0, 0), 0)
	groove.content_margin_top = 5
	groove.content_margin_bottom = 5
	var fill := _box(ACCENT, 5, Color(0, 0, 0, 0), 0)
	fill.content_margin_top = 5
	fill.content_margin_bottom = 5
	t.set_stylebox("slider", "HSlider", groove)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	return t
