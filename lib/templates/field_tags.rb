# frozen_string_literal: true

module Templates
  # Finds `{{Field Name;role=Signer;type=signature}}` text tags in PDF pages and
  # turns them into template fields placed where the tag was printed.
  module FieldTags
    TAG_REGEXP = /\{\{([^{}\r\n]{1,500})\}\}/

    FIELD_TYPES = %w[text signature initials date datenow number image file select
                     checkbox multiple phone stamp cells heading strikethrough].freeze

    # A tag without `type` named like a field type, e.g. `{{Signature}}`, gets that type.
    NAME_TYPES = %w[signature initials date image file stamp phone checkbox].index_by(&:itself).freeze

    SQUARE_FIELD_TYPES = %w[checkbox].freeze

    # Tags are only as tall as their text, which makes DocuSeal shrink field values that don't fit.
    # Areas without an explicit `height` get a minimum height in PDF points.
    DEFAULT_MIN_HEIGHT = 18
    MIN_HEIGHTS = { 'signature' => 36, 'image' => 36, 'stamp' => 36, 'initials' => 24, 'checkbox' => 0 }.freeze

    # These areas grow upwards so the signature or image sits on the line where the tag was.
    BOTTOM_ALIGNED_TYPES = %w[signature initials image stamp].freeze

    MAX_NAME_LENGTH = 255
    MAX_OPTIONS = 100
    MAX_OPTION_LENGTH = 255
    MAX_DEFAULT_VALUE_LENGTH = 5000
    MAX_TAGS_PER_PAGE = 500
    MAX_DIMENSION = 5000

    # Minimum gap between two characters, relative to the line height, that is read as a space.
    WORD_GAP_RATIO = 0.15

    Tag = Struct.new(:attrs, :area)

    module_function

    # Returns an Array of Tag with `area` relative to the page (0..1) and `page` 0-based.
    def find(doc, max_pages: doc.page_count)
      (0...[doc.page_count, max_pages].min).flat_map do |page_index|
        find_in_page(doc.get_page(page_index), page_index)
      end
    end

    def find_in_page(page, page_index)
      nodes = page.text_nodes

      return [] if nodes.blank?

      text, node_indexes = join_nodes(page, nodes)

      return [] unless text.include?('{{')

      tags = []

      text.to_enum(:scan, TAG_REGEXP).each do
        match = Regexp.last_match

        break if tags.size >= MAX_TAGS_PER_PAGE

        attrs = parse(match[1])

        next if attrs.nil?

        tag_nodes = node_indexes[match.begin(0)...match.end(0)].compact.map { |index| nodes[index] }

        next if tag_nodes.blank?

        tags << Tag.new(attrs:, area: build_area(page, page_index, tag_nodes, attrs))
      end

      tags
    end

    # Joins the page characters into a string. Justified text often has no space characters between
    # words, only a gap, so a space is inserted for gaps on the same line. Returns the string and the
    # node index of each of its characters (nil for inserted spaces).
    def join_nodes(page, nodes)
      chars = []
      node_indexes = []

      nodes.each_with_index do |node, index|
        if index.positive? && word_gap?(page, nodes[index - 1], node)
          chars << ' '
          node_indexes << nil
        end

        chars << node.content
        node_indexes << index
      end

      [chars.join, node_indexes]
    end

    def word_gap?(page, prev_node, node)
      return false if prev_node.content.blank? || node.content.blank?

      line_height = [prev_node.h, node.h].min * page.height

      return false if (prev_node.endy - node.endy).abs * page.height > line_height / 2

      gap = (node.x - prev_node.endx) * page.width

      gap > line_height * WORD_GAP_RATIO
    end

    def parse(body)
      name, attrs = split_tag_body(body)
      name = name.squish

      return if name.blank?

      type = attrs['type'].to_s.downcase.presence || NAME_TYPES.fetch(name.downcase, 'text')
      type = 'text' unless FIELD_TYPES.include?(type)

      {
        'name' => name.first(MAX_NAME_LENGTH),
        'type' => type,
        'role' => attrs['role'].presence&.first(MAX_NAME_LENGTH),
        'required' => cast_boolean(attrs['required'], default: true),
        'readonly' => cast_boolean(attrs['readonly'], default: false),
        'default_value' => (attrs['default'] || attrs['default_value']).presence&.first(MAX_DEFAULT_VALUE_LENGTH),
        'options' => parse_options(attrs['options']),
        'format' => attrs['format'].presence&.first(MAX_NAME_LENGTH),
        'width' => parse_dimension(attrs['width']),
        'height' => parse_dimension(attrs['height'])
      }.compact
    end

    def split_tag_body(body)
      name, *attr_parts = body.split(';')

      if name.to_s.include?('=')
        attr_parts.unshift(name)

        name = nil
      end

      attrs = attr_parts.each_with_object({}) do |part, acc|
        key, value = part.split('=', 2)

        acc[key.strip.downcase] = value.strip if key.present? && !value.nil?
      end

      [(attrs.delete('name') || name).to_s.strip, attrs]
    end

    def build_area(page, page_index, tag_nodes, attrs)
      bounds = node_bounds(tag_nodes)
      x, y, w, h = bounds.values_at('x', 'y', 'w', 'h')

      w = attrs['width'] / page.width if attrs['width']
      h = attrs['height'] / page.height if attrs['height']

      y, h = apply_min_height(y, h, page, attrs['type']) unless attrs['height']

      w = (h * page.height) / page.width if SQUARE_FIELD_TYPES.include?(attrs['type']) && !attrs['width']

      x = x.clamp(0.0, 1.0)
      y = y.clamp(0.0, 1.0)

      {
        'x' => x,
        'y' => y,
        'w' => w.clamp(0.0, 1.0 - x),
        'h' => h.clamp(0.0, 1.0 - y),
        'page' => page_index,
        # Tag text bounds, used to strip the tag text from the page.
        'redact' => bounds
      }
    end

    def apply_min_height(top, height, page, type)
      min_height = MIN_HEIGHTS.fetch(type, DEFAULT_MIN_HEIGHT) / page.height

      return [top, height] if height >= min_height

      top = BOTTOM_ALIGNED_TYPES.include?(type) ? top + height - min_height : top - ((min_height - height) / 2)

      [top, min_height]
    end

    def node_bounds(nodes)
      x = nodes.map(&:x).min
      y = nodes.map(&:y).min

      { 'x' => x, 'y' => y, 'w' => nodes.map(&:endx).max - x, 'h' => nodes.map(&:endy).max - y }
    end

    # Removes the tag text from the pages that contain tags. `redact` with 'white'
    # removes the glyphs without drawing a rectangle over them.
    def remove(doc, tags)
      tags.group_by { |tag| tag.area['page'] }.each do |page_index, page_tags|
        rects = page_tags.map { |tag| tag.area['redact'].merge('color' => 'white') }

        doc.get_page(page_index).redact(rects, keep_font: true)
      end

      doc
    end

    def parse_options(value)
      return if value.blank?

      value.split(',').map(&:strip).compact_blank.uniq.first(MAX_OPTIONS).map { |v| v.first(MAX_OPTION_LENGTH) }
    end

    def parse_dimension(value)
      return if value.blank?

      number = Float(value, exception: false)

      return if number.nil? || !number.finite? || number <= 0

      [number, MAX_DIMENSION].min
    end

    def cast_boolean(value, default:)
      return default if value.nil?

      casted = ActiveModel::Type::Boolean.new.cast(value.to_s.downcase)

      casted.nil? ? default : casted
    end
  end
end
