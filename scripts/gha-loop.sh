#!/usr/bin/env bash
set -euo pipefail

WORKFLOW="${1:-Integration Tests}"
MODE="${2:-inspect}"
BRANCH="${3:-}"
POLL_SECS="${GHA_LOOP_POLL_SECS:-15}"

# Force non-interactive output from gh to avoid alternate-buffer TUI behavior.
export GH_PAGER=cat

usage() {
  cat <<'EOF'
Usage:
  scripts/gha-loop.sh [workflow-name] [inspect|rerun-failed|watch-latest] [branch]

Examples:
  scripts/gha-loop.sh
  scripts/gha-loop.sh "Integration Tests" inspect
  scripts/gha-loop.sh "Integration Tests" rerun-failed main
  scripts/gha-loop.sh "Build Image" watch-latest

Modes:
  inspect       Show latest run details and fetch only failed-step logs if present.
  rerun-failed  Re-run only failed jobs for the latest failed run and watch it.
  watch-latest  Non-interactive live monitor of latest run (step + status deltas).

Environment:
  GHA_LOOP_POLL_SECS   Poll interval in seconds for watch mode (default: 15)
EOF
}

if [[ "${WORKFLOW}" == "-h" || "${WORKFLOW}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "[ERROR] GitHub CLI (gh) is not installed."
  echo "Install: https://cli.github.com/"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "[ERROR] gh is not authenticated."
  echo "Run: gh auth login"
  exit 1
fi

REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
if [[ -z "${REPO}" ]]; then
  echo "[ERROR] Could not resolve repository from current directory."
  exit 1
fi

resolve_run_id() {
  local mode="$1"

  if [[ "${mode}" == "rerun-failed" ]]; then
    if [[ -n "${BRANCH}" ]]; then
      gh run list \
        --workflow "${WORKFLOW}" \
        --status failure \
        --branch "${BRANCH}" \
        --limit 1 \
        --json databaseId \
        --jq '.[0].databaseId // empty'
    else
      gh run list \
        --workflow "${WORKFLOW}" \
        --status failure \
        --limit 1 \
        --json databaseId \
        --jq '.[0].databaseId // empty'
    fi
  else
    if [[ -n "${BRANCH}" ]]; then
      gh run list \
        --workflow "${WORKFLOW}" \
        --branch "${BRANCH}" \
        --limit 1 \
        --json databaseId \
        --jq '.[0].databaseId // empty'
    else
      gh run list \
        --workflow "${WORKFLOW}" \
        --limit 1 \
        --json databaseId \
        --jq '.[0].databaseId // empty'
    fi
  fi
}

run_id="$(resolve_run_id "${MODE}")"

if [[ -z "${run_id}" ]]; then
  if [[ "${MODE}" == "rerun-failed" ]]; then
    echo "[ERROR] No failed runs found for workflow: ${WORKFLOW}"
  else
    echo "[ERROR] No runs found for workflow: ${WORKFLOW}"
  fi
  exit 1
fi

run_status() {
  gh api "repos/${REPO}/actions/runs/${run_id}" --jq '.status'
}

run_conclusion() {
  gh api "repos/${REPO}/actions/runs/${run_id}" --jq '.conclusion // ""'
}

run_url() {
  gh api "repos/${REPO}/actions/runs/${run_id}" --jq '.html_url'
}

current_step_name() {
  gh api "repos/${REPO}/actions/runs/${run_id}/jobs" \
    --jq '[.jobs[]? | .steps[]? | select(.status=="in_progress") | .name][0] // ""'
}

current_step_started_at() {
  gh api "repos/${REPO}/actions/runs/${run_id}/jobs" \
    --jq '[.jobs[]? | .steps[]? | select(.status=="in_progress") | .started_at][0] // ""'
}

print_summary() {
  echo "Workflow : ${WORKFLOW}"
  echo "Repo     : ${REPO}"
  echo "Run ID   : ${run_id}"
  echo "Status   : $(run_status)"
  echo "URL      : $(run_url)"
}

print_live_step_snapshot() {
  local step
  local started

  step="$(current_step_name)"
  started="$(current_step_started_at)"

  if [[ -n "${step}" ]]; then
    echo "Active step: ${step}"
    if [[ -n "${started}" ]]; then
      echo "Step started at: ${started}"
    fi
  else
    echo "Active step: <none>"
  fi
}

dump_failed_logs() {
  local out_file="/tmp/gha-failed-${run_id}.log"
  if gh run view "${run_id}" --log-failed >"${out_file}" 2>/dev/null; then
    if [[ -s "${out_file}" ]]; then
      echo ""
      echo "Failed-step logs saved: ${out_file}"
      echo "--- tail (last 120 lines) ---"
      tail -n 120 "${out_file}" || true
      echo "--- end tail ---"
    else
      echo "No failed-step logs available for run ${run_id}."
    fi
  else
    echo "No failed-step logs available for run ${run_id}."
  fi
}

watch_run_until_complete() {
  local last_line=""

  echo "Polling every ${POLL_SECS}s"
  while true; do
    local status
    local conclusion
    local step
    local step_started
    local line

    status="$(run_status)"
    conclusion="$(run_conclusion)"
    step="$(current_step_name)"
    step_started="$(current_step_started_at)"

    line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] status=${status} conclusion=${conclusion:-n/a} step=${step:-none} started=${step_started:-n/a}"
    if [[ "${line}" != "${last_line}" ]]; then
      echo "${line}"
      last_line="${line}"
    fi

    if [[ "${status}" == "completed" ]]; then
      break
    fi

    sleep "${POLL_SECS}"
  done

  local final_conclusion
  final_conclusion="$(run_conclusion)"
  echo "Run conclusion: ${final_conclusion}"
  if [[ "${final_conclusion}" == "failure" ]]; then
    dump_failed_logs
    return 1
  fi

  return 0
}

case "${MODE}" in
  inspect)
    print_summary
    print_live_step_snapshot
    dump_failed_logs
    ;;
  rerun-failed)
    print_summary

    echo "Re-running failed jobs for run ${run_id}..."
    gh run rerun "${run_id}" --failed

    echo "Watching rerun for run ${run_id}..."
    watch_run_until_complete
    ;;
  watch-latest)
    print_summary
    watch_run_until_complete
    ;;
  *)
    echo "[ERROR] Unknown mode: ${MODE}"
    usage
    exit 1
    ;;
esac
