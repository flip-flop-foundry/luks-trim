#!/bin/sh
# luks-trim worker script — run once per node, then exit.
# Env vars injected by the per-node Job spec:
#   LONGHORN_ENABLED           "true" | "false"
#   TALOS_ENABLED              "true" | "false"
#   KMS_ENDPOINT               https://<host>:<port>  (empty = skip KMS path)
#   GLOBAL_KEY_ENABLED         "true" | "false"
#   GLOBAL_KEY_NS              namespace of the global key secret
#   GLOBAL_KEY_SECRET          name of the global key secret
#   GLOBAL_KEY_FIELD           data field name inside the secret
#   PV_ANNOTATIONS_ENABLED     "true" | "false"
#   PV_ANNOTATIONS_KEY_PREFIX  annotation key prefix (default: luks-trim)
#   PV_ANNOTATIONS_INCLUDE_FAILURE_REASON  "true" | "false"
#   PV_ANNOTATIONS_INCLUDE_NODE_NAME       "true" | "false"
#   DRY_RUN                    "true" | "false" — skip all writes when true
#   TALOS_STATIC_KEY_ENABLED   "true" | "false"
#   TALOS_STATIC_KEY_NS        namespace of the static key secret
#   TALOS_STATIC_KEY_SECRET    name of the static key secret
#   TALOS_STATIC_KEY_FIELD     data field name inside the secret
#
# All required tools (cryptsetup, dmsetup, fstrim, jq, curl, grpcurl) are
# pre-installed in the custom Ubuntu worker image built by the GitHub Actions
# workflow (.github/workflows/build-image.yml). No runtime package downloads.

{{- if .Values.talos.enabled }}
# Write the KMS proto definition used by grpcurl for Talos KMS unseal calls.
printf '%s\n' \
  'syntax = "proto3";' \
  'package sidero.kms;' \
  'service KMSService {' \
  '  rpc Seal(Request) returns (Response);' \
  '  rpc Unseal(Request) returns (Response);' \
  '}' \
  'message Request { string node_uuid = 1; bytes data = 2; }' \
  'message Response { bytes data = 1; }' \
  > /tmp/kms.proto
{{- end }}

KUBE_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
KUBE_CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
KUBE_API=https://kubernetes.default.svc
RUN_EPOCH=$(date +%s)
RUN_TS_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
WORKER_NODE=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo "unknown")

# ── Shared helpers ──────────────────────────────────────────────────────

is_true() {
  [ "${1:-false}" = "true" ]
}

log_info() {
  echo "  [INFO] $*"
}

log_warn() {
  echo "  [WARN] $*" >&2
}

log_error() {
  echo "  [ERROR] $*" >&2
}

# kube_get </api/path>
kube_get() {
  _api_path="$1"
  curl -sf --cacert "$KUBE_CA" \
    -H "Authorization: Bearer $KUBE_TOKEN" \
    "$KUBE_API$_api_path" 2>/dev/null
}

# kube_get_with_status </api/path>
# Prints response body followed by a final line containing the HTTP code.
kube_get_with_status() {
  _api_path="$1"
  curl -s -w "\n%{http_code}" --cacert "$KUBE_CA" \
    -H "Authorization: Bearer $KUBE_TOKEN" \
    "$KUBE_API$_api_path" 2>/dev/null
}

# fetch_secret_key <namespace> <secret-name> <field-name>
# Prints the base64-encoded value of the requested field from a K8s secret.
fetch_secret_key() {
  _namespace="$1"
  _secret_name="$2"
  _field_name="$3"

  _response=$(kube_get_with_status "/api/v1/namespaces/$_namespace/secrets/$_secret_name")
  _http_code=$(printf '%s' "$_response" | awk 'END{print}')
  _body=$(printf '%s' "$_response" | awk 'NR>1{print prev} {prev=$0}')

  case "$_http_code" in
    200) printf '%s' "$_body" | jq -r --arg f "$_field_name" '.data[$f] // empty' ;;
    404) log_warn "secret $_namespace/$_secret_name not found" ;;
    403) log_warn "secret $_namespace/$_secret_name: permission denied" ;;
    '')  log_warn "secret $_namespace/$_secret_name: no response from API" ;;
    *)   log_warn "secret $_namespace/$_secret_name: HTTP $_http_code" ;;
  esac
}

# kube_patch_with_status </api/path> <json-merge-patch>
# Prints only the HTTP status code.
kube_patch_with_status() {
  _api_path="$1"
  _json_patch="$2"
  curl -s -o /dev/null -w "%{http_code}" --cacert "$KUBE_CA" \
    -X PATCH \
    -H "Authorization: Bearer $KUBE_TOKEN" \
    -H "Content-Type: application/merge-patch+json" \
    --data "$_json_patch" \
    "$KUBE_API$_api_path" 2>/dev/null
}

# annotate_longhorn_pv <pv-name> <status> <reason> <encrypted> <discard-before>
#                      <discard-after> <key-identified> <key-source> <would-apply>
annotate_longhorn_pv() {
  _pv_name="$1"
  _status="$2"
  _reason="$3"
  _encrypted="$4"
  _discard_before="$5"
  _discard_after="$6"
  _key_identified="$7"
  _key_source="$8"
  _would_apply="$9"

  if ! is_true "${PV_ANNOTATIONS_ENABLED:-false}"; then
    return 0
  fi

  _key_prefix="${PV_ANNOTATIONS_KEY_PREFIX:-luks-trim}"
  _key_prefix=$(printf '%s' "$_key_prefix" | sed 's:/*$::')
  [ -z "$_key_prefix" ] && _key_prefix="luks-trim"

  _mode="live"
  is_true "${DRY_RUN:-false}" && _mode="dry-run"

  _result_json=$(jq -cn \
    --arg status "$_status" \
    --arg mode "$_mode" \
    --arg pv "$_pv_name" \
    --arg epoch "$RUN_EPOCH" \
    --arg ts "$RUN_TS_UTC" \
    --arg encrypted "$_encrypted" \
    --arg discard_before "$_discard_before" \
    --arg discard_after "$_discard_after" \
    --arg key_identified "$_key_identified" \
    --arg key_source "$_key_source" \
    --arg reason "$_reason" \
    --arg include_reason "${PV_ANNOTATIONS_INCLUDE_FAILURE_REASON:-true}" \
    --arg include_node "${PV_ANNOTATIONS_INCLUDE_NODE_NAME:-true}" \
    --arg node "$WORKER_NODE" \
    --arg would_apply "$_would_apply" \
    '{
      schema: "v1",
      component: "longhorn",
      status: $status,
      mode: $mode,
      pv: $pv,
      runEpoch: ($epoch | tonumber),
      runTime: $ts,
      encrypted: ($encrypted == "true"),
      allowDiscardsBefore: ($discard_before == "true"),
      allowDiscardsAfter: ($discard_after == "true"),
      keyIdentified: ($key_identified == "true"),
      keySource: (if $key_source == "" then null else $key_source end),
      fstrimOwner: "longhorn-recurring-job",
      wouldApplyAllowDiscards: ($would_apply == "true")
    }
    + (if $include_reason == "true" and $reason != "" then {reason: $reason} else {} end)
    + (if $include_node == "true" and $node != "" then {workerNode: $node} else {} end)')

  _patch_payload=$(jq -cn \
    --arg status_key "$_key_prefix/status" \
    --arg lastrun_key "$_key_prefix/lastrun" \
    --arg result_key "$_key_prefix/last-result" \
    --arg status_val "$_status" \
    --arg lastrun_val "$RUN_EPOCH" \
    --arg result_val "$_result_json" \
    '{metadata: {annotations: {($status_key): $status_val, ($lastrun_key): $lastrun_val, ($result_key): $result_val}}}')

  _http_code=$(kube_patch_with_status "/api/v1/persistentvolumes/$_pv_name" "$_patch_payload")
  case "$_http_code" in
    200|201) log_info "annotated PV $_pv_name (status=$_status)" ;;
    404) log_warn "PV $_pv_name not found for annotation" ;;
    403) log_warn "PV $_pv_name annotation denied (missing patch permission?)" ;;
    '')  log_warn "PV $_pv_name annotation: no response from API" ;;
    *)   log_warn "PV $_pv_name annotation failed (HTTP $_http_code)" ;;
  esac
}

# lookup_pvc <pv-name>  →  "namespace/pvcname"
lookup_pvc() {
  _pv_name="$1"
  _pv_json=$(kube_get "/api/v1/persistentvolumes/$_pv_name")
  [ -z "$_pv_json" ] && return

  _pvc_namespace=$(printf '%s' "$_pv_json" | jq -r '.spec.claimRef.namespace // empty')
  _pvc_name=$(printf '%s' "$_pv_json" | jq -r '.spec.claimRef.name // empty')
  [ -n "$_pvc_namespace" ] && [ -n "$_pvc_name" ] && echo "$_pvc_namespace/$_pvc_name"
}

# has_allow_discards_active <dm-name>
has_allow_discards_active() {
  _dm_name="$1"
  dmsetup table "$_dm_name" 2>/dev/null | grep -q "allow_discards"
}

# try_secret_key <device> <dm-name> <namespace> <secret> <field> <label>
try_secret_key() {
  _device="$1"
  _dm_name="$2"
  _namespace="$3"
  _secret_name="$4"
  _field_name="$5"
  _label="$6"

  _secret_key_b64=$(fetch_secret_key "$_namespace" "$_secret_name" "$_field_name")
  [ -z "$_secret_key_b64" ] && return 1

  try_key "$_device" "$_dm_name" "$_secret_key_b64" "$_label"
}

# try_key <device> <dm-name> <key_b64> <label>
# key_b64: base64-encoded passphrase (decoded to a tempfile before use).
# Reads existing LUKS flags and preserves them while adding allow-discards.
# In dry-run mode the key is verified but cryptsetup refresh is skipped.
try_key() {
  _device="$1"
  _dm_name="$2"
  _key_b64="$3"
  _label="$4"

  [ -z "$_key_b64" ] && return 1

  _tmp_key_file=$(mktemp) || {
    echo "    $_label: [ERROR] failed to create temporary key file"
    return 1
  }

  if ! printf '%s' "$_key_b64" | base64 -d > "$_tmp_key_file" 2>/dev/null; then
    echo "    $_label: [ERROR] failed to decode key payload (base64)"
    rm -f "$_tmp_key_file"
    return 1
  fi

  _luks_flags=$(cryptsetup luksDump "$_device" 2>/dev/null \
    | grep "^Flags:" | sed 's/Flags:[[:space:]]*//')

  if printf '%s' "$_luks_flags" | grep -q "allow-discards"; then
    echo "    $_label: allow-discards already persistent"
    rm -f "$_tmp_key_file"
    return 0
  fi

  _cryptsetup_flags="--allow-discards"
  printf '%s' "$_luks_flags" | grep -q "no-read-workqueue" && _cryptsetup_flags="$_cryptsetup_flags --perf-no_read_workqueue"
  printf '%s' "$_luks_flags" | grep -q "no-write-workqueue" && _cryptsetup_flags="$_cryptsetup_flags --perf-no_write_workqueue"

  if is_true "${DRY_RUN:-false}"; then
    # Verify the key unlocks the device without writing anything.
    if cryptsetup open --test-passphrase --key-file "$_tmp_key_file" "$_device" 2>/dev/null; then
      echo "    $_label: [dry-run] key valid — would apply allow-discards (flags: $_cryptsetup_flags --persistent)"
      rm -f "$_tmp_key_file"
      return 0
    else
      echo "    $_label: [dry-run] key did NOT unlock device"
      rm -f "$_tmp_key_file"
      return 1
    fi
  fi

  if cryptsetup $_cryptsetup_flags --persistent --key-file "$_tmp_key_file" refresh "$_dm_name" 2>/dev/null; then
    echo "    $_label: applied allow-discards"
    rm -f "$_tmp_key_file"
    return 0
  fi

  rm -f "$_tmp_key_file"
  return 1
}

# fstrim_dev <dm-name>
# Resolves the dm-crypt device to its mountpoint via the host mount table
# (accessible because hostPID=true exposes /proc/1/mounts) and runs fstrim
# in the host mount namespace via nsenter.
# Ubuntu's fstrim produces richer output than Alpine's (bytes freed, time),
# which is why the worker image is Ubuntu-based.
# In dry-run mode the mountpoint is identified but fstrim is not executed.
fstrim_dev() {
  _dm_name="$1"
  _real_dev=$(readlink -f "/dev/mapper/$_dm_name" 2>/dev/null)
  _mountpoint=$(awk -v d1="$_real_dev" -v d2="/dev/mapper/$_dm_name" \
    '$1==d1 || $1==d2 {print $2; exit}' /proc/1/mounts 2>/dev/null)

  if [ -z "$_mountpoint" ]; then
    _sectors=$(cat "/sys/class/block/$(basename "$_real_dev")/size" 2>/dev/null || echo 0)
    _size_mib=$(( _sectors / 2048 ))
    if [ "$_size_mib" -lt 1024 ]; then
      echo "    [fstrim] $_dm_name ($_real_dev): small system partition (~${_size_mib} MiB), skipping"
    else
      echo "    [fstrim] $_dm_name ($_real_dev): not found in mount table (block volume?), skipping"
    fi
    return 0
  fi

  echo "    [fstrim] $_dm_name ($_real_dev) mounted at $_mountpoint"
  if is_true "${DRY_RUN:-false}"; then
    # fstrim -n (--dry-run) does everything except issue the FITRIM ioctl —
    # it walks the filesystem free-space tree and reports what would be
    # discarded without touching the device.
    _trim_output=$(nsenter --mount=/proc/1/ns/mnt -- fstrim -n -v "$_mountpoint" 2>&1)
    _trim_rc=$?
    printf '%s\n' "$_trim_output" | sed 's/^/    [dry-run] /'
    [ "$_trim_rc" -eq 0 ] || echo "    [fstrim] [dry-run] fstrim -n exited $_trim_rc"
    return 0
  fi

  _trim_output=$(nsenter --mount=/proc/1/ns/mnt -- fstrim -v "$_mountpoint" 2>&1)
  _trim_rc=$?
  printf '%s\n' "$_trim_output" | sed 's/^/    /'
  [ "$_trim_rc" -eq 0 ] || echo "    [fstrim] [warn] fstrim exited $_trim_rc"
}

{{- if .Values.longhorn.enabled }}
# ── Longhorn volume processor ────────────────────────────────────────────
# For Longhorn volumes:
#   - encrypted (LUKS): enable allow-discards via cryptsetup refresh
#   - unencrypted: skip key lookup (no unlock required)
# This keeps the worker safe for mixed storage classes.
#
# NOTE — fstrim is NOT run here for Longhorn volumes.
# Longhorn's own "Trim Filesystem" RecurringJob is responsible for TRIM,
# once allow-discards is enabled on encrypted devices.
process_longhorn_volumes() {
  echo "--- Checking Longhorn volumes..."
  _device_dir="${LONGHORN_DEVICE_PATH:-/dev/longhorn}"
  if [ ! -d "$_device_dir" ] || [ -z "$(ls "$_device_dir"/ 2>/dev/null)" ]; then
    log_info "No volumes in $_device_dir on this node"
    return
  fi

  _global_key_b64=""
  if is_true "${GLOBAL_KEY_ENABLED:-false}"; then
    _global_key_b64=$(fetch_secret_key "$GLOBAL_KEY_NS" "$GLOBAL_KEY_SECRET" "$GLOBAL_KEY_FIELD")
  fi

  _failed_count=0
  for _device in "$_device_dir"/*; do
    [ -e "$_device" ] || continue
    _volume_name=$(basename "$_device")

    # Unencrypted Longhorn volumes: skip key operations.
    # TRIM remains Longhorn RecurringJob responsibility.
    if ! cryptsetup isLuks "$_device" >/dev/null 2>&1; then
      echo "  $_volume_name: not LUKS-encrypted — skipping (trim handled by Longhorn RecurringJob)"
      annotate_longhorn_pv "$_volume_name" "skipped" "not LUKS-encrypted; trim handled by Longhorn RecurringJob" "false" "false" "false" "false" "" "false"
      continue
    fi

    _discard_before="false"
    _discard_after="false"
    _key_identified="false"
    _would_apply="false"

    if has_allow_discards_active "$_volume_name"; then
      _discard_before="true"
      _discard_after="true"
      echo "  $_volume_name: allow_discards already active, skipping"
      annotate_longhorn_pv "$_volume_name" "skipped" "allow_discards already active" "true" "$_discard_before" "$_discard_after" "$_key_identified" "" "$_would_apply"
      continue
    fi

    _pvc_ref=$(lookup_pvc "$_volume_name")
    if [ -n "$_pvc_ref" ]; then
      _pvc_namespace="${_pvc_ref%%/*}"
      _pvc_name="${_pvc_ref##*/}"
      echo "  $_volume_name: PVC $_pvc_namespace/$_pvc_name — trying keys..."
    else
      echo "  $_volume_name: could not resolve PVC, trying global key only..."
      _pvc_namespace=""
      _pvc_name=""
    fi

    _applied_key_label=""

    # 1. Global key
    if [ -n "$_global_key_b64" ]; then
      try_key "$_device" "$_volume_name" "$_global_key_b64" "$GLOBAL_KEY_NS/$GLOBAL_KEY_SECRET" \
        && _applied_key_label="$GLOBAL_KEY_NS/$GLOBAL_KEY_SECRET"
    fi

    # 2. Per-PVC secret (secret named after the PVC, field CRYPTO_KEY_VALUE)
    if [ -z "$_applied_key_label" ] && [ -n "$_pvc_namespace" ] && [ -n "$_pvc_name" ]; then
      try_secret_key "$_device" "$_volume_name" "$_pvc_namespace" "$_pvc_name" "CRYPTO_KEY_VALUE" "$_pvc_namespace/$_pvc_name" \
        && _applied_key_label="$_pvc_namespace/$_pvc_name"
    fi

    # 3. Namespace shared secrets — iterate through every secret name listed
    #    under longhorn.namespaceSecrets for this PVC's namespace. The list
    #    is baked in at render time so no runtime config is needed.
    {{- if .Values.longhorn.namespaceSecrets }}
    if [ -z "$_applied_key_label" ] && [ -n "$_pvc_namespace" ]; then
      {{- range .Values.longhorn.namespaceSecrets }}
      if [ -z "$_applied_key_label" ] && [ "{{ .namespace }}" = "$_pvc_namespace" ]; then
        {{- range .secretNames }}
        if [ -z "$_applied_key_label" ]; then
          try_secret_key "$_device" "$_volume_name" "$_pvc_namespace" {{ . | quote }} "CRYPTO_KEY_VALUE" "$_pvc_namespace/{{ . }}" \
            && _applied_key_label="$_pvc_namespace/{{ . }}"
        fi
        {{- end }}
      fi
      {{- end }}
    fi
    {{- end }}

    if [ -n "$_applied_key_label" ]; then
      _key_identified="true"
      if is_true "${DRY_RUN:-false}"; then
        _would_apply="true"
        echo "  $_volume_name: [dry-run] key valid — allow-discards would be applied (key: $_applied_key_label)"
        annotate_longhorn_pv "$_volume_name" "success" "key validated in dry-run; allow_discards would be applied" "true" "$_discard_before" "$_discard_after" "$_key_identified" "$_applied_key_label" "$_would_apply"
      else
        _discard_after="true"
        echo "  $_volume_name: allow-discards enabled (key: $_applied_key_label)"
        annotate_longhorn_pv "$_volume_name" "success" "allow_discards enabled" "true" "$_discard_before" "$_discard_after" "$_key_identified" "$_applied_key_label" "$_would_apply"
      fi
    else
      echo "  [ERROR] $_volume_name: no matching key found — allow-discards NOT enabled"
      annotate_longhorn_pv "$_volume_name" "failure" "no matching key found; allow_discards not enabled" "true" "$_discard_before" "$_discard_after" "$_key_identified" "" "$_would_apply"
      _failed_count=$(( _failed_count + 1 ))
    fi
  done

  if [ "$_failed_count" -gt 0 ]; then
    echo "  [ERROR] $_failed_count Longhorn volume(s) could not be unlocked. Check key configuration."
    return 1
  fi
}
{{- end }}

{{- if .Values.talos.enabled }}
# ── Talos LUKS volume processor ──────────────────────────────────────────
# Volumes appear as /dev/mapper/luks2-<partition-uuid>.
# LUKS2 headers contain a sideroKMS token with UserData.sealedData.
# Flow: read sealedData → KMS Unseal(nodeUUID, sealedData) → passphrase.
#
# When talos.staticKey.enabled is true, the static passphrase is tried
# as a fallback after sideroKMS (or as the primary when kmsEndpoint is
# empty). This mirrors Talos itself, which supports multiple key slots.
#
# When talos.machineConfig.enabled is true, the Talos machine config is
# read from TALOS_MC_PATH (hostPath mount of /system/state/config.yaml)
# to auto-detect the KMS endpoint and/or static passphrase.

# find_siderokms_sealed_data <backing-device>
# Scans token IDs 0-31 and prints sealedData from the first sideroKMS token.
find_siderokms_sealed_data() {
  _backing_device="$1"
  _token_id=0

  while [ "$_token_id" -le 31 ]; do
    _token_json=$(cryptsetup token export --token-id "$_token_id" "$_backing_device" 2>/dev/null)
    if [ -n "$_token_json" ]; then
      _token_type=$(printf '%s' "$_token_json" | jq -r '.type // empty' 2>/dev/null)
      if [ "$_token_type" = "sideroKMS" ]; then
        printf '%s' "$_token_json" | jq -r '.UserData.sealedData // .userData.sealedData // .sealedData // empty'
        return 0
      fi
    fi
    _token_id=$(( _token_id + 1 ))
  done

  return 1
}

process_talos_volumes() {
  echo "--- Checking Talos LUKS volumes..."

  {{- if .Values.talos.machineConfig.enabled }}
  # ── Machine config auto-detection ───────────────────────────────────
  # The Talos machine config is mounted read-only at $TALOS_MC_PATH.
  # Extract KMS endpoint and static passphrase from it, using yq for
  # reliable YAML parsing.
  _machine_config_file="${TALOS_MC_PATH}/config.yaml"
  if [ ! -f "$_machine_config_file" ]; then
    log_warn "machineConfig.enabled but config file not found at $_machine_config_file"
  else
    log_info "reading machine config from $_machine_config_file"
    # Scan for KMS endpoint — check kind: VolumeConfig / UserVolumeConfig
    # documents first (new multi-document style), then fall back to the
    # legacy .machine.systemDiskEncryption field in the v1alpha1 document.
    # The config file is multi-document YAML; yq processes all documents.
    _mc_kms=$(yq e '
      select(.kind == "VolumeConfig" or .kind == "UserVolumeConfig")
      | .encryption.keys[]?
      | select(.kms != null)
      | .kms.endpoint
      ' "$_machine_config_file" 2>/dev/null | grep -v '^null$' | grep -v '^$' | head -1)
    if [ -z "$_mc_kms" ]; then
      _mc_kms=$(yq e '
        select(.machine.systemDiskEncryption != null)
        | .machine.systemDiskEncryption
        | to_entries[]?
        | .value.keys[]?
        | select(.kms != null)
        | .kms.endpoint
        ' "$_machine_config_file" 2>/dev/null | grep -v '^null$' | grep -v '^$' | head -1)
      [ -n "$_mc_kms" ] && log_info "machine config: KMS endpoint from systemDiskEncryption: $_mc_kms"
    else
      log_info "machine config: KMS endpoint from VolumeConfig: $_mc_kms"
    fi

    # Scan for static passphrase — same two-step order.
    _mc_static=$(yq e '
      select(.kind == "VolumeConfig" or .kind == "UserVolumeConfig")
      | .encryption.keys[]?
      | select(.static != null)
      | .static.passphrase
      ' "$_machine_config_file" 2>/dev/null | grep -v '^null$' | grep -v '^$' | head -1)
    if [ -z "$_mc_static" ]; then
      _mc_static=$(yq e '
        select(.machine.systemDiskEncryption != null)
        | .machine.systemDiskEncryption
        | to_entries[]?
        | .value.keys[]?
        | select(.static != null)
        | .static.passphrase
        ' "$_machine_config_file" 2>/dev/null | grep -v '^null$' | grep -v '^$' | head -1)
    fi
    [ -n "$_mc_static" ] && log_info "machine config: found static passphrase"
  fi
  {{- end }}

  _kms_host=$(printf '%s' "${KMS_ENDPOINT:-${_mc_kms:-}}" | sed 's|^https://||')
  _kms_enabled=false
  if [ -n "$_kms_host" ]; then
    _kms_enabled=true
    # Node UUID is required for KMS Unseal requests.
    _node_uuid=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [ -z "$_node_uuid" ]; then
      log_warn "cannot read node UUID from /sys/class/dmi/id/product_uuid — KMS path disabled"
      _kms_enabled=false
    fi
  fi

  _static_key_b64=""
  if is_true "${TALOS_STATIC_KEY_ENABLED:-false}" && [ -n "$TALOS_STATIC_KEY_SECRET" ]; then
    _static_key_b64=$(fetch_secret_key "$TALOS_STATIC_KEY_NS" "$TALOS_STATIC_KEY_SECRET" "$TALOS_STATIC_KEY_FIELD")
    if [ -z "$_static_key_b64" ]; then
      log_warn "static key secret $TALOS_STATIC_KEY_NS/$TALOS_STATIC_KEY_SECRET not found or empty"
    fi
  fi
  {{- if .Values.talos.machineConfig.enabled }}
  # Fall back to machine config static passphrase only when an explicit
  # Kubernetes secret is not configured.
  if [ -z "$_static_key_b64" ] && [ -n "${_mc_static:-}" ]; then
    _static_key_b64=$(printf '%s' "$_mc_static" | base64 | tr -d '\n')
    log_info "using static passphrase from machine config"
  fi
  {{- end }}

  if ! $_kms_enabled && [ -z "$_static_key_b64" ]; then
    {{- if .Values.talos.machineConfig.enabled }}
    # Nothing found in machine config and no explicit keys configured —
    # presume this node has no KMS/static encrypted volumes and skip.
    log_info "no KMS endpoint or static key found — assuming no encrypted volumes on this node"
    return 0
    {{- else }}
    log_error "no unlock path available: KMS endpoint is empty/unreachable and no static key configured"
    return 1
    {{- end }}
  fi

  _found_mapper=false
  _failed_count=0
  for _mapper_path in /dev/mapper/luks2-*; do
    [ -e "$_mapper_path" ] || continue
    _found_mapper=true
    _dm_name=$(basename "$_mapper_path")
    echo "  $_dm_name:"

    _discard_enabled=false
    if has_allow_discards_active "$_dm_name"; then
      echo "    allow_discards already active"
      _discard_enabled=true
    fi

    if ! $_discard_enabled; then
      _backing_device=$(cryptsetup status "$_dm_name" 2>/dev/null | awk '/[[:space:]]device:/{print $2}')
      if [ -z "$_backing_device" ]; then
        echo "    [ERROR] cannot determine backing device for $_dm_name"
        _failed_count=$(( _failed_count + 1 ))
        continue
      fi
      echo "    backing: $_backing_device"

      # ── KMS path ────────────────────────────────────────────────────
      if $_kms_enabled; then
        _sealed_data=$(find_siderokms_sealed_data "$_backing_device")
        if [ -n "$_sealed_data" ]; then
          # Build the KMS request using jq to guarantee valid JSON regardless of
          # special characters in _sealed_data or _node_uuid.
          _kms_request=$(jq -n \
            --arg uuid "$_node_uuid" \
            --arg data "$_sealed_data" \
            '{"node_uuid": $uuid, "data": $data}')
          _kms_response=$(grpcurl \
            -cacert /etc/ssl/certs/ca-certificates.crt \
            -import-path /tmp -proto kms.proto \
            -d "$_kms_request" \
            "$_kms_host" sidero.kms.KMSService/Unseal 2>/dev/null)
          if [ -n "$_kms_response" ]; then
            _kms_passphrase=$(printf '%s' "$_kms_response" | jq -r '.data // empty')
            if [ -n "$_kms_passphrase" ]; then
              _kms_key_b64=$(printf '%s' "$_kms_passphrase" | base64 | tr -d '\n')
              if try_key "$_backing_device" "$_dm_name" "$_kms_key_b64" "talos-kms"; then
                _discard_enabled=true
              else
                echo "    [WARN] KMS key did not unlock $_dm_name — will try static key if configured"
              fi
            else
              echo "    [WARN] KMS returned empty passphrase for $_dm_name"
            fi
          else
            echo "    [WARN] KMS unseal failed for $_dm_name — verbose output:"
            grpcurl -v -cacert /etc/ssl/certs/ca-certificates.crt \
              -import-path /tmp -proto kms.proto -d "$_kms_request" \
              "$_kms_host" sidero.kms.KMSService/Unseal || true
          fi
        else
          echo "    [INFO] no sideroKMS token in LUKS2 header of $_backing_device (scanned slots 0–31)"
        fi
      fi

      # ── Static key path (fallback or primary) ────────────────────────
      if ! $_discard_enabled && [ -n "$_static_key_b64" ]; then
        if try_key "$_backing_device" "$_dm_name" "$_static_key_b64" "talos-static"; then
          _discard_enabled=true
        else
          echo "    [WARN] static key did not unlock $_dm_name"
        fi
      fi

      if ! $_discard_enabled; then
        echo "    [ERROR] no key unlocked $_dm_name — allow-discards NOT enabled"
        _failed_count=$(( _failed_count + 1 ))
      fi
    fi

    $_discard_enabled && fstrim_dev "$_dm_name"
  done

  $_found_mapper || log_info "No /dev/mapper/luks2-* devices on this node"
  if [ "$_failed_count" -gt 0 ]; then
    echo "  [ERROR] $_failed_count Talos volume(s) failed. Check KMS connectivity, LUKS2 headers, and static key config."
    return 1
  fi
}
{{- end }}

# ── Main ─────────────────────────────────────────────────────────────────
echo "$(date) - luks-trim starting on $(cat /proc/sys/kernel/hostname)"
echo "  longhorn=${LONGHORN_ENABLED} talos=${TALOS_ENABLED} dry_run=${DRY_RUN:-false}"
_exit_code=0

if is_true "${LONGHORN_ENABLED:-false}"; then
  process_longhorn_volumes || _exit_code=1
fi
if is_true "${TALOS_ENABLED:-false}"; then
  process_talos_volumes || _exit_code=1
fi

if [ "$_exit_code" -ne 0 ]; then
  echo "$(date) - Done with ERRORS (exit $_exit_code) — review [ERROR] lines above."
else
  echo "$(date) - Done."
fi
exit "$_exit_code"
