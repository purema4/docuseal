# frozen_string_literal: true

module TemplateFilesHelper
  W_NS = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
  R_NS = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'

  # Builds a PDF with each inner array being the lines of one page.
  def build_pdf(pages, font: 'Helvetica')
    doc = HexaPDF::Document.new

    pages.each do |lines|
      canvas = doc.pages.add([0, 0, 612, 792]).canvas
      canvas.font(font, size: 12)

      Array.wrap(lines).each_with_index do |text, index|
        canvas.text(text, at: [72, 700 - (index * 40)])
      end
    end

    io = StringIO.new
    doc.write(io)
    io.string
  end

  def build_docx(body_xml: nil, paragraphs: [], rels: '', extra_entries: {}, content_types: nil)
    body_xml ||= paragraphs.map { |text| "<w:p><w:r><w:t xml:space=\"preserve\">#{text}</w:t></w:r></w:p>" }.join

    document_xml = <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="#{W_NS}" xmlns:r="#{R_NS}" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
        <w:body>#{body_xml}</w:body>
      </w:document>
    XML

    content_types ||= <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
      </Types>
    XML

    root_rels = <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
      </Relationships>
    XML

    document_rels = <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">#{rels}</Relationships>
    XML

    entries = {
      '[Content_Types].xml' => content_types,
      '_rels/.rels' => root_rels,
      'word/document.xml' => document_xml,
      'word/_rels/document.xml.rels' => document_rels,
      **extra_entries
    }

    Zip::OutputStream.write_buffer(StringIO.new) do |zip|
      entries.each do |name, data|
        zip.put_next_entry(name)
        zip.write(data)
      end
    end.string
  end

  def read_docx_entry(docx_data, name)
    Zip::File.open_buffer(StringIO.new(docx_data)).read(name)
  end

  def pdf_text(pdf_data)
    Pdfium::Document.open_bytes(pdf_data) do |doc|
      (0...doc.page_count).map { |index| doc.get_page(index).text }.join("\n")
    end
  end
end

RSpec.configure do |config|
  config.include TemplateFilesHelper
end
