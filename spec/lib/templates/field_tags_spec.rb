# frozen_string_literal: true

RSpec.describe Templates::FieldTags do
  describe '.parse' do
    it 'parses a simple tag name' do
      expect(described_class.parse('Full Name')).to eq(
        'name' => 'Full Name', 'type' => 'text', 'required' => true, 'readonly' => false
      )
    end

    it 'parses all supported attributes' do
      attrs = described_class.parse(
        'Test;readonly=true;required=false;type=image;role=Signer2;width=200;height=30;default=Bob'
      )

      expect(attrs).to eq(
        'name' => 'Test', 'type' => 'image', 'role' => 'Signer2', 'required' => false, 'readonly' => true,
        'default_value' => 'Bob', 'width' => 200.0, 'height' => 30.0
      )
    end

    it 'parses select options' do
      expect(described_class.parse('Color;type=select;options=Red, Green,,Red')['options']).to eq(%w[Red Green])
    end

    it 'supports the name attribute' do
      expect(described_class.parse('name=Company;role=Buyer')).to include('name' => 'Company', 'role' => 'Buyer')
    end

    it 'infers the type from the name when the type is not set' do
      expect(described_class.parse('Signature')['type']).to eq('signature')
      expect(described_class.parse(' initials ')['type']).to eq('initials')
      expect(described_class.parse('Date')['type']).to eq('date')
      expect(described_class.parse('Signature;type=text')['type']).to eq('text')
      expect(described_class.parse('Signature Date')['type']).to eq('text')
    end

    it 'falls back to text for unknown or unsafe types' do
      expect(described_class.parse('Amount;type=payment')['type']).to eq('text')
      expect(described_class.parse('Amount;type=<script>')['type']).to eq('text')
    end

    it 'ignores invalid dimensions' do
      attrs = described_class.parse('Sig;type=signature;width=-5;height=abc')

      expect(attrs).not_to include('width', 'height')
    end

    it 'caps dimensions' do
      expect(described_class.parse('Sig;width=999999')['width']).to eq(described_class::MAX_DIMENSION)
    end

    it 'returns nil for a blank name' do
      expect(described_class.parse(' ;type=text')).to be_nil
    end

    it 'truncates long names' do
      expect(described_class.parse('a' * 400)['name'].length).to eq(described_class::MAX_NAME_LENGTH)
    end
  end

  describe '.find and .remove' do
    let(:pdf_data) do
      build_pdf([['Name: {{Full Name;role=Buyer}} end', 'Sign: {{Signature;type=signature;width=150;height=40}}'],
                 ['{{Agree;type=checkbox}}']])
    end

    it 'finds tags with their areas on every page' do
      tags = Pdfium::Document.open_bytes(pdf_data) { |doc| described_class.find(doc) }

      expect(tags.map { |t| t.attrs['name'] }).to eq(['Full Name', 'Signature', 'Agree'])
      expect(tags.map { |t| t.area['page'] }).to eq([0, 0, 1])

      name_area = tags[0].area

      expect(name_area['x']).to be_within(0.05).of(115.0 / 612)
      expect(name_area['y']).to be_within(0.03).of(80.0 / 792)
      expect(name_area['w']).to be > 0.1
      expect(name_area['h'] * 792).to be_within(0.01).of(18)

      expect(tags[1].area['w']).to be_within(0.0001).of(150.0 / 612)
      expect(tags[1].area['h']).to be_within(0.0001).of(40.0 / 792)

      checkbox_area = tags[2].area

      expect(checkbox_area['w'] * 612).to be_within(0.01).of(checkbox_area['h'] * 792)
    end

    it 'gives tag areas a minimum height so default size values fit' do
      pdf = build_pdf([['{{Name}}', '{{Sign;type=signature}}', '{{Initials}}', '{{Photo;type=image;height=20}}']])

      tags = Pdfium::Document.open_bytes(pdf) { |doc| described_class.find(doc) }
      name, sign, initials, photo = tags.map(&:area)

      name_tag_center = name['redact']['y'] + (name['redact']['h'] / 2)

      expect(name['h'] * 792).to be_within(0.01).of(18)
      expect(name['y'] + (name['h'] / 2)).to be_within(0.0001).of(name_tag_center)

      sign_tag_bottom = sign['redact']['y'] + sign['redact']['h']

      expect(sign['h'] * 792).to be_within(0.01).of(36)
      expect(sign['y'] + sign['h']).to be_within(0.0001).of(sign_tag_bottom)

      expect(initials['h'] * 792).to be_within(0.01).of(24)
      expect(photo['h'] * 792).to be_within(0.01).of(20)
    end

    it 'reads spaces from gaps between words when the PDF has no space characters' do
      doc = HexaPDF::Document.new
      canvas = doc.pages.add([0, 0, 612, 792]).canvas
      canvas.font('Helvetica', size: 12)
      canvas.text('{{Artist', at: [72, 700])
      canvas.text('Legal', at: [122, 700])
      canvas.text('Name;role=Artist}}', at: [158, 700])
      canvas.text('{{Next}}', at: [72, 660])

      io = StringIO.new
      doc.write(io)

      tags = Pdfium::Document.open_bytes(io.string) { |pdf| described_class.find(pdf) }

      expect(tags.map { |t| t.attrs['name'] }).to eq(['Artist Legal Name', 'Next'])
      expect(tags.first.attrs['role']).to eq('Artist')
      expect(tags.first.area['redact']['w'] * 612).to be > 150
    end

    it 'removes the tag text and keeps the surrounding text' do
      data = Pdfium::Document.open_bytes(pdf_data) do |doc|
        described_class.remove(doc, described_class.find(doc))

        doc.save(StringIO.new).string
      end

      text = pdf_text(data).gsub(/\s+/, '')

      expect(text).not_to include('{{')
      expect(text).not_to include('FullName')
      expect(text).to include('Name:')
      expect(text).to include('end')
      expect(text).to include('Sign:')
    end

    it 'redraws the text around a tag with the original font' do
      data = build_pdf([['Name: {{Full Name}} end']], font: 'Times')

      data = Pdfium::Document.open_bytes(data) do |doc|
        described_class.remove(doc, described_class.find(doc))

        doc.save(StringIO.new).string
      end

      fonts = HexaPDF::Document.new(io: StringIO.new(data)).pages[0].resources[:Font]
      base_fonts = fonts.each.map { |_, font| font[:BaseFont].to_s }

      expect(pdf_text(data).gsub(/\s+/, '')).to eq('Name:end')
      expect(base_fonts).to all(include('Times'))
    end
  end
end
