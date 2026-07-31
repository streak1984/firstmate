# Shared contract: {{ROUND_NAME}}

Every direction in this round obeys this contract.
Each brief names the exemplar and mandate for one direction, while this file owns the requirements shared by all builders.
Comparability is as important as quality because the captain will judge the directions side by side.

## Subject and intent

Apply one measured exemplar's design language to {{PROJECT_NAME}} and its existing content.
This is a committed design exploration, not a safe restyling exercise.
Adopt palette relationships, typographic character, hero anatomy, action treatment, density, proof placement, and section rhythm without copying the exemplar's content, imagery, logo, or copy.

Project: `{{PROJECT_PATH}}`.
Round intent: {{ROUND_INTENT}}.
Shared measured reference pack: `{{REFERENCE_PACK}}`.

## Scope

The shared change scope is {{CHANGE_SCOPE}}.
The shared inheritance and sanity-check scope is {{INHERITED_SCOPE}}.

Do not change any content or copy.
Do not change routes, URL structure, slugs, redirects, SEO output, locale structure, content schemas, or protected accessibility behavior.
The project-specific protected behavior is {{PROTECTED_BEHAVIOR}}.

## Project gates

Run these existing project checks without weakening them:

```sh
{{CHECK_COMMANDS}}
```

The expected successful result is {{CHECK_EXPECTATION}}.
Work only in the isolated task worktree and follow the project's selected delivery path.

## Direction implementation

Build only the direction in the worker's mandate.
Use the measured reference pack rather than visual impressions.
Prefer a distinctive, internally coherent result over a safe result that converges with another direction.
Keep inner surfaces sound when shared tokens or chrome affect them, but do not polish beyond the declared scope.

## Direction rationale

Write `{{DIRECTION_OUTPUT_ROOT}}/<direction-task-id>/DIRECTION.md` with these sections:

- `Essence` states the direction in one sentence.
- `What changed` reports palette, type, hero anatomy, primary action, density, and proof placement in that order with concrete values.
- `What stayed recognisable` explains which subject-specific brand elements survived and why.
- `Strongest and weakest` names the direction's strongest result and weakest tradeoff honestly.

## Capture contract

Use `{{CAPTURE_RUNNER}}` with the round's declared serve contract and view/viewport matrix.
Capture built static output when it represents the application, and use dev mode only when application runtime behavior is required.
Write the verified deliverables under `{{DIRECTION_OUTPUT_ROOT}}/<direction-task-id>/shots/`.
Inspect the captures before reporting ready and revise any direction that does not read as distinctive or contains a rendering defect.

Required matrix: `{{CAPTURE_MATRIX}}`.
Serving declaration: `{{SERVE_CONTRACT}}`.
