#!/usr/bin/env bash
# Smoke test for scripts/check-stalled-pairs.sh.
#
# How to run, from the Nimbus repo root:
#
#     ./scripts/tests/check-stalled-pairs.sh
#
# Exits 0 on success, non-zero on failure. No framework.
#
# Covers both detection modes:
#   1. Pair stall: pair sitting in awaiting-review past the threshold
#      fires once, and a second sweep with no progress does not re-fire
#      (rate limit via updated_at).
#   2. Silent death: solo agent (lightweight / critic / solo worker)
#      whose tmux window has vanished while state=running fires once
#      per spawn. Paired workers in pair_mode=paired do NOT trip the
#      dead check — their window legitimately exits after handoff.

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

state_dir="$tmp_dir/state"
mkdir -p "$state_dir"

# Fake wake-auditor.sh stub that records its argv into a file.
log_file="$tmp_dir/wake-log"
stub="$tmp_dir/wake-stub.sh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$WAKE_LOG"
STUB
chmod +x "$stub"

# python3 helper for ISO-8601 timestamps in UTC.
ts_minutes_ago() {
    python3 -c "
import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=$1))
      .strftime('%Y-%m-%dT%H:%M:%SZ'))
"
}

old_ts=$(ts_minutes_ago 30)
fresh_ts=$(ts_minutes_ago 1)

# --- Fixtures ---------------------------------------------------------

# (1) Stalled paired worker — should trigger `stalled`.
cat > "$state_dir/test-stall.state" <<EOF
slug=test-stall
role=worker
state=running
spawned_at=$old_ts
updated_at=$old_ts
worktree_path=/tmp/fake-test-stall
branch=feature/test-stall
session_id=fake-session
effort=medium
pair_mode=paired
pair_state=awaiting-review
review_rounds=0
review_cap=6
summary=
blocked_reason=
EOF

# (2) Dead lightweight — running with no live -light window.
cat > "$state_dir/test-dead.state" <<EOF
slug=test-dead
role=lightweight
state=running
spawned_at=$fresh_ts
updated_at=$fresh_ts
worktree_path=/tmp/fake-test-dead
branch=fix/test-dead
session_id=fake-session
effort=medium
model=sonnet
summary=
blocked_reason=
EOF

# (3) Live critic — running and its -crit window IS in the live set.
#     Must NOT fire.
cat > "$state_dir/test-live-crit.state" <<EOF
slug=test-live-crit
role=critic
state=running
spawned_at=$fresh_ts
updated_at=$fresh_ts
worktree_path=/tmp/fake-test-live-crit
session_id=fake-session
effort=high
summary=
blocked_reason=
EOF

# (4) Paired worker NOT in awaiting-* and no window. Must NOT fire as
#     `dead` (paired workers are out of scope for silent-death) and
#     must NOT fire as `stalled` (no awaiting-* pair_state).
cat > "$state_dir/test-paired-norun.state" <<EOF
slug=test-paired-norun
role=worker
state=running
spawned_at=$fresh_ts
updated_at=$fresh_ts
worktree_path=/tmp/fake-test-paired-norun
branch=feature/test-paired-norun
session_id=fake-session
effort=medium
pair_mode=paired
pair_state=running
review_rounds=0
review_cap=6
summary=
blocked_reason=
EOF

# Live-window set: only test-live-crit's window. Everything else is
# considered dead by the tmux probe.
windows=$(printf 'test-live-crit-crit\nsome-other-window\n')

run_sweep() {
    WAKE_LOG="$log_file" \
    NIMBUS_STATE_DIR="$state_dir" \
    NIMBUS_WAKE_AUDITOR="$stub" \
    NIMBUS_TMUX_WINDOWS="$windows" \
        "$repo_root/scripts/check-stalled-pairs.sh"
}

# --- Sweep 1 ----------------------------------------------------------

run_sweep

if [[ ! -s "$log_file" ]]; then
    echo "FAIL: wake-auditor stub was never invoked" >&2
    exit 1
fi

# Sort log for stable comparison — order of invocations within a sweep
# follows glob order and isn't a contract.
got=$(sort "$log_file")
want=$(printf 'test-dead dead\ntest-stall stalled\n' | sort)
if [[ "$got" != "$want" ]]; then
    echo "FAIL: sweep 1 invocations do not match" >&2
    echo "want:" >&2; printf '%s\n' "$want" >&2
    echo "got:" >&2;  printf '%s\n' "$got"  >&2
    exit 1
fi

# --- Sweep 2 (rate limit) --------------------------------------------
# Identical state means neither fixture should re-fire.

run_sweep

invocations=$(wc -l < "$log_file" | tr -d ' ')
if [[ "$invocations" != "2" ]]; then
    echo "FAIL: rate limit broken — expected 2 total invocations, got $invocations" >&2
    cat "$log_file" >&2
    exit 1
fi

# --- Sweep 3 (respawn re-arms the dead check) -------------------------
# Rewrite spawned_at on the dead fixture as if the auditor cancelled and
# respawned it. The dead-pinged dedupe key is spawned_at, so the new
# spawn should trigger another `dead` wake-up.

new_spawn=$(ts_minutes_ago 0)
sed -i.bak "s/^spawned_at=.*/spawned_at=$new_spawn/" "$state_dir/test-dead.state"
rm -f "$state_dir/test-dead.state.bak"

run_sweep

invocations=$(wc -l < "$log_file" | tr -d ' ')
if [[ "$invocations" != "3" ]]; then
    echo "FAIL: respawn should re-fire dead wake-up — expected 3 total invocations, got $invocations" >&2
    cat "$log_file" >&2
    exit 1
fi

last=$(tail -1 "$log_file")
if [[ "$last" != "test-dead dead" ]]; then
    echo "FAIL: respawn should re-fire 'test-dead dead', got '$last'" >&2
    exit 1
fi

echo "ok: check-stalled-pairs.sh detects pair stalls + solo-agent death and rate-limits both"
exit 0
