# frozen_string_literal: true

require_relative "test_helper"
require "rack/mock"
require "bookworm/mcp/http"

class HttpTest < Minitest::Test
  PROTOCOL_VERSION = "2025-11-25"

  def setup
    @app = Bookworm::App.new
    @server = Bookworm::MCP.build_server(@app)
    @rack = Bookworm::MCP::HTTP.rack_app(@server)
    @client = Rack::MockRequest.new(@rack)
  end

  def test_health_endpoint
    response = @client.get("/health")

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    assert_equal "ok", payload["status"]
    assert_equal "bookworm-mcp", payload["name"]
    assert_equal "/mcp", payload["endpoint"]
  end

  def test_mcp_endpoint_initializes_and_lists_tools
    response = post({ jsonrpc: "2.0", id: 1, method: "initialize", params: initialize_params })

    assert_equal 200, response.status
    assert_equal "application/json", response.headers["content-type"]
    assert_equal "bookworm-mcp", json(response.body).dig("result", "serverInfo", "name")

    list = post({ jsonrpc: "2.0", id: 2, method: "tools/list" })
    assert_equal 200, list.status
    names = json(list.body).dig("result", "tools").map { |tool| tool["name"] }
    assert_includes names, "search"
    assert_includes names, "ingest_text"
  end

  def test_tool_call_over_http_without_session
    response = post(
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: {
          name: "ingest_text",
          arguments: { text: "Loss aversion is a cognitive bias.", title: "HTTP text" }
        }
      }
    )

    payload = json(response.body)
    assert_equal false, payload.dig("result", "isError")
    assert_equal "HTTP text", payload.dig("result", "structuredContent", "document", "title")
  end

  def test_unknown_path_returns_not_found
    response = @client.get("/unknown")

    assert_equal 404, response.status
    assert_equal "not found\n", response.body
  end

  def test_normalizes_path
    assert_equal "/mcp", Bookworm::MCP::HTTPApp.normalize_path("mcp")
    assert_equal "/mcp", Bookworm::MCP::HTTPApp.normalize_path("/mcp/")
    assert_equal "/", Bookworm::MCP::HTTPApp.normalize_path("")
  end

  def test_url_for_hides_wildcard_bind_address
    assert_equal "http://localhost:9292/mcp", Bookworm::MCP::HTTP.url_for("http", "0.0.0.0", 9292)
    assert_equal "https://localhost:9443/mcp", Bookworm::MCP::HTTP.url_for("https", "0.0.0.0", 9443)
    assert_equal "http://127.0.0.1:9393/mcp", Bookworm::MCP::HTTP.url_for("http", "127.0.0.1", 9393)
  end

  def test_generated_self_signed_tls_context
    skip "Puma built without SSL support" unless Puma::HAS_SSL

    context = Bookworm::MCP::HTTP.ssl_context

    assert_instance_of Puma::MiniSSL::Context, context
    assert_includes context.cert_pem, "BEGIN CERTIFICATE"
    assert_includes context.key_pem, "BEGIN RSA PRIVATE KEY"
  end

  def test_ssl_context_requires_both_cert_and_key
    error = assert_raises(ArgumentError) do
      Bookworm::MCP::HTTP.ssl_context("/tmp/cert.pem", nil)
    end
    assert_match(/both ssl_cert and ssl_key/, error.message)
  end

  private

  def initialize_params
    {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "bookworm-test", version: "0.0.0" }
    }
  end

  def post(payload)
    @client.post(
      "/mcp",
      input: JSON.generate(payload),
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json, text/event-stream",
      "HTTP_MCP_PROTOCOL_VERSION" => PROTOCOL_VERSION,
      "HTTP_HOST" => "localhost"
    )
  end

  def json(body)
    JSON.parse(body)
  end
end
