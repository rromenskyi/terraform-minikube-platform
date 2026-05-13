#!/bin/sh
# Collect every active VulnerabilityReport CRD across the configured
# allowlist of namespaces, format the HIGH + CRITICAL findings into a
# single markdown table, write to /work/cve-report.md.
#
# Reads $TARGET_NAMESPACES (space-separated). Iterates each, queries
# vulnerabilityreports.aquasecurity.github.io, aggregates per image
# repository:tag → counts of HIGH + CRITICAL → list of CVE IDs.
#
# Output shape: stable across runs given identical inputs (sort -u),
# so `git diff` against the committed report is a clean signal.

set -eu

OUT=/work/cve-report.md
TMP=/work/raw.json

: > "$TMP"

for NS in $TARGET_NAMESPACES; do
  # `--ignore-not-found` keeps the loop tolerant of namespaces the
  # operator hasn't enabled yet (e.g. `arc-buildkitd` if BuildKit
  # isn't installed). Empty result silently moves on.
  kubectl get vulnerabilityreports.aquasecurity.github.io -n "$NS" \
    -o json --ignore-not-found 2>/dev/null \
    | jq -c '.items[]?' >> "$TMP" || true
done

{
  printf '# Platform CVE report\n\n'
  printf 'Generated: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Source: trivy-operator VulnerabilityReport CRDs across\n'
  printf 'platform-system namespaces. Severity floor HIGH + CRITICAL.\n\n'

  # Build "image | crit | high | cves" table. jq does the heavy
  # lifting: for each report, extract image ref + severity counts +
  # collapse CVE IDs into a comma-joined string. sort -u then dedups
  # rows where two namespaces share the same image (e.g. shared
  # base layer).
  printf '| Image | CRITICAL | HIGH | CVE IDs |\n'
  printf '|---|---:|---:|---|\n'

  jq -r '
    . as $r
    | .report.artifact.repository as $repo
    | .report.artifact.tag        as $tag
    | (.report.summary.criticalCount // 0) as $crit
    | (.report.summary.highCount // 0)     as $high
    | (
        [.report.vulnerabilities[]?
          | select(.severity == "CRITICAL" or .severity == "HIGH")
          | .vulnerabilityID
        ]
        | unique | sort | join(", ")
      ) as $cves
    | "| \($repo):\($tag) | \($crit) | \($high) | \($cves) |"
  ' "$TMP" \
    | sort -u

  printf '\n'
  printf '_End of report._\n'
} > "$OUT"

echo "Wrote $OUT"
wc -l "$OUT"
