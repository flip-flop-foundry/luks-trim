# luks-trim

## The Problem - No Trim Propagation

![Nested allocation problem](docs/animations/nested-allocation-problem.svg)

luks-trim solves two related issues, files deleted from longhorn volumes and/or talos volumes do not by default release that space back to the hypervisor. This means that if the cluster node is provishioned on thin/sparse storage, proxmox/vmware will not be aware that the cluster node has release some stoage and will continue reserve it for a node that doesnt need it.

### The Problem - Longhorn

Longhorn does have an optional ```RecurringJob``` that can be made to run fstrim on volumes, but it [wont run on encrypted filesystems](https://github.com/longhorn/longhorn/issues/5599) and if run on unencrypted filesystems it still doesnt propagte information about the now unalocated space all the way to the hypervisor


### The Problem - Talos

Talos has no built in posibility to enable fstrim on a volume, or running it. Regardless if it is encrypted or not. A node that once pulled in a bunch of Images, wrote a lot to emptyDir and has since deleted that, will still appear to the hypervisor to use atleast that much space for ever.


## The Fix - luks-fstrim

![Nested allocation after trim propagation](docs/animations/nested-allocation-after-trim.svg)

Propagate trim across:

`Longhorn volume -> Talos volume -> VM sparse disk`

luks-fstrim can solve both these problems, or just one of them if that is what you need for your setup.

luks-fstrim enables fstrim on encrypted longhorn/talos volumes, runs fstrim on talos volumes and hands fstrim of longhorn volumes over to longhorn ```RecurringJob```. 

In short, on a scheduled interval, luks-trim will make sure any unallocated space is released to the layer below.




## What luks-trim does

- Runs as a scheduled CronJob coordinator that spawns one short-lived worker Job per selected node.
- Enables `allow-discards` on encrypted Longhorn volumes
- Enables `allow-discards` on Talos encrypted volumes, both system and uservolumes
- Runs `fstrim` for Talos-mounted filesystems to propagate discard to the VM backing disk.
- Supports dry-run verification mode for key and connectivity checks.
- Handles mixed encrypted and unencrypted Longhorn/Talos volumes.
- Can be configured to setup fstrim for both or either longhorn/talos


## What luks-trim does not do

- It does not execute Longhorn's own filesystem trim recurring job.
- Longhorn reclaim still requires a Longhorn `RecurringJob` of type `filesystem-trim`.
- It assumes a single Talos KMS endpoint per node when using KMS-based Talos keys.
  - Currently the first KMS server found will be used



## Key support

luks-fstrim supports several different key types for encrypted volumes:

 * Longhorn per NS keys
 * Longhorn per PVC keys
 * Longhorn global keys
 * Longhorn unencrypted
 * Talos static key
 * Talos kms key
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
  kmsEndpoint: "https://kms.example.com:50051" # This should not be needed, as luks-fstrim attempts to auto detect this.
```

Install:

```bash
helm upgrade --install luks-trim . -n luks-trim -v values.yaml
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
3. luks-trim run Talos-level `fstrim` which reclaims from node filesystems down to VM backing storage.

### Create a Longhorn filesystem-trim recurring job

This is example configuration for setting up the **required** longhorn job.
Once luks-trim has enabled discard/fstrim on encrypted volumes, this job actually runs the fstrim.

Using the Longhorn UI:

1. Open Longhorn UI and go to `Recurring Jobs`.
2. Create a new recurring job with task `filesystem-trim`.
3. Set your cron schedule (for example weekly during low traffic).
   * Ideally this job runs before the luks-trim job
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

## Security implications of trim on encrypted filesystems

Enabling discard or trim on encrypted storage is a trade-off between reclaim efficiency and metadata leakage.

- Trim does not reveal plaintext blocks, but it can leak allocation patterns (which blocks are in use vs free).
- Over time, an attacker with low-level disk visibility may infer filesystem type, approximate used space, and deletion/write timing patterns.
- This is one reason Longhorn declined to auto-enable this behavior globally for encrypted volumes in the upstream issue above.
- If your threat model prioritizes plausible deniability or minimizing metadata side channels, do not enable discard.
- If your threat model prioritizes storage utilization over plausible deniability, luks-trim is for you.

Operational recommendations:

- Roll out with `dryRun: true` first, then enable live mode.
- Ensure underlying storage stack fully supports discard before enabling
  - For example on proxmox you need to enable both "discard" and "ssd" on the VHD.

Security references:

- https://man7.org/linux/man-pages/man5/crypttab.5.html
- https://wiki.archlinux.org/title/Dm-crypt/Specialties#Discard/TRIM_support_for_solid_state_drives_(SSD)

## Development and CI

- Integration workflow: [.github/workflows/integration-test.yml](.github/workflows/integration-test.yml)
- Talos dev debug workflow (branch/worktree debugging): [.github/workflows/talos-dev-debug.yml](.github/workflows/talos-dev-debug.yml)
- Helper script for GitHub Actions loops: [scripts/gha-loop.sh](scripts/gha-loop.sh)


