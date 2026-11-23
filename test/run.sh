#!/usr/bin/env bash
# evener-sched test suite.
#
# Stub-based: every case runs in a fresh temp state dir with stubbed `evener`
# and `curl` on PATH and a temp bare git remote as the wake-entry clone. No
# live service, no network, no real sprite state is touched.
#
#   bash test/run.sh
#
# The whole suite nices itself (shared-machine courtesy).
set -u

if [ -z "${EVENER_SCHED_TEST_NICED:-}" ]; then
  exec nice -n 19 env EVENER_SCHED_TEST_NICED=1 bash "$0" "$@"
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0
FAIL=0
FAILED=""
TLIST=""

cleanup() {
  local d
  for d in $TLIST; do rm -rf "$d"; done
}
trap cleanup EXIT

# Fresh temp world: state dir, stub bin dir, stub log, bare remote + clone.
# Sets T, STATE, STUB (log path). Exports the EVENER_* env the tools read.
setup() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/evener-sched-test.XXXXXX")
  TLIST="$TLIST $T"
  STATE="$T/state"
  STUB="$T/stub.log"
  mkdir -p "$STATE/queue" "$STATE/state" "$STATE/logs" "$T/bin" "$T/run" \
           "$T/home" "$T/home/projects"

  # stub evener: records cwd + argv, exits 0 immediately.
  cat >"$T/bin/evener" <<'EOF'
#!/usr/bin/env bash
printf 'evener cwd=%s args=%s\n' "$PWD" "$*" >>"${EVENER_SCHED_TEST_LOG:?}"
exit 0
EOF
  # stub curl: records "<METHOD> <task>" for task PUT/DELETE calls.
  cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
method= url=
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf 'curl %s %s\n' "${method:-GET}" "${url##*/}" >>"${EVENER_SCHED_TEST_LOG:?}"
exit 0
EOF
  chmod +x "$T/bin/evener" "$T/bin/curl"

  git init --quiet --bare -b main "$T/remote"
  git clone --quiet "$T/remote" "$T/clone" 2>/dev/null
  git -C "$T/clone" config user.name "evener-sched tests"
  git -C "$T/clone" config user.email "evener-sched-tests@example.invalid"
  printf '{"jobs":[]}\n' >"$T/clone/due.json"
  git -C "$T/clone" add due.json
  git -C "$T/clone" commit --quiet -m "test: seed due.json"
  git -C "$T/clone" push --quiet -u origin main

  export EVENER_SCHED_STATE="$STATE"
  export EVENER_SCHED_GH_CLONE="$T/clone"
  export EVENER_SCHED_RUN_DIR="$T/run"
  export EVENER_SPRITE_CONFIG="$T/absent-config"   # no config file by default
  export EVENER_SCHED_TEST_LOG="$STUB"
  export PATH="$T/bin:$PATH"
  # A throwaway HOME keeps the tools' `PATH="$HOME/.local/bin:$PATH"`
  # prepend from shadowing the stubs with real binaries (a real evener in
  # ~/.local/bin would otherwise be launched by the gate).
  export HOME="$T/home"
  unset EVENER_SCHED_WORKDIR EVENER_SCHED_MODEL EVENER_SCHED_PROVIDER_ENV \
        EVENER_SCHED_NICE PROVIDER_ENV DEFAULT_MODEL WORKDIR NICE \
        EVENER_BIN RESUME_BUCKET LEGACY_CUTOFF 2>/dev/null || true
}

# Seed a due job spec (due 60s ago) with its prompt file.
# usage: seed_job <id> [model] [resume_session]
seed_job() {
  local id=$1 model=${2:-} rs=${3:-}
  local due due_iso
  due=$(( $(date +%s) - 60 ))
  due_iso=$(date -u -d "@$due" +%FT%TZ)
  jq -n --arg id "$id" --arg name "n-$id" --argjson due "$due" \
        --arg iso "$due_iso" --arg model "$model" --argjson mr 5 --arg rs "$rs" \
    '{id:$id, name:$name, due_epoch:$due, due_iso:$iso,
      model:(if $model == "" then null else $model end),
      max_rounds:$mr,
      resume_session:(if $rs == "" then null else $rs end),
      created_iso:"2026-01-01T00:00:00Z"}' >"$STATE/queue/$id.json"
  printf 'run the test job\n' >"$STATE/queue/$id.prompt"
}

launches() {
  if [ -f "$STUB" ]; then
    grep -c 'evener cwd=' "$STUB" || true
  else
    echo 0
  fi
}

run_case() {
  local name=$1 out
  out=$(mktemp "${TMPDIR:-/tmp}/evener-sched-case.XXXXXX")
  setup
  if "$name" >"$out" 2>&1; then
    PASS=$((PASS + 1))
    echo "PASS: $name"
  else
    FAIL=$((FAIL + 1))
    FAILED="$FAILED $name"
    echo "FAIL: $name"
    sed 's/^/    /' "$out"
  fi
  rm -f "$out"
}

# --- cases ------------------------------------------------------------------

add_list_rm_roundtrip() {
  local out id
  out=$(bash "$ROOT/bin/sched" add --in "5 minutes" --name rt --max-rounds 5 \
        --prompt "rt prompt") || { echo "sched add failed: $out"; return 1; }
  id=$(printf '%s\n' "$out" | sed -n 's/^scheduled: \([^ ]*\) .*/\1/p')
  [ -n "$id" ] || { echo "no id in add output: $out"; return 1; }
  [ -f "$STATE/queue/$id.json" ] || { echo "queue spec missing"; return 1; }
  [ -f "$STATE/queue/$id.prompt" ] || { echo "prompt file missing"; return 1; }
  jq -e --arg id "$id" '[.jobs[] | select(.id == $id)] | length == 1' \
     "$T/clone/due.json" >/dev/null || { echo "id not in remote due.json"; return 1; }
  out=$(bash "$ROOT/bin/sched" list)
  printf '%s\n' "$out" | grep -F "$id" | grep -F "queued" | grep -qF "no" \
    || { echo "list does not show $id queued fired=no:"; printf '%s\n' "$out"; return 1; }
  out=$(bash "$ROOT/bin/sched" rm "$id") || { echo "sched rm failed: $out"; return 1; }
  [ ! -f "$STATE/queue/$id.json" ] || { echo "queue entry survives rm"; return 1; }
  jq -e --arg id "$id" '[.jobs[] | select(.id == $id)] | length == 0' \
     "$T/clone/due.json" >/dev/null || { echo "id survives rm in remote due.json"; return 1; }
}

gate_launches_due_job_once() {
  seed_job j-once
  bash "$ROOT/gate/gate.sh" --once || { echo "first gate run failed"; return 1; }
  bash "$ROOT/gate/gate.sh" --once || { echo "second gate run failed"; return 1; }
  [ "$(launches)" = "1" ] \
    || { echo "expected exactly 1 launch, got $(launches)"; return 1; }
  [ -f "$STATE/state/j-once.started" ] || { echo "no .started marker"; return 1; }
}

gate_missing_prompt_fails() {
  seed_job j-noprompt
  rm "$STATE/queue/j-noprompt.prompt"
  bash "$ROOT/gate/gate.sh" --once || { echo "gate run failed"; return 1; }
  [ -f "$STATE/state/j-noprompt.failed" ] || { echo "no .failed marker"; return 1; }
  [ "$(launches)" = "0" ] || { echo "launched despite missing prompt"; return 1; }
}

steering_waits_on_live_daemon() {
  seed_job j-steer "" "test-sid-1001"
  printf '{"pid":%s,"session_id":"test-sid-1001"}\n' "$$" >"$T/run/info.json"
  bash "$ROOT/gate/gate.sh" --once || { echo "gate run 1 failed"; return 1; }
  [ -f "$STATE/state/j-steer.waiting" ] || { echo "no .waiting marker"; return 1; }
  [ "$(launches)" = "0" ] || { echo "launched while daemon live"; return 1; }
  printf '{"pid":4000000,"session_id":"test-sid-1001"}\n' >"$T/run/info.json"
  bash "$ROOT/gate/gate.sh" --once || { echo "gate run 2 failed"; return 1; }
  grep -qF -- '--resume-with test-sid-1001' "$STUB" \
    || { echo "no --resume-with launch after daemon death"; return 1; }
  [ ! -f "$STATE/state/j-steer.waiting" ] || { echo ".waiting not cleared"; return 1; }
}

config_precedence() {
  local sub
  for sub in a b c; do
    setup
    mkdir -p "$T/wd-a" "$T/wd-b"
    case $sub in
      a)
        printf 'WORKDIR=%s\n' "$T/wd-a" >"$T/config"
        export EVENER_SPRITE_CONFIG="$T/config"
        seed_job j-cfg-a
        ;;
      b)
        printf 'WORKDIR=%s\n' "$T/wd-a" >"$T/config"
        export EVENER_SPRITE_CONFIG="$T/config"
        export EVENER_SCHED_WORKDIR="$T/wd-b"
        seed_job j-cfg-b
        ;;
      c)
        export EVENER_SPRITE_CONFIG=/nonexistent
        seed_job j-cfg-c
        ;;
    esac
    bash "$ROOT/gate/gate.sh" --once || { echo "gate run ($sub) failed"; return 1; }
    case $sub in
      a) grep -qF "cwd=$T/wd-a" "$STUB" || { echo "config WORKDIR not honored"; return 1; } ;;
      b) grep -qF "cwd=$T/wd-b" "$STUB" || { echo "per-tool env var did not beat config"; return 1; } ;;
      c) grep -qF "cwd=$HOME" "$STUB" || { echo "neutral default (HOME) not used"; return 1; } ;;
    esac
  done
}

no_hardcoded_url_or_author() {
  # Needles are concatenated so this file itself carries no machine-identity
  # strings (they are checked for, never spelled out).
  local machine wake_host author_host
  machine="gray""goo"
  wake_host="sprites"".app"
  author_host="$machine"".local"
  if grep -n -e "$machine" -e "$wake_host" -e "$author_host" \
      "$ROOT/bin/sched" "$ROOT/gate/gate.sh"; then
    echo "machine-specific strings found in bin/sched or gate/gate.sh"
    return 1
  fi
}

provider_env_unset_warns() {
  seed_job j-penv
  bash "$ROOT/gate/gate.sh" --once || { echo "gate run failed"; return 1; }
  [ "$(launches)" -ge 1 ] || { echo "launch did not happen with PROVIDER_ENV unset"; return 1; }
  grep -q "PROVIDER_ENV" "$STATE/gate.log" \
    || { echo "no PROVIDER_ENV warn line in gate.log"; return 1; }
  grep -qi "warn" "$STATE/gate.log" \
    || { echo "gate.log line is not marked as a warning"; return 1; }
}

gh_sync_failure_keeps_local_queue() {
  mkdir -p "$T/not-a-repo"
  export EVENER_SCHED_GH_CLONE="$T/not-a-repo"
  local out
  out=$(bash "$ROOT/bin/sched" add --in "5 minutes" --name local-only \
        --max-rounds 5 --prompt "stay local") \
    || { echo "sched add failed outright: $out"; return 1; }
  printf '%s\n' "$out" | grep -qF "LOCALLY ONLY" \
    || { echo "no LOCALLY ONLY notice in output: $out"; return 1; }
  ls "$STATE/queue"/*.json >/dev/null 2>&1 \
    || { echo "local queue entry missing after failed sync"; return 1; }
}

# --- run --------------------------------------------------------------------

cd "$ROOT"
for c in add_list_rm_roundtrip gate_launches_due_job_once \
         gate_missing_prompt_fails steering_waits_on_live_daemon \
         config_precedence no_hardcoded_url_or_author \
         provider_env_unset_warns gh_sync_failure_keeps_local_queue; do
  run_case "$c"
done

echo "evener-sched tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || { echo "failed:$FAILED"; exit 1; }
