# Lab guide — MSSQL on OpenShift Virtualization with Trilio

**Audience:** anyone reproducing this lab end-to-end in their own OCP
cluster. **Estimated time:** ~45 min once the prereqs are in place
(most of which is waiting on the Trilio backup + restore wall clock).

---

## What this guide does

Walks you through the end-to-end scenario for backing up and restoring
Microsoft SQL Server running in a Windows VM on OpenShift
Virtualization (OCPv) with **Trilio for Kubernetes (TVK)** — including
**point-in-time recovery via continuous log shipping to S3**.

You will:

1. Configure the SQL Server inside an existing Windows VM for the chain
   (Full recovery, SYSTEM sysadmin, S3 credential, demo table).
2. Insert **pre-backup workload rows**.
3. Take a `COPY_ONLY .bak` anchor on the VM's data disk.
4. Trigger a Trilio backup of the VM. The snapshot captures the database
   files **and** the `.bak` anchor.
5. Insert **post-backup workload rows**.
6. Ship the transaction log to S3 (`BACKUP LOG ... TO URL`).
7. Restore the VM cross-namespace via a Trilio Restore CR.
8. From inside the restored VM: `RESTORE DATABASE WITH NORECOVERY` from
   the anchor, then `RESTORE LOG WITH RECOVERY` from S3 — bringing the
   database online at the post-backup state.
9. Verify all rows recovered with timestamps preserved.

If the final row count matches **pre + post + smoke**, you've proven
the whole chain. If it matches only **pre + smoke**, the snapshot
worked but log replay didn't — you're back to crash-consistent
behavior.

---

## What you'll prove

| Outcome | Evidence at the end |
|---|---|
| **VSS app-consistent capture** worked | Pre-backup rows present in restored DB with original timestamps |
| **Log chain replay** worked (true point-in-time recovery) | Post-backup rows present in restored DB with original timestamps |
| **Cross-namespace VM restore** worked | Restored VM is `Running` in a new namespace, `demo_db` `ONLINE` |
| **VSS handshake** worked | Application log on the original VM has Events 3197 (freeze), 3198 (thaw), 18264 (DB backed up), 8194 ×2 (benign workgroup ACL) |

---

## Prerequisites

This guide assumes the starting state:

- **OCP cluster** with OpenShift Virtualization (OCPv / KubeVirt) and
  Trilio for Kubernetes operator installed and licensed.
- **Windows VM** built per [`docs/windows-vm-prep.md`](windows-vm-prep.md).
  Specifically:
  - QGA installed and running.
  - SQL Server installed (named instance `MSSQLSERVER01` in the lab —
    substitute yours).
  - Data disk online as `D:` with default SQL paths relocated:
    `D:\SQLData`, `D:\SQLLog`, `D:\SQLBackup`.
  - SSH accessible via NodePort (you'll log in as `Administrator`).
- **An S3 bucket** you control (AWS, or NooBaa exposed via S3 endpoint)
  with an access key + secret available.
- **A TVK `Target`** in `trilio-system` pointed at a backup target
  (NFS, S3, etc.). The lab used `sa-nfs-cr-demo`. TVK auto-replicates
  Targets into namespaces whose BackupPlans reference them — you don't
  need to pre-create per-namespace Targets.
- **`oc` CLI** logged into the cluster with permission to create
  namespaces, Services, and Trilio CRs.

---

## Environment-specific values to gather before you start

Substitute these throughout the procedure. The bracketed values are
what the lab used — replace with yours.

| Value | Lab as-built | Your value |
|---|---|---|
| Namespace (original VM) | `mssql-vss-lab` | |
| Namespace (restore target) | `mssql-vss-restore-test` | |
| VM name | `win2k22-aqua-junglefowl-90` | |
| SQL instance | `MSSQLSERVER01` | |
| SSH NodePort + worker IP | `172.31.1.56:31256` | |
| SSH key | `~/.ssh/vbky-temp-key.pem` | |
| Data disk path | `D:\SQLBackup\` | |
| TVK Target name | `sa-nfs-cr-demo` (in `trilio-system`) | |
| TVK Retention Policy | `trilio-latest-retention-policy` (in `trilio-system`) | |
| Storage class (VMs) | `px-csi-replicated` (Portworx) | |
| Volume snapshot class | `px-csi-snapclass` | |
| S3 bucket | `mssql-vss-lab` | |
| S3 region | `us-east-1` | |
| S3 prefix | `lab` | |
| S3 endpoint host | `mssql-vss-lab.s3.us-east-1.amazonaws.com` | |

**Cluster-portability callouts:**

- Storage class names differ across clusters (ODF/Ceph, vSphere CSI,
  Portworx). Use whatever is `is-default-virt-class=true` for the VM,
  and the matching VolumeSnapshotClass.
- NodePort numbers are cluster-wide unique. The manifests in this repo
  let Kubernetes auto-assign; the lab uses `nodePort` omitted.
- If your Windows VM image is **Datacenter Evaluation**, expect the
  eval clock to interfere with longer labs — run `slmgr /rearm` before
  starting if the grace period is short.

---

## Driver legend

Each step in the procedure is tagged with one of these markers so you
know whether to do something or wait on Trilio.

| Marker | Meaning |
|---|---|
| **[TVK-AUTO]** | Trilio operator orchestrates automatically. |
| **[APPLY-CR]** | You apply a Backup/Restore CR. |
| **[MANUAL]** | Hand-run `sqlcmd` (you log into the VM and run the SQL yourself). |
| **[APP-WORKLOAD]** | Application writes (in this guide, stood in for by hand-run `sqlcmd INSERT`s). |

---

## Procedure

### Step 1 — Prepare SQL Server inside the original VM    `[one-time]`

SSH into the original VM:

```bash
ssh -i <your-ssh-key> -p <ssh-nodeport> Administrator@<worker-ip>
```

Open a `sqlcmd` session:

```cmd
sqlcmd -S .\MSSQLSERVER01 -E -C
```

(`-C` trusts SQL Server's self-signed certificate — required with
ODBC-18-based `sqlcmd`, which encrypts by default and otherwise fails
with a certificate-chain error. See `docs/windows-vm-prep.md` § 6.)

Run the setup SQL. Substitute your S3 credential details:

```sql
-- 1a. Verify demo_db exists and is in FULL recovery (default in our install)
SELECT name, recovery_model_desc FROM sys.databases WHERE name = 'demo_db';
GO

-- If missing or wrong, create and set:
-- CREATE DATABASE demo_db;
-- ALTER DATABASE demo_db SET RECOVERY FULL;
-- GO

-- 1b. Grant SYSTEM sysadmin (needed if you later automate via QGA-exec).
--     For customer-prod, use a least-privilege dedicated login instead.
ALTER SERVER ROLE sysadmin ADD MEMBER [NT AUTHORITY\SYSTEM];
GO

-- 1c. Create the S3 credential. Replace placeholders.
USE master;
GO
CREATE CREDENTIAL [s3://<bucket>.s3.<region>.amazonaws.com/<prefix>]
WITH IDENTITY  = 'S3 Access Key',
     SECRET   = '<access-key-id>:<secret-access-key>';
GO

-- 1d. Create the demo table and a smoke-test row
USE demo_db;
GO
CREATE TABLE dbo.writes (
  id INT IDENTITY(1,1) PRIMARY KEY,
  note NVARCHAR(64) NOT NULL,
  ts DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO
INSERT INTO dbo.writes (note) VALUES ('smoke-test');
GO

SELECT COUNT(*) AS baseline_count FROM dbo.writes;  -- expect 1
GO
```

**Success criteria:**
- `demo_db` shows `FULL` recovery.
- `dbo.writes` has 1 row.
- `CREATE CREDENTIAL` returns no error.

---

### Step 2 — Apply the BackupPlan against the VM    `[one-time, [APPLY-CR]]`

Create the namespace if needed, then apply the BackupPlan.
Manifest: [`manifests/backupplan.yaml`](../manifests/backupplan.yaml).
Substitute your VM name and Target name.

```bash
oc create namespace <ns-original>   # e.g. mssql-vss-lab

oc apply -f manifests/backupplan.yaml
```

The BackupPlan is **VM-scoped** (gvkSelector → your VM) and
**trigger-only** (no schedule). It points at the Target in
`trilio-system`; TVK will auto-replicate the Target into the
BackupPlan's namespace.

Verify:

```bash
oc -n <ns-original> get backupplan
# NAME                    READY
# mssql-vss-backupplan    true
```

**Success criteria:** `READY=true`.

---

### Step 3 — Insert pre-backup workload rows    `[APP-WORKLOAD]`

Still SSH'd into the original VM, in `sqlcmd`:

```sql
USE demo_db;
GO
DECLARE @i INT = 1;
WHILE @i <= 10
BEGIN
  INSERT INTO dbo.writes (note) VALUES (CONCAT('pre-anchor-', @i));
  SET @i += 1;
END
GO

SELECT COUNT(*) AS after_pre_anchor FROM dbo.writes;  -- expect 11
SELECT id, note, ts FROM dbo.writes ORDER BY id;
GO
```

**Success criteria:** Table has 11 rows (1 smoke + 10 pre-anchor),
all with current timestamps.

---

### Step 4 — Take the COPY_ONLY .bak anchor on the data disk    `[MANUAL]`

This `.bak` lives on `D:\SQLBackup\` so that the Trilio snapshot
in the next step captures it inside the VM image. `WITH COPY_ONLY`
ensures we don't perturb the log/differential chain.

```sql
BACKUP DATABASE demo_db
TO DISK = N'D:\SQLBackup\demo_db_anchor.bak'
WITH COPY_ONLY, INIT, NAME = 'demo_db COPY_ONLY anchor';
GO

-- Verify IsCopyOnly = 1 in the header
RESTORE HEADERONLY FROM DISK = N'D:\SQLBackup\demo_db_anchor.bak';
GO
```

**Success criteria:**
- `BACKUP DATABASE` reports success and ~hundreds of pages processed
  in <1 second.
- `RESTORE HEADERONLY` shows `IsCopyOnly = 1`,
  `BackupTypeDescription = 'Database'`, and a `LastLSN` value
  (write this down — you'll need it for verifying log replay later).

---

### Step 5 — Trigger the Trilio backup    `[APPLY-CR]` + `[TVK-AUTO]`

Apply the Backup CR. Manifest: [`manifests/backup.yaml`](../manifests/backup.yaml).
The `generateName` lets you re-apply for fresh runs without renaming.

```bash
oc create -f manifests/backup.yaml
# backup.triliovault.trilio.io/mssql-vss-backup-<suffix> created
```

Watch until it finishes (typical wall time: data-transfer-bound; the
lab's 20 GiB VM image took ~7m30s).

```bash
oc -n <ns-original> get backup -w
# NAME                          BACKUPPLAN              BACKUPTYPE  STATUS      SIZE
# mssql-vss-backup-<suffix>     mssql-vss-backupplan    Full        Available   ...
```

While it's running, on a second terminal SSH'd into the VM, you can
watch the VSS handshake live:

```cmd
wevtutil qe Application /q:"*[System[(EventID=3197 or EventID=3198 or EventID=18264 or EventID=8194)]]" /c:50 /rd:true /f:text
```

**Success criteria:**
- `Backup` CR reaches `STATUS=Available`.
- Windows Application log shows the **VSS signature**: 7× Event 3197
  (freeze), 7× 3198 (thaw), 7× 18264 ("Database backed up"), plus
  2× 8194 (`IVssWriterCallback` ACL — cosmetic on workgroup VMs).
  Counts may differ if you have other system databases excluded.

---

### Step 6 — Insert post-backup workload rows    `[APP-WORKLOAD]`

Back in the VM's `sqlcmd` session:

```sql
USE demo_db;
GO
DECLARE @i INT = 1;
WHILE @i <= 5
BEGIN
  INSERT INTO dbo.writes (note) VALUES (CONCAT('post-anchor-', @i));
  SET @i += 1;
END
GO

SELECT COUNT(*) AS after_post_anchor FROM dbo.writes;  -- expect 16
SELECT TOP 5 id, note, ts FROM dbo.writes ORDER BY id DESC;
GO
```

**Success criteria:** Table has 16 rows. The five newest are the
`post-anchor-*` rows. **Write down a couple of their timestamps** —
you'll check they survive the restore exactly.

---

### Step 7 — Ship the transaction log to S3    `[MANUAL]`

```sql
BACKUP LOG demo_db
TO URL = N's3://<bucket>.s3.<region>.amazonaws.com/<prefix>/demo_db_postbackup.trn'
WITH NAME = 'demo_db post-backup log';
GO

-- Verify the .trn header (LSN range)
RESTORE HEADERONLY FROM URL =
  N's3://<bucket>.s3.<region>.amazonaws.com/<prefix>/demo_db_postbackup.trn';
GO
```

**Success criteria:**
- `BACKUP LOG` reports success.
- `RESTORE HEADERONLY` shows `BackupTypeDescription = 'Transaction Log'`
  and an LSN range that **covers** the anchor's `LastLSN` from Step 4
  (specifically: `.trn.FirstLSN ≤ .bak.LastLSN+1 ≤ .trn.LastLSN+1`).
  If it doesn't, the chain is broken — review whether anything
  truncated the log between Step 4 and Step 7.

---

### Step 8 — Trigger the cross-namespace restore    `[APPLY-CR]` + `[TVK-AUTO]`

Capture the backup's storage location for the Restore CR:

```bash
oc -n <ns-original> get backup mssql-vss-backup-<suffix> \
   -o jsonpath='{.status.location}'
# e.g. f0c1db45.../abe56a06...
```

Edit [`manifests/restore.yaml`](../manifests/restore.yaml):

- Set `metadata.namespace` to your restore namespace
  (e.g. `mssql-vss-restore-test`).
- Set `spec.source.location` to the value you just captured.
- Set `spec.source.target.name` to your Target name.

Create the restore namespace and apply:

```bash
oc create namespace <ns-restore>
oc apply -f manifests/restore.yaml
```

Watch:

```bash
oc -n <ns-restore> get restore -w
# Typical wall time matches the backup; lab's 20 GiB took ~9m.
```

When the restore reaches `STATUS=Completed`, verify the VM is up:

```bash
oc -n <ns-restore> get vm,vmi
# vm     Running
# vmi    Running
```

**Success criteria:** restored VM is `Running` in the new namespace.
At this moment, the database inside the restored VM is at the
**snapshot state** (11 rows — the smoke + 10 pre-anchor). The
post-anchor rows are *not yet* recovered; we'll bring them in next.

---

### Step 9 — Add NodePort access services to the restored VM    `[one-time per restore]`

The BackupPlan is VM-scoped, so it didn't capture the launcher-pod
Services. We add ephemeral NodePort SSH/RDP services to reach the
restored VM. Manifest:
[`manifests/restore-access-services.yaml`](../manifests/restore-access-services.yaml).
The manifest's `metadata.namespace` should match `<ns-restore>`.

```bash
oc apply -f manifests/restore-access-services.yaml

oc -n <ns-restore> get svc
# Read the NodePort assigned to the SSH service.
```

SSH into the restored VM (same key and `Administrator` user — they
came along in the restored disk):

```bash
ssh -i <your-ssh-key> -p <restored-ssh-nodeport> Administrator@<worker-ip>
```

> **Restore-time portability note:** NodePorts are cluster-wide unique,
> so if your original VM still has its services up, the restored VM
> gets a *different* NodePort. That's expected.

**Success criteria:** you can SSH into the restored VM and reach
`sqlcmd -S .\MSSQLSERVER01 -E -C`.

---

### Step 10 — In-guest restore: rewind to RESTORING then replay log    `[MANUAL]`

Inside the restored VM, in `sqlcmd`:

```sql
-- Pre-flight: confirm restored DB is currently ONLINE (auto-recovered
-- from the snapshot) and at snapshot state.
SELECT name, state_desc, recovery_model_desc FROM sys.databases WHERE name = 'demo_db';
SELECT COUNT(*) AS at_snapshot_state FROM demo_db.dbo.writes;  -- expect 11
GO

-- 10a. Rewind: restore from the anchor .bak that came along on D:.
--      WITH NORECOVERY leaves the DB in RESTORING so we can apply logs.
USE master;
GO
RESTORE DATABASE demo_db
FROM DISK = N'D:\SQLBackup\demo_db_anchor.bak'
WITH NORECOVERY, REPLACE;
GO

-- 10b. Replay: pull the .trn from S3 and bring the DB online.
RESTORE LOG demo_db
FROM URL = N's3://<bucket>.s3.<region>.amazonaws.com/<prefix>/demo_db_postbackup.trn'
WITH RECOVERY;
GO
```

For a longer chain (multiple `.trn` files), the pattern is:

```sql
RESTORE LOG demo_db FROM URL = N's3://.../demo_db_log_001.trn' WITH NORECOVERY;
RESTORE LOG demo_db FROM URL = N's3://.../demo_db_log_002.trn' WITH NORECOVERY;
...
RESTORE LOG demo_db FROM URL = N's3://.../demo_db_log_NNN.trn' WITH RECOVERY, STOPAT = '2026-06-01 20:04:35';
GO
```

**Success criteria:**
- `RESTORE DATABASE` reports success and a few hundred pages
  processed in <1 second.
- `RESTORE LOG` reports success and a couple of dozen log records
  applied in <1 second.
- `demo_db` is now back to `ONLINE`.

---

### Step 11 — Validate    `[MANUAL]`

Still in `sqlcmd` on the restored VM:

```sql
USE demo_db;
GO

-- Total row count: 1 smoke + 10 pre + 5 post = 16
SELECT COUNT(*) AS total FROM dbo.writes;

-- Pre-backup rows preserved → VSS app-consistent capture worked.
SELECT COUNT(*) AS pre, MIN(ts) AS pre_min_ts, MAX(ts) AS pre_max_ts
FROM dbo.writes WHERE note LIKE 'pre-anchor-%';

-- Post-backup rows preserved with original timestamps → log chain
-- replay worked (true PITR, not crash-consistent rewind).
SELECT COUNT(*) AS post, MIN(ts) AS post_min_ts, MAX(ts) AS post_max_ts
FROM dbo.writes WHERE note LIKE 'post-anchor-%';

SELECT id, note, ts FROM dbo.writes ORDER BY id;
GO
```

**Success criteria:**
- Total = 16.
- Pre count = 10, with timestamps from Step 3 preserved.
- Post count = 5, with timestamps from Step 6 preserved.

If post-count is 0, the snapshot capture worked but the log chain
didn't. Re-check that the `.trn`'s LSN range covered the anchor's
LastLSN.

---

### Step 12 — Cleanup

```bash
# Remove the restore namespace (VM, PVCs, services, everything).
oc delete namespace <ns-restore>

# Keep the Trilio backup; it's small and useful for re-running.
# Or delete it:
# oc -n <ns-original> delete backup mssql-vss-backup-<suffix>
```

On the original VM:

```sql
-- Optional: clear out demo writes if you want a clean start for the next run.
USE demo_db;
TRUNCATE TABLE dbo.writes;
INSERT INTO dbo.writes (note) VALUES ('smoke-test');
GO
```

Don't delete the `.bak` on `D:\SQLBackup\` and the `.trn` in S3 unless
you want to start completely fresh — they're harmless to keep and
make a re-run cheap.

---

## Troubleshooting

**`BACKUP DATABASE` errors with permission denied on `D:\SQLBackup\`.**
Check the SQL service account has write access to that folder. With
default install + `xp_instance_regwrite` relocation per
`docs/windows-vm-prep.md`, this should be fine — but if you moved the
directory manually, NTFS ACLs may not have followed.

**`CREATE CREDENTIAL` fails with name collision.**
A credential of the same name already exists. `DROP CREDENTIAL
[s3://...]` first, or `CREATE OR ALTER CREDENTIAL`.

**`RESTORE LOG` fails with "LSN gap" or "log file is too early".**
The `.trn`'s `FirstLSN` is greater than the anchor's `LastLSN + 1`.
Something truncated the log between Step 4 and Step 7. Re-run from
Step 4 with no `BACKUP LOG` in between.

**VSS handshake produces fewer events than expected.**
Run `vssadmin list writers` from an elevated PowerShell on the
original VM. All 12 writers should be `Stable / No error`. If
`SqlServerWriter` is missing or errored, the SQL VSS Writer service
(`SQLWriter`) probably isn't running. Start it.

**8194 events ("`IVssWriterCallback`" ACL).**
Cosmetic — happens on workgroup-joined VMs. Doesn't affect SQL Server's
participation in the snapshot. Domain-joining the VM removes them.

**Restored VM is `Running` but `demo_db` is `RECOVERY_PENDING`.**
SQL couldn't auto-recover from the snapshot state — usually means
the `.ldf` and `.mdf` didn't come from the same point in time. Check
that both files live on the same PVC (they should, if you followed
`docs/windows-vm-prep.md`). If they're on separate PVCs, the snapshot
isn't atomic across them and you can't recover at all.

**Windows eval expires mid-lab.**
If you're running a Datacenter Evaluation image, run `slmgr /xpr`
inside the VM to see your grace period. `slmgr /rearm` + reboot
extends it (limited rearms available).

---

## Appendix A — Manifests

The four manifests this guide applies. All are present in
[`manifests/`](../manifests/) in this repo.

### `manifests/backupplan.yaml`

```yaml
apiVersion: triliovault.trilio.io/v1
kind: BackupPlan
metadata:
  name: mssql-vss-backupplan
  namespace: mssql-vss-lab          # ← your <ns-original>
spec:
  backupConfig:
    target:
      apiVersion: triliovault.trilio.io/v1
      kind: Target
      name: sa-nfs-cr-demo           # ← your Target name
      namespace: trilio-system
    retentionPolicy:
      apiVersion: triliovault.trilio.io/v1
      kind: Policy
      name: trilio-latest-retention-policy
      namespace: trilio-system
  snapshotConfig:
    target:
      apiVersion: triliovault.trilio.io/v1
      kind: Target
      name: sa-nfs-cr-demo
      namespace: trilio-system
  backupPlanComponents:
    customSelector:
      selectResources:
        gvkSelector:
          - groupVersionKind:
              group: kubevirt.io
              kind: VirtualMachine
              version: v1
            objects:
              - win2k22-aqua-junglefowl-90   # ← your VM name
```

### `manifests/backup.yaml`

```yaml
apiVersion: triliovault.trilio.io/v1
kind: Backup
metadata:
  generateName: mssql-vss-backup-
  namespace: mssql-vss-lab          # ← your <ns-original>
spec:
  type: Full
  backupPlan:
    apiVersion: triliovault.trilio.io/v1
    kind: BackupPlan
    name: mssql-vss-backupplan
    namespace: mssql-vss-lab
```

### `manifests/restore.yaml`

```yaml
apiVersion: triliovault.trilio.io/v1
kind: Restore
metadata:
  generateName: mssql-vss-restore-
  namespace: mssql-vss-restore-test  # ← your <ns-restore>
spec:
  restoreFlags:
    skipIfAlreadyExists: true
  source:
    type: Location
    location: <captured-from-backup.status.location>
    target:
      apiVersion: triliovault.trilio.io/v1
      kind: Target
      name: sa-nfs-cr-demo            # ← your Target name
      namespace: trilio-system
```

### `manifests/restore-access-services.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mssql-vss-restore-ssh
  namespace: mssql-vss-restore-test    # ← your <ns-restore>
spec:
  type: NodePort
  selector:
    vm.kubevirt.io/name: win2k22-aqua-junglefowl-90   # ← your VM name
  ports:
    - name: ssh
      port: 22
      targetPort: 22
      protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: mssql-vss-restore-rdp
  namespace: mssql-vss-restore-test
spec:
  type: NodePort
  selector:
    vm.kubevirt.io/name: win2k22-aqua-junglefowl-90
  ports:
    - name: rdp
      port: 3389
      targetPort: 3389
      protocol: TCP
```

---

## Appendix B — Sequence at a glance

```
┌──────────────────────────────────────────────────────────────┐
│ ORIGINAL VM (ns: <ns-original>)                              │
│                                                              │
│  Step 1: prep SQL (recovery model, sysadmin, credential, DB) │
│  Step 2: apply BackupPlan                                    │
│  Step 3: INSERT × 10 "pre-anchor"                            │
│  Step 4: BACKUP DATABASE WITH COPY_ONLY → D:\SQLBackup\      │
│  Step 5: apply Backup CR ──► Trilio snapshots the VM         │
│                              (captures .bak inside the image)│
│  Step 6: INSERT × 5 "post-anchor"                            │
│  Step 7: BACKUP LOG TO URL → S3 (.trn)                       │
└──────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌──────────────────────────────────────────────────────────────┐
│ RESTORED VM (ns: <ns-restore>)                               │
│                                                              │
│  Step 8: apply Restore CR ──► VM rehydrated cross-NS         │
│                               (.bak comes along on D:)       │
│  Step 9: apply NodePort access services                      │
│  Step 10a: RESTORE DATABASE WITH NORECOVERY from .bak        │
│  Step 10b: RESTORE LOG WITH RECOVERY from S3 .trn            │
│  Step 11: verify 16 rows; timestamps preserved               │
└──────────────────────────────────────────────────────────────┘
```

---

## References

- Windows VM build prerequisite: [`docs/windows-vm-prep.md`](windows-vm-prep.md).
- Trilio manifests applied by this guide: [`manifests/`](../manifests/).
