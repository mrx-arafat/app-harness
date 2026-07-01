## Rubric profile: cli

- functionality (1x): 1 = broken/major gaps — core commands error or do nothing | 2 = works with gaps — happy path only, some ACs unmet | 3 = every AC + HC works — all documented invocations behave correctly
- primary = ergonomics/DX (2x): 1 = no or wrong `--help`, cryptic flags, silent or noisy failures, undiscoverable | 2 = has help text and usable flags but rough (inconsistent naming, thin errors) | 3 = reference-grade — clear `--help`/usage, sane consistent flag design, actionable error messages, discoverable subcommands and exit-code conventions
- secondary = robustness (2x): 1 = crashes on bad/missing args, wrong or always-zero exit codes, unhandled exceptions/stack traces leak | 2 = handles common bad input but misses edge cases | 3 = distinctive/hardened — validates and rejects bad input gracefully, correct non-zero exit codes on every failure path, no crashes, no leaked stack traces, deterministic output
- craft (1x): 1 = rough/placeholders — TODOs, debug prints, hardcoded paths | 2 = acceptable — clean output, minor polish gaps | 3 = polished edge/empty/error states — quiet-by-default, `--json`/machine-readable where useful, sensible defaults, no leftover debug noise

Pivot when primary OR secondary = 1. Aggregate = functionality + craft + 2*primary + 2*secondary.
