extends Node
## The dashboard's interface sounds: short, quiet clicks from Kenney's CC0 UI pack (sounds/README.md).
##
## play("click") from anywhere that has this node. Settings > Appearance > Sounds turns them
## down or off (setting "ui_sounds": "on", "quiet" or "off").

const DIR := "res://sounds"
# How loud each one is, before the Sounds setting: the laser crossing buttons must stay in the background
const LEVEL_DB := {"hover": -21.0, "click": -11.0, "toggle": -13.0, "swipe": -14.0, "open": -9.0, "key": -12.0, "grab": -13.0}
const GAP_MS := {"hover": 60, "key": 25}  # don't stack the same sound faster than this
const VOICES := 6

var mode := "on"                          # "on", "quiet" (10 dB down) or "off"
var played: Array[String] = []            # what was played, newest last (for the self-test)
var _streams := {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _last_ms := {}


func _ready() -> void:
	for name in LEVEL_DB:
		var path := ProjectSettings.globalize_path(DIR.path_join(name + ".wav"))
		var stream: AudioStreamWAV = AudioStreamWAV.load_from_file(path) if FileAccess.file_exists(path) else null
		if stream:
			_streams[name] = stream
	for i in VOICES:
		var player := AudioStreamPlayer.new()
		add_child(player)
		_players.append(player)


func set_mode(value: String) -> void:
	mode = value if value in ["on", "quiet", "off"] else "on"


## `pitch` above 1 sounds brighter (on, open), below 1 duller (off, close).
func play(name: String, pitch := 1.0) -> void:
	if mode == "off" or not _streams.has(name):
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_ms.get(name, -100000)) < int(GAP_MS.get(name, 30)):
		return
	_last_ms[name] = now
	var player := _players[_next]
	_next = (_next + 1) % _players.size()
	player.stream = _streams[name]
	player.volume_db = LEVEL_DB[name] - (10.0 if mode == "quiet" else 0.0)
	player.pitch_scale = pitch * randf_range(0.97, 1.03)     # never quite the same twice
	player.play()
	played.append(name)
	if played.size() > 50:
		played = played.slice(-25)


func loaded() -> int:
	return _streams.size()
