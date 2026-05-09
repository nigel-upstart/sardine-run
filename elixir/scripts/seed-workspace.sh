#!/usr/bin/env bash
# Seeds a sardine-run workspace by cloning the target repo declared on the
# Traffic Control session and (if set) checking out session.branch.
#
# Runs from the workspace cwd as the after_create hook, so it operates
# outside the Codex sandbox and can use ssh/network/git as the host user.
#
# Repo resolution priority (first non-empty wins):
#   1. links.yaml entries with `kind: repo` (must collapse to one repo URL)
#   2. links.yaml entries with `kind: pr`   (must collapse to one repo URL)
#   3. session.yaml `cwd:` field, if it contains `<known-org>/<repo>` segment
#
# Multiple distinct candidates → exit non-zero (session must be split).
# Workspace already a clone of a different repo → exit non-zero (manual fix).
# Workspace already a clone of the right repo  → no-op.
set -euo pipefail

KNOWN_ORGS_RE='(teamupstart|nigel-upstart|openai|getprodigy)'

SESSION_ID=$(basename "$PWD")
STATE_REPO="${TRAFFIC_CONTROL_STATE_REPO:-$HOME/repos/nigel-upstart/traffic-control-state}"
SESSION_YAML="$STATE_REPO/sessions/$SESSION_ID/session.yaml"
LINKS_YAML="$STATE_REPO/sessions/$SESSION_ID/links.yaml"

log() { printf 'seed-workspace[%s]: %s\n' "$SESSION_ID" "$*" >&2; }

# --- Idempotency -------------------------------------------------------------
if [ -d .git ]; then
  existing=$(git config --get remote.origin.url 2>/dev/null || true)
  case "$existing" in
    *openai/symphony*)
      log "stale openai/symphony clone detected at $PWD"
      log "manual fix: rm -rf $PWD then re-dispatch this session"
      exit 11
      ;;
    "")
      log "workspace has .git but no remote; refusing to clobber"
      exit 12
      ;;
    *)
      log "workspace already cloned ($existing); skipping"
      exit 0
      ;;
  esac
fi

# --- Helpers -----------------------------------------------------------------
extract_link_urls() {
  # $1 = kind name to match (e.g. 'repo' or 'pr')
  # Handles both YAML layouts: `- kind: foo\n  url: ...` and
  # `- label: foo\n  kind: bar\n  url: ...`. The leading-dash regex variants
  # accept lines like `- kind: pr` where the dash is the first character.
  awk -v want="$1" '
    /^-[[:space:]]/ { kind=""; url="" }
    /^[-[:space:]]*kind:[[:space:]]/ {
      line=$0
      sub(/^[-[:space:]]*kind:[[:space:]]*"?/, "", line)
      sub(/"?[[:space:]]*$/, "", line)
      kind=line
    }
    /^[-[:space:]]*url:[[:space:]]/ {
      line=$0
      sub(/^[-[:space:]]*url:[[:space:]]*"?/, "", line)
      sub(/"?[[:space:]]*$/, "", line)
      if (kind == want && line != "") print line
    }
  ' "$LINKS_YAML"
}

extract_yaml_scalar() {
  # $1 = top-level key in session.yaml
  awk -v key="$1" '
    $0 ~ "^"key":" {
      sub("^"key":[[:space:]]*\"?", "")
      sub("\"?[[:space:]]*$", "")
      print
      exit
    }
  ' "$SESSION_YAML"
}

# --- Resolve candidate repo URLs --------------------------------------------
candidates=()

if [ -f "$LINKS_YAML" ]; then
  while IFS= read -r u; do
    u=${u%/}
    [ -n "$u" ] && candidates+=("$u")
  done < <(extract_link_urls repo | grep -E '^https://github.com/[^/]+/[^/]+/?$' || true)

  if [ "${#candidates[@]}" -eq 0 ]; then
    while IFS= read -r u; do
      base=$(printf '%s\n' "$u" | sed -E 's#^(https://github.com/[^/]+/[^/]+)/.*#\1#')
      [ -n "$base" ] && candidates+=("$base")
    done < <(extract_link_urls pr | grep -E '^https://github.com/[^/]+/[^/]+/' || true)
  fi
fi

if [ "${#candidates[@]}" -eq 0 ] && [ -f "$SESSION_YAML" ]; then
  cwd_val=$(extract_yaml_scalar cwd)
  if printf '%s' "$cwd_val" | grep -qE "/${KNOWN_ORGS_RE}/[^/]+"; then
    org_repo=$(printf '%s' "$cwd_val" | sed -E "s#.*/${KNOWN_ORGS_RE}/([^/]+)(/.*|\$)#\1/\2#")
    candidates+=("https://github.com/$org_repo")
  fi
fi

unique=()
while IFS= read -r u; do
  [ -n "$u" ] && unique+=("$u")
done < <(printf '%s\n' "${candidates[@]:-}" | awk 'NF' | sort -u)

if [ "${#unique[@]}" -eq 0 ]; then
  log "no repo signal found in $LINKS_YAML or $SESSION_YAML; skipping clone"
  exit 13
fi

if [ "${#unique[@]}" -gt 1 ]; then
  log "multiple repo candidates detected; refusing to guess"
  for u in "${unique[@]}"; do log "  - $u"; done
  exit 14
fi

repo_url="${unique[0]}"
ssh_url=$(printf '%s\n' "$repo_url" | sed -E 's#^https://github.com/(.+)$#git@github.com:\1.git#')

branch=""
if [ -f "$SESSION_YAML" ]; then
  branch_raw=$(extract_yaml_scalar branch)
  case "$branch_raw" in null|"~"|"") branch="" ;; *) branch="$branch_raw" ;; esac
fi

# --- Clone + checkout --------------------------------------------------------
log "cloning $ssh_url into $PWD"
git clone "$ssh_url" .

if [ -n "$branch" ]; then
  log "checking out branch '$branch'"
  git fetch origin --quiet || true
  if git rev-parse --verify "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    git checkout -B "$branch" "origin/$branch"
  elif git rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
    git checkout "$branch"
  else
    git checkout -b "$branch"
  fi
fi

log "ready: $repo_url @ $(git rev-parse --short HEAD)"
