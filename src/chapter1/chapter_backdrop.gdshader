shader_type canvas_item;
render_mode unshaded;
uniform vec2 viewport_pixels = vec2(1120.0, 720.0);
uniform vec4 map_rect = vec4(176.0, 120.0, 768.0, 480.0);
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float cloud(vec2 p) {
	vec2 a = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(a), hash(a + vec2(1.0, 0.0)), f.x), mix(hash(a + vec2(0.0, 1.0)), hash(a + vec2(1.0)), f.x), f.y);
}
void fragment() {
	vec2 pixel = floor(UV * viewport_pixels / 2.0) * 2.0;
	vec2 uv = pixel / viewport_pixels;
	float light = max(0.0, 1.0 - length((uv - vec2(0.24, 0.13)) * vec2(0.7, 1.0)));
	float canopy = cloud(pixel / 170.0) * 0.6 + cloud(pixel / 74.0) * 0.4;
	vec3 color = mix(vec3(0.030, 0.077, 0.092), vec3(0.102, 0.197, 0.207), light * 0.72 + canopy * 0.2);
	vec2 delta = max(max(map_rect.xy - pixel, pixel - map_rect.xy - map_rect.zw), vec2(0.0));
	float distance = length(delta);
	// A diffuse frame shadow distinguishes the finite source map from the
	// noninteractive teal surround; it adds no outside terrain or hidden hints.
	float shadow = exp(-distance / 21.0) * 0.42;
	color *= 1.0 - shadow;
	COLOR = vec4(color, 1.0);
}
