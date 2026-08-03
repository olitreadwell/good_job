# frozen_string_literal: true

module GoodJob
  class PerformanceRange
    include ActiveModel::Validations

    PARAMETER_KEYS = %w[chart_range chart_start chart_end].freeze
    TIME_ZONE_PARAMETER_KEY = "chart_time_zone"
    INPUT_PARAMETER_KEYS = [*PARAMETER_KEYS, TIME_ZONE_PARAMETER_KEY].freeze
    DEFAULT_KEY = "24h"
    MAXIMUM_TIME_SERIES_COORDINATES = 30
    MAXIMUM_TIME_ZONE_LENGTH = 255
    # Restrict custom bounds to portable four-digit years in the timezone used by the page.
    MINIMUM_YEAR = 1000
    MAXIMUM_YEAR = 9999
    MINIMUM_LOCAL_VALUE = "1000-01-01T00:00:00"
    MAXIMUM_LOCAL_VALUE = "9999-12-31T23:59:59"
    TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/
    LOCAL_TIMESTAMP_PATTERN = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?\z/

    OPTIONS = {
      "1h" => {
        label: "1h",
        duration: 1.hour,
        interval_seconds: 5.minutes.to_i,
        label_style: "time",
      },
      "6h" => {
        label: "6h",
        duration: 6.hours,
        interval_seconds: 15.minutes.to_i,
        label_style: "time",
      },
      "24h" => {
        label: "24h",
        duration: 24.hours,
        interval_seconds: 1.hour.to_i,
        label_style: "time",
      },
      "7d" => {
        label: "7d",
        duration: 24.hours * 7,
        interval_seconds: 6.hours.to_i,
        label_style: "date_time",
      },
    }.freeze

    # Single source for how bucket timestamps render: the strftime format produces the
    # server-side application-zone labels, and the Intl::DateTimeFormat options are shipped
    # to the browser to re-render the same fields in the browser's zone.
    LABEL_STYLES = {
      "time" => {
        strftime: "%H:%M",
        intl: { hour: "2-digit", hourCycle: "h23", minute: "2-digit" },
      },
      "time_seconds" => {
        strftime: "%H:%M:%S",
        intl: { hour: "2-digit", hourCycle: "h23", minute: "2-digit", second: "2-digit" },
      },
      "date_time" => {
        strftime: "%b %-d %H:%M",
        intl: { month: "short", day: "numeric", hour: "2-digit", hourCycle: "h23", minute: "2-digit" },
      },
      "date_time_year" => {
        strftime: "%b %-d, %Y %H:%M",
        intl: { year: "numeric", month: "short", day: "numeric", hour: "2-digit", hourCycle: "h23", minute: "2-digit" },
      },
    }.freeze

    # All candidates become integer seconds. The 30-day and 365-day scales are fixed elapsed
    # durations for readable long-range charts, not calendar month or year aggregation.
    SEMANTIC_INTERVALS = [
      *[1, 2, 5, 10, 15, 30].map(&:seconds),
      *[1, 2, 5, 10, 15, 30].map(&:minutes),
      *[1, 2, 3, 6, 12].map(&:hours),
      *[1, 2, 3, 5, 7, 14].map(&:days),
      *[1, 2, 3, 6].map { |multiple| multiple * 30.days },
      *[1, 2, 5, 10, 20, 50, 100, 200, 500].map { |multiple| multiple * 365.days },
    ].map(&:to_i).uniq.sort.freeze

    attr_reader :end_time, :interval_seconds, :key, :label_style, :start_time

    validate :apply_rejections

    def initialize(params = nil, query_string: nil, **parameter_keywords)
      @rejections = {}
      @params = params || parameter_keywords
      @repeated_parameter_keys = repeated_parameter_keys(query_string)
      @local_time_zone = local_time_zone
      resolve
      valid? # eagerly populate errors so form_start_value/form_end_value are safe without caller discipline
    end

    def apply(relation)
      relation.where(scheduled_at: start_time...end_time)
    end

    def canonical_parameters?(query_parameters)
      query_parameters.slice(*INPUT_PARAMETER_KEYS) == to_params
    end

    def chart_timestamp_label(timestamp)
      timestamp.in_time_zone.strftime(label_format)
    end

    def chart_timestamp_labels(timestamps)
      labels = timestamps.map { |timestamp| chart_timestamp_label(timestamp) }

      labels.each_index.group_by { |index| labels[index] }.each_value do |indices|
        next unless indices.many?

        offsets = indices.map { |index| timestamps[index].in_time_zone.formatted_offset }
        next unless offsets.uniq.many?

        indices.zip(offsets).each do |index, offset|
          labels[index] = "#{labels[index]} #{offset}"
        end
      end

      labels
    end

    def canonical_timestamp(timestamp)
      timestamp = timestamp.in_time_zone
      # ISO 8601 cannot preserve the sub-minute historical offsets present in some IANA zones.
      timestamp.utc_offset.remainder(60).zero? ? timestamp.iso8601 : timestamp.utc.iso8601
    end

    def custom?
      key.nil?
    end

    def label_format
      LABEL_STYLES.fetch(label_style).fetch(:strftime)
    end

    def timestamp_intl_options
      LABEL_STYLES.fetch(label_style).fetch(:intl)
    end

    def custom_params
      {
        "chart_start" => canonical_timestamp(start_time),
        "chart_end" => canonical_timestamp(end_time),
      }
    end

    def default?
      to_params.empty?
    end

    def end_local_value
      local_value(end_time)
    end

    # The end endpoint's submitted text, redisplayed as-is when it was rejected; otherwise the
    # resolved (fallback) value.
    def form_end_value
      errors.messages_for(:chart_end).any? ? @params[:chart_end].to_s : end_local_value
    end

    # The start endpoint's submitted text, redisplayed as-is when it was rejected; otherwise the
    # resolved (fallback) value.
    def form_start_value
      errors.messages_for(:chart_start).any? ? @params[:chart_start].to_s : start_local_value
    end

    def navigation_params
      return to_params unless key

      # A preset is a relative definition; navigation also carries this evaluated instance.
      {
        "chart_range" => key,
        "chart_start" => canonical_timestamp(start_time),
        "chart_end" => canonical_timestamp(end_time),
      }
    end

    def options
      OPTIONS.map { |option_key, option| { key: option_key, label: option.fetch(:label) } }
    end

    def reload_params
      return to_params if custom? || default?

      { "chart_range" => key }
    end

    def start_end_binds
      [
        query_attribute("start_time", start_time, ActiveRecord::Type::DateTime.new),
        query_attribute("end_time", end_time, ActiveRecord::Type::DateTime.new),
      ]
    end

    def start_local_value
      local_value(start_time)
    end

    # Keep this order in sync with the $1/$2/$3 placeholders in PerformanceIndexChart.
    def time_series_binds
      [
        query_attribute("series_start_time", series_start_time, ActiveRecord::Type::DateTime.new),
        query_attribute("series_end_time", series_end_time, ActiveRecord::Type::DateTime.new),
        query_attribute("interval_seconds", interval_seconds, ActiveRecord::Type::Integer.new(limit: 8)),
      ]
    end

    def time_series_bucket_sql(column_name, start_expression:, interval_expression:)
      column_sql = GoodJob::Job.adapter_class.quote_column_name(column_name)

      <<~SQL.squish
        #{start_expression} +
        FLOOR(EXTRACT(EPOCH FROM (#{column_sql} - #{start_expression})) / #{interval_expression}) *
        #{interval_expression} * INTERVAL '1 second'
      SQL
    end

    def time_series_coordinate_count
      coordinate_count(interval_seconds)
    end

    def to_params
      @canonical_params.dup
    end

    private

    def align_time(time, interval = interval_seconds)
      # JRuby can misreport rational epochs for extreme years even when integer seconds are correct.
      (time - (time.to_i % interval) - time.subsec).utc
    end

    def aligned_epoch_seconds(time, interval)
      time.to_i.div(interval) * interval
    end

    def coordinate_count(interval)
      first_coordinate = aligned_epoch_seconds(start_time, interval)
      last_coordinate = aligned_epoch_seconds(end_time - Rational(1, 1_000_000), interval)

      ((last_coordinate - first_coordinate) / interval) + 1
    end

    def custom_times
      raw_start = @params[:chart_start]
      raw_end = @params[:chart_end]
      return if raw_start.nil? && raw_end.nil?

      # Both endpoints present (however invalid) means the badge/dropdown must not fall back to
      # claiming a preset identity; a lone missing endpoint is treated as no custom attempt at all.
      @custom_attempted = !raw_start.nil? && !raw_end.nil?

      reject!(:chart_start, :required) if raw_start.nil?
      reject!(:chart_end, :required) if raw_end.nil?

      parsed_start = parse_time("chart_start", raw_start)
      parsed_end = parse_time("chart_end", raw_end)
      return unless parsed_start && parsed_end
      return reject!(:chart_end, :after_start) unless parsed_start < parsed_end

      [parsed_start, parsed_end]
    end

    def custom_interval_seconds
      # Fall back to the coarsest interval rather than raising: MINIMUM_YEAR/MAXIMUM_YEAR bound the
      # widest possible range today, but nothing enforces that bound against SEMANTIC_INTERVALS.last.
      SEMANTIC_INTERVALS.find do |interval|
        coordinate_count(interval) <= MAXIMUM_TIME_SERIES_COORDINATES
      end || SEMANTIC_INTERVALS.last
    end

    def custom_label_style
      elapsed_seconds = end_time - start_time

      if elapsed_seconds >= 365.days
        "date_time_year"
      elsif elapsed_seconds >= 24.hours
        "date_time"
      elsif interval_seconds < 1.minute
        "time_seconds"
      else
        "time"
      end
    end

    def parse_time(parameter_key, value)
      return if value.nil?
      return reject!(parameter_key, :repeated) if @repeated_parameter_keys.include?(parameter_key)
      return reject!(parameter_key, :invalid) unless value.is_a?(String)

      timestamp = if TIMESTAMP_PATTERN.match?(value)
                    Time.iso8601(value)
                  elsif (local_match = LOCAL_TIMESTAMP_PATTERN.match(value))
                    parse_local_time(parameter_key, local_match)
                  end
      return reject!(parameter_key, :invalid) unless timestamp
      return reject!(parameter_key, :invalid) unless timestamp.to_f.finite?

      timestamp = timestamp.in_time_zone.change(usec: 0)
      return reject!(parameter_key, :invalid) unless timestamp.year.between?(MINIMUM_YEAR, MAXIMUM_YEAR)

      timestamp
    rescue ArgumentError, RangeError
      reject!(parameter_key, :invalid)
    end

    def repeated_parameter_keys(query_string)
      return [] if query_string.blank?

      keys = URI.decode_www_form(query_string).filter_map do |key, _value|
        key if INPUT_PARAMETER_KEYS.include?(key)
      end
      keys.tally.select { |_key, count| count > 1 }.keys
    rescue ArgumentError
      reject!(:base, :malformed)
      INPUT_PARAMETER_KEYS
    end

    # Records the first rejection reason for an attribute; later calls for the same attribute
    # are ignored so a more specific upstream reason (e.g. a DST gap) isn't overwritten by a
    # generic fallback. Returns nil so callers can `return reject!(...)`.
    def reject!(attribute, reason)
      @rejections[attribute.to_sym] ||= reason
      nil
    end

    def apply_rejections
      @rejections.each do |attribute, reason|
        errors.add(attribute, I18n.t("good_job.performance.range.errors.#{attribute}.#{reason}"))
      end
    end

    def query_attribute(name, value, type)
      ActiveRecord::Relation::QueryAttribute.new(name, value, type)
    end

    def local_value(time)
      time.in_time_zone.strftime("%Y-%m-%dT%H:%M:%S")
    end

    def parse_local_time(parameter_key, match)
      # A rejected timezone is reported once, on chart_time_zone itself; don't double-report here.
      return unless @local_time_zone

      components = match.captures
      components[-1] ||= "0"
      numeric_components = components.map { |component| Integer(component, 10) }
      local_time = Time.utc(*numeric_components)
      normalized_value = format("%04d-%02d-%02dT%02d:%02d:%02d", *numeric_components)
      return reject!(parameter_key, :invalid) unless local_time.strftime("%Y-%m-%dT%H:%M:%S") == normalized_value

      periods = @local_time_zone.tzinfo.periods_for_local(local_time)
      return reject!(parameter_key, :nonexistent) if periods.empty?

      # A local input cannot carry an offset. Include both repeated fall-back occurrences
      # by resolving starts to the earlier instant and ends to the later instant.
      instants = periods.map do |period|
        (local_time - period.utc_total_offset).in_time_zone
      end
      parameter_key == "chart_end" ? instants.max : instants.min
    end

    def local_time_zone
      return reject!(:chart_time_zone, :repeated) if @repeated_parameter_keys.include?(TIME_ZONE_PARAMETER_KEY)

      value = @params[TIME_ZONE_PARAMETER_KEY] || @params[TIME_ZONE_PARAMETER_KEY.to_sym]
      return Time.zone if value.nil?
      return reject!(:chart_time_zone, :invalid) unless value.is_a?(String) && value.bytesize <= MAXIMUM_TIME_ZONE_LENGTH
      return reject!(:chart_time_zone, :invalid) unless /\A[A-Za-z0-9._+-]+(?:\/[A-Za-z0-9._+-]+)*\z/.match?(value)

      tzinfo = TZInfo::Timezone.get(value)
      ActiveSupport::TimeZone.create(value, nil, tzinfo)
    rescue TZInfo::InvalidTimezoneIdentifier
      reject!(:chart_time_zone, :invalid)
    end

    def resolve
      range_key = preset_key

      if (times = custom_times)
        @start_time, @end_time = times

        # Do not attach a preset identity to tampered bounds with a different elapsed duration.
        if range_key && end_time - start_time == OPTIONS.fetch(range_key).fetch(:duration)
          @key = range_key
          @canonical_params = navigation_params
          options = OPTIONS.fetch(key)
        else
          @key = nil
          @canonical_params = custom_params
          @interval_seconds = custom_interval_seconds
          @label_style = custom_label_style
        end
      elsif @custom_attempted
        # Both endpoints were submitted but rejected (crossed, malformed, nonexistent, ...).
        # Fall back to the default window for chart data, but don't claim a preset identity that
        # doesn't match what was actually submitted.
        @key = nil
        options = OPTIONS.fetch(DEFAULT_KEY)
        @end_time = current_end_time
        @start_time = end_time - options.fetch(:duration)
        @canonical_params = {}
      else
        @key = range_key || DEFAULT_KEY
        options = OPTIONS.fetch(key)
        @end_time = current_end_time
        @start_time = end_time - options.fetch(:duration)
        @canonical_params = range_key ? { "chart_range" => key } : {}
      end

      return unless options

      @interval_seconds ||= options.fetch(:interval_seconds)
      @label_style = options.fetch(:label_style)
    end

    def preset_key
      return reject!(:chart_range, :repeated) if @repeated_parameter_keys.include?("chart_range")

      value = @params[:chart_range]
      return if value.nil?
      return value if value.is_a?(String) && OPTIONS.key?(value)

      reject!(:chart_range, :unknown)
    end

    def series_end_time
      align_time(end_time - Rational(1, 1_000_000))
    end

    def series_start_time
      align_time(start_time)
    end

    def current_end_time
      current_time = Time.current
      current_time.usec.zero? ? current_time : current_time.ceil
    end
  end
end
