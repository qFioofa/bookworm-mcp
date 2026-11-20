# frozen_string_literal: true

require "openssl"
require "securerandom"
require "puma"
require_relative "http_app"

module Bookworm
  module MCP
    module HTTP
      DEFAULT_HOST = "127.0.0.1"
      DEFAULT_PORT = 9292
      DEFAULT_HTTPS_PORT = 9443
      DEFAULT_PATH = "/mcp"

      module_function

      def rack_app(server, path: DEFAULT_PATH, allowed_hosts: nil)
        HTTPApp.new(server: server, path: path, allowed_hosts: allowed_hosts)
      end

      def start(
        server,
        host: DEFAULT_HOST,
        port: DEFAULT_PORT,
        https: true,
        https_port: DEFAULT_HTTPS_PORT,
        path: DEFAULT_PATH,
        allowed_hosts: nil,
        ssl_cert: nil,
        ssl_key: nil
      )
        if https && port.to_i == https_port.to_i
          raise ArgumentError, "HTTP and HTTPS ports must differ"
        end

        app = HTTPApp.new(server: server, path: path, allowed_hosts: allowed_hosts)
        puma = ::Puma::Server.new(app)
        puma.add_tcp_listener(host, port)

        puts Bookworm::I18n.t("http.listening", url: url_for("http", host, port, path))
        if https
          context = ssl_context(ssl_cert, ssl_key)
          puts Bookworm::I18n.t("http.self_signed") unless ssl_cert && ssl_key
          puma.add_ssl_listener(host, https_port, context)
          puts Bookworm::I18n.t("http.listening", url: url_for("https", host, https_port, path))
        end
        $stdout.flush

        %w[INT TERM].each do |signal|
          Signal.trap(signal) { Thread.new { puma.stop(true) } }
        end

        puma.run.join
      end

      def url_for(scheme, host, port, path = DEFAULT_PATH)
        display_host = %w[0.0.0.0 ::].include?(host.to_s) ? "localhost" : host
        "#{scheme}://#{display_host}:#{port}#{HTTPApp.normalize_path(path)}"
      end

      def ssl_context(cert_path = nil, key_path = nil)
        unless ::Puma::HAS_SSL
          raise "Puma was built without SSL support. Install OpenSSL development headers and reinstall puma."
        end

        context = ::Puma::MiniSSL::Context.new
        context.verify_mode = ::Puma::MiniSSL::VERIFY_NONE

        if cert_path && key_path
          context.cert = cert_path
          context.key = key_path
        elsif cert_path || key_path
          raise ArgumentError, "both ssl_cert and ssl_key are required"
        else
          key, cert = self_signed_certificate
          context.key_pem = key
          context.cert_pem = cert
        end

        context
      end

      def self_signed_certificate
        key = OpenSSL::PKey::RSA.new(2048)
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = SecureRandom.random_number(2**63)
        cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
        cert.public_key = key.public_key
        cert.not_before = Time.now - 3600
        cert.not_after = Time.now + (365 * 24 * 3600)

        factory = OpenSSL::X509::ExtensionFactory.new
        factory.subject_certificate = cert
        factory.issuer_certificate = cert
        cert.add_extension(factory.create_extension("basicConstraints", "CA:FALSE", true))
        cert.add_extension(factory.create_extension("keyUsage", "digitalSignature,keyEncipherment", true))
        cert.add_extension(factory.create_extension("extendedKeyUsage", "serverAuth", false))
        cert.add_extension(factory.create_extension(
          "subjectAltName",
          "DNS:localhost,IP:127.0.0.1,IP:0:0:0:0:0:0:0:1",
          false
        ))
        cert.sign(key, OpenSSL::Digest.new("SHA256"))

        [key.to_pem, cert.to_pem]
      end
    end
  end
end
