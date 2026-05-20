#!/usr/bin/env bash
# gate.sh — Run quality gate on a stage's output (progressive multi-agent ensemble)
# Usage: bash scripts/gate.sh <stage_name> [ticket_id]
# Returns: JSON verdict to stdout

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

STAGE="${1:?Usage: gate.sh <stage_name> [ticket_id] [attempt]}"
TICKET_ID="${2:-}"
ATTEMPT="${3:-1}"
AUTOPILOT_DIR=".autopilot"

# Normalize non-numeric attempt (e.g. "synthesis") to full gate
[[ "$ATTEMPT" =~ ^[0-9]+$ ]] || ATTEMPT=3
GEMINI_GATE_MODEL="${GEMINI_GATE_MODEL:-gemini-2.5-pro}"

# ─── Temp dir with cleanup trap ───────────────────────────────────────────────

TMPDIR_GATE=$(mktemp -d)
[[ -n "$TMPDIR_GATE" ]] || { echo "gate.sh: mktemp failed — cannot create temp dir" >&2; exit 1; }
trap 'rm -rf "$TMPDIR_GATE"; kill "${_gate_hb_pid:-}" 2>/dev/null || true' EXIT

# ─── Determine what to judge ─────────────────────────────────────────────────

if [[ -n "$TICKET_ID" ]]; then
  OUTPUT_FILE="$AUTOPILOT_DIR/stages/developer/$TICKET_ID/output.md"
  CHECKLIST_STAGE="developer"
else
  OUTPUT_FILE="$AUTOPILOT_DIR/stages/$STAGE/output.md"
  CHECKLIST_STAGE="$STAGE"
fi

if [[ ! -f "$OUTPUT_FILE" ]]; then
  echo '{"verdict":"FAIL","score":0,"checklist":[],"blockers":["Output file not found: '"$OUTPUT_FILE"'"],"critique":"The stage produced no output file. This is a runner error, not a content error.","suggestions":[],"contested_decisions":[]}'
  exit 0
fi

# ─── Pre-screen: deterministic structural check before any LLM call ───────────

PRE_SCREEN_STATUS=0
PRE_SCREEN_OUT=$(python3 "$SCRIPT_DIR/pre_screen.py" "$CHECKLIST_STAGE" "$OUTPUT_FILE" 2>&1) || PRE_SCREEN_STATUS=$?

if [[ $PRE_SCREEN_STATUS -ne 0 ]]; then
  printf 'gate.sh: pre-screen failed for %s — returning FAIL without invoking LLM agents\n' "$CHECKLIST_STAGE" >&2
  printf '%s\n' "$PRE_SCREEN_OUT" >&2
  printf '%s\n' "$PRE_SCREEN_OUT" | python3 -c "
import sys, re, json
text = sys.stdin.read()
blockers = []
for line in text.splitlines():
    m = re.match(r'^\s+\d+\.\s+(.+)', line)
    if m:
        blockers.append(m.group(1).strip())
if not blockers:
    blockers = [text.strip() or 'Pre-screen structural check failed']
result = {
    'verdict': 'FAIL',
    'score': 0,
    'checklist': [],
    'blockers': blockers,
    'critique': text.strip(),
    'suggestions': [],
    'contested_decisions': [],
    'blind_critic_score': None,
    'edge_case_score': None,
}
print(json.dumps(result))
"
  exit 0
fi

# ─── Load checklist for this stage ───────────────────────────────────────────

get_checklist() {
  case "$CHECKLIST_STAGE" in
    context-validator)
      cat <<'EOF'
- Any `### CONFLICT-` heading present in the report → FAIL (BLOCKER)
- `### WARN-` headings present → non-blocking suggestions only
- All three sections present: "Conflicts", "Warnings", "Verified" — BLOCKER if any section missing
EOF
      ;;
    analyst)
      cat <<'EOF'
- All features from brief appear as functional requirements
- Every FR has at least one acceptance criterion in Given/When/Then form
- Non-functional requirements present (at minimum: the constraints from brief)
- Out of scope section present and non-empty
- Open questions section is EMPTY (any open question is a BLOCKER)
- No invented features not in brief
- Every specific value, threshold, sign convention, state name, or behavior referenced in any AC that is NOT explicitly in the brief must have a corresponding Decisions Made entry (BLOCKER if any undocumented implicit decision found)
EOF
      local cv_output="$AUTOPILOT_DIR/stages/context-validator/output.md"
      if [[ -f "$cv_output" ]]; then
        echo "- All ### CONFLICT- items from the context validation report must be explicitly addressed — BLOCKER if any CONFLICT item is unaddressed"
        local conflicts
        conflicts=$(grep "^### CONFLICT-" "$cv_output" | sed 's/^### //')
        if [[ -n "$conflicts" ]]; then
          while IFS= read -r conflict; do
            echo "- $conflict must be explicitly resolved in the sprint scope document"
          done <<< "$conflicts"
        fi
      fi
      ;;
    architect)
      cat <<'EOF'
- All PRD functional requirements are addressed by the design
- File/folder structure is complete and specific (every file listed)
- API contracts have types — not just names (BLOCKER if missing)
- Error handling strategy present
- Testing strategy present
- One ADR per technology not explicitly specified in brief (BLOCKER if missing)
- No TBD, no decisions left unmade (BLOCKER)
- ADR separator "--- ADR ---" present between each ADR
EOF
      ;;
    task-breakdown)
      cat <<'EOF'
- Every FR from PRD maps to at least one ticket
- No circular dependencies between tickets
- Every ticket references specific files from the architecture
- Setup tickets (init, config) are ordered before implementation tickets
- Parallelizable tickets do not write the same file
- Ticket count is reasonable for project scope
- Each ticket has explicit acceptance criteria
- Every ticket has a manifest file at .autopilot/stages/task-breakdown/manifests/TASK-NNN.json — BLOCKER if any ticket is missing one
- All paths in requires.existing_files of every manifest exist in the repository — BLOCKER if any path is absent
- All ADRs in requires.adrs of every manifest exist in the ADR directory — BLOCKER if any ADR is missing
- No circular manifest dependencies (TASK-A's requires references TASK-B's provides.new_files and TASK-B's requires references TASK-A's provides.new_files) — BLOCKER if circular dependency found
- provides.exports for each ticket is sufficient to satisfy all downstream_contracts that reference that ticket — BLOCKER if signature mismatch found
EOF
      ;;
    developer)
      cat <<'EOF'
- All acceptance criteria from the specific ticket are met
- No placeholder code (TODO, "implement this", empty function bodies) — BLOCKER
- Tests present for business logic functions
- Code follows patterns from ADRs
- No imports of packages not in package.json — BLOCKER
- File(s) specified in the ticket were actually created/modified
- If a design artifact was provided: a ## Design Compliance Checklist section is present in the output — BLOCKER if missing
- If a design artifact was provided: every component/screen named in the design appears in the checklist with a ✅ — BLOCKER if any design component is ❌ or absent without an explicit justification
- If a design artifact was provided: no design element was removed, renamed, or substituted — only loading/error/empty states may be added — BLOCKER if any substitution exists without justification
EOF
      ;;
    reviewer)
      cat <<'EOF'
- Test suite exits 0 (BLOCKER if failing)
- Lint exits 0 (BLOCKER if failing)
- Definition of done from brief is satisfied (BLOCKER if not)
- No TODO comments in production code
- README or equivalent exists
EOF
      ;;
    security-scan)
      local severity_threshold
      severity_threshold=$(python3 -c "
import re
try:
    txt = open('${SKILL_DIR}/references/stage-registry.yaml').read()
    m = re.search(r'id: security-scan.*?severity_threshold:\s*(\S+)', txt, re.DOTALL)
    print(m.group(1) if m else 'HIGH')
except Exception:
    print('HIGH')
" 2>/dev/null || echo "HIGH")
      if [[ "$severity_threshold" == "CRITICAL" ]]; then
        cat <<'EOF'
- CRITICAL finding present → FAIL (BLOCKER)
- HIGH findings present → WARNING only (severity_threshold is CRITICAL; HIGH is non-blocking)
- MEDIUM findings → suggestion only (non-blocking)
- Each finding must include: CWE reference, location, risk description, required mitigation — BLOCKER if any finding is missing one of these fields
- "Required before task-breakdown" section present listing all CRITICAL findings
EOF
      else
        cat <<'EOF'
- CRITICAL finding present → FAIL (BLOCKER)
- HIGH finding present → FAIL (BLOCKER)
- MEDIUM findings → suggestion only (non-blocking)
- Each finding must include: CWE reference, location, risk description, required mitigation — BLOCKER if any finding is missing one of these fields
- "Required before task-breakdown" section present listing all CRITICAL and HIGH findings
EOF
      fi
      ;;
    *)
      echo "Unknown stage for checklist: $CHECKLIST_STAGE" >&2
      exit 1
      ;;
  esac
}

CHECKLIST=$(get_checklist)
if [[ ! -f "PROJECT_BRIEF.md" ]]; then
  echo '{"verdict":"FAIL","score":0,"checklist":[],"blockers":["PROJECT_BRIEF.md not found in working directory"],"critique":"The gate cannot run without a project brief. Ensure gate.sh is invoked from the project root.","suggestions":[],"contested_decisions":[]}'
  exit 0
fi
BRIEF=$(cat PROJECT_BRIEF.md)
OUTPUT=$(cat "$OUTPUT_FILE")

# ─── Triage: fast score estimation before full gate ──────────────────────────

read -r -d '' TRIAGE_SYSTEM_PROMPT << 'TGPROMPT' || true
You are a triage agent estimating document quality before a full gate review.
Output ONLY valid JSON — no preamble, no explanation, no markdown fences:
{"score": <integer 1-10>, "failing_sections": ["<section heading>", ...], "diagnosis": "<one sentence>"}
score 8-10: high quality, likely passes full gate.
score 5-7: issues present, full review needed.
score 1-4: fundamentally broken, retries will not help.
failing_sections: list of exact markdown heading names that fail quality. Empty array if score >= 8.
diagnosis: one sentence on the primary problem, or "No major issues found" if score >= 8.
Maximum output: 200 tokens. Output only the JSON object.
TGPROMPT

TRIAGE_SCORE=""
TRIAGE_SECTIONS='[]'
TRIAGE_DIAGNOSIS=""
TRIAGE_DONE=false

TRIAGE_PROMPT="STAGE_OUTPUT:
$OUTPUT

PROJECT_BRIEF:
$BRIEF"

printf '  [gate] %s  triage started at %s\n' "$STAGE" "$(date '+%H:%M:%S')" >&2
TRIAGE_STATUS=0
TRIAGE_RAW=$(printf '%s\n' "$TRIAGE_PROMPT" | claude -p "$TRIAGE_SYSTEM_PROMPT" --dangerously-skip-permissions \
  --json-schema '{"type":"object","properties":{"score":{"type":"integer","minimum":1,"maximum":10},"failing_sections":{"type":"array","items":{"type":"string"}},"diagnosis":{"type":"string"}},"required":["score","failing_sections","diagnosis"]}' \
  2>"$TMPDIR_GATE/triage_err") || TRIAGE_STATUS=$?

if [[ $TRIAGE_STATUS -ne 0 || -z "$TRIAGE_RAW" ]]; then
  printf 'gate.sh: triage agent failed (exit %s) — falling back to full gate\n' "$TRIAGE_STATUS" >&2
  [[ -s "$TMPDIR_GATE/triage_err" ]] && cat "$TMPDIR_GATE/triage_err" >&2
else
  TRIAGE_PARSED=$(printf '%s\n' "$TRIAGE_RAW" | python3 -c "
import sys, re, json
text = sys.stdin.read()
text = re.sub(r'^\s*\`\`\`(?:json)?\s*\n?', '', text, count=1, flags=re.IGNORECASE)
text = re.sub(r'\n?\s*\`\`\`\s*$', '', text, flags=re.IGNORECASE)
text = text.strip()
m = re.search(r'\{.*\}', text, re.DOTALL)
if m:
    text = m.group(0)
try:
    d = json.loads(text)
    score = int(d.get('score', 0))
    if not 1 <= score <= 10:
        raise ValueError('score out of range: ' + str(score))
    sections = d.get('failing_sections', [])
    sections = [str(s) for s in sections] if isinstance(sections, list) else []
    diagnosis = str(d.get('diagnosis', ''))[:500]
    print(json.dumps({'ok': True, 'score': score, 'sections': sections, 'diagnosis': diagnosis}))
except Exception as e:
    print(json.dumps({'ok': False, 'error': str(e)}))
" 2>/dev/null || printf '%s\n' '{"ok":false,"error":"python parse failed"}')

  TRIAGE_OK=$(printf '%s\n' "$TRIAGE_PARSED" | python3 -c "import sys,json; print('true' if json.load(sys.stdin).get('ok') else 'false')" 2>/dev/null || echo "false")

  if [[ "$TRIAGE_OK" != "true" ]]; then
    TRIAGE_ERR=$(printf '%s\n' "$TRIAGE_PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null || echo "unknown")
    printf 'gate.sh: triage output malformed (%s) — falling back to full gate\n' "$TRIAGE_ERR" >&2
  else
    TRIAGE_SCORE=$(printf '%s\n' "$TRIAGE_PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin)['score'])")
    TRIAGE_SECTIONS=$(printf '%s\n' "$TRIAGE_PARSED" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['sections']))")
    TRIAGE_DIAGNOSIS=$(printf '%s\n' "$TRIAGE_PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin)['diagnosis'])")
    TRIAGE_DONE=true
    printf '  [gate] %s  triage complete — score=%s\n' "$STAGE" "$TRIAGE_SCORE" >&2
  fi
fi

if [[ "$TRIAGE_DONE" == "true" ]]; then
  if [[ "$TRIAGE_SCORE" -ge 8 ]]; then
    printf 'gate.sh: triage score=%s >= 8 — PASS (fast-path, no ensemble)\n' "$TRIAGE_SCORE" >&2
    python3 -c "
import sys, json
score = int(sys.argv[1])
print(json.dumps({
    'verdict': 'PASS',
    'score': score,
    'checklist': [],
    'blockers': [],
    'critique': '',
    'suggestions': [],
    'contested_decisions': [],
    'blind_critic_score': None,
    'edge_case_score': None,
}))
" "$TRIAGE_SCORE"
    exit 0
  elif [[ "$TRIAGE_SCORE" -lt 5 ]]; then
    printf 'gate.sh: triage score=%s < 5 — FAIL (immediate escalation)\n' "$TRIAGE_SCORE" >&2
    python3 -c "
import sys, json
score = int(sys.argv[1])
diagnosis = sys.argv[2]
print(json.dumps({
    'verdict': 'FAIL',
    'score': score,
    'checklist': [],
    'blockers': [diagnosis],
    'critique': diagnosis,
    'suggestions': [],
    'contested_decisions': [],
    'blind_critic_score': None,
    'edge_case_score': None,
    'triage_escalate': True,
}))
" "$TRIAGE_SCORE" "$TRIAGE_DIAGNOSIS"
    exit 0
  else
    printf 'gate.sh: triage score=%s (5-7) — proceeding to full gate\n' "$TRIAGE_SCORE" >&2
    TRIAGE_FAILING_SECTIONS="$TRIAGE_SECTIONS"
  fi
fi

MANIFEST_CONTEXT=""
# ─── For task-breakdown: append manifest contents to output for Adjudicator ───

if [[ "$CHECKLIST_STAGE" == "task-breakdown" ]]; then
  MANIFEST_DIR="$AUTOPILOT_DIR/stages/task-breakdown/manifests"
  MANIFEST_CONTEXT=""
  MANIFEST_COUNT=0
  MANIFEST_CAP=30
  if [[ -d "$MANIFEST_DIR" ]]; then
    for manifest_file in "$MANIFEST_DIR"/TASK-*.json; do
      [[ -f "$manifest_file" ]] || continue
      if [[ $MANIFEST_COUNT -ge $MANIFEST_CAP ]]; then
        printf 'gate.sh: WARNING: manifest count exceeds cap (%d); remaining manifests omitted from gate context\n' "$MANIFEST_CAP" >&2
        break
      fi
      if ! python3 -c "import sys,json; json.load(open(sys.argv[1]))" "$manifest_file" 2>/dev/null; then
        printf 'gate.sh: WARNING: skipping malformed manifest %s (invalid JSON)\n' "$(basename "$manifest_file")" >&2
        continue
      fi
      MANIFEST_CONTEXT+="=== MANIFEST: $(basename "$manifest_file") ===
$(cat "$manifest_file")

"
      MANIFEST_COUNT=$(( MANIFEST_COUNT + 1 ))
    done
  fi
  if [[ -n "$MANIFEST_CONTEXT" ]]; then
    OUTPUT="$OUTPUT

=== CONTEXT MANIFESTS ===
$MANIFEST_CONTEXT"
  else
    printf 'gate.sh: WARNING: no valid manifest files found in %s — manifest BLOCKER checks rely on LLM inference only\n' "$MANIFEST_DIR" >&2
  fi
fi

# ─── Section-scoped gate: pass only failing sections to full gate agents ──────

GATE_INPUT="$OUTPUT"
if [[ -n "${TRIAGE_FAILING_SECTIONS:-}" && "${TRIAGE_FAILING_SECTIONS:-}" != '[]' ]]; then
  SCOPED_STATUS=0
  SCOPED_CONTENT=$(python3 "$SCRIPT_DIR/extract_sections.py" "$OUTPUT_FILE" "$TRIAGE_FAILING_SECTIONS" \
    2>"$TMPDIR_GATE/scope_err") || SCOPED_STATUS=$?
  [[ -s "$TMPDIR_GATE/scope_err" ]] && cat "$TMPDIR_GATE/scope_err" >&2
  if [[ $SCOPED_STATUS -eq 0 && -n "$SCOPED_CONTENT" ]]; then
    GATE_INPUT="$SCOPED_CONTENT"
    if [[ -n "$MANIFEST_CONTEXT" ]]; then
      GATE_INPUT="$GATE_INPUT

=== CONTEXT MANIFESTS ===
$MANIFEST_CONTEXT"
    fi
    printf 'gate.sh: section-scoped gate active — agents receive failing sections only\n' >&2
  else
    printf 'gate.sh: section-scoped gate unavailable — using full document\n' >&2
  fi
fi

# ─── Agent system prompts ─────────────────────────────────────────────────────

read -r -d '' BLIND_CRITIC_SYSTEM_PROMPT << 'BCPROMPT' || true
You are a quality critic reviewing a technical document.
You will receive only the document itself. No stage name, no checklist, no brief.

Your job: find every deficiency in this document. Look for:
- Incomplete sections (promised but not delivered)
- Internal inconsistencies (claim A contradicts claim B)
- Vague or non-actionable language where specificity is needed
- Missing concrete detail (examples: no types on "API contracts", no file paths in "file structure")
- Assertions without evidence or rationale
- Structural gaps (a section that should logically follow but doesn't exist)

Output a numbered list of deficiencies. For each: one sentence describing the problem,
one sentence describing what a correct version would look like.
Do NOT suggest improvements — only find problems.
Output ONLY the deficiencies list. If you find none, output "NO_DEFICIENCIES".
BCPROMPT

read -r -d '' EDGE_CASE_HUNTER_SYSTEM_PROMPT << 'ECHPROMPT' || true
You are an edge case analyst. You will receive a technical document and the original brief
that drove it.

Your job: walk every branching path and boundary condition described in the brief,
and report only those that the document does not handle.

For each unhandled case: describe the scenario, describe what the document says (or doesn't say),
and describe what could go wrong if this scenario occurs in implementation.

Output a numbered list. If all cases are handled, output "ALL_CASES_HANDLED".
Do NOT suggest how to fix them — only enumerate them.
ECHPROMPT

read -r -d '' ADJUDICATOR_SYSTEM_PROMPT << 'ADJPROMPT' || true
You are a quality gate adjudicator running in a fully automated pipeline.
You will receive:
- OUTPUT: the document being evaluated
- BRIEF: the original project brief
- CHECKLIST: the specific quality checklist for this stage
- BLIND_CRITIC_REPORT: deficiencies found by a critic who saw only the output
- EDGE_CASE_REPORT: unhandled edge cases found by an analyst who had the brief

Your job: synthesize all inputs and issue a final verdict.

Process:
1. Go through CHECKLIST item by item: PASS / FAIL / N/A with one-line reason
2. Incorporate BLIND_CRITIC_REPORT: mark each deficiency as BLOCKER or WARNING
3. Incorporate EDGE_CASE_REPORT: mark each unhandled case as BLOCKER or WARNING
4. Identify contested decisions (see below)
5. Assign score and verdict

Contested decisions: if you find a section where two or more legitimate options exist,
neither is clearly better from the brief's constraints, and the document picked one
without a substantiated rationale — flag it as CONTESTED_DECISION in your output.
This triggers the Decision Engine (not a FAIL by itself).

Score:
- 10: All checklist items pass, no deficiencies, no unhandled edge cases
- 8-9: All blockers pass, minor warnings only
- 7: Threshold — all blockers pass, some warnings
- 5-6: Has blockers
- 1-4: Fundamental problems

Output ONLY valid JSON:
{
  "verdict": "PASS" | "FAIL",
  "score": <1-10>,
  "checklist": [{"item": "...", "result": "PASS|FAIL|N/A", "reason": "..."}],
  "blockers": ["..."],
  "critique": "<if FAIL: specific actionable instructions. If PASS: empty string>",
  "suggestions": ["..."],
  "contested_decisions": [
    {
      "section": "<section heading>",
      "decision": "<what was decided>",
      "alternatives": ["<option A>", "<option B>"],
      "why_contested": "<what signal from brief makes this genuinely unclear>"
    }
  ]
}
ADJPROMPT

read -r -d '' GEMINI_REVIEWER_SYSTEM_PROMPT << 'GRPROMPT' || true
You are an independent quality gate reviewer. You have been trained by Google and are reviewing
a document produced by a Claude (Anthropic) model. Your role is to catch issues that
same-model self-review consistently misses due to shared training biases and blindspots.

You will receive:
- OUTPUT: the document being evaluated
- BRIEF: the original project brief that drove this document
- CHECKLIST: the quality checklist for this stage

Your job: evaluate the OUTPUT against the CHECKLIST and BRIEF. Apply your own independent
judgment — do not inflate the score. Be especially alert to:
- Vagueness where the checklist requires specificity
- Missing coverage of brief requirements not caught by simple checklist matching
- Internal contradictions the producing model may have rationalized away
- Implicit assumptions that contradict the brief's constraints

Process:
1. Check each CHECKLIST item: PASS / FAIL / N/A with one-line reason
2. Identify any blockers (items that prevent downstream stages from succeeding)
3. Identify contested decisions (two legitimate options exist, neither clearly better from the brief)
4. Assign a score and verdict

Score:
- 10: All checklist items pass, no gaps relative to brief
- 8-9: All blockers pass, minor warnings only
- 7: Threshold — all blockers pass, some warnings
- 5-6: Has blockers
- 1-4: Fundamental problems

Output ONLY valid JSON:
{
  "verdict": "PASS" | "FAIL",
  "score": <1-10>,
  "checklist": [{"item": "...", "result": "PASS|FAIL|N/A", "reason": "..."}],
  "blockers": ["..."],
  "critique": "<if FAIL: specific actionable instructions. If PASS: empty string>",
  "suggestions": ["..."],
  "contested_decisions": [
    {
      "section": "<section heading>",
      "decision": "<what was decided>",
      "alternatives": ["<option A>", "<option B>"],
      "why_contested": "<what signal from brief makes this genuinely unclear>"
    }
  ]
}
GRPROMPT

# ─── Launch agents based on attempt number (progressive cost scaling) ─────────

BC_STATUS=0
ECH_STATUS=0
SKIP_ADJUDICATOR=false

if [[ "$ATTEMPT" -ge 3 ]]; then
  # Full ensemble: BC + ECH in parallel, then Adjudicator
  echo "$GATE_INPUT" | claude -p "$BLIND_CRITIC_SYSTEM_PROMPT" --dangerously-skip-permissions \
    > "$TMPDIR_GATE/bc_output" 2>"$TMPDIR_GATE/bc_err" &
  BC_PID=$!

  printf '%s\n\nBRIEF:\n%s' "$GATE_INPUT" "$BRIEF" | claude -p "$EDGE_CASE_HUNTER_SYSTEM_PROMPT" --dangerously-skip-permissions \
    > "$TMPDIR_GATE/ech_output" 2>"$TMPDIR_GATE/ech_err" &
  ECH_PID=$!

  wait $BC_PID || BC_STATUS=$?
  wait $ECH_PID || ECH_STATUS=$?

elif [[ "$ATTEMPT" -eq 2 ]]; then
  # Cross-model review: single Gemini call as independent reviewer
  # Gemini receives full context and produces verdict JSON directly — Adjudicator skipped
  if command -v gemini >/dev/null 2>&1; then
    GEMINI_PROMPT="OUTPUT:
$GATE_INPUT

BRIEF:
$BRIEF

CHECKLIST:
$CHECKLIST"
    GEMINI_STATUS=0
    printf '%s\n' "$GEMINI_PROMPT" | GEMINI_CLI_TRUST_WORKSPACE=true gemini -p "$GEMINI_REVIEWER_SYSTEM_PROMPT" \
      --output-format text -m "$GEMINI_GATE_MODEL" --yolo \
      > "$TMPDIR_GATE/gemini_output" 2>"$TMPDIR_GATE/gemini_err" || GEMINI_STATUS=$?
    if [[ $GEMINI_STATUS -eq 0 && -s "$TMPDIR_GATE/gemini_output" ]]; then
      RESULT=$(cat "$TMPDIR_GATE/gemini_output")
      SKIP_ADJUDICATOR=true
      printf '[BLIND_CRITIC_NOT_RUN: attempt 2 — gemini reviewer used]\n' \
        > "$TMPDIR_GATE/bc_output"
      printf '[EDGE_CASE_HUNTER_NOT_RUN: attempt 2 — gemini reviewer used]\n' \
        > "$TMPDIR_GATE/ech_output"
    else
      printf 'gate.sh: Gemini reviewer failed (exit %s) — falling back to adjudicator-only\n' \
        "$GEMINI_STATUS" >&2
      [[ -s "$TMPDIR_GATE/gemini_err" ]] && cat "$TMPDIR_GATE/gemini_err" >&2
    fi
  else
    printf 'gate.sh: gemini not in PATH — falling back to adjudicator-only\n' >&2
  fi
  # Fallback: adjudicator-only (same as attempt 1) when Gemini unavailable
  if [[ "$SKIP_ADJUDICATOR" == "false" ]]; then
    printf '[BLIND_CRITIC_NOT_RUN: attempt 2 — gemini unavailable, adjudicator fallback]\n' \
      > "$TMPDIR_GATE/bc_output"
    printf '[EDGE_CASE_HUNTER_NOT_RUN: attempt 2 — gemini unavailable, adjudicator fallback]\n' \
      > "$TMPDIR_GATE/ech_output"
  fi

else
  # Attempt 1: adjudicator only — no BC, no ECH
  printf '[BLIND_CRITIC_NOT_RUN: attempt 1 — checklist review only]\n' \
    > "$TMPDIR_GATE/bc_output"
  printf '[EDGE_CASE_HUNTER_NOT_RUN: attempt 1 — checklist review only]\n' \
    > "$TMPDIR_GATE/ech_output"
fi

# ─── Read results with fallback on failure ────────────────────────────────────

if [[ $BC_STATUS -ne 0 ]]; then
  cat "$TMPDIR_GATE/bc_err" >&2
  BC_REPORT="[BLIND_CRITIC_UNAVAILABLE: agent failed (exit $BC_STATUS)]"
else
  BC_REPORT=$(cat "$TMPDIR_GATE/bc_output")
  [[ -n "$BC_REPORT" ]] || BC_REPORT="[BLIND_CRITIC_UNAVAILABLE: agent produced no output]"
fi

if [[ $ECH_STATUS -ne 0 ]]; then
  cat "$TMPDIR_GATE/ech_err" >&2
  ECH_REPORT="[EDGE_CASE_HUNTER_UNAVAILABLE: agent failed (exit $ECH_STATUS)]"
else
  ECH_REPORT=$(cat "$TMPDIR_GATE/ech_output")
  [[ -n "$ECH_REPORT" ]] || ECH_REPORT="[EDGE_CASE_HUNTER_UNAVAILABLE: agent produced no output]"
fi

if [[ "$SKIP_ADJUDICATOR" == "false" ]]; then

  # ─── Build Adjudicator input and run sequentially ────────────────────────────

  ADJUDICATOR_PROMPT="OUTPUT:
$GATE_INPUT

BRIEF:
$BRIEF

CHECKLIST:
$CHECKLIST

BLIND_CRITIC_REPORT:
$BC_REPORT

EDGE_CASE_REPORT:
$ECH_REPORT"

  _gate_start=$(date +%s)
  printf "  [gate] %s  adjudicator started at %s\n" "$STAGE" "$(date '+%H:%M:%S')" >&2
  (
    while true; do
      sleep 15
      printf "  [gate] %s  adjudicator still running (%ds)\n" "$STAGE" "$(( $(date +%s) - _gate_start ))" >&2
    done
  ) &
  _gate_hb_pid=$!

  ADJUDICATOR_STATUS=0
  RESULT=$(echo "$ADJUDICATOR_PROMPT" | claude -p "$ADJUDICATOR_SYSTEM_PROMPT" --dangerously-skip-permissions) || ADJUDICATOR_STATUS=$?

  kill "$_gate_hb_pid" 2>/dev/null || true
  wait "$_gate_hb_pid" 2>/dev/null || true
  printf "  [gate] %s  adjudicator complete (%ds)\n" "$STAGE" "$(( $(date +%s) - _gate_start ))" >&2

  if [[ $ADJUDICATOR_STATUS -ne 0 ]]; then
    echo "gate.sh: adjudicator agent failed (exit $ADJUDICATOR_STATUS)" >&2
    echo '{"verdict":"FAIL","score":1,"checklist":[],"blockers":["Adjudicator agent failed to run (exit '"$ADJUDICATOR_STATUS"')"],"critique":"The adjudicator agent exited non-zero. This is likely a transient error. Retry the gate run.","suggestions":[],"contested_decisions":[]}'
    exit 0
  fi

fi

# ─── Extract JSON from LLM response (handles code fences and preamble prose) ──

RESULT=$(printf '%s\n' "$RESULT" | python3 -c "
import sys, re, json

text = sys.stdin.read()

# Strip markdown code fences anchored at start/end only (avoids corrupting mid-JSON backticks)
text = re.sub(r'^\s*\`\`\`(?:json)?\s*\n?', '', text, count=1, flags=re.IGNORECASE)
text = re.sub(r'\n?\s*\`\`\`\s*$', '', text, flags=re.IGNORECASE)
text = text.strip()

# If direct parse succeeds, use as-is
try:
    json.loads(text)
    print(text)
    sys.exit(0)
except Exception:
    pass

# Find the first { ... } block spanning the text
m = re.search(r'\{.*\}', text, re.DOTALL)
if m:
    candidate = m.group(0)
    try:
        json.loads(candidate)
        print(candidate)
        sys.exit(0)
    except Exception:
        pass

# Nothing extractable — print original so the validation below produces the right error
print(text)
" 2>/dev/null || printf '%s\n' "$RESULT")

# ─── Validate JSON ────────────────────────────────────────────────────────────

if ! printf '%s\n' "$RESULT" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
  # Gate returned non-JSON — treat as a FAIL with a runner error
  echo '{"verdict":"FAIL","score":1,"checklist":[],"blockers":["Gate returned invalid JSON — model response was malformed"],"critique":"The quality gate itself produced a non-JSON response. This is a transient error. Retry the gate run.","suggestions":[],"contested_decisions":[]}'
  exit 0
fi

# ─── Compute BC/ECH issue counts and merge into result ───────────────────────

if [[ -z "$BC_REPORT" || "$BC_REPORT" == \[BLIND_CRITIC_UNAVAILABLE* || "$BC_REPORT" == \[BLIND_CRITIC_NOT_RUN* ]]; then
  BC_SCORE="null"
else
  BC_SCORE=$(printf '%s\n' "$BC_REPORT" | grep -cE '^[0-9]+\. ' || true)
fi

if [[ -z "$ECH_REPORT" || "$ECH_REPORT" == \[EDGE_CASE_HUNTER_UNAVAILABLE* || "$ECH_REPORT" == \[EDGE_CASE_HUNTER_NOT_RUN* ]]; then
  ECH_SCORE="null"
else
  ECH_SCORE=$(printf '%s\n' "$ECH_REPORT" | grep -cE '^[0-9]+\. ' || true)
fi

RESULT=$(printf '%s\n' "$RESULT" | python3 -c "
import sys, json
bc = sys.argv[1]; ech = sys.argv[2]
d = json.load(sys.stdin)
d['blind_critic_score'] = int(bc) if bc != 'null' else None
d['edge_case_score'] = int(ech) if ech != 'null' else None
print(json.dumps(d))
" "$BC_SCORE" "$ECH_SCORE") || { printf '%s\n' '{"verdict":"FAIL","score":1,"checklist":[],"blockers":["Gate score merge failed"],"critique":"Internal error merging BC/ECH scores into result JSON.","suggestions":[],"contested_decisions":[]}'; exit 0; }

if [[ -n "${TRIAGE_FAILING_SECTIONS:-}" && "${TRIAGE_FAILING_SECTIONS:-}" != '[]' ]]; then
  RESULT=$(printf '%s\n' "$RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['triage_failing_sections'] = json.loads(sys.argv[1])
print(json.dumps(d))
" "$TRIAGE_FAILING_SECTIONS") || true
fi

printf '%s\n' "$RESULT"
