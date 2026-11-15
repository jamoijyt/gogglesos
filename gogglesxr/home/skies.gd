extends RefCounted
## What is outside Goggles Home's glass wall. Built in code, apart from the night grid (the
## picture shared with the dashboard) and your own 360° picture.

const CHOICES := {"grid": "Night grid", "day": "Clear day", "sunset": "Sunset", "space": "Deep space", "custom": "My picture"}
const GRID_IMAGE := "res://environments/goggles-home.jpg"

const SPACE_SHADER := """
shader_type sky;
float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}
void sky() {
	vec3 d = normalize(EYEDIR);
	// stars: one in a few hundred cells of a fine grid on the sky, round and of mixed brightness
	vec3 grid = d * 180.0;
	vec3 cell = floor(grid);
	float pick = hash(cell);
	float star = step(0.9965, pick) * smoothstep(0.5, 0.1, length(fract(grid) - 0.5));
	// a faint band of colour across the sky
	float band = exp(-pow((d.y - 0.25 * sin(d.x * 2.0 + 1.0)) * 3.0, 2.0));
	vec3 deep = mix(vec3(0.004, 0.006, 0.018), vec3(0.03, 0.015, 0.06), band);
	deep += vec3(0.0, 0.03, 0.04) * band * (0.5 + 0.5 * sin(d.z * 5.0));
	COLOR = deep + vec3(0.9, 0.95, 1.0) * star * (0.4 + 0.6 * hash(cell + 7.0));
}
"""


## -> [Sky, ambient light colour]. Falls back to the night grid when a picture can't be read.
static func make(id: String, custom_path := "") -> Array:
	var sky := Sky.new()
	match id:
		"day":
			var m := ProceduralSkyMaterial.new()
			m.sky_top_color = Color(0.16, 0.36, 0.72)
			m.sky_horizon_color = Color(0.62, 0.76, 0.88)
			m.ground_bottom_color = Color(0.1, 0.16, 0.12)
			m.ground_horizon_color = Color(0.56, 0.68, 0.72)
			m.sun_angle_max = 12.0
			sky.sky_material = m
			return [sky, Color(0.72, 0.78, 0.82)]
		"sunset":
			var m := ProceduralSkyMaterial.new()
			m.sky_top_color = Color(0.08, 0.07, 0.25)
			m.sky_horizon_color = Color(0.98, 0.45, 0.2)
			m.sky_curve = 0.09
			m.ground_bottom_color = Color(0.03, 0.02, 0.06)
			m.ground_horizon_color = Color(0.75, 0.3, 0.2)
			sky.sky_material = m
			return [sky, Color(0.75, 0.55, 0.5)]
		"space":
			var m := ShaderMaterial.new()
			m.shader = Shader.new()
			m.shader.code = SPACE_SHADER
			sky.sky_material = m
			return [sky, Color(0.4, 0.45, 0.6)]
	var path := custom_path if id == "custom" else ""
	if path == "" or not FileAccess.file_exists(path):
		path = ProjectSettings.globalize_path(GRID_IMAGE)
	var image := Image.load_from_file(path) if FileAccess.file_exists(path) else null
	if image == null and id == "custom":
		path = ProjectSettings.globalize_path(GRID_IMAGE)
		image = Image.load_from_file(path) if FileAccess.file_exists(path) else null
	if image == null:
		return [null, Color(0.45, 0.62, 0.57)]
	var panorama := PanoramaSkyMaterial.new()
	panorama.panorama = ImageTexture.create_from_image(image)
	sky.sky_material = panorama
	return [sky, Color(0.45, 0.62, 0.57) if id != "custom" else Color(0.6, 0.62, 0.62)]
