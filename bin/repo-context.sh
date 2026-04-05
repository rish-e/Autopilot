#!/bin/bash
# repo-context.sh — Generate compact repo context for Autopilot
#
# Creates a cached project summary using JCodeMunch AST parsing,
# avoiding expensive full-file reads during project onboarding.
#
# Usage:
#   repo-context.sh [project_dir]    Generate or refresh repo context
#   repo-context.sh --check          Check if context exists and is fresh
#   repo-context.sh --clear          Remove cached context
#
# Output: .autopilot/repo-context.md (cached, refreshed on git changes)
# Performance: <5s for most projects (depends on JCodeMunch indexing)

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

# Resolve project dir (skip flags)
_arg="${1:-}"
if [[ "$_arg" == --* ]] || [[ -z "$_arg" ]]; then
    PROJECT_DIR="$(pwd)"
else
    PROJECT_DIR="$(cd "$_arg" && pwd)"
fi
CACHE_DIR="$PROJECT_DIR/.autopilot"
CACHE_FILE="$CACHE_DIR/repo-context.md"
STALENESS_MARKER="$CACHE_DIR/.repo-context-ref"
MAX_AGE_SECONDS=3600  # Refresh if older than 1 hour

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────

is_git_repo() {
    git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null
}

get_head_ref() {
    git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown"
}

is_cache_fresh() {
    [ -f "$CACHE_FILE" ] || return 1
    [ -f "$STALENESS_MARKER" ] || return 1

    # Check if HEAD changed since last context generation
    if is_git_repo; then
        local cached_ref
        cached_ref=$(cat "$STALENESS_MARKER" 2>/dev/null || echo "")
        local current_ref
        current_ref=$(get_head_ref)
        [ "$cached_ref" = "$current_ref" ] && return 0
    fi

    # Fallback: check age
    local cache_mtime now cache_age
    cache_mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    cache_age=$((now - cache_mtime))
    [ "$cache_age" -lt "$MAX_AGE_SECONDS" ]
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_check() {
    if is_cache_fresh; then
        echo -e "${GREEN}Fresh${NC}: $CACHE_FILE"
        echo -e "${DIM}$(wc -l < "$CACHE_FILE" | tr -d ' ') lines, $(wc -c < "$CACHE_FILE" | awk '{printf "%.1f KB", $1/1024}')${NC}"
        exit 0
    elif [ -f "$CACHE_FILE" ]; then
        echo -e "${YELLOW}Stale${NC}: $CACHE_FILE (HEAD changed or too old)"
        exit 1
    else
        echo -e "${YELLOW}Missing${NC}: No repo context cached"
        exit 1
    fi
}

cmd_clear() {
    rm -f "$CACHE_FILE" "$STALENESS_MARKER"
    echo -e "${GREEN}Cleared${NC} repo context cache"
}

cmd_generate() {
    mkdir -p "$CACHE_DIR"

    # Check if cache is fresh
    if is_cache_fresh; then
        echo -e "${DIM}Cache is fresh, skipping regeneration${NC}"
        cat "$CACHE_FILE"
        return
    fi

    echo -e "${BOLD}Generating repo context...${NC}" >&2

    local context=""
    local project_name
    project_name=$(basename "$PROJECT_DIR")

    # Header
    context="# Repo Context: $project_name"
    context+="\n# Generated: $(date -u '+%Y-%m-%d %H:%M UTC')"
    if is_git_repo; then
        local branch
        branch=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "detached")
        context+="\n# Branch: $branch | HEAD: $(get_head_ref | head -c 8)"
    fi
    context+="\n"

    # File tree (quick, no JCodeMunch needed)
    context+="\n## File Tree\n\`\`\`"
    if is_git_repo; then
        context+="\n$(git -C "$PROJECT_DIR" ls-files | head -200)"
        local total
        total=$(git -C "$PROJECT_DIR" ls-files | wc -l | tr -d ' ')
        if [ "$total" -gt 200 ]; then
            context+="\n... ($total files total, showing first 200)"
        fi
    else
        context+="\n$(find "$PROJECT_DIR" -maxdepth 4 -not -path '*/.*' -not -path '*/node_modules/*' -not -path '*/__pycache__/*' | head -200 | sed "s|$PROJECT_DIR/||")"
    fi
    context+="\n\`\`\`\n"

    # Package info (if exists)
    if [ -f "$PROJECT_DIR/package.json" ]; then
        context+="\n## Package Info"
        local pkg_name pkg_desc
        pkg_name=$(python3 -c "import json; d=json.load(open('$PROJECT_DIR/package.json')); print(d.get('name',''))" 2>/dev/null || true)
        pkg_desc=$(python3 -c "import json; d=json.load(open('$PROJECT_DIR/package.json')); print(d.get('description',''))" 2>/dev/null || true)
        [ -n "$pkg_name" ] && context+="\n- Name: $pkg_name"
        [ -n "$pkg_desc" ] && context+="\n- Description: $pkg_desc"

        # Key dependencies
        local deps
        deps=$(python3 -c "
import json
d = json.load(open('$PROJECT_DIR/package.json'))
all_deps = list(d.get('dependencies', {}).keys()) + list(d.get('devDependencies', {}).keys())
print(', '.join(sorted(all_deps)[:20]))
" 2>/dev/null || true)
        [ -n "$deps" ] && context+="\n- Key deps: $deps"
        context+="\n"
    fi

    if [ -f "$PROJECT_DIR/pyproject.toml" ]; then
        context+="\n## Python Project"
        local py_name
        py_name=$(grep -m1 '^name' "$PROJECT_DIR/pyproject.toml" 2>/dev/null | sed 's/.*=\s*"\(.*\)"/\1/' || true)
        [ -n "$py_name" ] && context+="\n- Name: $py_name"
        context+="\n"
    fi

    # Entry points (key files)
    context+="\n## Entry Points"
    for f in "src/index.ts" "src/index.js" "src/main.ts" "src/main.py" "main.py" "app.py" \
             "src/app.ts" "src/App.tsx" "pages/index.tsx" "app/page.tsx" "app/layout.tsx" \
             "index.html" "server.ts" "server.js"; do
        if [ -f "$PROJECT_DIR/$f" ]; then
            context+="\n- $f"
        fi
    done
    context+="\n"

    # Git recent activity (if available)
    if is_git_repo; then
        context+="\n## Recent Activity (last 10 commits)"
        context+="\n\`\`\`"
        context+="\n$(git -C "$PROJECT_DIR" log --oneline -10 2>/dev/null || echo "no commits")"
        context+="\n\`\`\`\n"
    fi

    # Write cache
    echo -e "$context" > "$CACHE_FILE"
    get_head_ref > "$STALENESS_MARKER"

    echo -e "${GREEN}Generated${NC}: $CACHE_FILE ($(wc -l < "$CACHE_FILE" | tr -d ' ') lines)" >&2
    cat "$CACHE_FILE"
}

# ─── Main ────────────────────────────────────────────────────────────────────

# Parse flags first, before PROJECT_DIR resolution
case "${1:-}" in
    --check)
        PROJECT_DIR="$(pwd)"
        CACHE_DIR="$PROJECT_DIR/.autopilot"
        CACHE_FILE="$CACHE_DIR/repo-context.md"
        STALENESS_MARKER="$CACHE_DIR/.repo-context-ref"
        cmd_check
        ;;
    --clear)
        PROJECT_DIR="$(pwd)"
        CACHE_DIR="$PROJECT_DIR/.autopilot"
        CACHE_FILE="$CACHE_DIR/repo-context.md"
        STALENESS_MARKER="$CACHE_DIR/.repo-context-ref"
        cmd_clear
        ;;
    --help|-h)
        echo "Usage: repo-context.sh [project_dir|--check|--clear]"
        echo "Generate a compact repo context summary for Autopilot"
        ;;
    *) cmd_generate ;;
esac
