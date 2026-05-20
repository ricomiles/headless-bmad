#!/usr/bin/env bash
# run_dev_story.sh — Implement a single story non-interactively using bmad-dev-story
# Usage: bash scripts/run_dev_story.sh <story-key>
#   e.g.: bash scripts/run_dev_story.sh 1-2-user-authentication
#
# Resolves the bmad-dev-story skill, loads its full content, and invokes it
# via claude -p with [PIPELINE_MODE: autonomous] + [STORY_PATH: stories/<key>.md].

set -euo pipefail

STORY_KEY="${1:?Usage: run_dev_story.sh <story-key>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORY_FILE="stories/${STORY_KEY}.md"
AUTOPILOT_DIR=".autopilot"
OUTPUT_DIR="$AUTOPILOT_DIR/stages/developer/$STORY_KEY"

mkdir -p "$OUTPUT_DIR"

if [[ ! -f "$STORY_FILE" ]]; then
  echo "ERROR: Story file not found: $STORY_FILE" >&2
  exit 1
fi

# ─── Resolve bmad-dev-story skill ────────────────────────────────────────────

resolve_bmad_skill() {
  local skill_name="$1"
  # Prefer repo-local skills (src/bmm-skills/) over global install
  local bmad_src
  bmad_src="$(cd "$SCRIPT_DIR/../../bmm-skills" && pwd 2>/dev/null)" || true
  if [[ -n "$bmad_src" && -d "$bmad_src" ]]; then
    for phase in "4-implementation" "3-solutioning" "2-plan-workflows" "1-analysis"; do
      [[ -d "$bmad_src/$phase/$skill_name" ]] && \
        echo "$bmad_src/$phase/$skill_name" && return 0
    done
  fi
  # Project-local install (.claude/skills/ sibling — bmad project install)
  local project_skills
  project_skills="$(cd "$SCRIPT_DIR/../.." && pwd 2>/dev/null)" || true
  [[ -n "$project_skills" && -d "$project_skills/$skill_name" ]] && \
    echo "$project_skills/$skill_name" && return 0

  # Fallback: global install
  [[ -d "$HOME/.claude/skills/$skill_name" ]] && \
    echo "$HOME/.claude/skills/$skill_name" && return 0
  return 1
}

load_skill_content() {
  local skill_dir="$1"
  local content=""
  [[ -f "$skill_dir/SKILL.md" ]] && content+="$(cat "$skill_dir/SKILL.md")"$'\n\n'
  for steps_dir in "$skill_dir/steps" "$skill_dir/steps-c"; do
    if [[ -d "$steps_dir" ]]; then
      while IFS= read -r -d '' sf; do
        content+="--- Step: $(basename "$sf") ---"$'\n'"$(cat "$sf")"$'\n\n'
      done < <(find "$steps_dir" -maxdepth 1 -name "*.md" -print0 | sort -z)
      break
    fi
  done
  echo "$content"
}

SKILL_DIR=$(resolve_bmad_skill "bmad-dev-story" 2>/dev/null || true)

if [[ -n "$SKILL_DIR" ]]; then
  echo "  [run_dev_story] Using bmad-dev-story skill from $SKILL_DIR" >&2
  SYSTEM_PROMPT=$(load_skill_content "$SKILL_DIR")
else
  echo "  [run_dev_story] bmad-dev-story not found — using fallback prompt" >&2
  SYSTEM_PROMPT=$(cat <<'EOF'
You are a senior developer implementing a story in fully automated mode.
You have a story file with tasks/subtasks to complete.

Rules:
- Read the complete story file before implementing
- Implement ALL tasks/subtasks in exact order
- Follow red-green-refactor: write failing tests first, then make them pass, then refactor
- Write complete, working code — no placeholders, no TODOs, no stubs
- Follow the architecture and ADRs exactly — do not deviate from decided patterns
- After implementing, update the story file:
  - Check all completed tasks [x]
  - Add implementation notes to Dev Agent Record → Completion Notes
  - Update File List with all created/modified files (relative paths)
  - Set Status to: review
EOF
)
fi

# ─── Gather context ───────────────────────────────────────────────────────────

STORY_CONTENT=$(cat "$STORY_FILE")
ARCH_CONTENT=""
[[ -f "docs/architecture.md" ]] && ARCH_CONTENT=$(cat "docs/architecture.md")

ADR_CONTENT=""
for adr_dir in "docs/ADRs" "$AUTOPILOT_DIR/stages/architect/ADRs"; do
  if [[ -d "$adr_dir" ]]; then
    for adr in "$adr_dir"/*.md; do
      [[ -f "$adr" ]] && ADR_CONTENT+="$(cat "$adr")"$'\n\n'
    done
    break
  fi
done

PROJECT_CONTEXT=""
[[ -f "docs/project-context.md" ]] && PROJECT_CONTEXT=$(cat "docs/project-context.md")

# Gather critiques from previous failed attempts at this story
CRITIQUE_CONTEXT=""
for i in 1 2 3; do
  crit="$OUTPUT_DIR/critique_${i}.md"
  if [[ -f "$crit" ]]; then
    CRITIQUE_CONTEXT+="
=== CRITIQUE FROM ATTEMPT $i — ADDRESS THIS ===
$(cat "$crit")
"
  fi
done

# ─── Build prompt ─────────────────────────────────────────────────────────────

FULL_PROMPT="[PIPELINE_MODE: autonomous]
[STORY_PATH: $STORY_FILE]
[STORY_KEY: $STORY_KEY]

"

if [[ -n "$CRITIQUE_CONTEXT" ]]; then
  FULL_PROMPT+="PREVIOUS ATTEMPT(S) FAILED. YOU MUST ADDRESS ALL CRITIQUES:
$CRITIQUE_CONTEXT

---
"
fi

# Design injection for developer stage
DESIGN_CONTEXT=$(python3 "$SCRIPT_DIR/inject_designs.py" "developer" 2>/dev/null || true)
if [[ -n "$DESIGN_CONTEXT" ]]; then
  FULL_PROMPT+="$DESIGN_CONTEXT

[DESIGN_RULE: The design above covers a SUBSET of the UI. Components explicitly shown in the design are FROZEN — implement them exactly as shown; do NOT remove, rename, or substitute any element. Screens or components NOT in the design are at your discretion — follow the design's visual language and patterns. At the end of your output you MUST include a ## Design Compliance Checklist covering only the frozen (designed) components: list each by name, the file implementing it, and mark ✅ implemented or ❌ missing/deviated (with justification). Missing this section is a gate BLOCKER.]

"
fi

FULL_PROMPT+="STORY FILE (stories/$STORY_KEY.md):
$STORY_CONTENT
"

if [[ -n "$ARCH_CONTENT" ]]; then
  FULL_PROMPT+="
ARCHITECTURE (docs/architecture.md):
$ARCH_CONTENT
"
fi

if [[ -n "$ADR_CONTENT" ]]; then
  FULL_PROMPT+="
ARCHITECTURE DECISION RECORDS:
$ADR_CONTENT
"
fi

if [[ -n "$PROJECT_CONTEXT" ]]; then
  FULL_PROMPT+="
PROJECT CONTEXT (docs/project-context.md):
$PROJECT_CONTEXT
"
fi

FULL_PROMPT+="
---
Your task: Implement the story. Write all code, update the story file to mark tasks complete and set Status to 'review'.
"

# ─── Invoke ───────────────────────────────────────────────────────────────────

echo "$FULL_PROMPT" | claude -p "$SYSTEM_PROMPT" \
  --dangerously-skip-permissions \
  > "$OUTPUT_DIR/output.md"

echo "Story $STORY_KEY implementation complete → $OUTPUT_DIR/output.md"
