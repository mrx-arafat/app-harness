#!/usr/bin/env bash
# run.sh — cli adapter "run" shim (ADAPTER-CONTRACT §5).
# CLI/TUI tools have no long-lived server to boot. `start` prints the neutral
# ready line and exits; `stop` is an idempotent no-op. bash 3.2 compatible.
set -u

MODE=""
for _a in "$@"; do
  case "$_a" in
    start) MODE="start" ;;
    stop)  MODE="stop" ;;
  esac
done

case "$MODE" in
  start)
    # Nothing to boot: port 0, pid 0, no url.
    printf 'READY 0 0 -\n'
    exit 0
    ;;
  stop)
    # No process was started; nothing to kill.
    exit 0
    ;;
  *)
    printf 'FAIL unknown or missing command (expected start|stop)\n' >&2
    exit 1
    ;;
esac
