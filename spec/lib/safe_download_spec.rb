# frozen_string_literal: true

RSpec.describe SafeDownload do
  let(:public_ip) { '93.184.216.34' }

  before do
    allow(described_class).to receive(:resolve).and_call_original
    allow(described_class).to receive(:resolve).with('files.example.com').and_return([public_ip])
  end

  it 'downloads a file from a public HTTPS URL' do
    stub_request(:get, 'https://files.example.com/doc.pdf').to_return(status: 200, body: '%PDF-1.4 test')

    expect(described_class.call('https://files.example.com/doc.pdf', max_bytes: 1.megabyte)).to eq('%PDF-1.4 test')
  end

  it 'rejects plain HTTP URLs' do
    expect { described_class.call('http://files.example.com/doc.pdf', max_bytes: 1.megabyte) }
      .to raise_error(described_class::Error, /Only HTTPS/)
  end

  it 'rejects non-standard ports' do
    expect { described_class.call('https://files.example.com:8443/doc.pdf', max_bytes: 1.megabyte) }
      .to raise_error(described_class::Error, /port 443/)
  end

  it 'rejects URLs with credentials' do
    expect { described_class.call('https://user:pass@files.example.com/doc.pdf', max_bytes: 1.megabyte) }
      .to raise_error(described_class::Error, /credentials/)
  end

  [
    '127.0.0.1', '10.0.0.5', '172.16.3.4', '192.168.1.10', '169.254.169.254', '100.64.0.1', '0.0.0.0',
    '[::1]', '[fd00::1]', '[fe80::1]', '[::ffff:127.0.0.1]', '[::ffff:169.254.169.254]'
  ].each do |host|
    it "rejects the internal address #{host}" do
      expect { described_class.call("https://#{host}/doc.pdf", max_bytes: 1.megabyte) }
        .to raise_error(described_class::Error, /disallowed address/)
    end
  end

  it 'rejects hostnames that resolve to internal addresses' do
    allow(described_class).to receive(:resolve).with('internal.example.com').and_return(['10.1.2.3'])

    expect { described_class.call('https://internal.example.com/doc.pdf', max_bytes: 1.megabyte) }
      .to raise_error(described_class::Error, /disallowed address/)
  end

  it 'rejects hostnames when any resolved address is internal' do
    allow(described_class).to receive(:resolve).with('mixed.example.com').and_return([public_ip, '127.0.0.1'])

    expect { described_class.call('https://mixed.example.com/doc.pdf', max_bytes: 1.megabyte) }
      .to raise_error(described_class::Error, /disallowed address/)
  end

  it 'rejects redirects to internal addresses' do
    stub_request(:get, 'https://files.example.com/doc.pdf')
      .to_return(status: 302, headers: { 'Location' => 'https://169.254.169.254/latest/meta-data/' })

    expect { described_class.call('https://files.example.com/doc.pdf', max_bytes: 1.megabyte) }
      .to raise_error(described_class::Error, /disallowed address/)
  end

  it 'rejects redirects to plain HTTP' do
    stub_request(:get, 'https://files.example.com/doc.pdf')
      .to_return(status: 301, headers: { 'Location' => 'http://files.example.com/doc.pdf' })

    expect { described_class.call('https://files.example.com/doc.pdf', max_bytes: 1.megabyte) }
      .to raise_error(described_class::Error, /Only HTTPS/)
  end

  it 'stops after too many redirects' do
    stub_request(:get, 'https://files.example.com/loop')
      .to_return(status: 302, headers: { 'Location' => 'https://files.example.com/loop' })

    expect { described_class.call('https://files.example.com/loop', max_bytes: 1.megabyte) }
      .to raise_error(described_class::Error, /Too many redirects/)
  end

  it 'rejects responses larger than the limit' do
    stub_request(:get, 'https://files.example.com/big.pdf').to_return(status: 200, body: 'a' * 2048)

    expect { described_class.call('https://files.example.com/big.pdf', max_bytes: 1024) }
      .to raise_error(described_class::Error, /too large/)
  end

  it 'raises on error responses' do
    stub_request(:get, 'https://files.example.com/missing.pdf').to_return(status: 404)

    expect { described_class.call('https://files.example.com/missing.pdf', max_bytes: 1.megabyte) }
      .to raise_error(described_class::Error, /HTTP 404/)
  end
end
