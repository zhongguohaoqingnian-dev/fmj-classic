shader_type canvas_item;
uniform sampler2D visibility_mask : filter_nearest, repeat_disable;
void fragment() {
	vec4 art = texture(TEXTURE, UV);
	float visible = texture(visibility_mask, UV).r;
	COLOR = mix(vec4(0.043, 0.106, 0.118, 1.0), art, visible);
}
