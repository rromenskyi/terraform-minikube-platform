#!/usr/bin/env bash
# Pre-commit scrub check — guards every committed file against
# operator-private identifiers (tenant slugs, app names, internal
# node names, public IPs the operator owns).
#
# The engine itself stays generic; the operator-private list lives
# OUTSIDE the repo at `config/.scrub-list` (gitignored). This script
# is the engine's framework — it knows HOW to check, the gitignored
# list knows WHAT to flag. Same separation the rest of `config/`
# follows (engine ships `.example` templates, operator's live values
# are gitignored).
#
# Format of `config/.scrub-list`:
#   - one regex per line (extended POSIX)
#   - lines starting with `#` are comments
#   - blank lines ignored
#   - patterns are case-insensitive
#
# Exit:
#   0 — no matches OR scrub-list missing (gitignored, operator opt-in)
#   1 — at least one match found (offending lines printed)
#
# Wiring as a pre-commit hook:
#   ln -s ../../tools/check-scrub.sh .git/hooks/pre-commit
#   # or for `pre-commit` framework, add a `local` repo hook pointing here
#
# Manual invocation (run-as-needed without commit gate):
#   ./tools/check-scrub.sh          # pending change (staged, else working tree)
#   ./tools/check-scrub.sh --all    # every tracked file

set -euo pipefail

SCRUB_LIST="${SCRUB_LIST:-config/.scrub-list}"

if [ ! -f "$SCRUB_LIST" ]; then
  # Operator hasn't opted in yet — silently pass. Print a hint only
  # when run interactively (no STDIN piped from a hook).
  if [ -t 0 ]; then
    echo "scrub: $SCRUB_LIST not found — operator opt-in. See" \
         "config/.scrub-list.example for the format." >&2
  fi
  exit 0
fi

# Build the alternation regex from non-comment / non-blank lines.
PATTERN="$(grep -vE '^\s*(#|$)' "$SCRUB_LIST" | paste -sd '|' -)"

if [ -z "$PATTERN" ]; then
  exit 0
fi

if [ "${1:-}" = "--all" ]; then
  # Full-tree audit: every tracked file, not just the pending change.
  MATCHES="$(git grep -n -I -i -E -e "$PATTERN" -- ':!'"$SCRUB_LIST" || true)"
  if [ -z "$MATCHES" ]; then
    exit 0
  fi
  echo "scrub: operator-private identifiers in tracked files:" >&2
  printf '%s\n' "$MATCHES" >&2
  exit 1
fi

# Staged changes when run as a pre-commit hook; the working-tree diff
# when invoked manually with nothing staged. Every text file counts —
# yaml, scripts and the ./tf wrapper leak as easily as .tf and .md.
DIFF_ARGS="--cached"
if [ -z "$(git diff --cached --name-only)" ]; then
  DIFF_ARGS=""
fi

# `git diff` exits 0 when there are no changes; capture it without
# tripping `set -e` and let the grep determine the final exit.
ADDED_LINES="$(git diff $DIFF_ARGS --text 2>/dev/null \
                | grep -E '^\+' \
                | grep -vE '^\+\+\+' || true)"

if [ -z "$ADDED_LINES" ]; then
  exit 0
fi

MATCHES="$(printf '%s\n' "$ADDED_LINES" | grep -iE -- "$PATTERN" || true)"

if [ -z "$MATCHES" ]; then
  exit 0
fi

cat >&2 <<EOF
scrub: operator-private identifiers detected in staged diff
─────────────────────────────────────────────────────────
The patterns in \`$SCRUB_LIST\` matched lines being committed.
Either scrub them out (use generic placeholders like
\`<tenant>\`, \`<env>\`, \`<key>-<env>\`, \`example.com\`) or
update the scrub list if a pattern is too aggressive.

Offending lines:
EOF
printf '%s\n' "$MATCHES" >&2
exit 1
