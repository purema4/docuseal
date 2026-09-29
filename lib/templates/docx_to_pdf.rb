# frozen_string_literal: true

module Templates
  # Converts an untrusted DOCX file into PDF with a headless LibreOffice process.
  #
  # Before conversion the DOCX package is rebuilt in memory:
  # - zip bombs are rejected (entry count, per-entry and total uncompressed size limits)
  # - macro-enabled documents are rejected
  # - external relationships (linked images, remote templates, OLE links, etc.) are dropped
  # - field codes that pull remote/local content (INCLUDEPICTURE, INCLUDETEXT, LINK, DDE...) are neutralized
  # - `{{field tags}}` are moved into their own runs so the tag text can be removed from the PDF
  #   without touching surrounding text
  module DocxToPdf
    ConversionError = Class.new(StandardError)
    InvalidDocument = Class.new(StandardError)
    ConverterUnavailable = Class.new(StandardError)
    ConverterBusy = Class.new(StandardError)

    W_NS = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
    NS = { 'w' => W_NS }.freeze

    MAX_ENTRIES = 1000
    MAX_ENTRY_SIZE = 50.megabytes
    MAX_TOTAL_SIZE = 150.megabytes
    MAX_PDF_SIZE = 100.megabytes

    TIMEOUT = ENV.fetch('DOCX_CONVERSION_TIMEOUT', '60').to_i
    MAX_CONCURRENCY = ENV.fetch('DOCX_CONVERSION_CONCURRENCY', '2').to_i
    CONCURRENCY_WAIT = 30

    SEMAPHORE = Concurrent::Semaphore.new([MAX_CONCURRENCY, 1].max)

    MACRO_CONTENT_TYPES = %w[
      application/vnd.ms-word.document.macroEnabled.main+xml
      application/vnd.ms-word.template.macroEnabledTemplate.main+xml
      application/vnd.ms-office.vbaProject
    ].freeze

    DANGEROUS_FIELD_REGEXP = /\b(?:INCLUDEPICTURE|INCLUDETEXT|INCLUDE|LINK|DDE|DDEAUTO|IMPORT|DATABASE)\b/i
    URL_VALUE_REGEXP = %r{\A\s*(?:[a-z][a-z0-9+.-]*:|//|\\\\)}i
    HYPERLINK_REL_TYPE = %r{/hyperlink\z}

    WORD_XML_PART_REGEXP = %r{
      \Aword/(?:document|header\d*|footer\d*|footnotes|endnotes|comments|glossary/document)\.xml\z
    }x

    LIBREOFFICE_PROFILE = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
      <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop></item>
      <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="BlockUntrustedRefererLinks" oor:op="fuse"><value>true</value></prop></item>
      <item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="UseLocking" oor:op="fuse"><value>false</value></prop></item>
      </oor:items>
    XML

    module_function

    def call(docx_data)
      sanitized = sanitize(docx_data)

      convert(sanitized)
    end

    def available?
      soffice_path.present?
    end

    def soffice_path
      custom_path = ENV.fetch('SOFFICE_PATH', '')

      return custom_path if custom_path.present? && File.executable?(custom_path)

      %w[soffice libreoffice].each do |name|
        ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |dir|
          path = File.join(dir, name)

          return path if File.file?(path) && File.executable?(path)
        end
      end

      nil
    end

    def sanitize(docx_data)
      entries = read_entries(docx_data)

      %w[word/document.xml [Content_Types].xml].each do |name|
        raise InvalidDocument, "Invalid DOCX file: #{name} is missing" unless entries.key?(name)
      end

      if MACRO_CONTENT_TYPES.any? { |type| entries['[Content_Types].xml'].include?(type) } ||
         entries.keys.any? { |name| name.downcase.end_with?('vbaproject.bin') }
        raise InvalidDocument, 'Macro-enabled documents are not supported'
      end

      entries.each do |name, data|
        entries[name] =
          if name.end_with?('.rels')
            sanitize_rels(data)
          elsif WORD_XML_PART_REGEXP.match?(name)
            sanitize_word_xml(data)
          else
            data
          end
      end

      write_entries(entries)
    end

    def read_entries(docx_data)
      entries = {}
      total_size = 0

      Zip::File.open_buffer(StringIO.new(docx_data)) do |zip|
        raise InvalidDocument, 'DOCX file contains too many entries' if zip.size > MAX_ENTRIES

        zip.each do |entry|
          next if entry.directory?
          next unless entry.file?

          data = entry.get_input_stream { |io| io.read(MAX_ENTRY_SIZE + 1) }.to_s

          raise InvalidDocument, 'DOCX file entry is too large' if data.bytesize > MAX_ENTRY_SIZE

          total_size += data.bytesize

          raise InvalidDocument, 'DOCX file is too large when uncompressed' if total_size > MAX_TOTAL_SIZE

          entries[entry.name] = data.b
        end
      end

      entries
    rescue Zip::Error, Zip::EntrySizeError, Zlib::Error
      raise InvalidDocument, 'Invalid DOCX file'
    end

    def write_entries(entries)
      Zip::OutputStream.write_buffer(StringIO.new) do |zip|
        entries.each do |name, data|
          zip.put_next_entry(name)
          zip.write(data)
        end
      end.string
    end

    def parse_xml(data)
      Nokogiri::XML(data, nil, nil, Nokogiri::XML::ParseOptions::NONET | Nokogiri::XML::ParseOptions::STRICT)
    rescue Nokogiri::XML::SyntaxError
      raise InvalidDocument, 'Invalid DOCX file: malformed XML'
    end

    def sanitize_rels(data)
      doc = parse_xml(data)

      doc.root&.element_children&.each do |rel|
        next unless rel['TargetMode'].to_s.casecmp?('External')
        next if HYPERLINK_REL_TYPE.match?(rel['Type'].to_s)

        rel.remove
      end

      doc.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
    end

    def sanitize_word_xml(data)
      doc = parse_xml(data)

      neutralize_fields(doc)
      remove_url_attributes(doc)
      doc.xpath('//w:altChunk', NS).each(&:remove)
      isolate_tags(doc)

      doc.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
    end

    def neutralize_fields(doc)
      doc.xpath('//w:p', NS).each do |paragraph|
        instr_nodes = paragraph.xpath('.//w:instrText', NS)

        instr_nodes.each { |node| node.content = '' } if DANGEROUS_FIELD_REGEXP.match?(instr_nodes.map(&:text).join)
      end

      doc.xpath('//w:fldSimple', NS).each do |node|
        instr = node.attribute_with_ns('instr', W_NS)

        instr.value = '' if instr && DANGEROUS_FIELD_REGEXP.match?(instr.value)
      end
    end

    def remove_url_attributes(doc)
      doc.xpath('//@*[local-name()="href" or local-name()="src"]').each do |attr|
        attr.remove if URL_VALUE_REGEXP.match?(attr.value)
      end
    end

    def isolate_tags(doc)
      doc.xpath('//w:p', NS).each do |paragraph|
        text_nodes = paragraph.xpath('.//w:r/w:t', NS).select { |t| closest_paragraph(t) == paragraph }

        text = text_nodes.map(&:text).join

        next unless text.include?('{{')

        ranges = text.to_enum(:scan, FieldTags::TAG_REGEXP).map { Regexp.last_match.offset(0) }

        next if ranges.empty?

        offset = 0

        text_nodes.each do |node|
          node_text = node.text
          segments = split_segments(node_text, offset, ranges)

          offset += node_text.length

          split_run(node, segments) if segments.any? { |_, is_tag| is_tag }
        end
      end
    end

    def closest_paragraph(node)
      node.ancestors.find { |a| a.name == 'p' && a.namespace&.href == W_NS }
    end

    def split_segments(text, offset, ranges)
      segments = []

      text.each_char.with_index do |char, index|
        pos = offset + index
        is_tag = ranges.any? { |from, to| pos >= from && pos < to }

        if segments.last && segments.last[1] == is_tag
          segments.last[0] << char
        else
          segments << [+char, is_tag]
        end
      end

      segments
    end

    def split_run(text_node, segments)
      run = text_node.parent
      rpr = run.at_xpath('w:rPr', NS)
      children = run.children.to_a - [rpr]
      index = children.index(text_node)

      new_runs = []

      prefix = children[0...index]
      suffix = children[(index + 1)..]

      new_runs << build_run(run, rpr, prefix) if prefix.any?

      segments.each do |segment_text, is_tag|
        new_text_node = text_node.dup(0)
        new_text_node.namespace = text_node.namespace
        new_text_node.content = segment_text
        new_text_node['xml:space'] = 'preserve'

        new_runs << build_run(run, rpr, [new_text_node], hidden_color: is_tag)
      end

      new_runs << build_run(run, rpr, suffix) if suffix.any?

      new_runs.each { |new_run| run.add_previous_sibling(new_run) }

      run.remove
    end

    def build_run(run, rpr, children, hidden_color: false)
      new_run = run.dup(0)
      new_run.namespace = run.namespace

      new_rpr = rpr&.dup(1)

      if hidden_color
        new_rpr ||= Nokogiri::XML::Node.new('rPr', run.document).tap { |n| n.namespace = run.namespace }

        new_rpr.xpath('w:color', NS).each(&:remove)

        color = Nokogiri::XML::Node.new('color', run.document)
        color.namespace = run.namespace
        color.set_attribute('w:val', 'FFFFFF')

        new_rpr.add_child(color)
      end

      new_run.add_child(new_rpr) if new_rpr

      children.each { |child| new_run.add_child(child) }

      new_run
    end

    def convert(docx_data)
      path = soffice_path

      raise ConverterUnavailable, 'DOCX conversion is not available: LibreOffice is not installed' unless path

      raise ConverterBusy, 'DOCX conversion is busy, try again later' unless SEMAPHORE.try_acquire(1, CONCURRENCY_WAIT)

      begin
        Dir.mktmpdir('docx2pdf') do |dir|
          input_path = File.join(dir, 'document.docx')
          output_dir = File.join(dir, 'out')
          profile_dir = File.join(dir, 'profile')

          FileUtils.mkdir_p([output_dir, File.join(profile_dir, 'user')])
          File.write(File.join(profile_dir, 'user', 'registrymodifications.xcu'), LIBREOFFICE_PROFILE)
          File.binwrite(input_path, docx_data)

          run_soffice(path, dir, input_path, output_dir, profile_dir)

          output_path = File.join(output_dir, 'document.pdf')

          raise ConversionError, 'Unable to convert DOCX to PDF' unless File.exist?(output_path)
          raise ConversionError, 'Converted PDF is too large' if File.size(output_path) > MAX_PDF_SIZE

          File.binread(output_path)
        end
      ensure
        SEMAPHORE.release(1)
      end
    end

    def run_soffice(path, dir, input_path, output_dir, profile_dir)
      env = { 'HOME' => dir, 'PATH' => ENV.fetch('PATH', ''), 'LANG' => 'C.UTF-8' }

      args = [
        path, '--headless', '--invisible', '--norestore', '--nolockcheck', '--nodefault', '--nologo',
        "-env:UserInstallation=file://#{profile_dir}",
        '--convert-to', 'pdf:writer_pdf_Export', '--outdir', output_dir, input_path
      ]

      pid = spawn_unprivileged(env, args, { unsetenv_others: true, chdir: dir,
                                            in: File::NULL, out: File::NULL, err: File::NULL })

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT

      loop do
        _, status = Process.wait2(pid, Process::WNOHANG)

        if status
          raise ConversionError, 'Unable to convert DOCX to PDF' unless status.success?

          break
        end

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          kill_process_group(pid)

          raise ConversionError, 'DOCX conversion timed out'
        end

        sleep 0.1
      end
    end

    # The Docker image runs the app as root with the effective uid switched to docuseal (see config/dotenv.rb).
    # A child started in that state keeps real uid 0, so it could switch back to root, and the dynamic linker
    # runs in secure mode and refuses to load LibreOffice's bundled libraries. The child fully drops to the
    # effective user and group before starting LibreOffice.
    def spawn_unprivileged(env, args, options)
      return Process.spawn(env, *args, pgroup: true, **options) if Process.uid == Process.euid

      uid = Process.euid
      gid = Process.egid

      pid = Process.fork do
        Process.setpgid(0, 0)
        Process::Sys.seteuid(Process.uid)
        Process.groups = [gid]
        Process::Sys.setresgid(gid, gid, gid)
        Process::Sys.setresuid(uid, uid, uid)

        exec(env, *args, **options)
      rescue StandardError
        exit!(127) # rubocop:disable Rails/Exit -- a forked child must not run the parent's at_exit hooks
      end

      begin
        Process.setpgid(pid, pid)
      rescue Errno::EACCES, Errno::ESRCH
        nil
      end

      pid
    end

    def kill_process_group(pid)
      Process.kill('KILL', -pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
end
