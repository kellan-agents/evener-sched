#!/usr/bin/env bash
# evener-sched gate — run as a Sprite service.
#
# The Sprite pauses ~30s after inbound activity stops and only inbound HTTP
# can wake it, so scheduled work has two parts: an external clock pings the
# public URL to wake the machine (a GitHub Actions repo holding due.json),
# and this gate — a normal service, restarted on boot, running while the
# machine is up — checks the local queue every INTERVAL seconds and launches
# every job that is due as an unattended evener one-shot.
#
# Spin-down is preserved: the gate holds no task while idle, so the machine
# sleeps. At launch it takes one 5-minute bridge task (`evener-sched`) that
# spans the gap between the wake ping and the session's first keepawake
# marker; from then on the keepawake heartbeat holds the machine via the
# plugin markers (the one-shot sessions load the installed plugin) and
# releases it when the session ends.
#
# Queue:   $STATE/queue/<id>.json   job specs written by `sched add`
#          $STATE/queue/<id>.prompt the prompt text
# State:   $STATE/state/<id>.started set once at launch; a started job is
#                                  never launched again, whatever happens
#          $STATE/state/<id>.pid    pid of the launched CLI process
#          $STATE/state/<id>.done    record written when the CLI exits (the
#                                  session may OUTLIVE the CLI: the one-shot
#                                  hands its turn to a session daemon that
#                                  inherits the log fd — pid death is never
#                                  job death, and never a reason to retry)
#          $STATE/state/<id>.failed set when the spec is unusable
# Logs:    $STATE/logs/<id>.log     the session's output
#          $STATE/gate.log          gate decisions (the audit trail)
#
# Machine-specific values come from the optional shared config file
# (~/.config/evener-sprite/config, overridable via EVENER_SPRITE_CONFIG);
# per-tool EVENER_* env vars override the config file, and neutral built-in
# defaults sit under both. See config.example.
set -u

CONFIG_FILE="${EVENER_SPRITE_CONFIG:-$HOME/.config/evener-sprite/config}"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

PATH="$HOME/.local/bin:$PATH"
STATE="${EVENER_SCHED_STATE:-$HOME/.local/state/evener-sched}"
QUEUE="$STATE/queue"
RUNDATA="$STATE/state"
LOGS="$STATE/logs"
LOG="$STATE/gate.log"
RUN_DIR="${EVENER_SCHED_RUN_DIR:-$HOME/.local/state/evener/run}"
SOCKET="${EVENER_SCHED_SOCKET:-/.sprite/api.sock}"
TASK_NAME="${EVENER_SCHED_TASK:-evener-sched}"
INTERVAL="${EVENER_SCHED_INTERVAL:-10}"
WORKDIR="${EVENER_SCHED_WORKDIR:-${WORKDIR:-$HOME}}"
NICE="${EVENER_SCHED_NICE:-${NICE:-10}}"
MODE="${1:-}"

mkdir -p "$QUEUE" "$RUNDATA" "$LOGS"
touch "$LOG"

# The one-shot sessions need the provider key, exactly like the hub service.
# A missing provider env is never fatal here; launches warn loudly instead.
PROVIDER_ENV="${EVENER_SCHED_PROVIDER_ENV:-${PROVIDER_ENV:-}}"
# shellcheck disable=SC1091
[ -n "$PROVIDER_ENV" ] && . "$PROVIDER_ENV"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }

task_put() {
  curl -s --max-time 10 --unix-socket "$SOCKET" -H 'Content-Type: application/json' \
    -X PUT "http://sprite/v1/tasks/$TASK_NAME" -d '{"expire":"5m"}' >/dev/null
}

live_pid() { [ -n "${1:-}" ] && [ -r "/proc/$1/cmdline" ]; }

# Is a daemon currently serving this session? (run-dir info files map each
# live serve daemon to its root session.)
daemon_live() {
  local sid=$1 j jpid jsid
  for j in "$RUN_DIR"/*.json; do
    [ -f "$j" ] || continue
    jpid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$j" | head -1)
    jsid=$(sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p' "$j" | head -1)
    if [ "$jsid" = "$sid" ] && [ -d "/proc/$jpid" ]; then
      return 0
    fi
  done
  return 1
}

warn_no_provider_env() {
  if [ -z "$PROVIDER_ENV" ]; then
    log "warn: PROVIDER_ENV not configured; launching without provider env"
  fi
}

# How many queue entries are due but not started yet.
due_count() {
  local spec id due now n=0
  now=$(date +%s)
  for spec in "$QUEUE"/*.json; do
    [ -f "$spec" ] || continue
    id=$(jq -r '.id' "$spec")
    [ -n "$id" ] && [ "$id" != "null" ] || continue
    [ -f "$RUNDATA/$id.started" ] && continue
    [ -f "$RUNDATA/$id.failed" ] && continue
    due=$(jq -r '.due_epoch' "$spec")
    [ "$due" -le "$now" ] 2>/dev/null && n=$((n + 1))
  done
  echo "$n"
}

start_due_jobs() {
  local spec id name model mr due now prompt rs mdesc
  local MODEL_ARGS=()
  now=$(date +%s)
  for spec in "$QUEUE"/*.json; do
    [ -f "$spec" ] || continue
    id=$(jq -r '.id' "$spec")
    [ -n "$id" ] && [ "$id" != "null" ] || continue
    [ -f "$RUNDATA/$id.started" ] && continue
    [ -f "$RUNDATA/$id.failed" ] && continue
    due=$(jq -r '.due_epoch' "$spec")
    [ "$due" -le "$now" ] 2>/dev/null || continue

    name=$(jq -r '.name // "?"' "$spec")
    model=$(jq -r '.model // ""' "$spec")
    mr=$(jq -r '.max_rounds' "$spec")
    prompt="$QUEUE/$id.prompt"
    if [ ! -f "$prompt" ]; then
      log "job $id ($name): no prompt file; FAILED"
      echo "{\"id\":\"$id\",\"error\":\"missing prompt file\"}" >"$RUNDATA/$id.failed"
      continue
    fi

    # Steering an existing session: launch exactly once with the session's
    # full context. A live daemon cannot take external input, so wait (logged
    # once) until it is gone; the steering lands on the next tick after that.
    rs=$(jq -r '.resume_session // ""' "$spec")
    if [ -n "$rs" ]; then
      if daemon_live "$rs" ]; then
        if [ ! -f "$RUNDATA/$id.waiting" ]; then
          log "job $id ($name): target session $rs has a live daemon; waiting for it to go idle/dead (cancel with sched rm $id)"
          touch "$RUNDATA/$id.waiting"
        fi
        continue
      fi
      rm -f "$RUNDATA/$id.waiting"
      touch "$RUNDATA/$id.started"
      # One 5-minute bridge hold; keepawake covers the session itself.
      task_put
      warn_no_provider_env
      # resume-with uses the target session's own model; no --model needed.
      ( cd "$WORKDIR" && exec nice -n "$NICE" evener --resume-with "$rs" --max-rounds "$mr" ) \
        <"$prompt" >>"$LOGS/$id.log" 2>&1 &
      echo $! >"$RUNDATA/$id.pid"
      log "job $id ($name) launched steering of session $rs (cli pid $(cat "$RUNDATA/$id.pid"))"
      continue
    fi

    # Launch exactly once, no matter what happens afterwards: the CLI process
    # is not a reliable liveness signal (it exits before the session ends),
    # so pid death must never trigger a retry.
    touch "$RUNDATA/$id.started"
    # One 5-minute bridge hold per launch; keepawake covers the session.
    task_put
    warn_no_provider_env
    # --model only when the spec carries one; otherwise evener uses its own
    # configured default.
    MODEL_ARGS=()
    [ -n "$model" ] && MODEL_ARGS=(--model "$model")
    # The subshell execs, so $! is the evener CLI pid. Never wrap the launch
    # in setsid: setsid forks and exits, and $! dies instantly. Nice the
    # launch: session work must yield to the hub under load (the serve
    # daemon inherits the nice value).
    ( cd "$WORKDIR" && exec nice -n "$NICE" evener "${MODEL_ARGS[@]}" --max-rounds "$mr" ) \
      <"$prompt" >>"$LOGS/$id.log" 2>&1 &
    echo $! >"$RUNDATA/$id.pid"
    if [ -n "$model" ]; then mdesc="model $model"; else mdesc="default model"; fi
    log "job $id ($name) launched ($mdesc, cli pid $(cat "$RUNDATA/$id.pid"))"
  done
}

settle_finished_jobs() {
  local f pid id status
  for f in "$RUNDATA"/*.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null) || continue
    live_pid "$pid" && continue
    id=$(basename "$f" .pid)
    # The CLI process exited. That is NOT job completion — the session can
    # still be running in its daemon — but it is worth recording. wait
    # returns 127 for a pid that is not our child (gate restarted meanwhile).
    status="unknown (gate restarted?)"
    if wait "$pid" 2>/dev/null; then
      status=0
    else
      rc=$?
      [ "$rc" -ne 127 ] && status="$rc"
    fi
    {
      printf '{"id":"%s","cli_exit_iso":"%s","cli_exit":"%s"}\n' \
        "$id" "$(date -u +%FT%TZ)" "$status"
    } >"$RUNDATA/$id.done"
    rm -f "$f"
    log "job $id: CLI process exited ($status); session result in $LOGS/$id.log"
  done
}

beat() {
  start_due_jobs
  settle_finished_jobs
}

log "gate starting (state=$STATE queue=$QUEUE interval=${INTERVAL}s task=$TASK_NAME workdir=$WORKDIR)"
PREV=$(date +%s)
while true; do
  beat
  if [ "$MODE" = "--once" ]; then break; fi
  sleep "$INTERVAL"
  NOW=$(date +%s)
  GAP=$(( NOW - PREV - INTERVAL ))
  if (( GAP > 30 )); then
    log "gate resumed after ${GAP}s gap (sprite pause or stall); due jobs pending: $(due_count)"
  fi
done
