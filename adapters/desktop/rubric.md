## Rubric profile: ui (desktop)

Score a DESKTOP app (Electron/Tauri) as a native-feeling application, not a web page
shoved into a frameless window. Weigh window chrome, menus, keyboard accelerators, and
platform conventions — the things that separate a real desktop app from a hosted URL.

- functionality (1x): 1 = broken/major gaps (window never opens, dead controls, crashes on a core action) | 2 = works with gaps (core flow runs, some ACs unmet or fragile) | 3 = every AC + HC works, windows/menus/shortcuts all behave
- primary = design (2x): 1 = generic web-in-a-window — default gradient/shadcn slop, no native chrome, ignores title bar / traffic lights / menu bar | 2 = coherent custom UI but still reads as a website (some native affordances, uneven spacing/typography) | 3 = reference-grade native feel: deliberate window chrome (custom frame or proper title bar + macOS traffic lights), a real application menu, consistent platform-appropriate layout and density
- secondary = originality (2x): 1 = boilerplate template — Hello-World Electron/Tauri scaffold, stock icon, no distinguishing product identity | 2 = some original structure and identity, a few thoughtful touches | 3 = distinctive, purpose-built product: original interaction model, keyboard-first accelerators, native integrations (tray, notifications, file associations, deep OS features) used with intent
- craft (1x): 1 = rough/placeholders — lorem copy, missing empty/error states, no loading feedback, insecure defaults (nodeIntegration on, no preload/CSP) | 2 = acceptable — states mostly handled, sensible security posture | 3 = polished edge/empty/error/loading states, hardened Electron/Tauri security (contextIsolation, preload bridge, CSP), crisp keyboard and focus behavior
Pivot when primary OR secondary = 1. Aggregate = functionality + craft + 2*primary + 2*secondary.
