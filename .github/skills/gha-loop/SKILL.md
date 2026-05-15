---
name: gha-loop
description: "Use when: GitHub Actions failures need fast triage, failed-step log collection, rerun of failed jobs, or iterative CI debugging in this repo. Triggers: gha loop, CI failure, GitHub Actions failed, rerun failed jobs, inspect failed logs."
---

# GHA Loop Skill

This skill provides a fast, repeatable workflow for iterating on GitHub Actions failures in this repository using the local helper script and Make targets.

## Scope

Workspace-local skill for this repository.

## Prerequisites

- GitHub CLI installed: gh
- Authenticated session: gh auth login
- Repository helper script present: scripts/gha-loop.sh

## Default Workflow

1. Inspect latest run and failed-step logs.
2. Identify the first failing step and root cause.
3. Apply a targeted fix in the repo.
4. Run local validation where possible.
5. Re-run only failed jobs.
6. Watch the rerun and collect failed logs again if needed.
7. Repeat until green.

## Commands

- Inspect latest run:
  - make gha-inspect
  - scripts/gha-loop.sh "Integration Tests" inspect
- Re-run failed jobs from latest failed run:
  - make gha-rerun
  - scripts/gha-loop.sh "Integration Tests" rerun-failed
- Watch latest run:
  - make gha-watch
  - make gha-follow
  - scripts/gha-loop.sh "Integration Tests" watch-latest
- Limit to a branch:
  - scripts/gha-loop.sh "Integration Tests" inspect main
  - scripts/gha-loop.sh "Integration Tests" rerun-failed main

## Expected Outputs

- Run summary with run id, workflow, job status, and failing step.
- Failed-step logs written to:
  - /tmp/gha-failed-<run-id>.log
- Clear rerun result and final conclusion.
- Live status deltas while a run is in progress:
  - status
  - active step name
  - active step start time

## Ongoing Execution Monitoring

Use these for in-progress runs:

- make gha-follow
- scripts/gha-loop.sh "Integration Tests" watch-latest

Behavior:

- Non-interactive polling (no alternate-buffer TUI)
- Prints only status/step changes to reduce noise
- Poll interval configurable via environment variable:
  - GHA_LOOP_POLL_SECS=10 make gha-follow

## Agent Behavior

When this skill is invoked, prefer this order:

1. Run inspect mode first unless the user explicitly requests rerun/watch only.
2. Use failed-step logs as the primary evidence source.
3. Keep fixes narrow and validate quickly.
4. After each patch, run rerun-failed and report the new failing step (if any).
5. Stop only when the requested workflow is green or user asks to pause.

## Reporting Template

- Failing step: <name>
- Root cause: <short technical explanation>
- Change applied: <files and intent>
- Validation: <local checks + run conclusion>
- Next action: <rerun/patch/escalate>
