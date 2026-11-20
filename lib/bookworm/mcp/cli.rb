# frozen_string_literal: true

require "optparse"

module Bookworm
  module MCP
    module CLI
      module_function

      def start(argv)
        options = {}
        parser = OptionParser.new do |opts|
          opts.banner = Bookworm::I18n.t("cli.usage")
          opts.on("--version", Bookworm::I18n.t("cli.version")) do
            puts Bookworm::VERSION
            exit 0
          end
          opts.on("--max-inline-bytes BYTES", Integer, Bookworm::I18n.t("cli.max_inline_bytes")) do |value|
            options[:max_inline_bytes] = value
          end
          opts.on("--default-ttl SECONDS", Integer, Bookworm::I18n.t("cli.default_ttl")) do |value|
            options[:default_ttl] = value
          end
          opts.on("--locale LOCALE", Bookworm::I18n.t("cli.locale")) do |value|
            Bookworm::I18n.setup!(locale: value)
          end
          opts.on("--http", Bookworm::I18n.t("cli.http")) do
            options[:http] = true
          end
          opts.on("--[no-]https", Bookworm::I18n.t("cli.https")) do |value|
            options[:https] = value
          end
          opts.on("--host HOST", Bookworm::I18n.t("cli.host")) do |value|
            options[:host] = value
          end
          opts.on("--port PORT", Integer, Bookworm::I18n.t("cli.port")) do |value|
            options[:port] = value
          end
          opts.on("--https-port PORT", Integer, Bookworm::I18n.t("cli.https_port")) do |value|
            options[:https_port] = value
          end
          opts.on("--path PATH", Bookworm::I18n.t("cli.path")) do |value|
            options[:path] = value
          end
          opts.on("--allowed-hosts HOSTS", Bookworm::I18n.t("cli.allowed_hosts")) do |value|
            options[:allowed_hosts] = value
          end
          opts.on("--ssl-cert PATH", Bookworm::I18n.t("cli.ssl_cert")) do |value|
            options[:ssl_cert] = value
          end
          opts.on("--ssl-key PATH", Bookworm::I18n.t("cli.ssl_key")) do |value|
            options[:ssl_key] = value
          end
          opts.on("-h", "--help", Bookworm::I18n.t("cli.help")) do
            puts opts
            exit 0
          end
        end
        parser.parse!(argv)

        config = Bookworm::Config.new(**options.slice(:max_inline_bytes, :default_ttl))
        app = Bookworm::App.new(config: config)
        server = Bookworm::MCP.build_server(app)

        if options[:http]
          require_relative "http"
          Bookworm::MCP::HTTP.start(server, **http_options(options))
        else
          transport = ::MCP::Server::Transports::StdioTransport.new(server)
          transport.open
        end
      end

      def http_options(options)
        allowed_hosts = options[:allowed_hosts] || ENV["BOOKWORM_HTTP_ALLOWED_HOSTS"]
        allowed_hosts = allowed_hosts.to_s.split(",").map(&:strip).reject(&:empty?)

        {
          host: options[:host] || ENV.fetch("BOOKWORM_HTTP_HOST", Bookworm::MCP::HTTP::DEFAULT_HOST),
          port: options[:port] || env_integer("BOOKWORM_HTTP_PORT", Bookworm::MCP::HTTP::DEFAULT_PORT),
          https: options.fetch(:https, env_flag("BOOKWORM_HTTPS", true)),
          https_port: options[:https_port] || env_integer("BOOKWORM_HTTPS_PORT", Bookworm::MCP::HTTP::DEFAULT_HTTPS_PORT),
          path: options[:path] || ENV.fetch("BOOKWORM_HTTP_PATH", Bookworm::MCP::HTTP::DEFAULT_PATH),
          allowed_hosts: allowed_hosts,
          ssl_cert: options[:ssl_cert] || ENV["BOOKWORM_SSL_CERT"],
          ssl_key: options[:ssl_key] || ENV["BOOKWORM_SSL_KEY"]
        }
      end

      def env_integer(name, default)
        Integer(ENV.fetch(name, ""), exception: false) || default
      end

      def env_flag(name, default)
        value = ENV[name]
        return default if value.nil? || value.empty?

        !%w[0 false no off].include?(value.downcase)
      end
    end
  end
end
