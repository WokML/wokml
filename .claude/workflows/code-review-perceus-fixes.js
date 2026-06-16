export const meta = {
  name: 'code-review-perceus-fixes',
  description: 'Recall-biased review of the 6 fix commits (07262ae~1..cb1d457): do they truly close the original findings, and did they introduce new bugs?',
  phases: [ { title: 'Find' }, { title: 'Verify' } ],
}

const REPO = '/Users/zy/wokml'
const DIFF = 'git --no-pager diff 07262ae~1 cb1d457'

const SCOPE = 'Review scope: the wok Haskell project at ' + REPO + ', branch feat/perceus-interpreter-m1. The diff under review is the SIX FIX COMMITS that were meant to resolve 6 confirmed correctness findings from a prior review. Get it with `' + DIFF + '` (run via Bash). Read enclosing functions for every hunk. TWO QUESTIONS to keep front of mind for EVERY finding: (1) does the fix ACTUALLY close the whole bug CLASS, not merely the one reproduced shape? (2) did the fix introduce a NEW bug (double-free, over-free/use-after-free, broken refcount accounting, non-termination, regression)?\n\nThe 6 findings and their fixes:\n- F3 (07262ae) Bool was mis-classified UNBOXED in Wok.IR.Perceus.isBoxedType but the RC interpreter heap-allocates Bool as a boxed NCon. Fix: isBoxedType Bool=True; also reclassified TcString as unboxed. CHECK: is EVERY constructor/record/closure type now boxed and every RVLit type (U64/U32/Char/Unit/String/Never) unboxed? any double-drop now on Bool (pass-drop + boolOp manual operand drop)? is the TcString reclassification safe?\n- F1 (3e62e99) Case own-children/drop-parent "reused" check missed scrutinee-capturing joins reached via nested Case or transitive join chains (a real UAF). Fix: full recursive jump walk (jumpTargets/altJumpTargets through Case/Let/LetJoin/LetRec); ctxJoins changed from Map JoinId (Set Unique) to Map JoinId (Set Unique, Set JoinId) recording onward jumps; closeJoins transitively closes; the Jump rule now reserves the TRANSITIVE cap. CHECK: does closeJoins TERMINATE if the join graph has a cycle (recursive/looping joins)? does reserving the transitive cap at a Jump now OVER-reserve so some owned var is never dropped (a LEAK) on some path? are all ctxJoins readers updated to the new tuple type? branch reconciliation still correct?\n- F5 (a251ab6) returning a LetRec group member dropped-then-returned it. Fix: Ret rule dead = (delta\\moved)\\owned (owned = atomVars result ∩ delta); lint added relRets. CHECK: can excluding owned from dead ever skip a drop that WAS needed (leak) for a non-result var? is the lint relRets consistent with runtime?\n- F2 (91d619a) value-CAF referenced from a function read an uninstalled placeholder. Fix: installBinds writes the forced boxed CAF node into its reserved STATIC cell via writeStatic (an uncounted alias sharing the dynamic root\'s children). CHECK: the static cell now ALIASES the dynamic CAF cell\'s children — can any path drop those children twice or leave the dynamic root mis-accounted? does the baseline (stLive==rcBaseline) still hold? CAF-to-CAF refs still work?\n- F6 (e808700) a covered letrec group capturing a value-CAF cascade-decref\'d it. Fix: bind the STATIC handle (negative addr) into the accumulator env so captures are uncounted; relies on incref/dropAddr being no-ops on static addrs. CHECK: does binding the static handle break main\'s own use of the CAF, CAF-to-CAF, or the F2 forward-ref? interaction between F2 and F6 (both touch installBinds CAF handling)?\n- F4 (cb1d457) closure cell leaked on application. Fix: enterRC consume helper increfs each boxed captured handle then dropAddr\'s the closure cell, uniform across EQ/LT/GT; static-global and LetRec-region addrs (isRegionAddr, new) exempt. CHECK: the consume-once invariant — does the body consume each captured boxed var EXACTLY once? for SHARED closures (rc>1) does incref-then-shell-decrement net correctly? GT over-application path correct? could a captured var be both consumed by the body AND released by the closure drop (double-free)? borrow-style captures?\n\nConventions: src/ is Strict+StrictData (no `!` bangs); -Wall -Werror. Reference interpreter Wok.Interp.{Machine,Value,Prim} must be untouched.'

const CAND_SCHEMA = { type: 'object', additionalProperties: false, required: ['candidates'],
  properties: { candidates: { type: 'array', maxItems: 6, items: { type: 'object', additionalProperties: false,
    required: ['file','line','summary','failure_scenario','kind'],
    properties: { file: { type: 'string' }, line: { type: 'string' }, summary: { type: 'string' },
      failure_scenario: { type: 'string' }, kind: { type: 'string', enum: ['correctness','cleanup','altitude'] } } } } } }

const angles = [
  ['A-linescan', 'Angle A — line-by-line diff scan. Read every hunk; Read the enclosing function. For each changed line ask what input/state makes it wrong. Focus on the fix correctness: inverted conditions, off-by-one in the new set arithmetic (dead/moved/owned/cap unions), non-termination in closeJoins, refcount under/over-count in the enterRC consume helper, double-free/over-free.'],
  ['B-removed', 'Angle B — removed-behavior auditor. For every line these fixes DELETE or replace (e.g. the old reused check, old Ret dead formula, old installBinds CAF branch, old enterRC branches), name the invariant it held and confirm the new code re-establishes it without dropping a guard or a needed drop.'],
  ['C-crossfile', 'Angle C — cross-file tracer. The ctxJoins type changed (Set Unique -> (Set Unique, Set JoinId)); Grep ALL readers/writers and confirm each is updated correctly. isBoxedType callers; enterRC callers (EQ/LT/GT, PRApply/$); installBinds; isRegionAddr new export. Any call site broken by a changed shape/precondition?'],
  ['D-reuse', 'Reuse angle. Does any fix re-implement an existing helper (free-var/jump walks already in Anf/Reachable/Multiplicity; a drop/consume helper)? Name the existing one.'],
  ['E-simplify', 'Simplification angle. Redundant/derivable state added by the fixes (e.g. recomputing transitive closures, duplicated traversal), dead code, over-complex set arithmetic. Name the simpler form.'],
  ['F-efficiency', 'Efficiency angle. Wasted work added: closeJoins recomputed per Case/Jump (O(n^2)?), repeated freeVars, enterRC consume traversing the env each call. Name the cheaper alternative.'],
  ['G-altitude', 'Altitude angle. Are these fixes at the right depth or band-aids? F2/F6 special-case CAF handling in installBinds (static aliasing) — is that papering over a missing boxed-CAF representation? F4 consume-once assumption vs a general borrow/own model? F1 over-approximation vs a precise liveness. Flag where a deeper fix is warranted.'],
]

const finderResults = await parallel(angles.map(([label, body]) => () => agent(
  body + '\n\n' + SCOPE + '\n\nReturn UP TO 6 candidates (file, line, one-line summary, concrete failure_scenario, kind). Prioritize: (a) the original finding NOT actually fully fixed, and (b) a NEW bug introduced by the fix. Pass through every candidate with a nameable failure scenario.',
  { label, phase: 'Find', schema: CAND_SCHEMA })))

const all = []
for (const r of finderResults) { if (r && r.candidates) for (const c of r.candidates) all.push(c) }
const seen = new Set(); const deduped = []
for (const c of all) { const k = (c.file||'') + '|' + (c.summary||'').toLowerCase().replace(/[^a-z0-9]+/g,' ').trim().slice(0,55); if (seen.has(k)) continue; seen.add(k); deduped.push(c) }
log('Finders produced ' + all.length + ' candidates, ' + deduped.length + ' after dedup')

const VERIFY_SCHEMA = { type: 'object', additionalProperties: false,
  required: ['verdict','kind','severity','reason','file','line','summary','failure_scenario'],
  properties: { verdict: { type: 'string', enum: ['CONFIRMED','PLAUSIBLE','REFUTED'] },
    kind: { type: 'string', enum: ['correctness','cleanup','altitude'] },
    severity: { type: 'string', enum: ['high','medium','low'] }, reason: { type: 'string' },
    file: { type: 'string' }, line: { type: 'string' }, summary: { type: 'string' }, failure_scenario: { type: 'string' } } }

phase('Verify')
const verified = await parallel(deduped.map(c => () => agent(
  'Recall-biased VERIFIER for a review of the 6 Perceus fix commits at ' + REPO + ' (diff `' + DIFF + '`). Verify this candidate by reading the actual code + diff; you may build/run tests. CANDIDATE:\nfile: ' + c.file + '\nline: ' + c.line + '\nkind: ' + c.kind + '\nsummary: ' + c.summary + '\nfailure_scenario: ' + c.failure_scenario +
  '\n\nPLAUSIBLE by default for realistic reachable states. REFUTE only if constructible: factually wrong (quote line), provably impossible (cite type/constant/invariant), already handled (cite guard), or pure style with no effect. Classify kind + severity (a real UAF/double-free/leak/non-termination = high). Echo file/line/summary/failure_scenario.',
  { label: 'verify:' + (c.file||'').split('/').pop() + ':' + c.line, phase: 'Verify', schema: VERIFY_SCHEMA })))

const kept = verified.filter(Boolean).filter(v => v.verdict === 'CONFIRMED' || v.verdict === 'PLAUSIBLE')
const sev = { high:0, medium:1, low:2 }, knd = { correctness:0, altitude:1, cleanup:2 }, vrd = { CONFIRMED:0, PLAUSIBLE:1 }
kept.sort((a,b) => (knd[a.kind]-knd[b.kind]) || (sev[a.severity]-sev[b.severity]) || (vrd[a.verdict]-vrd[b.verdict]))
return { total: all.length, deduped: deduped.length, kept: kept.length, findings: kept.slice(0,10) }