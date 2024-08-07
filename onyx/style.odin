package onyx

Color_Scheme :: struct {
	background,
	foreground,
	substance,
	accent,
	content: Color,
}

Font_Style :: enum {
	Light,
	Regular,
	Medium,
	Bold,
}

Style :: struct {
	fonts: [Font_Style]int,
	color: Color_Scheme,

	header_text_size,
	button_text_size,
	content_text_size: f32,

	text_input_height,
	button_height: f32,
	
	tooltip_rounding,
	tooltip_padding,
	panel_rounding,
	rounding: f32,
	
	stroke_width: f32,
	title_margin: f32,
	title_padding: f32,
	panel_background_opacity: f32,
}

light_color_scheme :: proc() -> Color_Scheme {
	return Color_Scheme{
		background = {0, 0, 0, 255},
		foreground = {25, 25, 32, 255},
		substance = {65, 65, 75, 255},
		accent = {59, 130, 246, 255},
		content = {255, 255, 255, 255},
	}
}
dark_color_scheme :: proc() -> Color_Scheme {
	return Color_Scheme{
		background = {0, 0, 0, 255},
		foreground = {15, 15, 15, 255},
		substance = {45, 45, 45, 255},
		accent = {59, 130, 246, 255},
		content = {255, 255, 255, 255},
	}
}

set_style_font :: proc(style: Font_Style, path: string) -> bool {
	core.style.fonts[style] = load_font(path) or_return
	return true
}

set_style_rounding :: proc(amount: f32) {
	core.style.rounding = amount
}

set_color_scheme :: proc(scheme: Color_Scheme) {
	core.style.color = scheme
}