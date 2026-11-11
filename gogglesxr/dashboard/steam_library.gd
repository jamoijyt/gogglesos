extends RefCounted
## Reads the installed games straight from Steam's own files. No Steam API key needed.

const STEAM_ROOTS := [".steam/debian-installation", ".steam/steam", ".local/share/Steam"]
## Runtimes and tools Steam lists next to games
const NOT_GAMES := ["Proton", "Steam Linux Runtime", "Steamworks Common", "SteamVR", "Steam Controller"]


static func installed_games() -> Array[Dictionary]:
	var home := OS.get_environment("HOME")
	var folders: Array[String] = []
	for root in STEAM_ROOTS:
		var steamapps := home.path_join(root).path_join("steamapps")
		if not DirAccess.dir_exists_absolute(steamapps):
			continue
		_add(folders, steamapps)
		var vdf := FileAccess.open(steamapps.path_join("libraryfolders.vdf"), FileAccess.READ)
		if vdf:
			var re := RegEx.new()
			re.compile("\"path\"\\s+\"([^\"]+)\"")
			for m in re.search_all(vdf.get_as_text()):
				_add(folders, m.get_string(1).path_join("steamapps"))
	var games: Array[Dictionary] = []
	var seen := {}
	var field := RegEx.new()
	field.compile("\"(appid|name)\"\\s+\"([^\"]*)\"")
	for folder in folders:
		var dir := DirAccess.open(folder)
		if dir == null:
			continue
		for file in dir.get_files():
			if not (file.begins_with("appmanifest_") and file.ends_with(".acf")):
				continue
			var f := FileAccess.open(folder.path_join(file), FileAccess.READ)
			if f == null:
				continue
			var info := {}
			for m in field.search_all(f.get_as_text()):
				if not info.has(m.get_string(1)):
					info[m.get_string(1)] = m.get_string(2)
			var id: String = info.get("appid", "")
			var title: String = info.get("name", "")
			if id == "" or title == "" or seen.has(id) or _is_tool(title):
				continue
			seen[id] = true
			games.append({"id": id, "name": title})
	games.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
	return games


## The list prepared by the GogglesXR app (gogglesxr dashboard writes it): VR games only,
## hidden ones left out, favourites first, with cover art. Empty if it isn't there.
static func prepared_games() -> Array[Dictionary]:
	var cache := OS.get_environment("XDG_CACHE_HOME")
	if cache == "":
		cache = OS.get_environment("HOME").path_join(".cache")
	var file := FileAccess.open(cache.path_join("gogglesxr/library.json"), FileAccess.READ)
	var games: Array[Dictionary] = []
	if file == null:
		return games
	var data: Variant = JSON.parse_string(file.get_as_text())
	if not (data is Dictionary and data.get("games") is Array):
		return games
	for item in data.games:
		if item is Dictionary and item.has("name") and item.has("launch"):
			games.append(item)
	return games


## Games for the Library panel: the prepared list, or everything Steam has installed.
static func games() -> Array[Dictionary]:
	var prepared := prepared_games()
	if not prepared.is_empty():
		return prepared
	var games: Array[Dictionary] = []
	for game in installed_games():
		games.append({"id": game.id, "name": game.name, "launch": "steam://rungameid/" + game.id, "art": "", "favourite": false})
	return games


## Everything installed, whatever the Library panel shows (to name a running game).
static func all_games() -> Array[Dictionary]:
	var games: Array[Dictionary] = []
	for game in installed_games():
		games.append({"id": game.id, "name": game.name, "launch": "steam://rungameid/" + game.id, "art": ""})
	return games


static func launch(url: String) -> bool:
	return url.begins_with("steam://") and OS.create_process("steam", [url]) > 0


## Cover art as a texture, or null. `size` is the card's picture size in pixels.
static func cover(path: String, size: Vector2i) -> Texture2D:
	if path == "" or not FileAccess.file_exists(path):
		return null
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return null
	# Fill the card: scale to cover it, then cut off what sticks out
	var scale := maxf(float(size.x) / image.get_width(), float(size.y) / image.get_height())
	image.resize(maxi(size.x, int(ceil(image.get_width() * scale))), maxi(size.y, int(ceil(image.get_height() * scale))), Image.INTERPOLATE_LANCZOS)
	var cut := Image.create_empty(size.x, size.y, false, image.get_format())
	cut.blit_rect(image, Rect2i((image.get_width() - size.x) / 2, (image.get_height() - size.y) / 2, size.x, size.y), Vector2i.ZERO)
	return ImageTexture.create_from_image(cut)


static func _add(list: Array[String], path: String) -> void:
	# The same library is often reachable through several links
	var real := path.simplify_path()
	if DirAccess.dir_exists_absolute(real) and not list.has(real):
		list.append(real)


static func _is_tool(title: String) -> bool:
	for prefix in NOT_GAMES:
		if title.begins_with(prefix):
			return true
	return false
