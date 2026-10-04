# frozen_string_literal: true

module Templates
  # Creates a template from PDF or DOCX documents sent to the API, with fields taken from
  # `{{field tags}}` found in the documents and/or from the explicit `fields` param.
  module CreateFromApi
    Error = Class.new(StandardError)

    MAX_FILE_SIZE = ENV.fetch('API_TEMPLATE_MAX_FILE_SIZE_MB', '20').to_i.megabytes
    MAX_PAGES = ENV.fetch('API_TEMPLATE_MAX_PAGES', '500').to_i
    MAX_ROLES = 20

    PDF_CONTENT_TYPE = 'application/pdf'
    PDF_MAGIC = '%PDF-'
    ZIP_MAGIC = "PK\x03\x04".b
    DATA_URI_PREFIX_REGEXP = %r{\Adata:[a-z0-9.+/-]*;base64,}i
    UNSAFE_FILENAME_CHARS_REGEXP = %r{[/\\:*?"<>|\x00-\x1f\x7f]}

    PREFERENCES_KEYS = %w[font_size font_type font color background align valign format price currency mask].freeze
    VALIDATION_KEYS = %w[pattern message min max step].freeze

    PreparedDocument = Struct.new(:name, :data, :page_sizes, :tags, :fields_params) do
      def page_count
        page_sizes.size
      end
    end
    FileStub = Struct.new(:original_filename, :content_type)

    module_function

    def call(template, params, source_type:)
      documents = params[:documents].map.with_index do |doc_params, index|
        prepare_document(doc_params, index, source_type:, remove_tags: params[:remove_tags].to_s != 'false',
                                            flatten: params[:flatten].to_s == 'true')
      end

      template.name = params[:name].presence || template.name.presence || documents.first.name

      ApplicationRecord.transaction do
        template.save!

        attachments = documents.map do |document|
          store_document(template, document, extract_acro_fields: no_fields?(documents))
        end

        template.schema = documents.zip(attachments).map do |document, attachment|
          { 'attachment_uuid' => attachment.uuid, 'name' => document.name }
        end

        assign_fields_and_submitters(template, documents, attachments)

        template.save!
      end

      template
    end

    def prepare_document(doc_params, index, source_type:, remove_tags: true, flatten: false)
      data = load_file(doc_params[:file])

      if source_type == :docx
        raise Error, "documents[#{index}].file must be a DOCX file" unless data.start_with?(ZIP_MAGIC)

        data = DocxToPdf.call(data)
      end

      raise Error, "documents[#{index}].file must be a PDF file" unless data[0, 1024].to_s.include?(PDF_MAGIC)

      data, page_sizes, tags = process_pdf(data, index, remove_tags:, flatten:)

      PreparedDocument.new(
        name: document_name(doc_params[:name], index),
        data:,
        page_sizes:,
        tags:,
        fields_params: Array.wrap(doc_params[:fields])
      )
    end

    def process_pdf(data, index, remove_tags:, flatten:)
      Pdfium::Document.open_bytes(data) do |doc|
        raise Error, "documents[#{index}].file is password protected" if doc.encrypted?
        raise Error, "documents[#{index}].file has no pages" if doc.page_count.zero?
        raise Error, "documents[#{index}].file has more than #{MAX_PAGES} pages" if doc.page_count > MAX_PAGES

        page_sizes = (0...doc.page_count).map { |page_index| doc.page_size(page_index) }

        flattened = flatten && doc.form?

        flatten_forms(doc) if flattened

        tags = FieldTags.find(doc)

        FieldTags.remove(doc, tags) if remove_tags && tags.present?

        data = doc.save(StringIO.new).string.b if flattened || (remove_tags && tags.present?)

        [data, page_sizes, tags]
      end
    rescue Pdfium::PasswordError
      raise Error, "documents[#{index}].file is password protected"
    rescue Pdfium::PdfiumError
      raise Error, "documents[#{index}].file is not a valid PDF file"
    end

    def flatten_forms(doc)
      (0...doc.page_count).each { |page_index| doc.get_page(page_index).flatten }
    end

    def load_file(file)
      data =
        if file.respond_to?(:read) && file.respond_to?(:size)
          raise Error, file_too_large_message if file.size > MAX_FILE_SIZE

          file.read
        elsif file.is_a?(String) && file.match?(%r{\Ahttps?://}i)
          SafeDownload.call(file, max_bytes: MAX_FILE_SIZE)
        elsif file.is_a?(String)
          decode_base64(file)
        else
          raise Error, 'file must be a base64 encoded string, an HTTPS URL or an uploaded file'
        end

      raise Error, 'File is empty' if data.blank?
      raise Error, file_too_large_message if data.bytesize > MAX_FILE_SIZE

      data.b
    rescue SafeDownload::Error => e
      raise Error, e.message
    end

    def decode_base64(value)
      value = value.sub(DATA_URI_PREFIX_REGEXP, '')

      raise Error, file_too_large_message if value.bytesize > ((MAX_FILE_SIZE * 4 / 3) + 1024)

      Base64.strict_decode64(value.gsub(/\s+/, ''))
    rescue ArgumentError
      raise Error, 'file must be a valid base64 encoded string or an HTTPS URL'
    end

    def file_too_large_message
      "File is larger than #{MAX_FILE_SIZE / 1.megabyte}MB"
    end

    def document_name(name, index)
      name = name.to_s.gsub(UNSAFE_FILENAME_CHARS_REGEXP, ' ').squish.first(200)
      name = File.basename(name, '.*') if name.match?(/\.(pdf|docx)\z/i)

      name.presence || "Document #{index + 1}"
    end

    def no_fields?(documents)
      documents.all? { |document| document.tags.blank? && document.fields_params.blank? }
    end

    def store_document(template, document, extract_acro_fields:)
      file = FileStub.new("#{document.name}.pdf", PDF_CONTENT_TYPE)

      CreateAttachments.handle_pdf_or_image(template, file, document.data, {}, extract_fields: extract_acro_fields)
    rescue CreateAttachments::PdfEncrypted
      raise Error, 'PDF file is password protected'
    end

    def assign_fields_and_submitters(template, documents, attachments)
      fields = []

      documents.zip(attachments).each_with_index do |(document, attachment), doc_index|
        document.tags.each do |tag|
          merge_field(fields, build_tag_field(tag, attachment))
        end

        document.fields_params.each_with_index do |field_params, field_index|
          path = "documents[#{doc_index}].fields[#{field_index}]"

          merge_field(fields, build_param_field(field_params, document, attachment, path))
        end
      end

      roles = fields.filter_map { |f| f['role_name'] }.uniq

      raise Error, "Too many roles, maximum is #{MAX_ROLES}" if roles.size > MAX_ROLES

      roles = [I18n.t(:first_party)] if roles.empty?

      template.submitters = roles.map { |role| { 'name' => role, 'uuid' => SecureRandom.uuid } }

      fields.each do |field|
        role = field.delete('role_name') || roles.first

        field['type'] ||= 'text'

        normalize_date_signed_field(field) if field['type'] == 'datenow'

        field['submitter_uuid'] = template.submitters.find { |s| s['name'] == role }['uuid']
      end

      fields = ProcessDocument.normalize_attachment_fields(template, attachments) if fields.empty?

      template.fields = fields
    end

    # 'datenow' is the builder's "Date signed" shortcut, not a stored field type: like the builder, store it
    # as a read-only date that is filled with the signing date.
    def normalize_date_signed_field(field)
      field['type'] = 'date'
      field['readonly'] = true
      field['default_value'] = '{{date}}'
    end

    # Fields with the same name and role are merged, so a tag repeated on several pages or a
    # `fields` param with the same name as a tag shares one value across all its areas.
    def merge_field(fields, field)
      existing = fields.find { |f| f['name'] == field['name'] && f['role_name'] == field['role_name'] }

      return fields << field unless existing

      areas = existing['areas'] + field['areas']

      existing.merge!(field.except('uuid', 'areas'))
      existing['areas'] = areas

      fields
    end

    def build_tag_field(tag, attachment)
      attrs = tag.attrs

      field = {
        'uuid' => SecureRandom.uuid,
        'name' => attrs['name'],
        'type' => attrs['type'],
        'required' => attrs['required'],
        'readonly' => attrs['readonly'],
        'preferences' => attrs['format'] ? { 'format' => attrs['format'] } : {},
        'areas' => [tag.area.except('redact').merge('attachment_uuid' => attachment.uuid)]
      }

      field['default_value'] = attrs['default_value'] if attrs['default_value']
      field['options'] = build_options(attrs['options']) if attrs['options']
      field['role_name'] = attrs['role'] if attrs['role']

      field
    end

    def build_param_field(params, document, attachment, path)
      field = { 'uuid' => SecureRandom.uuid, 'name' => params[:name].to_s }.merge(optional_param_attrs(params))

      field['areas'] = Array.wrap(params[:areas]).map.with_index do |area, index|
        build_area(area, document, attachment, "#{path}.areas[#{index}]").tap do |built_area|
          built_area['option_uuid'] = find_or_add_option(field, area[:option]) if area[:option].present?
        end
      end

      field
    end

    # Areas of 'radio' and 'multiple' fields reference one of the field options.
    def find_or_add_option(field, value)
      field['options'] ||= []

      option = field['options'].find { |o| o['value'] == value.to_s }

      unless option
        option = { 'value' => value.to_s, 'uuid' => SecureRandom.uuid }

        field['options'] << option
      end

      option['uuid']
    end

    def optional_param_attrs(params)
      attrs = %w[type title description].index_with { |key| params[key].to_s }.compact_blank

      attrs['role_name'] = params[:role].to_s if params[:role].present?
      attrs['required'] = cast_boolean(params[:required]) if params.key?(:required)
      attrs['readonly'] = cast_boolean(params[:readonly]) if params.key?(:readonly)
      attrs['default_value'] = params[:default_value] if params.key?(:default_value)
      attrs['options'] = build_options(params[:options]) if params[:options].present?
      attrs['preferences'] = params[:preferences].to_h.slice(*PREFERENCES_KEYS) if params[:preferences].present?
      attrs['validation'] = params[:validation].to_h.slice(*VALIDATION_KEYS) if params[:validation].present?

      attrs
    end

    def build_area(area, document, attachment, path)
      page = Integer(area[:page].presence || 1, exception: false)
      page_count = document.page_count

      raise Error, "#{path}.page must be between 1 and #{page_count}" unless page&.between?(1, page_count)

      coords = %i[x y w h].index_with { |key| Float(area[key].to_s, exception: false) }

      coords.each do |key, value|
        raise Error, "#{path}.#{key} must be a positive number" unless value&.finite? && value >= 0
      end

      coords = points_to_relative(coords, document.page_sizes[page - 1]) if coords.values.any? { |v| v > 1 }

      fits = coords[:x] + coords[:w] <= 1.0001 && coords[:y] + coords[:h] <= 1.0001

      raise Error, "#{path} must fit within the page" unless fits

      {
        'x' => coords[:x], 'y' => coords[:y], 'w' => coords[:w], 'h' => coords[:h],
        'page' => page - 1,
        'attachment_uuid' => attachment.uuid
      }
    end

    # Coordinates greater than 1 are PDF points (1/72 inch) from the top left corner of the page.
    def points_to_relative(coords, page_size)
      width, height = page_size

      { x: coords[:x] / width, y: coords[:y] / height, w: coords[:w] / width, h: coords[:h] / height }
    end

    def build_options(options)
      Array.wrap(options).map { |value| { 'value' => value.to_s, 'uuid' => SecureRandom.uuid } }
    end

    def cast_boolean(value)
      ActiveModel::Type::Boolean.new.cast(value) ? true : false
    end
  end
end
