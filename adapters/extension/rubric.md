## Rubric profile: ui (browser/Chrome extension)

- functionality (1x): 1 = extension fails to load, popup/options/background broken, or major AC/HC gaps | 2 = core flow works but some AC/HC gaps or rough edges | 3 = every AC + HC works — popup, options, background, and content-script behavior all verified live

- primary = design (2x): 1 = default unstyled popup/options, clashing with native browser chrome, generic icon/no icon, AI-slop tells (purple gradients, emoji-as-icons, lorem placeholder copy) | 2 = coherent, readable UI that respects extension-popup size constraints and looks intentional, but generic/templated | 3 = reference-grade — a crisp toolbar icon, a popup/options UI that feels native to the browser (correct density, no unbounded scrolling/clipping in the ~360-600px popup viewport), thoughtful empty/loading/error states, no AI-slop tells

- secondary = originality (2x): 1 = boilerplate "todo-list"/"hello world" clone with no distinct value proposition, permissions grossly overreaching the stated purpose | 2 = a real feature idea, permissions roughly match what the extension does | 3 = a distinctive, well-scoped extension — permissions are minimal and justified by the manifest's declared purpose, the interaction model (popup vs. options vs. content-script injection vs. background automation) is a deliberate design choice, not just "whatever scaffold produced"

- craft (1x): 1 = rough/placeholder icons, unhandled errors surface as blank popups or silent failures, console errors on load | 2 = acceptable polish, most error/empty states handled | 3 = polished edge-case handling — options save confirmation, popup loading/error states, background service worker survives being woken/terminated by the browser, content-script failures degrade gracefully without breaking the host page

Pivot when primary OR secondary = 1. Aggregate = functionality + craft + 2*primary + 2*secondary.

### Extension-specific anti-gaming notes for the Evaluator

- A popup that only renders because a build step inlined broken JS (console errors present) is NOT functionality=3, even if the screenshot looks fine — cross-check `probe.json` `consoleErrorsTotal` and each surface's `errors[]`.
- `host_permissions: ["<all_urls>"]` or `permissions: ["*://*/*"]` without a manifest-purpose justification is a `secondary` (originality/robustness) pivot signal, not just a craft nitpick — check `slop.json` for `extension-broad-permissions` hits.
- A background service worker that never registers (see `probe.json` surface `kind:"background"` status) is a functionality failure, not a craft nitpick, even if the popup alone looks polished.
