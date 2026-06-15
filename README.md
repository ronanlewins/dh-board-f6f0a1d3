# Dark Horse — Meta Ads weekly dashboard

A single-page, mobile-first dashboard for Conor. One URL, updated each week.

- **Live URL:** _(filled in after first deploy — GitHub Pages)_
- **Access:** public but `noindex` + `robots.txt` disallow. Unguessable repo name. Anyone with the link can view; it won't show in Google.
- **Source of content:** the `/meta-weekly-report` skill in the Dark Horse workspace.

## How it works

- `index.html` — the dashboard. Vanilla HTML/CSS/JS, no build step, no dependencies. Reads `data/weeks.json` at load.
- `data/weeks.json` — all weeks, newest last. The dashboard shows the **last** entry as "this week" and draws the cost-per-enquiry trend across all entries.

## Weekly update (done by `/meta-weekly-report`)

1. Append the new week object to the `weeks` array in `data/weeks.json` and bump `updated`.
2. Commit + push:
   ```bash
   cd ~/dark-horse-meta-dashboard
   ./publish.sh "week ending YYYY-MM-DD"
   ```
3. GitHub Pages redeploys in ~1 minute. The URL stays the same.

## Week object schema

```json
{
  "week_ending": "2026-06-14",
  "week_label": "Week ending 14 Jun 2026",
  "status": "measurement | ontrack | watch | problem",
  "status_label": "Measurement window",
  "video_url": "https://zoom.us/rec/...",
  "headline": "One-line plain-English summary.",
  "days_live": 5,
  "cards": {
    "spend": "€23.30",
    "enquiries": "2",
    "enquiries_sub": "Facebook tracked 1 of 2",
    "cost_per_enquiry": "€11.65",
    "cost_per_enquiry_sub": "true cost, both enquiries",
    "cost_per_enquiry_band": "great",
    "cost_per_enquiry_band_label": "Great",
    "click_rate": "1.5%",
    "click_rate_band": "great",
    "click_rate_band_label": "Great",
    "best_ad": "V1"
  },
  "metrics": { "cpl": 11.65, "enquiries": 2, "spend": 23.30 },
  "working": ["..."],
  "not_working": ["..."],
  "next_move": "One clear action in plain English."
}
```

`metrics` holds the numeric values used to draw the trend line — keep them numbers, not strings.

### Colour bands (cost per enquiry + click rate)

Each of those two cards can carry a colour pill so Conor can scan good/bad at a glance:

- `*_band` — one of `great | good | watch | high | low | poor`. Maps to colour: green (great/good), amber (watch), orange (high/low), red (poor). Set from the band the weekly report diagnoses (benchmarks live in the workspace, not here — do not hardcode thresholds in this repo).
- `*_band_label` — optional plain-English word shown on the pill (defaults: Great / Good / Watch / Running high / Running low / Needs attention).

### Links

- **`video_url`** (per week) — the weekly Zoom/Loom walkthrough recording. When set, a gold "Watch this week's walkthrough" button shows at the top. Leave `""` to hide it. Ronan's weekly ritual: record a short walkthrough → paste the link here → send Conor the dashboard URL + the video plays right from it.
- **`sheet_url`** (top-level, set once) — the Google Sheet. Renders a "Open the numbers sheet →" link near the bottom + in the footer, so Conor can dig into the raw numbers himself. Access to the Sheet is controlled separately by Google sharing.

When `status` is `measurement`, the dashboard automatically dims the pills and appends "· early" — the colours show but read as provisional, not a verdict. Leave a band field out to show no pill.
