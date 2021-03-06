# frozen_string_literal: true

require "test_prof/rspec_stamp"
require "test_prof/event_prof/instrumentations/active_support"
require "test_prof/utils/sized_ordered_set"

module TestProf
  # EventProf profiles your tests and suites against custom events,
  # such as ActiveSupport::Notifacations.
  #
  # It works very similar to `rspec --profile` but can track arbitrary events.
  #
  # Example:
  #
  #   # Collect SQL queries stats for every suite and example
  #   EVENT_PROF='sql.active_record' rspec ...
  #
  # By default it collects information only about top-level groups (aka suites),
  # but you can also profile individual examples. Just set the configuration option:
  #
  #  TestProf::EventProf.configure do |config|
  #    config.per_example = true
  #  end
  #
  # Or provide the EVENT_PROF_EXAMPLES=1 env variable.
  module EventProf
    # EventProf configuration
    class Configuration
      # Map of supported instrumenters
      INSTRUMENTERS = {
        active_support: 'ActiveSupport'
      }.freeze

      attr_accessor :instrumenter, :top_count, :per_example,
                    :rank_by, :events, :write_json

      def initialize
        @events = ENV['EVENT_PROF'].split(',')
        @instrumenter = :active_support
        @top_count = (ENV['EVENT_PROF_TOP'] || 5).to_i
        @per_example = ENV['EVENT_PROF_EXAMPLES'] == '1'
        @rank_by = (ENV['EVENT_PROF_RANK'] || :time).to_sym
        @stamp = ENV['EVENT_PROF_STAMP']
        @write_json = ENV['EVENT_PROF_WRITE_JSON']

        RSpecStamp.config.tags = @stamp if stamp?
      end

      def write_json?
        !@write_json.nil?
      end

      def stamp?
        !@stamp.nil?
      end

      def per_example?
        per_example == true
      end

      def resolve_instrumenter
        return instrumenter if instrumenter.is_a?(Module)

        raise ArgumentError, "Unknown instrumenter: #{instrumenter}" unless
          INSTRUMENTERS.key?(instrumenter)

        Instrumentations.const_get(INSTRUMENTERS[instrumenter])
      end
    end

    class << self
      def config
        @config ||= Configuration.new
      end

      def configure
        yield config
      end

      # Returns new configured instances of profilers
      def build
        config.events.map do |event|
          Profiler.new(
            event: event,
            instrumenter: config.resolve_instrumenter
          )
        end
      end
    end

    class Profiler # :nodoc:
      include TestProf::Logging

      attr_reader :event, :total_count, :total_time

      def initialize(event:, instrumenter:)
        @event = event

        log :info, "EventProf enabled (#{@event})"

        instrumenter.subscribe(event) { |time| track(time) }

        @groups = Utils::SizedOrderedSet.new(
          top_count, sort_by: rank_by
        )

        @examples = Utils::SizedOrderedSet.new(
          top_count, sort_by: rank_by
        )

        @total_count = 0
        @total_time = 0.0

        return unless config.write_json?
        TestProf.start_json(build_path('group'))
        TestProf.start_json(build_path('example')) if config.per_example?
      end

      def track(time)
        return if @current_group.nil?
        @total_time += time
        @total_count += 1

        @time += time
        @count += 1

        return if @current_example.nil?

        @example_event_time += time
        @example_count += 1
      end

      def group_started(id)
        reset_group!
        @current_group = id
      end

      def group_finished(id)
        data = { id: id, time: @time, count: @count, examples: @total_examples }

        @groups << data unless data[rank_by].zero?

        @current_group = nil

        # TODO: this is rspec-specific
        return unless config.write_json?
        data = { location: id.metadata[:location], description: id.description, time: @time, count: @count, examples: @total_examples }
        TestProf.write_json(build_path('group'), data)
      end

      def example_started(id)
        return unless config.per_example?
        reset_example!
        @current_example = id
        @example_start_time = RSpec::Core::Time.now
      end

      def example_finished(id)
        @total_examples += 1
        return unless config.per_example?

        @example_end_time = RSpec::Core::Time.now
        data = { id: id, time: @example_event_time, count: @example_count }
        @examples << data unless data[rank_by].zero?
        @current_example = nil

        # TODO: this is rspec-specific
        return unless config.write_json?
        data = { location: id.metadata[:location], description: id.description, time: @example_event_time, count: @example_count, total: @example_end_time - @example_start_time }
        TestProf.write_json(build_path('example'), data)
      end

      def suite_finished
        return unless config.write_json?
        TestProf.finish_json(build_path('group'))
        TestProf.finish_json(build_path('example')) if config.per_example?
      end

      def results
        {
          groups: @groups.to_a
        }.tap do |data|
          next unless config.per_example?

          data[:examples] = @examples.to_a
        end
      end

      def rank_by
        EventProf.config.rank_by
      end

      def top_count
        EventProf.config.top_count
      end

      private

      def build_path(mode)
        @paths ||= {}
        @paths[mode] ||= TestProf.artifact_path("event-prof-report-#{event}-#{mode}.json")
      end

      def config
        EventProf.config
      end

      def reset_group!
        @time = 0.0
        @count = 0
        @total_examples = 0
      end

      def reset_example!
        @example_count = 0
        @example_event_time = 0.0
      end
    end
  end
end

require "test_prof/event_prof/rspec" if defined?(RSpec::Core)
require "test_prof/event_prof/minitest" if defined?(Minitest)
require "test_prof/event_prof/custom_events"
