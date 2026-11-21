# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "bookworm"
require "minitest/autorun"
require "json"
require "tmpdir"
require "zip"

module FixtureHelpers
  def with_tmpdir
    Dir.mktmpdir("bookworm-test") do |dir|
      yield dir
    end
  end

  def build_pdf(path, text: "Hello PDF text")
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " \
        "/Resources << /Font << /F1 5 0 R >> >> >>",
      nil,
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    ]
    stream = "BT /F1 24 Tf 100 700 Td (#{text}) Tj ET"
    objects[3] = "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"

    pdf = +"%PDF-1.4\n"
    offsets = [0]
    objects.each_with_index do |object, index|
      offsets << pdf.bytesize
      pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n"
    end
    xref = pdf.bytesize
    pdf << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
    offsets[1..].each { |offset| pdf << format("%010d 00000 n \n", offset) }
    pdf << "trailer << /Size #{objects.length + 1} /Root 1 0 R >>\n"
    pdf << "startxref\n#{xref}\n%%EOF\n"
    File.binwrite(path, pdf)
    path
  end

  def build_epub(path)
    files = {
      "mimetype" => "application/epub+zip",
      "META-INF/container.xml" => <<~XML,
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
      XML
      "OEBPS/content.opf" => <<~XML,
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Test Book</dc:title>
            <dc:creator>Jane Doe</dc:creator>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="toc" href="toc.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="nav"/>
            <itemref idref="toc"/>
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
          </spine>
        </package>
      XML
      "OEBPS/nav.xhtml" => <<~XML,
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>Navigation</title></head>
          <body>
            <div id="toc">
              <p><a href="ch1.xhtml">Chapter One</a></p>
              <p><a href="ch2.xhtml">Chapter Two</a></p>
            </div>
          </body>
        </html>
      XML
      "OEBPS/toc.xhtml" => <<~XML,
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>Contents</title></head>
          <body>
            <div class="contents">
              <p><a href="ch1.xhtml">Chapter One</a></p>
              <p><a href="ch1.xhtml#a">Section A</a></p>
              <p><a href="ch1.xhtml#b">Section B</a></p>
              <p><a href="ch2.xhtml">Chapter Two</a></p>
              <p><a href="ch2.xhtml#c">Section C</a></p>
            </div>
          </body>
        </html>
      XML
      "OEBPS/ch1.xhtml" => <<~XML,
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>One</title></head>
          <body>
            <h1>Chapter One</h1>
            <p>Loss aversion is a cognitive bias.</p>
            <p>People dislike losses more than gains.</p>
          </body>
        </html>
      XML
      "OEBPS/ch2.xhtml" => <<~XML
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>Two</title></head>
          <body>
            <h1>Chapter Two</h1>
            <p>For example, an investor refuses to sell a losing stock.</p>
          </body>
        </html>
      XML
    }

    File.delete(path) if File.exist?(path)
    Zip::OutputStream.open(path) do |zip|
      files.each do |name, content|
        zip.put_next_entry(name)
        zip.write(content)
      end
    end
    path
  end

  def fb2_xml
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"
                   xmlns:l="http://www.w3.org/1999/xlink">
        <description>
          <title-info>
            <book-title>Test FB2</book-title>
            <author><first-name>Ivan</first-name><last-name>Petrov</last-name></author>
            <lang>ru</lang>
            <annotation><p>Краткая аннотация.</p></annotation>
          </title-info>
        </description>
        <body>
          <section>
            <title><p>Глава 1</p></title>
            <p>Потери неприятны.</p>
            <p>Например, инвестор отказывается продавать убыточную акцию.<a l:href="#n_1" type="note">[1]</a></p>
            <section>
              <title><p>Раздел 1.1</p></title>
              <p>Подробности про потери и приобретения.</p>
            </section>
          </section>
          <section>
            <title><p>Глава 2</p></title>
            <p>Второй пример: аналитик и тимлид обсуждают сроки.</p>
          </section>
        </body>
        <body name="notes">
          <title><p>Примечания</p></title>
          <section id="n_1">
            <title><p>1</p></title>
            <p>Сноска: потеря — это субъективная реакция на убыток.</p>
          </section>
        </body>
      </FictionBook>
    XML
  end

  def build_fb2(path)
    File.write(path, fb2_xml)
    path
  end

  def build_fb2_cp1251(path)
    xml = fb2_xml.sub('encoding="utf-8"', 'encoding="windows-1251"')
    File.binwrite(path, xml.encode("Windows-1251"))
    path
  end

  def build_fb2_zip(path)
    File.delete(path) if File.exist?(path)
    Zip::OutputStream.open(path) do |zip|
      zip.put_next_entry(File.basename(path, ".zip"))
      zip.write(fb2_xml)
    end
    path
  end
end
