# TVK VM-backup hook sequencing — minimal repro (no Windows, no MSSQL)

Self-contained repro for the hook/QGA ordering behavior found during the
MSSQL app-consistency POC (2026-07-04, TVK 5.3.1). It uses a plain Fedora
containerdisk VM and a "probe" Hook whose log is a deterministic pass/fail
oracle, so a code change can be verified in minutes without building a
Windows + SQL Server environment.

**Validated end-to-end 2026-07-16** on TVK 5.3.1 / OCP 4.18 / OpenShift
Virtualization (Portworx CSI). Sample output below is from that run.

## What it demonstrates

Observed TVK 5.3.1 ordering for a KubeVirt VM backup with hooks:

```
pre-hook → QGA fsfreeze → CSI snapshot → post-hook → QGA thaw
```

Three findings, all captured by this repro:

1. **The post-hook runs while the guest is frozen.** QGA disables
   `guest-exec` in the frozen state, so a post-hook can never run anything
   in the guest — it would deadlock until its own timeout.
2. **The thaw waits for the post-hook**, so post-hook runtime directly
   extends the freeze window. (In the real MSSQL lab, a freeze held past
   ~60 s trips the SQL Server VSS writer timeout and the backup silently
   loses app-consistency — that end-to-end consequence is the only part
   that needs the Windows rig; see "Acceptance test" below.)
3. **The Hook `resourceVersion` pinned into the BackupPlan goes stale and
   the Backup status misreports it.** TVK's webhook pins the Hook's
   RV/uid into `BackupPlan.spec.hookConfig` at admission. After a Hook
   edit, backups **execute the live Hook content** (verified via the
   `PROBE_REVISION` marker) while `Backup.status.hookStatus` still reports
   the old, pinned resourceVersion — the audit trail claims a hook version
   that did not run.

## Prerequisites

- OpenShift Virtualization (KubeVirt) + CDI, and a StorageClass with CSI
  snapshot support that is either the cluster default or annotated
  `storageclass.kubevirt.io/is-default-virt-class: "true"` (the DataVolume
  uses the `spec.storage` API, which honors both; add
  `storageClassName` in `01-vm.yaml` to pick one explicitly). The root
  disk is a PVC so the backup does a real fsfreeze + CSI snapshot.
- TVK installed, with at least one working `Target`.
- Outbound registry access for `quay.io/containerdisks/fedora`.

## Run it

```sh
# 1. VM (namespace + DataVolume + VM). Import + boot + agent ≈ 3–5 min.
oc apply -f 01-vm.yaml
oc -n tvk-hook-seq-repro wait vmi seq-probe --for=condition=AgentConnected --timeout=15m

# 2. Probe hook, then the BackupPlan — EDIT 03 first: point the two
#    Target references at a Target on your cluster.
oc apply -f 02-hook.yaml
oc apply -f 03-backupplan.yaml
oc -n tvk-hook-seq-repro wait backupplan seq-probe-backupplan --for=jsonpath='{.status.status}'=Available --timeout=5m

# 3. Trigger a backup and wait for it to finish (~2–3 min for this VM).
oc create -f 04-backup.yaml
oc -n tvk-hook-seq-repro get backup -w

# 4. Read the oracle — the probe logs inside the launcher pod.
POD=$(oc -n tvk-hook-seq-repro get pod -l vm.kubevirt.io/name=seq-probe -o name | head -n1)
oc -n tvk-hook-seq-repro exec $POD -c compute -- \
  cat /var/tmp/tvk-seqprobe-pre.log /var/tmp/tvk-seqprobe-post.log
```

Both hook phases run the same three checks and always exit 0 (the backup
completes either way — the *log* is the verdict, which keeps the repro
deterministic on both broken and fixed builds). Logs append across runs;
match blocks by their `start` timestamps.

## Reading the result

| Log line | Broken ordering (5.3.1 behavior) | Correct ordering |
|---|---|---|
| `PRE fsfreeze-status(start)` | `{"return":"thawed"}` | `{"return":"thawed"}` |
| `PRE guest-exec` | `ALLOWED` | `ALLOWED` |
| `POST fsfreeze-status(start)` | **`{"return":"frozen"}`** | `{"return":"thawed"}` |
| `POST guest-exec` | **`BLOCKED` (guest-exec has been disabled)** | `ALLOWED` |
| `POST fsfreeze-status(+15s)` | **still `frozen`** → thaw is waiting on this very hook | `thawed` |

### Sample run (TVK 5.3.1, 2026-07-16 — broken ordering)

```
=== PRE start 2026-07-16T11:06:08Z  PROBE_REVISION=1
PRE fsfreeze-status(start): {"return":"thawed"}
PRE guest-exec: ALLOWED {"return":{"pid":1187}}
PRE fsfreeze-status(+15s): {"return":"thawed"}
=== PRE end 2026-07-16T11:06:23Z
=== POST start 2026-07-16T11:06:27Z  PROBE_REVISION=1
POST fsfreeze-status(start): {"return":"frozen"}
POST guest-exec: BLOCKED error: internal error: unable to execute QEMU agent command 'guest-exec': Command guest-exec has been disabled: the command is not allowed
POST fsfreeze-status(+15s): {"return":"frozen"}
=== POST end 2026-07-16T11:06:42Z
```

Cross-check the freeze window independently via the virt-launcher log —
KubeVirt logs the freeze/unfreeze API calls:

```sh
oc -n tvk-hook-seq-repro logs $POD -c compute | grep -E 'Freezed|Unfreezed'
```

Same run: `Freezed vmi` at `11:06:23.46` (immediately after PRE ended) and
`Unfreezed vmi` at `11:06:42.38` (< 1 s after POST ended) — the thaw waited
for the post-hook. On a fixed build, `Unfreezed` lands before `POST start`.

### resourceVersion pinning check (finding 3, no VM behavior involved)

1. Edit `02-hook.yaml`: change `PROBE_REVISION=1` to `=2` (both phases) and
   re-apply. Note the Hook's new `metadata.resourceVersion`.
2. Run another backup **without touching the BackupPlan**.
3. Compare three places:

```sh
oc -n tvk-hook-seq-repro get backupplan seq-probe-backupplan \
  -o jsonpath='{.spec.hookConfig.hooks[0].hook.resourceVersion}'   # still the OLD RV
oc -n tvk-hook-seq-repro get backup <name> \
  -o jsonpath='{.status.hookStatus.hookPriorityStatus[0].hooks[0].hook.resourceVersion}'  # reports the OLD RV
# ...but the probe log for this run prints PROBE_REVISION=2 — the NEW content ran.
```

Observed 2026-07-16 (TVK 5.3.1): execution follows the **live** Hook;
the pinned RV in the BackupPlan and the RV echoed into
`Backup.status.hookStatus` both stay stale. The defect is the audit
trail — the Backup records a hook version it did not execute. Expected
fix: report the resourceVersion actually fetched at execution time (or
reconcile the pin on Hook updates).

> Historical note: the 2026-07-04 MSSQL POC initially attributed a hook
> failure to the stale pin ("old hook re-ran"). This marker-based repro
> shows execution was live all along; that failure's real cause was
> finding 1 (guest-exec rejected while frozen).

## Acceptance test (the only part that needs Windows + MSSQL)

The customer-visible impact of findings 1–2 — a fragile VSS writer (SQL
Server) timing out when the freeze is held, losing the app-consistent
event signature — is documented with full evidence in the parent repo:

- `output/hook-poc-20260704.md` (+ raw logs/event captures alongside it)
- `manifests/hook-mssql-anchor.yaml` / `manifests/backupplan.yaml` — the
  production-shaped hook this probe is derived from
- `docs/lab-guide.md` — full Windows + SQL lab build, if you want to
  reproduce that end-to-end signature yourself (3197 freeze / 3198 thaw /
  18264 backup-complete ×7 in the guest Application event log)

Suggested flow: iterate on the fix against this Fedora probe, then run one
end-to-end MSSQL validation (we can also re-run it on our existing lab
against a candidate build).

## Cleanup

```sh
oc delete ns tvk-hook-seq-repro
```

(Backups already written to the Target are removed per your retention/target
policy, not by the namespace delete.)
