extends Node
## The PC's mouse and keyboard, driven from the headset.
##
## Runs gogglesxr-desktop-input (gogglesxr/desktop-grab/desktop_input.c), which creates a
## virtual pointer and keyboard on the PC, and sends it one line per action. Started the first
## time something is pointed at or typed, stopped when nothing needs it.

signal changed                            # message changed (ready, or why it can't work)

const HELPER := "/usr/libexec/gogglesos/gogglesxr-desktop-input"
const MESSAGES := {
	"no-permission": "The headset can't use the PC's mouse yet. Log out and back in once after updating Goggles OS.",
	"no-uinput": "This PC can't create a virtual mouse (no uinput).",
	"not-installed": "Desktop control isn't installed. Update Goggles OS (Goggles Update).",
}

var message := ""                         # "" while working
var helper_ready := false
var lines: Array[String] = []             # what the helper printed (in --print test mode, its events)
var _pipe: FileAccess
var _pid := -1
var _reader: Thread
var _lock := Mutex.new()
var _last_move := Vector2i(-1, -1)
var _held_buttons := {}
var _held_keys := {}


func start() -> bool:
	if _pid > 0:
		return message == ""
	var helper := OS.get_environment("GOGGLESXR_DESKTOP_INPUT")
	if helper == "":
		helper = HELPER
	if not FileAccess.file_exists(helper):
		_set_message(MESSAGES["not-installed"])
		return false
	var args := PackedStringArray()
	if OS.get_environment("GOGGLESXR_DESKTOP_INPUT_PRINT") != "":
		args.append("--print")
	var started := OS.execute_with_pipe(helper, args)   # blocking: the reader thread waits for lines
	if started.is_empty():
		_set_message("Couldn't start desktop control.")
		return false
	_pipe = started.stdio
	_pid = started.pid
	_reader = Thread.new()
	_reader.start(_read_lines.bind(started.stdio))
	_set_message("")
	return true


func stop() -> void:
	release_all()
	if _pipe:
		_pipe.close()                     # the helper lets go of everything and removes its devices
		_pipe = null
	if _pid > 0:
		OS.kill(_pid)
	_pid = -1
	helper_ready = false
	if _reader:
		_reader.wait_to_finish()
		_reader = null


func running() -> bool:
	return _pid > 0


func _read_lines(pipe: FileAccess) -> void:
	while pipe.is_open() and pipe.get_error() == OK:
		var line := pipe.get_line()
		if line == "" and pipe.get_error() != OK:
			break
		_lock.lock()
		lines.append(line)
		if lines.size() > 400:
			lines = lines.slice(-200)
		_lock.unlock()
		if line == "ready":
			call_deferred("_on_ready")
		elif line.begins_with("error:"):
			call_deferred("_on_error", line.substr(6).strip_edges())


func _on_ready() -> void:
	helper_ready = true
	_set_message("")


func _on_error(reason: String) -> void:
	_set_message(MESSAGES.get(reason.get_slice(":", 0), "Desktop control stopped: " + reason))
	_pid = -1


func output() -> Array[String]:
	_lock.lock()
	var copy := lines.duplicate()
	_lock.unlock()
	return copy


func _set_message(text: String) -> void:
	if text != message:
		message = text
		changed.emit()


func _send(line: String) -> void:
	if not start() or _pipe == null:
		return
	_pipe.store_line(line)
	_pipe.flush()


## Put the pointer on a spot of the whole desktop (0..1 across all screens).
func move(at: Vector2) -> void:
	var p := Vector2i(roundi(clampf(at.x, 0, 1) * 65535), roundi(clampf(at.y, 0, 1) * 65535))
	if p == _last_move:
		return
	_last_move = p
	_send("m %d %d" % [p.x, p.y])


## Button 0 left, 1 right, 2 middle.
func button(index: int, down: bool) -> void:
	if down == _held_buttons.get(index, false):
		return
	_held_buttons[index] = down
	_send("b %d %d" % [index, 1 if down else 0])


func wheel(clicks: int, sideways := 0) -> void:
	if clicks != 0 or sideways != 0:
		_send("w %d %d" % [clicks, sideways])


## A Linux key code (linux/input-event-codes.h), down or up.
func key(code: int, down: bool) -> void:
	_held_keys[code] = down
	_send("k %d %d" % [code, 1 if down else 0])


func tap(code: int) -> void:
	key(code, true)
	key(code, false)


func release_all() -> void:
	if _pipe == null:
		return
	for index in _held_buttons:
		if _held_buttons[index]:
			button(index, false)
	for code in _held_keys:
		if _held_keys[code]:
			key(code, false)


func _exit_tree() -> void:
	stop()
