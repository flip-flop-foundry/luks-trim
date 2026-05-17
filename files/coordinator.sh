# All required tools (curl, jq) are pre-installed in the custom
# Ubuntu worker image — no runtime package downloads needed.

KUBE_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
KUBE_CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
KUBE_API=https://kubernetes.default.svc
RUN_TS=$(date +%s)

log_info() {
  echo "  [INFO] $*"
}

log_error() {
  echo "  [ERROR] $*"
}

sanitize_node_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '._' '--' | cut -c1-40
}

build_nodes_api_url() {
  if [ -n "$LABEL_SELECTOR" ]; then
    printf '%s' "$KUBE_API/api/v1/nodes?labelSelector=$(printf '%s' "$LABEL_SELECTOR" | jq -sRr @uri)"
  else
    printf '%s' "$KUBE_API/api/v1/nodes"
  fi
}

is_excluded_node() {
  _node_name="$1"
  printf '%s' "$EXCLUDED_NODES" | grep -qxF "$_node_name"
}

echo "$(date) - luks-trim coordinator starting"
echo "  longhorn=${LONGHORN_ENABLED} talos=${TALOS_ENABLED}"

# Build the label-selector query parameter.
# nodeLabelSelector is baked in at render time; empty = no filter.
LABEL_SELECTOR={{ .Values.nodeLabelSelector | quote }}
NODE_URL=$(build_nodes_api_url)

NODE_NAMES=$(curl -sf --cacert "$KUBE_CA" \
  -H "Authorization: Bearer $KUBE_TOKEN" \
  "$NODE_URL" | jq -r '.items[].metadata.name')

[ -z "$NODE_NAMES" ] && { log_error "no nodes returned from API"; exit 1; }

# Build excluded-nodes lookup (newline-separated list baked in at render time).
EXCLUDED_NODES={{ if .Values.excludedNodes }}{{ join "\n" .Values.excludedNodes | quote }}{{ else }}""{{ end }}

# Values rendered by Helm are static for this run, so build JSON once.
TOLERATIONS_JSON={{ .Values.tolerations | toJson | squote }}
WORKER_RESOURCES_JSON={{ .Values.workerResources | toJson | squote }}
IMAGE_PULL_SECRETS_JSON={{ .Values.imagePullSecrets | toJson | squote }}
POD_ANNOTATIONS_JSON={{ .Values.podAnnotations | toJson | squote }}

submit_failures=0
for NODE_NAME in $NODE_NAMES; do
  # Apply excludedNodes denylist.
  if is_excluded_node "$NODE_NAME"; then
    log_info "Skipping excluded node: $NODE_NAME"
    continue
  fi

  SAFE_NODE_NAME=$(sanitize_node_name "$NODE_NAME")
  JOB_NAME="luks-trim-${SAFE_NODE_NAME}-${RUN_TS}"
  log_info "Submitting Job $JOB_NAME -> $NODE_NAME"

  JOB_SPEC=$(jq -n \
    --arg name       "$JOB_NAME" \
    --arg node       "$NODE_NAME" \
    --arg ns         "$CHART_NAMESPACE" \
    --arg ts         "$RUN_TS" \
    --arg image      "$WORKER_IMAGE" \
    --arg pullpol    "$WORKER_IMAGE_PULL_POLICY" \
    --arg sa         "$SA_NAME" \
    --arg cm         "$SCRIPT_CONFIGMAP" \
    --argjson ttl    "$WORKER_TTL" \
    --arg le         "$LONGHORN_ENABLED" \
    --arg te         "$TALOS_ENABLED" \
    --arg kms        "$KMS_ENDPOINT" \
    --arg gke        "$GLOBAL_KEY_ENABLED" \
    --arg gkns       "$GLOBAL_KEY_NS" \
    --arg gksec      "$GLOBAL_KEY_SECRET" \
    --arg gkfield    "$GLOBAL_KEY_FIELD" \
    --arg devpath    "$LONGHORN_DEVICE_PATH" \
    --arg dr         "$DRY_RUN" \
    --arg tske       "$TALOS_STATIC_KEY_ENABLED" \
    --arg tskns      "$TALOS_STATIC_KEY_NS" \
    --arg tsksec     "$TALOS_STATIC_KEY_SECRET" \
    --arg tskfield   "$TALOS_STATIC_KEY_FIELD" \
    --arg mcpath     "${TALOS_MC_PATH:-}" \
    --argjson tols   "$TOLERATIONS_JSON" \
    --argjson res    "$WORKER_RESOURCES_JSON" \
    --argjson ips    "$IMAGE_PULL_SECRETS_JSON" \
    --argjson anns   "$POD_ANNOTATIONS_JSON" \
    '{
      apiVersion: "batch/v1",
      kind: "Job",
      metadata: {
        name: $name,
        namespace: $ns,
        labels: {
          "app.kubernetes.io/name": "luks-trim",
          "luks-trim/role": "worker",
          "luks-trim/run": $ts,
          "luks-trim/node": $node
        }
      },
      spec: {
        ttlSecondsAfterFinished: $ttl,
        backoffLimit: 0,
        template: {
          metadata: {
            labels: {
              "app.kubernetes.io/name": "luks-trim",
              "luks-trim/role": "worker",
              "luks-trim/node": $node
            },
            annotations: (if $anns | length > 0 then $anns else null end)
          },
          spec: {
            nodeName: $node,
            serviceAccountName: $sa,
            hostPID: true,
            restartPolicy: "Never",
            tolerations: $tols,
            imagePullSecrets: (if $ips | length > 0 then $ips else null end),
            containers: [{
              name: "luks-trim",
              image: $image,
              imagePullPolicy: $pullpol,
              securityContext: {privileged: true},
              resources: $res,
              env: ([
                {name: "LONGHORN_ENABLED",           value: $le},
                {name: "TALOS_ENABLED",              value: $te},
                {name: "KMS_ENDPOINT",               value: $kms},
                {name: "GLOBAL_KEY_ENABLED",         value: $gke},
                {name: "GLOBAL_KEY_NS",              value: $gkns},
                {name: "GLOBAL_KEY_SECRET",          value: $gksec},
                {name: "GLOBAL_KEY_FIELD",           value: $gkfield},
                {name: "LONGHORN_DEVICE_PATH",       value: $devpath},
                {name: "DRY_RUN",                    value: $dr},
                {name: "TALOS_STATIC_KEY_ENABLED",   value: $tske},
                {name: "TALOS_STATIC_KEY_NS",        value: $tskns},
                {name: "TALOS_STATIC_KEY_SECRET",    value: $tsksec},
                {name: "TALOS_STATIC_KEY_FIELD",     value: $tskfield}
              ] + (if $mcpath != "" then [{name: "TALOS_MC_PATH", value: $mcpath}] else [] end)),
              command: ["/bin/sh", "/scripts/trim.sh"],
              volumeMounts: ([
                {name: "dev",         mountPath: "/dev"},
                {name: "host-ssl",    mountPath: "/etc/ssl/certs", readOnly: true},
                {name: "trim-script", mountPath: "/scripts",       readOnly: true}
              ] + (if $mcpath != "" then [{name: "host-talos-state", mountPath: $mcpath, readOnly: true}] else [] end))
            }],
            volumes: ([
              {name: "dev",         hostPath: {path: "/dev"}},
              {name: "host-ssl",    hostPath: {path: "/etc/ssl/certs", type: "Directory"}},
              {name: "trim-script", configMap: {name: $cm, defaultMode: 493}}
            ] + (if $mcpath != "" then [{name: "host-talos-state", hostPath: {path: {{ .Values.talos.machineConfig.hostPath | default "/system/state" | quote }}, type: "Directory"}}] else [] end))
          }
        }
      }
    }')

  curl -sf -X POST \
    --cacert "$KUBE_CA" \
    -H "Authorization: Bearer $KUBE_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$JOB_SPEC" \
    "$KUBE_API/apis/batch/v1/namespaces/$CHART_NAMESPACE/jobs" \
    && echo "    Created" \
    || { echo "    [ERROR] Job creation failed for $NODE_NAME"; submit_failures=$(( submit_failures + 1 )); }
done

if [ "$submit_failures" -gt 0 ]; then
  echo "[ERROR] $submit_failures per-node Job(s) failed to submit. Affected nodes did not run trim."
  exit 1
fi
echo "$(date) - All per-node Jobs submitted. Workers self-delete after ${WORKER_TTL}s."
