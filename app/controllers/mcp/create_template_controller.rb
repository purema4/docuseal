# frozen_string_literal: true

module Mcp
  class CreateTemplateController < McpBaseController
    SCHEMA = {
      name: 'create_template',
      title: 'Create Template',
      description: 'Create a document template. Provide an HTTPS URL to upload a PDF/DOCX file, or provide only ' \
                   'a name to create an empty template and receive an edit URL where the file can be uploaded ' \
                   'via the UI. Text tags like {{Full Name;role=Signer;type=signature}} in the document are ' \
                   'turned into fields.',
      inputSchema: {
        type: 'object',
        properties: {
          name: {
            type: 'string',
            description: 'Template name (used as the template name and required when url is not provided)'
          },
          url: {
            type: 'string',
            description: 'Optional HTTPS URL of a PDF or DOCX file to upload. If omitted, an empty template is ' \
                         'created and the returned edit_url can be used to upload a file via the UI.'
          }
        },
        required: %w[name]
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true
      }
    }.freeze

    ZIP_MAGIC = Templates::CreateFromApi::ZIP_MAGIC

    rescue_from Templates::CreateFromApi::Error,
                Templates::DocxToPdf::InvalidDocument,
                Templates::DocxToPdf::ConversionError,
                Templates::DocxToPdf::ConverterUnavailable,
                Templates::DocxToPdf::ConverterBusy,
                Templates::CreateAttachments::InvalidFileType,
                Templates::CreateAttachments::PdfEncrypted do |e|
      render_tool_error(tool_error_message(e))
    end

    rescue_from RateLimit::LimitApproached do
      render_tool_error('Too many requests, try again later')
    end

    def call
      @template = build_template

      authorize!(:create, @template)

      RateLimit.call("mcp-template-create:#{current_user.id}", limit: Api::TemplatesFromFileController::RATE_LIMIT,
                                                               ttl: Api::TemplatesFromFileController::RATE_LIMIT_TTL,
                                                               enabled: true)

      Templates.maybe_assign_access(@template)

      mcp_params['url'].present? ? create_from_url(mcp_params['url'].to_s) : create_empty

      WebhookUrls.enqueue_events(@template, 'template.created')

      SearchEntries.enqueue_reindex(@template)

      render_tool_result(
        id: @template.id,
        name: @template.name,
        edit_url: edit_template_url(@template),
        roles: @template.submitters.pluck('name'),
        fields: @template.fields.pluck('name')
      )
    end

    private

    def build_template
      account = current_user.account

      Template.new(account:, author: current_user, folder: account.default_template_folder, source: :mcp)
    end

    def create_empty
      @template.name = mcp_params['name'].to_s.presence || 'New Template'
      @template.save!
    end

    def create_from_url(url)
      data = Templates::CreateFromApi.load_file(url)
      filename = url_filename(url)

      if Marcel::MimeType.for(StringIO.new(data)).start_with?('image/')
        create_from_image(data, filename)
      else
        source_type = data.start_with?(ZIP_MAGIC) ? :docx : :pdf
        params = { name: mcp_params['name'].to_s.presence,
                   documents: [{ name: filename, file: StringIO.new(data) }] }.with_indifferent_access

        Templates::CreateFromApi.call(@template, params, source_type:)
      end
    end

    def create_from_image(data, filename)
      tempfile = Tempfile.new
      tempfile.binmode
      tempfile.write(data)
      tempfile.rewind

      file = ActionDispatch::Http::UploadedFile.new(tempfile:, filename:, type: Marcel::MimeType.for(tempfile))

      @template.name = mcp_params['name'].to_s.presence || File.basename(filename, '.*')
      @template.save!

      documents, = Templates::CreateAttachments.call(@template, { files: [file] })

      @template.update!(schema: documents.map { |doc| { attachment_uuid: doc.uuid, name: doc.filename.base } })
    end

    def url_filename(url)
      File.basename(URI.decode_www_form_component(URI.parse(url).path.to_s)).presence || 'Document'
    rescue URI::InvalidURIError, ArgumentError
      'Document'
    end

    def tool_error_message(error)
      case error
      when Templates::CreateAttachments::InvalidFileType then 'url must point to a PDF, DOCX or image file'
      when Templates::CreateAttachments::PdfEncrypted then 'PDF file is password protected'
      else error.message.sub('documents[0].file', 'url')
      end
    end
  end
end
