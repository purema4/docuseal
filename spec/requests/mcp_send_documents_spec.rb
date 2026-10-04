# frozen_string_literal: true

describe 'MCP send_documents tool' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:mcp_token) { McpToken.create!(user:, name: 'Test') }
  let(:headers) { { 'Authorization' => "Bearer #{mcp_token.token}", 'Content-Type' => 'application/json' } }
  let(:template) { create(:template, submitter_count: 2, account:, author: user) }
  let(:submitters) do
    [{ email: 'first@example.com', role: 'First Party' }, { email: 'second@example.com', role: 'Second Party' }]
  end

  before do
    AccountConfig.create!(account:, key: AccountConfig::ENABLE_MCP_KEY, value: true)
  end

  def call_tool(arguments)
    body = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'send_documents', arguments: } }

    post '/mcp', params: body.to_json, headers:
  end

  def tool_result
    JSON.parse(response.parsed_body.dig('result', 'content', 0, 'text'))
  end

  it 'emails the signature requests by default' do
    expect do
      call_tool({ template_id: template.id, submitters: })
    end.to change(SendSubmitterInvitationEmailJob.jobs, :size).by(2)

    submission = Submission.find(tool_result['id'])

    expect(submission.submitters.map(&:sent_at)).to all(be_present)
  end

  it 'does not email the signature requests when send_email is false' do
    expect do
      call_tool({ template_id: template.id, submitters:, send_email: false })
    end.not_to change(SendSubmitterInvitationEmailJob.jobs, :size)

    submission = Submission.find(tool_result['id'])

    expect(submission.submitters.map(&:sent_at)).to all(be_nil)
    expect(submission.submitters.map { |s| s.preferences['send_email'] }).to all(be(false))
    result_submitters = tool_result['submitters'].index_by { |s| s['email'] }

    expect(result_submitters.transform_values { |s| s['role'] })
      .to eq('first@example.com' => 'First Party', 'second@example.com' => 'Second Party')

    submission.submitters.each do |submitter|
      expect(result_submitters[submitter.email]['url']).to end_with("/s/#{submitter.slug}")
    end
  end

  it 'only emails the first submitter when the order is preserved' do
    expect do
      call_tool({ template_id: template.id, submitters:, order: 'preserved' })
    end.to change(SendSubmitterInvitationEmailJob.jobs, :size).by(1)

    expect(Submission.find(tool_result['id']).submitters_order).to eq('preserved')
    expect(tool_result['submitters_order']).to eq('preserved')
  end

  it 'uses the template order setting when no order is given' do
    template.update!(preferences: { 'submitters_order' => 'preserved' })

    call_tool({ template_id: template.id, submitters: })

    expect(Submission.find(tool_result['id']).submitters_order).to eq('preserved')
  end
end
