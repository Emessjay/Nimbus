#!/usr/bin/env bash
# Smoke test for scripts/check-stalled-pairs.sh.
#
# How to run, from the Nimbus repo root:
#
#     ./scripts/tests/check-stalled-pairs.sh
#
# Exits 0 on success, non-zero on failure. No framework.
#
# Strategy: build a temporary state dir with one fake pair whose
# updated_at is 30 minutes ago, stub out wake-auditor.sh so we don't
# need a real tmux session, run check-stalled-pairs.sh with the
# state-dir + wake-auditor env overrides, and assert the stub was
# invoked with the expected args.

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

# Synthesize a stalled pair: updated_at 30 minutes in the past.
# Use python3 (already a dependency of the notify hook) for a portable
# "now minus 30min" in UTC ISO format.
old_ts=$(python3 -c '
import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=30))
      .strftime("%Y-%m-%dT%H:%M:%SZ"))
')

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

WAKE_LOG="$log_file" \
NIMBUS_STATE_DIR="$state_dir" \
NIMBUS_WAKE_AUDITOR="$stub" \
    "$repo_root/scripts/check-stalled-pairs.sh"

if [[ ! -s "$log_file" ]]; then
    echo "FAIL: wake-auditor stub was never invoked" >&2
    exit 1
fi

got=$(cat "$log_file")
want="test-stall stalled"
if [[ "$got" != "$want" ]]; then
    echo "FAIL: expected stub args '$want', got '$got'" >&2
    exit 1
fi

# Second run with the same state file must NOT re-invoke the stub
# (rate-limit: same updated_at already pinged).
WAKE_LOG="$log_file" \
NIMBUS_STATE_DIR="$state_dir" \
NIMBUS_WAKE_AUDITOR="$stub" \
    "$repo_root/scripts/check-stalled-pairs.sh"

invocations=$(wc -l < "$log_file" | tr -d ' ')
if [[ "$invocations" != "1" ]]; then
    echo "FAIL: stub was invoked $invocations times; expected exactly 1 (rate limit broken)" >&2
    exit 1
fi

echo "ok: check-stalled-pairs.sh fires on stalled pair and rate-limits repeats"
exit 0
