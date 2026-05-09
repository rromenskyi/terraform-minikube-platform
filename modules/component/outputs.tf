# This module currently exposes no outputs — a `kind: deployment` component
# is a leaf in the dependency graph (consumers route to it via Service DNS,
# not via cross-module references). Leaving this file as a placeholder per
# AGENT.md module conventions; add outputs here if a future feature needs
# to surface the rendered Service name / namespace / port to the caller.
