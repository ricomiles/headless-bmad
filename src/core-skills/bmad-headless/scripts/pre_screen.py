#!/usr/bin/env python3
"""
pre_screen.py — Zero-cost structural check for stage output before any LLM gate call.
Usage: python3 scripts/pre_screen.py <stage_name> <output_file_path>
Exit 0: all checks pass (or stage not recognized) — proceed to gate
Exit 1: structural failure(s) found — gate returns FAIL immediately; no LLM invoked
"""

import sys
import re

KNOWN_STAGES = {'analyst', 'architect', 'developer'}

REQUIRED_SECTIONS = {
    'analyst': [
        ('functional requirements', 'Add a "## Functional Requirements" heading listing all FRs.'),
        ('non-functional requirements', 'Add a "## Non-Functional Requirements" heading.'),
        ('out of scope', 'Add an "## Out of Scope" heading listing what is explicitly excluded.'),
        ('decisions made', 'Add a "## Decisions Made" heading with D-NNN entries for all implicit decisions.'),
    ],
    'architect': [
        ('api contract', 'Add an "## API Contracts" or "## Interfaces" section defining all endpoints and data contracts.'),
        ('file structure', 'Add a "## File Structure" or "## Folder Structure" section listing the key files and directories.'),
    ],
}


def _extract_section(content, keywords):
    lines = content.splitlines()
    in_section = False
    section_depth = 0
    section_lines = []
    for line in lines:
        m = re.match(r'^(#{1,6})\s+', line)
        if m:
            depth = len(m.group(1))
            heading_text = re.sub(r'^#+\s+', '', line).lower()
            if any(kw in heading_text for kw in keywords):
                in_section = True
                section_depth = depth
                section_lines = []
                continue
            elif in_section and depth <= section_depth:
                break
            elif in_section:
                section_lines.append(line)
        elif in_section:
            section_lines.append(line)
    return '\n'.join(section_lines).strip() if section_lines else None


def check_required_sections(content, stage):
    failures = []
    reqs = REQUIRED_SECTIONS.get(stage)
    if not reqs:
        return failures
    headings = [
        re.sub(r'^#+\s+', '', line).strip().lower()
        for line in content.splitlines()
        if re.match(r'^#{1,4}\s+', line)
    ]
    for kw, fix in reqs:
        if not any(kw in h for h in headings):
            failures.append(f"Missing required section '{kw}'. {fix}")
    return failures


def check_placeholder_text(content):
    failures = []
    placeholders = re.findall(r'\b(TBD|TODO|FIXME)\b', content, re.IGNORECASE)
    if placeholders:
        unique = list(dict.fromkeys(p.upper() for p in placeholders))
        failures.append(
            f"Placeholder text found: {', '.join(unique)}. "
            'Replace all placeholder text with concrete content before submitting.'
        )
    open_q = _extract_section(content, ['open question', 'open questions'])
    if open_q:
        non_empty = [l for l in open_q.strip().splitlines() if l.strip() and not l.strip().startswith('#')]
        if non_empty:
            failures.append(
                '"Open questions" section found with unresolved items. '
                'Resolve all open questions and remove the section before submitting.'
            )
    return failures


def check_analyst_fr_criteria(content):
    failures = []
    lines = content.splitlines()
    fr_pattern = re.compile(r'^#{1,4}\s+FR[-\s]?\d+', re.IGNORECASE)
    next_heading = re.compile(r'^#{1,4}\s+')
    gwt = re.compile(r'\b(Given|When|Then)\b', re.IGNORECASE)

    i = 0
    while i < len(lines):
        if fr_pattern.match(lines[i]):
            fr_heading = lines[i].strip()
            j = i + 1
            found_gwt = False
            while j < len(lines):
                if next_heading.match(lines[j]):
                    break
                if gwt.search(lines[j]):
                    found_gwt = True
                    break
                j += 1
            if not found_gwt:
                failures.append(
                    f"FR heading '{fr_heading}' has no Given/When/Then acceptance criterion. "
                    'Add at least one "Given ... When ... Then ..." criterion under this FR.'
                )
        i += 1
    return failures


def check_architect_specifics(content):
    failures = []
    api_section = _extract_section(content, ['api contract', 'api contracts', 'endpoints', 'interfaces'])
    if api_section and re.search(r'\bTBD\b', api_section, re.IGNORECASE):
        failures.append(
            'TBD found in API contracts/interfaces section. '
            'All API contracts must specify concrete types — replace every TBD with a real type or value.'
        )
    file_section = _extract_section(
        content, ['file structure', 'folder structure', 'directory structure', 'file/folder']
    )
    if file_section and re.search(r'\bTBD\b', file_section, re.IGNORECASE):
        failures.append(
            'TBD found in file/folder structure section. '
            'All file paths must be specified concretely — replace every TBD with a real path.'
        )
    has_inline_adrs = '--- ADR ---' in content or bool(re.search(r'(?m)^#+ ADR[-\s]', content))
    has_adr_file_ref = bool(re.search(r'ADR[s]?.*(?:file|doc|separate|see)|see.*ADR', content, re.IGNORECASE))
    if not has_inline_adrs and not has_adr_file_ref:
        failures.append(
            'No ADRs found. Architecture must include ADRs either inline '
            '(headings matching "# ADR-..." or separated by "--- ADR ---") '
            'or reference a separate ADR document.'
        )
    return failures


def _brief_has_designs():
    """Return True if PROJECT_BRIEF.md declares a designs/UI section."""
    try:
        with open('PROJECT_BRIEF.md') as f:
            brief = f.read()
    except (FileNotFoundError, OSError):
        return False
    headings = [
        re.sub(r'^#+\s+', '', line).strip().lower()
        for line in brief.splitlines()
        if re.match(r'^#{1,4}\s+', line)
    ]
    return any(
        any(kw in h for kw in ('design', 'ui', 'mockup', 'wireframe'))
        for h in headings
    )


def check_developer_design_compliance(content):
    """If the brief declares a design, output must contain a Design Compliance Checklist heading."""
    failures = []
    if not _brief_has_designs():
        return failures
    output_headings = [
        re.sub(r'^#+\s+', '', line).strip().lower()
        for line in content.splitlines()
        if re.match(r'^#{1,4}\s+', line)
    ]
    if not any('design compliance' in h for h in output_headings):
        failures.append(
            'PROJECT_BRIEF.md declares a design but the output is missing a '
            '"## Design Compliance Checklist" section. '
            'Add a checklist mapping each designed component to its implementation file, '
            'marked ✅ implemented or ❌ missing/deviated (with justification).'
        )
    return failures


def run_checks(stage, output_path):
    # AC5: unknown stages are a complete no-op — skip ALL checks
    if stage not in KNOWN_STAGES:
        print('Pre-screen: PASS — proceeding to gate')
        sys.exit(0)

    try:
        with open(output_path) as f:
            content = f.read()
    except FileNotFoundError:
        print(f'Pre-screen: ERROR — output file not found: {output_path}')
        sys.exit(1)
    except OSError as e:
        print(f'Pre-screen: ERROR — cannot read output file: {e}')
        sys.exit(1)

    failures = []
    failures.extend(check_required_sections(content, stage))
    failures.extend(check_placeholder_text(content))
    if stage == 'analyst':
        failures.extend(check_analyst_fr_criteria(content))
    elif stage == 'architect':
        failures.extend(check_architect_specifics(content))
    elif stage == 'developer':
        failures.extend(check_developer_design_compliance(content))

    if failures:
        print(f'Pre-screen: FAIL — {len(failures)} structural issue(s) found:')
        for i, msg in enumerate(failures, 1):
            print(f'  {i}. {msg}')
        sys.exit(1)
    else:
        print('Pre-screen: PASS — proceeding to gate')
        sys.exit(0)


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print('Usage: python3 pre_screen.py <stage_name> <output_file_path>')
        sys.exit(1)
    run_checks(sys.argv[1], sys.argv[2])
