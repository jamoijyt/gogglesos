extends Control
## The virtual keyboard: types on the PC from the headset (through desktop_input.gd).
##
## Keys are the PC's physical keys (Linux key codes), labelled for a US layout; the PC turns
## them into letters with its own keyboard layout. Shift, Ctrl, Alt and Super stay pressed for
## the next key, like on a phone; press them twice to hold them until pressed again.

signal key(code: int, down: bool)
signal hide_requested

const SIZE := Vector2(1280, 430)
const ACCENT := Color("3ddc84")
const INK := Color("e6f3ee")
const MUTED := Color("9fbfb4")

# [label, shifted label, key code, width in key units]
const ROWS := [
	[["Esc", "Esc", 1, 1.2], ["1", "!", 2, 1], ["2", "@", 3, 1], ["3", "#", 4, 1], ["4", "$", 5, 1], ["5", "%", 6, 1],
	 ["6", "^", 7, 1], ["7", "&", 8, 1], ["8", "*", 9, 1], ["9", "(", 10, 1], ["0", ")", 11, 1], ["-", "_", 12, 1],
	 ["=", "+", 13, 1], ["⌫", "⌫", 14, 1.8]],
	[["Tab", "Tab", 15, 1.5], ["q", "Q", 16, 1], ["w", "W", 17, 1], ["e", "E", 18, 1], ["r", "R", 19, 1], ["t", "T", 20, 1],
	 ["y", "Y", 21, 1], ["u", "U", 22, 1], ["i", "I", 23, 1], ["o", "O", 24, 1], ["p", "P", 25, 1], ["[", "{", 26, 1],
	 ["]", "}", 27, 1], ["\\", "|", 43, 1.5]],
	[["Caps", "Caps", 58, 1.8], ["a", "A", 30, 1], ["s", "S", 31, 1], ["d", "D", 32, 1], ["f", "F", 33, 1], ["g", "G", 34, 1],
	 ["h", "H", 35, 1], ["j", "J", 36, 1], ["k", "K", 37, 1], ["l", "L", 38, 1], [";", ":", 39, 1], ["'", "\"", 40, 1],
	 ["Enter", "Enter", 28, 2.2]],
	[["Shift", "Shift", 42, 2.3], ["z", "Z", 44, 1], ["x", "X", 45, 1], ["c", "C", 46, 1], ["v", "V", 47, 1], ["b", "B", 48, 1],
	 ["n", "N", 49, 1], ["m", "M", 50, 1], [",", "<", 51, 1], [".", ">", 52, 1], ["/", "?", 53, 1], ["↑", "↑", 103, 1],
	 ["Del", "Del", 111, 1.7]],
	[["Ctrl", "Ctrl", 29, 1.5], ["Super", "Super", 125, 1.4], ["Alt", "Alt", 56, 1.4], ["Space", "Space", 57, 6.1],
	 ["←", "←", 105, 1], ["↓", "↓", 108, 1], ["→", "→", 106, 1], ["Hide", "Hide", -1, 1.6]],
]
const MODIFIERS := [42, 29, 56, 125]      # Shift, Ctrl, Alt, Super

var modifiers := {}                       # code -> "" (off), "once" (next key) or "held"
var _buttons := {}                        # code -> [Button, label, shifted label]


func _ready() -> void:
	size = SIZE
	custom_minimum_size = SIZE
	var back := Panel.new()
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.1, 0.09, 0.94)
	style.set_corner_radius_all(26)
	style.border_color = Color(ACCENT, 0.35)
	style.set_border_width_all(2)
	back.add_theme_stylebox_override("panel", style)
	add_child(back)
	var rows := VBoxContainer.new()
	rows.position = Vector2(20, 20)
	rows.size = SIZE - Vector2(40, 40)
	rows.add_theme_constant_override("separation", 10)
	add_child(rows)
	var unit := (SIZE.x - 40 - 13 * 8) / 15.0
	for row_keys in ROWS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_vertical = Control.SIZE_EXPAND_FILL
		rows.add_child(row)
		for k in row_keys:
			row.add_child(_make_key(k[0], k[1], int(k[2]), float(k[3]) * unit))
	_refresh()


func _key_style(colour: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = colour
	s.set_corner_radius_all(12)
	s.border_color = border
	s.set_border_width_all(1)
	s.anti_aliasing = true
	return s


func _make_key(text: String, shifted: String, code: int, width: float) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(width, 0)
	b.size_flags_vertical = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 30 if text.length() == 1 else 22)
	for state in ["font_color", "font_hover_color", "font_pressed_color"]:
		b.add_theme_color_override(state, INK)
	b.add_theme_stylebox_override("normal", _key_style(Color(1, 1, 1, 0.07), Color(1, 1, 1, 0.1)))
	b.add_theme_stylebox_override("hover", _key_style(Color(ACCENT, 0.18), ACCENT))
	b.add_theme_stylebox_override("pressed", _key_style(Color(ACCENT, 0.45), ACCENT))
	if code == -1:
		b.pressed.connect(func(): hide_requested.emit())
	elif code in MODIFIERS:
		b.pressed.connect(_toggle_modifier.bind(code))
	else:
		b.button_down.connect(_press.bind(code))
		b.button_up.connect(_release.bind(code))
	_buttons[code] = [b, text, shifted]
	return b


func _toggle_modifier(code: int) -> void:
	var now: String = modifiers.get(code, "")
	modifiers[code] = "once" if now == "" else ("held" if now == "once" else "")
	_refresh()


## A normal key: the latched modifiers go down with it and come back up after it.
func _press(code: int) -> void:
	for m in MODIFIERS:
		if modifiers.get(m, "") != "":
			key.emit(m, true)
	key.emit(code, true)


func _release(code: int) -> void:
	key.emit(code, false)
	for m in MODIFIERS:
		if modifiers.get(m, "") != "":
			key.emit(m, false)
		if modifiers.get(m, "") == "once":
			modifiers[m] = ""
	_refresh()


func _refresh() -> void:
	var shift: bool = modifiers.get(42, "") != ""
	for code in _buttons:
		var entry: Array = _buttons[code]
		var b: Button = entry[0]
		b.text = entry[2] if shift else entry[1]
		if code in MODIFIERS:
			var state: String = modifiers.get(code, "")
			var fill := Color(ACCENT, 0.55) if state == "held" else (Color(ACCENT, 0.28) if state == "once" else Color(1, 1, 1, 0.07))
			b.add_theme_stylebox_override("normal", _key_style(fill, ACCENT if state != "" else Color(1, 1, 1, 0.1)))


## Let go of every latched modifier (when the keyboard closes).
func clear() -> void:
	modifiers.clear()
	_refresh()
