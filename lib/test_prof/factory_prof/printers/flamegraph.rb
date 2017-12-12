# frozen_string_literal: true

require "json"

module TestProf::FactoryProf
  module Printers
    module Flamegraph # :nodoc: all
      class << self
        include TestProf::Logging

        def dump(result)
          return log(:info, "No factories detected") if result.raw_stats == {}
          report_data = {
            total_stacks: result.roots.size,
            total: result.roots.inject(0.0) { |memo, node| memo + (node[2] - node[1]) }
          }

          @paths = {}
          report_data[:roots] = convert(result)

          path = generate_html(report_data)

          log :info, "FactoryFlame report generated: #{path}"
        end

        def convert(result)
          result.roots.map { |tree| traverse(result, tree, nil, '') }
        end

        def traverse(result, tree, parent, path)
          sample, start_time, end_time, children = tree
          path = "#{path}/#{sample}"
          if @paths[path]
            node = @paths[path]
            node[:value] += end_time - start_time
            node[:total] += 1
          else
            node = { name: sample, value: end_time - start_time, total: 1 }
            @paths[path] = node
            if !parent.nil?
              parent[:children] ||= []
              parent[:children] << node
            end
          end

          children.each { |child| traverse(result, child, node, path) }
          node
        end

        private

        def generate_html(data)
          template = File.read(TestProf.asset_path("flamegraph.template.html"))
          template.sub! '/**REPORT-DATA**/', data.to_json

          outpath = TestProf.artifact_path("factory-flame.html")
          File.write(outpath, template)
          outpath
        end
      end
    end
  end
end
