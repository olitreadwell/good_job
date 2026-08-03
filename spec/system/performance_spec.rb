# frozen_string_literal: true

require 'rails_helper'

describe 'Performance Page', :js do
  before do
    ActiveJob::Base.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)
    page.driver.browser.page.command("Emulation.setTimezoneOverride", timezoneId: "UTC")
  end

  after do
    # Preserve Capybara's server-error check, then close Cuprite and drain again so
    # browser cleanup cannot race the shared database cleaner with a late request.
    Capybara.reset_sessions!
  ensure
    Capybara.current_session.quit
    Capybara.reset_sessions!
    ApplicationRecord.connection_pool.disconnect
  end

  it 'renders index properly' do
    ExampleJob.perform_later
    GoodJob.perform_inline

    visit good_job.root_path
    click_link 'Performance'
    expect(page).to have_css 'h2', text: 'Performance'
    expect(page).to have_content 'ExampleJob'
  end

  it 'can select and reload a chart range on the index' do
    initial_time = Time.zone.parse("2024-01-01 12:34:56 UTC")

    Timecop.freeze(initial_time) do
      ExampleJob.perform_later
      GoodJob.perform_inline

      visit good_job.performance_index_path

      expect(page).to have_link("Reload performance data", href: good_job.performance_index_path(locale: "en"))
      expect(page).to have_no_css("a.performance-range-reload.disabled")

      click_button "Open performance time ranges"
      click_link "Last 1 hour"

      expect(page).to have_current_path(/chart_range=1h/)
      expect(page).to have_css(".performance-range-key", text: "1h")
      initial_dates = endpoint_values

      Timecop.travel(initial_time + 12.seconds)
      find("a[aria-label='Reload performance data']").click

      query = Rack::Utils.parse_query(URI.parse(page.current_url).query)
      expect(query).to eq("chart_range" => "1h", "locale" => "en")
      expect(page).to have_css(".performance-range-key", text: "1h")
      expect(endpoint_values).not_to eq(initial_dates)
    end
  end

  it "converts preset index and show ranges to exact custom ranges without changing the display" do
    Timecop.freeze(Time.zone.parse("2024-01-01 12:34:56 UTC")) do
      ExampleJob.perform_later
      GoodJob.perform_inline

      exact_range = {
        chart_start: "2024-01-01T10:03:17Z",
        chart_end: "2024-01-01T11:03:17Z",
        locale: "de",
      }

      [
        good_job.performance_index_path(chart_range: "1h", **exact_range),
        good_job.performance_path("ExampleJob", chart_range: "1h", **exact_range),
      ].each do |path|
        visit path
        initial_dates = endpoint_values
        initial_chart_config = find("[data-performance-chart-config-value]")["data-performance-chart-config-value"]

        click_button "Leistungszeiträume öffnen"
        find("a.performance-range-custom").click

        query = Rack::Utils.parse_query(URI.parse(page.current_url).query)
        expect(query).to eq(exact_range.stringify_keys)
        expect(page).to have_css(".performance-range-key", text: "Benutzerdefiniert")
        expect(endpoint_values).to eq(initial_dates)
        expect(find("[data-performance-chart-config-value]")["data-performance-chart-config-value"]).to eq(initial_chart_config)
      end
    end
  end

  it "presents accessible range controls with the expected field contract and tab order" do
    with_narrow_viewport do
      visit good_job.performance_index_path

      expect(page).to have_css("#performance-range-name", text: "Performance time range", visible: :all)
      browser_time_zone = page.evaluate_script("new Intl.DateTimeFormat().resolvedOptions().timeZone")
      expect(page).to have_css("[data-performance-range-target='timeZoneLabel']", text: browser_time_zone)

      field_contract = page.evaluate_script(<<~JAVASCRIPT)
        (() => {
          const start = document.querySelector("[data-performance-range-target='startInput']")
          const end = document.querySelector("[data-performance-range-target='endInput']")
          return {
            endMaximum: end.max,
            endMinimum: end.min,
            endStep: end.step,
            startMaximum: start.max,
            startMinimum: start.min,
            startStep: start.step,
          }
        })()
      JAVASCRIPT

      expect(field_contract).to eq(
        "endMaximum" => "9999-12-31T23:59:59",
        "endMinimum" => "1000-01-01T00:00:00",
        "endStep" => "1",
        "startMaximum" => "9999-12-31T23:59:59",
        "startMinimum" => "1000-01-01T00:00:00",
        "startStep" => "1"
      )

      page.execute_script(<<~JAVASCRIPT)
        document.querySelector("[data-performance-range-target='startInput']").focus()
      JAVASCRIPT

      focus_sequence = []
      30.times do
        current_focus = page.evaluate_script(<<~JAVASCRIPT)
          document.activeElement.getAttribute("aria-label") || document.activeElement.value
        JAVASCRIPT
        focus_sequence << current_focus unless focus_sequence.last == current_focus
        break if current_focus == "Open performance time ranges"

        page.driver.browser.keyboard.type(:tab)
      end
      expect(focus_sequence).to eq(
        [
          "Start time",
          "End time",
          "Open performance time ranges",
        ]
      )
    end
  end

  it "opens the native picker from a click on the field body" do
    visit good_job.performance_index_path

    page.execute_script(<<~JAVASCRIPT)
      document.querySelector("[data-performance-range-target='startInput']").showPicker = function() {
        document.body.dataset.performancePicker = this.name
      }
    JAVASCRIPT
    find("[data-performance-range-target='startInput']").click

    expect(page.evaluate_script("document.body.dataset.performancePicker")).to eq("chart_start")
  end

  it "updates native local ranges on both performance pages" do
    Timecop.freeze(Time.zone.parse("2024-01-01 12:34:56 UTC")) do
      ExampleJob.perform_later
      GoodJob.perform_inline

      [
        good_job.performance_index_path(chart_range: "1h"),
        good_job.performance_path("ExampleJob", chart_range: "1h"),
      ].each do |path|
        visit path

        page.execute_script(<<~JAVASCRIPT)
          const start = document.querySelector("[data-performance-range-target='startInput']")
          const end = document.querySelector("[data-performance-range-target='endInput']")
          start.value = "2024-01-01T10:03:17"
          end.value = "2024-01-01T11:07:42"
          start.dispatchEvent(new Event("input", { bubbles: true }))
          end.dispatchEvent(new Event("change", { bubbles: true }))
        JAVASCRIPT

        expect(page).to have_current_path(/chart_start=/)

        query = Rack::Utils.parse_query(URI.parse(page.current_url).query)
        expect(query.keys).to contain_exactly("chart_start", "chart_end", "locale")
        expect(Time.iso8601(query.fetch("chart_start"))).to eq(Time.zone.parse("2024-01-01 10:03:17 UTC"))
        expect(Time.iso8601(query.fetch("chart_end"))).to eq(Time.zone.parse("2024-01-01 11:07:42 UTC"))
        expect(page).to have_css(".performance-range-key", text: "Custom")
      end
    end
  end

  it "renders a validation error instead of accepting crossed endpoints, since ordering is no longer enforced client-side" do
    Timecop.freeze(Time.zone.parse("2024-01-01 12:34:56 UTC")) do
      visit good_job.performance_index_path(chart_range: "1h")

      page.execute_script(<<~JAVASCRIPT)
        const start = document.querySelector("[data-performance-range-target='startInput']")
        const end = document.querySelector("[data-performance-range-target='endInput']")
        start.value = "2024-01-01T11:07:42"
        end.value = "2024-01-01T10:03:17"
        start.dispatchEvent(new Event("input", { bubbles: true }))
        end.dispatchEvent(new Event("change", { bubbles: true }))
      JAVASCRIPT

      # Turbo renders the 422 response's body without updating the address bar, matching
      # standard Rails form-validation-error behavior for a GET form.
      expect(page).to have_css(".invalid-feedback", text: "must be after the start time")
      expect(page).to have_current_path(good_job.performance_index_path(chart_range: "1h"))
      expect(page).to have_css(".performance-range-key", text: "Custom")
    end
  end

  it "keeps the widget and index axis in browser time while retaining exact canonical endpoints" do
    with_browser_time_zone("America/St_Johns") do
      visit good_job.performance_index_path(
        chart_start: "2024-01-01T10:03:17Z",
        chart_end: "2024-01-01T11:07:42Z"
      )

      browser_state = page.evaluate_script(<<~JAVASCRIPT)
        (() => {
          const start = document.querySelector("[data-performance-range-target='startInput']")
          const end = document.querySelector("[data-performance-range-target='endInput']")
          const chartElement = document.querySelector("[data-performance-chart-target='canvas']")
          const chart = Chart.getChart(chartElement)
          const metadata = JSON.parse(document.querySelector("[data-performance-chart-config-value]").dataset.performanceChartConfigValue).goodJob
          const formatter = new Intl.DateTimeFormat(document.documentElement.lang, metadata.timestamp_intl_options)

          return {
            actualChartLabel: chart.data.labels[0],
            expectedChartLabel: formatter.format(new Date(metadata.timestamps[0])),
            inputNames: [start.name, end.name],
            inputValues: [start.value, end.value],
          }
        })()
      JAVASCRIPT

      expect(page).to have_css("[data-performance-range-target='timeZoneLabel']", text: "America/St_Johns")
      expect(browser_state.fetch("actualChartLabel")).to eq(browser_state.fetch("expectedChartLabel"))
      expect(browser_state.except("actualChartLabel", "expectedChartLabel")).to eq(
        "inputNames" => %w[chart_start chart_end],
        "inputValues" => ["2024-01-01T06:33:17", "2024-01-01T07:37:42"]
      )

      page.execute_script(<<~JAVASCRIPT)
        const url = new URL(window.location.href)
        url.searchParams.set("after_at", "browser-time-navigation-marker")
        window.history.replaceState({}, "", url)

        const end = document.querySelector("[data-performance-range-target='endInput']")
        end.value = "2024-01-01T07:40:00"
        end.dispatchEvent(new Event("input", { bubbles: true }))
        end.dispatchEvent(new Event("change", { bubbles: true }))
      JAVASCRIPT

      expect(page).to have_no_current_path(/after_at=/)
      query = Rack::Utils.parse_query(URI.parse(page.current_url).query)
      expect(query).to eq(
        "chart_start" => "2024-01-01T10:03:17Z",
        "chart_end" => "2024-01-01T11:10:00Z",
        "locale" => "en"
      )
    end
  end

  it "localizes sub-minute and multi-year chart labels at their required precision" do
    examples = [
      {
        params: {
          chart_start: "2024-01-01T10:00:01Z",
          chart_end: "2024-01-01T10:00:46Z",
        },
        bucket_size: "2s",
        style: "time_seconds",
      },
      {
        params: {
          chart_start: "2004-07-01T00:00:00Z",
          chart_end: "2024-07-01T00:00:00Z",
        },
        bucket_size: "~1y",
        style: "date_time_year",
      },
    ]

    with_browser_time_zone("America/St_Johns") do
      examples.each do |example|
        visit good_job.performance_index_path(example.fetch(:params))

        label_state = page.evaluate_script(<<~JAVASCRIPT)
          (() => {
            const chartElement = document.querySelector("[data-performance-chart-target='canvas']")
            const chart = Chart.getChart(chartElement)
            const metadata = JSON.parse(document.querySelector("[data-performance-chart-config-value]").dataset.performanceChartConfigValue).goodJob

            return {
              actual: chart.data.labels[0],
              coordinateCount: metadata.timestamps.length,
              expected: new Intl.DateTimeFormat(document.documentElement.lang, metadata.timestamp_intl_options).format(new Date(metadata.timestamps[0])),
              intlOptions: metadata.timestamp_intl_options,
            }
          })()
        JAVASCRIPT

        expect(label_state.fetch("actual")).to eq(label_state.fetch("expected"))
        expect(label_state.fetch("coordinateCount")).to be <= GoodJob::PerformanceRange::MAXIMUM_TIME_SERIES_COORDINATES
        expect(label_state.fetch("intlOptions")).to eq(
          GoodJob::PerformanceRange::LABEL_STYLES.fetch(example.fetch(:style)).fetch(:intl).stringify_keys
        )
        expect(page).to have_css(
          ".performance-chart-bucket-size",
          text: "Chart bucket size: #{example.fetch(:bucket_size)}"
        )

        next unless example.fetch(:style) == "date_time_year"

        endpoint_labels = endpoint_values
        expect(endpoint_labels.first).to include("2004")
        expect(endpoint_labels.last).to include("2024")
      end
    end
  end

  it "disambiguates repeated fall-back chart ticks in browser time" do
    with_time_zone("America/New_York") do
      with_browser_time_zone("America/New_York") do
        visit good_job.performance_index_path(
          chart_start: "2024-11-03T00:45:00-04:00",
          chart_end: "2024-11-03T01:45:00-05:00"
        )

        chart_labels = page.evaluate_script(<<~JAVASCRIPT)
          Chart.getChart(document.querySelector("[data-performance-chart-target='canvas']")).data.labels
        JAVASCRIPT

        expect(chart_labels).to include("01:00 GMT-4", "01:00 GMT-5")
      end
    end
  end

  it "prepares browser-local edits submitted directly through the form" do
    with_browser_time_zone("America/St_Johns") do
      visit good_job.performance_index_path(
        chart_start: "2024-01-01T10:03:17Z",
        chart_end: "2024-01-01T11:07:42Z"
      )

      page.execute_script(<<~JAVASCRIPT)
        const url = new URL(window.location.href)
        url.searchParams.set("after_at", "direct-submit-navigation-marker")
        window.history.replaceState({}, "", url)

        const start = document.querySelector("[data-performance-range-target='startInput']")
        start.value = "2024-01-01T06:40:00"
        start.dispatchEvent(new Event("input", { bubbles: true }))
        start.form.requestSubmit()
      JAVASCRIPT

      expect(page).to have_no_current_path(/after_at=/)
      query = Rack::Utils.parse_query(URI.parse(page.current_url).query)
      expect(query).to eq(
        "chart_start" => "2024-01-01T10:10:00Z",
        "chart_end" => "2024-01-01T11:07:42Z",
        "locale" => "en"
      )
    end
  end

  it "keeps exact repeated-hour ranges continuous when their local values are not ordered" do
    with_time_zone("America/New_York") do
      with_browser_time_zone("America/New_York") do
        [
          {
            chart_range: "1h",
            chart_start: "2024-11-03T01:30:00-04:00",
            chart_end: "2024-11-03T01:30:00-05:00",
          },
          {
            chart_start: "2024-11-03T01:45:00-04:00",
            chart_end: "2024-11-03T01:15:00-05:00",
          },
        ].each do |parameters|
          visit good_job.performance_index_path(parameters)

          field_state = page.evaluate_script(<<~JAVASCRIPT)
            (() => {
              const start = document.querySelector("[data-performance-range-target='startInput']")
              const end = document.querySelector("[data-performance-range-target='endInput']")
              return {
                endMinimum: end.min,
                formValid: start.form.checkValidity(),
                startMaximum: start.max,
                values: [start.value, end.value],
              }
            })()
          JAVASCRIPT
          chart_metadata = JSON.parse(find("[data-performance-chart-config-value]")["data-performance-chart-config-value"]).fetch("goodJob")

          expect(field_state.fetch("formValid")).to be(true)
          expect(field_state.fetch("startMaximum")).to eq("9999-12-31T23:59:59")
          expect(field_state.fetch("endMinimum")).to eq("1000-01-01T00:00:00")
          expect(chart_metadata.fetch("range_start")).to eq(parameters.fetch(:chart_start))
          expect(chart_metadata.fetch("range_end")).to eq(parameters.fetch(:chart_end))
        end

        page.execute_script(<<~JAVASCRIPT)
          const url = new URL(window.location.href)
          url.searchParams.set("after_at", "fold-edit-marker")
          window.history.replaceState({}, "", url)

          const end = document.querySelector("[data-performance-range-target='endInput']")
          end.value = "2024-11-03T01:20:00"
          end.dispatchEvent(new Event("input", { bubbles: true }))
          end.dispatchEvent(new Event("change", { bubbles: true }))
        JAVASCRIPT

        expect(page).to have_no_current_path(/after_at=/)
        query = Rack::Utils.parse_query(URI.parse(page.current_url).query)
        expect(query).to eq(
          "chart_start" => "2024-11-03T01:45:00-04:00",
          "chart_end" => "2024-11-03T01:20:00-05:00",
          "locale" => "en"
        )
      end
    end
  end

  it "permits a start edit across an ordered fall-back fold range" do
    with_time_zone("America/New_York") do
      with_browser_time_zone("America/New_York") do
        visit good_job.performance_index_path(
          chart_start: "2024-11-03T00:30:00-04:00",
          chart_end: "2024-11-03T01:15:00-05:00"
        )

        initial_state = page.evaluate_script(<<~JAVASCRIPT)
          (() => {
            const start = document.querySelector("[data-performance-range-target='startInput']")
            const end = document.querySelector("[data-performance-range-target='endInput']")
            return {
              endMinimum: end.min,
              startMaximum: start.max,
              valueMilliseconds: [start.valueAsNumber, end.valueAsNumber],
            }
          })()
        JAVASCRIPT

        expect(initial_state).to eq(
          "endMinimum" => "1000-01-01T00:00:00",
          "startMaximum" => "9999-12-31T23:59:59",
          "valueMilliseconds" => [
            Time.utc(2024, 11, 3, 0, 30).to_i * 1_000,
            Time.utc(2024, 11, 3, 1, 15).to_i * 1_000,
          ]
        )

        page.execute_script(<<~JAVASCRIPT)
          const url = new URL(window.location.href)
          url.searchParams.set("after_at", "ordered-fold-navigation-marker")
          window.history.replaceState({}, "", url)

          const start = document.querySelector("[data-performance-range-target='startInput']")
          start.value = "2024-11-03T01:45:00"
          start.dispatchEvent(new Event("input", { bubbles: true }))
          start.dispatchEvent(new Event("change", { bubbles: true }))
        JAVASCRIPT

        expect(page).to have_no_current_path(/after_at=/)
        query = Rack::Utils.parse_query(URI.parse(page.current_url).query)
        expect(query).to eq(
          "chart_start" => "2024-11-03T01:45:00-04:00",
          "chart_end" => "2024-11-03T01:15:00-05:00",
          "locale" => "en"
        )
      end
    end
  end

  it "renders a validation error for a browser-local endpoint in a DST gap" do
    with_browser_time_zone("America/New_York") do
      visit good_job.performance_index_path(
        chart_start: "2024-03-10T06:00:00Z",
        chart_end: "2024-03-10T08:00:00Z"
      )

      page.execute_script(<<~JAVASCRIPT)
        const start = document.querySelector("[data-performance-range-target='startInput']")
        start.value = "2024-03-10T02:30:00"
        start.dispatchEvent(new Event("input", { bubbles: true }))
        start.dispatchEvent(new Event("change", { bubbles: true }))
      JAVASCRIPT

      # Turbo renders the 422 response's body without updating the address bar, matching
      # standard Rails form-validation-error behavior for a GET form.
      expect(page).to have_css(".invalid-feedback", text: "does not exist because of a time zone change")
      expect(page).to have_css(".performance-range-key", text: "Custom")
    end
  end

  it "keeps both endpoints in one consistent zone when only one is near the four-digit year boundary" do
    # Both zones hold a fixed, DST-free offset from UTC deep into the future, so the local year
    # each one renders for a given instant is deterministic. Pass the zone explicitly (rather than
    # relying on the global Time.zone) so this computation is independent of request-thread state.
    phoenix = ActiveSupport::TimeZone["America/Phoenix"]

    with_time_zone("America/Phoenix") do
      with_browser_time_zone("Asia/Tokyo") do
        # America/Phoenix (UTC-7) renders this instant with a year-9999 local date.
        # Asia/Tokyo (UTC+9) renders the same instant with a year-10000 local date, which falls
        # outside the four-digit year bound even though chart_start is far from any boundary.
        start_instant = Time.iso8601("9990-01-01T00:00:00Z")
        end_instant = Time.iso8601("9999-12-31T20:00:00Z")

        visit good_job.performance_index_path(
          chart_start: start_instant.iso8601,
          chart_end: end_instant.iso8601
        )

        field_state = page.evaluate_script(<<~JAVASCRIPT)
          (() => {
            const start = document.querySelector("[data-performance-range-target='startInput']")
            const end = document.querySelector("[data-performance-range-target='endInput']")
            return {
              endHasName: end.hasAttribute("name"),
              endValue: end.value,
              startHasName: start.hasAttribute("name"),
              startValue: start.value,
              timeZoneLabel: document.querySelector("[data-performance-range-target='timeZoneLabel']").textContent,
            }
          })()
        JAVASCRIPT

        expect(end_instant.in_time_zone(phoenix).year).to eq(9999)
        expect(field_state.fetch("startValue")).to eq(start_instant.in_time_zone(phoenix).strftime("%Y-%m-%dT%H:%M"))
        expect(field_state.fetch("endValue")).to eq(end_instant.in_time_zone(phoenix).strftime("%Y-%m-%dT%H:%M"))
        expect(field_state.fetch("startHasName")).to be(true)
        expect(field_state.fetch("endHasName")).to be(true)
        expect(field_state.fetch("timeZoneLabel")).to eq(phoenix.name)
      end
    end
  end

  it 'can select a custom page range by dragging the index chart' do
    Timecop.freeze(Time.zone.parse("2024-01-01 12:34:56 UTC")) do
      ExampleJob.perform_later
      GoodJob.perform_inline

      visit good_job.performance_index_path(chart_range: "1h")

      chart_config = JSON.parse(find("[data-performance-chart-config-value]")["data-performance-chart-config-value"])
      chart_metadata = chart_config.fetch("goodJob")
      timestamps = chart_metadata.fetch("timestamps")
      interval_seconds = chart_metadata.fetch("interval_seconds")
      range_start = Time.iso8601(chart_metadata.fetch("range_start"))
      range_end = Time.iso8601(chart_metadata.fetch("range_end"))
      chart_area = page.evaluate_script("Chart.getChart(document.querySelector('[data-performance-chart-target=\"canvas\"]')).chartArea")
      canvas_rect = page.evaluate_script("document.querySelector('[data-performance-chart-target=\"canvas\"]').getBoundingClientRect().toJSON()")
      y = canvas_rect.fetch("y") + ((chart_area.fetch("top") + chart_area.fetch("bottom")) / 2)
      start_x = canvas_rect.fetch("x") + chart_area.fetch("left") + 1
      end_x = canvas_rect.fetch("x") + chart_area.fetch("right") - 1

      expect(Time.iso8601(timestamps.first)).to be < range_start
      expect(Time.iso8601(timestamps.last) + interval_seconds).to be > range_end

      page.driver.browser.mouse.move(x: start_x, y: y)
      page.driver.browser.mouse.down
      page.driver.browser.mouse.move(x: end_x, y: y, steps: 5)
      page.driver.browser.mouse.up

      expect(page).to have_current_path(/chart_start=/)
      expect(page).to have_current_path(/chart_end=/)
      expect(page).to have_no_current_path(/chart_range=/)
      expect(page).to have_css(".performance-range-key", text: "Custom")

      query = Rack::Utils.parse_query(URI.parse(page.current_url).query)
      expect(Time.iso8601(query.fetch("chart_start"))).to eq(range_start)
      expect(Time.iso8601(query.fetch("chart_end"))).to eq(range_end)
    end
  end

  it "serializes an upper-edge drag without crossing the four-digit canonical boundary" do
    with_time_zone("America/Toronto") do
      expected_start = "9999-12-31T23:54:59-05:00"
      expected_end = "9999-12-31T23:59:59-05:00"
      visit good_job.performance_index_path(
        after_at: "drag-navigation-marker",
        chart_start: expected_start,
        chart_end: expected_end
      )

      chart_area = page.evaluate_script("Chart.getChart(document.querySelector('[data-performance-chart-target=\"canvas\"]')).chartArea")
      canvas_rect = page.evaluate_script("document.querySelector('[data-performance-chart-target=\"canvas\"]').getBoundingClientRect().toJSON()")
      y = canvas_rect.fetch("y") + ((chart_area.fetch("top") + chart_area.fetch("bottom")) / 2)
      start_x = canvas_rect.fetch("x") + chart_area.fetch("left") + 1
      end_x = canvas_rect.fetch("x") + chart_area.fetch("right") - 1

      page.driver.browser.mouse.move(x: start_x, y: y)
      page.driver.browser.mouse.down
      page.driver.browser.mouse.move(x: end_x, y: y, steps: 5)
      page.driver.browser.mouse.up

      expect(page).to have_no_current_path(/after_at=/)
      expect(page).to have_current_path(/chart_start=/)
      expect(page).to have_css(".performance-range-key", text: "Custom")

      query = Rack::Utils.parse_query(URI.parse(page.current_url).query)
      expect(query).to eq("chart_start" => expected_start, "chart_end" => expected_end)
      expect(query.values).to all(match(GoodJob::PerformanceRange::TIMESTAMP_PATTERN))
    end
  end

  it "shows explicit empty table states for a range without executions" do
    visit good_job.performance_index_path(
      chart_start: "2020-01-01T10:03:17Z",
      chart_end: "2020-01-01T11:07:42Z"
    )

    expect(page).to have_content("No executions in this time range.", count: 2)
  end

  it 'preserves exact preset bounds and identity on show until reload establishes a fresh window' do
    initial_time = Time.zone.parse("2024-01-01 12:34:56.500 UTC")

    Timecop.freeze(initial_time) do
      ExampleJob.perform_later
      GoodJob.perform_inline
      GoodJob::Execution.find_by!(job_class: "ExampleJob").update!(scheduled_at: initial_time - 30.minutes)

      ExampleJob.perform_later
      GoodJob.perform_inline
      GoodJob::Execution.where(job_class: "ExampleJob").order(:created_at).last!
                        .update!(scheduled_at: initial_time + 5.seconds)

      visit good_job.performance_index_path

      index_dates = endpoint_values
      index_config = JSON.parse(find("[data-performance-chart-config-value]")["data-performance-chart-config-value"])
      expected_navigation = {
        "chart_range" => "24h",
        "chart_start" => index_config.dig("goodJob", "range_start"),
        "chart_end" => index_config.dig("goodJob", "range_end"),
        "locale" => "en",
      }
      drilldown_query = Rack::Utils.parse_query(URI.parse(find(".performance-name a")[:href]).query)

      expect(drilldown_query).to eq(expected_navigation)

      Timecop.travel(initial_time + 12.seconds)
      click_link 'ExampleJob'

      show_query = Rack::Utils.parse_query(URI.parse(page.current_url).query)
      show_config = JSON.parse(find("[data-performance-chart-config-value]")["data-performance-chart-config-value"])

      expect(page).to have_css 'h2', text: 'Performance - ExampleJob'
      expect(show_query).to eq(expected_navigation)
      expect(endpoint_values).to eq(index_dates)
      expect(page).to have_css(".performance-range-key", text: "24h")
      expect(show_config.dig("data", "datasets", 0, "data").sum).to eq(1)

      find("a[aria-label='Reload performance data']").click

      expect(Rack::Utils.parse_query(URI.parse(page.current_url).query)).to eq("chart_range" => "24h", "locale" => "en")
      expect(page).to have_css(".performance-range-key", text: "24h")
      expect(endpoint_values).not_to eq(index_dates)
    end
  end

  def with_narrow_viewport
    page.current_window.resize_to(390, 844)
    yield
  ensure
    page.current_window.resize_to(1024, 800)
  end

  def with_browser_time_zone(zone_name)
    page.driver.browser.page.command("Emulation.setTimezoneOverride", timezoneId: zone_name)
    yield
  ensure
    page.driver.browser.page.command("Emulation.setTimezoneOverride", timezoneId: "UTC")
  end

  def with_time_zone(zone_name)
    original_zone = Time.zone_default
    Time.zone_default = Time.find_zone!(zone_name)
    yield
  ensure
    Time.zone_default = original_zone
  end

  def endpoint_values
    all("[data-performance-range-target='startInput'], [data-performance-range-target='endInput']").map(&:value)
  end
end
