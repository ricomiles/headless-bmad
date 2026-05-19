#!/usr/bin/env bash
# run_stage.sh — Invoke a single BMAD stage non-interactively
# Usage: bash scripts/run_stage.sh <stage_name>
#
# Resolves the corresponding BMAD-v6 skill for each stage, loads its full
# content (SKILL.md + step files + templates), and invokes it via claude -p
# with [PIPELINE_MODE: autonomous] to bypass interactive pauses.
# Falls back to hardcoded prompts if the skill cannot be resolved.

set -euo pipefail

STAGE="${1:?Usage: run_stage.sh <stage_name> [ticket_id]}"
TICKET_ID="${2:-}"
if [[ -n "$TICKET_ID" && ! "$TICKET_ID" =~ ^[A-Z]+-[0-9]+$ ]]; then
  echo "ERROR: invalid TICKET_ID: $TICKET_ID (expected format: TASK-NNN)" >&2
  exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOPILOT_DIR=".autopilot"
STATE_FILE="$AUTOPILOT_DIR/PIPELINE_STATE.json"
OUTPUT_DIR="$AUTOPILOT_DIR/stages/$STAGE"
AUTOPILOT_OUTPUT="$OUTPUT_DIR/output.md"   # always written (stdout capture)

# Per-ticket output path for manifest-scoped developer invocation
if [[ -n "$TICKET_ID" && "$STAGE" == "developer" ]]; then
  OUTPUT_DIR="$AUTOPILOT_DIR/stages/$STAGE/$TICKET_ID"
  AUTOPILOT_OUTPUT="$OUTPUT_DIR/output.md"
fi

mkdir -p "$OUTPUT_DIR"

# ─── Skill resolution ────────────────────────────────────────────────────────
# Script lives at src/core-skills/headless-bmad/scripts/ inside the repo.
# BMAD-v6 skills live at src/bmm-skills/<phase>/<skill-name>/.
# Falls back to global install (~/.claude/skills/) if run from outside the repo.

resolve_bmad_skill() {
  local skill_name="$1"

  # Primary: repo-relative lookup (src/core-skills/bmad-headless/scripts/ → src/bmm-skills/)
  local skill_root bmad_src
  skill_root="$(cd "$SCRIPT_DIR/.." && pwd)"  # src/core-skills/bmad-headless/
  bmad_src="$(cd "$skill_root/../../bmm-skills" && pwd 2>/dev/null)" || true

  if [[ -n "$bmad_src" && -d "$bmad_src" ]]; then
    for phase_dir in \
      "$bmad_src/1-analysis" \
      "$bmad_src/2-plan-workflows" \
      "$bmad_src/3-solutioning" \
      "$bmad_src/4-implementation"; do
      if [[ -d "$phase_dir/$skill_name" ]]; then
        echo "$phase_dir/$skill_name"
        return 0
      fi
    done
    # Nested subdirs (e.g. 1-analysis/research/bmad-domain-research)
    local found
    found=$(find "$bmad_src" -type d -name "$skill_name" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
      echo "$found"
      return 0
    fi
  fi

  # Project-local install (.claude/skills/ sibling — bmad project install)
  # SCRIPT_DIR/../.. resolves to the .claude/skills/ directory
  local project_skills
  project_skills="$(cd "$SCRIPT_DIR/../.." && pwd 2>/dev/null)" || true
  if [[ -n "$project_skills" && -d "$project_skills/$skill_name" ]]; then
    echo "$project_skills/$skill_name"
    return 0
  fi

  # Fallback: global install
  if [[ -d "$HOME/.claude/skills/$skill_name" ]]; then
    echo "$HOME/.claude/skills/$skill_name"
    return 0
  fi

  return 1
}

# Stage → BMAD-v6 skill mapping
get_stage_skill() {
  case "$1" in
    analyst)           echo "bmad-create-prd" ;;
    architect)         echo "bmad-create-architecture" ;;
    task-breakdown)    echo "" ;;                              # use hardcoded v2 prompt
    developer)         echo "bmad-dev-story" ;;           # per-story, called from run_dev_story.sh
    context-ingestion) echo "bmad-document-project" ;;
    context-validator) echo "" ;;                         # uses hardcoded system prompt
    reviewer)          echo "" ;;                          # keeps hardcoded prompt (runs bash tests)
    *)                 echo "" ;;
  esac
}

# Stage → canonical BMAD-v6 artifact output path
get_bmad_output_path() {
  case "$1" in
    analyst)           echo "docs/prd.md" ;;
    architect)         echo "docs/architecture.md" ;;
    task-breakdown)    echo "$AUTOPILOT_DIR/stages/task-breakdown/output.md" ;;
    context-ingestion) echo "docs/project-context.md" ;;
    *)                 echo "$AUTOPILOT_OUTPUT" ;;
  esac
}

# ─── Skill content loader ─────────────────────────────────────────────────────
# Concatenates SKILL.md + step files (sorted) + templates from a skill dir.

load_skill_content() {
  local skill_dir="$1"
  local content=""

  # SKILL.md — contains the autonomous mode block we added
  if [[ -f "$skill_dir/SKILL.md" ]]; then
    content+="$(cat "$skill_dir/SKILL.md")"$'\n\n'
  fi

  # Step files — load all in sorted order from any steps* subdir
  for steps_dir in \
    "$skill_dir/steps" \
    "$skill_dir/steps-c" \
    "$skill_dir/steps-e" \
    "$skill_dir/steps-v"; do
    if [[ -d "$steps_dir" ]]; then
      while IFS= read -r -d '' step_file; do
        content+="--- Step: $(basename "$step_file") ---"$'\n'
        content+="$(cat "$step_file")"$'\n\n'
      done < <(find "$steps_dir" -maxdepth 1 -name "*.md" -print0 | sort -z)
      break
    fi
  done

  # Instructions file (used by bmad-document-project and similar)
  if [[ -f "$skill_dir/instructions.md" ]]; then
    content+="--- Instructions ---"$'\n'
    content+="$(cat "$skill_dir/instructions.md")"$'\n\n'
  fi

  # Templates — include output templates so the model knows the expected format
  for tmpl_dir in "$skill_dir/templates" "$skill_dir/data"; do
    if [[ -d "$tmpl_dir" ]]; then
      while IFS= read -r -d '' tmpl; do
        content+="--- Template: $(basename "$tmpl") ---"$'\n'
        content+="$(cat "$tmpl")"$'\n\n'
      done < <(find "$tmpl_dir" -maxdepth 1 -name "*.md" -print0 | sort -z)
    fi
  done

  echo "$content"
}

# ─── Persona loading ─────────────────────────────────────────────────────────
# Maps each stage to its BMAD-v6 agent skill and extracts the Overview section
# (the persona identity) to prepend to the system prompt.

get_stage_persona_skill() {
  case "$1" in
    analyst)           echo "bmad-agent-analyst" ;;
    architect)         echo "bmad-agent-architect" ;;
    task-breakdown)    echo "bmad-agent-pm" ;;
    context-ingestion) echo "bmad-agent-analyst" ;;
    context-validator) echo "bmad-agent-analyst" ;;
    developer)         echo "bmad-agent-dev" ;;
    reviewer)          echo "" ;;
    *)                 echo "" ;;
  esac
}

load_persona_overview() {
  local skill_md="$1/SKILL.md"
  [[ ! -f "$skill_md" ]] && return
  python3 - "$skill_md" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
# Extract title line + Overview section, stopping before the next ## heading
m = re.search(r'^(# .+?\n\n## Overview\n.+?)(?=\n## )', content, re.DOTALL | re.MULTILINE)
if m:
    print(m.group(1).strip())
PYEOF
}

# ─── Design injection ────────────────────────────────────────────────────────

DESIGN_CONTEXT=""
if [[ "$STAGE" == "analyst" || "$STAGE" == "architect" || "$STAGE" == "developer" ]]; then
  DESIGN_CONTEXT=$(python3 "$SCRIPT_DIR/inject_designs.py" "$STAGE" 2>/dev/null || true)

  IMAGE_FLAGS=()
  if echo "$DESIGN_CONTEXT" | grep -q "^IMAGE_INJECT:"; then
    IMAGE_LINE=$(echo "$DESIGN_CONTEXT" | grep "^IMAGE_INJECT:")
    IFS=':' read -ra IMAGE_PATHS <<< "${IMAGE_LINE#IMAGE_INJECT:}"
    for img in "${IMAGE_PATHS[@]}"; do
      [[ -f "$img" ]] && IMAGE_FLAGS+=("--image" "$img")
    done
    DESIGN_CONTEXT=$(echo "$DESIGN_CONTEXT" | grep -v "^IMAGE_INJECT:")
  fi

  if echo "$DESIGN_CONTEXT" | grep -q "^FIGMA_INJECT:"; then
    FIGMA_LINE=$(echo "$DESIGN_CONTEXT" | grep "^FIGMA_INJECT:")
    IFS=':' read -ra FIGMA_PARTS <<< "${FIGMA_LINE#FIGMA_INJECT:}"
    FILE_KEY="${FIGMA_PARTS[0]}"
    FRAME_NAMES="${FIGMA_PARTS[1]:-}"
    FIGMA_IMG_DIR=".autopilot/stages/$STAGE/figma-frames"
    mkdir -p "$FIGMA_IMG_DIR"
    python3 "$SCRIPT_DIR/fetch_figma_frames.py" "$FILE_KEY" "$FRAME_NAMES" "$FIGMA_IMG_DIR" 2>/dev/null || true
    for img in "$FIGMA_IMG_DIR"/*.png; do
      [[ -f "$img" ]] && IMAGE_FLAGS+=("--image" "$img")
    done
    DESIGN_CONTEXT=$(echo "$DESIGN_CONTEXT" | grep -v "^FIGMA_INJECT:")
  fi
fi

# ─── Build context ────────────────────────────────────────────────────────────

BRIEF=$(cat PROJECT_BRIEF.md)
STATE=$(cat "$STATE_FILE")

PRIOR_CONTEXT=""
gather_prior() {
  local prior_stage="$1"
  local prior_file="$AUTOPILOT_DIR/stages/$prior_stage/output.md"

  # Prefer BMAD canonical path if it exists (richer content)
  local bmad_path
  bmad_path=$(get_bmad_output_path "$prior_stage")
  if [[ -f "$bmad_path" ]]; then
    prior_file="$bmad_path"
  fi

  if [[ -f "$prior_file" ]]; then
    PRIOR_CONTEXT+="
=== OUTPUT FROM STAGE: $prior_stage ===
$(cat "$prior_file")

"
  fi
}

case "$STAGE" in
  context-ingestion)
    PRIOR_CONTEXT=""
    ;;
  context-validator)
    gather_prior "context-ingestion"
    ;;
  analyst)
    gather_prior "context-ingestion"
    # Inject context-validator conflict report in brownfield mode
    cv_output="$AUTOPILOT_DIR/stages/context-validator/output.md"
    if [[ -f "$cv_output" ]]; then
      PRIOR_CONTEXT+="
=== CONTEXT VALIDATION CONFLICTS — ALL ### CONFLICT- ITEMS MUST BE EXPLICITLY ADDRESSED IN YOUR SPRINT SCOPE DOCUMENT ===
$(cat "$cv_output")

"
    fi
    ;;
  architect)
    gather_prior "context-ingestion"
    gather_prior "analyst"
    # Inject context-validator conflict report in brownfield mode
    cv_output="$AUTOPILOT_DIR/stages/context-validator/output.md"
    if [[ -f "$cv_output" ]]; then
      PRIOR_CONTEXT+="
=== CONTEXT VALIDATION CONFLICTS — ARCHITECTURE AND ADRS MUST RESOLVE ALL ### CONFLICT- ITEMS ===
$(cat "$cv_output")

"
    fi
    # Inject security-scan findings when re-running architect after security-scan failure
    sec_output="$AUTOPILOT_DIR/stages/security-scan/output.md"
    sec_status=$(python3 -c "
import json, sys
try:
    s = json.load(open(sys.argv[1] + '/PIPELINE_STATE.json'))
    print(s.get('stages', {}).get('security-scan', {}).get('status', 'absent'))
except Exception:
    print('absent')
" "$AUTOPILOT_DIR" 2>/dev/null || echo "absent")
    if [[ "$sec_status" == "pending" && -f "$sec_output" ]]; then
      PRIOR_CONTEXT+="
=== SECURITY REVIEW FINDINGS — ADDRESS ALL CRITICAL AND HIGH ITEMS BEFORE REGENERATING THE ARCHITECTURE ===
$(cat "$sec_output")

"
    fi
    ;;
  security-scan)
    gather_prior "architect"
    sec_adr_dir="docs/ADRs"
    if [[ ! -d "$sec_adr_dir" ]]; then
      sec_adr_dir="$AUTOPILOT_DIR/stages/architect/ADRs"
    fi
    if [[ -d "$sec_adr_dir" ]]; then
      PRIOR_CONTEXT+="
=== ARCHITECTURE DECISION RECORDS ===
"
      for sec_adr in "$sec_adr_dir"/*.md; do
        [[ -f "$sec_adr" ]] || continue
        PRIOR_CONTEXT+="$(cat "$sec_adr")

"
      done
    fi
    ;;
  task-breakdown)
    gather_prior "context-ingestion"
    gather_prior "analyst"
    gather_prior "architect"
    ADR_DIR="docs/ADRs"
    if [[ ! -d "$ADR_DIR" ]]; then
      ADR_DIR="$AUTOPILOT_DIR/stages/architect/ADRs"
    fi
    if [[ -d "$ADR_DIR" ]]; then
      PRIOR_CONTEXT+="
=== ARCHITECTURE DECISION RECORDS ===
"
      for adr in "$ADR_DIR"/*.md; do
        [[ -f "$adr" ]] || continue
        PRIOR_CONTEXT+="$(cat "$adr")

"
      done
    fi
    mkdir -p "$AUTOPILOT_DIR/stages/task-breakdown/manifests"
    # Include Decision Engine ADRs when primary dir is docs/ADRs (DE writes to .autopilot)
    DE_ADR_DIR="$AUTOPILOT_DIR/stages/architect/ADRs"
    if [[ "$ADR_DIR" != "$DE_ADR_DIR" && -d "$DE_ADR_DIR" ]]; then
      for adr in "$DE_ADR_DIR"/*-decision-engine.md; do
        [[ -f "$adr" ]] || continue
        PRIOR_CONTEXT+="$(cat "$adr")

"
      done
    fi
    ;;
  developer)
    if [[ -n "$TICKET_ID" ]]; then
      MANIFEST_PATH="$AUTOPILOT_DIR/stages/task-breakdown/manifests/$TICKET_ID.json"
      if [[ -f "$MANIFEST_PATH" ]]; then
        PRIOR_CONTEXT=$(python3 "$SCRIPT_DIR/assemble_context.py" --manifest "$MANIFEST_PATH") || {
          echo "  [run_stage] ERROR: assemble_context.py failed for $TICKET_ID" >&2
          exit 1
        }
      else
        echo "  [run_stage] WARNING: Manifest not found: $MANIFEST_PATH — context will be empty" >&2
      fi
    fi
    ;;
  reviewer)
    gather_prior "analyst"
    gather_prior "architect"
    gather_prior "task-breakdown"
    # Include Decision Engine ADRs from architect stage
    DE_ADR_DIR="$AUTOPILOT_DIR/stages/architect/ADRs"
    if [[ -d "$DE_ADR_DIR" ]]; then
      for adr in "$DE_ADR_DIR"/*-decision-engine.md; do
        [[ -f "$adr" ]] || continue
        PRIOR_CONTEXT+="$(cat "$adr")

"
      done
    fi
    ;;
  integration-validator)
    # Script-driven stage; validate_interfaces.py reads manifests directly
    PRIOR_CONTEXT=""
    ;;
esac

# ─── Critiques from failed attempts ──────────────────────────────────────────

CRITIQUE_CONTEXT=""
for i in 1 2 3; do
  local_crit="$OUTPUT_DIR/critique_${i}.md"
  if [[ -f "$local_crit" ]]; then
    CRITIQUE_CONTEXT+="
=== CRITIQUE FROM ATTEMPT $i — YOU MUST ADDRESS THIS ===
$(cat "$local_crit")
"
  fi
done

# ─── Previous output for patch mode (retry only, not synthesis pass) ──────────

PREVIOUS_OUTPUT=""
if [[ -n "$CRITIQUE_CONTEXT" && "${SYNTHESIS_PASS:-}" != "1" && -f "$OUTPUT_DIR/output.md" ]]; then
  PREVIOUS_OUTPUT=$(cat "$OUTPUT_DIR/output.md")
  # Cap at 50 000 chars (~12 k tokens) to avoid context-window overflow on large docs
  if [[ ${#PREVIOUS_OUTPUT} -gt 50000 ]]; then
    PREVIOUS_OUTPUT="${PREVIOUS_OUTPUT:0:50000}
[TRUNCATED — document exceeds 50 000 chars. Only the first portion is shown. Apply critiqued patches based on the sections visible above; do not alter sections outside the critique.]"
  fi
fi

# ─── System prompt: skill-based or hardcoded fallback ────────────────────────

BMAD_OUTPUT_PATH=$(get_bmad_output_path "$STAGE")
mkdir -p "$(dirname "$BMAD_OUTPUT_PATH")" 2>/dev/null || true

SKILL_NAME=$(get_stage_skill "$STAGE")
SYSTEM_PROMPT=""

if [[ -n "$SKILL_NAME" ]]; then
  SKILL_DIR=$(resolve_bmad_skill "$SKILL_NAME" 2>/dev/null || true)
  if [[ -n "$SKILL_DIR" ]]; then
    echo "  [run_stage] Using BMAD-v6 skill: $SKILL_NAME (from $SKILL_DIR)" >&2
    SYSTEM_PROMPT=$(load_skill_content "$SKILL_DIR")
  else
    echo "  [run_stage] Skill '$SKILL_NAME' not found — falling back to hardcoded prompt" >&2
  fi
fi

# Hardcoded fallback prompts (used when skill not installed/found, or for reviewer)
if [[ -z "$SYSTEM_PROMPT" ]]; then
  case "$STAGE" in
    context-ingestion)
      SYSTEM_PROMPT=$(cat <<'CEOF'
You are a senior engineer doing a codebase audit before a sprint.
Your job is to produce CONTEXT.md: a complete picture of the existing system
so downstream stages extend rather than replace it.

Use bash tools to:
1. Map the codebase: find source files (exclude node_modules, .git, dist, build)
2. Read key files from the brief (entry points, base classes, main patterns)
3. Read existing architecture docs if paths are provided
4. Pull sprint data from the board URL in the brief if present

Rules:
- Do NOT suggest changes — document only what exists
- Quote actual code snippets when documenting patterns (developers will copy these exactly)
- Sprint status must clearly mark: DONE (skip), IN-PROGRESS (do not conflict),
  THIS-RUN (build these), BLOCKED (do not touch)
- If sprint board is inaccessible, use the brief sprint context section and note this
- Output ONLY the CONTEXT.md in markdown. No preamble.
CEOF
)
      ;;
    context-validator)
      SYSTEM_PROMPT=$(cat <<'EOF'
You are a context validator running in fully automated mode.
You will receive CONTEXT.md from context-ingestion and PROJECT_BRIEF.md.

Your job: detect conflicts between the sprint scope and the existing codebase before any planning begins.

Perform three checks:

1. DO-NOT-TOUCH ZONE CONFLICTS
   - Extract the do-not-touch zones from PROJECT_BRIEF.md
   - Extract the files each in-scope sprint ticket touches (from CONTEXT.md sprint status and file tree)
   - If any in-scope ticket touches a file inside a do-not-touch zone → CONFLICT entry

2. ADR CONTRADICTIONS
   - Extract existing ADRs from CONTEXT.md (architecture summary and ADR list sections)
   - For each ADR that mandates a specific technology or approach:
     check whether any in-scope sprint ticket implies a contradictory technology or approach
   - Each contradiction → CONFLICT entry

3. DONE TICKET VERIFICATION
   - For each sprint ticket marked DONE in CONTEXT.md sprint status:
     check whether the files expected for that ticket appear in CONTEXT.md's codebase file tree
   - Files absent → WARN entry (non-blocking)

Rules:
- CONFLICT items are blocking. Any CONFLICT item in the output → the gate will FAIL.
- WARN items are non-blocking. Gate records them as suggestions, pipeline continues.
- If no conflicts or warnings exist, output empty Conflicts and Warnings sections and a Verified section confirming DONE tickets.
- If no DONE tickets exist in the sprint board, output the Verified section with a single entry: "- ✓ No DONE tickets to verify."
- Output ONLY the CONTEXT_CONFLICTS.md content in markdown. No preamble.
EOF
)
      ;;
    analyst)
      SYSTEM_PROMPT=$(cat <<'EOF'
You are a senior product analyst running in fully automated mode.
Your job is to produce a complete PRD from the provided PROJECT_BRIEF.md.

## AC format — non-negotiable

"Given [precondition], When [user action], Then [observable outcome]" is the ONLY
acceptable format for acceptance criteria. Declarative statements ("AC1: System shows X",
"The user can Y") are not ACs. They will fail the quality gate every time.

Every functional requirement must have at minimum:
1. Happy-path AC — normal preconditions, normal action, expected result
2. Error/failure AC — what happens when the operation fails (network error, invalid input,
   server error, permission denied)
3. Empty/first-use AC — what the user sees when there is no data yet (first launch,
   no entries, empty list)

If the feature has boundary inputs (min/max values, zero, negative), add a fourth AC
for the boundary case. If the feature has multiple distinct user-visible states, each
state needs its own AC.

## Decision rules

Any value, behavior, or convention the brief does not explicitly state — YOU decide it.
Apply it consistently across the entire document. Document every decision in
"## Decisions Made" as:
  D-NNN: [topic] — [decision] — [rationale: one sentence]

This includes without exception:
- Sign conventions for all numeric fields (positive = gain, negative = loss, etc.)
- Exact formula constants and arithmetic (spell out the full formula, not a description)
- Timezone policy (stored as UTC, displayed in device local, etc.)
- Default values for every user-configurable field before the user changes it
- State machine transitions (which event moves from state A to state B?)
- Navigation entry point for every screen (user taps X in bottom nav → reaches Y)
- Sort order for every list (most recent first, alphabetical, etc.)
- Truncation and display formatting for every value shown in the UI
- Error message convention (inline, toast, modal, banner)
- What "current" means for fields that can be inferred multiple ways

## Open Questions

The "Open Questions" section must be EMPTY. If you have a question, answer it using
the most conservative/minimal reasonable interpretation, move it to Decisions Made, and
continue. An open question in the output is a gate blocker with no exceptions.

## Pre-output checklist — complete this before finalizing

Work through each check in order before you write "## Decisions Made":

1. AC format audit: re-read every AC. Count any that are declarative (not Given/When/Then).
   Rewrite every one of them before continuing.

2. AC coverage audit: for each FR, verify you have a happy-path AC, an error-state AC,
   and an empty/first-use AC. Add any that are missing.

3. Value decision audit: for each AC, identify every concrete value it references
   (numbers, enum names, format strings, color codes, time values). For each: is it
   explicitly stated in the brief? If not, add a D-NNN entry to Decisions Made.

4. Navigation audit: for each feature that renders a screen or view, confirm that at
   least one AC states how the user reaches it from the home screen.

5. Consistency pass: read every formula, every threshold, every sign reference across
   the entire document. Verify all use the same D-NNN convention you declared. If any
   uses a different constant or different convention: fix it before outputting.

6. Placeholder scan: search the document for "TBD", "TODO", "to be decided", "TBD",
   "open question". If found: replace each with a concrete decision.

## Output

Output ONLY the PRD in markdown. No preamble, no explanation.
EOF
)
      ;;
    architect)
      SYSTEM_PROMPT=$(cat <<'EOF'
You are a senior software architect running in fully automated mode.
You will receive a PROJECT_BRIEF and a PRD. Produce a complete architecture document
and one ADR per significant technology or design decision.

Rules:
- Every technology choice not specified in the brief requires an ADR
- The file/folder structure must be specific enough to create with mkdir -p commands
- API contracts must include types (TypeScript types, OpenAPI, or equivalent)
- If the brief specifies a tech, use it — do not substitute
- No "we could also..." — make decisions and document them in ADRs
- Separate ADRs with "--- ADR ---" delimiters so the script can split them
- Output ONLY the architecture markdown followed by the ADRs. No preamble.
EOF
)
      ;;
    task-breakdown)
      SYSTEM_PROMPT=$(cat <<'EOF'
You are a senior engineering lead running in fully automated mode.
You will receive a PRD and architecture document. Break the work into
implementable tickets ordered by dependency.

Rules:
- Each ticket must be implementable by a single focused claude -p call
  (estimate: a ticket that would take a human dev 30min to 2hrs)
- Tickets must be ordered so no ticket depends on an unbuilt ticket above it
- Mark tickets as "parallelizable: yes" only if they truly share no state
- Every ticket must reference specific files from the architecture's file/folder
  structure
- Setup tickets (project init, package.json, tsconfig) come first
- Test tickets come after the implementation tickets they test
- For every ticket, write a context manifest JSON file to
  .autopilot/stages/task-breakdown/manifests/TASK-NNN.json using
  your file-write capability (you have dangerously-skip-permissions)
- Verify that every path in requires.existing_files exists before listing it
- Verify that every ADR in requires.adrs exists before listing it
- Ensure provides.exports declares every symbol that downstream tickets'
  downstream_contracts will reference — verify cross-ticket consistency
- No circular manifest dependencies: if TASK-A requires TASK-B's output files,
  TASK-B must not also require TASK-A's output files
- Output ONLY the TASKS.md to .autopilot/stages/task-breakdown/output.md.
  Manifests are written as separate JSON files (not embedded in TASKS.md).
EOF
)
      ;;
    reviewer)
      SYSTEM_PROMPT=$(cat <<'EOF'
You are a senior QA engineer running in fully automated mode.
Your job:
1. Run all tests and lint (use bash commands)
2. Start the application if applicable (from the definition of done in the brief)
3. Execute the acceptance criteria from PROJECT_BRIEF's definition of done
4. Write a review report: what passed, what failed, what needs fixing

Output format:
- First line: "PIPELINE_COMPLETE" if everything passes, or "PIPELINE_INCOMPLETE" if anything fails
- Then: the review report in markdown
EOF
)
      ;;
    security-scan)
      SYSTEM_PROMPT=$(cat <<'EOF'
You are a security architect performing an automated threat analysis.
You will receive a system architecture document, its ADRs, and the project brief.

Your job: identify security vulnerabilities in the design before implementation begins.

Review against:
- OWASP Top 10 (relevant items for this application type)
- Authentication and authorization model completeness
- Input validation coverage (are all entry points validated?)
- Secrets management (are credentials/keys handled correctly in the design?)
- Data exposure risk (is sensitive data minimized, encrypted at rest/transit where needed?)
- Dependency risk (are third-party libraries pinned? are there known-vulnerable choices?)

Severity classification:
- CRITICAL: can lead to authentication bypass, data breach, or RCE
- HIGH: significant security gap, exploitable with moderate effort
- MEDIUM: improvement recommended but not blocking

Output ONLY the security review markdown. No preamble.
EOF
)
      ;;
    integration-validator)
      python3 "$SCRIPT_DIR/validate_interfaces.py" \
        --manifests-dir "$AUTOPILOT_DIR/stages/task-breakdown/manifests" \
        --source-root "$(pwd)" \
        > "$AUTOPILOT_OUTPUT" || true
      exit 0
      ;;
    *)
      echo "Unknown stage: $STAGE" >&2
      exit 1
      ;;
  esac
fi

# ─── Prepend persona to system prompt ────────────────────────────────────────

PERSONA_SKILL=$(get_stage_persona_skill "$STAGE")
if [[ -n "$PERSONA_SKILL" && -n "$SYSTEM_PROMPT" ]]; then
  PERSONA_DIR=$(resolve_bmad_skill "$PERSONA_SKILL" 2>/dev/null || true)
  if [[ -n "$PERSONA_DIR" ]]; then
    PERSONA_OVERVIEW=$(load_persona_overview "$PERSONA_DIR")
    if [[ -n "$PERSONA_OVERVIEW" ]]; then
      echo "  [run_stage] Prepending persona: $PERSONA_SKILL" >&2
      SYSTEM_PROMPT="$PERSONA_OVERVIEW

---

$SYSTEM_PROMPT"
    fi
  fi
fi

# ─── Construct full prompt ────────────────────────────────────────────────────

FULL_PROMPT=""

# Autonomous mode header
FULL_PROMPT+="[PIPELINE_MODE: autonomous]
[OUTPUT_PATH: $BMAD_OUTPUT_PATH]
"

# Synthesis pass: injected when auto_resolve() is triggered after max_retries failures
if [[ "${SYNTHESIS_PASS:-}" == "1" ]]; then
  FULL_PROMPT+="[SYNTHESIS_PASS: FINAL AUTONOMOUS ATTEMPT]
All prior retries failed the quality gate. This is the last attempt before escalating to the user.
You MUST make an explicit documented decision on EVERY ambiguous, missing, or unclear point.
Rules:
- No open questions. No TBDs. No placeholders. No deferral.
- For every decision you make, document it inline as: AUTONOMOUS DECISION: <what and why>
- All prior critiques are included below — address EVERY single item, one by one
- Treat conflicts in the brief as you would as a senior engineer: pick the most reasonable interpretation and state it
Proceed autonomously.
"
fi

# Stage-specific routing hints for the skill
case "$STAGE" in
  task-breakdown)
    FULL_PROMPT+="[TASK: Produce the TASKS.md ticket breakdown and emit one TASK-NNN.json context manifest per ticket to .autopilot/stages/task-breakdown/manifests/]
"
    ;;
  analyst)
    FULL_PROMPT+="[TASK: Produce the complete PRD]
[DECISION_RULE: Any value the brief does not explicitly specify is your decision. Before outputting: re-read every acceptance criterion and identify every concrete value, threshold, sign convention, state, format, or behavior it references. For each: is it in the brief? If not, decide it and add to Decisions Made. Open Questions section must be empty. Every decided value must be consistent throughout the entire document. The gate WILL FAIL if any AC references an undocumented implicit decision.]
"
    ;;
  architect)
    FULL_PROMPT+="[TASK: Produce the architecture document and ADRs]
"
    ;;
  context-ingestion)
    FULL_PROMPT+="[TASK: Produce the project context document]
"
    ;;
  context-validator)
    FULL_PROMPT+="[TASK: Detect do-not-touch zone violations, ADR contradictions, and done-ticket verification failures, and produce the conflict report]
"
    ;;
  developer)
    if [[ -n "$TICKET_ID" ]]; then
      FULL_PROMPT+="[TASK: Implement ticket $TICKET_ID using the manifest-assembled context provided]
"
    else
      FULL_PROMPT+="[TASK: Execute the developer stage]
"
    fi
    ;;
  security-scan)
    FULL_PROMPT+="[TASK: Perform security review of the architecture against OWASP Top 10 and produce findings report]
"
    ;;
esac

FULL_PROMPT+="
"

if [[ -n "$DESIGN_CONTEXT" ]]; then
  FULL_PROMPT+="$DESIGN_CONTEXT

"
fi

if [[ -n "$CRITIQUE_CONTEXT" && "${SYNTHESIS_PASS:-}" != "1" ]]; then
  FULL_PROMPT+="PATCH MODE RETRY: Your previous attempt failed the quality gate. Patch the previous output.
Fix ONLY the sections identified in the critique below. Do not change any other section.
Return the COMPLETE document with patches applied — not just the changed sections.
$CRITIQUE_CONTEXT
"
  if [[ -n "$PREVIOUS_OUTPUT" ]]; then
    FULL_PROMPT+="
PREVIOUS OUTPUT — patch this document, return the full document with only the critiqued sections changed:
$PREVIOUS_OUTPUT

---
"
  fi
elif [[ -n "$CRITIQUE_CONTEXT" ]]; then
  FULL_PROMPT+="PREVIOUS ATTEMPT(S) FAILED. YOU MUST ADDRESS ALL CRITIQUES BELOW BEFORE OUTPUTTING:
$CRITIQUE_CONTEXT

---
"
fi

FULL_PROMPT+="PROJECT_BRIEF:
$BRIEF
"

if [[ -n "$PRIOR_CONTEXT" ]]; then
  FULL_PROMPT+="
$PRIOR_CONTEXT
"
fi

FULL_PROMPT+="
CURRENT PIPELINE STATE (for context only):
$STATE

---
Your task: Execute the $STAGE stage. Write the output artifact to $BMAD_OUTPUT_PATH.
"

# ─── Invoke claude -p ─────────────────────────────────────────────────────────

TMP_SP=$(mktemp)
trap 'rm -f "$TMP_SP"; kill "${_heartbeat_pid:-}" 2>/dev/null || true' EXIT
printf '%s' "$SYSTEM_PROMPT" > "$TMP_SP"

_log_append_stage() {
  local type="${1}" msg="${2:-}" extra="${3:-}"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  msg="${msg//\"/\\\"}"
  if [[ -n "$extra" ]]; then
    printf '{"ts":"%s","type":"%s","stage":"%s","msg":"%s",%s}\n' \
      "$ts" "$type" "$STAGE" "$msg" "$extra" >> ".autopilot/pipeline.log" 2>/dev/null || true
  else
    printf '{"ts":"%s","type":"%s","stage":"%s","msg":"%s"}\n' \
      "$ts" "$type" "$STAGE" "$msg" >> ".autopilot/pipeline.log" 2>/dev/null || true
  fi
}

_stage_start=$(date +%s)
_tokens_in=$(( ${#FULL_PROMPT} / 4 ))
printf "  [run_stage] %s  LLM call started at %s (~%d tokens in)\n" "$STAGE" "$(date '+%H:%M:%S')" "$_tokens_in" >&2
_log_append_stage "llm_start" "~${_tokens_in} tokens in" "\"tokens_in_est\":${_tokens_in}"

# Heartbeat: print elapsed time every 20s while the LLM call is in flight
(
  while true; do
    sleep 20
    _elapsed=$(( $(date +%s) - _stage_start ))
    printf "  [run_stage] %s  ... still running (%ds)\n" "$STAGE" "$_elapsed" >&2
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '{"ts":"%s","type":"llm_heartbeat","stage":"%s","msg":"still running %ds","elapsed_s":%d}\n' \
      "$ts" "$STAGE" "$_elapsed" "$_elapsed" >> ".autopilot/pipeline.log" 2>/dev/null || true
  done
) &
_heartbeat_pid=$!

echo "$FULL_PROMPT" | claude -p \
  --system-prompt-file "$TMP_SP" \
  --dangerously-skip-permissions \
  "${IMAGE_FLAGS[@]+"${IMAGE_FLAGS[@]}"}" \
  > "$AUTOPILOT_OUTPUT"

kill "$_heartbeat_pid" 2>/dev/null || true
wait "$_heartbeat_pid" 2>/dev/null || true

_elapsed=$(( $(date +%s) - _stage_start ))
_tokens_out=$(( $(wc -c < "$AUTOPILOT_OUTPUT" 2>/dev/null || echo 0) / 4 ))
printf "  [run_stage] %s  LLM call complete (%ds, ~%d tokens out)\n" "$STAGE" "$_elapsed" "$_tokens_out" >&2
_log_append_stage "llm_end" "${_elapsed}s ~${_tokens_out} tokens out" "\"elapsed_s\":${_elapsed},\"tokens_out_est\":${_tokens_out}"

# ─── Post-processing ──────────────────────────────────────────────────────────

# If claude wrote the artifact via tools to $BMAD_OUTPUT_PATH, copy it to
# the autopilot stage output so the gate can read it.
if [[ -f "$BMAD_OUTPUT_PATH" && "$BMAD_OUTPUT_PATH" != "$AUTOPILOT_OUTPUT" ]]; then
  cp "$BMAD_OUTPUT_PATH" "$AUTOPILOT_OUTPUT"
fi

# For architect: split ADRs out of the output
if [[ "$STAGE" == "architect" ]]; then
  ADR_DIR="docs/ADRs"
  mkdir -p "$ADR_DIR"
  python3 "$SCRIPT_DIR/split_adrs.py" "$AUTOPILOT_OUTPUT" "$ADR_DIR"
  # Also keep a copy in the legacy location for backwards compatibility
  mkdir -p "$AUTOPILOT_DIR/stages/architect/ADRs"
  for adr in "$ADR_DIR"/*.md; do
    [[ -f "$adr" ]] && cp "$adr" "$AUTOPILOT_DIR/stages/architect/ADRs/" 2>/dev/null || true
  done
fi

echo "Stage $STAGE complete → $AUTOPILOT_OUTPUT (artifact: $BMAD_OUTPUT_PATH)"
