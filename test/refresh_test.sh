#!/usr/bin/env bash
# Isolated refresh-hook tests: fake herdr and compute, no running server needed.
set -eu
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/lib"
cp "$here/../bin/refresh.sh" "$tmp/bin/refresh.sh"
export TEST_CALLS="$tmp/calls" TEST_CWDS="$tmp/cwds"
export HERDR_BIN_PATH="$tmp/herdr"
cat >"$tmp/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_CALLS"
if [ "$1 $2" = 'api snapshot' ]; then
  printf '%s\n' '{"result":{"snapshot":{"workspaces":[{"workspace_id":"ws-a"},{"workspace_id":"ws-b"}],"panes":[{"workspace_id":"ws-a","focused":true,"cwd":"/repo/a"},{"workspace_id":"ws-b","cwd":"/repo/b"}]}}}'
fi
EOF
cat >"$tmp/lib/compute.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$TEST_CWDS"
[ "$1" != '/not-jj' ] || exit 3
printf 'main\t*1\n'
EOF
chmod +x "$tmp/herdr"
export HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"ws-agent","workspace_cwd":"/repo/focused","focused_pane_cwd":"/repo/agent"}'

run() {
  : >"$TEST_CALLS"
  : >"$TEST_CWDS"
  bash "$tmp/bin/refresh.sh"
}
check() {
  if [ "$2" != "$3" ]; then
    printf 'FAIL %s\nexpected: [%s]\nactual:   [%s]\n' "$1" "$2" "$3"
    exit 1
  fi
  printf 'ok   %s\n' "$1"
}

export HERDR_PLUGIN_EVENT=pane.agent_status_changed
run
check 'agent transition refreshes only its workspace' \
  'workspace report-metadata ws-agent --source mroth.jj-status --token jj_bookmark=main --token jj_status=*1' "$(cat "$TEST_CALLS")"
check 'agent transition prefers triggering pane cwd' '/repo/agent' "$(cat "$TEST_CWDS")"

export HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"ws-agent","workspace_cwd":"/repo/fallback"}'
run
check 'agent transition falls back to workspace cwd' '/repo/fallback' "$(cat "$TEST_CWDS")"

export HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"ws-agent","workspace_cwd":"/repo/focused","focused_pane_cwd":"/not-jj"}'
run
check 'leaving jj clears stale tokens' \
  'workspace report-metadata ws-agent --source mroth.jj-status --clear-token jj_bookmark --clear-token jj_status' "$(cat "$TEST_CALLS")"

export HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"ws-agent","workspace_cwd":"/repo/focused","focused_pane_cwd":"/repo/agent"}'
for event in workspace.focused workspace.updated worktree.opened; do
  export HERDR_PLUGIN_EVENT="$event"
  run
  check "$event retains workspace cwd preference" '/repo/focused' "$(cat "$TEST_CWDS")"
done

for event in startup ''; do
  export HERDR_PLUGIN_EVENT="$event"
  run
  check "startup/action sweeps despite focused context ($event)" \
    $'/repo/a\n/repo/b' "$(cat "$TEST_CWDS")"
done

export HERDR_PLUGIN_EVENT=pane.agent_status_changed
export HERDR_PLUGIN_CONTEXT_JSON='{}'
run
check 'missing event workspace falls back to sweep' $'/repo/a\n/repo/b' "$(cat "$TEST_CWDS")"
printf '\nAll refresh tests passed.\n'
