#!/usr/bin/env bash
#
# Tiered test driver for the external/wifi-csi-pose submodule.
#
# Lives in the parent repo because the submodule is upstream-owned (euaziel) and we
# have no push access to it -- it must stay byte-identical to its pinned commit.
#
#   ./scripts/test-submodule.sh [tier0|tier1a|tier1b|matrix|tier3|all]
#
# Tiers are independent; each prints one "TIER n: PASS|FAIL|SKIP" line. Nothing is
# installed implicitly -- a tier that needs a missing toolchain SKIPs and tells you
# the exact command to run.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUB="$REPO_ROOT/external/wifi-csi-pose"
VENVS="$REPO_ROOT/.venvs"
LOGS="$REPO_ROOT/logs"
UV="$HOME/.local/bin/uv"

EXPECTED_HASH="8c0680d7d285739ea9597715e84959d9c356c87ee3ad35b5f1e69a4ca41151c6"

RESULTS=()
FAILED=0

# --- output helpers -----------------------------------------------------------
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'
else B=""; G=""; R=""; Y=""; N=""; fi

hdr()  { printf '\n%s=== %s ===%s\n' "$B" "$*" "$N"; }
step() { printf '\n%s--- %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %sok%s   %s\n' "$G" "$N" "$*"; }
bad()  { printf '  %sFAIL%s %s\n' "$R" "$N" "$*"; }
note() { printf '  %s\n' "$*"; }

record() { # record <tier> <PASS|FAIL|SKIP> [detail]
  RESULTS+=("$1|$2|${3:-}")
  [ "$2" = "FAIL" ] && FAILED=1
  return 0
}

# --- guards -------------------------------------------------------------------

# The submodule tree must be pristine before AND after. Before: we never want to
# test a mutated checkout. After: catches any tier that unexpectedly wrote to a
# tracked file.
assert_submodule_clean() {
  local when="$1" dirty
  dirty="$(git -C "$SUB" status --porcelain)"
  if [ -n "$dirty" ]; then
    bad "submodule working tree is dirty ($when):"
    printf '%s\n' "$dirty" | sed 's/^/       /'
    printf '\n  The submodule must stay byte-identical to its pinned commit.\n'
    printf '  Restore with: git -C %s checkout -- . && git -C %s clean -fd\n' "$SUB" "$SUB"
    exit 1
  fi
  ok "submodule tree clean ($when)"
}

# ./verify --generate-hash OVERWRITES the tracked v1/data/proof/expected_features.sha256.
# It rewrites the very oracle we are testing against, silently turning a red result
# green. There is no legitimate reason to invoke it from this script.
reject_generate_hash() {
  for a in "$@"; do
    case "$a" in
      --generate-hash|*generate-hash*)
        bad "refusing --generate-hash: it overwrites the tracked expected_features.sha256"
        note "That flag rewrites the oracle and converts a failing proof into a passing one."
        exit 1 ;;
    esac
  done
}

# =============================================================================
# TIER 0 -- zero-install integrity. Runs on whatever python3 exists. No network.
# =============================================================================
tier0() {
  hdr "TIER 0  integrity checks (no installs, no network)"
  local fails=0

  step "0.1 submodule + git integrity"
  git -C "$REPO_ROOT" submodule status
  note "HEAD: $(git -C "$SUB" rev-parse HEAD)"
  if git -C "$SUB" fsck --no-dangling --no-progress 2>&1 | grep -q .; then
    bad "git fsck reported problems"; fails=$((fails+1))
  else
    ok "git fsck clean"
  fi

  step "0.2 proof-input baseline digests"
  ( cd "$SUB" && shasum -a 256 \
      v1/data/proof/sample_csi_data.json \
      v1/data/proof/verify.py \
      v1/data/proof/expected_features.sha256 \
      v1/src/core/csi_processor.py \
      v1/src/hardware/csi_extractor.py ) | sed 's/^/  /'
  note "(baseline: if these are stable, any Tier 1 hash mismatch is a library/platform"
  note " difference, not repo tampering)"

  step "0.3 proof metadata assertions (mirrors .github/workflows/verify-pipeline.yml)"
  if ( cd "$SUB" && python3 -c "
import json
m = json.load(open('v1/data/proof/sample_csi_meta.json'))
assert m['is_synthetic'] is True,  'meta.is_synthetic is not True'
assert m['numpy_seed'] == 42,      'meta.numpy_seed is not 42'
d = json.load(open('v1/data/proof/sample_csi_data.json'))
print('  frames=%d subcarriers=%d antennas=%d seed=%s'
      % (len(d['frames']), d['num_subcarriers'], d['num_antennas'], d.get('numpy_seed')))
" ); then ok "metadata assertions pass"
  else bad "metadata assertions failed"; fails=$((fails+1)); fi

  step "0.4 syntax check (ast.parse -- writes no __pycache__)"
  if ( cd "$SUB" && find v1/src v1/data/proof scripts -name '*.py' -print0 \
        | xargs -0 python3 -c '
import ast, sys
bad = 0
for f in sys.argv[1:]:
    try:
        ast.parse(open(f, encoding="utf-8").read(), f)
    except SyntaxError as e:
        bad += 1
        print("  SYNTAX %s:%s %s" % (f, e.lineno, e.msg))
print("  checked %d files, %d syntax errors" % (len(sys.argv) - 1, bad))
sys.exit(1 if bad else 0)
' ); then ok "no syntax errors under $(python3 -V 2>&1)"
  else bad "syntax errors found"; fails=$((fails+1)); fi

  for s in verify install.sh deploy.sh ui/start-ui.sh scripts/generate-witness-bundle.sh; do
    if bash -n "$SUB/$s" 2>/dev/null; then ok "bash -n $s"
    else bad "bash -n $s"; fails=$((fails+1)); fi
  done

  step "0.5 prerequisite gate fires correctly"
  # Upstream commits every .sh and `verify` as mode 100644, so `./verify` (and
  # `make verify`, which calls @./verify) fail with "Permission denied" on a fresh
  # clone. chmod would dirty the submodule, so invoke through bash instead.
  local gate_out gate_rc=0
  gate_out="$( cd "$SUB" && bash verify 2>&1 )" || gate_rc=$?
  if [ "$gate_rc" -eq 1 ] && printf '%s' "$gate_out" | grep -q "Cannot proceed"; then
    ok "gate refuses to run without numpy/scipy (exit 1) -- expected on a bare host"
  elif [ "$gate_rc" -eq 0 ]; then
    ok "prerequisites already satisfied; ./verify ran (see Tier 1)"
  else
    note "unexpected: exit=$gate_rc"
    printf '%s\n' "$gate_out" | tail -5 | sed 's/^/       /'
  fi

  step "0.6 mock-pattern scan (static replay of ./verify phase 3)"
  local hits
  hits="$( cd "$SUB" && find v1/src -name '*.py' ! -path '*/testing/*' ! -path '*__pycache__*' \
            -exec grep -Hn 'np\.random\.rand\b\|np\.random\.randn\b' {} \; || true )"
  if [ -z "$hits" ]; then ok "CLEAN -- no unseeded RNG in production modules"
  else bad "mock/random patterns in production code:"; printf '%s\n' "$hits" | sed 's/^/       /'
       fails=$((fails+1)); fi

  step "0.7 host toolchain detection"
  ( cd "$SUB" && bash install.sh --check-only 2>&1 | tail -25 | sed 's/^/  /' ) || true

  if [ "$fails" -eq 0 ]; then record "0" PASS "integrity"; else record "0" FAIL "$fails check(s)"; fi
}

# =============================================================================
# TIER 1a -- cheap proof probe on the system Python 3.9 + scipy 1.13.1.
#
# The pipeline touches scipy in exactly two places (signal.windows.hamming and
# fft.fft), both byte-stable across 1.13/1.14, so this is very likely to
# reproduce the locked hash without installing a new interpreter.
# =============================================================================
tier1a() {
  hdr "TIER 1a  proof probe (system python3 + scipy 1.13.1)"
  local venv="$VENVS/proof39"

  if [ ! -x "$venv/bin/python" ]; then
    step "creating $venv"
    mkdir -p "$VENVS"
    /usr/bin/python3 -m venv "$venv"
    "$venv/bin/python" -m pip install -q --upgrade pip
    "$venv/bin/pip" install -q numpy==1.26.4 scipy==1.13.1
  fi
  note "$("$venv/bin/python" -c 'import numpy,scipy,sys;print("python %s | numpy %s | scipy %s"%(sys.version.split()[0],numpy.__version__,scipy.__version__))')"

  run_proof "$venv" "1a" "scipy 1.13.1 (locked file says 1.14.1)"
}

# =============================================================================
# TIER 1b -- authoritative proof on the exact locked stack via uv-managed 3.12.
# =============================================================================
tier1b() {
  hdr "TIER 1b  authoritative proof (python 3.12 + exact locked deps)"
  local venv="$VENVS/proof312"

  if [ ! -x "$UV" ]; then
    printf '  %sSKIP%s uv not installed. To enable this tier:\n' "$Y" "$N"
    note "  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh"
    record "1b" SKIP "uv not installed"
    return 0
  fi

  if [ ! -x "$venv/bin/python" ]; then
    step "creating $venv with python 3.12"
    "$UV" python install 3.12
    "$UV" venv --python 3.12 "$venv"
    ( cd "$SUB" && VIRTUAL_ENV="$venv" "$UV" pip install -r v1/requirements-lock.txt )
  fi
  note "$("$venv/bin/python" -c 'import numpy,scipy,sys;print("python %s | numpy %s | scipy %s"%(sys.version.split()[0],numpy.__version__,scipy.__version__))')"

  run_proof "$venv" "1b" "exact locked stack"

  step "determinism -- second run must produce an identical hash"
  local h1 h2
  # `|| true`: verify.py exits 1 on a hash mismatch, which would trip set -e/pipefail
  # here. We only care whether the two runs agree with each other.
  h1="$( cd "$SUB/v1" && "$venv/bin/python" data/proof/verify.py 2>/dev/null | grep -i 'computed' | head -1 || true )"
  h2="$( cd "$SUB/v1" && "$venv/bin/python" data/proof/verify.py 2>/dev/null | grep -i 'computed' | head -1 || true )"
  if [ -n "$h1" ] && [ "$h1" = "$h2" ]; then ok "deterministic across runs"
  else bad "non-deterministic: '$h1' vs '$h2'"; fi
}

# =============================================================================
# TIER 1m -- dependency matrix.
#
# The proof hashes raw little-endian float64 bytes with no rounding (verify.py
# L191-193), so the digest is sensitive to the last ULP. This runs the pipeline
# across several dependency stacks on THIS machine and tabulates the hashes,
# which isolates "library version" from "platform" as the cause of a mismatch.
# =============================================================================
tier1matrix() {
  hdr "TIER 1m  dependency matrix"

  if [ ! -x "$UV" ]; then
    printf '  %sSKIP%s uv not installed.\n' "$Y" "$N"
    record "1m" SKIP "uv not installed"
    return 0
  fi

  # label | python | numpy | scipy   (the doc stack is what ADR-028 says the
  # published hash was regenerated with; the lock stack is what CI installs)
  local specs=(
    "lock-3.12|3.12|1.26.4|1.14.1"
    "doc-3.12|3.12|2.4.2|1.17.1"
  )

  printf '\n  %-12s %-8s %-9s %-9s %s\n' STACK PYTHON NUMPY SCIPY "PIPELINE HASH"
  printf '  %s\n' "------------------------------------------------------------------------------"

  local spec label py np_v sp_v venv h
  for spec in "${specs[@]}"; do
    IFS='|' read -r label py np_v sp_v <<< "$spec"
    venv="$VENVS/mx-$label"
    if [ ! -x "$venv/bin/python" ]; then
      "$UV" venv --python "$py" "$venv" >/dev/null 2>&1
      VIRTUAL_ENV="$venv" "$UV" pip install -q "numpy==$np_v" "scipy==$sp_v" >/dev/null 2>&1
    fi
    h="$( cd "$SUB/v1" && "$venv/bin/python" data/proof/verify.py 2>/dev/null \
          | grep -iE '^\s*Computed:' | head -1 | awk '{print $2}' || true )"
    printf '  %-12s %-8s %-9s %-9s %s\n' "$label" "$py" "$np_v" "$sp_v" "${h:-<no output>}"
  done

  # The 3.9 probe, if Tier 1a already built it
  if [ -x "$VENVS/proof39/bin/python" ]; then
    h="$( cd "$SUB/v1" && "$VENVS/proof39/bin/python" data/proof/verify.py 2>/dev/null \
          | grep -iE '^\s*Computed:' | head -1 | awk '{print $2}' || true )"
    printf '  %-12s %-8s %-9s %-9s %s\n' "probe-3.9" "3.9" "1.26.4" "1.13.1" "${h:-<no output>}"
  fi

  printf '  %s\n' "------------------------------------------------------------------------------"
  printf '  %-12s %-8s %-9s %-9s %s\n' "PUBLISHED" "-" "2.4.2*" "1.17.1*" "$EXPECTED_HASH"
  printf '\n  * per docs/adr/ADR-028 L240 and docs/WITNESS-LOG-028.md L223, which state the\n'
  printf '    published hash was regenerated with numpy 2.4.2 + scipy 1.17.1 -- NOT the\n'
  printf '    numpy 1.26.4 + scipy 1.14.1 pinned in v1/requirements-lock.txt (what CI installs).\n'

  record "1m" INFO "hash matrix tabulated"
}

# =============================================================================
# TIER 3 -- the Rust workspace (~1,037 tests across 15 crates).
#
# Runs in a COPY of rust-port/wifi-densepose-rs (3 MB) because the committed
# Cargo.lock is stale: `cargo --locked` refuses it, and letting cargo refresh
# the lock in place would dirty the submodule. Only version pins differ; the
# package set is identical.
#
# --no-default-features is required -- defaults pull tch (libtorch) and ort
# (ONNX Runtime), which need native libraries we do not have.
# =============================================================================
tier3() {
  hdr "TIER 3  Rust workspace"

  local CARGO="$HOME/.cargo/bin/cargo"
  if [ ! -x "$CARGO" ]; then
    printf '  %sSKIP%s Rust not installed. To enable this tier:\n' "$Y" "$N"
    note "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \\"
    note "    | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path"
    record "3" SKIP "cargo not installed"
    return 0
  fi

  local work="$REPO_ROOT/.rustwork"
  local ws="$work/wifi-densepose-rs"
  step "syncing workspace copy -> $ws"
  rm -rf "$work"; mkdir -p "$work"
  cp -R "$SUB/rust-port/wifi-densepose-rs" "$work/"

  export CARGO_TARGET_DIR="$REPO_ROOT/.cargo-target"
  local log="$LOGS/rust-tests.log"

  step "cargo test --workspace --no-default-features   (first run: ~15 min)"
  local rc=0
  ( cd "$ws" && "$CARGO" test --workspace --no-default-features ) >"$log" 2>&1 || rc=$?

  local passed failed ignored bins
  read -r passed failed ignored bins <<< "$(
    grep '^test result:' "$log" \
      | awk '{p+=$4; f+=$6; i+=$8} END {print p+0, f+0, i+0, NR+0}'
  )"
  note "passed=$passed  failed=$failed  ignored=$ignored  across $bins test binaries"

  if [ "$rc" -eq 0 ] && [ "${failed:-1}" -eq 0 ] && [ "${passed:-0}" -gt 0 ]; then
    ok "cargo test exited 0 with 0 failures"
    record "3" PASS "$passed passed, 0 failed"
  else
    bad "cargo test failed (exit=$rc)"
    grep -E '^failures:|^error\[E|error: could not compile' "$log" | head -10 | sed 's/^/       /'
    record "3" FAIL "exit=$rc, $failed failed"
  fi
  note "full log: $log"
}

# Shared proof runner: prepend the venv to PATH (./verify resolves python3 off PATH)
# and check the verdict, the hash, and the exit code.
run_proof() { # run_proof <venv> <tier-label> <caveat>
  local venv="$1" label="$2" caveat="$3" out rc=0
  step "verify --verbose --audit"
  # `bash verify`, not `./verify` -- upstream ships it non-executable (mode 100644).
  # ./verify resolves python3 off PATH, so prepending the venv is all that's needed.
  out="$( cd "$SUB" && PATH="$venv/bin:$PATH" bash verify --verbose --audit 2>&1 )" || rc=$?

  printf '%s\n' "$out" | grep -E 'VERDICT|Pipeline hash|Computed|Expected|Status:|Mock scan|CODEBASE AUDIT|Spectral entropy|SOURCE PROVENANCE' \
    | sed 's/^/  /' || true

  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "VERDICT: PASS"; then
    if printf '%s' "$out" | grep -q "$EXPECTED_HASH"; then
      ok "VERDICT: PASS, hash matches ${EXPECTED_HASH:0:8}..."
      record "$label" PASS "${caveat}"
    else
      bad "PASS reported but expected hash not present in output"
      record "$label" FAIL "hash not found"
    fi
  else
    bad "proof did not pass (exit=$rc)"
    printf '%s\n' "$out" | tail -20 | sed 's/^/       /'
    record "$label" FAIL "exit=$rc"
  fi
}

# --- main ---------------------------------------------------------------------
reject_generate_hash "$@"

TARGET="${1:-tier0}"
mkdir -p "$LOGS"
LOG="$LOGS/${TARGET}-$(date +%Y%m%dT%H%M%S).log"

{
  printf '%s\n' "submodule: $(git -C "$SUB" rev-parse HEAD)"
  assert_submodule_clean "before"

  case "$TARGET" in
    tier0)   tier0 ;;
    tier1a)  tier1a ;;
    tier1b)  tier1b ;;
    matrix)  tier1matrix ;;
    tier3)   tier3 ;;
    all)     tier0; tier1a; tier1b; tier1matrix; tier3 ;;
    *) printf 'usage: %s [tier0|tier1a|tier1b|matrix|tier3|all]\n' "$0" >&2; exit 2 ;;
  esac

  hdr "SUMMARY"
  # bash 3.2 (macOS default) errors on ${arr[@]} when empty under `set -u`
  for r in ${RESULTS[@]+"${RESULTS[@]}"}; do
    IFS='|' read -r t s d <<< "$r"
    case "$s" in
      PASS) c="$G" ;; FAIL) c="$R" ;; *) c="$Y" ;;
    esac
    printf '  TIER %-3s %s%s%s  %s\n' "$t" "$c" "$s" "$N" "$d"
  done

  assert_submodule_clean "after"
  printf '\nlog: %s\n' "$LOG"

  # Must exit from INSIDE the block: `| tee` runs it in a subshell, so $FAILED
  # is invisible to the parent. pipefail then propagates this as the script's
  # exit status.
  exit "$FAILED"
} 2>&1 | tee "$LOG"
