package ui

import "core:math"
import "core:math/ease"
import "core:math/linalg"

@(private="file") SIZE :: 22
@(private="file") PADDING :: 4

Checkbox_Info :: struct {
	using generic: Generic_Widget_Info,
	value: bool,
	text: string,
	text_side: Maybe(Side),

	__text_size: [2]f32,
}

make_checkbox :: proc(info: Checkbox_Info, loc := #caller_location) -> Checkbox_Info {
	info := info
	info.id = hash(loc)
	info.text_side = info.text_side.? or_else .Left
	if len(info.text) > 0 {
		info.__text_size = measure_text({font = core.style.fonts[.Regular], size = 18, text = info.text})
		if info.text_side == .Bottom || info.text_side == .Top {
			info.desired_size.x = max(SIZE, info.__text_size.x)
			info.desired_size.y = SIZE + info.__text_size.y
		} else {
			info.desired_size.x = SIZE + info.__text_size.x + PADDING * 2
			info.desired_size.y = SIZE
		}
	} else {
		info.desired_size = SIZE
	}
	return info
}

display_checkbox :: proc(info: Checkbox_Info) -> Generic_Widget_Result {
	self := get_widget(info)
	self.box = info.box.? or_else next_widget_box(info)
	self.hover_time = animate(self.hover_time, 0.1, .Hovered in self.state)

	if self.visible {
		icon_box: Box
		if len(info.text) > 0 {
			switch info.text_side {
				case .Left:
				icon_box = {self.box.low, SIZE}
				case .Right:
				icon_box = {{self.box.high.x - SIZE, self.box.low.y}, SIZE}
				case .Top:
				icon_box = {{center_x(self.box) - SIZE / 2, self.box.high.y - SIZE}, SIZE}
				case .Bottom:
				icon_box = {{center_x(self.box) - SIZE / 2, self.box.low.y}, SIZE}
			}
			icon_box.low = linalg.floor(icon_box.low)
			icon_box.high += icon_box.low
		} else {
			icon_box = self.box
		}
		// Paint box
		opacity: f32 = 0.5 if self.disabled else 1
		draw_rounded_box_stroke(icon_box, core.style.rounding, 1, core.style.color.substance)
		center := box_center(icon_box)
		// Hover 
		if self.hover_time > 0 {
			draw_rounded_box_fill(self.box, core.style.rounding, fade(core.style.color.substance, 0.5 * self.hover_time))
		}
		// Paint icon
		if info.value {
			scale: f32 = SIZE / 4
			begin_path()
			point(center + {-1, -0.047} * scale)
			point(center + {-0.333, 0.619} * scale)
			point(center + {1, -0.713} * scale)
			stroke_path(2, core.style.color.content)
			end_path()
		}
		// Paint text
		if len(info.text) > 0 {
			switch info.text_side {
				case .Left: 	
				draw_text({icon_box.high.x + PADDING, center.y - info.__text_size.y / 2}, {text = info.text, font = core.style.fonts[.Regular], size = 18}, fade(core.style.color.content, opacity))
				case .Right: 	
				draw_text({icon_box.low.x - PADDING, center.y - info.__text_size.y / 2}, {text = info.text, font = core.style.fonts[.Regular], size = 18, align_h = .Right}, fade(core.style.color.content, opacity))
				case .Top: 		
				draw_text(self.box.low, {text = info.text, font = core.style.fonts[.Regular], size = 18}, fade(core.style.color.content, opacity))
				case .Bottom: 	
				draw_text({self.box.low.x, self.box.high.y - info.__text_size.y}, {text = info.text, font = core.style.fonts[.Regular], size = 18}, fade(core.style.color.content, opacity))
			}
		}
	}
	//
	commit_widget(self, point_in_box(core.mouse_pos, self.box))
	// We're done here
	return Generic_Widget_Result{self = self},
}

do_checkbox :: proc(info: Checkbox_Info, loc := #caller_location) -> Generic_Widget_Result {
	return display_checkbox(make_checkbox(info, loc))
}