require 'pango'
require_relative '../args/typographer'
require_relative 'embedding_utils'

module Squib
  class Card

    # :nodoc:
    # @api private
    def draw_text_hint(cc, x, y, layout, color)
      color = @deck.text_hint if color.to_s.eql? 'off' and not @deck.text_hint.to_s.eql? 'off'
      return if color.to_s.eql? 'off' or color.nil?
      # when w,h < 0, it was never set. extents[1] are ink extents
      w = layout.width / Pango::SCALE
      w = layout.extents[1].width / Pango::SCALE if w < 0
      h = layout.height / Pango::SCALE
      h = layout.extents[1].height / Pango::SCALE if h < 0
      cc.rounded_rectangle(0, 0, w, h, 0, 0)
      cc.set_source_color(color)
      cc.set_line_width(2.0)
      cc.stroke
    end

    # :nodoc:
    # @api private
    def compute_valign(layout, valign, embed_h)
      return 0 unless layout.height > 0
      ink_extents = layout.extents[1]
      ink_extents.height = embed_h * Pango::SCALE if ink_extents.height == 0 # JUST embed, bug #134
      case valign.to_s.downcase
      when 'middle'
        Pango.pixels((layout.height - ink_extents.height) / 2)
      when 'bottom'
        Pango.pixels(layout.height - ink_extents.height)
      else
        0
      end
    end

    def set_font_rendering_opts!(layout)
      font_options                = Cairo::FontOptions.new
      font_options.antialias      = Conf::ANTIALIAS_OPTS[(@deck.antialias || 'gray').downcase]
      font_options.hint_metrics   = 'on' # TODO make this configurable
      font_options.hint_style     = 'full' # TODO make this configurable
      layout.context.font_options = font_options
    end

    # :nodoc:
    # @api private
    def set_wh!(layout, width, height)
      layout.width  = width * Pango::SCALE unless width.nil? || width == :auto
      layout.height = height * Pango::SCALE unless height.nil? || height == :auto
    end

    def max_embed_height(embed_draws)
      embed_draws.inject(0) do |max, ed|
        ed[:h] > max ? ed[:h] : max
      end
    end

    def embed_images!(embed, str, layout, valign)
      return [] unless embed.rules.any?
      layout.markup = str
      clean_str     = layout.text
      attrs = layout.attributes || Pango::AttrList.new
      puts "Embedding! #{str}"
      puts "  Rules: #{embed.rules.keys}"
      puts "  Indices: #{EmbeddingUtils.indices(clean_str, embed.rules.keys)}"
      EmbeddingUtils.indices(clean_str, embed.rules.keys).each do |key, ranges|
        puts "Ranges: #{ranges}"
        rule = embed.rules[key]
        ranges.each do |range|
          w = rule[:box].width[@index] * Pango::SCALE / (range.size - 1)
          puts "Width is gonna be #{embed.rules[key][:box].width[@index]}, or #{w} in Pango"
          carve = Pango::Rectangle.new(0, 0, w, 0)
          att = Pango::AttrShape.new(carve, carve, rule)
          att.start_index = range.first
          att.end_index = range.last
          attrs.insert(att)
          puts "Inserting attribute!"
        end
      end
      layout.attributes = attrs
      layout.context.set_shape_renderer do |cxt, att, do_path|
        unless do_path
          rule = att.data
          x = Pango.pixels(layout.index_to_pos(att.start_index).x) +
              rule[:adjust].dx[@index]
          y = Pango.pixels(layout.index_to_pos(att.start_index).y) +
                rule[:adjust].dy[@index] +
                compute_valign(layout, valign, rule[:box].height[@index])
          puts "Gonna draw!! #{x},#{y}, and width was #{att.ink_rect.width / Pango::SCALE}. do_path: #{do_path}, "
          rule[:draw].call(self, x, y)
          cxt.reset_clip
          [cxt, att, do_path]
        end
      end
    end

    # # :nodoc:
    # # @api private
    # def next_embed(keys, str)
    #   ret     = nil
    #   ret_key = nil
    #   keys.each do |key|
    #     i = str.index(key)
    #     ret ||= i
    #     unless i.nil? || i > ret
    #       ret = i
    #       ret_key = key
    #     end
    #   end
    #   ret_key
    # end
    #
    # # :nodoc:
    # def process_embeds(embed, str, layout)
    #   return [] unless embed.rules.any?
    #   layout.markup = str
    #   clean_str     = layout.text
    #   draw_calls    = []
    #   searches      = []
    #   while (key = next_embed(embed.rules.keys, clean_str)) != nil
    #     rule    = embed.rules[key]
    #     spacing = rule[:box].width[@index] * Pango::SCALE
    #     kindex   = clean_str.index(key)
    #     kindex   = clean_str[0..kindex].bytesize # byte index (bug #57)
    #     str = str.sub(key, "\u2062<span letter_spacing=\"#{spacing.to_i}\">\u2062</span>\u2062")
    #     layout.markup = str
    #     clean_str     = layout.text
    #     searches << { index: kindex, rule: rule }
    #   end
    #   searches.each do |search|
    #     rect = layout.index_to_pos(search[:index])
    #     x    = Pango.pixels(rect.x) + search[:rule][:adjust].dx[@index]
    #     y    = Pango.pixels(rect.y) + search[:rule][:adjust].dy[@index]
    #     h    = rule[:box].height[@index]
    #     draw_calls << { x: x, y: y, h: h, # defer drawing until we've valigned
    #                    draw: search[:rule][:draw] }
    #   end
    #   return draw_calls
    # end

    def stroke_outline!(cc, layout, draw)
      if draw.stroke_width > 0
        cc.pango_layout_path(layout)
        cc.fancy_stroke draw
        cc.set_source_squibcolor(draw.color)
      end
    end

    def warn_if_ellipsized(layout)
       if @deck.conf.warn_ellipsize? && layout.ellipsized?
         Squib.logger.warn { "Ellipsized (too much text). Card \##{@index}. Text:  \"#{layout.text}\". \n (To disable this warning, set warn_ellipsize: false in config.yml)" }
       end
    end

    # :nodoc:
    # @api private
    def text(embed, para, box, trans, draw)
      Squib.logger.debug {"Rendering text with: \n#{para} \nat:\n #{box} \ndraw:\n #{draw} \ntransform: #{trans}"}
      extents = nil
      use_cairo do |cc|
        cc.set_source_squibcolor(draw.color)
        cc.translate(box.x, box.y)
        cc.rotate(trans.angle)
        cc.move_to(0, 0)

        font_desc      = Pango::FontDescription.new(para.font)
        font_desc.size = para.font_size * Pango::SCALE unless para.font_size.nil?
        layout         = cc.create_pango_layout
        layout.font_description = font_desc
        layout.text = para.str
        if para.markup
          para.str = @deck.typographer.process(layout.text)
          layout.markup = para.str
        end

        set_font_rendering_opts!(layout)
        set_wh!(layout, box.width, box.height)
        layout.wrap      = para.wrap
        layout.ellipsize = para.ellipsize
        layout.alignment = para.align

        layout.justify = para.justify unless para.justify.nil?
        layout.spacing = para.spacing unless para.spacing.nil?

        embed_images!(embed, para.str, layout, para.valign)

        vertical_start = compute_valign(layout, para.valign, 0)
        cc.move_to(0, vertical_start)

        stroke_outline!(cc, layout, draw) if draw.stroke_strategy == :stroke_first
        cc.move_to(0, vertical_start)

        cc.show_pango_layout(layout)
        cc.move_to(0, vertical_start)
        stroke_outline!(cc, layout, draw) if draw.stroke_strategy == :fill_first
        draw_text_hint(cc, box.x, box.y, layout, para.hint)
        extents = { width: layout.extents[1].width / Pango::SCALE,
                    height: layout.extents[1].height / Pango::SCALE }
        warn_if_ellipsized layout
      end
      return extents
    end

  end
end
