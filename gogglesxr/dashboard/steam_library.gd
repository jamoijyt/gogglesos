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


static func launch(app_id: String) -> bool:
	return OS.create_process("steam", ["steam://rungameid/" + app_id]) > 0


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
