# frozen_string_literal: true

module Api
  class TemplatesFromFileController < ApiBaseController
    MAX_REQUEST_SIZE = ENV.fetch('API_TEMPLATE_MAX_REQUEST_SIZE_MB', '50').to_i.megabytes
    RATE_LIMIT = ENV.fetch('API_TEMPLATE_CREATE_RATE_LIMIT', '30').to_i
    RATE_LIMIT_TTL = 1.minute

    PERMITTED_FIELD_PARAMS = [
      :name, :type, :role, :required, :readonly, :title, :description, :default_value,
      { default_value: [],
        options: [],
        preferences: Templates::CreateFromApi::PREFERENCES_KEYS,
        validation: %i[pattern message min max step],
        areas: %i[x y w h page option] }
    ].freeze

    prepend_before_action :check_request_size
    before_action :require_token_for_multipart
    before_action :authorize_create
    before_action :check_rate_limit

    rescue_from Templates::CreateFromApi::Error,
                Templates::DocxToPdf::InvalidDocument,
                Templates::DocxToPdf::ConversionError do |e|
      render json: { error: e.message }, status: :unprocessable_content
    end

    rescue_from Templates::DocxToPdf::ConverterUnavailable do |e|
      render json: { error: e.message }, status: :not_implemented
    end

    rescue_from Templates::DocxToPdf::ConverterBusy do |e|
      render json: { error: e.message }, status: :service_unavailable
    end

    rescue_from ActiveRecord::RecordInvalid do
      render json: { error: 'Unable to create template' }, status: :unprocessable_content
    end

    def pdf
      create_template(:pdf)
    end

    def docx
      create_template(:docx)
    end

    private

    def create_template(source_type)
      Params::TemplateCreateFromFileValidator.call(params.to_unsafe_h)

      template = find_template_by_external_id || @template
      is_new = template.new_record?

      assign_template_attributes(template, is_new:)

      Templates::CreateFromApi.call(template, create_params, source_type:)

      WebhookUrls.enqueue_events(template, is_new ? 'template.created' : 'template.updated')

      SearchEntries.enqueue_reindex(template)

      render json: Templates::SerializeForApi.call(template)
    end

    def assign_template_attributes(template, is_new:)
      if is_new
        template.source = :api
        template.external_id = create_params[:external_id].presence

        Templates.maybe_assign_access(template)
      end

      if is_new || create_params.key?(:shared_link)
        template.shared_link = ActiveModel::Type::Boolean.new.cast(create_params[:shared_link]) || false
      end

      return unless is_new || create_params[:folder_name].present?

      template.folder = TemplateFolders.find_or_create_by_name(current_user, create_params[:folder_name])
    end

    # An existing template with the same external_id in the current account is updated with the new documents.
    def find_template_by_external_id
      external_id = create_params[:external_id].presence

      return if external_id.blank?

      template = Template.where(account_id: current_account.id, external_id:).active.order(id: :desc).first

      authorize!(:update, template) if template

      template
    end

    def authorize_create
      @template = Template.new(account: current_account, author: current_user)

      authorize!(:create, @template)
    end

    # Multipart forms can be submitted cross-site, so they must not be authenticated with the session cookie.
    def require_token_for_multipart
      return unless request.content_mime_type&.symbol == :multipart_form
      return if request.headers['X-Auth-Token'].present?

      render json: { error: 'X-Auth-Token header is required for multipart requests' }, status: :unauthorized
    end

    def check_rate_limit
      RateLimit.call("api-template-create:#{current_user.id}", limit: RATE_LIMIT, ttl: RATE_LIMIT_TTL, enabled: true)
    end

    def check_request_size
      size = request.content_length || request.body&.size

      return if size.to_i <= MAX_REQUEST_SIZE

      render json: { error: "Request is larger than #{MAX_REQUEST_SIZE / 1.megabyte}MB" }, status: :content_too_large
    end

    def create_params
      @create_params ||=
        params.permit(:name, :folder_name, :external_id, :shared_link, :remove_tags, :flatten,
                      documents: [:name, :file, { fields: PERMITTED_FIELD_PARAMS }]).to_h
    end
  end
end
