# 1. Integration tests

Tests must run as a GitHub Actions workflow. The worker image used is configurable
(default: `latest` from ghcr.io/flip-flop-foundry/luks-trim/worker).

## Why Docker-based Talos is not sufficient

`talosctl cluster create` defaults to Docker containers as Talos nodes. Docker
containers run on overlayfs, which does not support the FITRIM ioctl. This means:

- `fstrim` inside the container returns success but no storage is reclaimed on the host.
- Deleting files in a container does not reflect in host-visible disk usage until the
  layer is garbage collected — not via TRIM.

This makes a Docker-based cluster unsuitable for verifying that fstrim actually
frees space, which is the core behaviour this chart exists to exercise.

## Required infrastructure: QEMU provisioner

GitHub Actions `ubuntu-latest` runners support nested KVM. `talosctl cluster create
--provisioner qemu` provisions real QEMU VMs with virtio-scsi disks. Using
`discard=unmap` on the virtual disk and a thin-provisioned qcow2 backing image
accurately reproduces the Proxmox/LVM-thin scenario:

> Deleting a file in the VM does not free space in the qcow2 image until the guest
> issues UNMAP/TRIM commands (i.e. fstrim runs).

The qcow2 image size on the runner's filesystem is the observable proxy for "host
storage consumed", equivalent to the LVM thin pool utilisation on Proxmox.

**Note**: `docker/setup-qemu-action@v3` is NOT suitable here. That action installs
QEMU user-space binfmt_misc handlers for cross-architecture container builds with
`docker buildx`. It does not install `qemu-system-x86_64` or enable VM execution.

The correct setup step is:
```yaml
- name: Install QEMU system emulator and KVM
  run: |
    sudo apt-get update
    sudo apt-get install -y qemu-system-x86 qemu-kvm
    # Grant the current user access to /dev/kvm (KVM is available on ubuntu-latest)
    sudo chmod 666 /dev/kvm
```

Reference: https://docs.siderolabs.com/talos/v1.13/getting-started/quickstart

## Test environment setup

The workflow must provision:

- QEMU via `apt-get install qemu-system-x86` (available on `ubuntu-latest`)
- `talosctl` — version configurable via workflow input, default: latest release
- A single-node Talos v1.13 cluster via `talosctl cluster create --provisioner qemu`
  with a thin-provisioned qcow2 disk and `discard=unmap`
- `kubectl` and `helm` pointed at the provisioned cluster
- Longhorn installed via Helm
- Four Longhorn StorageClasses:
  - `luks-global-key` — encrypted, uses chart global key
  - `luks-ns-key` — encrypted, uses namespace shared key
  - `luks-pvc-key` — encrypted, uses per-PVC secret (secret name = PVC name)
  - `no-encryption` — plain unencrypted Longhorn volume
- A Longhorn `RecurringJob` of type `filesystem-trim` scoped to all volumes
- The luks-trim chart installed with `dryRun: false`

### Observability helpers needed

| Metric | How to read |
|---|---|
| Talos/host disk usage | `du -sh` on the qcow2 image file from the runner |
| Longhorn "Actual Size" | `kubectl get volume -n longhorn-system -o jsonpath` or Longhorn API |
| Trigger Longhorn fstrim job | `kubectl create job --from=cronjob/<name>` |
| Trigger luks-trim | `kubectl create job --from=cronjob/luks-trim` |
| Read worker pod logs | `kubectl logs -l luks-trim/role=worker` |

## Main test sequence

1. Create one PVC per StorageClass and mount each into a test pod.
2. Write a 2 GiB file to each volume (`dd if=/dev/urandom ...`).
3. Assert: Longhorn Actual Size and qcow2 file size have grown by ~2 GiB each.
4. Delete the files. Assert: sizes do NOT change (confirming trim has not run).
5. Run luks-trim with `longhorn.enabled=true`, `talos.enabled=false`.
   Then trigger the Longhorn fstrim RecurringJob.
   Assert:
   - Longhorn Actual Size shrinks ~2 GiB per encrypted volume.
   - qcow2 file size is unchanged (Longhorn fstrim reclaims space within the volume,
     not from the VM disk layer).
   - Coordinator and all worker pods exited 0.
   - Worker pod logs contain no `[ERROR]` lines.
6. Write another 2 GiB file to each volume and delete it.
7. Run luks-trim with `longhorn.enabled=true`, `talos.enabled=true`.
   Assert:
   - Longhorn Actual Size shrinks (encrypted volumes).
   - qcow2 file size shrinks (Talos fstrim reclaims space from the VM disk).
   - All pods exited 0, no `[ERROR]` lines.
8. Write another 2 GiB file to each volume and delete it.
9. Re-run luks-trim with `dryRun: true` and assert no size changes occur and
   logs contain `[dry-run]` lines for every volume.


---

# 2. Support unencrypted volumes

Both Talos and Longhorn may have unencrypted volumes co-existing with encrypted ones.
The current script hard-codes the assumption that all volumes are LUKS2.

## Approach

Encryption status must be detected at runtime, not assumed from configuration.

- **Detection**: `cryptsetup isLuks <device>` exits 0 if the device has a LUKS2
  header, non-zero otherwise. This is fast (reads only the header) and has no
  side effects.
- **Longhorn path**: before attempting any key lookup, run `cryptsetup isLuks` on
  the device. If not LUKS, skip all key operations and go directly to `fstrim_dev`.
  The `fstrim_dev` function already works on plain dm or block devices.
- **Talos path**: `/dev/mapper/luks2-*` naming implies encryption, but the same
  isLuks check should be applied for safety. If Talos ever mounts an unencrypted
  volume under that path prefix, the script should handle it gracefully rather than
  failing with a cryptsetup error.

## Values impact

`longhorn.enabled` and `talos.enabled` continue to control whether each path runs.
No new values are needed — the detection is fully automatic within each path.

---

# 3. KMS server endpoint cannot be auto-detected from LUKS2 header

**Answer: No, the KMS endpoint is not stored in the LUKS2 header.**

The Talos `sideroKMS` LUKS2 token contains only `sealedData` — the key material
sealed by the KMS server. The KMS endpoint URL is part of the Talos machine
configuration (`machine.systemDiskEncryption.*.keys[].kms.endpoint`) and is not
written into the LUKS header.

The endpoint could theoretically be read from the Talos node config via the Talos
API (`talosctl get KMSConfig`), but that would require embedding talosctl credentials
(TLS client cert + key) into the chart, which is a significant security and
complexity trade-off. The Talos API also listens on port 50000 which is not
accessible from a Kubernetes pod by default.

**Resolution**: `talos.kmsEndpoint` remains a required value when `talos.enabled`
is true. Document this clearly. Close this issue as "by design".

---

# 4. Support additional Talos key types

Talos v1.13 supports four key kinds (ref: https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/disk-encryption):

| Kind | LUKS2 token type | Notes |
|---|---|---|
| `kms` | `sideroKMS` | **Currently supported** |
| `static` | None (direct keyslot) | Passphrase defined in machine config |
| `nodeID` | Likely `talos:nodeID` or similar | Derived from node UUID + partition label |
| `tpm` | TPM-sealed | Requires TPM hardware, out of scope |

## static key support

A `static` key is a plain passphrase stored in the Talos machine config. There is
no LUKS2 token associated with it — the passphrase is used directly as a keyslot
unlock. To support this in luks-trim, the operator would supply the passphrase via
a Kubernetes Secret (same mechanism as Longhorn global/namespace keys).

New values needed:
```yaml
talos:
  staticKey:
    enabled: false
    secretName: ""
    secretNamespace: ""  # defaults to chart namespace
    secretKey: "passphrase"
```

Runtime: if `staticKey.enabled`, fetch the secret and use it as the passphrase in
`try_key`. If `sideroKMS` token is not found and `staticKey` is configured, fall
back to the static key. This matches how Talos itself handles multiple key slots.

## nodeID key support

The `nodeID` key is derived from the node UUID and the partition label using an
HMAC function internal to Talos. Replicating this derivation outside of Talos
(in a shell script) requires knowing the exact algorithm. This needs research
against Talos source before implementation. Tracking separately.

## tpm key support

Requires TPM hardware and interaction with the TPM device from inside the worker
pod. Out of scope until there is a concrete use case.


# 5. Chart improvements

* Maybe we should have ability to add labels to the luks-trim NS for:

pod-security.kubernetes.io/enforce=privileged \
pod-security.kubernetes.io/audit=privileged \
pod-security.kubernetes.io/warn=privileged \


# 6. Test improvments

 * At the time of writing we dont have any tests for dry-run on new volumes (volumes that havent had discard enabled)
  * We should have test cases for this.