#!/usr/bin/env node
// workflow-logic.test.mjs — orchestration-logic tests for harness.workflow.js.
//
// Executes the REAL workflow body (meta block stripped) inside an AsyncFunction
// with the injected globals mocked, so we exercise the loop/brake/gate/pivot
// orchestration WITHOUT running any agent, shell command, or filesystem write.
//
// TAP output on stdout: "ok N - desc" / "not ok N - desc", then "1..N", then a
// "# workflow-logic: X passed, Y failed" summary. process.exitCode=1 on failure.
//
// Node 18+, zero dependencies. The workflow file is the spec: where a scenario's
// expectation disagreed with observed behavior, the TEST was corrected.

import { readFileSync } from 'node:fs'

// ---------------------------------------------------------------------------
// Load the workflow body: read the file, strip the leading `export const meta`
// block, and compile the remainder as an async function whose parameters are
// exactly the globals the workflow expects to be injected.
// ---------------------------------------------------------------------------
const WORKFLOW_URL = new URL('../../harness.workflow.js', import.meta.url)
const src = readFileSync(WORKFLOW_URL, 'utf8')
const body = src.replace(/^export const meta = \{[\s\S]*?\n\}\n/, '')
if (body === src) {
  console.error('FATAL: could not strip meta block from harness.workflow.js — regex did not match')
  process.exit(2)
}
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

// ---------------------------------------------------------------------------
// Verdict builders (mirror the workflow's VERDICT schema exactly).
// ---------------------------------------------------------------------------
const sc = (functionality, primary, secondary, craft) => ({ functionality, primary, secondary, craft })

function verdict(o = {}) {
  return {
    clean: o.clean !== undefined ? o.clean : true,
    issues: o.issues !== undefined ? o.issues : 0,
    summary: o.summary || 'ok',
    scores: o.scores || sc(3, 3, 3, 3),
    pivot: o.pivot !== undefined ? o.pivot : false,
    passedCriteria: o.passedCriteria || [],
    regressions: o.regressions || [],
    holdoutFailures: o.holdoutFailures || [],
    findings: o.findings || '',
    evidence: o.evidence || [],
  }
}

const cleanVerdict = () =>
  verdict({ passedCriteria: ['AC1'], evidence: [{ id: 'AC1', proof: 'saw it work' }] })

const gatePass = () => ({ passed: true, blocking: 0, summary: 'ok', checks: [] })
const gateFail = () => ({
  passed: false,
  blocking: 1,
  summary: 'build broke',
  checks: [{ name: 'build', status: 'fail', detail: 'boom' }],
})

// ---------------------------------------------------------------------------
// Default agent dispatcher — canned values for every non-eval label the
// workflow emits. Eval labels have NO default: a scenario MUST script them, and
// an unexpected/unmocked label throws loudly so a missing mock never passes
// silently.
// ---------------------------------------------------------------------------
function defaultHandler(label) {
  switch (label) {
    case 'resolve-workdir': return { workdir: '/tmp/wf-test' }
    // Build mode (default): guard passes when workdir/app is empty. No baseline.
    case 'mode-guard': return { ok: true, reason: '', baseline: '' }
    case 'planner': return 'ok'
    case 'planner-respec': return 'ok'
    case 'adapter-info': return { id: 'web', rubric: 'rubric text', seed: '' }
    case 'spec-check': return { acs: 5, surfaces: 2 }
    case 'generator': return 'run cmd'
    case 'generator-releak': return 'run cmd'
    case 'leak-check': return { leaks: 0 }
    case 'leak-recheck': return { leaks: 0 }
    case 'prep-criteria': return { surfaces: ['/'] }
    case 'seed': return { seeded: true }
    case 'preview': return '{"screenshots":["/tmp/a.png"],"baseUrl":"http://x"}'
    case 'report': return '{"written":true}'
  }
  if (/^boot#\d+$/.test(label)) return { baseUrl: 'http://127.0.0.1:5000' }
  if (/^prep#\d+$/.test(label)) return 'prep done'
  if (/^checkpoint#\d+$/.test(label)) return { missing: [] }
  if (/^gate#\d+$/.test(label)) return gatePass()
  if (/^gate-fix#\d+$/.test(label)) return 'done'
  if (/^gate-pivot#\d+$/.test(label)) return gatePass()
  if (/^gate-postfix(-repair|-re)?#\d+$/.test(label)) return gatePass()
  if (/^fix#\d+$/.test(label)) return 'done'
  if (/^pivot#\d+$/.test(label)) return 'run cmd'
  throw new Error(`workflow-logic: unexpected/unmocked agent label: "${label}"`)
}

// ---------------------------------------------------------------------------
// Run the workflow body once with fully mocked globals.
//   config.args        — merged over the default args object
//   config.handlers    — exact-label overrides (value or fn({label,prompt}))
//   config.evalHandler — fallback for eval-A#N / eval-B#N (+ -retry) labels
// Returns { result, calls, logs }.
// ---------------------------------------------------------------------------
async function runWorkflow(config = {}) {
  const { args: argsOverride = {}, handlers = {}, evalHandler = null } = config
  const calls = []
  const logs = []

  const agent = async (prompt, opts) => {
    const label = opts && opts.label
    calls.push({ label, prompt })
    if (Object.prototype.hasOwnProperty.call(handlers, label)) {
      const h = handlers[label]
      return typeof h === 'function' ? h({ label, prompt, calls }) : h
    }
    if (evalHandler && /^eval-[AB]#\d+/.test(label)) return evalHandler(label)
    return defaultHandler(label)
  }

  // A thunk that rejects resolves to null (matches the workflow's parallel contract).
  const parallel = async (thunks) =>
    Promise.all(thunks.map((t) => Promise.resolve().then(t).catch(() => null)))

  const phase = () => {}
  const log = (m) => logs.push(String(m))
  const budget = { total: null, spent: () => 0, remaining: () => Infinity }
  const args = Object.assign(
    { brief: 'test app', workdir: '/tmp/wf-test', skillDir: '/skill' },
    argsOverride
  )

  const fn = new AsyncFunction(
    'agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow',
    body
  )
  const result = await fn(agent, parallel, {}, phase, log, args, budget, {})
  return { result, calls, logs }
}

// Helpers for assertions on captured calls / logs.
const called = (calls, label) => calls.some((c) => c.label === label)
const logHas = (logs, needle) => logs.some((l) => l.includes(needle))
const passNum = (label) => Number(label.match(/#(\d+)/)[1])
const evalSide = (label) => label[5] // 'A' or 'B' in "eval-A#..."

// ---------------------------------------------------------------------------
// TAP harness
// ---------------------------------------------------------------------------
let N = 0
let FAILS = 0
function ok(cond, desc) {
  N++
  if (cond) {
    console.log(`ok ${N} - ${desc}`)
  } else {
    FAILS++
    console.log(`not ok ${N} - ${desc}`)
  }
}

// Run one scenario, converting any unexpected throw into a single failing point
// so one broken scenario cannot abort the whole file.
async function scenario(name, fn) {
  try {
    await fn()
  } catch (err) {
    ok(false, `${name}: threw unexpectedly — ${err && err.message}`)
  }
}

// ===========================================================================
// S1 — clean first pass
// ===========================================================================
await scenario('S1', async () => {
  const { result, calls, logs } = await runWorkflow({
    evalHandler: () => cleanVerdict(),
  })
  ok(result.clean === true, 'S1 clean-first-pass: returns clean=true')
  ok(
    Array.isArray(result.scoreHistory) &&
      result.scoreHistory.length === 1 &&
      result.scoreHistory[0] === 18,
    'S1 clean-first-pass: scoreHistory === [18]'
  )
  ok(!called(calls, 'fix#1'), 'S1 clean-first-pass: no fix#1 call')
  ok(result.gatePassed === true, 'S1 clean-first-pass: gatePassed=true')
  ok(
    typeof result.report === 'string' && result.report.endsWith('/REPORT.md'),
    'S1 clean-first-pass: report path returned'
  )
  ok(
    !called(calls, 'eval-A#1-retry') && !called(calls, 'eval-B#1-retry'),
    'S1 clean-first-pass: dead-evaluator retry did NOT fire'
  )
  void logs
})

// ===========================================================================
// S2 — stall brake (no aggregate-score improvement for 2 passes)
// ===========================================================================
await scenario('S2', async () => {
  // Scores identical (2/2/2/2 -> agg 12) every pass so the STALL brake trips;
  // issues + regressions vary per pass so the no-progress brake can't fire first.
  const { result, logs } = await runWorkflow({
    args: { maxPasses: 5 },
    evalHandler: (label) => {
      const n = passNum(label)
      return verdict({
        clean: false,
        issues: n,
        scores: sc(2, 2, 2, 2),
        regressions: ['R' + n],
      })
    },
  })
  ok(result.needsHuman === true, 'S2 stall: needsHuman=true')
  ok(logHas(logs, 'stall'), 'S2 stall: a log line contains "stall"')
  ok(
    result.scoreHistory.length >= 3 && result.scoreHistory.every((a) => a === 12),
    'S2 stall: aggregate stayed flat at 12 across passes'
  )
})

// ===========================================================================
// S3 — no-backslide cross-check (silent omission of a locked criterion)
// ===========================================================================
await scenario('S3', async () => {
  // maxPasses=2 so the loop ends on the pass that regresses AC1, keeping it the
  // final verdict. pass1 locks AC1 (with evidence); pass2 silently omits it.
  const { result, logs } = await runWorkflow({
    args: { maxPasses: 2 },
    evalHandler: (label) => {
      if (passNum(label) === 1) {
        return verdict({
          clean: false,
          issues: 1,
          scores: sc(2, 2, 2, 2),
          passedCriteria: ['AC1'],
          evidence: [{ id: 'AC1', proof: 'saw it work' }],
        })
      }
      // pass 2: silent omission — neither passed again nor flagged.
      return verdict({
        clean: false,
        issues: 0,
        scores: sc(2, 2, 2, 2),
        passedCriteria: [],
        regressions: [],
      })
    },
  })
  ok(logHas(logs, 'no-backslide'), 'S3 no-backslide: log line contains "no-backslide"')
  ok(
    result.final && Array.isArray(result.final.regressions) &&
      result.final.regressions.includes('AC1'),
    'S3 no-backslide: final verdict regressions include AC1'
  )
})

// ===========================================================================
// S4 — forced pivot (discard-and-restart on primary=1)
// ===========================================================================
await scenario('S4', async () => {
  const { result, calls } = await runWorkflow({
    evalHandler: (label) => {
      if (passNum(label) === 1) {
        // Pass A triggers the pivot (primary=1 -> pivot); both lock AC1 first.
        if (evalSide(label) === 'A') {
          return verdict({
            clean: false,
            scores: sc(2, 1, 2, 2),
            pivot: true,
            passedCriteria: ['AC1'],
            evidence: [{ id: 'AC1', proof: 'proofA' }],
          })
        }
        return verdict({
          clean: false,
          scores: sc(2, 2, 2, 2),
          pivot: false,
          passedCriteria: ['AC1'],
          evidence: [{ id: 'AC1', proof: 'proofB' }],
        })
      }
      // pass 2 (post-pivot): clean, locks a DIFFERENT criterion.
      return verdict({
        clean: true,
        scores: sc(3, 3, 3, 3),
        passedCriteria: ['AC2'],
        evidence: [{ id: 'AC2', proof: 'proof2' }],
      })
    },
  })
  ok(called(calls, 'pivot#1'), 'S4 pivot: pivot#1 agent was called')
  ok(called(calls, 'gate-pivot#1'), 'S4 pivot: gate-pivot#1 was called')
  ok(result.pivotsUsed === 1, 'S4 pivot: pivotsUsed === 1')
  ok(
    !result.lockedCriteria.includes('AC1'),
    'S4 pivot: pre-pivot lock (AC1) cleared from lockedCriteria'
  )
})

// ===========================================================================
// S5 — post-fix gate failure (fix breaks the build, repair fails again)
// ===========================================================================
await scenario('S5', async () => {
  const { result, calls } = await runWorkflow({
    handlers: {
      'gate-postfix#1': gateFail(),
      'gate-postfix-re#1': gateFail(),
    },
    evalHandler: () => verdict({ clean: false, issues: 2, scores: sc(2, 2, 2, 2) }),
  })
  ok(result.needsHuman === true, 'S5 post-fix gate: needsHuman=true')
  ok(result.gatePassed === false, 'S5 post-fix gate: gatePassed=false')
  ok(called(calls, 'fix#1'), 'S5 post-fix gate: fix#1 ran')
  ok(
    called(calls, 'gate-postfix-repair#1') && called(calls, 'gate-postfix-re#1'),
    'S5 post-fix gate: repair + re-gate both ran'
  )
})

// ===========================================================================
// S6 — evidence gate (a passed criterion without evidence is not locked)
// ===========================================================================
await scenario('S6', async () => {
  const { result, logs } = await runWorkflow({
    evalHandler: () =>
      verdict({
        clean: true,
        scores: sc(3, 3, 3, 3),
        passedCriteria: ['AC1', 'AC2'],
        evidence: [{ id: 'AC1', proof: 'saw AC1' }], // AC2 has no evidence
      }),
  })
  ok(result.lockedCriteria.includes('AC1'), 'S6 evidence gate: AC1 locked')
  ok(!result.lockedCriteria.includes('AC2'), 'S6 evidence gate: AC2 NOT locked')
  ok(logHas(logs, 'evidence gate'), 'S6 evidence gate: log line contains "evidence gate"')
})

// ===========================================================================
// S7 — holdout leak (hidden-check content leaked into the build, twice)
// ===========================================================================
await scenario('S7', async () => {
  const { result, calls } = await runWorkflow({
    handlers: {
      'leak-check': { leaks: 1 },
      'leak-recheck': { leaks: 1 },
    },
    // eval should never run — but if it did, this makes the failure loud.
    evalHandler: () => {
      throw new Error('S7: evaluator ran but should not have (early holdout-leak return)')
    },
  })
  ok(result.needsHuman === true, 'S7 holdout leak: needsHuman=true')
  ok(result.clean === false, 'S7 holdout leak: clean=false')
  ok(!called(calls, 'gate#0'), 'S7 holdout leak: no gate#0 call (returned before Gate phase)')
  ok(called(calls, 'generator-releak'), 'S7 holdout leak: regeneration attempt ran')
})

// ===========================================================================
// S8 — thin spec (machine extraction under threshold -> planner re-spec)
// ===========================================================================
await scenario('S8', async () => {
  const { result, calls } = await runWorkflow({
    handlers: {
      'spec-check': { acs: 1, surfaces: 0 },
    },
    evalHandler: () => cleanVerdict(),
  })
  ok(called(calls, 'planner-respec'), 'S8 thin spec: planner-respec was called')
  ok(result.clean === true, 'S8 thin spec: proceeds to a clean run after re-spec')
})

// ===========================================================================
// S9 — dead-evaluator retry (eval-A returns null once, retry succeeds)
// ===========================================================================
await scenario('S9', async () => {
  const { result, calls, logs } = await runWorkflow({
    handlers: {
      'eval-A#1': null, // dead on first attempt
      'eval-A#1-retry': cleanVerdict(),
    },
    evalHandler: () => cleanVerdict(), // eval-B#1 (and any other) come back clean
  })
  ok(called(calls, 'eval-A#1-retry'), 'S9 dead-eval retry: eval-A#1-retry fired')
  ok(logHas(logs, 'retrying'), 'S9 dead-eval retry: a log line contains "retrying"')
  ok(result.clean === true, 'S9 dead-eval retry: run completes clean after retry')
})

// ===========================================================================
// S10 — feature-mode guard failure (no existing app -> early stop, no Planner)
// ===========================================================================
await scenario('S10', async () => {
  const { result, calls } = await runWorkflow({
    args: { mode: 'feature' },
    handlers: {
      'mode-guard': { ok: false, reason: 'feature mode but no existing app', baseline: '' },
    },
    // Nothing past the guard should run; make any stray eval call loud.
    evalHandler: () => {
      throw new Error('S10: evaluator ran but the mode guard should have stopped the run')
    },
  })
  ok(!called(calls, 'planner'), 'S10 feature-guard: Planner (opus) never called')
  ok(result.needsHuman === true, 'S10 feature-guard: needsHuman=true')
  ok(result.clean === false, 'S10 feature-guard: clean=false')
  ok(result.mode === 'feature', 'S10 feature-guard: mode=feature in return')
  ok(result.adapter === 'unresolved', 'S10 feature-guard: adapter=unresolved')
})

// ===========================================================================
// S11 — flap detection (criterion churns fail -> pass -> fail across passes)
// ===========================================================================
await scenario('S11', async () => {
  const { result, logs } = await runWorkflow({
    args: { maxPasses: 3 },
    evalHandler: (label) => {
      const n = passNum(label)
      if (n === 1) {
        // AC1 failing (findings line carries the id).
        return verdict({
          clean: false, issues: 1, scores: sc(2, 2, 2, 2),
          findings: '- [ ] AC1 /home: EXPECTED shows list | ACTUAL blank | REPRO open / | FIX Home.tsx',
        })
      }
      if (n === 2) {
        // AC1 "fixed" (passed with evidence), some other issue keeps the loop going.
        return verdict({
          clean: false, issues: 2, scores: sc(2, 2, 2, 2),
          passedCriteria: ['AC1'],
          evidence: [{ id: 'AC1', proof: 'saw the list render' }],
        })
      }
      // pass 3: AC1 broke AGAIN — the fix did not hold.
      return verdict({
        clean: false, issues: 3, scores: sc(2, 2, 2, 2),
        regressions: ['AC1'],
      })
    },
  })
  ok(
    Array.isArray(result.flapping) && result.flapping.some((f) => f.startsWith('AC1 (')),
    'S11 flap: AC1 reported in result.flapping'
  )
  ok(
    result.flapping.some((f) => f === 'AC1 (F->P->F)'),
    'S11 flap: state trail is F->P->F'
  )
  ok(logHas(logs, 'flap detection'), 'S11 flap: log line contains "flap detection"')
})

// ===========================================================================
// S12 — no false flaps (a criterion fixed once and holding is NOT flapping)
// ===========================================================================
await scenario('S12', async () => {
  const { result } = await runWorkflow({
    args: { maxPasses: 2 },
    evalHandler: (label) => {
      const n = passNum(label)
      if (n === 1) {
        return verdict({
          clean: false, issues: 1, scores: sc(2, 2, 2, 2),
          findings: '- [ ] AC1 /home: EXPECTED shows list | ACTUAL blank | REPRO open / | FIX Home.tsx',
        })
      }
      // pass 2: fixed and clean — one transition (F->P), not a flap.
      return verdict({
        clean: true, scores: sc(3, 3, 3, 3),
        passedCriteria: ['AC1'],
        evidence: [{ id: 'AC1', proof: 'saw the list render' }],
      })
    },
  })
  ok(result.clean === true, 'S12 no-false-flap: run ends clean')
  ok(
    Array.isArray(result.flapping) && result.flapping.length === 0,
    'S12 no-false-flap: single F->P transition is not reported as flapping'
  )
})

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------
console.log(`1..${N}`)
console.log(`# workflow-logic: ${N - FAILS} passed, ${FAILS} failed`)
if (FAILS > 0) process.exitCode = 1
