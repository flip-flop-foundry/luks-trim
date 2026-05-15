---
name: integration-test-triage
description: "Use when: triaging failures in the Integration Tests GitHub Actions workflow for this repo (Talos QEMU, Longhorn install, luks-trim T0/T1/T2/T3 checks). Triggers: integration test failed, talos qemu failure, longhorn install failed, dry-run assertion failed, fstrim test failed, gha integration triage."
---

# Integration Test Triage Skill

This skill is specialized for fast diagnosis and repair of failures in the Integration Tests workflow in this repository.

## Scope

- Workflow: Integration Tests
- File focus:
  - .github/workflows/integration-test.yml
  - templates/configmap.yaml
  - templates/cronjob.yaml
  - values.yaml
  - Dockerfile
- Infra context:
  - Talos single-node QEMU cluster
  - Longhorn Helm install
  - Encrypted PVC write/delete/trim assertions
  - luks-trim live and dry-run job execution

## Fast Loop

1. Inspect latest workflow failure:
   - make gha-inspect
  - For in-progress execution, use: make gha-follow
2. Identify first failing step and exact error lines.
3. Apply smallest targeted patch.
4. Run local static/syntax checks for changed files.
5. Re-run failed jobs only:
   - make gha-rerun
6. Repeat until green.

## Primary Failure Map

### Step: Install QEMU and KVM

Symptoms:
- kvm-ok fails
- /dev/kvm permission errors

Checks:
- Confirm qemu-system-x86 and qemu-kvm packages install
- Confirm chmod 666 /dev/kvm runs

Typical fixes:
- Keep tool install minimal and deterministic
- Avoid architecture-specific package names unless required

### Step: Create Talos QEMU cluster

Symptoms:
- talosctl cluster create timeout
- factory schematic id errors
- machine config patch rejected

Checks:
- Validate factory schematic POST response has id
- Validate mc-patch YAML indentation and keys
- Confirm talos version resolved and installer image path is valid

Typical fixes:
- Fix patch YAML shape under cluster/machine
- Increase wait timeout if startup is slow
- Ensure control-plane scheduling override remains enabled

### Step: Install Longhorn

Symptoms:
- helm upgrade/install fails
- chart version not found
- pods never become Ready

Checks:
- Verify detected chart version exists
- Confirm longhorn repo update succeeded
- Check namespace and pod events in longhorn-system

Typical fixes:
- Correct version resolution logic
- Pin temporarily to a known-good version while debugging
- Adjust wait timeout for heavy startup paths

### Step: Create test namespace and LUKS key secret

Symptoms:
- Secret creation conflicts or malformed keys
- downstream encryption provisioning errors

Checks:
- Ensure required literals exist: CRYPTO_KEY_VALUE/provider/cipher/hash/size/pbkdf
- Confirm namespace longhorn-system for secret

Typical fixes:
- Keep key names aligned with Longhorn CSI encryption expectations
- Handle namespace pre-existence safely if needed

### Step: Create encrypted Longhorn StorageClass / PVC / filler pod

Symptoms:
- PVC Pending
- filler pod not Ready
- volume provisioning events indicate secret or parameter mismatch

Checks:
- StorageClass parameters include all CSI secret refs
- PVC references correct storageClassName
- filler pod mounts expected PVC name

Typical fixes:
- Correct storage class secret names/namespaces
- Verify replica count and scheduling assumptions for single-node test

### Step: T1 live run assertions

Symptoms:
- worker job failure
- [ERROR] lines in worker logs
- actualSize reclaim assertion warning or failure behavior

Checks:
- coordinator job complete then worker job discovered correctly
- worker logs scoped to exact worker job label
- longhorn volume actualSize read from correct volume id

Typical fixes:
- Tighten worker-job selection logic
- Preserve robust log and status checks before reclaim assertions
- Keep reclaim threshold realistic and advisory where intended

### Step: T2 dry-run assertions

Symptoms:
- no [dry-run] lines
- [ERROR] lines appear
- actualSize changes beyond threshold

Checks:
- chart upgraded with dryRun=true
- dry-run job worker identified from current run only
- delta threshold computed from pre-dry-run baseline

Typical fixes:
- Ensure dryRun value is propagated to worker env
- Ensure test writes and baseline capture order are stable
- verify script logs [dry-run] paths in templates/configmap.yaml

## Evidence Collection

When failing, collect and prefer in this order:

1. Failed-step log from gha-loop output (/tmp/gha-failed-<run-id>.log)
2. Job summary and first failing step from gh run view
3. Kubernetes diagnostics already emitted by workflow failure handler

## Patch Strategy

- Keep changes scoped to the failing step first.
- Avoid broad refactors during red CI unless required.
- Preserve existing observability logs and failure messages.
- Re-run failed jobs before re-running whole workflow.

## Reporting Template

- Run ID: <id>
- Failing step: <name>
- Root cause: <1-3 lines>
- Patch: <files + intent>
- Local checks: <what passed>
- Rerun result: <pass/fail + next failing step>
