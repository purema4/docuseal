# frozen_string_literal: true

module Params
  class TemplateCreateFromFileValidator < BaseValidator
    MAX_DOCUMENTS = 10
    MAX_FIELDS = 500
    MAX_AREAS = 100
    MAX_OPTIONS = 100
    MAX_STRING_LENGTH = 255
    MAX_TEXT_LENGTH = 5000

    FIELD_TYPES = %w[text signature initials date datenow number image file select checkbox
                     multiple radio phone stamp cells heading strikethrough payment].freeze

    def call
      required(params, :documents)
      type(params, :documents, Array)

      max_length(params, :name, MAX_STRING_LENGTH)
      max_length(params, :folder_name, MAX_STRING_LENGTH)
      max_length(params, :external_id, MAX_STRING_LENGTH)
      boolean(params, :shared_link)
      boolean(params, :remove_tags)
      boolean(params, :flatten)

      raise_error("documents must contain at most #{MAX_DOCUMENTS} items") if params[:documents].size > MAX_DOCUMENTS

      total_fields = params[:documents].sum { |doc| doc.is_a?(Hash) ? Array.wrap(doc[:fields]).size : 0 }

      raise_error("documents must contain at most #{MAX_FIELDS} fields in total") if total_fields > MAX_FIELDS

      in_path_each(params, :documents) do |document_params|
        validate_document(document_params)
      end

      true
    end

    def validate_document(params)
      raise_error('document must be an Object') unless params.is_a?(Hash)

      required(params, :file)
      max_length(params, :name, MAX_STRING_LENGTH)
      type(params, :fields, Array)

      in_path_each(params, :fields) do |field_params|
        validate_field(field_params)
      end
    end

    def validate_field(params)
      raise_error('field must be an Object') unless params.is_a?(Hash)

      required(params, :name)
      string(params, :name)
      max_length(params, :name, MAX_STRING_LENGTH)
      value_in(params, :type, FIELD_TYPES, allow_nil: true)
      string(params, :role)
      max_length(params, :role, MAX_STRING_LENGTH)
      boolean(params, :required)
      boolean(params, :readonly)
      string(params, :title)
      max_length(params, :title, MAX_STRING_LENGTH)
      string(params, :description)
      max_length(params, :description, MAX_TEXT_LENGTH)
      type(params, :options, Array)
      type(params, :areas, Array)
      type(params, :preferences, Hash)
      type(params, :validation, Hash)

      validate_default_value(params)
      validate_options(params)
      validate_validation(params)

      raise_error("areas must contain at most #{MAX_AREAS} items") if Array.wrap(params[:areas]).size > MAX_AREAS

      in_path_each(params, :areas) do |area_params|
        raise_error('area must be an Object') unless area_params.is_a?(Hash)

        %i[x y w h].each { |key| required(area_params, key, message: "#{key} is required") if area_params[key].nil? }

        max_length(area_params, :option, MAX_STRING_LENGTH)
      end
    end

    def validate_default_value(params)
      value = params[:default_value]

      return if value.nil? || value.is_a?(Numeric) || value.in?([true, false])

      if value.is_a?(String)
        max_length(params, :default_value, MAX_TEXT_LENGTH)
      elsif value.is_a?(Array)
        raise_error('default_value must contain only strings') unless value.all?(String)
      else
        raise_error('default_value must be a String, Number, Boolean or Array')
      end
    end

    def validate_options(params)
      options = params[:options]

      return unless options.is_a?(Array)

      raise_error("options must contain at most #{MAX_OPTIONS} items") if options.size > MAX_OPTIONS

      options.each do |value|
        next if (value.is_a?(String) && value.size <= MAX_STRING_LENGTH) || value.is_a?(Numeric)

        raise_error("options must be strings of at most #{MAX_STRING_LENGTH} characters")
      end
    end

    def validate_validation(params)
      validation = params[:validation]

      return unless validation.is_a?(Hash)

      string(validation, :pattern)
      max_length(validation, :pattern, MAX_STRING_LENGTH)
      string(validation, :message)
      max_length(validation, :message, MAX_STRING_LENGTH)
    end

    def string(params, key)
      return if params.blank? || params[key].nil?
      return if params[key].is_a?(String)

      raise_error("#{key} must be a String")
    end

    def max_length(params, key, length)
      return if params.blank? || params[key].nil?
      return if params[key].to_s.length <= length

      raise_error("#{key} must be at most #{length} characters")
    end
  end
end
