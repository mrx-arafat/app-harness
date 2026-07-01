## Rubric profile: ui (mobile)

Native mobile UX (iOS / Android). Score each surface as a real app screen a user would
open, tap, scroll, and rotate — not a static mockup. Judge against platform conventions,
not the web.

- functionality (1x): 1 = broken/crashes on launch, dead buttons, major ACs missing | 2 = core
  flows work but with gaps (some ACs unmet, actions no-op, data not persisted) | 3 = every
  acceptance (AC) + held-out (HC) criterion works end-to-end on a booted simulator.

- primary = Design (2x): native platform fit and visual quality.
  1 = generic web-ported boilerplate: cramped taps, system-default unstyled components, wrong
      platform metaphors, ignored spacing/typographic scale, low-contrast or clashing palette.
  2 = clean and consistent but unremarkable: correct-enough spacing and hierarchy, follows the
      obvious template, touch targets mostly adequate.
  3 = reference-grade native feel: honors iOS HIG / Material where appropriate, deliberate
      typographic scale and spacing rhythm, all interactive targets >= 44x44pt (iOS) / 48dp
      (Android), clear visual hierarchy, cohesive color/elevation system.

- secondary = Originality (2x): distinctiveness vs generic scaffolding.
  1 = indistinguishable from `expo init` / stock template: default screen, one centered list,
      no considered empty/loading/error states, web-feeling transitions.
  2 = some thoughtful choices: a custom component or two, at least one designed empty or loading
      state, a coherent but familiar layout.
  3 = distinctive and native-feeling: memorable layout/interaction choices, considered
      empty + loading + error states, animations/transitions that read as native (gesture-driven,
      shared-element, spring physics) rather than CSS-fade ports.

- craft (1x): polish of the edges a real device exposes.
  1 = rough: content under the notch/home indicator, keyboard covers inputs, no loading or error
      handling, placeholder/lorem content, janky scrolling.
  2 = acceptable: safe-area mostly respected, basic loading states, no obvious crashes on rotate.
  3 = polished: correct safe-area insets, keyboard avoidance, pull-to-refresh where expected,
      offline/loading/error states handled, platform-appropriate navigation (stack/tab/modal),
      no placeholder data.

Pivot when primary OR secondary = 1. Aggregate = functionality + craft + 2*primary + 2*secondary.
