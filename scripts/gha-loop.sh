#!/usr/bin/env bash
set -euo pipefail

WORKFLOW="${1:-Integration Tests}"
MODE="${2:-inspect}"
BRANCH="${3:-}"

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
  watch-latest  Watch latest run live, then print failed logs if it fails.
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

print_summary() {
  echo "Workflow : ${WORKFLOW}"
  echo "Run ID   : ${run_id}"
  gh run view "${run_id}"
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

case "${MODE}" in
  inspect)
    print_summary
    dump_failed_logs
    ;;
  rerun-failed)
    print_summary

    echo "Re-running failed jobs for run ${run_id}..."
    gh run rerun "${run_id}" --failed

    echo "Watching rerun for run ${run_id}..."
    gh run watch "${run_id}" --exit-status || true

    final_conclusion=$(gh run view "${run_id}" --json conclusion --jq '.conclusion')
    echo "Rerun conclusion: ${final_conclusion}"
    if [[ "${final_conclusion}" == "failure" ]]; then
      dump_failed_logs
      exit 1
    fi
    ;;
  watch-latest)
    print_summary
    gh run watch "${run_id}" --exit-status || true
    final_conclusion=$(gh run view "${run_id}" --json conclusion --jq '.conclusion')
    echo "Run conclusion: ${final_conclusion}"
    if [[ "${final_conclusion}" == "failure" ]]; then
      dump_failed_logs
      exit 1
    fi
    ;;
  *)
    echo "[ERROR] Unknown mode: ${MODE}"
    usage
    exit 1
    ;;
esac
