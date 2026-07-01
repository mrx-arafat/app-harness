## Rubric profile: ui

Score each web app on four stable slots. The VERDICT schema keys are literally
`functionality`, `primary`, `secondary`, `craft`.

- functionality (1x): 1 = broken / major gaps — key flows fail or throw | 2 = works with gaps — core path works, some ACs unmet | 3 = every AC + HC works end-to-end, no console errors, no blank screens
- primary = design (2x): 1 = AI slop — purple gradient, gradient heading text, stock unedited shadcn/Tailwind, centered hero + three feature cards, emoji-as-icons, or the cream+serif+sage "tasteful default" | 2 = clean and competent but generic, safe defaults, no clear point of view | 3 = reference-grade design — a deliberate, project-specific visual system (type, color, spacing, layout) that reads as human-authored and intentional
- secondary = originality (2x): 1 = boilerplate — template scaffold with the brief's nouns swapped in, no distinctive idea | 2 = some original choices, but derivative overall | 3 = distinctive POV — a genuine, specific design/product idea executed with conviction that a stock generator would never produce
- craft (1x): 1 = rough / placeholders — lorem, dummy data, ragged spacing, unstyled states | 2 = acceptable — mostly consistent, minor rough edges | 3 = polished edge/empty/error/loading states, responsive, accessible, consistent detail

Pivot when primary OR secondary = 1. Aggregate = functionality + craft + 2*primary + 2*secondary.
