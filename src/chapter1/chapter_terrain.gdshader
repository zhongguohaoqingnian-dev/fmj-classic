shader_type canvas_item;
render_mode unshaded;

// TEXTURE is an immutable map of material IDs, not collision or event data.
uniform sampler2D map_data : filter_nearest, repeat_disable;
uniform sampler2D materials : source_color, filter_nearest, repeat_disable;
uniform vec2 map_cells = vec2(1.0);
uniform float tile_pixels = 32.0;
uniform float patch_pixels = 64.0;
uniform float material_count = 1.0;
uniform float grass_id = -1.0;
uniform float dry_grass_id = -1.0;
uniform float edge_pixels = 5.0;
uniform sampler2D valley_depth : source_color, filter_nearest, repeat_disable;
uniform bool valley_enabled = false;
uniform vec4 valley_region = vec4(0.0, 0.0, 640.0, 448.0);
uniform vec2 valley_image_size = vec2(640.0, 448.0);
uniform vec2 camera_native = vec2(0.0);
uniform vec2 viewport_native = vec2(560.0, 360.0);
uniform vec4 tint : source_color = vec4(1.0);

float noise(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
vec4 cell_at(vec2 p) {
	return texture(map_data, (clamp(p, vec2(0.0), map_cells - 1.0) + 0.5) / map_cells);
}
vec4 sample_material(float index, vec2 pixel) {
	vec2 p = mod(floor(pixel), patch_pixels);
	if (index == grass_id || index == dry_grass_id) {
		vec2 patch = floor(pixel / patch_pixels);
		if (noise(patch) > 0.5) p.x = patch_pixels - 1.0 - p.x;
		if (noise(patch + 97.0) > 0.5) p.y = patch_pixels - 1.0 - p.y;
	}
	vec2 uv = vec2((index * patch_pixels + p.x + 0.5) / (patch_pixels * material_count), (p.y + 0.5) / patch_pixels);
	vec4 color = texture(materials, uv);
	if (index == grass_id) color.rgb = mix(color.rgb, vec3(0.26, 0.40, 0.17), 0.26);
	if (index == dry_grass_id) color.rgb = mix(color.rgb, vec3(0.35, 0.37, 0.16), 0.17);
	return color;
}
void fragment() {
	vec2 world_pixel = floor(UV * map_cells * tile_pixels);
	vec2 cell = floor(world_pixel / tile_pixels);
	vec2 within = mod(world_pixel, tile_pixels) + 0.5;
	vec4 center = cell_at(cell);
	float index = floor(center.r * 255.0 + 0.5);
	// Only inspected natural materials may cross a boundary. Floors, props and
	// absent art never acquire a grass fringe or a collision-derived outline.
	if (center.g > 0.5 && edge_pixels > 0.0) {
		vec2 direction = vec2(within.x < tile_pixels * 0.5 ? -1.0 : 1.0, 0.0);
		float distance = min(within.x, tile_pixels - within.x);
		float dy = min(within.y, tile_pixels - within.y);
		if (dy < distance) {
			direction = vec2(0.0, within.y < tile_pixels * 0.5 ? -1.0 : 1.0);
			distance = dy;
		}
		vec4 neighbor = cell_at(cell + direction);
		float other = floor(neighbor.r * 255.0 + 0.5);
		float coverage = 0.5 * (1.0 - smoothstep(0.0, edge_pixels, distance));
		if (neighbor.g > 0.5 && noise(floor(world_pixel / 2.0)) < coverage) {
			index = other;
		}
	}
	vec4 surface = sample_material(index, world_pixel);
	if (valley_enabled && center.b > 0.5) {
		// One continuous distant image spans both sides of the bridge. Integer
		// source pixels follow a small fraction of the foreground camera travel.
		vec2 camera_extent = max(vec2(0.0), map_cells * tile_pixels - viewport_native);
		vec2 distant = world_pixel - camera_native + (valley_region.zw - viewport_native) * 0.5;
		distant += (camera_native - camera_extent * 0.5) * 0.16;
		distant = clamp(floor(distant), vec2(0.0), valley_region.zw - vec2(1.0));
		surface = texture(valley_depth, (valley_region.xy + distant + 0.5) / valley_image_size);
		// A narrow shadow at the original ravine rim seats the foreground ledge.
		float rim = tile_pixels;
		if (cell_at(cell + vec2(-1.0,0.0)).b < 0.5) rim = min(rim,within.x);
		if (cell_at(cell + vec2(1.0,0.0)).b < 0.5) rim = min(rim,tile_pixels-within.x);
		if (cell_at(cell + vec2(0.0,-1.0)).b < 0.5) rim = min(rim,within.y);
		if (cell_at(cell + vec2(0.0,1.0)).b < 0.5) rim = min(rim,tile_pixels-within.y);
		surface.rgb *= mix(0.72,1.0,smoothstep(0.0,10.0,rim));
	}
	COLOR = surface * tint;
}
