# frozen_string_literal: true

require_relative "lib/bookworm/version"

Gem::Specification.new do |spec|
  spec.name = "bookworm-mcp"
  spec.version = Bookworm::VERSION
  spec.authors = ["Bookworm contributors"]
  spec.summary = "Local-first MCP server for analytical book search"
  spec.description = "Search books and text fragments through MCP. " \
                     "Returns evidence-backed passages, citations, outlines, " \
                     "a rule-based entity graph, and cases. " \
                     "No storage, no evaluation, no generation."
  spec.homepage = "https://github.com/qFioofa/bookworm-mcp"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "lib/**/*.yml", "bin/*", "README.md", "LICENSE"]
  spec.bindir = "bin"
  spec.executables = ["bookworm-mcp"]
  spec.require_paths = ["lib"]

  spec.add_dependency "mcp", "~> 1.11"
  spec.add_dependency "rack", "~> 3.2"
  spec.add_dependency "puma", ">= 6"
  spec.add_dependency "pdf-reader", "~> 2.12"
  spec.add_dependency "rubyzip", "~> 2.3"
  spec.add_dependency "rexml", "~> 3.3"
  spec.add_dependency "base64", ">= 0.2"
  spec.add_dependency "rgl", "~> 0.6"
  spec.add_dependency "plantuml_builder", "~> 0.3"
  spec.add_dependency "i18n", "~> 1.14"
  spec.add_dependency "rake-text", "~> 1.0"

  spec.add_development_dependency "minitest", "~> 5.20"
  spec.add_development_dependency "rake", "~> 13.0"
end
