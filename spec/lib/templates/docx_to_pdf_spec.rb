# frozen_string_literal: true

RSpec.describe Templates::DocxToPdf do
  describe '.sanitize' do
    it 'drops external relationships but keeps hyperlinks and internal parts' do
      rels = <<~XML
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="https://attacker.example/pixel.png" TargetMode="External"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://www.docuseal.com" TargetMode="External"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/attachedTemplate" Target="file:///etc/passwd" TargetMode="External"/>
        <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
      XML

      result = read_docx_entry(described_class.sanitize(build_docx(paragraphs: ['Hello'], rels:)),
                               'word/_rels/document.xml.rels')

      expect(result).not_to include('attacker.example')
      expect(result).not_to include('/etc/passwd')
      expect(result).to include('https://www.docuseal.com')
      expect(result).to include('styles.xml')
    end

    it 'neutralizes field codes that include external content' do
      body_xml = <<~XML
        <w:p>
          <w:r><w:fldChar w:fldCharType="begin"/></w:r>
          <w:r><w:instrText xml:space="preserve"> INCLUDEPICTURE "http://169.254.169.254/latest" </w:instrText></w:r>
          <w:r><w:fldChar w:fldCharType="end"/></w:r>
        </w:p>
        <w:p><w:fldSimple w:instr="INCLUDETEXT &quot;/etc/passwd&quot;"><w:r><w:t>x</w:t></w:r></w:fldSimple></w:p>
        <w:p><w:r><w:pict><v:shape><v:imagedata src="https://attacker.example/a.png" o:href="file:///etc/hosts"/></v:shape></w:pict></w:r></w:p>
        <w:p><w:altChunk r:id="rId9"/></w:p>
      XML

      result = read_docx_entry(described_class.sanitize(build_docx(body_xml:)), 'word/document.xml')

      expect(result).not_to include('169.254.169.254')
      expect(result).not_to include('/etc/passwd')
      expect(result).not_to include('attacker.example')
      expect(result).not_to include('/etc/hosts')
      expect(result).not_to include('altChunk')
    end

    it 'moves field tags into their own hidden runs, including tags split across runs' do
      body_xml = <<~XML
        <w:p>
          <w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">Name: {{Full </w:t></w:r>
          <w:r><w:rPr><w:b/></w:rPr><w:t>Name;role=Buyer}} and more</w:t></w:r>
        </w:p>
      XML

      result = read_docx_entry(described_class.sanitize(build_docx(body_xml:)), 'word/document.xml')

      doc = Nokogiri::XML(result)
      runs = doc.xpath('//w:r', 'w' => TemplateFilesHelper::W_NS).to_a

      tag_runs = runs.select { |r| r.at_xpath('w:rPr/w:color[@w:val="FFFFFF"]', 'w' => TemplateFilesHelper::W_NS) }
      plain_runs = runs - tag_runs

      expect(tag_runs.map(&:text).join).to eq('{{Full Name;role=Buyer}}')
      expect(plain_runs.map(&:text)).to eq(['Name: ', ' and more'])
      expect(runs).to all(satisfy { |r| r.at_xpath('w:rPr/w:b', 'w' => TemplateFilesHelper::W_NS) })
    end

    it 'rejects macro-enabled documents' do
      content_types = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Override PartName="/word/document.xml" ContentType="application/vnd.ms-word.document.macroEnabled.main+xml"/>
        </Types>
      XML

      expect { described_class.sanitize(build_docx(paragraphs: ['x'], content_types:)) }
        .to raise_error(described_class::InvalidDocument, /Macro-enabled/)
    end

    it 'rejects documents with too many entries' do
      stub_const("#{described_class}::MAX_ENTRIES", 5)

      extra_entries = Array.new(5) { |i| ["word/media/#{i}.txt", 'x'] }.to_h

      expect { described_class.sanitize(build_docx(paragraphs: ['x'], extra_entries:)) }
        .to raise_error(described_class::InvalidDocument, /too many entries/)
    end

    it 'rejects zip bombs' do
      stub_const("#{described_class}::MAX_ENTRY_SIZE", 1.megabyte)

      docx = build_docx(paragraphs: ['x'], extra_entries: { 'word/media/bomb.bin' => "\0" * 2.megabytes })

      expect(docx.bytesize).to be < 100.kilobytes
      expect { described_class.sanitize(docx) }.to raise_error(described_class::InvalidDocument, /too large/)
    end

    it 'rejects files that are not DOCX packages' do
      expect { described_class.sanitize('not a zip') }.to raise_error(described_class::InvalidDocument)

      zip = Zip::OutputStream.write_buffer(StringIO.new) do |z|
        z.put_next_entry('hello.txt')
        z.write('hi')
      end.string

      expect { described_class.sanitize(zip) }.to raise_error(described_class::InvalidDocument, /document.xml/)
    end

    it 'rejects malformed XML' do
      docx = build_docx(paragraphs: ['x'])
      docx = Zip::OutputStream.write_buffer(StringIO.new) do |zip|
        Zip::File.open_buffer(StringIO.new(docx)).each do |entry|
          zip.put_next_entry(entry.name)
          zip.write(entry.name == 'word/document.xml' ? '<w:document><unclosed>' : entry.get_input_stream.read)
        end
      end.string

      expect { described_class.sanitize(docx) }.to raise_error(described_class::InvalidDocument, /malformed XML/)
    end
  end

  describe '.call', if: described_class.available? do
    it 'converts the field tags fixture to a PDF with tags that can be located and removed' do
      pdf = described_class.call(Rails.root.join('spec/fixtures/fieldtags.docx').binread)

      expect(pdf).to start_with('%PDF-')

      Pdfium::Document.open_bytes(pdf) do |doc|
        tags = Templates::FieldTags.find(doc)

        expect(tags.map { |t| t.attrs['name'] }).to include('Text Field', 'Field1', 'FIeld2', 'DOB', 'Signature',
                                                            'Sign here', 'Name', 'Test')

        Templates::FieldTags.remove(doc, tags)

        text = pdf_text(doc.save(StringIO.new).string)

        expect(text).not_to include('{{')
        expect(text).to include('Simple text field')
      end
    end

    it 'kills the conversion when it times out' do
      stub_const("#{described_class}::TIMEOUT", 0)

      expect { described_class.call(build_docx(paragraphs: ['Hello'])) }
        .to raise_error(described_class::ConversionError, /timed out/)
    end
  end

  it 'raises when LibreOffice is not installed' do
    allow(described_class).to receive(:soffice_path).and_return(nil)

    expect { described_class.call(build_docx(paragraphs: ['Hello'])) }
      .to raise_error(described_class::ConverterUnavailable)
  end
end
