---
name: schedule-work
description: Use when work needs to run at a future time on this sprite, or an existing session needs waking/steering at a scheduled moment: registering scheduled evener runs with sched, choosing between sched, in-session job_watch timers, and background jobs, and checking what ran.
---

# Scheduling work on this sprite

This sprite sleeps ~30s after inbound activity stops; nothing on the machine
can wake it. Choose the pattern that matches the need:

| Need | Use |
|---|---|
| Long work right now, keep working meanwhile | a background shell job (mode="background") |
| Wake *this session* in ≤24h, one-shot or repeating ≤1h, while the machine is likely awake anyway | `job_watch` with `after_seconds` / `repeat_seconds` (durable; fires when the daemon is alive — including after boot auto-resume) |
| Run something at a future time even if the sprite is asleep | `sched` (external GitHub Actions clock pings the sprite; the gate service runs the job) |

## sched — future-time runs

`sched` is the `bin/sched` script from the evener-sched repo; your machine's
AGENTS.md guidance names the local checkout path if one is installed.
Machine-specific values (default model, work dir, provider env file) come
from the shared config file `~/.config/evener-sprite/config` — see the repo's
`config.example` for every key.

```bash
sched add --in "4 hours" --name tidy --max-rounds 20 \
  --prompt "Run the test suite in <repo> and summarize failures."
sched add --at "tomorrow 09:00" --resume-session <session-id> \
  --prompt "Continue the build and report."   # steer an existing session
sched list      # ids, due times, state, whether the GitHub wake fired
sched rm <id>    # cancel
```

- A scheduled job is a **full headless session with tools** (shell, gh,
  delegates) — the prompt is the instruction. It has **no ask_user**: design
  the prompt so the job can finish unattended. `--max-rounds` defaults to 40.
- `--resume-session <id>` continues an **existing session's context** with
  the prompt as its next input. If the target session's daemon is live at
  due time, the gate waits (logged once) until it is idle/dead; cancel with
  `sched rm`. Resume-with uses the target's own model.
- Timing is best-effort: the GitHub cron floor is 5 minutes and can lag; a
  wake boots the machine (~20s). For an exact moment, dispatch the companion
  wake repo's `ping-at.yml` workflow (`gh workflow run ping-at.yml -f at=<UTC
  ISO>`, repo per `EVENER_SCHED_GH_CLONE`, default `~/projects/sprite-sched`).

## Verify what ran

- `~/.local/state/evener-sched/gate.log` — launches, waits, gaps (the
  machine's freeze record).
- `~/.local/state/evener-sched/logs/<job-id>.log` — the job session's output.
- `~/.local/state/evener-keepawake/heartbeat.log` — what held the machine
  awake and when it slept (`resumed after Ns gap` lines).

## Gotchas

- Prompts are stored in plain files under
  `~/.local/state/evener-sched/queue/` — never put secrets in them.
- Pauses are both freeze-and-resume (short) and full stop/start (long or
  under load). Durable state survives both; boot auto-resume (the
  evener-resume tool) brings recently-active sessions back, and
  `evener doctor sessions --json --since 24h` lists sessions to steer.
- Machine-specific conventions — the local sched path, where scheduled jobs
  should leave human-visible results, and any yield rules for heavy work —
  live in this machine's AGENTS.md guidance, not here.
