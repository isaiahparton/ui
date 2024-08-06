package onyx

/*
	make_text_iterator() 	- Prepare a `Text_Iterator` for iteration
	make_text_job() 			- Given a `Text_Info` as an input, it will create a `Text_Job` to be rendered or processed
*/

import "base:runtime"

import "core:os"
import "core:fmt"
import "core:c/libc"
import "core:math"
import "core:math/bits"
import "core:math/linalg"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import sapp "extra:sokol-odin/sokol/app"

import ttf "vendor:stb/truetype"

FMT_BUFFER_COUNT 		:: 128
FMT_BUFFER_SIZE 		:: 1024
TEXT_BREAK 					:: "..."

Horizontal_Text_Align :: enum {
	Left,
	Middle,
	Right,
}

Vertical_Text_Align :: enum {
	Top,
	Middle,
	Baseline,
	Bottom,
}

Text_Wrap :: enum {
	None,
	Normal,
	Word,
}

Text_Info :: struct {
	using options: Text_Options,
	text: string,
}

Text_Options :: struct {
	font: int,							// Font index
	spacing,							// Glyph spacing
	size: f32,							// Font size
	width: Maybe(f32),					// Maximum line width
	max_lines: Maybe(int),				// Maximum number of lines
	wrap: Text_Wrap,					// Wrapping type
	align_h: Horizontal_Text_Align,		// Alignment
	align_v: Vertical_Text_Align,
	hidden: bool,						// Every glyph appears as a bullet
}

Interactive_Text_Result :: struct {
	// If a selection or a change was made
	changed: bool,
	// If the text is hovered
	hovered: bool,
	// Text and selection bounds
	bounds,
	selection_bounds: [2][2]f32,
}

Text_Job_Glyph :: struct {
	origin: [2]f32,
	glyph: ^Glyph,
}

Text_Job :: struct {
	glyphs: [dynamic]Text_Job_Glyph,
}

Text_Iterator :: struct {
	font: ^Font,
	size: ^Font_Size,
	glyph: ^Glyph,
	line_limit: Maybe(f32),
	line_size: [2]f32,
	new_line: bool, 					// Set if `codepoint` is the first rune on a new line
	offset: [2]f32,

	last_codepoint,
	codepoint: rune,

	next_word,
	index,
	next_index: int,
}

Font_Size :: struct {
	ascent,
	descent,
	line_gap,
	scale: f32,
	glyphs: map[rune]Glyph,
	break_size: f32,
}

destroy_font_size :: proc(using self: ^Font_Size) {
	delete(glyphs)
}

Font :: struct {
	name,
	path: string,
	data: ttf.fontinfo,
	sizes: map[f32]Font_Size,
}

destroy_font :: proc(using self: ^Font) {
	for _, &size in sizes {
		destroy_font_size(&size)
	}
	delete(name)
	delete(path)
}

Glyph :: struct {
	texture: Texture,
	offset: [2]f32,
	advance: f32,
}

@private fmt_buffers: [FMT_BUFFER_COUNT][FMT_BUFFER_SIZE]u8
@private fmt_buffer_index: u8

get_tmp_builder :: proc() -> strings.Builder {
	buf := get_tmp_buffer()
	return strings.builder_from_bytes(buf)
}

get_tmp_buffer :: proc() -> []u8 {
	defer	fmt_buffer_index = (fmt_buffer_index + 1) % FMT_BUFFER_COUNT
	return fmt_buffers[fmt_buffer_index][:]
}

tmp_print :: proc(args: ..any) -> string {
	str := fmt.bprint(fmt_buffers[fmt_buffer_index][:], ..args)
	fmt_buffer_index = (fmt_buffer_index + 1) % FMT_BUFFER_COUNT
	return str
}

tmp_printf :: proc(text: string, args: ..any) -> string {
	str := fmt.bprintf(fmt_buffers[fmt_buffer_index][:], text, ..args)
	fmt_buffer_index = (fmt_buffer_index + 1) % FMT_BUFFER_COUNT
	return str
}

tmp_join :: proc(args: []string, sep := " ") -> string {
	size := 0
	buffer := &fmt_buffers[fmt_buffer_index]
	for arg, index in args {
		copy(buffer[size:size + len(arg)], arg[:])
		size += len(arg)
		if index < len(args) - 1 {
			copy(buffer[size:size + len(sep)], sep[:])
			size += len(sep)
		}
	}
	str := string(buffer[:size])
	fmt_buffer_index = (fmt_buffer_index + 1) % FMT_BUFFER_COUNT
	return str
}

trim_zeroes :: proc(text: string) -> string {
	text := text
	for i := len(text) - 1; i >= 0; i -= 1 {
		if text[i] != '0' {
			if text[i] == '.' {
				text = text[:i]
			}
			break
		} else {
			text = text[:i]
		}
	}
	return text
}

tmp_print_bit_set :: proc(set: $S/bit_set[$E;$U], sep := " ") -> string {
	size := 0
	buffer := &fmt_buffers[fmt_buffer_index]
	count := 0
	max := card(set)
	for member in E {
		if member not_in set {
			continue
		}
		name := fprint(member)
		copy(buffer[size:size + len(name)], name[:])
		size += len(name)
		if count < max - 1 {
			copy(buffer[size:size + len(sep)], sep[:])
			size += len(sep)
		}
		count += 1
	}
	str := string(buffer[:size])
	fmt_buffer_index = (fmt_buffer_index + 1) % FMT_BUFFER_COUNT
	return str
}

make_text_iterator :: proc(info: Text_Info) -> (it: Text_Iterator, ok: bool) {
	if info.size <= 0 {
		return
	}
	it.font = &core.fonts[info.font].?
	it.size, ok = get_font_size(it.font, info.size)
	it.line_limit = info.width
	it.line_size.y = it.size.ascent - it.size.descent + it.size.line_gap
	return
}

update_text_iterator_offset :: proc(it: ^Text_Iterator, info: Text_Info) {
	it.offset.x = 0
	#partial switch info.align_h {
		case .Middle: it.offset.x -= math.floor(measure_next_line(info, it^) / 2)
		case .Right: it.offset.x -= measure_next_line(info, it^)
	}
}

iterate_text_codepoint :: proc(it: ^Text_Iterator, info: Text_Info) -> bool {
	it.last_codepoint = it.codepoint
	if it.next_index >= len(info.text) {
		return false
	}
	// Update index
	it.index = it.next_index
	// Decode next codepoint
	bytes: int
	it.codepoint, bytes = utf8.decode_rune(info.text[it.index:])
	// Update next index
	it.next_index += bytes
	// Get current glyph data
	if it.codepoint != '\n' {
		if glyph, ok := __get_glyph(it.font, it.size, '•' if info.hidden else it.codepoint); ok {
			it.glyph = glyph
		}
	} else {
		it.glyph = nil
	}
	return true
}

iterate_text :: proc(it: ^Text_Iterator, info: Text_Info) -> (ok: bool) {
	// Update horizontal offset with last glyph
	if it.glyph != nil {
		it.offset.x += it.glyph.advance + info.spacing
	}
	/*
		Pre-paint
			Decode the next codepoint -> Update glyph data -> New line if needed
	*/
	ok = iterate_text_codepoint(it, info)
	// Space needed to fit this glyph/word
	space: f32 = it.glyph.advance if it.glyph != nil else 0
	if !ok {
		// We might need to use the end index
		it.index = it.next_index
		it.glyph = nil
		it.codepoint = 0
	} else {
		// Get the space for the next word if needed
		if (info.wrap == .Word) && (it.next_index >= it.next_word) && (it.codepoint != ' ') {
			for i := it.next_word; true; /**/ {
				c, b := utf8.decode_rune(info.text[i:])
				if c != '\n' {
					if g, ok := __get_glyph(it.font, it.size, it.codepoint); ok {
						space += g.advance
					}
				}
				if c == ' ' || i > len(info.text) - 1 {
					it.next_word = i + b
					break
				}
				i += b
			}
		}
	}
	// Reset new line state
	it.new_line = false
	if it.codepoint == '\t' {
		it.line_size.x += it.glyph.advance
	}
	// If the last rune was '\n' then this is a new line
	if (it.last_codepoint == '\n') {
		it.new_line = true
	} else {
		// Or if this rune would exceede the limit
		if ( it.line_limit != nil && it.line_size.x + space >= it.line_limit.? ) {
			if info.wrap == .None {
				it.index = it.next_index
				it.offset.y += it.size.ascent - it.size.descent
				ok = false
			} else {
				it.new_line = true
			}
		}
	}
	// Update vertical offset if there's a new line or if reached end
	if it.new_line {
		it.line_size.x = 0
		it.offset.y += it.size.ascent - it.size.descent + it.size.line_gap
	} else if it.glyph != nil {
		it.line_size.x += it.glyph.advance + info.spacing
	}
	return
}

measure_next_line :: proc(info: Text_Info, it: Text_Iterator) -> f32 {
	it := it
	for iterate_text(&it, info) {
		if it.new_line {
			break
		}
	}
	return it.line_size.x
}

measure_next_word :: proc(info: Text_Info, it: Text_Iterator) -> (size: f32, end: int) {
	it := it
	for iterate_text_codepoint(&it, info) {
		if it.glyph != nil {
			size += it.glyph.advance + info.spacing
		}
		if it.codepoint == ' ' {
			break
		}
	}
	end = it.index
	return
}

measure_text :: proc(info: Text_Info) -> [2]f32 {
	size: [2]f32
	if it, ok := make_text_iterator(info); ok {
		for iterate_text(&it, info) {
			size.x = max(size.x, it.line_size.x)
			if it.new_line {
				size.y += it.size.ascent - it.size.descent + it.size.line_gap
			}
		}
		size.y += it.size.ascent - it.size.descent
	}
	return size
}

load_font :: proc(file_path: string) -> (handle: int, success: bool) {
	font: Font
	if file_data, ok := os.read_entire_file(file_path); ok {
		if ttf.InitFont(&font.data, raw_data(file_data), 0) {
			for i in 0..<MAX_FONTS {
				if core.fonts[i] == nil {
					core.fonts[i] = font
					handle = int(i)
					success = true
					break
				}
			}
		} else {
			fmt.printf("[ui] Failed to initialize font '%s'\n", file_path)
		}
	} else {
		fmt.printf("[ui] Failed to load font '%s'\n", file_path)
	}
	return
}

unload_font :: proc(handle: int) {
	if font, ok := &core.fonts[handle].?; ok {
		destroy_font(font)
		core.fonts[handle] = nil
	}
}

get_font_size :: proc(font: ^Font, size: f32) -> (data: ^Font_Size, ok: bool) {
	size := math.round(size)
	data, ok = &font.sizes[size]
	if !ok {
		data = map_insert(&font.sizes, size, Font_Size{})
		// Compute glyph scale
		data.scale = ttf.ScaleForPixelHeight(&font.data, f32(size))
		// Compute vertical metrics
		ascent, descent, line_gap: i32
		ttf.GetFontVMetrics(&font.data, &ascent, &descent, &line_gap)
		data.ascent = f32(f32(ascent) * data.scale)
		data.descent = f32(f32(descent) * data.scale)
		data.line_gap = f32(f32(line_gap) * data.scale)

		ok = true
	}
	return
}

// First creates the glyph if it doesn't exist, then returns its data
__get_glyph :: proc(font: ^Font, size: ^Font_Size, codepoint: rune) -> (data: ^Glyph, ok: bool) {
	// Try fetching from map
	data, ok = &size.glyphs[codepoint]
	// If the glyph doesn't exist, we create and render it
	if !ok {
		// Get codepoint index
		index := ttf.FindGlyphIndex(&font.data, codepoint)
		// Get metrics
		advance, left_side_bearing: i32
		ttf.GetGlyphHMetrics(&font.data, index, &advance, &left_side_bearing)
		// Generate bitmap
		image_width, image_height, glyph_offset_x, glyph_offset_y: libc.int
		image_data := ttf.GetGlyphBitmap(
			&font.data, 
			size.scale, 
			size.scale, 
			index,
			&image_width,
			&image_height,
			&glyph_offset_x,
			&glyph_offset_y,
		)
		// Set glyph data
		data = map_insert(&size.glyphs, codepoint, Glyph({
			texture = load_texture_from_memory(image_data, int(image_width), int(image_height), 1).? or_return,
			offset = {f32(glyph_offset_x), f32(glyph_offset_y) + size.ascent},
			advance = f32((f32(advance) - f32(left_side_bearing)) * size.scale),
		}))
		ok = true
	}
	return
}

draw_text :: proc(origin: [2]f32, info: Text_Info, color: Color) -> [2]f32 {
	size: [2]f32 
	origin := origin
	if info.align_v != .Top {
		size = measure_text(info)
		#partial switch info.align_v {
			case .Middle: origin.y -= size.y / 2
			case .Bottom: origin.y -= size.y
		}
	}
	origin = linalg.floor(origin)
	if it, ok := make_text_iterator(info); ok {
		update_text_iterator_offset(&it, info)
		for iterate_text(&it, info) {
			// Reset offset if new line
			if it.new_line {
				update_text_iterator_offset(&it, info)
			}
			// Paint the glyph
			if it.codepoint != '\n' && it.codepoint != ' ' && it.glyph != nil {
				dst: Box = {
					lo = origin + it.offset + it.glyph.offset,
				}
				dst.hi = dst.lo + (it.glyph.texture.source.hi - it.glyph.texture.source.lo)
				draw_texture(it.glyph.texture, dst, color)
			}
			// Update size
			if it.new_line {
				size.x = max(size.x, it.line_size.x)
				size.y += it.line_size.y
			}
		}
		size.y += it.line_size.y
	}
	return size 
}

draw_aligned_rune :: proc(
	font: int, 
	size: f32, 
	icon: rune, 
	origin: [2]f32, 
	color: Color, 
	align_h: Horizontal_Text_Align, 
	align_v: Vertical_Text_Align,
) -> [2]f32 {
	font := &core.fonts[font].?
	font_size, _ := get_font_size(font, size)
	glyph, _ := __get_glyph(font, font_size, rune(icon))
	icon_size := glyph.texture.source.hi - glyph.texture.source.lo

	box: Box
	switch align_h {
		case .Right: 
		box.lo.x = origin.x - icon_size.x
		box.hi.x = origin.x 
		case .Middle: 
		box.lo.x = origin.x - math.floor(icon_size.x / 2) 
		box.hi.x = origin.x + math.floor(icon_size.x / 2)
		case .Left: 
		box.lo.x = origin.x 
		box.hi.x = origin.x + icon_size.x 
	}
	switch align_v {
		case .Bottom, .Baseline: 
		box.lo.y = origin.y - icon_size.y
		box.hi.y = origin.y 
		case .Middle: 
		box.lo.y = origin.y - math.floor(icon_size.y / 2) 
		box.hi.y = origin.y + math.floor(icon_size.y / 2)
		case .Top: 
		box.lo.y = origin.y 
		box.hi.y = origin.y + icon_size.y 
	}
	draw_texture(glyph.texture, box, color)
	return icon_size
}

draw_rune_aligned_clipped :: proc(font: int, size: f32, icon: rune, origin: [2]f32, color: Color, align: [2]Alignment, clip: Box) -> [2]f32 {
	font := &core.fonts[font].?
	font_size, _ := get_font_size(font, size)
	glyph, _ := __get_glyph(font, font_size, rune(icon))
	icon_size := glyph.texture.source.hi - glyph.texture.source.lo

	box: Box
	switch align.x {
		case .Far: 
		box.lo.x = origin.x - icon_size.x
		box.hi.x = origin.x 
		case .Middle: 
		box.lo.x = origin.x - icon_size.x / 2 
		box.hi.x = origin.x + icon_size.x / 2
		case .Near: 
		box.lo.x = origin.x 
		box.hi.x = origin.x + icon_size.x 
	}
	switch align.y {
		case .Far: 
		box.lo.y = origin.y - icon_size.y
		box.hi.y = origin.y 
		case .Middle: 
		box.lo.y = origin.y - icon_size.y / 2 
		box.hi.y = origin.y + icon_size.y / 2
		case .Near: 
		box.lo.y = origin.y 
		box.hi.y = origin.y + icon_size.y 
	}
	draw_texture(glyph.texture, box, color)
	return icon_size
}

// Draw interactive text
/*
draw_interactive_text :: proc(result: Generic_Widget_Result, s: ^edit.State, origin: [2]f32, info: Text_Info, color: Color) -> Interactive_Text_Result {
	widget := result.self.?
	using result: Interactive_Text_Result
	// Initial measurement
	size := measure_text(info)
	origin := origin
	// Layer to paint on
	surface := __get_draw_surface()
	// Apply baseline if needed
	#partial switch info.align_v {
		case .Middle: origin.y -= size.y / 2 
		case .Bottom: origin.y -= size.y
	}
	// Hovered index
	hover_index: int
	// Paint the text
	if it, ok := make_text_iterator(info); ok {
		// If we've reached the end
		at_end := false
		// Determine hovered line
		line_height := it.size.ascent - it.size.descent + it.size.line_gap
		line_count := int(math.floor(size.y / line_height))
		hovered_line := clamp(int((core.mouse_pos.y - origin.y) / line_height), 0, line_count)
		// Current line and column
		line, column: int
		// Keep track of smallest distance to mouse
		min_dist: f32 = math.F32_MAX
		// Get line offset
		update_text_iterator_offset(&it, info)
		// Top left of this line
		line_origin := origin + it.offset
		// Horizontal bounds of the selection on the current line
		line_box_bounds: [2]f32 = {math.F32_MAX, 0}
		// Set bounds
		bounds.lo = line_origin
		bounds.hi = bounds.lo

		s.line_start = -1

		// Start iteration
		for {
			// Iterate the iterator
			if !iterate_text(&it, info) {
				at_end = true
			}
			// Get hovered state
			if it.new_line {
				// Allows for highlighting the last glyph in a line
				if hovered_line == line {
					dist1 := math.abs((origin.x + it.offset.x) - core.mouse_pos.x)
					if dist1 < min_dist {
						min_dist = dist1
						hover_index = it.index
					}
				}
				// Check if the last line was hovered
				line_box: Box = {line_origin, line_origin + it.line_size}
				if point_in_box(core.mouse_pos, line_box) {
					hovered = true
				}
				update_text_iterator_offset(&it, info)
				if line == hovered_line {
					s.line_end = it.index
				}
				line += 1
				column = 0
				line_origin = origin + it.offset
			}
			// Update hovered index
			if hovered_line == line {
				if !unicode.is_white_space(it.codepoint) {
					if s.line_start == -1 {
						s.line_start = it.index
					}
				}
				// Left side of glyph
				dist1 := math.abs((origin.x + it.offset.x) - core.mouse_pos.x)
				if dist1 < min_dist {
					min_dist = dist1
					hover_index = it.index
				}
				if it.glyph != nil && (it.new_line || it.next_index >= len(info.text)) {
					// Right side of glyph
					dist2 := math.abs((origin.x + it.offset.x + it.glyph.advance) - core.mouse_pos.x)
					if dist2 < min_dist {
						min_dist = dist2
						hover_index = it.next_index
					}
				}
			}
			// Get the glyph point
			point: [2]f32 = origin + it.offset
			glyph_color := color
			// Get selection info
			if .Focused in (widget.last_state) {
				lo, hi := min(s.selection[0], s.selection[1]), max(s.selection[0], s.selection[1])
				if hi == lo {
					if lo == it.index {
						line_box_bounds = {
							point.x,
							point.x,
						}
						surface.z = 0.1
						draw_box_fill({{point.x - 1, point.y - 2}, {point.x + 1, point.y + it.size.ascent - it.size.descent + 2}}, core.style.color.accent)
						surface.z = 0
					}
				} else if it.index >= lo && hi > it.index {
					glyph_color = core.style.color.background
					line_box_bounds = {
						min(line_box_bounds[0], point.x),
						max(line_box_bounds[1], point.x),
					}
					if it.glyph != nil {
						draw_box_fill({{point.x - 1, point.y - 2}, {point.x + it.glyph.advance + 1, point.y + it.size.ascent - it.size.descent + 2}}, core.style.color.accent)
					}
				}
			}
			// Paint the glyph
			if it.glyph != nil {
				// Paint the glyph
				dst: Box = {low = point + it.glyph.offset}
				dst.hi = dst.lo + (it.glyph.src.hi - it.glyph.src.lo)
				bounds.hi = linalg.max(bounds.hi, dst.hi)
				surface.z = 0.01
				draw_texture(it.glyph.src, dst, glyph_color)
				surface.z = 0
			}
			// Paint this line's selection
			if (.Focused in widget.last_state) && (it.index >= len(info.text) || info.text[it.index] == '\n') {
				// Draw it if the selection is valid
				if line_box_bounds[1] >= line_box_bounds[0] {
					box: Box = {
						{line_box_bounds[0] - 1, line_origin.y},
						{line_box_bounds[1] + 1, line_origin.y + it.line_size.y},
					}
					selection_bounds = {
						linalg.min(selection_bounds.lo, box.lo),
						linalg.max(selection_bounds.hi, box.hi),
					}
					
					line_box_bounds = {math.F32_MAX, 0}
				}
			}
			// Break if reached end
			if at_end {
				s.line_end = it.index
				break
			}
			// Increment column
			column += 1
		}
	}

	s.line_start = max(s.line_start, 0)

	last_selection := s.selection
	if .Pressed in widget.state {
		if .Pressed not_in widget.last_state {
			if widget.click_count == 3 {
				edit.perform_command(s, .Select_All)
			} else {
				s.selection = {hover_index, hover_index}
			}
		}
		if widget.click_count == 2 {
			next, last: int
			if hover_index < s.selection[1] {
				last = hover_index if info.text[hover_index] == ' ' else max(0, strings.last_index_any(info.text[:hover_index], " \n") + 1)
				next = strings.index_any(info.text[s.selection[1]:], " \n")
				if next == -1 {
					next = len(info.text)
				} else {
					next += s.selection[1]
				}
			} else {
				last = max(0, strings.last_index_any(info.text[:s.selection[1]], " \n") + 1)
				next = 0 if (hover_index > 0 && info.text[hover_index - 1] == ' ') else strings.index_any(info.text[hover_index:], " \n")
				if next == -1 {
					next = len(info.text) - hover_index
				}
				next += hover_index
			}
			s.selection = {last, next}
		} else {
			s.selection[1] = hover_index
		}
	}
	if last_selection != s.selection {
		core.draw_next_frame = true
	}
	return result
}
*/