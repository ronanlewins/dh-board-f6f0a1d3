# Dark Horse — Meta Ads weekly dashboard

A single-page, mobile-first dashboard for Conor. One URL, updated each week.

- **Live URL:** https://ronanlewins.github.io/dh-board-f6f0a1d3/ (GitHub Pages)
- **Access:** **password-protected** — the page is AES-encrypted with [StatiCrypt](https://github.com/robinmoisson/staticrypt); Conor enters a shared password to unlock it. Also `noindex` + `robots.txt`. The served `index.html` is an encrypted blob — the numbers are NOT readable without the password, and no plaintext data file is served.
- **Password:** stored locally in `.staticrypt-pw` (gitignored — never committed). Change it by editing that file and re-running `./publish.sh`.
- **Source of content:** the `/meta-weekly-report` skill in the Dark Horse workspace.

## How it works

- `_src/template.html` — the dashboard markup/CSS/JS, with a `__DATA__` marker where the data gets inlined. **Committed** (no data, no secrets).
- `data/weeks.json` — all weeks, newest last, plus the top-level `cpl_bands` constant. **Gitignored** (local only) so the raw numbers never reach the public repo. The page defaults to the **most recent** week, but a week-ending **dropdown** lets Conor browse any past week; the selected week drives every card and the trend (see [Selected-week behaviour](#selected-week-behaviour)).
- `validate.py` — the **schema validator**. Fails loudly (nonzero exit) and names the offending week/field if `weeks.json` is missing any required numeric, card/band field, or has a malformed `cpl_bands`. `build.sh` runs it FIRST, so a bad schema never deploys.
- `build.sh` — the build contract (see [Build contract](#build-contract)). Validates the schema, inlines `data/weeks.json` into the template (→ `_build/index.html`), runs pre-encryption checks, encrypts with StatiCrypt using the password from `.staticrypt-pw`, then enforces a post-encryption size gate → produces the served `index.html`.
- `index.html` — the **encrypted** page (the only thing served). Regenerated every build.

## Weekly update (done by `/meta-weekly-report`)

1. Append the new week object to the `weeks` array in `data/weeks.json` and bump `updated`.
2. Build + commit + push (publish.sh runs build.sh = inline + encrypt, then pushes):
   ```bash
   cd ~/dark-horse-meta-dashboard
   ./publish.sh "week ending YYYY-MM-DD"
   ```
3. GitHub Pages redeploys in ~1 minute. The URL and password stay the same.

> Requires: Node (for `npx staticrypt`) + Python 3 (for the inline step). Both already present on this machine.

## Data schema

`data/weeks.json` has three top-level keys plus the per-week array:

```json
{
  "updated": "2026-06-29",
  "sheet_url": "https://docs.google.com/spreadsheets/d/.../edit",
  "cpl_bands": [
    { "key": "green", "max": 40,   "color": "#6f9f6a" },
    { "key": "amber", "max": 55,   "color": "#caa53d" },
    { "key": "red",   "max": null, "color": "#bd312e" }
  ],
  "ctr_bands": [
    { "key": "red",   "max": 0.7,  "color": "#bd312e" },
    { "key": "amber", "max": 1.0,  "color": "#caa53d" },
    { "key": "green", "max": null, "color": "#6f9f6a" }
  ],
  "frequency_bands": [
    { "key": "green", "max": 2.0,  "color": "#6f9f6a" },
    { "key": "amber", "max": 2.5,  "color": "#caa53d" },
    { "key": "red",   "max": null, "color": "#bd312e" }
  ],
  "weeks": [ { /* week object, see below */ } ]
}
```

### Band arrays (top-level constants): `cpl_bands`, `ctr_bands`, `frequency_bands`

The green/amber/red zone bands drawn behind the charts — `cpl_bands` behind the **cost-per-enquiry trend** AND the cost-per-enquiry card mini-graph, `ctr_bands` behind the **Click rate** card mini-graph, `frequency_bands` behind the **Audience freshness** card mini-graph. (Spend + Enquiries are volume metrics with no good/bad zone, so they get **no** bands.) Each is an **ordered, ascending array** of `{ key, max, color }`:

- `key` — string band name (non-empty).
- `max` — **inclusive upper bound** for that band, as a **number** (`int`/`float`), in the metric's own unit (EUR for cpl, % for ctr, × for frequency). Bands must be strictly ascending by `max`. The **final** band's `max` MUST be `null` (= "everything above"). There is **no `unit` field** — the unit is implied by the metric.
- `color` — hex string for the band fill (non-empty).

The chart fills each segment with its band `color`, so **direction is encoded in the colours**: for "lower is better" metrics (cpl, frequency) green is the low band; for "higher is better" metrics (ctr) green is the **top** band (so the array runs red → amber → green). The y-axis top = the last finite `max` × a headroom factor (clamped above the data max). **Thresholds are NOT hardcoded in this repo** — they are computed in the workspace from `meta-ads-benchmarks.md` and passed in: `cpl_bands` from §6 (CPL), `ctr_bands` from §3 (CTR), `frequency_bands` from §1 (Frequency). All three are constants: the weekly pipeline only changes them if those benchmark ranges change.

### Week object

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
    "audience_freshness": "1.5×",
    "audience_freshness_sub": "Each person saw the ad about 1.5 times — plenty of fresh people still to reach.",
    "audience_freshness_band": "great",
    "audience_freshness_band_label": "Great",
    "best_ad": "V1"
  },
  "metrics": { "cpl": 11.65, "ctr": 1.5, "frequency": 1.50, "enquiries": 2, "spend": 23.30 },
  "working": ["..."],
  "not_working": ["..."],
  "next_move": "One clear action in plain English."
}
```

### `metrics` (all numbers — drive the charts)

Every value in `metrics` MUST be a **number**, not a string. All five are **required** (the validator fails the build if any is missing or non-numeric). They feed the cost-per-enquiry trend line and the per-card click-to-expand mini-graphs:

| Field | Type | Notes |
|---|---|---|
| `cpl` | number | True cost per enquiry where available, else Meta CPL (EUR). |
| `ctr` | number | Link CTR as a percent value, e.g. `1.5` = 1.5%. **(added in the redesign)** |
| `frequency` | number | Week's frequency, e.g. `2.13`. Drives the audience-freshness card. **(added in the redesign)** |
| `enquiries` | number | Count of enquiries. |
| `spend` | number | EUR spent. |

### `cards` — zone bands + audience freshness

Three cards carry a colour band so Conor can scan good/bad at a glance: **cost per enquiry**, **click rate**, and **audience freshness**. Spend, enquiries, and best ad stay neutral (no band).

- `*_band` — one of `great | good | watch | high | low | poor`. Maps to colour: green (`great`/`good`), amber (`watch`), orange (`high`/`low`), red (`poor`). Set from the band the weekly report diagnoses — benchmarks live in the workspace, **do not hardcode thresholds in this repo**.
- `*_band_label` — plain-English word shown on the pill (defaults: Great / Good / Watch / Running high / Running low / Needs attention).

**Audience-freshness card (added in the redesign — the "when do we change the ad" metric):** the Frequency metric in plain English. Four required fields:

| Field | Type | Notes |
|---|---|---|
| `audience_freshness` | string | Frequency rendered `"N.N×"` (one decimal + `×`), e.g. `"2.1×"`. |
| `audience_freshness_sub` | string | Short plain-English helper sentence shown under the number. |
| `audience_freshness_band` | string | `great`/`good`/`watch`/`high`/`poor` (no `low` — frequency only fails high), from `meta-ads-benchmarks.md §1`. |
| `audience_freshness_band_label` | string | Pill word: Great / Good / Watch / Running high / Needs attention. |

### Selected-week behaviour

The page holds a single `selectedIndex` state. The week **dropdown** near the title lists every entry in `weeks` and defaults to the most recent (`selectedIndex = weeks.length - 1`). On every render:

- **Cards, headline, status, working/not-working, next move** read from `weeks[selectedIndex]` — switching the dropdown re-renders all of them from that one week.
- **The trend chart and the per-card expand mini-graphs** plot `weeks.slice(0, selectedIndex + 1)` — history *as of* the selected week, never future data. The trend's plotted-point count = `selectedIndex + 1`; the selected week's point is emphasised.

When `status` is `measurement`, the dashboard dims the band pills and appends "· early" — the colours show but read as provisional, not a verdict.

### Links

- **`video_url`** (per week) — the weekly Zoom/Loom walkthrough recording. When set, a gold "Watch this week's walkthrough" button shows at the top. Leave `""` to hide it. Ronan's weekly ritual: record a short walkthrough → paste the link here → send Conor the dashboard URL + the video plays right from it.
- **`sheet_url`** (top-level, set once) — the Google Sheet. Renders a "Open the numbers sheet →" link near the bottom + in the footer, so Conor can dig into the raw numbers himself. Access to the Sheet is controlled separately by Google sharing.

## Build contract

`build.sh` runs **five steps in this exact order** and exits nonzero (blocking `publish.sh` from pushing) if any fails:

1. **Validate** — `python3 validate.py` against `data/weeks.json`. Fails if any required numeric (`cpl`, `ctr`, `frequency`, `enquiries`, `spend`), any required card/band field (incl. the 4 audience-freshness fields), or any top-level band array (`cpl_bands`, `ctr_bands`, `frequency_bands`) is missing/malformed.
2. **Inline + render** — inline `data/weeks.json` into `_src/template.html` → `_build/index.html`.
3. **Pre-encryption checks** on `_build/index.html` — light theme present, expected card/zone markup present, and **WCAG 2.2 AA contrast** for each band number on its washed background. Abort on failure.
4. **Encrypt** — StatiCrypt `_build/index.html` (password from `.staticrypt-pw`) → served `index.html`.
5. **Post-encryption size gate** — fail if the encrypted `index.html` **> 200KB** (204800 bytes). The size check must come after encryption because the encrypted file only exists then.

`publish.sh` calls `build.sh` and pushes **only if it exited 0** — a validator/check/size failure blocks the deploy. The threshold ceiling (200KB) leaves room for the interactive JS plus years of weekly data.
