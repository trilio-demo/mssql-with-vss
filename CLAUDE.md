# restore-mssql-with-vss — Project Context for Claude Code

## User
Vince Button — Solution Architect at Trilio. Pre-sales technical role. Builds
lab POCs to validate sales narratives and answer customer technical questions.
Deep storage / data protection background; works mostly on OpenShift and OpenStack.

## This Project
A lab POC to demonstrate that **Trilio for Kubernetes (TVK)** can take
**application-consistent** backups of **Microsoft SQL Server** running inside
a **Windows VM on OpenShift Virtualization (OCPv / KubeVirt)** — and recover
from them, including surgical file-level restore. The lab exists to answer a
specific technical inquiry from Erick Saidon (Infrastructure Engineer, City of
Delray Beach), a re-entry opportunity after losing the deal to Veeam in
October 2025.

Two related deliverables:
1. **Lab evidence** proving the QGA → Windows VSS Writer handshake works
   (Windows Event Viewer freeze/thaw events, clean MS SQL recovery,
   FLR of `.mdf` / `.ldf` / `.bak` from a backup).
2. **Captured material** (sequence notes, screenshots, command transcripts,
   architecture diagram) structured for a **separate blog-writing agent**
   that lives outside this repo and consumes the bundle in `output/`.

- **Full requirements:** [docs/requirements.md](docs/requirements.md)
- **Windows VM prep guide:** [docs/windows-vm-prep.md](docs/windows-vm-prep.md)
  *(self-contained reference — Vince uses this offline to build the SQL VM)*

## Input / Output
- **Input:**
  - Customer/conversation context in `collateral/` (one-time, gitignored).
  - Live lab: OCPv cluster, Windows Server VM, MS SQL Server, Trilio operator.
- **Output:** Lab evidence bundle in `output/` — event-log captures,
  Trilio UI screenshots, restore transcripts, sequence/architecture diagrams.
  Also: a customer-facing technical response to Erick once the lab is verified.

## Interface
Claude Code CLI, plus hands-on cluster work (`oc`, Trilio UI, RDP/console into
the Windows VM).

## Key Integrations
- OpenShift Virtualization (OCPv / KubeVirt)
- Trilio for Kubernetes (TVK) operator
- Microsoft SQL Server (Developer or Standard edition, in a Windows Server VM)
- QEMU Guest Agent (QGA) — must be installed in the Windows VM
- CSI snapshot-capable storage (lab default: ODF/Ceph; production target uses Portworx + Pure + Exagrid)

## Tech / Tooling
- `oc` / `kubectl` and YAML manifests for cluster work
- PowerShell and `sqlcmd` inside the Windows VM
- Mermaid for diagrams in markdown
- **Python 3.13** for the write generator — pyenv (`3.13.13`) + uv. Project
  shell is set up (`pyproject.toml`, `.python-version`, `uv.lock`, `.venv/`).
  No deps yet — SQL Server driver (`pymssql` vs `pyodbc`) gets added when we
  write the generator and know whether it runs from Mac, in-cluster, or in
  the VM itself.

## How to Work With This User
- Be direct and concise. No hand-holding.
- Don't decide demo scope unilaterally — Vince has the customer/sales context.
- Prioritize lab-validated claims over theoretical ones. If we haven't seen it
  in Event Viewer or the Trilio UI, don't write it down as fact.
- Capture as we go — every interesting screenshot/log lands in `output/` with
  a descriptive filename, so the blog agent has raw material to work from.
- Confirm before destructive cluster actions (delete VM, delete backup target,
  uninstall operator).

---

## Environment
- First started: CLI
- Date: 2026-05-06

## Project Status
- [x] Demo scope locked: **DB-only with Python write generator (inside the Windows VM)**
- [x] Cluster locked: **`ocp-px`** (OCP 4.18.19, OCPv + Trilio already installed; Portworx storage)
- [x] Python tooling set up (pyenv 3.13.13 + uv) — driver: `pyodbc` + MS ODBC Driver 18 (added when generator is written)
- [x] Trilio licensed on all clusters
- [x] Windows version: **Server 2022** (DataSource `win2k22` already defined on cluster)
- [x] VM storage class: **`px-csi-replicated`** (Portworx) — annotated `is-default-virt-class=true`; snapshots via `px-csi-snapclass`
- [x] Build approach: **fresh namespace `mssql-vss-lab`, fresh VM from Win2k22 golden image** via engineering's flow
- [x] PDF inspector tool: `src/pdf_inspect.py` (pymupdf) — reusable for any collateral PDF; supports `--render-all`
- [x] `docs/windows-vm-prep.md` rewritten for the golden-image flow (verbatim Sysprep `unattend.xml` from engineering guide, post-boot config, NodePort exposure, SQL install)
- [x] Golden image uploaded as DataVolume `win2k22` (Portworx, RWO block — Ceph SC was orphaned)
- [x] VM created from catalog template — name **`win2k22-aqua-junglefowl-90`** in `mssql-vss-lab`
- [x] Secure Boot + SMM patched off (image bootloader signing chain didn't match OVMF secboot trust); Windows booted, Sysprep ran clean
- [x] QGA verified running, RDP enabled, OpenSSH Server installed and running (password auth)
- [x] NodePort exposure: RDP `31211`, SSH `31256` on worker IPs (e.g. `172.31.1.56`)
- [x] SSH Service selector fixed (`vm.kubevirt.io/name: win2k22-aqua-junglefowl-90` — prep doc YAML had used `kubevirt.io/domain: mssql-lab` which doesn't match the launcher pod's labels)
- [x] MS SQL Developer Edition installed (**SQL Server 2025**, named instance `MSSQLSERVER01`, default instance was *not* selected) — confirmed via screenshot `collateral/MSSQL-installed-screen.png`
- [x] **Windows eval rearmed (2026-05-24).** Engineering golden image is Datacenter Evaluation, build `20348.fe_release.210507` (May 2021). `slmgr /rearm` + reboot took the VM out of `Notification` mode; `slmgr /xpr` now shows `Initial grace period ends 6/3/2026 4:27 PM` — only ~10 days, not the documented 180 (rearm-after-expiry quirk). Reboot loop expected to be dead; verify with `oc logs -n openshift-cnv deployment/virt-controller --since=2m | grep <vm>` over the next ~70 min. 4 rearms remaining.
- [x] **Data disk online (2026-05-25).** 20 GiB virtio disk `disk-copper-cheetah-64` initialized in Windows as **`D:`** (NTFS, label `Data`). CDs (`virtio-win`, `sysprep`) detached. SQL default Data/Log/Backup paths relocated to `D:\SQL{Data,Log,Backup}\` via `xp_instance_regwrite`. Smoke test passed: `demo_db.mdf` / `demo_db_log.ldf` / `demo_db_smoke.bak` all on D:.
- [ ] Hostname not renamed (still `WIN-1LU5F0AC846`). Cosmetic only; skip or rename later via `Rename-Computer`.
- [ ] SSMS install (deferred — `sqlcmd -C` works fine for everything we need; revisit if a customer-facing screenshot demands it).
- [x] Done-state verified: `SQLWriter` + `MSSQL$MSSQLSERVER01` services Running; `sqlcmd -S .\MSSQLSERVER01 -E -C` returns banner; `demo_db` ONLINE.
- [x] SSH public-key auth working — root cause was `administrators_authorized_keys` written as UTF-16 LE + BOM (PowerShell/editor default); rewritten as plain ASCII via `[System.IO.File]::WriteAllText(..., [System.Text.Encoding]::ASCII)`. Fix + verification baked into `docs/windows-vm-prep.md` § 4e.
- [x] **Trilio BackupPlan created (2026-05-25).** `mssql-vss-lab/mssql-vss-backupplan` — VM-scoped (gvkSelector → `win2k22-aqua-junglefowl-90`), target `sa-nfs-cr-demo` (auto-replicated from `trilio-system`), retention `trilio-latest-retention-policy` (latest 5), **trigger-only** (no schedule). Manifests in `manifests/`.
- [ ] Write Python write generator (continuous INSERTs into `demo_db`)
- [x] **First backup completed (2026-05-25).** `mssql-vss-backup-2phcr` — 7m 52s, ~17.85 GiB on `sa-nfs-cr-demo`. **Full handshake captured: 7× Event 3197 (freeze) + 7× Event 3198 (thaw) + 7× Event 18264 (DB backed up) + 2× VSS 8194.** *Originally misread as "missing thaw" because we searched for 18265 — 18265 is for transaction-log backups, NOT thaw. Corrected 2026-05-28 by manual `guest-fsfreeze-freeze/-thaw` cycle producing the identical event signature.* **VSS 8194 = optional `IVssWriterCallback` ACL miss on workgroup VMs — benign noise; SqlServerWriter doesn't depend on it.** Evidence: `output/vss-diagnostic-20260528.md`.
- [x] **Restore test passed (2026-05-28).** `mssql-vss-backup-2phcr` → fresh ns `mssql-vss-restore` via `type: Location` Restore CR (`manifests/restore.yaml`). Wall time **7m 59s** — symmetric with backup #1's 7m 52s (data-transfer-bound). Restored VM Running, all 3 PVCs Bound clean, `MSSQL$MSSQLSERVER01` + `SQLWriter` Running, `demo_db` ONLINE, smoke-test row intact (exact timestamp match to original). Empirical app-consistency confirmed.
- [x] **QGA/VSS diagnostic completed (2026-05-28).** Manual `guest-fsfreeze-freeze/-thaw` cycle via `virsh qemu-agent-command` produced identical event signature to backup #1 (3197 ×7 freeze, 3198 ×7 thaw, 18264 ×7 backup-complete, 8194 ×2). All 12 VSS writers `Stable / No error`. **Corrected 2026-05-25 misread: 3197/3198 = freeze/thaw, 18264 = "DB backed up", 18265 = "log backed up" (unrelated to VSS).** 8194 is cosmetic (workgroup VM `IVssWriterCallback` ACL). No QGA "restore trigger" exists — restore actions must be guest-boot-task or cluster-side. Evidence: `output/vss-diagnostic-20260528.md`, `output/vss-events-manual-freezethaw-20260528-125052.txt`, `output/vssadmin-list-writers-20260528.txt`.
- [ ] **Services missing from restore.** Our BackupPlan's `gvkSelector` is VM-only, so launcher-pod Services didn't come along. Workaround: ephemeral NodePort access services in `mssql-vss-restore` (manifest `manifests/restore-access-services.yaml`; SSH `30539`, RDP `30123`). **Plan: BackupPlan v2 adds OpenShift Routes + restore-time host-rewrite transform** (NodePorts are cluster-wide; Routes are namespace-scoped — no collision on side-by-side restore).
- [ ] Demonstrate surgical FLR — pull a single `.mdf` / `.ldf` / `.bak` file from a backup
- [ ] (Negative control, optional) Repeat backup with QGA stopped — show crash-consistent gap
- [ ] **Backup #2 under load** — once generator exists, re-run a backup with continuous writes; check whether torn data appears (real stress test of the 8194 path).
- [ ] Bundle evidence in `output/` for the blog-writing agent (backup #1 packet copied 2026-05-25; restore-verification + FLR + load-test packets still pending)
- [ ] Draft customer-facing technical response to Erick
- [x] Repo shipped (bootstrap step 13): **https://github.com/trilio-demo/mssql-with-vss** (public, 2026-05-24)

---

## Session State
*(Updated at end of each session — read at start of each new session.)*

### Last session: 2026-05-28 (cross-NS restore + QGA/VSS diagnostic — backup #1 fully validated, event-ID misread retracted)

**Accomplished (morning — cross-NS restore):**
- **Cross-namespace restore.** Fresh ns `mssql-vss-restore`; Restore CR
  `mssql-vss-restore-cj6vp` via `type: Location` pattern (manifest
  `manifests/restore.yaml`). Wall time **7m 59s** — symmetric with backup
  #1's 7m 52s (data-transfer-bound). All 3 PVCs Bound clean (60G rootdisk,
  20G data disk, 1G persistent-state). VM Running on `worker-0-frqj5`.
- **Services did NOT come across.** Our BackupPlan's `gvkSelector` is
  VM-only — launcher-pod Services weren't selected. Workaround for now:
  ephemeral NodePort access services in `mssql-vss-restore` with auto-assigned
  ports — manifest `manifests/restore-access-services.yaml`. **SSH `30539`,
  RDP `30123`.** Plan: **BackupPlan v2 adds OpenShift Routes** (namespace-scoped,
  no NodePort collision) + restore-time host-rewrite transform.
- **Restore validation:** `MSSQL$MSSQLSERVER01` + `SQLWriter` Running.
  `demo_db` ONLINE. `dbo.writes` row intact: `id=1,
  payload='smoke-test row', ts=2026-05-25 01:12:38.0930152` — exact match
  to the original write. Empirical app-consistency confirmed.

**Accomplished (afternoon — QGA/VSS diagnostic):**
- **Full QGA command sweep.** QGA 110.0.2 in the VM. Verified
  `guest-info`, `guest-ping`, `guest-sync`, `guest-get-osinfo/-host-name/
  -time/-timezone/-users/-vcpus/-load/-fsinfo/-disks/-ssh-keys`,
  `guest-network-get-interfaces`, `guest-exec` (runs as `NT AUTHORITY\SYSTEM`).
  **No "restore trigger" exists** — QGA is host→guest RPC; the guest is
  not notified when KubeVirt rehydrates PVCs. Restore-side hooks must be
  guest-boot-task + sentinel, or cluster-side.
- **Manual freeze/thaw cycle** via `virsh qemu-agent-command`. 4 filesystems
  quiesced (C:, D:, 2× System Reserved). Window 12:50:52–12:51:01 CDT
  (~9s, mirrors backup #1). All 12 VSS writers ended `Stable / No error`,
  including **SqlServerWriter**.
- **Event-log correlation produced identical signature to backup #1:**
  3197 ×7 (freeze), **3198 ×7 (thaw)**, 18264 ×7 (DB backed up), 8194 ×2.
- **🔴 CORRECTED 2026-05-25 misread.** Backup #1 was originally tagged
  "no thaw events" because we searched for **18265**. 18265 is **transaction-log
  backup**, NOT thaw. The actual freeze/thaw IDs are **3197/3198**, and
  re-grep of `output/vss-events-backup1-20260525-015910.txt` shows
  3198 ×7 were there the whole time. **Backup #1 had a complete, clean
  VSS handshake.** The 8194 is an optional `IVssWriterCallback` ACL miss
  on workgroup VMs — cosmetic, SqlServerWriter doesn't depend on it.
- **Dual-provider quirk explained.** SQL named-instance `MSSQLSERVER01`
  logs each freeze/thaw under BOTH `MSSQLSERVER` (legacy) and
  `MSSQL$MSSQLSERVER01` (instance) providers. That's why 4 DBs produce
  7× events (3 system DBs ×2 providers + demo_db on the instance provider
  only — model on the legacy provider has separate accounting).
- **Memory:** saved `project_lab_ssh_key.md` (use
  `~/.ssh/vbky-temp-key.pem` for lab VMs — default keys not authorized).
- **Evidence captured:** `output/vss-diagnostic-20260528.md`,
  `output/vss-events-manual-freezethaw-20260528-125052.txt`,
  `output/vssadmin-list-writers-20260528.txt`.

**Eval clock:** grace ends **2026-06-03 16:27** (6 days, 4 rearms in reserve).

**Doc updates parked (rolled forward from 2026-05-25 + new):**
1. § 6 + generator section: ODBC 18 self-signed cert workaround — `sqlcmd -C`
   for sqlcmd, `TrustServerCertificate=yes` for pyodbc.
2. New post-install §: CD-detach via `oc patch --type=json` + data-disk
   `Initialize-Disk` (catalog template attaches the disk but doesn't online
   it in Windows — silent-fail mode if Step 3.4 missed).
3. New post-install §: SQL default-path relocation via `xp_instance_regwrite`
   (system DBs on C:, demo DBs on D:).
4. New restore §: `type: Location` Restore CR pattern; cross-NS NodePort
   collision footnote; Routes-via-BackupPlan plan.
5. Notes: `micro` editor scp-from-Mac; SSMS still deferred (`sqlcmd -C` enough).

(The previously parked 8194 / missing-18265 item is **dropped** — it was a
backup-analysis artifact, not a VM-build step, and the corrected explainer
now lives in `output/vss-diagnostic-20260528.md`.)

**Open items for next session (in priority order):**
1. **Python generator** (Task #11). `uv add pyodbc`; `src/write_generator.py` —
   continuous INSERT loop into `demo_db.dbo.writes`. Conn string must include
   `Server=localhost\MSSQLSERVER01;Encrypt=yes;TrustServerCertificate=yes`.
   Decide where it runs (Mac, in-cluster pod, or in the VM itself).
2. **Backup #2 under load.** Only remaining open consistency question:
   does a heavy write rate stretch the freeze window past SQL's ~60s
   I/O-freeze ceiling? Capture event log + row-count delta on `dbo.writes`.
3. **FLR demo** (Task #10). Pull single `.mdf`/`.ldf`/`.bak` from backup #1
   via Trilio UI/CLI. VM backups are block-mode PVCs — FLR may need a
   helper pod to mount the snapshot PVC rather than a built-in file browser.
   **Research Trilio's FLR path on this cluster first.**
4. **BackupPlan v2** — add Routes + restore-time host-rewrite transform.
5. **Bake parked doc updates into `docs/windows-vm-prep.md`** (5 items above).
6. **Draft customer-facing response to Erick** once #2/#3 evidenced.

**Lab state at end of 2026-05-28:**
- Cluster: `ocp-px`. Eval grace: ends 2026-06-03 16:27 (6 days, 4 rearms).
- `mssql-vss-lab/win2k22-aqua-junglefowl-90` — original, Running on
  `worker-0-frqj5`. `demo_db` ONLINE.
- `mssql-vss-restore/win2k22-aqua-junglefowl-90` — restored, Running on
  `worker-0-frqj5`. `demo_db` ONLINE, smoke-test row intact.
- Backup `mssql-vss-backup-2phcr` Available · Restore
  `mssql-vss-restore-cj6vp` Completed.
- Reach original VM: `ssh -i ~/.ssh/vbky-temp-key.pem -p 31256
  administrator@172.31.1.56`.
- Reach restored VM: `ssh -i ~/.ssh/vbky-temp-key.pem -p 30539
  administrator@172.31.1.56`, RDP `:30123`.

---

### Previous session: 2026-05-25 (D: drive online + SQL on D: + first backup + 8194 finding)

**Accomplished:** CDs detached, 20 GiB data disk initialized as `D:`
(NTFS, label `Data`). SQL default Data/Log/Backup paths relocated to
`D:\SQL{Data,Log,Backup}\` via `xp_instance_regwrite` (system DBs left on C:).
`sqlcmd -C` workaround for ODBC 18 self-signed cert error. Trilio BackupPlan
created (VM-scoped, target `sa-nfs-cr-demo` auto-replicated from
`trilio-system`, retention 5, trigger-only). First backup `mssql-vss-backup-2phcr`
Available, 7m 52s, ~17.85 GiB. 9-second freeze window (well inside SQL's 60s
IO-freeze timeout). `micro` editor scp'd from Mac (curl on Win2k22 wouldn't
follow GitHub redirects).

**Finding — VSS callback gap (RETRACTED / CORRECTED 2026-05-28 — see
`output/vss-diagnostic-20260528.md`):**
- Original 2026-05-25 read: "7× 18264 (freeze), 0× 18265 (thaw), VSS 8194 —
  thaw is broken." **Wrong on the event IDs.**
- Correct mapping: freeze = **3197**, thaw = **3198**, "DB backed up" =
  **18264**, "log backed up" = **18265** (only fires for transaction-log
  backups, NOT VSS snapshots).
- Re-grep of `output/vss-events-backup1-20260525-015910.txt` with the right
  IDs: 3197 ×7, **3198 ×7** (thaw events were always there), 18264 ×7,
  8194 ×2.
- VSS 8194 = optional `IVssWriterCallback` ACL miss on workgroup VMs.
  SqlServerWriter does not depend on this callback, so the standard
  `OnThaw` path delivers and SQL logs 3198 + 18264 normally. Benign noise.
- **Net:** backup #1 had a full, clean freeze/thaw handshake. The
  load-window concern is purely about SQL's ~60s I/O-freeze timeout vs.
  freeze duration — separate question, settled by the generator + load
  backup, not by the 8194 path.
- **Blog narrative:** document the dual event-ID providers (per-DB ×2 for
  named instance) and the 8194 workgroup quirk as an explainer, not a defect.

### Earlier sessions
*Bootstrap (2026-05-06) → cluster/VM stand-up (2026-05-07/08) details have
aged out of relevance. Durable facts live in **Project Status** above; all
the journey is in `git log`. Notable historic notes baked into
`docs/windows-vm-prep.md`: Secure Boot off for the golden image, stuck-stop
ghost-record recovery, service-selector gotcha, Sysprep password placeholder,
Datacenter-Eval `slmgr /rearm` quirk.*
