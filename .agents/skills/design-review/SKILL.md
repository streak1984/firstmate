---
name: design-review
description: Review and improve the visual quality of a web UI with measured evidence rather than impressions. Use before critiquing a design, when the captain reports that something looks wrong or unfinished, and when reviewing a crewmate's design work before it lands.
---

# design-review

This skill owns how firstmate reviews visual design quality.
[`design-directions`](../design-directions/SKILL.md) owns generating and comparing several competing directions; this skill owns judging and improving ONE design.
`bin/fm-capture.sh` owns the mechanics of serving a project and capturing verified screenshots.

Every rule below earned its place by catching a real defect, or by failing to.

## 1. Measure; never eyeball

A review that says "the spacing feels off" cannot be acted on or verified.
A review that says "content starts at x=164 in one section and x=372 in the next" can be fixed once and checked.
Measure through the browser and quote the numbers in the finding:

- **Contrast** before approving any colour pairing. A plausible-looking choice can fail outright: brand green with white text measured 3.68:1, below the 4.5:1 normal-text floor, while the alternative reached 10.68:1. The prettier option was the broken one.
- **Computed styles**, not screenshots, for colour and type. Body links that looked "a bit blue" were exactly `rgb(29, 78, 216)` - the browser default, never styled at all.
- **Element geometry** for alignment. Compare each section's left edge and container width at one viewport; a wandering edge reads as sloppiness that nobody can name.
- **Hit-testing** for interaction. A dropdown that "closes when you move to it" was a 10.4px band between trigger and menu whose `elementFromPoint` resolved to the page header - definitively outside the dropdown, so hover was lost mid-approach.
- **Rendered dimensions** against the requested viewport, always. See section 2.

## 2. Verify the evidence before you judge it

Capture tooling fails silently and in ways that look like success.
All three of these were observed on this fleet:

- A screenshot command exited 0, printed its path, and wrote **no file**. Assert every artifact exists and is non-empty.
- `resize 390 844` exited 0 and produced a **500x844** image, so an entire day of "mobile looks fine" was judged at the wrong width. Verify the PNG's real dimensions against the matrix.
- A dev server injected a **dev-toolbar overlay** into every screenshot. Capture from built static output wherever the project supports it.

`bin/fm-capture.sh` enforces all three; prefer it over ad hoc capture.
An apparent site defect may also be a capture artifact: a "stray floating element" on every page turned out to be the dev toolbar, and filing it would have wasted a round.

## 3. The checklist that actually caught things

Work top to bottom; each item below is a defect firstmate found in a real review.

**Header and navigation** - the most visible surface and the most commonly wrong.
Is it one row rather than two stacked bars?
Does it align to the same container edge as the page content?
Are dropdown indicators real icons rather than text carets (`▾`)?
Is the trigger-to-menu gap bridged by a hit-testable element inside the dropdown?
Does it work by click and keyboard, with `aria-expanded`, Escape to close, and outside-click dismissal - not hover alone?

**Hero** - dead vertical space below the call to action; images clipped at a container edge or overflowing on mobile; missing trust element the content supports.

**Alignment** - does every section share one container width and one horizontal inset, or do full-width blocks and prose disagree?

**Cards and grids** - equal heights; contained inside the container rather than bleeding past it; bottom actions aligned.

**Prose** - inline links styled in the brand palette with hover, focus and visited states; measure centred at a readable width rather than left-anchored with a large dead right margin.

**Assets** - badges, logos and illustrations constrained to a deliberate size rather than rendering at source resolution.

**Mobile** - at a genuinely verified 390px, and check that the signature move of the design is visible in the state captured; a navigation-led design is invisible in a closed-nav screenshot.

## 4. Fix the rule, not the instance

Two defects were fixed as rules - inline link styling, and how prose is centred within the container - and both then held across every page type.
Had they been fixed where they were spotted, the next round would have found the same defect elsewhere.
When a finding could recur, say so in the finding and require the rule.

## 5. Independent assessment, then reconcile

Form the mechanical findings and the visual judgement separately before combining them, so neither anchors the other.
Reconcile both against the actual captures rather than against each other.
(Concept adapted from the `critique` flow of [impeccable](https://github.com/pbakaus/impeccable), Apache-2.0.)

## 6. Deterministic checks are prompts, never gates

Automated design checkers earn a place as advisory input and lose it the moment they block.
A measured example: one flagged a plain, entirely reasonable dashboard for using Inter - taste encoded as a defect.
Treat mechanical output as review prompts, deduplicate it, and let a human or firstmate judge intent.
Never let such a checker declare a page clean either: one returned an empty result with exit 0 when its browser had failed to launch.

## 7. The questions worth asking of a design

Use these to turn "it looks unfinished" into specific findings.
(Typography, layout and pre-ship framings here are concept-level adaptations informed by [impeccable](https://github.com/pbakaus/impeccable), Apache-2.0, rewritten rather than copied.)

**Typography** - is there real hierarchy, or only size steps?
Is the display face doing any work, or is it the framework default?
Is the body measure roughly 45-75 characters?
Do line-height and letter-spacing hold at the largest and smallest sizes, not just the middle?

**Layout** - squint at it: what groups, and is that the intended grouping?
Is the spacing scale rhythmic or arbitrary?
Does the composition survive 1440, 1024 and 390 without a special case at each?

**Colour and system drift** - are there several near-identical values of the same hue competing?
Does one colour own the primary action, or do two fight for it?

**Pre-ship triage** - order findings by severity and fix in that order; a misaligned header outranks a 32px offset on one page.

## 8. Running a review round

Number the defects and describe each as evidence, consequence, and the fix, not as an adjective.
Require the worker to verify its own fix in a real browser and to look at its own screenshots.
Then **re-verify independently with the same measurement that found the defect**, and bounce the round if any listed item is still visible.
Ask for the change's own strongest and weakest point; a worker that names its trade-off is more useful than one that oversells.
Expect several rounds: a real site review took four, and each round surfaced defects the previous one had hidden.

Stop when the remaining findings are matters of taste rather than defects, and say plainly which they are.
