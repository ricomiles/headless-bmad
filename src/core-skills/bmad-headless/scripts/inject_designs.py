#!/usr/bin/env python3
"""
inject_designs.py — Read design artifacts from PROJECT_BRIEF.md and return
formatted context for injection into a pipeline stage's prompt.

Usage: python3 scripts/inject_designs.py <stage_name>
Output: formatted context string to stdout, or empty string if no designs apply

Supported types:
  claude-artifact   React/HTML artifact from Claude (JSX, HTML)
  images            PNG/JPG screenshots or exports (base64 encoded for claude -p)
  figma-dev-export  Figma Dev Mode JSON export + optional images
  figma             Figma URL (requires FIGMA_TOKEN env var)

Stages that receive design context:
  analyst        — reads designs, extracts acceptance criteria
  architect      — reads designs, infers API contracts and component structure
  task-breakdown — reads designs, writes design-specific ACs into every UI ticket
  developer      — receives design as frozen reference to implement against
"""

import sys
import os
import re
import json
import base64
import mimetypes

DESIGN_STAGES = {"analyst", "architect", "task-breakdown", "developer"}


def main():
    stage = sys.argv[1] if len(sys.argv) > 1 else ""
    if stage not in DESIGN_STAGES:
        print("")
        return

    brief = read_brief()
    if not brief:
        print("")
        return

    design_config = parse_design_block(brief)
    if not design_config:
        print("")
        return

    design_type = design_config.get("type", "").strip()
    notes = design_config.get("notes", "").strip()

    if design_type == "claude-artifact":
        output = handle_claude_artifact(design_config, stage, notes)
    elif design_type == "images":
        output = handle_images(design_config, stage, notes)
    elif design_type == "figma-dev-export":
        output = handle_figma_dev_export(design_config, stage, notes)
    elif design_type == "figma":
        output = handle_figma_url(design_config, stage, notes)
    else:
        sys.stderr.write(f"Unknown design type: {design_type}\n")
        output = ""

    print(output)


# ─── Design type handlers ─────────────────────────────────────────────────────

def handle_claude_artifact(config, stage, notes):
    """
    Claude design handoff — a directory (or single file) containing:
    - README / spec doc (the written design spec)
    - Multiple JSX/TSX component files
    - Design system / tokens doc
    - Possibly images (handled via IMAGE_FLAGS)

    Reads the directory as a structured bundle:
    1. Spec/README files first (anchor for all stages)
    2. Component files in logical order
    3. Design system / token files
    Respects a token budget — truncates if the handoff is very large.
    """
    # Support both single file (path:) and directory (dir:)
    dir_path  = config.get("dir",  "").strip()
    file_path = config.get("path", "").strip()

    if dir_path:
        if not os.path.isdir(dir_path):
            sys.stderr.write(f"Design handoff directory not found: {dir_path}\n")
            return ""
        bundle = read_handoff_dir(dir_path)
    elif file_path:
        if not os.path.exists(file_path):
            sys.stderr.write(f"Design artifact not found: {file_path}\n")
            return ""
        ext  = os.path.splitext(file_path)[1].lower()
        lang = "jsx" if ext in (".jsx", ".tsx") else "html" if ext == ".html" else "javascript"
        with open(file_path) as f:
            code = f.read()
        bundle = DesignBundle(
            spec="",
            components=[(file_path, lang, code)],
            design_system="",
            image_paths=[],
            file_tree=file_path,
        )
    else:
        sys.stderr.write("Design block has neither dir: nor path:\n")
        return ""

    return format_bundle_for_stage(bundle, stage, notes)


# ── Token budget ──────────────────────────────────────────────────────────────
# Rough char limits per stage injection (not exact tokens, but conservative).
# Analyst/architect need the spec + shape of components.
# Developer needs full component code to implement against.
CHAR_BUDGET = {
    "analyst":        40_000,
    "architect":      50_000,
    "task-breakdown": 40_000,
    "developer":      80_000,
}


class DesignBundle:
    def __init__(self, spec, components, design_system, image_paths, file_tree):
        self.spec          = spec           # str: README / spec content
        self.components    = components     # [(path, lang, code), ...]
        self.design_system = design_system  # str: tokens / design system doc
        self.image_paths   = image_paths    # [str, ...]
        self.file_tree     = file_tree      # str: directory listing


def read_handoff_dir(dir_path):
    """
    Walk a design handoff directory and classify files into:
    - spec docs (README, SPEC, DESIGN)
    - component files (.jsx .tsx .js .ts .html)
    - design system / tokens (.md with "token"/"system"/"design" in name, .json)
    - images (.png .jpg .svg) → handled as IMAGE_FLAGS
    """
    spec_names      = {"readme", "spec", "design", "overview", "handoff", "index"}
    ds_names        = {"token", "design-system", "designsystem", "system", "theme", "colors", "typography"}
    code_exts       = {".jsx", ".tsx", ".js", ".ts", ".html"}
    image_exts      = {".png", ".jpg", ".jpeg", ".svg", ".webp"}
    doc_exts        = {".md", ".mdx", ".txt"}

    spec_files      = []
    component_files = []
    ds_files        = []
    image_paths     = []
    all_paths       = []

    for root, dirs, files in os.walk(dir_path):
        dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in ("node_modules", "dist", "build", ".git"))
        for fname in sorted(files):
            fpath = os.path.join(root, fname)
            relpath = os.path.relpath(fpath, dir_path)
            ext   = os.path.splitext(fname)[1].lower()
            stem  = os.path.splitext(fname)[0].lower()
            all_paths.append(relpath)

            if ext in image_exts:
                image_paths.append(fpath)
            elif ext in doc_exts:
                if any(kw in stem for kw in ds_names):
                    ds_files.append((relpath, "markdown", fpath))
                elif any(kw in stem for kw in spec_names):
                    spec_files.append((relpath, "markdown", fpath))
                else:
                    # Other docs go into spec bucket
                    spec_files.append((relpath, "markdown", fpath))
            elif ext in code_exts:
                lang = "jsx" if ext in (".jsx", ".tsx") else "typescript" if ext == ".ts" else "javascript"
                component_files.append((relpath, lang, fpath))
            elif ext == ".json":
                if any(kw in stem for kw in ds_names | {"tokens", "theme"}):
                    ds_files.append((relpath, "json", fpath))

    def read_file(fpath):
        try:
            with open(fpath, encoding="utf-8", errors="replace") as f:
                return f.read()
        except Exception as e:
            return f"(could not read: {e})"

    spec_content = ""
    for relpath, lang, fpath in spec_files:
        content = read_file(fpath)
        spec_content += f"### {relpath}\n{content}\n\n"

    ds_content = ""
    for relpath, lang, fpath in ds_files:
        content = read_file(fpath)
        ds_content += f"### {relpath}\n```{lang}\n{content}\n```\n\n"

    components = []
    for relpath, lang, fpath in component_files:
        code = read_file(fpath)
        components.append((relpath, lang, code))

    file_tree = "\n".join(all_paths)

    return DesignBundle(
        spec=spec_content,
        components=components,
        design_system=ds_content,
        image_paths=image_paths,
        file_tree=file_tree,
    )


def format_bundle_for_stage(bundle, stage, notes):
    """
    Format the design bundle differently per stage, respecting char budget.
    """
    budget = CHAR_BUDGET.get(stage, 40_000)

    # Build the header block (always included)
    header = f"""=== CLAUDE DESIGN HANDOFF ===
Files in this handoff:
{bundle.file_tree}

"""
    if notes:
        header += f"Design notes: {notes}\n\n"

    # Stage-specific framing
    stage_intros = {
        "analyst": """Your job: read this design handoff and extract user-facing acceptance criteria.
For every screen, component, and interaction visible in the code:
- Write Given/When/Then acceptance criteria
- Treat mock/hardcoded data as the shape of real data
- Note every conditional render as a state requiring a criterion
Do NOT write implementation details.
""",
        "architect": """Your job: read this design handoff and infer what the backend and frontend architecture must provide.
From the component code and mock data:
- Extract every data structure (field names, types, relationships)
- Identify every async operation / API call implied by handlers
- Define what state must be persisted vs local-only
- Map out the component dependency tree for the frontend architecture
""",
        "task-breakdown": """This design covers a subset of the UI. Components and screens shown in the design are FROZEN — implement them exactly. Screens or components NOT in the design are at developer discretion, but must follow the same visual language and patterns.
When writing tickets that touch any UI screen or component:
- If the component is in the design: name it explicitly, write an AC that it matches the design exactly, and list it in the manifest's "design_components" field
- If the component is NOT in the design: note it as "undesigned — follow design system patterns" so the developer knows they have discretion
- Add a design compliance AC to every ticket that owns a designed component: "Given the design handoff, when implemented, the component matches the design exactly — no element may be removed or substituted"
""",
        "developer": """This design covers a subset of the UI. The rule is:
- Components and screens explicitly shown in the design are FROZEN — implement them exactly as shown
- Screens or components NOT in the design are at your discretion — build them to match the design's visual language and patterns, but the exact layout is up to you

For FROZEN components you must:
1. Preserve all UI structure, layout, and interactions exactly as shown
2. Replace every mock/hardcoded value with real API calls
3. Reorganise into proper files per the architecture (do not keep as a monolith)
4. Add loading, error, and empty states for every async fetch
5. Use mock data shapes as test fixtures

At the end of your output you MUST include a ## Design Compliance Checklist section:
- List every component/screen explicitly named in the design above (frozen scope only)
- For each, note the file that implements it and mark as ✅ implemented or ❌ missing/deviated (with reason)
- Any deviation from a frozen component requires an explicit justification
- Components you built that are NOT in the design do not need to appear here
""",
    }

    intro = stage_intros.get(stage, "")
    used = len(header) + len(intro)

    sections = []

    # 1. Spec / README (always first, always included)
    if bundle.spec:
        block = f"--- SPEC / README ---\n{bundle.spec}"
        sections.append(("spec", block))
        used += len(block)

    # 2. Design system / tokens (small, include early)
    if bundle.design_system:
        block = f"--- DESIGN SYSTEM / TOKENS ---\n{bundle.design_system}"
        sections.append(("ds", block))
        used += len(block)

    # 3. Components — include as many as budget allows
    # Developer gets full code; all other stages get truncated excerpts
    trunc_limit = None if stage == "developer" else 3_000  # chars per file for non-dev

    component_blocks = []
    for relpath, lang, code in bundle.components:
        if trunc_limit and len(code) > trunc_limit:
            display = code[:trunc_limit] + f"\n... (truncated — {len(code)} chars total)"
        else:
            display = code
        block = f"--- {relpath} ---\n```{lang}\n{display}\n```\n"
        component_blocks.append((len(block), block))

    # Sort smaller files first so we fit more in budget
    component_blocks.sort(key=lambda x: x[0])

    included = 0
    skipped  = []
    for size, block in component_blocks:
        if used + size < budget:
            sections.append(("component", block))
            used += size
            included += 1
        else:
            # Extract just the path from the block header
            first_line = block.split("\n")[0]
            skipped.append(first_line.strip("- "))

    if skipped:
        skip_note = f"--- NOTE: {len(skipped)} component file(s) omitted due to context budget ---\n"
        skip_note += "\n".join(f"  {s}" for s in skipped)
        skip_note += "\nReference them directly from the handoff directory.\n"
        sections.append(("skip_note", skip_note))

    # 4. Image marker (images handled via --image flags in run_stage.sh)
    if bundle.image_paths:
        marker = "IMAGE_INJECT:" + ":".join(bundle.image_paths)
        sections.append(("images", marker))

    body = "\n".join(block for _, block in sections if not _.startswith("images"))
    image_markers = "\n".join(block for kind, block in sections if kind == "images")

    return f"{header}{intro}\n{body}\n{image_markers}\n=== END DESIGN HANDOFF ===\n"


def handle_images(config, stage, notes):
    """
    PNG/JPG screenshots or exports.
    Encodes images as base64 for inclusion in claude -p multimodal prompt.
    """
    paths_raw = config.get("paths", "")
    if isinstance(paths_raw, str):
        # Parse YAML-style list from the brief
        paths = [p.strip().lstrip("- ").strip() for p in paths_raw.strip().splitlines() if p.strip()]
    else:
        paths = paths_raw

    if not paths:
        sys.stderr.write("No image paths found in designs block.\n")
        return ""

    # For text-based prompt injection (claude -p takes text), we describe the images
    # and note their paths. Claude Code's vision is activated when images are passed
    # via the --image flag or in the API call. Here we output a marker that
    # run_stage.sh picks up to pass images via --image flags.
    found = []
    missing = []
    for p in paths:
        if os.path.exists(p):
            found.append(p)
        else:
            missing.append(p)

    if missing:
        sys.stderr.write(f"Missing design images: {missing}\n")

    if not found:
        return ""

    stage_framing = {
        "analyst": "read these UI screens and extract acceptance criteria from what you see",
        "architect": "read these UI screens and infer the API contracts and data models they require",
        "developer": "implement the UI to exactly match these screens — layout, spacing, components, interactions"
    }

    image_list = "\n".join(f"  - {p}" for p in found)
    framing = stage_framing.get(stage, "use as reference")

    # Emit a special marker that run_stage.sh reads to pass --image flags
    # Format: IMAGE_INJECT:<path1>:<path2>:...
    image_marker = "IMAGE_INJECT:" + ":".join(found)

    return f"""=== DESIGN IMAGES ===
{image_marker}
The following design screens are provided as images ({framing}):
{image_list}
{f"Design notes: {notes}" if notes else ""}
=== END DESIGN IMAGES ===
"""


def handle_figma_dev_export(config, stage, notes):
    """
    Figma Dev Mode JSON export. More precise than images — has exact measurements.
    """
    spec_path = config.get("spec_path", "").strip()
    images_path = config.get("images_path", "").strip()

    if not spec_path or not os.path.exists(spec_path):
        sys.stderr.write(f"Figma dev export not found: {spec_path}\n")
        return ""

    with open(spec_path) as f:
        spec = json.load(f)

    # Extract the useful parts of the Figma export spec
    # Figma Dev Mode exports vary — we pull component names, properties, and tokens
    summary = summarize_figma_spec(spec)

    image_context = ""
    if images_path and os.path.isdir(images_path):
        screens = [f for f in os.listdir(images_path)
                   if f.lower().endswith((".png", ".jpg", ".jpeg"))]
        if screens:
            image_list = "\n".join(f"  - {images_path}/{s}" for s in sorted(screens))
            image_marker = "IMAGE_INJECT:" + ":".join(
                f"{images_path}/{s}" for s in sorted(screens)
                if os.path.exists(f"{images_path}/{s}")
            )
            image_context = f"\n{image_marker}\nScreen images:\n{image_list}"

    stage_framing = {
        "analyst": "Extract acceptance criteria from the component specs and screen images.",
        "architect": "Use exact component specs, tokens, and measurements to define frontend architecture.",
        "developer": "Implement components to exactly match the Figma specs. Use exact values for spacing, typography, and color tokens."
    }

    return f"""=== FIGMA DEV EXPORT ===
{stage_framing.get(stage, "")}

Component summary:
{summary}
{image_context}
{f"Design notes: {notes}" if notes else ""}
=== END FIGMA DEV EXPORT ===
"""


def handle_figma_url(config, stage, notes):
    """
    Live Figma URL. Requires FIGMA_TOKEN env var.
    Fetches file metadata and frame list — actual frame images fetched in run_stage.sh.
    """
    url = config.get("url", "").strip()
    frames = config.get("frames", [])
    if isinstance(frames, str):
        frames = [f.strip().lstrip("- ").strip() for f in frames.splitlines() if f.strip()]

    token = os.environ.get("FIGMA_TOKEN", "")
    if not token:
        sys.stderr.write("FIGMA_TOKEN not set — cannot fetch Figma file\n")
        sys.stderr.write("Set it with: export FIGMA_TOKEN=your_token\n")
        return ""

    # Extract file key from URL
    m = re.search(r'figma\.com/(?:file|design)/([A-Za-z0-9]+)', url)
    if not m:
        sys.stderr.write(f"Could not extract Figma file key from URL: {url}\n")
        return ""

    file_key = m.group(1)

    # Emit marker for run_stage.sh to fetch Figma frames
    frame_list = "\n".join(f"  - {f}" for f in frames) if frames else "  (all frames)"
    figma_marker = f"FIGMA_INJECT:{file_key}:{','.join(frames)}"

    stage_framing = {
        "analyst": "read these Figma screens and extract acceptance criteria",
        "architect": "read these Figma screens and infer API contracts and component structure",
        "developer": "implement the UI to match these Figma screens exactly"
    }

    return f"""=== FIGMA DESIGN ===
{figma_marker}
Figma file: {url}
Frames to use ({stage_framing.get(stage, "reference")}):
{frame_list}
{f"Design notes: {notes}" if notes else ""}
=== END FIGMA DESIGN ===
"""


# ─── Helpers ──────────────────────────────────────────────────────────────────

def read_brief(brief_path="PROJECT_BRIEF.md"):
    if not os.path.exists(brief_path):
        return None
    with open(brief_path) as f:
        return f.read()


def parse_design_block(content):
    """
    Parse the ## Designs section from the brief.
    Returns a dict of key: value pairs.
    """
    lines = content.splitlines()
    in_section = False
    section_lines = []

    for line in lines:
        if re.match(r'^#{1,3}\s+', line):
            heading = re.sub(r'^#+\s+', '', line).lower()
            if any(kw in heading for kw in ["design", "ui", "mockup", "wireframe"]):
                in_section = True
                section_lines = []
                continue
            elif in_section:
                break
        elif in_section:
            section_lines.append(line)

    if not section_lines:
        return None

    # Parse simple key: value and key: multiline list
    config = {}
    current_key = None
    list_lines = []

    for line in section_lines:
        # Key: value line
        kv = re.match(r'^(\w[\w-]*):\s*(.*)$', line.strip())
        if kv:
            if current_key and list_lines:
                config[current_key] = "\n".join(list_lines)
            current_key = kv.group(1)
            val = kv.group(2).strip()
            if val:
                config[current_key] = val
                current_key = None
            else:
                list_lines = []
        elif current_key and line.strip():
            list_lines.append(line.strip())

    if current_key and list_lines:
        config[current_key] = "\n".join(list_lines)

    return config if config else None


def summarize_figma_spec(spec):
    """Extract a readable summary from a Figma Dev Mode JSON export."""
    lines = []

    # Components
    components = spec.get("components", {})
    if components:
        lines.append(f"Components ({len(components)}):")
        for name, comp in list(components.items())[:20]:
            lines.append(f"  - {comp.get('name', name)}")

    # Tokens / styles
    styles = spec.get("styles", {})
    if styles:
        lines.append(f"\nDesign tokens ({len(styles)}):")
        for name, style in list(styles.items())[:10]:
            lines.append(f"  - {style.get('name', name)}: {style.get('styleType', '')}")

    # Document structure
    doc = spec.get("document", {})
    if doc:
        pages = doc.get("children", [])
        if pages:
            lines.append(f"\nPages: {', '.join(p.get('name', '') for p in pages)}")

    return "\n".join(lines) if lines else "(spec loaded — see full JSON for details)"


if __name__ == "__main__":
    main()
