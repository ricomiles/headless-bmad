#!/usr/bin/env bash
# run_pipeline.sh — Main pipeline loop
# Called by the orchestrator after initialization.
# Reads PIPELINE_STATE.json, runs pending stages, gates, retries, escalates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
AUTOPILOT_DIR=".autopilot"
STATE_FILE="$AUTOPILOT_DIR/PIPELINE_STATE.json"

# Load stage plan from registry (ordered stages + per-stage capability flags)
PLAN_JSON=$(python3 "$SCRIPT_DIR/load_stage_plan.py") || { echo "[Autopilot] ERROR: load_stage_plan.py failed — registry missing or corrupt" >&2; exit 1; }
read -ra STAGES <<< "$(python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join(d['stages']))" <<< "$PLAN_JSON")"

# Read a capability flag for a given stage from the plan
stage_flag() {
  python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
print('true' if d['flags'].get(sys.argv[1], {}).get(sys.argv[2]) is True else 'false')
" "$1" "$2" <<< "$PLAN_JSON"
}

# Read max_retries for a stage from the plan
stage_retries() {
  python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
print(d['flags'].get(sys.argv[1], {}).get('max_retries', 3))
" "$1" <<< "$PLAN_JSON"
}

# Returns "true" if Decision Engine invocation is allowed; "false" if disabled via PROJECT_BRIEF.md
decision_engine_enabled() {
  if grep -qE '^contested_decision_detection:\s*false' PROJECT_BRIEF.md 2>/dev/null; then
    echo "false"
  else
    echo "true"
  fi
}

# ─── Brief enrichment (analyst stage only) ───────────────────────────────────
# Enriches PROJECT_BRIEF.md so the analyst can produce a passing PRD with fewer
# gate retries. Upfront call expands all implicit details; retry call patches
# exactly what the gate critique flagged as missing.
# Non-blocking: failure logs a warning and the pipeline proceeds with the original.

enrich_brief() {
  local critique_file="${1:-}"

  [[ -f "PROJECT_BRIEF.md" ]] || { log "  ↳ enrich_brief: PROJECT_BRIEF.md not found — skipping"; return 1; }

  local brief system_prompt user_content enriched mode

  brief=$(cat "PROJECT_BRIEF.md")

  if [[ -n "$critique_file" && -f "$critique_file" ]]; then
    mode="retry-patch"
    local critique
    critique=$(cat "$critique_file")

    read -r -d '' system_prompt << 'RETRY_SP' || true
You are a requirements analyst patching a project brief.
An automated PRD pipeline failed its quality gate with the critique provided.
Trace each blocker back to the root brief gap and add the missing information.

For each critique item:
- "Missing FR for X" — add feature X: entry point, inputs, outputs, error cases, defaults
- "Missing AC / no Given/When/Then" — add behavioral specifics (precondition, user action, expected result, error result) for that feature to the brief
- "Contradiction between A and B" — pick one rule, state it explicitly, resolve in the brief
- "Undocumented decision" — add to "## Implicit Decisions": D-NNN: [topic] — [decision] — [rationale]
- "Placeholder / TBD / open question" — replace with a concrete decision

Rules:
- Stay within existing feature scope — do not add wholly new capabilities
- All additions must be concrete and testable (exact numbers, exact behaviors)
- Output ONLY the complete updated PROJECT_BRIEF.md in markdown. No preamble, no code fences.
RETRY_SP

    user_content="PROJECT_BRIEF.md:

${brief}

ANALYST GATE CRITIQUE — trace each item to a brief gap and add the missing information:

${critique}"

  else
    mode="upfront"

    read -r -d '' system_prompt << 'UPFRONT_SP' || true
You are a requirements analyst enriching a project brief before it enters a fully
automated PRD pipeline. The downstream analyst must produce Given/When/Then ACs for
every requirement without guessing. Expand the brief so no guess is needed.

For every feature, add all of the following that are not already explicit:
- Empty/no-data state: what the user sees when there are no entries yet
- Error/failure state: what happens when the operation fails
- Boundary inputs: behavior at min, max, zero, negative values
- Exact numeric values: replace "reasonable", "appropriate", "sensible" with real numbers
- Default values: what every user-configurable field shows before the user changes it
- Sign conventions: what does positive/negative mean for each numeric field?
- Timezone and locale policy: stored as UTC? displayed in device local timezone?
- State transitions: what event triggers each state change?
- Navigation: how does the user reach each screen from the home screen?
- Derived field formulas: exact arithmetic expression, not a prose description

At the document level, add or expand:
- "## Implicit Decisions" section — one D-NNN entry per discretionary choice you make:
    D-001: [topic] — [decision] — [rationale: one sentence]
- "## Out of Scope" — explicitly list anything that could be mistaken as in scope for v1
- "## Non-Functional Requirements" if absent — performance, storage, offline, accessibility, platform version

Rules:
- Do NOT invent new features — only elaborate what is already described
- When a choice is arbitrary, pick the simplest option and document it in Implicit Decisions
- Replace all TBD, TODO, and "to be decided" text with concrete decisions
- Output ONLY the complete enriched PROJECT_BRIEF.md in markdown. No preamble, no code fences.
UPFRONT_SP

    user_content="PROJECT_BRIEF.md:

${brief}"
  fi

  log "  ↳ enrich_brief: running ${mode} enrichment..."

  enriched=$(printf '%s\n' "$user_content" | claude -p "$system_prompt" \
    --dangerously-skip-permissions 2>/dev/null) || {
    log "  ↳ enrich_brief: claude call failed — original brief preserved"
    return 1
  }

  # Strip markdown code fences if the model wrapped output
  enriched=$(printf '%s\n' "$enriched" | python3 -c "
import sys, re
text = sys.stdin.read().strip()
text = re.sub(r'^\x60\x60\x60(?:markdown)?\s*\n?', '', text, count=1, flags=re.IGNORECASE)
text = re.sub(r'\n?\s*\x60\x60\x60\s*$', '', text, flags=re.IGNORECASE)
print(text.strip())
" 2>/dev/null) || true

  if [[ -z "$enriched" || ${#enriched} -lt 200 ]]; then
    log "  ↳ enrich_brief: output empty or too short — original brief preserved"
    return 1
  fi

  local words_before words_after
  words_before=$(wc -w < "PROJECT_BRIEF.md" | tr -d ' ')
  printf '%s\n' "$enriched" > "PROJECT_BRIEF.md"
  words_after=$(wc -w < "PROJECT_BRIEF.md" | tr -d ' ')
  log "  ↳ enrich_brief: ${mode} complete — ${words_before} → ${words_after} words"
}

# ─── Helpers ────────────────────────────────────────────────────────────────

LOG_FILE=".autopilot/pipeline.log"

log() {
  local msg="$*"
  echo "[Autopilot $(date '+%H:%M:%S')] $msg"
  _log_append "pipeline" "" "$msg"
}

_log_append() {
  local type="${1}" stage="${2:-}" msg="${3:-}" extra="${4:-}"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  msg="${msg//\"/\\\"}"
  if [[ -n "$extra" ]]; then
    printf '{"ts":"%s","type":"%s","stage":"%s","msg":"%s",%s}\n' \
      "$ts" "$type" "$stage" "$msg" "$extra" >> "$LOG_FILE" 2>/dev/null || true
  else
    printf '{"ts":"%s","type":"%s","stage":"%s","msg":"%s"}\n' \
      "$ts" "$type" "$stage" "$msg" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

state_get() {
  python3 "$SCRIPT_DIR/update_state.py" get "$1"
}

check_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "ERROR: No pipeline state found. Run: python3 scripts/update_state.py init PROJECT_BRIEF.md"
    exit 1
  fi
}

# ─── Stage runner ────────────────────────────────────────────────────────────

run_stage() {
  local stage="$1"
  log "Starting stage: $stage"
  _log_append "stage" "$stage" "Starting"
  python3 "$SCRIPT_DIR/update_state.py" start "$stage"
  bash "$SCRIPT_DIR/run_stage.sh" "$stage"
}

# ─── Gate runner ─────────────────────────────────────────────────────────────

run_gate() {
  local stage="$1"
  local attempt="$2"
  local allow_triage_escalate="${3:-true}"
  [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=3

  # Determine gate model label for logging
  local gate_model="adjudicator"
  if [[ "$attempt" -eq 2 ]] && command -v gemini >/dev/null 2>&1; then
    gate_model="gemini"
  elif [[ "$attempt" -ge 3 ]]; then
    gate_model="ensemble"
  fi

  log "Running quality gate: $stage (attempt $attempt) [$gate_model]"
  _log_append "gate_start" "$stage" "attempt=$attempt model=$gate_model" "\"attempt\":$attempt,\"model\":\"$gate_model\""

  local gate_output
  gate_output=$(bash "$SCRIPT_DIR/gate.sh" "$stage" "" "$attempt")

  local verdict score critique blind_critic_score edge_case_score contested_count triage_escalate
  verdict=$(echo "$gate_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['verdict'])")
  score=$(echo "$gate_output"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['score'])")
  critique=$(echo "$gate_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('critique',''))")
  blind_critic_score=$(printf '%s\n' "$gate_output" | python3 -c "import sys,json; d=json.load(sys.stdin); v=d.get('blind_critic_score'); print(v if v is not None else 'null')")
  edge_case_score=$(printf '%s\n' "$gate_output" | python3 -c "import sys,json; d=json.load(sys.stdin); v=d.get('edge_case_score'); print(v if v is not None else 'null')")
  contested_count=$(printf '%s\n' "$gate_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('contested_decisions') or []))")
  triage_escalate=$(printf '%s\n' "$gate_output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('true' if d.get('triage_escalate') else 'false')
" 2>/dev/null || echo "false")

  if [[ "$verdict" == "PASS" ]]; then
    log "✓ $stage passed (score $score/10)"
    _log_append "gate_end" "$stage" "PASS score=$score/10 [$gate_model]" "\"verdict\":\"PASS\",\"score\":$score,\"attempt\":$attempt,\"model\":\"$gate_model\""
    python3 "$SCRIPT_DIR/update_state.py" gate "$stage" PASS "$score" "" "$blind_critic_score" "$edge_case_score" "$contested_count"
    # Write contested decisions for Decision Engine (PASS only; FAIL path skips this block)
    mkdir -p "$AUTOPILOT_DIR/stages/$stage"
    : > "$AUTOPILOT_DIR/stages/$stage/contested_decisions.json"
    if [[ "$contested_count" -gt 0 ]]; then
      log "  ↳ $contested_count contested decision(s) flagged — Decision Engine may deliberate"
      printf '%s\n' "$gate_output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for dec in (d.get('contested_decisions') or []):
    print(json.dumps(dec))
" > "$AUTOPILOT_DIR/stages/$stage/contested_decisions.json" 2>/dev/null || true
    fi
    return 0
  else
    log "✗ $stage failed (score $score/10)"
    _log_append "gate_end" "$stage" "FAIL score=$score/10 [$gate_model]" "\"verdict\":\"FAIL\",\"score\":$score,\"attempt\":$attempt,\"model\":\"$gate_model\""
    if [[ "$triage_escalate" == "true" && "$allow_triage_escalate" == "true" ]]; then
      log "  ↳ triage score below threshold — escalating immediately (no retries)"
      python3 "$SCRIPT_DIR/update_state.py" gate "$stage" FAIL "$score" "$critique" "$blind_critic_score" "$edge_case_score" "$contested_count"
      mkdir -p "$AUTOPILOT_DIR/stages/$stage"
      echo "$critique" > "$AUTOPILOT_DIR/stages/$stage/critique_${attempt}.md"
      escalate_triage "$stage" "$critique"
      # escalate_triage calls exit 2 — unreachable
    fi
    if [[ -n "$critique" ]]; then
      log "  Critique: ${critique:0:120}..."
    fi
    python3 "$SCRIPT_DIR/update_state.py" gate "$stage" FAIL "$score" "$critique" "$blind_critic_score" "$edge_case_score" "$contested_count"

    # Save critique file for retry context
    mkdir -p "$AUTOPILOT_DIR/stages/$stage"
    echo "$critique" > "$AUTOPILOT_DIR/stages/$stage/critique_${attempt}.md"
    return 1
  fi
}

# ─── Escalation ──────────────────────────────────────────────────────────────

escalate() {
  local stage="$1"
  local max_retries="${2:-3}"

  log "⚠ Escalating: $stage failed $max_retries times"
  python3 "$SCRIPT_DIR/update_state.py" escalate "$stage"

  # Collect all critiques
  local critiques=""
  for i in $(seq 1 $max_retries); do
    local crit_file="$AUTOPILOT_DIR/stages/$stage/critique_${i}.md"
    if [[ -f "$crit_file" ]]; then
      critiques+="### Attempt $i\n$(cat "$crit_file")\n\n"
    fi
  done

  # Generate escalation file
  cat > "$AUTOPILOT_DIR/ESCALATION.md" <<EOF
# Escalation required — $stage

The pipeline cannot proceed automatically.
Stage **$stage** failed quality gates $max_retries times.

## What you need to do

Review the critiques below. The most common cause is the PROJECT_BRIEF.md
not providing enough detail on a specific point. Update the brief with the
missing information, then resume:

\`\`\`bash
bash scripts/run_pipeline.sh
\`\`\`

## Critique history

$(echo -e "$critiques")

## Stage output (last attempt)

See: $AUTOPILOT_DIR/stages/$stage/output.md

## Pipeline state

$(python3 "$SCRIPT_DIR/update_state.py" status)
EOF

  log "Escalation written to $AUTOPILOT_DIR/ESCALATION.md"
  log "Autonomous synthesis also failed. Human input required."
  exit 2
}

# ─── Triage escalation (score < 5 — fundamentally broken, no retries) ────────

escalate_triage() {
  local stage="$1"
  local diagnosis="$2"

  log "⚠ Escalating: $stage — triage score below recoverable threshold (score < 5)"
  python3 "$SCRIPT_DIR/update_state.py" escalate "$stage"

  cat > "$AUTOPILOT_DIR/ESCALATION.md" <<EOF
# Escalation required — $stage (triage)

The pipeline cannot proceed automatically.
Stage **$stage** received a triage score below 5. This indicates the output is fundamentally
broken and will not improve with retries — the source brief likely lacks sufficient detail.

## Triage diagnosis

$diagnosis

## What you need to do

1. Review the stage output: \`$AUTOPILOT_DIR/stages/$stage/output.md\`
2. Identify what context the stage was missing or what brief constraint was unclear
3. Update \`PROJECT_BRIEF.md\` with the missing information
4. Resume the pipeline:

\`\`\`bash
bash scripts/run_pipeline.sh
\`\`\`

## Stage output (last attempt)

See: $AUTOPILOT_DIR/stages/$stage/output.md

## Pipeline state

$(python3 "$SCRIPT_DIR/update_state.py" status)
EOF

  log "Escalation written to $AUTOPILOT_DIR/ESCALATION.md"
  log "Triage determined output is fundamentally broken. Human input required."
  exit 2
}

# ─── Autonomous synthesis ─────────────────────────────────────────────────────
# Called after max_retries normal failures. Combines all critique feedback and
# instructs the model to make explicit autonomous decisions on every open point.
# Returns 0 if the synthesis gate passes, 1 if it also fails.

auto_resolve() {
  local stage="$1"
  local max_retries="${2:-3}"
  log "→ $stage failed $max_retries times. Attempting autonomous synthesis..."
  log "  Combining all critiques — model will decide all ambiguities."

  export SYNTHESIS_PASS=1
  run_stage "$stage"
  unset SYNTHESIS_PASS

  if run_gate "$stage" "synthesis" "false"; then
    log "✓ Autonomous synthesis resolved $stage"
    return 0
  fi

  log "✗ Synthesis pass also failed for $stage"
  return 1
}

# ─── Repair-loop escalation ───────────────────────────────────────────────────

escalate_repair_loop() {
  local stage="$1"
  local repair_cycles_done="$2"

  log "⚠ Escalating: $stage failed after $repair_cycles_done repair cycle(s)"
  python3 "$SCRIPT_DIR/update_state.py" escalate "$stage"

  local history
  history="## Original $stage failure"$'\n\n'
  local original_out="$AUTOPILOT_DIR/stages/$stage/output_repair_0.md"
  if [[ -f "$original_out" ]]; then
    history+="$(cat "$original_out")"$'\n\n'
  fi

  for i in $(seq 1 "$repair_cycles_done"); do
    local pf_out="$AUTOPILOT_DIR/stages/$stage/parse_failures_${i}.json"
    if [[ -f "$pf_out" ]]; then
      history+=$'\n## Repair cycle '"$i"$' — failing tickets (parse_failures)\n\n```json\n'
      history+="$(cat "$pf_out")"
      history+=$'\n```\n\n'
    fi
    local cycle_out="$AUTOPILOT_DIR/stages/$stage/output_repair_${i}.md"
    if [[ -f "$cycle_out" ]]; then
      history+=$'\n## Repair cycle '"$i"$' — '"$stage"$' output\n\n'
      history+="$(cat "$cycle_out")"$'\n\n'
    fi
  done

  cat > "$AUTOPILOT_DIR/ESCALATION.md" <<EOF
# Escalation required — $stage (repair loop exhausted)

The $stage stage failed after $repair_cycles_done repair cycle(s) and cannot proceed automatically.

## What you need to do

Review the failure history below. Common causes:
- Test assertion relies on environment state not reproducible in automation
- An architectural decision needs changing (update PROJECT_BRIEF.md and re-run)
- A ticket's implementation has a logic error that the repair agent couldn't resolve

After fixing, resume with:
\`\`\`bash
bash scripts/run_pipeline.sh
\`\`\`

${history}

## Pipeline state

$(python3 "$SCRIPT_DIR/update_state.py" status)
EOF

  log "Escalation written to $AUTOPILOT_DIR/ESCALATION.md"
  exit 2
}

# ─── Security-scan escalation ─────────────────────────────────────────────────

escalate_security() {
  local stage="$1"
  local arch_attempts="$2"
  local arch_max="$3"

  log "⚠ Escalating: $stage failed after $arch_attempts architect retry attempt(s)"
  python3 "$SCRIPT_DIR/update_state.py" escalate "$stage"

  local sec_findings=""
  local sec_findings_file="$AUTOPILOT_DIR/stages/security-scan/output.md"
  if [[ -f "$sec_findings_file" ]]; then
    sec_findings=$(cat "$sec_findings_file")
  fi

  local arch_critiques=""
  for i in $(seq 1 "$arch_attempts"); do
    local arch_crit_file="$AUTOPILOT_DIR/stages/architect/critique_${i}.md"
    if [[ -f "$arch_crit_file" ]]; then
      arch_critiques+="### Architect attempt $i"$'\n'"$(cat "$arch_crit_file")"$'\n\n'
    fi
  done

  cat > "$AUTOPILOT_DIR/ESCALATION.md" <<EOF
# Escalation required — security-scan

The pipeline cannot proceed automatically.
The **security-scan** stage failed, and the **architect** was retried $arch_attempts time(s)
but could not resolve all CRITICAL and HIGH findings.

## What you need to do

Review the security findings below. Determine which finding requires a human decision
(e.g. a constraint in the brief that conflicts with security best practice, or a
technology choice that needs replacing). Update **PROJECT_BRIEF.md** or the architecture
document directly, then resume:

\`\`\`bash
bash scripts/run_pipeline.sh
\`\`\`

**Which finding needs your input?** Review the "Required before task-breakdown" section
in the security review below and decide which item the architect could not resolve without
human guidance.

## Latest security review findings

$sec_findings

## Architect retry history

$arch_critiques

## Pipeline state

$(python3 "$SCRIPT_DIR/update_state.py" status)
EOF

  log "Escalation written to $AUTOPILOT_DIR/ESCALATION.md"
  log "Review security findings and update PROJECT_BRIEF.md, then re-run the pipeline."
  exit 2
}

# ─── Main loop ───────────────────────────────────────────────────────────────

main() {
  check_state
  log "Resuming pipeline..."
  python3 "$SCRIPT_DIR/update_state.py" status

  for stage in "${STAGES[@]}"; do
    local status
    status=$(state_get "stages.$stage.status")

    if [[ "$status" == "passed" ]]; then
      log "↷ Skipping $stage (already passed)"
      continue
    fi

    if [[ "$status" == "escalated" ]]; then
      log "Pipeline previously escalated at $stage. Running autonomous synthesis..."
      local stage_max_retries
      stage_max_retries=$(stage_retries "$stage")
      if auto_resolve "$stage" "$stage_max_retries"; then
        log "✓ $stage resolved via synthesis — continuing pipeline"
        continue
      else
        escalate "$stage" "$stage_max_retries"
      fi
    fi

    local is_parallelizable is_repair_loop
    is_parallelizable=$(stage_flag "$stage" "parallelizable") || { log "ERROR: stage_flag failed for $stage parallelizable"; exit 1; }
    is_repair_loop=$(stage_flag "$stage" "repair_loop") || { log "ERROR: stage_flag failed for $stage repair_loop"; exit 1; }

    # Parallelizable stage: agent-orchestrated parallel execution
    if [[ "$is_parallelizable" == "true" ]]; then
      log "Starting $stage stage (agent-orchestrated)"
      python3 "$SCRIPT_DIR/update_state.py" start "$stage"
      mkdir -p "$AUTOPILOT_DIR/stages/$stage"
      bash "$SCRIPT_DIR/run_developer_agent.sh"
      continue

    # Repair-loop stage: targeted repair loop on gate failure
    elif [[ "$is_repair_loop" == "true" ]]; then
      local max_repair_cycles
      max_repair_cycles=$(python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
print(d['flags'].get(sys.argv[1], {}).get('repair_loop_max_cycles', 2))
" "$stage" <<< "$PLAN_JSON") || { log "ERROR: failed to read repair_loop_max_cycles for $stage"; exit 1; }
      [[ "$max_repair_cycles" =~ ^[0-9]+$ ]] || { log "ERROR: invalid repair_loop_max_cycles '${max_repair_cycles}' for $stage"; exit 1; }

      local repair_target
      repair_target=$(python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
targets = d['flags'].get(sys.argv[1], {}).get('repair_targets', [])
print(targets[0] if targets else '')
" "$stage" <<< "$PLAN_JSON")

      if [[ -z "$repair_target" ]]; then
        log "ERROR: $stage has repair_loop:true but no repair_targets in registry"
        exit 1
      fi

      log "Starting $stage stage (repair-loop capable, max cycles: $max_repair_cycles)"
      python3 "$SCRIPT_DIR/update_state.py" start "$stage"

      local repair_cycle=0
      local reviewer_passed=false

      # Initial stage run
      bash "$SCRIPT_DIR/run_stage.sh" "$stage" || true
      # Save output before first gate evaluation
      cp "$AUTOPILOT_DIR/stages/$stage/output.md" \
         "$AUTOPILOT_DIR/stages/$stage/output_repair_0.md" 2>/dev/null || true

      while true; do
        if run_gate "$stage" "$((repair_cycle + 1))" "false"; then
          reviewer_passed=true
          break
        fi

        if [[ $repair_cycle -ge $max_repair_cycles ]]; then
          log "$stage repair cycles exhausted ($max_repair_cycles)"
          break
        fi

        repair_cycle=$((repair_cycle + 1))
        log "$stage failed — repair cycle $repair_cycle/$max_repair_cycles"

        # Increment repair_cycles in state
        python3 "$SCRIPT_DIR/update_state.py" repair_cycle "$stage"

        # Parse failures from stage output
        local repair_json
        repair_json=$(python3 "$SCRIPT_DIR/parse_failures.py" \
          --reviewer-output "$AUTOPILOT_DIR/stages/$stage/output.md" \
          --manifest-dir "$AUTOPILOT_DIR/stages/task-breakdown/manifests") || {
          log "WARNING: parse_failures.py failed — cannot identify failing tickets; escalating"
          break
        }

        # Save parse_failures output for escalation history
        printf '%s\n' "$repair_json" > "$AUTOPILOT_DIR/stages/$stage/parse_failures_${repair_cycle}.json" 2>/dev/null || true

        # Extract known ticket IDs (exclude "unknown"), one per line
        local failing_tickets
        failing_tickets=$(printf '%s\n' "$repair_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k in d.keys():
    if k != 'unknown':
        print(k)
")

        if [[ -z "$failing_tickets" ]]; then
          log "WARNING: no tickets identified in failure output — escalating"
          break
        fi

        while IFS= read -r ticket_id; do
          [[ -z "$ticket_id" ]] && continue
          log "Repairing $ticket_id (repair cycle $repair_cycle)"
          local repair_dir="$AUTOPILOT_DIR/stages/$repair_target/$ticket_id"
          mkdir -p "$repair_dir"

          # Write repair critique for this ticket
          printf '%s\n' "$repair_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
cycle = sys.argv[1]
tid = sys.argv[2]
entry = d.get(tid, {})
failures = entry.get('failures', [])
print(f'REPAIR CYCLE {cycle}: Fix only the following test failures. Do not change other behavior.')
print()
for f in failures:
    line_ref = f'{f[\"file\"]}:{f[\"line\"]}' if f.get('line') else f['file']
    print(f'- {line_ref} — {f[\"message\"]}')
" "$repair_cycle" "$ticket_id" > "$repair_dir/critique_${repair_cycle}.md"

          # Re-run repair target for this ticket (manifest-scoped)
          bash "$SCRIPT_DIR/run_stage.sh" "$repair_target" "$ticket_id" || true
          python3 "$SCRIPT_DIR/update_state.py" repair_cycle ticket "$ticket_id"
        done <<< "$failing_tickets"

        # Re-run stage and save output copy for escalation history
        bash "$SCRIPT_DIR/run_stage.sh" "$stage" || true
        cp "$AUTOPILOT_DIR/stages/$stage/output.md" \
           "$AUTOPILOT_DIR/stages/$stage/output_repair_${repair_cycle}.md" 2>/dev/null || true
      done

      if [[ "$reviewer_passed" == "false" ]]; then
        escalate_repair_loop "$stage" "$repair_cycle"
      fi
      continue

    elif [[ "$stage" == "security-scan" ]]; then
      # Security-scan: on failure, inject findings into architect and retry architect
      local arch_max_retries
      arch_max_retries=$(stage_retries "architect")
      [[ "$arch_max_retries" =~ ^[0-9]+$ ]] || { log "ERROR: invalid architect max_retries '${arch_max_retries}'"; exit 1; }

      run_stage "$stage"

      local arch_attempt=0
      local security_passed=false

      while true; do
        if run_gate "$stage" "$((arch_attempt + 1))" "false"; then
          security_passed=true
          break
        fi

        arch_attempt=$((arch_attempt + 1))
        if [[ $arch_attempt -gt $arch_max_retries ]]; then
          log "Architect retries exhausted ($arch_max_retries) — security-scan still failing"
          break
        fi

        log "Security-scan failed — injecting findings into architect (retry $arch_attempt/$arch_max_retries)"

        # Run architect; on gate failure retry it directly without re-gating security-scan
        # (output hasn't changed — a re-gate would always fail and burn a retry slot)
        while true; do
          python3 "$SCRIPT_DIR/update_state.py" start "architect"
          run_stage "architect"

          if run_gate "architect" "$arch_attempt" "false"; then
            break  # architect passed; proceed to re-run security-scan
          fi

          log "Architect failed gate on security-findings retry $arch_attempt"
          if [[ $arch_attempt -ge $arch_max_retries ]]; then
            log "Architect max retries reached — escalating"
            break 2
          fi
          arch_attempt=$((arch_attempt + 1))
          log "Security-scan still failing — re-running architect (retry $arch_attempt/$arch_max_retries)"
        done

        log "Architect passed — re-running security-scan against updated architecture"
        python3 "$SCRIPT_DIR/update_state.py" start "$stage"
        run_stage "$stage"
        # loop back to gate security-scan at top of while
      done

      if [[ "$security_passed" == "false" ]]; then
        local effective_attempts=$(( arch_attempt > arch_max_retries ? arch_max_retries : arch_attempt ))
        escalate_security "$stage" "$effective_attempts" "$arch_max_retries"
      fi

    elif [[ "$stage" == "integration-validator" ]]; then
      # Integration-validator: script-driven stage with targeted developer repair loop
      local iv_max_retries
      iv_max_retries=$(stage_retries "$stage")
      [[ "$iv_max_retries" =~ ^[0-9]+$ ]] || { log "ERROR: invalid max_retries '${iv_max_retries}' for $stage"; exit 1; }

      local repair_cycle=0
      local iv_passed=false

      # Initial run (run_stage.sh executes validate_interfaces.py internally)
      log "Starting $stage stage (targeted repair capable, max cycles: $iv_max_retries)"
      python3 "$SCRIPT_DIR/update_state.py" start "$stage"
      bash "$SCRIPT_DIR/run_stage.sh" "$stage" || true
      cp "$AUTOPILOT_DIR/stages/$stage/output.md" \
         "$AUTOPILOT_DIR/stages/$stage/output_repair_0.md" 2>/dev/null || true

      while true; do
        if run_gate "$stage" "$((repair_cycle + 1))" "false"; then
          iv_passed=true
          break
        fi

        if [[ $repair_cycle -ge $iv_max_retries ]]; then
          log "$stage repair cycles exhausted ($iv_max_retries)"
          break
        fi

        repair_cycle=$((repair_cycle + 1))
        log "$stage failed — repair cycle $repair_cycle/$iv_max_retries"

        # Parse IV failures to find affected tickets
        local repair_json
        repair_json=$(python3 "$SCRIPT_DIR/parse_iv_failures.py" \
          --iv-output "$AUTOPILOT_DIR/stages/$stage/output.md" \
          --manifest-dir "$AUTOPILOT_DIR/stages/task-breakdown/manifests") || {
          log "WARNING: parse_iv_failures.py failed — cannot identify failing tickets; escalating"
          break
        }

        printf '%s\n' "$repair_json" \
          > "$AUTOPILOT_DIR/stages/$stage/parse_failures_${repair_cycle}.json" 2>/dev/null || true

        local failing_tickets
        failing_tickets=$(printf '%s\n' "$repair_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k in d.keys():
    if k != 'unknown':
        print(k)
")

        if [[ -z "$failing_tickets" ]]; then
          log "WARNING: no tickets identified in IV failure output — escalating"
          break
        fi

        while IFS= read -r ticket_id; do
          [[ -z "$ticket_id" ]] && continue
          log "Repairing $ticket_id (IV repair cycle $repair_cycle)"
          local repair_dir="$AUTOPILOT_DIR/stages/developer/$ticket_id"
          mkdir -p "$repair_dir"

          printf '%s\n' "$repair_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
cycle = sys.argv[1]
tid = sys.argv[2]
entry = d.get(tid, {})
failures = entry.get('failures', [])
print(f'REPAIR CYCLE {cycle}: Fix only the following interface contract violations. Do not change other behavior.')
print()
for f in failures:
    line_ref = f'{f[\"file\"]}:{f[\"line\"]}' if f.get('line') else f['file']
    print(f'- {line_ref} — {f[\"message\"]}')
" "$repair_cycle" "$ticket_id" > "$repair_dir/critique_${repair_cycle}.md"

          bash "$SCRIPT_DIR/run_stage.sh" developer "$ticket_id" || true
          python3 "$SCRIPT_DIR/update_state.py" repair_cycle ticket "$ticket_id"
        done <<< "$failing_tickets"

        # Re-run integration-validator and save output copy for escalation history
        python3 "$SCRIPT_DIR/update_state.py" start "$stage"
        bash "$SCRIPT_DIR/run_stage.sh" "$stage" || true
        cp "$AUTOPILOT_DIR/stages/$stage/output.md" \
           "$AUTOPILOT_DIR/stages/$stage/output_repair_${repair_cycle}.md" 2>/dev/null || true
      done

      if [[ "$iv_passed" == "false" ]]; then
        escalate_repair_loop "$stage" "$repair_cycle"
      fi

    else
      # Standard stage: run → gate → retry loop
      local attempt=1
      local stage_passed=false
      local max_retries
      max_retries=$(stage_retries "$stage")
      [[ "$max_retries" =~ ^[0-9]+$ ]] || { log "ERROR: invalid max_retries '${max_retries}' for stage $stage"; exit 1; }

      # Analyst only: enrich brief before first attempt to reduce gate retries
      if [[ "$stage" == "analyst" ]]; then
        log "Enriching PROJECT_BRIEF.md before analyst stage..."
        enrich_brief || true
      fi

      while [[ $attempt -le $max_retries ]]; do
        run_stage "$stage"

        if run_gate "$stage" "$attempt"; then
          stage_passed=true
          if [[ "$(decision_engine_enabled)" == "true" ]] && [[ "$(stage_flag "$stage" "decision_engine")" == "true" ]]; then
            local de_decisions_file="$AUTOPILOT_DIR/stages/$stage/contested_decisions.json"
            if [[ -f "$de_decisions_file" ]]; then
              while IFS= read -r decision_json; do
                [[ -z "$decision_json" ]] && continue
                local de_label
                de_label=$(python3 -c "import sys,json; print(json.loads(sys.argv[1]).get('decision','<unknown>')[:80])" "$decision_json" 2>/dev/null || echo "<unknown>")
                log "Running Decision Engine for: $de_label"
                bash "$SCRIPT_DIR/decision-engine.sh" "$decision_json" || \
                  log "WARNING: Decision Engine failed for '$de_label' — continuing"
              done < "$de_decisions_file"
            fi
          elif [[ -f "$AUTOPILOT_DIR/stages/$stage/contested_decisions.json" ]]; then
            log "Decision Engine disabled — contested decisions for $stage logged but not deliberated"
          fi
          break
        fi

        if [[ $attempt -lt $max_retries ]]; then
          # Analyst only: patch brief with gate critique before retry
          if [[ "$stage" == "analyst" ]]; then
            local crit_file="$AUTOPILOT_DIR/stages/analyst/critique_${attempt}.md"
            if [[ -f "$crit_file" ]]; then
              log "Patching brief with analyst critique ${attempt} before retry..."
              enrich_brief "$crit_file" || true
            fi
          fi
          log "Retrying $stage (attempt $((attempt+1))/$max_retries)..."
          _log_append "retry" "$stage" "attempt $((attempt+1))/$max_retries" "\"attempt\":$((attempt+1)),\"max\":$max_retries"
        fi

        ((attempt++))
      done

      if [[ "$stage_passed" == "false" ]]; then
        if auto_resolve "$stage" "$max_retries"; then
          stage_passed=true
        else
          escalate "$stage" "$max_retries"
        fi
      fi
    fi
  done

  # All stages passed
  log "All stages complete. Assembling deliverables..."
  python3 "$SCRIPT_DIR/assemble.py"
  python3 "$SCRIPT_DIR/update_state.py" complete

  log "Pipeline complete. Deliverables in .autopilot/DELIVERABLES/"
  python3 "$SCRIPT_DIR/update_state.py" status
}

main "$@"
