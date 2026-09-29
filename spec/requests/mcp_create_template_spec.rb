# frozen_string_literal: true

describe 'MCP create_template tool' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:mcp_token) { McpToken.create!(user:, name: 'Test') }
  let(:headers) { { 'Authorization' => "Bearer #{mcp_token.token}", 'Content-Type' => 'application/json' } }

  let(:tagged_pdf) do
    build_pdf([['Buyer: {{Full Name;role=Buyer}}', 'Sign: {{Buyer Signature;type=signature;role=Buyer}}']])
  end

  before do
    RateLimit::STORE.clear
    AccountConfig.create!(account:, key: AccountConfig::ENABLE_MCP_KEY, value: true)
    allow(SafeDownload).to receive(:resolve).and_call_original
    allow(SafeDownload).to receive(:resolve).with('files.example.com').and_return(['93.184.216.34'])
  end

  def call_tool(arguments, request_headers = headers)
    body = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'create_template', arguments: } }

    post '/mcp', params: body.to_json, headers: request_headers
  end

  def tool_result
    content = response.parsed_body.dig('result', 'content', 0, 'text')

    response.parsed_body.dig('result', 'isError') ? content : JSON.parse(content)
  end

  def tool_error?
    response.parsed_body.dig('result', 'isError') == true
  end

  it 'creates an empty template when no url is given' do
    call_tool({ name: 'Empty template' })

    expect(tool_error?).to be(false)

    template = Template.find(tool_result['id'])

    expect(template.name).to eq('Empty template')
    expect(template.source).to eq('mcp')
    expect(template.account).to eq(account)
    expect(template.schema).to eq([])
    expect(tool_result['edit_url']).to include("/templates/#{template.id}/edit")
  end

  it 'creates fields from text tags in a PDF' do
    stub_request(:get, 'https://files.example.com/agreement.pdf').to_return(status: 200, body: tagged_pdf)

    call_tool({ name: 'Agreement', url: 'https://files.example.com/agreement.pdf' })

    expect(tool_error?).to be(false)
    expect(tool_result).to include('roles' => ['Buyer'], 'fields' => ['Full Name', 'Buyer Signature'])

    template = Template.find(tool_result['id'])

    expect(template.name).to eq('Agreement')
    expect(template.source).to eq('mcp')
    expect(template.schema.first['name']).to eq('agreement')
    expect(template.fields.pluck('type')).to eq(%w[text signature])
    expect(pdf_text(template.schema_documents.first.download)).not_to include('{{')
  end

  it 'names the template after the file when no name is given' do
    stub_request(:get, 'https://files.example.com/Sale%20Agreement.pdf').to_return(status: 200, body: tagged_pdf)

    call_tool({ name: '', url: 'https://files.example.com/Sale%20Agreement.pdf' })

    expect(tool_error?).to be(false)
    expect(Template.find(tool_result['id']).name).to eq('Sale Agreement')
  end

  it 'creates fields from text tags in a DOCX', if: Templates::DocxToPdf.available? do
    stub_request(:get, 'https://files.example.com/fieldtags.docx')
      .to_return(status: 200, body: Rails.root.join('spec/fixtures/fieldtags.docx').binread)

    call_tool({ name: 'Field tags', url: 'https://files.example.com/fieldtags.docx' })

    expect(tool_error?).to be(false)
    expect(tool_result['roles']).to eq(['First Party', 'Signer2'])
    expect(tool_result['fields']).to include('Text Field', 'DOB', 'Sign here', 'Test')

    template = Template.find(tool_result['id'])

    expect(template.schema_documents.first.content_type).to eq('application/pdf')
  end

  it 'still accepts images' do
    stub_request(:get, 'https://files.example.com/scan.png')
      .to_return(status: 200, body: Rails.root.join('spec/fixtures/sample-image.png').binread)

    call_tool({ name: 'Scan', url: 'https://files.example.com/scan.png' })

    expect(tool_error?).to be(false)

    template = Template.find(tool_result['id'])

    expect(template.schema.size).to eq(1)
    expect(template.schema_documents.first.content_type).to eq('image/png')
  end

  it 'rejects files that are not PDF, DOCX or images' do
    stub_request(:get, 'https://files.example.com/page.html').to_return(status: 200, body: '<html>hi</html>')

    call_tool({ name: 'Page', url: 'https://files.example.com/page.html' })

    expect(tool_error?).to be(true)
    expect(tool_result).to eq('url must be a PDF file')
    expect(Template.count).to eq(0)
  end

  it 'rejects URLs pointing to internal addresses' do
    call_tool({ name: 'Metadata', url: 'https://169.254.169.254/latest/meta-data/' })

    expect(tool_error?).to be(true)
    expect(tool_result).to include('disallowed address')
    expect(a_request(:get, /169.254.169.254/)).not_to have_been_made
    expect(Template.count).to eq(0)
  end

  it 'rejects plain HTTP URLs' do
    call_tool({ name: 'Doc', url: 'http://files.example.com/agreement.pdf' })

    expect(tool_error?).to be(true)
    expect(tool_result).to eq('Only HTTPS URLs are allowed')
  end

  it 'rate limits template creation per user' do
    stub_const('Api::TemplatesFromFileController::RATE_LIMIT', 2)

    3.times { call_tool({ name: 'Empty' }) }

    expect(tool_error?).to be(true)
    expect(tool_result).to eq('Too many requests, try again later')
    expect(Template.count).to eq(2)
  end

  it 'requires an MCP token' do
    call_tool({ name: 'Empty' }, { 'Content-Type' => 'application/json' })

    expect(response).to have_http_status(:unauthorized)
    expect(Template.count).to eq(0)
  end

  it 'does not accept an API token instead of an MCP token' do
    call_tool({ name: 'Empty' }, headers.merge('Authorization' => "Bearer #{user.access_token.token}"))

    expect(response).to have_http_status(:unauthorized)
  end

  it 'requires MCP to be enabled for the account' do
    AccountConfig.where(account:, key: AccountConfig::ENABLE_MCP_KEY).delete_all

    call_tool({ name: 'Empty' })

    expect(response).to have_http_status(:forbidden)
    expect(Template.count).to eq(0)
  end
end
