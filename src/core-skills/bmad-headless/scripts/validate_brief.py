#!/usr/bin/env python3
"""
validate_brief.py — Validate PROJECT_BRIEF.md before pipeline start
Usage: python3 scripts/validate_brief.py <brief_path>
Exit 0: brief is valid, pipeline can start
Exit 1: brief has blocking issues, fix before running
"""

import sys
import re

def _has_outcome_language(bullet_text):
    """Detect if a feature bullet describes an outcome vs. just naming a feature."""
    text = re.sub(r'^[-*•\d.]+\s*', '', bullet_text).strip()
    words = text.split()
    if len(words) <= 3:
        return False
    outcome_signals = re.compile(
        r'\b(user[s]?\s+(can|will|may|should)|allow\w*|enable\w*|support(?:s|ed|ing)?\b|'
        r'provide\w*|let\s+user|so\s+that|in\s+order\s+to)\b',
        re.IGNORECASE
    )
    if outcome_signals.search(text):
        return True
    return len(words) >= 6

def validate(path):
    try:
        with open(path) as f:
            content = f.read()
    except FileNotFoundError:
        print(f"ERROR: File not found: {path}")
        sys.exit(1)

    errors = []    # Blocking — pipeline will not start
    warnings = []  # Non-blocking — pipeline will start but may hit gate failures

    text = content.lower()
    word_count = len(content.split())

    # ─── BLOCKING checks ─────────────────────────────────────────────────────

    # Project overview
    overview_section = extract_section(content, ["overview", "about", "what"])
    if not overview_section or len(overview_section.split()) < 30:
        errors.append("Project overview is missing or too short (< 30 words). "
                      "Add a section explaining what is being built, for whom, and why.")

    # Core features
    features_section = extract_section(content, ["feature", "scope", "functionality", "what it does"])
    if not features_section:
        errors.append("No core features / scope section found. "
                      "Add a section listing what the project must do.")
    else:
        bullets = re.findall(r'^[-*•]\s+.+', features_section, re.MULTILINE)
        numbered = re.findall(r'^\d+\.\s+.+', features_section, re.MULTILINE)
        all_items = bullets + numbered
        if len(all_items) < 2:
            errors.append("Core features section has fewer than 2 listed items. "
                          "Use a bullet list to enumerate features explicitly.")
        else:
            outcome_items = [b for b in all_items if _has_outcome_language(b)]
            label_only_items = [b for b in all_items if not _has_outcome_language(b)]
            if label_only_items:
                errors.append(
                    f"Feature descriptions must state user outcomes ('user can X'), not just feature labels. "
                    f"Found {len(label_only_items)} label-only bullets."
                )
            if len(outcome_items) < 3:
                errors.append(
                    f"Fewer than 3 features with outcome language (found {len(outcome_items)}). "
                    "Describe at minimum 3 features with what users can accomplish, "
                    "e.g. 'Users can generate invoices from YAML config'."
                )

    # Tech stack
    tech_section = extract_section(content, ["tech", "stack", "technology", "languages", "framework"])
    if not tech_section:
        errors.append("No tech stack section found. "
                      "Specify at minimum: language, framework, and database (or 'no database').")
    else:
        has_lang = any(lang in tech_section.lower() for lang in [
            "python", "javascript", "typescript", "ruby", "go", "rust",
            "java", "kotlin", "swift", "c#", "php", "elixir"
        ])
        if not has_lang:
            errors.append("Tech stack section doesn't mention a programming language. "
                          "Add the language explicitly.")

    # Definition of done
    done_section = extract_section(content, ["done", "complete", "complete when", "definition", "acceptance"])
    if not done_section or len(done_section.split()) < 10:
        errors.append("Definition of done is missing or too vague. "
                      "Add a section describing concretely how to verify the project is complete.")

    # Placeholder text — only flag action-item uses, not descriptive prose
    # TBD/FIXME/xxx are almost never used descriptively
    _hard = re.findall(r'\b(TBD|to be determined|to be decided|FIXME|xxx)\b',
                       content, re.IGNORECASE)
    # TODO only as an action item: "TODO:", "[TODO]", "TODO -", or at line start
    _todo = re.search(r'(?:^|[\[\s])TODO\s*(?:\]|:|\s*[-–])',
                      content, re.IGNORECASE | re.MULTILINE)
    # placeholder only as bracketed filler: [placeholder] or {placeholder}
    _ph = re.search(r'[\[{]placeholder[\]}]', content, re.IGNORECASE)
    placeholders = _hard + (["TODO"] if _todo else []) + (["placeholder"] if _ph else [])
    if placeholders:
        errors.append(f"Brief contains placeholder text: {set(placeholders)}. "
                      "Replace all placeholders with real decisions before running.")

    # Word count (blocking — brief under 150 words is too sparse to drive the pipeline)
    if word_count < 150:
        errors.append(f"Brief word count ({word_count}) is below 150 words. "
                      "A brief this short will cause quality gate failures. "
                      "Aim for at least 150-300 words for a small project.")

    # Open questions (any unresolved item blocks the pipeline)
    open_q_section = extract_section(content, ["open question", "open questions", "unknowns", "unresolved"])
    if open_q_section:
        non_empty = [l for l in open_q_section.strip().splitlines() if l.strip() and not l.strip().startswith('#')]
        if non_empty:
            errors.append("Open questions section found with unresolved items. "
                          "Resolve all questions before running the pipeline. "
                          "If all questions are resolved, remove the section entirely.")

    # ─── WARNING checks ───────────────────────────────────────────────────────

    # Out of scope
    if "out of scope" not in text and "not in scope" not in text and "won't" not in text:
        warnings.append("No 'out of scope' section found. "
                        "Without it, the architect may gold-plate with features you don't want.")

    # Quality bar
    if not extract_section(content, ["quality", "testing", "test", "lint", "coverage"]):
        warnings.append("No quality bar / testing section found. "
                        "The pipeline will use conservative defaults.")

    # Constraints
    if not extract_section(content, ["constraint", "non-negotiable", "must not", "requirement"]):
        warnings.append("No constraints section found. "
                        "The pipeline will make all discretionary decisions on its own.")

    # ─── Report ───────────────────────────────────────────────────────────────

    print(f"\nBrief validation: {path}")
    print(f"Length: {word_count} words, {len(content.splitlines())} lines\n")

    if errors:
        print(f"BLOCKING ISSUES ({len(errors)}) — pipeline cannot start:")
        for i, err in enumerate(errors, 1):
            print(f"  {i}. {err}")
        print()

    if warnings:
        print(f"WARNINGS ({len(warnings)}) — pipeline will start but expect gate failures:")
        for i, warn in enumerate(warnings, 1):
            print(f"  {i}. {warn}")
        print()

    if not errors and not warnings:
        print("Brief richness: HIGH — analyst is likely to pass on attempt 1")
        print("✓ Brief looks good. Pipeline can start.\n")
    elif not errors:
        print("✓ No blocking issues. Warnings above are advisory.\n")
    else:
        print("✗ Fix blocking issues before running the pipeline.\n")
        sys.exit(1)


def extract_section(content, keywords):
    """
    Extract content from a markdown section whose heading contains any of the keywords.
    Returns the section body (up to the next heading), or None if not found.
    """
    lines = content.splitlines()
    in_section = False
    section_lines = []

    for line in lines:
        # Check if this is a heading line
        if re.match(r'^#{1,3}\s+', line):
            heading_text = re.sub(r'^#+\s+', '', line).lower()
            if any(kw in heading_text for kw in keywords):
                if not in_section:
                    in_section = True
                    section_lines = []
                else:
                    # Second matching heading (e.g. "Out of Scope" after "In Scope")
                    # ends the first section rather than restarting it
                    break
                continue
            elif in_section:
                # Reached a new heading — section is over
                break
        elif in_section:
            section_lines.append(line)

    if section_lines:
        return "\n".join(section_lines).strip()

    # Fallback: search for keyword anywhere with some context
    for kw in keywords:
        if kw in content.lower():
            idx = content.lower().index(kw)
            return content[idx:idx+500]

    return None

def is_brownfield(path):
    """Detect brownfield mode from brief content."""
    try:
        with open(path) as f:
            content = f.read().lower()
        # Handle "mode: brownfield" inline or "## Mode\nbrownfield" section format
        return "brownfield" in content
    except FileNotFoundError:
        return False


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 validate_brief.py <brief_path>")
        sys.exit(1)

    brief_path = sys.argv[1]

    if is_brownfield(brief_path):
        print("[brownfield mode detected]")

        try:
            with open(brief_path) as f:
                content = f.read()
        except FileNotFoundError:
            print(f"ERROR: File not found: {brief_path}")
            sys.exit(1)

        errors = []
        warnings = []
        word_count = len(content.split())

        # Placeholder text (always blocking) — same tighter matching as greenfield
        _hard = re.findall(r'\b(TBD|to be determined|to be decided|FIXME)\b',
                           content, re.IGNORECASE)
        _todo = re.search(r'(?:^|[\[\s])TODO\s*(?:\]|:|\s*[-–])',
                          content, re.IGNORECASE | re.MULTILINE)
        placeholders = _hard + (["TODO"] if _todo else [])
        if placeholders:
            errors.append(f"Brief contains placeholder text: {set(placeholders)}.")

        # Tech stack still required
        has_lang = any(lang in content.lower() for lang in [
            "python", "javascript", "typescript", "ruby", "go", "rust",
            "java", "kotlin", "swift", "c#", "php", "elixir"
        ])
        if not has_lang:
            errors.append("Tech stack: no programming language found.")

        # Sprint context
        if not extract_section(content, ["sprint context", "sprint status", "sprint board", "sprint goal"]):
            errors.append("[brownfield] No sprint context section. "
                          "Add sprint status: done, in-progress, this-run scope, blocked.")

        # This run scope
        scope = extract_section(content, ["this sprint", "this run", "scope", "in scope"])
        if not scope or len(scope.split()) < 8:
            errors.append("[brownfield] Sprint scope not defined. "
                          "List ticket IDs autopilot should build this run.")

        # Feature depth: scope items must describe what each ticket accomplishes
        if scope and len(scope.split()) >= 8:
            scope_bullets = re.findall(r'^[-*•]\s+.+', scope, re.MULTILINE)
            scope_numbered = re.findall(r'^\d+\.\s+.+', scope, re.MULTILINE)
            scope_items = scope_bullets + scope_numbered
            if scope_items:
                outcome_items = [b for b in scope_items if _has_outcome_language(b)]
                label_only_items = [b for b in scope_items if not _has_outcome_language(b)]
                if label_only_items:
                    errors.append(
                        f"[brownfield] Scope descriptions must state what each item accomplishes, not just labels. "
                        f"Found {len(label_only_items)} label-only item(s)."
                    )
                if len(outcome_items) < 3:
                    errors.append(
                        f"[brownfield] Fewer than 3 scope items with outcome language (found {len(outcome_items)}). "
                        "Describe what each scoped ticket accomplishes."
                    )

        # Do-not-touch
        dnt = content.lower()
        if "do not touch" not in dnt and "don't touch" not in dnt and "do-not-touch" not in dnt:
            errors.append("[brownfield] No 'do not touch' section. Required even if empty — write 'none'.")

        # Definition of done
        done_section = extract_section(content, ["done", "complete", "definition", "acceptance"])
        if not done_section or len(done_section.split()) < 8:
            errors.append("Definition of done missing or too vague.")

        # Open questions
        open_q_section = extract_section(content, ["open question", "open questions", "unknowns", "unresolved"])
        if open_q_section:
            non_empty = [l for l in open_q_section.strip().splitlines() if l.strip() and not l.strip().startswith('#')]
            if non_empty:
                errors.append("Open questions section found with unresolved items. "
                              "Resolve all questions before running the pipeline. "
                              "If all questions are resolved, remove the section entirely.")

        # Warnings
        if word_count < 80:
            errors.append(f"Brief word count ({word_count}) is below 80 words. "
                          "Add more context — brownfield briefs must describe what's changing and why.")

        board_signals = ["http", "jira", "linear", "notion", "github", "asana"]
        if not any(s in content.lower() for s in board_signals):
            warnings.append("[brownfield] No sprint board URL found — will use manual sprint context only.")

        if "architecture" not in content.lower() and "docs/" not in content.lower():
            warnings.append("[brownfield] No existing architecture doc path — will infer from codebase.")

        print(f"\nBrief validation: {brief_path}")
        print(f"Length: {word_count} words\n")

        if errors:
            print(f"BLOCKING ISSUES ({len(errors)}) — pipeline cannot start:")
            for i, err in enumerate(errors, 1):
                print(f"  {i}. {err}")
            print()
        if warnings:
            print(f"WARNINGS ({len(warnings)}):")
            for i, warn in enumerate(warnings, 1):
                print(f"  {i}. {warn}")
            print()

        if not errors and not warnings:
            print("Brief richness: HIGH — analyst is likely to pass on attempt 1")
            print("✓ Brownfield brief looks good. Pipeline can start.\n")
        elif not errors:
            print("✓ No blocking issues. Warnings above are advisory.\n")
        else:
            print("✗ Fix blocking issues before running the pipeline.\n")
            sys.exit(1)
    else:
        validate(brief_path)
