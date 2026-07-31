---
name: design-directions
description: >-
  Run a framework-agnostic design-direction round when the captain asks to explore, compare, or choose among multiple visual directions for a web project.
user-invocable: true
metadata:
  internal: true
---

# Design directions

Use this skill when the captain asks to explore several visual design directions for a web project or invokes `/design-directions`.
This skill owns the design-round procedure.
The project remains unchanged by firstmate because ordinary isolated ship tasks produce every direction.

## Inputs and round setup

The minimum input is a resolved project plus the captain's intent.
Firstmate proposes the exemplars, per-direction mandates, scope, and view/viewport matrix unless the captain supplies any of them.
For a project firstmate has not seen before, derive a provisional view set from the sitemap, route manifest, or navigation and ask the captain to confirm it.
Do not add project-side configuration for the round.

Create `data/<round>/CONTRACT.md` from [`templates/CONTRACT.md`](templates/CONTRACT.md), replace every placeholder with project-specific current facts, and verify that no placeholder remains.
That generated file is the shared contract for every builder and the template is its single tracked owner.
Do not restate the contract in direction briefs or this procedure.

## Exemplar selection and harvest

Discover candidates through free galleries, public knowledge, direct competitors, and the subject's own sibling properties.
Do not require a paid reference subscription.
Do not use unofficial scraping services or tools whose terms are unclear.

Open every candidate in a real browser and verify that the actual visual site can be seen.
Drop a candidate that redirects to an agent-only text representation, blocks inspection, or otherwise cannot be seen well enough to measure.
Choose credible exemplars for the subject's category and audience, include at least one direct competitor when possible, and deliberately spread the design languages apart.
Reject an exemplar that occupies substantially the same visual ground as another selected direction.
Weight category proximity because the executed round's closest competitor became the chosen direction, while preserving enough spread to prevent convergence.

Dispatch one cheap-tier harvest worker for all selected exemplars.
The harvest pack must include a reference hero and supporting screenshot plus measured palette values from computed styles, font stacks and sizes, hero anatomy, CTA radius and padding, proof placement, section rhythm, and a concise cross-exemplar comparison.
Builders receive those measurements and screenshots, never only an impression such as "make it like Stripe".
An exemplar supplies a traceable design language, not its content, imagery, logo, or copy.

## Direction mandate

Write one mandate per direction with these fields:

1. `Exemplar` names and links the verified shipped site and points to its measured harvest files.
2. `Essence` states in one sentence what the direction is.
3. `Hard question` asks one specific tension this direction must resolve, such as whether the subject's brand colour survives on a dark canvas.
4. `Allowed variation` is limited to design tokens, component styling, block composition, and shared chrome.
5. `Frozen contract` points to the generated `data/<round>/CONTRACT.md` and does not repeat it.
6. `Distinctiveness` tells the builder that a committed direction which provokes a reaction is more useful than a safe direction which converges with the others.
7. `Rationale` requires `DIRECTION.md` to report concrete design values, what stayed recognisable from the subject, and the builder's honest strongest and weakest point.

The home page plus shared header and footer is the default unit of work because it is judgeable at a glance and carries the design language.
Inner pages inherit the changed system and must remain sound, but builders do not polish each one unless the round contract says otherwise.

## Build and capture phases

Run the round in this sequence:

1. Resolve the project, intent, scope, and provisional view set.
2. Select and live-verify a deliberately spread exemplar set.
3. Dispatch one cheap-tier worker to harvest every exemplar into one measured reference pack.
4. Generate the shared round contract from the template and write one mandate per direction.
5. Dispatch one strong-tier ship worker per direction in parallel isolated worktrees.
6. Require every worker to pass the project contract, write `DIRECTION.md`, and capture the same matrix through `bin/fm-capture.sh`.
7. Independently verify every expected capture before assembling the review.
8. Assemble one neutral comparison surface and present it to the captain.
9. Record the captain's decision, keep the chosen worker alive for any pre-landing revision, and land through the project's normal delivery path.
10. Preserve unchosen commits with tags, then ask separately whether their worktrees may be released.

Resolve dispatch profiles through the ordinary harness and quota rules.
Choose a cheap reasoning tier for measured harvest and extraction, and choose a strong reasoning tier for each direction build.
Do not weaken the building tier merely to save cost.
One comparison shot was sufficient for four directions in the proven round, so do not add an earlier thumbnail decision stage by default.

Declare serving and captures through the executable contract documented by `bin/fm-capture.sh --help`.
Prefer static mode after a successful build whenever the built output can actually be served without application runtime behavior.
Use dev mode only when server rendering, authentication, middleware, server routes, or equivalent behavior makes static output unrepresentative.
The standard viewports are 1440x900 and 390x844, and captures are viewport-sized rather than full-page.
The minimum comparable set is desktop hero, desktop mid-page, desktop footer, and mobile hero.
Add a capture with a preparation script for any active interactive state that carries a mandate's signature move.
A failed, missing, empty, or mid-load capture blocks the round and must never be omitted or replaced silently.

## Comparison surface

Firstmate assembles the surface with its current visual-review tooling rather than generating it through a project script.
The surface must remain neutral instead of borrowing the current site or any candidate direction's visual language.
It must be fully decidable in read-only form even when annotation is available.

Place these elements in order:

1. A named decision and an explicit statement of what remained identical across every option.
2. An at-a-glance table with one direction per column and aligned rows for canvas, display type, headline device, primary action, brand-colour treatment, proof placement, and distance from today, including inline swatches where useful.
3. One card per direction naming and linking the exemplar, stating the essence, showing a full-width desktop hero, and following it with desktop mid-page, desktop footer, mobile hero, and exemplar thumbnails.
4. The strongest and weakest point paired for every direction, plus a firstmate reservation when independent review disagrees with the builder.
5. A recommendation with reasoning and an explicit invitation to combine named elements from different preserved directions.

Do not present the surface until every commissioned direction has the same required capture set.

## Decision, adoption, and preservation

Before treating the visual review as complete, load `decision-hold-lifecycle` and apply its unresolved-decision gate.
Write `data/<round>/DECISION.md` with the captain's own words, the chosen direction and branch, the requested pre-landing revision if any, each unchosen direction with one line of reasoning, and a pointer to the comparison surface.
Mirror the outcome onto the relevant backlog items so structured state agrees with the decision record.

Keep the chosen worker alive until the captain says the decision and any requested revision are final.
Land the chosen branch through the project's selected delivery path after its normal tests and an independent rendered-result check.
After landing, install any newly declared dependency in the receiving checkout before declaring adoption complete.
Further refinement after landing is ordinary ship work, not another phase of this capability.

At round end, have the owning workers automatically create an annotated preservation tag for every unchosen tip using `design-<round-slug>/<direction-slug>`.
Verify that each tag resolves to the intended commit before asking about cleanup.
Creating and verifying the preservation tags does not authorize worktree release.
Releasing any unchosen worktree with unlanded commits requires the captain's explicit authority, even after the tag and branch make the work recoverable.

## Known gaps

- Deriving a complete view set for a project firstmate has never encountered is untested.
- Partial adoption that mixes elements across directions is untested, although a synthesis brief naming the sources is the expected next experiment.
- The evidence covers one-shot comparison at four directions and does not establish whether one shot remains sufficient above four.
