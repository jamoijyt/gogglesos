extends Node
## The PC's desktop, live, for the Desktop panel and the big screen.
##
## Runs gogglesxr-desktop-grab (gogglesxr/desktop-grab), which asks KWin for a picture of the
## desktop several times a second and writes it to a file in the runtime folder. This node reads
## each new picture on a thread and keeps `texture` up to date. The helper only runs while
## something wants the picture (want()).

signal changed                            # a new texture object, or a new message

const HELPER := "/usr/libexec/gogglesos/gogglesxr-desktop-grab"
const MESSAGES := {
	"not-authorized": "Plasma didn't allow the desktop view. Log out and back in once after updating Goggles OS, then try again.",
	"no-kwin": "The desktop view needs KDE Plasma on Wayland.",
	"no-session": "The desktop view couldn't reach your desktop session.",
	"format": "This desktop's picture format isn't supported yet.",
	"not-installed": "The desktop view isn't installed. Update Goggles OS (Goggles Update).",
}

var texture: ImageTexture
var message := ""
var screen := "all"
var fps := 15
var max_width := 1920
var _users := {}
var _pid := -1
var _path := ""
var _last_frame := -1
var _reader: Thread
var _wait := 0.0
var _restart_wait := 0.0


func _init() -> void:
	var run := OS.get_environment("XDG_RUNTIME_DIR")
	if run == "" or not DirAccess.dir_exists_absolute(run):
		run = OS.get_user_data_dir()
	_path = run.path_join("gogglesxr-desktop.raw")


## Something (the panel, the big screen) wants the picture, or no longer does.
func want(who: String, on: bool) -> void:
	if on:
		_users[who] = true
	else:
		_users.erase(who)
	if _users.is_empty():
		stop()
	elif _pid < 0 and _restart_wait <= 0.0:
		start()


func running() -> bool:
	return _pid > 0


func set_options(new_screen: String, new_fps: int) -> void:
	if new_screen == screen and new_fps == fps:
		return
	screen = new_screen
	fps = new_fps
	if _pid > 0:
		stop()
		start()


func start() -> void:
	var helper := OS.get_environment("GOGGLESXR_DESKTOP_GRAB")
	if helper == "":
		helper = HELPER
	if not FileAccess.file_exists(helper):
		_set_message(MESSAGES["not-installed"])
		return
	for stale in [_path, _path + ".error"]:
		if FileAccess.file_exists(stale):
			DirAccess.remove_absolute(stale)
	var args := ["--out", _path, "--fps", str(fps), "--max-width", str(max_width), "--screen", screen]
	if OS.get_environment("GOGGLESXR_DESKTOP_TEST") != "":
		args.append("--test-pattern")
	_last_frame = -1
	_pid = OS.create_process(helper, args)
	if _pid <= 0:
		_set_message("Couldn't start the desktop view.")
	elif texture == null:
		_set_message("")


func stop() -> void:
	if _pid > 0:
		OS.kill(_pid)
	_pid = -1


func _set_message(text: String) -> void:
	if text != message:
		message = text
		changed.emit()


func _process(delta: float) -> void:
	_restart_wait = maxf(0.0, _restart_wait - delta)
	if _pid <= 0:
		if not _users.is_empty() and _restart_wait <= 0.0 and message == "":
			start()
		return
	_wait -= delta
	if _wait > 0.0:
		return
	_wait = 0.5 / fps
	if _reader:
		if _reader.is_alive():
			return
		var image: Variant = _reader.wait_to_finish()
		_reader = null
		if image is Image:
			_show(image)
	if FileAccess.file_exists(_path + ".error"):
		var reason := FileAccess.get_file_as_string(_path + ".error").strip_edges()
		var kind := reason.get_slice(":", 0)
		_set_message(MESSAGES.get(kind, "The desktop view stopped: " + reason.get_slice(":", 1).strip_edges()))
	if not OS.is_process_running(_pid):
		_pid = -1
		_restart_wait = 5.0                   # try again in a while, unless it gave a reason
		return
	var file := FileAccess.open(_path, FileAccess.READ)
	if file == null or file.get_length() < 16:
		return
	if file.get_buffer(4).get_string_from_ascii() != "GXDF":
		return
	file.get_32()
	file.get_32()
	var frame := file.get_32()
	file.close()
	if frame != _last_frame:
		_last_frame = frame
		_reader = Thread.new()
		_reader.start(_read.bind(_path))


## Runs on a thread: the newest picture as an Image, or null.
static func _read(path: String) -> Variant:
	var data := FileAccess.get_file_as_bytes(path)
	if data.size() < 16 or data.slice(0, 4).get_string_from_ascii() != "GXDF":
		return null
	var w := data.decode_u32(4)
	var h := data.decode_u32(8)
	if w == 0 or h == 0 or data.size() < 16 + w * h * 4:
		return null
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data.slice(16, 16 + w * h * 4))


func _show(image: Image) -> void:
	var fresh := texture == null or texture.get_size() != Vector2(image.get_size())
	if fresh:
		texture = ImageTexture.create_from_image(image)
	else:
		texture.update(image)
	if fresh or message != "":
		message = ""
		changed.emit()


func _exit_tree() -> void:
	stop()
	if _reader:
		_reader.wait_to_finish()
