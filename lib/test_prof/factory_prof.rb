# frozen_string_literal: true

require "test_prof/factory_prof/printers/simple"
require "test_prof/factory_prof/printers/flamegraph"
require "test_prof/factory_prof/factory_builders/factory_bot"
require "test_prof/factory_prof/factory_builders/fabrication"

module TestProf
  # FactoryProf collects "factory stacks" that can be used to build
  # flamegraphs or detect most popular factories
  module FactoryProf
    FACTORY_BUILDERS = [FactoryBuilders::FactoryBot,
                        FactoryBuilders::Fabrication].freeze

    # FactoryProf configuration
    class Configuration
      attr_accessor :mode

      def initialize
        @mode =
          case ENV['FPROF']
          when 'flamegraph'
            :flamegraph
          when 'json'
            :json
          else
            :simple
          end
        @parent = @stack
      end

      # Whether we want to generate flamegraphs
      def flamegraph?
        @mode == :flamegraph
      end

      def json?
        @mode == :json
      end
    end

    class Result # :nodoc:
      attr_reader :roots, :raw_stats

      def initialize(roots, raw_stats)
        @roots = roots
        @raw_stats = raw_stats
      end

      # Returns sorted stats
      def stats
        return @stats if instance_variable_defined?(:@stats)

        @stats = @raw_stats.values
                           .sort_by { |el| -el[:total] }
      end

      def total
        return @total if instance_variable_defined?(:@total)
        @total = @raw_stats.values.sum { |v| v[:top_level_time] }
      end

      private

      def sorted_stats(key)
        @raw_stats.values
                  .map { |el| [el[:name], el[key]] }
                  .sort_by { |el| -el[1] }
      end
    end

    class << self
      include TestProf::Logging

      def config
        @config ||= Configuration.new
      end

      def configure
        yield config
      end

      # Patch factory lib, init vars
      def init
        @running = false
        @stack = []
        @nodes = []
        @roots = []

        log :info, "FactoryProf enabled (#{config.mode} mode)"

        FACTORY_BUILDERS.each(&:patch)
      end

      # Inits FactoryProf and setups at exit hook,
      # then runs
      def run
        init

        printer = config.flamegraph? ? Printers::Flamegraph : Printers::Simple

        at_exit do
          File.write(build_path(), JSON.dump(result)) if config.json?
          printer.dump(result)
        end

        start
      end

      def build_path
        @path ||= TestProf.artifact_path("factory_prof-report.json")
      end

      def start
        reset!
        @running = true
      end

      def stop
        @running = false
      end

      def result
        Result.new(@roots, @stats)
      end

      def track(factory)
        return yield unless running?

        begin
          @depth += 1
          @stats[factory][:total] += 1
          @stats[factory][:top_level] += 1 if @depth == 1

          start_time = TestProf.now

          if config.flamegraph? || config.json?
            node = [factory, start_time, nil, []]
            @nodes << node
          end

          yield
        ensure
          end_time = TestProf.now
          time = end_time - start_time

          @stats[factory][:total_time] += time
          @stats[factory][:top_level_time] += time if @depth == 1
          @depth -= 1

          return unless config.flamegraph? || config.json?

          node = @nodes.pop
          node[2] = end_time

          if @nodes.size.positive?
            parent = @nodes.pop
            parent[3] << node
            @nodes << parent
          else
            @roots << node
          end
        end
      end

      private

      def reset!
        @stack = [] if config.flamegraph? || config.json?
        @depth = 0
        @stats = Hash.new { |h, k| h[k] = { name: k, total: 0, top_level: 0, top_level_time: 0, total_time: 0 } }
      end

      def running?
        @running == true
      end
    end
  end
end

TestProf.activate('FPROF') do
  TestProf::FactoryProf.run
end
