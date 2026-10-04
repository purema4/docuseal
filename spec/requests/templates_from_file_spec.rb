# frozen_string_literal: true

describe 'Templates from file API' do
  let(:account) { create(:account, :with_testing_account) }
  let(:testing_account) { account.testing_accounts.first }
  let(:author) { create(:user, account:) }
  let(:testing_author) { create(:user, account: testing_account) }
  let(:headers) { { 'x-auth-token': author.access_token.token } }

  let(:tagged_pdf) do
    build_pdf([
                ['Buyer name: {{Full Name;role=Buyer}}', 'Buyer sign: {{Buyer Signature;type=signature;role=Buyer}}'],
                ['Seller sign: {{Seller Signature;type=signature;role=Seller;width=150;height=40}}',
                 'Again: {{Full Name;role=Buyer}}']
              ])
  end

  let(:plain_pdf) { build_pdf([['Plain document without tags'], ['Second page']]) }

  before do
    RateLimit::STORE.clear
    allow(Accounts).to receive(:link_expires_at).and_return(Accounts::LINK_EXPIRES_AT)
  end

  def post_pdf(body, request_headers = headers)
    post '/api/templates/pdf', params: body.to_json,
                               headers: request_headers.merge('Content-Type' => 'application/json')
  end

  def post_docx(body, request_headers = headers)
    post '/api/templates/docx', params: body.to_json,
                                headers: request_headers.merge('Content-Type' => 'application/json')
  end

  def stored_pdf(template)
    template.schema_documents.first.download
  end

  describe 'POST /api/templates/pdf' do
    it 'creates a template with fields from field tags' do
      post_pdf({ name: 'Sale agreement', documents: [{ name: 'agreement', file: Base64.strict_encode64(tagged_pdf) }] })

      expect(response).to have_http_status(:ok)

      template = Template.find(response.parsed_body['id'])

      expect(template.account).to eq(account)
      expect(template.author).to eq(author)
      expect(template.name).to eq('Sale agreement')
      expect(template.source).to eq('api')
      expect(template.submitters.pluck('name')).to eq(%w[Buyer Seller])
      expect(template.schema.size).to eq(1)
      expect(template.schema.first['name']).to eq('agreement')

      buyer_uuid, seller_uuid = template.submitters.pluck('uuid')
      fields = template.fields.index_by { |f| f['name'] }

      expect(fields.keys).to eq(['Full Name', 'Buyer Signature', 'Seller Signature'])
      expect(fields['Full Name']).to include('type' => 'text', 'submitter_uuid' => buyer_uuid, 'required' => true)
      expect(fields['Full Name']['areas'].pluck('page')).to eq([0, 1])
      expect(fields['Buyer Signature']).to include('type' => 'signature', 'submitter_uuid' => buyer_uuid)
      expect(fields['Seller Signature']).to include('type' => 'signature', 'submitter_uuid' => seller_uuid)
      expect(fields['Seller Signature']['areas'].first['w']).to be_within(0.0001).of(150.0 / 612)

      attachment_uuid = template.schema.first['attachment_uuid']

      expect(template.fields.flat_map { |f| f['areas'] }.pluck('attachment_uuid')).to all(eq(attachment_uuid))
      expect(template.fields.flat_map { |f| f['areas'] }.first.keys).to match_array(%w[x y w h page attachment_uuid])

      text = pdf_text(stored_pdf(template))

      expect(text).not_to include('{{')
      expect(text.gsub(/\s+/, '')).to include('Buyername:')

      expect(response.parsed_body['documents'].first['uuid']).to eq(attachment_uuid)
      expect(response.parsed_body['fields'].size).to eq(3)
    end

    it 'enqueues the template.created webhook' do
      create(:webhook_url, account:, events: ['template.created'])

      expect do
        post_pdf({ documents: [{ file: Base64.strict_encode64(tagged_pdf) }] })
      end.to change(SendTemplateCreatedWebhookRequestJob.jobs, :size).by(1)
    end

    it 'keeps tag text when remove_tags is false' do
      post_pdf({ remove_tags: false, documents: [{ file: Base64.strict_encode64(tagged_pdf) }] })

      expect(response).to have_http_status(:ok)
      expect(pdf_text(stored_pdf(Template.last))).to include('{{Full Name;role=Buyer}}')
    end

    it 'creates fields from the fields param using 1-based pages and relative coordinates' do
      post_pdf({
                 documents: [{
                   name: 'Plain',
                   file: "data:application/pdf;base64,#{Base64.strict_encode64(plain_pdf)}",
                   fields: [
                     { name: 'Company', type: 'text', required: false, title: 'Company name',
                       areas: [{ x: 0.1, y: 0.2, w: 0.3, h: 0.04, page: 2 }] },
                     { name: 'Plan', type: 'select', options: %w[Basic Pro], role: 'Customer',
                       preferences: { font_size: 12, evil: 'x' },
                       areas: [{ x: 0.5, y: 0.5, w: 0.2, h: 0.04 }] }
                   ]
                 }]
               })

      expect(response).to have_http_status(:ok)

      template = Template.last
      fields = template.fields.index_by { |f| f['name'] }

      expect(template.name).to eq('Plain')
      expect(template.submitters.pluck('name')).to eq(['Customer'])
      expect(fields['Company']).to include('type' => 'text', 'required' => false, 'title' => 'Company name')
      expect(fields['Company']['areas'].first).to include('x' => 0.1, 'y' => 0.2, 'w' => 0.3, 'h' => 0.04, 'page' => 1)
      expect(fields['Plan']['options'].pluck('value')).to eq(%w[Basic Pro])
      expect(fields['Plan']['preferences']).to eq('font_size' => 12)
      expect(fields['Plan']['areas'].first['page']).to eq(0)
    end

    it 'assigns fields without a role to the first party' do
      post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf),
                               fields: [{ name: 'Note', areas: [{ x: 0.1, y: 0.1, w: 0.2, h: 0.05 }] }] }] })

      expect(response).to have_http_status(:ok)

      template = Template.last

      expect(template.submitters.pluck('name')).to eq(['First Party'])
      expect(template.fields.first['submitter_uuid']).to eq(template.submitters.first['uuid'])
    end

    it 'stores datenow fields as read-only dates filled with the signing date' do
      pdf = build_pdf([['Signed on: {{Signing Date;type=datenow;role=Buyer}}']])

      post_pdf({ documents: [{ file: Base64.strict_encode64(pdf),
                               fields: [{ name: 'Seller Date', type: 'datenow', role: 'Seller',
                                          areas: [{ x: 0.1, y: 0.5, w: 0.2, h: 0.04 }] }] }] })

      expect(response).to have_http_status(:ok)

      fields = Template.last.fields.index_by { |f| f['name'] }

      expect(fields['Signing Date']).to include('type' => 'date', 'readonly' => true, 'default_value' => '{{date}}')
      expect(fields['Seller Date']).to include('type' => 'date', 'readonly' => true, 'default_value' => '{{date}}')
    end

    it 'merges fields param into tags with the same name and role' do
      post_pdf({
                 documents: [{
                   file: Base64.strict_encode64(tagged_pdf),
                   fields: [{ name: 'Full Name', role: 'Buyer', required: false, description: 'Legal name' }]
                 }]
               })

      expect(response).to have_http_status(:ok)

      field = Template.last.fields.find { |f| f['name'] == 'Full Name' }

      expect(field).to include('type' => 'text', 'required' => false, 'description' => 'Legal name')
      expect(field['areas'].size).to eq(2)
    end

    it 'creates a template with multiple documents' do
      post_pdf({ documents: [{ name: 'One', file: Base64.strict_encode64(tagged_pdf) },
                             { name: 'Two', file: Base64.strict_encode64(plain_pdf) }] })

      expect(response).to have_http_status(:ok)

      template = Template.last

      expect(template.name).to eq('One')
      expect(template.schema.pluck('name')).to eq(%w[One Two])
      expect(response.parsed_body['documents'].size).to eq(2)
    end

    it 'accepts multipart file uploads' do
      file = Rack::Test::UploadedFile.new(StringIO.new(tagged_pdf), 'application/pdf', original_filename: 'up.pdf')

      post '/api/templates/pdf', params: { name: 'Uploaded', documents: [{ name: 'up', file: }] }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(Template.last.fields.size).to eq(3)
    end

    it 'does not accept multipart uploads authenticated with a session cookie' do
      sign_in(author)

      file = Rack::Test::UploadedFile.new(StringIO.new(tagged_pdf), 'application/pdf', original_filename: 'up.pdf')

      post '/api/templates/pdf', params: { documents: [{ file: }] }

      expect(response).to have_http_status(:unauthorized)
      expect(Template.count).to eq(0)
    end

    it 'accepts JSON requests authenticated with a session cookie' do
      sign_in(author)

      post '/api/templates/pdf', params: { documents: [{ file: Base64.strict_encode64(plain_pdf) }] }.to_json,
                                 headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:ok)
    end

    it 'downloads files from public HTTPS URLs' do
      allow(SafeDownload).to receive(:resolve).with('files.example.com').and_return(['93.184.216.34'])
      stub_request(:get, 'https://files.example.com/doc.pdf').to_return(status: 200, body: tagged_pdf)

      post_pdf({ documents: [{ file: 'https://files.example.com/doc.pdf' }] })

      expect(response).to have_http_status(:ok)
      expect(Template.last.fields.size).to eq(3)
    end

    it 'places the template into the folder and sets external_id and shared_link' do
      post_pdf({ folder_name: 'Contracts', external_id: 'ext-1', shared_link: true,
                 documents: [{ file: Base64.strict_encode64(plain_pdf) }] })

      expect(response).to have_http_status(:ok)

      template = Template.last

      expect(template.folder.name).to eq('Contracts')
      expect(template.folder.account).to eq(account)
      expect(template.external_id).to eq('ext-1')
      expect(template.shared_link).to be(true)
    end

    it 'accepts coordinates in PDF points' do
      areas = [{ x: 61.2, y: 79.2, w: 306, h: 39.6, page: 1 }]

      post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf), fields: [{ name: 'Company', areas: }] }] })

      expect(response).to have_http_status(:ok)

      area = Template.last.fields.first['areas'].first

      expect(area['x']).to be_within(0.0001).of(0.1)
      expect(area['y']).to be_within(0.0001).of(0.1)
      expect(area['w']).to be_within(0.0001).of(0.5)
      expect(area['h']).to be_within(0.0001).of(0.05)
    end

    it 'links radio areas to options' do
      post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf),
                               fields: [{ name: 'Size', type: 'radio', options: %w[S M],
                                          areas: [{ x: 0.1, y: 0.1, w: 0.02, h: 0.02, option: 'S' },
                                                  { x: 0.2, y: 0.1, w: 0.02, h: 0.02, option: 'L' }] }] }] })

      expect(response).to have_http_status(:ok)

      field = Template.last.fields.first
      options = field['options'].to_h { |o| [o['value'], o['uuid']] }

      expect(options.keys).to eq(%w[S M L])
      expect(field['areas'].pluck('option_uuid')).to eq([options['S'], options['L']])
    end

    it 'updates the existing template with the same external_id' do
      existing = create(:template, account:, author:, external_id: 'sync-key', name: 'Existing')
      other_account = create(:account)
      other_account_template = create(:template, account: other_account, author: create(:user, account: other_account),
                                                 external_id: 'sync-key')
      create(:webhook_url, account:, events: ['template.updated', 'template.created'])

      expect do
        post_pdf({ external_id: 'sync-key', documents: [{ file: Base64.strict_encode64(tagged_pdf) }] })
      end.not_to change(Template, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['id']).to eq(existing.id)

      existing.reload

      expect(existing.name).to eq('Existing')
      expect(existing.fields.pluck('name')).to eq(['Full Name', 'Buyer Signature', 'Seller Signature'])
      expect(existing.submitters.pluck('name')).to eq(%w[Buyer Seller])
      expect(SendTemplateUpdatedWebhookRequestJob.jobs.size).to eq(1)
      expect(SendTemplateCreatedWebhookRequestJob.jobs.size).to eq(0)
      expect(other_account_template.reload.fields.pluck('name')).not_to include('Buyer Signature')
    end

    it 'flattens PDF form fields when flatten is true' do
      pdf = HexaPDF::Document.new.tap do |doc|
        page = doc.pages.add
        form = doc.acro_form(create: true)
        field = form.create_text_field('Applicant')
        field.create_widget(page, Rect: [100, 600, 300, 620])
        field.field_value = 'Filled value'
        form.create_appearances
      end

      io = StringIO.new
      pdf.write(io)

      post_pdf({ flatten: true, documents: [{ file: Base64.strict_encode64(io.string) }] })

      expect(response).to have_http_status(:ok)

      template = Template.last

      expect(template.fields).to eq([])
      expect(pdf_text(stored_pdf(template))).to include('Filled value')
      expect(HexaPDF::Document.new(io: StringIO.new(stored_pdf(template))).acro_form&.each_field.to_a).to be_blank
    end

    it 'extracts PDF form fields when there are no tags or fields' do
      pdf = HexaPDF::Document.new.tap do |doc|
        page = doc.pages.add
        form = doc.acro_form(create: true)
        field = form.create_text_field('Applicant')
        field.create_widget(page, Rect: [100, 600, 300, 620])
      end

      io = StringIO.new
      pdf.write(io)

      post_pdf({ documents: [{ file: Base64.strict_encode64(io.string) }] })

      expect(response).to have_http_status(:ok)
      expect(Template.last.fields.pluck('name')).to eq(['Applicant'])
    end

    describe 'authentication and authorization' do
      it 'requires an API token' do
        post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf) }] }, {})

        expect(response).to have_http_status(:unauthorized)
        expect(Template.count).to eq(0)
      end

      it 'rejects an invalid API token' do
        post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf) }] }, { 'x-auth-token': 'invalid' })

        expect(response).to have_http_status(:unauthorized)
      end

      it 'rejects tokens of archived users' do
        author.update!(archived_at: Time.current)

        post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf) }] })

        expect(response).to have_http_status(:unauthorized)
      end

      it 'creates the template in the account of the token owner' do
        post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf) }] },
                 { 'x-auth-token': testing_author.access_token.token })

        expect(response).to have_http_status(:ok)
        expect(Template.last.account).to eq(testing_account)
      end

      it 'ignores attributes that are not allowed to be assigned' do
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        post_pdf({ account_id: other_account.id, author_id: other_user.id, slug: 'custom-slug', source: 'native',
                   archived_at: Time.current, documents: [{ file: Base64.strict_encode64(plain_pdf) }] })

        expect(response).to have_http_status(:ok)

        template = Template.last

        expect(template.account).to eq(account)
        expect(template.author).to eq(author)
        expect(template.slug).not_to eq('custom-slug')
        expect(template.source).to eq('api')
        expect(template.archived_at).to be_nil
      end

      it 'does not create templates in folders of another account' do
        other_folder = create(:template_folder, account: create(:account), name: 'Private')

        post_pdf({ folder_name: 'Private', documents: [{ file: Base64.strict_encode64(plain_pdf) }] })

        expect(response).to have_http_status(:ok)
        expect(Template.last.folder).not_to eq(other_folder)
        expect(Template.last.folder.account).to eq(account)
      end
    end

    describe 'input validation' do
      it 'requires documents' do
        post_pdf({ name: 'x' })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('documents is required')
      end

      it 'requires a file for each document' do
        post_pdf({ documents: [{ name: 'x' }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('file is required in `documents[0]`.')
      end

      it 'limits the number of documents' do
        post_pdf({ documents: Array.new(11) { { file: 'x' } } })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to include('at most 10')
      end

      it 'rejects unknown field types' do
        post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf), fields: [{ name: 'a', type: 'kba' }] }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to include('type must be one of')
      end

      it 'rejects too long values' do
        post_pdf({ name: 'a' * 256, documents: [{ file: Base64.strict_encode64(plain_pdf) }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('name must be at most 255 characters')
      end

      it 'rejects areas outside of the page' do
        post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf),
                                 fields: [{ name: 'a', areas: [{ x: 0.9, y: 0.1, w: 0.5, h: 0.1 }] }] }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('documents[0].fields[0].areas[0] must fit within the page')
      end

      it 'rejects pages that do not exist' do
        post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf),
                                 fields: [{ name: 'a', areas: [{ x: 0.1, y: 0.1, w: 0.1, h: 0.1, page: 3 }] }] }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('documents[0].fields[0].areas[0].page must be between 1 and 2')
      end

      it 'rejects non numeric coordinates' do
        post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf),
                                 fields: [{ name: 'a', areas: [{ x: 'NaN', y: 0.1, w: 0.1, h: 0.1 }] }] }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to include('x must be a positive number')
      end

      it 'rejects files that are not PDF' do
        post_pdf({ documents: [{ file: Base64.strict_encode64(build_docx(paragraphs: ['x'])) }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('documents[0].file must be a PDF file')
        expect(Template.count).to eq(0)
      end

      it 'rejects corrupted PDF files' do
        post_pdf({ documents: [{ file: Base64.strict_encode64("%PDF-1.7\n#{'garbage' * 10}") }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('documents[0].file is not a valid PDF file')
      end

      it 'rejects password protected PDF files' do
        doc = HexaPDF::Document.new(io: StringIO.new(plain_pdf))
        doc.encrypt(user_password: 'secret', owner_password: 'owner')
        io = StringIO.new
        doc.write(io)

        post_pdf({ documents: [{ file: Base64.strict_encode64(io.string) }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('documents[0].file is password protected')
      end

      it 'rejects invalid base64' do
        post_pdf({ documents: [{ file: 'not base64 ***' }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to include('base64')
      end

      it 'does not create anything when a later document is invalid' do
        post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf) }, { file: Base64.strict_encode64('nope') }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(Template.count).to eq(0)
        expect(ActiveStorage::Attachment.where(record_type: 'Template').count).to eq(0)
      end
    end

    describe 'resource limits' do
      it 'rejects files larger than the limit' do
        stub_const('Templates::CreateFromApi::MAX_FILE_SIZE', 1.kilobyte)

        post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf) }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to include('larger than')
      end

      it 'rejects documents with too many pages' do
        stub_const('Templates::CreateFromApi::MAX_PAGES', 1)

        post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf) }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('documents[0].file has more than 1 pages')
      end

      it 'rejects requests larger than the limit' do
        stub_const('Api::TemplatesFromFileController::MAX_REQUEST_SIZE', 1.kilobyte)

        post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf) }] })

        expect(response).to have_http_status(:content_too_large)
        expect(Template.count).to eq(0)
      end

      it 'rate limits template creation per user' do
        stub_const('Api::TemplatesFromFileController::RATE_LIMIT', 2)

        3.times { post_pdf({ documents: [{ file: Base64.strict_encode64(plain_pdf) }] }) }

        expect(response).to have_http_status(:too_many_requests)
        expect(Template.count).to eq(2)
      end
    end

    describe 'server-side request forgery' do
      it 'rejects URLs pointing to internal addresses' do
        post_pdf({ documents: [{ file: 'https://169.254.169.254/latest/meta-data/' }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to include('disallowed address')
        expect(a_request(:get, /169.254.169.254/)).not_to have_been_made
      end

      it 'rejects plain HTTP URLs' do
        post_pdf({ documents: [{ file: 'http://files.example.com/doc.pdf' }] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('Only HTTPS URLs are allowed')
      end
    end
  end

  describe 'POST /api/templates/docx' do
    let(:docx) { Rails.root.join('spec/fixtures/fieldtags.docx').binread }

    it 'creates a template with fields from DOCX field tags', if: Templates::DocxToPdf.available? do
      post_docx({ name: 'Field tags', documents: [{ name: 'fieldtags.docx', file: Base64.strict_encode64(docx) }] })

      expect(response).to have_http_status(:ok)

      template = Template.last

      expect(template.name).to eq('Field tags')
      expect(template.schema.first['name']).to eq('fieldtags')
      expect(template.submitters.pluck('name')).to eq(['First Party', 'Signer2'])

      first_party_uuid, signer2_uuid = template.submitters.pluck('uuid')
      fields = template.fields.index_by { |f| f['name'] }

      expect(fields.keys).to include('Text Field', 'Field1', 'FIeld2', 'DOB', 'Signature', 'Sign here', 'Name', 'Test')
      expect(fields['Text Field']).to include('type' => 'text', 'submitter_uuid' => first_party_uuid)
      expect(fields['FIeld2']['submitter_uuid']).to eq(signer2_uuid)
      expect(fields['DOB']['type']).to eq('date')
      expect(fields['Sign here']['type']).to eq('signature')
      expect(fields['Name']).to include('readonly' => true, 'default_value' => 'Bob')
      expect(fields['Test']).to include('type' => 'image', 'required' => false, 'submitter_uuid' => signer2_uuid)

      expect(template.schema_documents.first.content_type).to eq('application/pdf')
      expect(pdf_text(stored_pdf(template))).not_to include('{{')
    end

    it 'rejects files that are not DOCX' do
      post_docx({ documents: [{ file: Base64.strict_encode64(plain_pdf) }] })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('documents[0].file must be a DOCX file')
    end

    it 'rejects macro-enabled documents' do
      content_types = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Override PartName="/word/document.xml" ContentType="application/vnd.ms-word.document.macroEnabled.main+xml"/>
        </Types>
      XML

      post_docx({ documents: [{ file: Base64.strict_encode64(build_docx(paragraphs: ['x'], content_types:)) }] })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('Macro-enabled documents are not supported')
    end

    it 'returns 501 when LibreOffice is not installed' do
      allow(Templates::DocxToPdf).to receive(:soffice_path).and_return(nil)

      post_docx({ documents: [{ file: Base64.strict_encode64(build_docx(paragraphs: ['{{Name}}'])) }] })

      expect(response).to have_http_status(:not_implemented)
      expect(response.parsed_body['error']).to include('LibreOffice is not installed')
    end
  end
end
