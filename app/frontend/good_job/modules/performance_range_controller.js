import { Controller } from "stimulus"

// Enhances the Performance range form for display only; parsing and validation are always
// authoritative on the server (GoodJob::PerformanceRange), which surfaces real validation
// errors instead of silently falling back. This controller's only jobs are: detect the
// browser's timezone once and submit it, show the fields in that zone for readability, and
// auto-submit on change.
//
// Round-tripping exact instants through offset-less datetime-local values means an endpoint
// inside a DST fall-back repeated hour re-submits ambiguously; the server resolves starts to
// the earlier occurrence and ends to the later one (PerformanceRange#parse_local_time).
export default class extends Controller {
  static targets = ["endInput", "startInput", "timeZoneInput", "timeZoneLabel"]
  static values = {
    endTimestamp: String,
    invalid: Boolean,
    startTimestamp: String,
  }

  connect() {
    // Leave an invalid submission's redisplayed raw input, error state, and application
    // time zone untouched; switching the submitted zone under already-rendered values would
    // shift the untouched endpoint on the corrective resubmit.
    if (this.invalidValue) return

    try {
      const browserTimeZone = this.#detectBrowserTimeZone()
      const startValue = this.#browserLocalValue(this.startTimestampValue, this.startInputTarget)
      const endValue = this.#browserLocalValue(this.endTimestampValue, this.endInputTarget)
      if (!browserTimeZone || !startValue || !endValue) return

      // Commit atomically so the fields, the visible zone label, and the submitted
      // chart_time_zone always agree on one zone.
      this.startInputTarget.value = startValue
      this.endInputTarget.value = endValue
      this.timeZoneLabelTarget.textContent = browserTimeZone
      this.timeZoneInputTarget.value = browserTimeZone
      this.timeZoneInputTarget.disabled = false
    } catch (_error) {
      // Keep the server-rendered application-zone values and label when enhancement is unavailable.
    }
  }

  // Submit on every change; the server's response (canonical state or validation errors) is
  // the only feedback.
  submitRange() {
    if (!this.element.checkValidity()) return

    this.element.requestSubmit()
  }

  // Open the browser picker from a click on the rendered field when supported.
  openPicker(event) {
    const input = event.currentTarget
    if (typeof input.showPicker !== "function") return

    try {
      input.focus()
      input.showPicker()
      event.preventDefault()
    } catch (_error) {
      // Let the input's native click behavior continue when showPicker is unavailable here.
    }
  }

  #detectBrowserTimeZone() {
    try {
      return new Intl.DateTimeFormat().resolvedOptions().timeZone || null
    } catch (_error) {
      return null
    }
  }

  #browserLocalValue(timestamp, input) {
    const date = new Date(timestamp)
    if (!Number.isFinite(date.getTime())) return null

    const year = String(date.getFullYear())
    if (year.length !== 4) return null

    const value = [
      year,
      "-",
      String(date.getMonth() + 1).padStart(2, "0"),
      "-",
      String(date.getDate()).padStart(2, "0"),
      "T",
      String(date.getHours()).padStart(2, "0"),
      ":",
      String(date.getMinutes()).padStart(2, "0"),
      ":",
      String(date.getSeconds()).padStart(2, "0"),
    ].join("")

    // The input's server-rendered min/max carry PerformanceRange's portable-year bounds;
    // four-digit-year datetime-local strings compare lexicographically.
    if ((input.min && value < input.min) || (input.max && value > input.max)) return null

    return value
  }
}
