import ChartController from "chart_controller"

const MINIMUM_RANGE_SELECTION_WIDTH = 8

// Builds an Intl.DateTimeFormat that renders a time zone name, falling back
// across the representations browsers support inconsistently.
const buildTimeZoneNameFormatter = (locale, baseOptions = {}) => {
  for (const timeZoneName of ["shortOffset", "short"]) {
    try {
      return new Intl.DateTimeFormat(locale, { ...baseOptions, timeZoneName })
    } catch (_error) {
      // Try the next supported timezone-name representation.
    }
  }

  return null
}

// Performance-page time-series charts: re-renders the server's application-zone axis labels
// in the browser's zone (the server remains the authority on which date/time fields to show,
// shipped as Intl options in the goodJob payload), and adds pointer-drag range selection.
export default class extends ChartController {
  connect() {
    this.goodJobChart = this.configValue.goodJob || {}
    super.connect()
    this.#connectRangeSelection()
  }

  disconnect() {
    this.#disconnectRangeSelection()
    super.disconnect()
  }

  chartData() {
    const {goodJob: _goodJob, ...chartData} = this.configValue
    this.#localizeTimeSeriesLabels(chartData)

    return chartData
  }

  #localizeTimeSeriesLabels(chartData) {
    if (!this.goodJobChart.time_series) return

    try {
      const timestamps = this.goodJobChart.timestamps
      const boundaryTimestamps = [this.goodJobChart.range_start, this.goodJobChart.range_end]
      const dates = [...boundaryTimestamps, ...timestamps].map(timestamp => new Date(timestamp))
      // Match PerformanceRange's portable four-digit-year bounds in the browser-local calendar.
      const representable = dates.every(date => {
        const year = date.getFullYear()
        return Number.isFinite(date.getTime()) && year >= 1000 && year <= 9999
      })
      if (!representable) return

      const formatter = new Intl.DateTimeFormat(document.documentElement.lang, this.goodJobChart.timestamp_intl_options)
      if (!formatter.resolvedOptions().timeZone) return

      const chartDates = dates.slice(boundaryTimestamps.length)
      const labels = chartDates.map(date => formatter.format(date))
      const timeZoneFormatter = buildTimeZoneNameFormatter(document.documentElement.lang)
      if (!timeZoneFormatter) {
        chartData.data.labels = labels
        return
      }

      const timeZoneNames = chartDates.map(date => this.#timeZoneName(timeZoneFormatter, date))
      const groupedIndices = labels.reduce((groups, label, index) => {
        const indices = groups.get(label) || []
        indices.push(index)
        groups.set(label, indices)
        return groups
      }, new Map())

      groupedIndices.forEach(indices => {
        if (indices.length < 2) return

        const names = indices.map(index => timeZoneNames[index]).filter(Boolean)
        if (new Set(names).size < 2) return

        indices.forEach(index => {
          if (timeZoneNames[index]) labels[index] = `${labels[index]} ${timeZoneNames[index]}`
        })
      })

      chartData.data.labels = labels
    } catch (_error) {
      // Preserve application-zone labels when browser localization is unavailable.
    }
  }

  #timeZoneName(formatter, date) {
    return formatter.formatToParts(date).find(part => part.type === "timeZoneName")?.value
  }

  #connectRangeSelection() {
    if (!this.goodJobChart.time_series || this.goodJobChart.timestamps.length < 2) return

    this.rangeSelectionPointerDown = this.#startRangeSelection.bind(this)
    this.canvasTarget.addEventListener("pointerdown", this.rangeSelectionPointerDown)
  }

  #disconnectRangeSelection() {
    if (this.rangeSelectionPointerDown) {
      this.canvasTarget.removeEventListener("pointerdown", this.rangeSelectionPointerDown)
      this.rangeSelectionPointerDown = null
    }

    this.#removeRangeSelectionEvents()
    this.#removeRangeSelectionElement()
  }

  #startRangeSelection(event) {
    if (event.button !== 0 || !this.#eventInChartArea(event)) return

    event.preventDefault()

    const position = this.#eventPosition(event)
    this.rangeSelectionStartX = position.x
    this.rangeSelectionCurrentX = position.x

    this.rangeSelectionPointerMove = this.#updateRangeSelection.bind(this)
    this.rangeSelectionPointerUp = this.#finishRangeSelection.bind(this)
    this.rangeSelectionPointerCancel = this.#cancelRangeSelection.bind(this)

    this.canvasTarget.setPointerCapture(event.pointerId)
    this.canvasTarget.addEventListener("pointermove", this.rangeSelectionPointerMove)
    this.canvasTarget.addEventListener("pointerup", this.rangeSelectionPointerUp)
    this.canvasTarget.addEventListener("pointercancel", this.rangeSelectionPointerCancel)

    this.#renderRangeSelection()
  }

  #updateRangeSelection(event) {
    this.rangeSelectionCurrentX = this.#eventPosition(event).x
    this.#renderRangeSelection()
  }

  #finishRangeSelection(event) {
    this.rangeSelectionCurrentX = this.#eventPosition(event).x
    this.#removeRangeSelectionEvents()
    this.#removeRangeSelectionElement()

    if (Math.abs(this.rangeSelectionCurrentX - this.rangeSelectionStartX) < MINIMUM_RANGE_SELECTION_WIDTH) return

    const [startParameter, endParameter] = this.#selectedRange()
    const startTime = new Date(startParameter).getTime()
    const endTime = new Date(endParameter).getTime()
    if (!startParameter || !endParameter || startTime >= endTime) return

    const url = new URL(window.location.href)
    url.searchParams.set("chart_start", startParameter)
    url.searchParams.set("chart_end", endParameter)
    url.searchParams.delete("chart_range")
    // The selected bounds carry explicit offsets, so a page-zone parameter (possibly rejected
    // on the current render) must not ride along.
    url.searchParams.delete("chart_time_zone")
    // Shed stale pagination cursors: they would pin a listing to the previous time window.
    url.searchParams.delete("after_at")
    url.searchParams.delete("after_id")

    if (window.Turbo) {
      window.Turbo.visit(url.toString())
    } else {
      window.location.assign(url.toString())
    }
  }

  #cancelRangeSelection() {
    this.#removeRangeSelectionEvents()
    this.#removeRangeSelectionElement()
  }

  #removeRangeSelectionEvents() {
    if (this.rangeSelectionPointerMove) {
      this.canvasTarget.removeEventListener("pointermove", this.rangeSelectionPointerMove)
      this.rangeSelectionPointerMove = null
    }

    if (this.rangeSelectionPointerUp) {
      this.canvasTarget.removeEventListener("pointerup", this.rangeSelectionPointerUp)
      this.rangeSelectionPointerUp = null
    }

    if (this.rangeSelectionPointerCancel) {
      this.canvasTarget.removeEventListener("pointercancel", this.rangeSelectionPointerCancel)
      this.rangeSelectionPointerCancel = null
    }
  }

  #renderRangeSelection() {
    const chartArea = this.chart.chartArea
    const startX = this.#clamp(this.rangeSelectionStartX, chartArea.left, chartArea.right)
    const currentX = this.#clamp(this.rangeSelectionCurrentX, chartArea.left, chartArea.right)
    const left = Math.min(startX, currentX)
    const width = Math.abs(currentX - startX)
    const selectionElement = this.#rangeSelectionElement()

    selectionElement.style.left = `${left}px`
    selectionElement.style.top = `${chartArea.top}px`
    selectionElement.style.width = `${width}px`
    selectionElement.style.height = `${chartArea.bottom - chartArea.top}px`
  }

  #rangeSelectionElement() {
    if (!this.selectionElement) {
      this.selectionElement = document.createElement("div")
      this.selectionElement.className = "chart-range-selection"
      this.canvasTarget.parentElement.appendChild(this.selectionElement)
    }

    return this.selectionElement
  }

  #removeRangeSelectionElement() {
    if (this.selectionElement) {
      this.selectionElement.remove()
      this.selectionElement = null
    }
  }

  #selectedRange() {
    const chartArea = this.chart.chartArea
    const startX = this.#clamp(this.rangeSelectionStartX, chartArea.left, chartArea.right)
    const currentX = this.#clamp(this.rangeSelectionCurrentX, chartArea.left, chartArea.right)
    const firstIndex = this.#timestampIndexForPixel(Math.min(startX, currentX))
    const lastIndex = this.#timestampIndexForPixel(Math.max(startX, currentX))
    const timestamps = this.goodJobChart.timestamps

    // Clamp partial edge buckets to the exact page range so drag selection cannot
    // widen the half-open interval represented by the toolbar and server query.
    const firstBucketStart = new Date(timestamps[firstIndex]).getTime()
    const rangeStart = new Date(this.goodJobChart.range_start).getTime()
    const rangeEnd = new Date(this.goodJobChart.range_end).getTime()
    const nextTimestamp = timestamps[lastIndex + 1]
    const startParameter = firstBucketStart < rangeStart ? this.goodJobChart.range_start : timestamps[firstIndex]
    const endParameter = nextTimestamp && new Date(nextTimestamp).getTime() < rangeEnd ?
      nextTimestamp : this.goodJobChart.range_end

    return [startParameter, endParameter]
  }

  #timestampIndexForPixel(pixel) {
    const chartArea = this.chart.chartArea
    const timestamps = this.goodJobChart.timestamps
    const ratio = (pixel - chartArea.left) / (chartArea.right - chartArea.left)
    const index = Math.round(ratio * (timestamps.length - 1))

    return this.#clamp(index, 0, timestamps.length - 1)
  }

  #eventInChartArea(event) {
    const position = this.#eventPosition(event)
    const chartArea = this.chart.chartArea

    return position.x >= chartArea.left &&
      position.x <= chartArea.right &&
      position.y >= chartArea.top &&
      position.y <= chartArea.bottom
  }

  #eventPosition(event) {
    return Chart.helpers.getRelativePosition(event, this.chart)
  }

  #clamp(value, min, max) {
    return Math.min(Math.max(value, min), max)
  }
}
