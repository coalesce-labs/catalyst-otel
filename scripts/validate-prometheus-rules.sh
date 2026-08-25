#!/usr/bin/env bash
# OTL-89: guards against the #182 crashloop class -- a promtool *test* file
# (rule_files/evaluation_interval/tests keys) sitting in the directory that
# prometheus.yml globs for *rule* files (provisioning/prometheus/*.yml,
# non-recursive -- see docker-compose.yml's otel-prometheus mount). Any such
# file is not valid rulefmt, so Prometheus exits on boot the moment it's
# picked up.
#
# Two gates:
#   1. every file directly under the globbed rules dir must pass
#      `promtool check rules` (real rulefmt).
#   2. every promtool test-format file must still pass `promtool test rules`
#      from its new home outside the glob.
# Plus a planted negative control proving gate 1 isn't a silent no-op.
set -euo pipefail

RULES_DIR="provisioning/prometheus"
TESTS_DIR="$RULES_DIR/tests"
FAIL=0

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

if ! command -v promtool >/dev/null 2>&1; then
  echo "FAIL: promtool not installed -- cannot validate Prometheus rules (install via 'brew install prometheus' or the prom/prometheus image)"
  exit 1
fi

# --- gate 1: every file the Docker glob (/etc/prometheus/rules/*.yml) would
# actually load must be a valid rulefmt rules file. ---
shopt -s nullglob
rule_files=("$RULES_DIR"/*.yml)
shopt -u nullglob
if [ "${#rule_files[@]}" -eq 0 ]; then
  fail "no *.yml files found directly under $RULES_DIR -- glob pattern or path is wrong"
fi
for f in "${rule_files[@]}"; do
  if promtool check rules "$f" >/tmp/otl89-promtool-check.$$ 2>&1; then
    pass "$f is a valid rulefmt rules file"
  else
    fail "$f is NOT a valid rulefmt rules file (would crashloop Prometheus on boot -- the #182 incident class):"
    sed 's/^/  /' /tmp/otl89-promtool-check.$$
  fi
  rm -f /tmp/otl89-promtool-check.$$
done

# --- gate 2: promtool unit tests still pass from their new (out-of-glob) home ---
shopt -s nullglob
test_files=("$TESTS_DIR"/*.test.yml)
shopt -u nullglob
if [ "${#test_files[@]}" -eq 0 ]; then
  fail "no *.test.yml files found under $TESTS_DIR -- expected at least recording-rules.test.yml"
fi
for f in "${test_files[@]}"; do
  if promtool test rules "$f" >/tmp/otl89-promtool-test.$$ 2>&1; then
    pass "$f: promtool test rules passed"
  else
    fail "$f: promtool test rules FAILED:"
    sed 's/^/  /' /tmp/otl89-promtool-test.$$
  fi
  rm -f /tmp/otl89-promtool-test.$$
done

# --- planted negative control: prove gate 1 actually rejects a non-rulefmt
# file instead of silently passing everything (the #182 class was exactly a
# green check that never ran against the wrong-location file). Reuses the
# real promtool test file as the negative fixture -- it IS a non-rulefmt
# file by construction (rule_files/evaluation_interval/tests keys), checked
# from a throwaway copy so this never touches the real globbed dir. ---
if [ "${#test_files[@]}" -gt 0 ]; then
  NEGATIVE_CONTROL="${test_files[0]}"
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  cp "$NEGATIVE_CONTROL" "$TMP_DIR/planted-negative-control.yml"
  if promtool check rules "$TMP_DIR/planted-negative-control.yml" >/dev/null 2>&1; then
    fail "NEGATIVE CONTROL DID NOT TRIP: promtool check rules accepted a promtool test-format file as valid rulefmt -- this gate is a no-op and would NOT have caught the #182 incident"
  else
    pass "negative control: gate 1 correctly rejects a planted non-rulefmt file"
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "Prometheus rules validation FAILED — see FAIL lines above"
  exit 1
fi

echo ""
echo "All Prometheus rules checks passed."
