#!/bin/sh
# Commit /work/cve-report.md to the platform repo if it changed since
# the last snapshot. PR is force-pushed onto a stable branch
# (`$BRANCH_PREFIX`) so multiple weekly runs collapse into one PR
# rather than spawning a new one each time.
#
# Reads:
#   $GH_TOKEN       — classic PAT, scope `repo` (full)
#   $GH_REPO        — `owner/repo`
#   $BRANCH_PREFIX  — branch the snapshot lives on
#   $REPORT_PATH    — committed file path inside the repo
#
# Exits 0 silently when:
#   - the repo's current $REPORT_PATH already matches /work/cve-report.md
#   - or the diff is whitespace-only
# (no PR opened, no branch pushed)

set -eu

apk add --no-cache curl jq >/dev/null 2>&1

WORK=/work
REPO_DIR="$WORK/repo"
NEW="$WORK/cve-report.md"
DEST="$REPO_DIR/$REPORT_PATH"

if [ ! -s "$NEW" ]; then
  echo "Collected report is empty — nothing to commit. Skipping."
  exit 0
fi

# Shallow clone of the target branch (if it doesn't exist yet, fall
# back to default branch). Using https + token in URL avoids needing
# a deploy-key file.
git config --global user.email "security-scan-bot@platform"
git config --global user.name  "platform-security-scan"

CLONE_URL="https://x-access-token:${GH_TOKEN}@github.com/${GH_REPO}.git"

if ! git clone --depth 1 --branch "$BRANCH_PREFIX" "$CLONE_URL" "$REPO_DIR" 2>/dev/null; then
  # Branch doesn't exist yet — clone default branch and create the
  # snapshot branch off its tip.
  git clone --depth 1 "$CLONE_URL" "$REPO_DIR"
  cd "$REPO_DIR"
  git checkout -b "$BRANCH_PREFIX"
fi
cd "$REPO_DIR"

mkdir -p "$(dirname "$DEST")"
cp "$NEW" "$DEST"

git add "$REPORT_PATH"

# Did anything actually change?
#   - For an untracked-now-staged file (very first commit on this
#     branch), `git diff --cached` shows the full content and the
#     -I filter is moot — staged add ⇒ commit.
#   - For an existing file, fall back to comparing staged vs HEAD,
#     ignoring the `Generated:` timestamp line so a stale-but-equal
#     snapshot doesn't churn the PR.
if git diff --cached --quiet -I '^Generated: ' -- "$REPORT_PATH" 2>/dev/null \
   && git diff --quiet HEAD -- "$REPORT_PATH" 2>/dev/null; then
  echo "No substantive change to $REPORT_PATH since last snapshot. Exiting silently."
  exit 0
fi
git commit -m "chore(security-scan): weekly CVE snapshot $(date -u +%Y-%m-%d)"
git push -f origin "$BRANCH_PREFIX"

# Open PR via GitHub API. If a PR is already open from $BRANCH_PREFIX
# the API call returns 422; that's expected on subsequent weekly runs
# when the operator hasn't merged yet — branch is force-pushed above,
# the existing PR's "files changed" view auto-refreshes. Suppress the
# 422 so the CronJob doesn't flag as failed.

DEFAULT_BRANCH=$(curl -fsSL \
  -H "Authorization: token $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GH_REPO}" \
  | jq -r '.default_branch')

PR_BODY=$(printf 'Weekly CVE snapshot from trivy-operator across platform-system namespaces.\n\nReview the diff vs the previous snapshot to see new/resolved findings since last week.\n\nSource: `modules/security-scan`.\n')

PR_RESPONSE=$(curl -sS -o /tmp/pr-resp.json -w '%%{http_code}' \
  -X POST \
  -H "Authorization: token $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GH_REPO}/pulls" \
  -d "$(jq -n \
        --arg title "chore(security-scan): weekly CVE snapshot" \
        --arg head  "$BRANCH_PREFIX" \
        --arg base  "$DEFAULT_BRANCH" \
        --arg body  "$PR_BODY" \
        '{title: $title, head: $head, base: $base, body: $body}')")

PR_URL=""
if [ "$PR_RESPONSE" = "201" ]; then
  PR_URL=$(jq -r '.html_url' /tmp/pr-resp.json)
  echo "Opened PR: $PR_URL"
elif [ "$PR_RESPONSE" = "422" ]; then
  # Either PR already open OR the head branch is identical to base.
  # Both fine — branch was force-pushed, existing PR refreshes.
  echo "PR not opened (422 — likely already exists for $BRANCH_PREFIX). Branch was force-pushed."
  # Look up the existing open PR's URL so the Telegram message can
  # link to it.
  PR_URL=$(curl -fsSL \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GH_REPO}/pulls?head=${GH_REPO%%/*}:${BRANCH_PREFIX}&state=open" \
    | jq -r '.[0].html_url // empty')
else
  echo "Unexpected response from GitHub API: HTTP $PR_RESPONSE"
  cat /tmp/pr-resp.json
  exit 1
fi

# Optional Telegram DM — only fires when the engine wired the
# `security-scan-telegram` Secret in (telegram_notify_enabled = true)
# AND the operator populated bot_token + chat_id in Vault. Empty
# either var = silent skip; container exit code unaffected.
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] && [ -n "$PR_URL" ]; then
  ADDED=$(git diff HEAD~1 -- "$REPORT_PATH" 2>/dev/null | grep -c '^+|' || true)
  REMOVED=$(git diff HEAD~1 -- "$REPORT_PATH" 2>/dev/null | grep -c '^-|' || true)
  MSG=$(printf '🛡 *Platform CVE snapshot changed*\n\n%s lines added, %s removed in `%s`.\n\nPR: %s' \
    "$ADDED" "$REMOVED" "$REPORT_PATH" "$PR_URL")
  curl -fsS -o /dev/null \
    -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${MSG}" \
    -d "parse_mode=Markdown" \
    && echo "Telegram notification sent." \
    || echo "Telegram notification failed (non-fatal — report still committed)."
fi
