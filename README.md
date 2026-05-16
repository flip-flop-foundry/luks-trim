# luks-trim

## The Problem - No Trim Propagation

![Nested allocation problem](docs/animations/nested-allocation-problem.svg)

luks-trim solves two related issues: files deleted from Longhorn volumes and/or Talos volumes do not, by default, release that space back to the hypervisor. This means that if a cluster node is provisioned on thin/sparse storage, Proxmox/VMware will not detect that storage was released and will continue reserving space the node no longer needs.

### The Problem - Longhorn

Longhorn has an optional `RecurringJob` that can run filesystem trim on volumes. For encrypted volumes, discard is not auto-enabled out of the box (see [#5599](https://github.com/longhorn/longhorn/issues/5599)); and even for unencrypted volumes, reclaim does not always propagate through every lower layer unless trim/discard is also enabled and executed in the node/VM storage stack.


### The Problem - Talos

Talos is also a valid standalone use case (without Longhorn).

Today, Talos does not provide a built-in way to enable fstrim on a volume, or running it. Regardless of whether a volume is encrypted, a node that once pulled many images or wrote a lot to `emptyDir` will continue to appear to the hypervisor as using that space until trim is run.

Relevant upstream references:

- Talos feature request (open): https://github.com/siderolabs/talos/issues/8314
- Linked Talos implementation PR (open): https://github.com/siderolabs/talos/pull/9848
- Parent storage roadmap issue (open): https://github.com/siderolabs/talos/issues/13134

Important nuance from maintainers/community in #8314:

- Some fstrim functionality can be brought in via Talos system extensions.
- Talos supports some fstrim-related operations during disk wipes.
- A native integrated periodic solution is still tracked upstream.


## The Fix - luks-trim

![Nested allocation after trim propagation](docs/animations/nested-allocation-after-trim.svg)

Propagate trim across:

`Longhorn volume -> Talos volume -> VM sparse disk`

luks-trim can solve both these problems, or just one of them if that is what you need for your setup.

luks-trim enables discard on encrypted Longhorn/Talos volumes, runs fstrim on Talos volumes, and delegates Longhorn volume trimming to a Longhorn `RecurringJob`.

In short, on a scheduled interval, luks-trim will make sure any unallocated space is released to the layer below.




## What luks-trim does

- Runs as a scheduled CronJob coordinator that spawns one short-lived worker Job per selected node.
- Enables `allow-discards` on encrypted Longhorn volumes
- Enables `allow-discards` on Talos encrypted volumes, both system and `userVolumes`.
- Runs `fstrim` for Talos-mounted filesystems to propagate discard to the VM backing disk.
- Supports dry-run verification mode for key and connectivity checks.
- Handles mixed encrypted and unencrypted Longhorn/Talos volumes.
- Can be configured to set up fstrim for both or either Longhorn/Talos.
- Works on mounted/in-use volumes with little do no affect on other pods.

## What luks-trim does not do

- It does not execute Longhorn's own filesystem trim recurring job.
- Longhorn reclaim still requires a Longhorn `RecurringJob` of type `filesystem-trim`.
- It assumes a single Talos KMS endpoint per node when using KMS-based Talos keys (currently the first KMS server found is used).



## Key support

luks-trim supports several different key types for encrypted volumes:

 * Longhorn per NS keys
 * Longhorn per PVC keys
 * Longhorn global keys
 * Longhorn unencrypted
 * Talos static key
 * Talos KMS key
 * Talos unencrypted


## Quick start

Prerequisites:

- Kubernetes 1.27+
- Longhorn installed (if Longhorn enabled in the helm values)
- Talos nodes (only if enabling Talos system-volume processing)
- Helm 3

Create a values file (example):

```yaml
namespace: luks-trim

schedule: "0 2 * * 0"
timezone: "UTC"

dryRun: false

longhorn:
  enabled: true
  globalKey:
    enabled: true
    secretName: longhorn-global-key
    secretNamespace: longhorn-system
    secretKey: CRYPTO_KEY_VALUE # This is the key name in the secret, where the encryption key is stored

talos:
  enabled: true
  kmsEndpoint: "https://kms.example.com:50051" # Optional when talos.machineConfig.enabled=true and endpoint auto-detection is enabled.
```

Install:

```bash
helm upgrade --install luks-trim . -n luks-trim -f values.yaml
```

Run once immediately:

```bash
kubectl create job \
  --from=cronjob/luks-trim \
  -n luks-trim \
  luks-trim-manual-$(date +%s)
```

Watch worker logs:

```bash
kubectl logs -n luks-trim -l luks-trim/role=worker --tail=200 --prefix
```

Longhorn-only mode (non-Talos clusters):

```yaml
longhorn:
  enabled: true

talos:
  enabled: false
```

## Configuration reference

The full project behavior and configuration rationale are documented inline in [values.yaml](values.yaml).
That file is intentionally comment-heavy and should be treated as the authoritative reference.

## Notes for Longhorn users


For encrypted Longhorn volumes, the expected flow is:

1. `luks-trim` enables `allow-discards` on the volume.
2. Longhorn `filesystem-trim` RecurringJob performs the volume filesystem trim.
3. Subsequent execution of `luks-trim` runs Talos-level `fstrim` (if enabled) which releases the free storage from node filesystems down to VM backing storage.

### Create a Longhorn filesystem-trim recurring job

This is an example configuration for setting up the **required** Longhorn job.
Once luks-trim has enabled discard on encrypted volumes, this job performs the actual filesystem trim on Longhorn volumes.

Using the Longhorn UI:

1. Open Longhorn UI and go to `Recurring Jobs`.
2. Create a new recurring job with task `filesystem-trim`.
3. Set your cron schedule (for example weekly during low traffic).
  * Ideally this job runs after a luks-trim run has enabled `allow-discards` on encrypted volumes.
4. Assign the recurring job to volumes directly, or add it to a group such as `default`.

Using a manifest:

```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: fs-trim-weekly
  namespace: longhorn-system
spec:
  cron: "0 3 * * 0"
  task: "filesystem-trim"
  groups:
    - default
  retain: 1
  concurrency: 2
```

Apply it:

```bash
kubectl apply -f recurringjob-fs-trim-weekly.yaml
```

Then assign to a specific Longhorn volume if needed:

```bash
kubectl -n longhorn-system label volume/<VOLUME-NAME> recurring-job.longhorn.io/fs-trim-weekly=enabled
```

More details from Longhorn docs:

- https://longhorn.io/docs/1.11.2/snapshots-and-backups/scheduling-backups-and-snapshots/

## Technical overview (Longhorn + Talos both enabled)

This is the complete flow when both `longhorn.enabled=true` and `talos.enabled=true`.

### End-to-end flow

1. The cron job spawns a Coordinator which selects target nodes and creates per-node worker Jobs.
2. Worker discovers Longhorn devices under `/dev/longhorn/*`.
3. For encrypted Longhorn devices, key discovery order is:
global key -> per-PVC key -> namespace key list.
4. Worker applies persistent `allow-discards` on encrypted Longhorn dm-crypt mappings using `cryptsetup ... refresh --persistent`.
5. Worker discovers Talos unlock material:
KMS endpoint from `talos.kmsEndpoint` or machine config (when `talos.machineConfig.enabled=true`), plus optional static key.
6. Worker scans Talos LUKS mappings under `/dev/mapper/luks2-*`, finds `sideroKMS` token data (slots 0-31), unseals via KMS, and falls back to static key when configured.
7. Worker applies persistent `allow-discards` on Talos LUKS mappings.
8. Worker runs `fstrim` on Talos-mounted filesystems.
9. Longhorn `RecurringJob` with task `filesystem-trim` runs separately and trims Longhorn filesystems.
10. A later Talos-level `fstrim` run propagates those newly freed blocks from node filesystems down to VM/thin-backed storage.

### Why new encrypted Longhorn volumes often need two luks-trim runs

1. Run #1 enables discard flags, but encrypted Longhorn volumes are not trimmed by luks-trim itself.
2. Longhorn `filesystem-trim` must run to discard free blocks inside Longhorn volumes.
3. Those freed blocks then become reclaimable at the Talos filesystem layer.
4. Run #2 (or any later Talos-level fstrim run) is what commonly makes reclaim visible to VM sparse disks / thin pools / hypervisors.

### Troubleshooting checkpoints

1. Confirm Longhorn key discovery and discard enablement in worker logs:
`kubectl logs -n luks-trim -l luks-trim/role=worker --tail=-1 | grep -E "allow-discards|no matching key|Longhorn"`
2. Confirm Talos KMS/static path and machine-config detection in worker logs:
`kubectl logs -n luks-trim -l luks-trim/role=worker --tail=-1 | grep -E "machine config|talos-kms|talos-static|sideroKMS|KMS"`
3. Confirm Longhorn trim job completed:
`kubectl -n longhorn-system get recurringjobs.longhorn.io,jobs | grep filesystem-trim`
4. If reclaim is not visible in hypervisor after first cycle, run the second cycle explicitly:
run Longhorn `filesystem-trim`, then trigger `luks-trim` again.
5. Check for common hard failures in worker logs:
`[ERROR] no matching key found`, `[ERROR] no key unlocked`, `KMS unseal failed`, `not found in mount table`.

## Security implications of trim on encrypted filesystems

Enabling discard or trim on encrypted storage is a trade-off between reclaim efficiency and metadata leakage.

- Trim does not reveal plaintext blocks, but it can leak allocation patterns (which blocks are in use vs free).
- Over time, an attacker with low-level disk visibility may infer filesystem type, approximate used space, and deletion/write timing patterns.
- This is one reason Longhorn declined to auto-enable this behavior globally for encrypted volumes in the upstream issue above.
- If your threat model prioritizes plausible deniability or minimizing metadata side channels, do not enable discard.
- If your threat model prioritizes storage utilization over plausible deniability, luks-trim is for you.

Operational recommendations:

- Roll out with `dryRun: true` first, then enable live mode.
- Ensure the underlying storage stack fully supports discard before enabling (for example, on Proxmox, enable both `discard` and `ssd` on the virtual disk).

Security references:

- https://man7.org/linux/man-pages/man5/crypttab.5.html
- https://wiki.archlinux.org/title/Dm-crypt/Specialties#Discard/TRIM_support_for_solid_state_drives_(SSD)

