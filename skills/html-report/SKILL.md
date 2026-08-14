---
name: html-report
description: "Produce a polished, standalone, single-file HTML report with KPI tiles, charts, tables and narrative from tabular data such as GA4, Search Console, or Google Ads exports. Use when the user wants a report he can open in a browser and share as one file - copy skills/html-report/template.html, fill the REPORT_DATA block, write the narrative, and delete unused sections."
---

# HTML report

This directory is a reusable recipe plus a finished, ready-to-fill HTML template for standalone single-file reports.
Chart.js is already inlined in the template, so copying one file is the whole setup: no build step, no install, no internet.
The result renders fully from `file://` and is safe to email or drop in a shared drive.

## Files

- `template.html` - the report scaffold: header, KPI tiles, chart sections, data-table sections, footer, CSS design tokens, and the inlined Chart.js build.
- `example/ga4-monthly-example.html` - the template genuinely filled with fictional GA4-shaped sample data; copy its patterns when in doubt.
- `assets/chart.umd.js` - the vendored Chart.js UMD build, byte-identical to the copy inlined in `template.html`.
- `assets/LICENSE.md` and `assets/VERSION` - the Chart.js MIT license and the exact version and source URL.

## When to use this skill

Use it when the user wants a report they can read in a browser and share as one file: a period review, a channel breakdown, an export made readable.
Do not use it for interactive dashboards, multi-page sites, or data that changes daily - regenerate the report instead of trying to make it live.

## The fill procedure

1. Copy `template.html` to a report name.
2. Fill the `REPORT_DATA` script block near the top of the body: `meta` (title, subtitle, date range, data source), `kpis` (the tile row), `charts` (chart specs), `tables` (standalone tables).
3. Write the narrative: the Summary paragraph and one short paragraph per section, straight into the HTML.
4. Delete the sections you do not need - each section, its canvas or table element, and its spec in `REPORT_DATA` go together.
5. Add a chart by copying a chart section, wiring its canvas to a new spec key in `REPORT_DATA.charts`, and writing one spec.
6. Open the file in a browser from `file://` and run the final checklist below.
7. When the data is not real, say so visibly in the page itself.

Never edit chart internals, the CSS design tokens, or the Chart.js block to change data.
Every report-specific number lives in `REPORT_DATA`; the header, KPI tiles, charts, fallback tables, and standalone tables are all rendered from it.

### REPORT_DATA schema

- `meta` - `title`, `subtitle`, `dateRange`, `dataSource`, optional `generated` (delete `generated` to auto-fill today's date).
- `kpis` - array of `{label, value, delta?, deltaFormat?, format?, upIsGood?}`.
  `format` is `"int"` (12 345), `"pct"` (4,2 %), `"pp"` (0,2 pp), or `"compact"` (1,2 mill.); `deltaFormat` defaults to `"pct"`.
  `upIsGood` says whether a rising delta is positive (false for example for cost); deltas always render with an arrow glyph plus sign, never color alone.
- `charts` - map of spec key to chart spec: `{type, xLabel, labels, series, format, points?, horizontal?, valueLabels?, area?, beginAtZero?}`.
  `series` is `[{name, values}]`, max 8 entries; series names must be unique.
  `series[i].color: "deemph"` renders that series in de-emphasis gray - use it when one series is the point and the rest are context.
  Supported `type` values are `"line"` and `"bar"`; `horizontal: true` makes bars horizontal; `valueLabels: true` draws the value at the bar tip.
- `tables` - map of spec key to table spec: `{columns: [{key, label, format?}], rows: [{key: value, ...}]}`.
  Columns with a `format` render right-aligned with tabular figures.

## Chart-selection rules

Pick the form by what the reader must do, before any color decision:

- A single current value is a KPI tile, never a chart.
- Compare magnitude low to high: bar chart.
- Trend over time: line chart.
- Tell distinct series apart: categorical colors.
- One series is the point and the rest are context: emphasis - one categorical hue plus de-emphasis gray for the rest.
- Above or below a baseline: diverging colors, two hues plus a neutral gray midpoint, never two cool hues.
- Part to whole: stacked bars, at most 6 segments before folding the tail into "Other".
- More than about 7 classes that all carry meaning: a table, not more colors.

Hard rules:

- Never a dual-axis chart - one y-scale per chart; two measures mean two charts.
- Categorical hues come from the fixed 8-slot palette in template order; never cycle or generate hues.
  The 9th series folds into "Other".
- Sequential encoding is one hue light to dark; diverging is two hues plus a neutral gray midpoint; never rainbow.
- A legend is always present for 2+ series and never for a single series - the chart title names the single series.
- Text - values, labels, legends, axis ticks - wears the text-color tokens, never the series color.
  Identity comes from the colored mark beside the text, never from coloring the text itself.
- Status and delta colors are reserved for good/bad meaning, are distinct from the series colors, and never carry meaning alone: pair them with a +/- sign or arrow glyph.
- A value-ramp on nominal categories (products, teams, channels) is wrong: one series means one color, every bar in slot 1.
- Too many series is solved by folding into "Other", faceting, or a table - never by inventing more hues.

## Design rules and palette

The template's `:root` custom properties are the design tokens, and the CSS block documents their roles.
The palette is validated (lightness band, chroma floor, CVD separation, normal-vision floor, contrast) as a fixed order - do not add, reorder, or restyle the categorical slots.
If you change any hex, re-validate the new palette against those checks before shipping.

Categorical slots (light theme only by captain decision 2026-08-14):

| Slot | Hue | Hex |
|------|-----|-----|
| 1 | blue | `#2a78d6` |
| 2 | orange | `#eb6834` |
| 3 | aqua | `#1baf7a` |
| 4 | yellow | `#eda100` |
| 5 | magenta | `#e87ba4` |
| 6 | green | `#008300` |
| 7 | violet | `#4a3aa7` |
| 8 | red | `#e34948` |

Sequential default hue is blue, light to dark: `#cde2fb`, `#b7d3f6`, `#9ec5f4`, `#86b6ef`, `#6da7ec`, `#5598e7`, `#3987e5`, `#2a78d6`, `#256abf`, `#1c5cab`, `#184f95`, `#104281`, `#0d366b`.
For an ordinal ramp (funnel stages, tiers), start no lighter than step `#86b6ef` so the lightest step still clears 2:1 on the surface.
The diverging pair is blue `#2a78d6` to red `#e34948` with neutral gray `#f0efec` as the midpoint, equal step count per arm.
Status colors (fixed, never themed): good `#0ca30c`, warning `#fab219`, serious `#ec835a`, critical `#d03b3b`; delta text uses `#006300` for good and `#d03b3b` for bad.
Surfaces: page plane `#f9f9f7`, chart surface `#fcfcfb`, primary ink `#0b0b0b`, secondary ink `#52514e`, muted `#898781`, gridline `#e1e0d9`, baseline `#c3c2b7`, border `rgba(11, 11, 11, 0.10)`.

Mark and layout rules:

- Lines are 2px with round join and cap; markers are at least 8px across with a 2px surface ring, and only when points are meaningful - dense series get no markers.
- Bars are at most 24px thick, rounded at the data end and square at the baseline, and grow from a single baseline.
- Gridlines and axes are solid 1px hairlines, one step off the surface; never dashed.
- Area fills are the series hue at about 10% opacity, never a saturated block.
- Label selectively - the endpoint, the extreme, the series the story is about; never a number on every point.
  The axis ticks, tooltip, and fallback table carry the rest.
- Every chart has a table-view fallback: the `<details>` element in each figure, generated from the same spec so it always matches.
- Numbers use Norwegian formatting - space as thousands separator, comma as decimal - via `Intl` `nb-NO`; always through a `format` field, never hand-formatted.
- KPI tile values use proportional figures; only columns of numbers that must align (table cells, axis ticks) use `tabular-nums`.
- The page is a centered ~960px column and never scrolls horizontally; wide tables scroll inside their own container.
- Light theme only: the body background is painted explicitly so the page stays light regardless of the reader's OS theme.

## What the template does for you

The house-defaults script in the template wraps Chart.js so agents pass minimal specs:

- `fmChart(canvas, spec)` applies the palette in fixed order, recessive hairline axes and gridlines, thin marks, rounded bar ends, legend only for 2+ series, tooltips, `maintainAspectRatio: false` inside the fixed-height figure frame, and Norwegian number formatting.
- `fmTable(host, spec)` renders any table spec, and every chart spec automatically gets its matching fallback table.
- The render driver fills the header, footer, KPI tiles, charts, and tables from `REPORT_DATA`; `fmFormat` and `fmChart` are exposed on `window` for console checks.

## Final checklist

- Offline render check: open the file from `file://` with no internet and confirm every chart drew (no blank canvases), no labels collide, and the page does not scroll horizontally.
- Palette rules respected: only the fixed slot order, no new or generated hues, no dual-axis chart, legend rules followed, text in text colors.
- Table fallback present: every chart figure still contains its `<details>` table and the numbers match the chart.
- No external requests: the HTML references no `http://`, `https://`, or protocol-relative `//` URLs in `src=`, `href=`, `url()`, or `fetch()` - only in-page anchors and comments.
- Sample data is labeled as such in the page itself when the figures are not real.

## Updating the vendored Chart.js

`assets/chart.umd.js` is the canonical copy; `template.html` inlines it byte-for-byte in the marked script block.
To update, fetch the new UMD build from the npm registry tarball (see `assets/VERSION` for the current source), replace `assets/chart.umd.js` and `assets/VERSION`, and replace the inlined copy so both stay byte-identical.
Do not edit the inlined block by hand.
