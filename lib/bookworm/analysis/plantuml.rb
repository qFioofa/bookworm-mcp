# frozen_string_literal: true

module Bookworm
  module Analysis
    module Plantuml
      module_function

      def render(nodes:, edges:, title: nil, include_evidence: false)
        aliases = {}
        lines = ["@startuml", "left to right direction", "skinparam shadowing false", "skinparam defaultFontName SansSerif"]
        lines << "title #{escape(title)}" if title && !title.empty?

        nodes.each_with_index do |node, index|
          entity_id = node[:entity_id] || node[:id]
          next unless entity_id

          alias_name = "E#{index + 1}"
          aliases[entity_id] = alias_name
          label = node[:name].to_s
          type = node[:type].to_s
          mention_count = node[:mention_count]
          label = "#{label}\\n[#{type}]" unless type.empty?
          label = "#{label} (#{mention_count})" if mention_count.to_i > 1
          lines << %(card "#{escape(label)}" as #{alias_name})
        end

        edges.each do |edge|
          source = aliases[edge[:source_id] || edge[:source]]
          target = aliases[edge[:target_id] || edge[:target]]
          next unless source && target

          arrow = edge[:directed] == false ? "--" : "-->"
          predicate = edge[:predicate].to_s
          lines << "#{source} #{arrow} #{target} : #{escape(predicate)}"

          next unless include_evidence && edge[:directed] != false

          evidence = Array(edge[:evidence]).first
          next unless evidence

          citation = evidence[:citation] || evidence
          note = "#{citation[:document_title]}".to_s
          note = "#{note} p.#{citation[:page]}" if citation[:page]
          lines << "note on link : #{escape(note)}"
        end

        lines << "legend right"
        lines << "  #{escape(Bookworm::I18n.t("graph.legend"))}"
        lines << "endlegend"
        lines << "@enduml"
        lines.join("\n")
      end

      def url(source)
        require "plantuml_builder"

        encoded = PlantumlBuilder::Compressor.new(source).encode
        "https://www.plantuml.com/plantuml/svg/~1#{encoded}"
      end

      def escape(value)
        value.to_s.gsub('"', "'").gsub(/[\r\n]+/, " ").strip
      end
    end
  end
end
