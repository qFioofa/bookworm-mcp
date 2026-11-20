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
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
          </spine>
        </package>
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

  def build_fb2(path)
    File.write(path, <<~XML)
      <?xml version="1.0" encoding="utf-8"?>
      <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
        <description>
          <title-info>
            <book-title>Test FB2</book-title>
            <author><first-name>Ivan</first-name><last-name>Petrov</last-name></author>
            <lang>ru</lang>
          </title-info>
        </description>
        <body>
          <section>
            <title><p>Глава 1</p></title>
            <p>Потери неприятны.</p>
            <p>Например, инвестор отказывается продавать убыточную акцию.</p>
          </section>
        </body>
      </FictionBook>
    XML
    path
  end
end
