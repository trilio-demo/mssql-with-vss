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
- [x] **First backup completed (2026-05-25).** `mssql-vss-backup-2phcr` — 7m 52s, ~17.85 GiB on `sa-nfs-cr-demo`. **Freeze evidence captured: 7× Event 18264.** **Finding:** no 18265 (thaw) events + **VSS 8194 "IVssWriterCallback Access Denied"** — workgroup-VM security context blocks the explicit thaw callback to SQL Writer; SQL auto-resumed via internal timeout. Snapshot was taken during freeze so it's still consistent in this quiet lab; under load, this *could* drift to crash-consistent. Restore + load-test will validate. Evidence in `output/`.
- [x] **Restore test passed (2026-05-28).** `mssql-vss-backup-2phcr` → fresh ns `mssql-vss-restore` via `type: Location` Restore CR (`manifests/restore.yaml`). Wall time **7m 59s** — symmetric with backup #1's 7m 52s (data-transfer-bound). Restored VM Running, all 3 PVCs Bound clean, `MSSQL$MSSQLSERVER01` + `SQLWriter` Running, `demo_db` ONLINE, smoke-test row intact (exact timestamp match to original). **Closes the 8194 / missing-18265 question for quiet load: backup #1 was app-consistent.**
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

### Last session: 2026-05-28 (cross-NS restore verified clean; 8194 closed for quiet load)

**Accomplished:**
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
- **Restore validation — backup #1 was app-consistent for quiet load:**
  `MSSQL$MSSQLSERVER01` + `SQLWriter` Running. `demo_db` ONLINE. `dbo.writes`
  row intact: `id=1, payload='smoke-test row', ts=2026-05-25 01:12:38.0930152`
  — exact match to the original write. **Closes the 8194 / missing-18265 open
  question for quiet load.** The 9-second freeze window outran SQL's 60s
  IO-freeze timeout; snapshot captured a consistent state before auto-thaw.
  Generator-driven backup #2 is the real stress test of that claim under writes.
- **Eval clock:** grace ends **2026-06-03 16:27** (6 days, 4 rearms in reserve).

**Doc updates parked (rolled forward from 2026-05-25 + new):**
1. § 6 + generator section: ODBC 18 self-signed cert workaround — `sqlcmd -C`
   for sqlcmd, `TrustServerCertificate=yes` for pyodbc.
2. New post-install §: CD-detach via `oc patch --type=json` + data-disk
   `Initialize-Disk` (catalog template attaches the disk but doesn't online
   it in Windows — silent-fail mode if Step 3.4 missed).
3. New post-install §: SQL default-path relocation via `xp_instance_regwrite`
   (system DBs on C:, demo DBs on D:).
4. New post-backup §: 8194 / missing-18265 finding — workgroup-VM security
   context; document as a "known limitation in non-domain VMs".
5. New restore §: `type: Location` Restore CR pattern; cross-NS NodePort
   collision footnote; Routes-via-BackupPlan plan.
6. Notes: `micro` editor scp-from-Mac; SSMS still deferred (`sqlcmd -C` enough).

**Open items for next session (in priority order):**
1. **Capture today's evidence** into `output/`: restore-verification SSH
   transcript (services + `demo_db` ONLINE + smoke-test row); side-by-side
   `oc get vm -A` showing both namespaces running.
2. **FLR demo** (Task #10). Pull single `.mdf`/`.ldf`/`.bak` from backup #1
   via Trilio UI/CLI. Note: VM backups use block-mode PVCs — FLR may need a
   helper pod to mount the snapshot PVC rather than a built-in file browser.
   Research Trilio's FLR path on this cluster first.
3. **Python generator** (Task #11). `uv add pyodbc`; `src/write_generator.py` —
   continuous INSERT loop into `demo_db.dbo.writes`. Conn string must include
   `Server=localhost\MSSQLSERVER01;Encrypt=yes;TrustServerCertificate=yes`.
4. **Backup #2 under load.** Real stress test of the 9-second-window claim.
5. **BackupPlan v2** — add Routes + restore-time transform.
6. **Bake parked doc updates into `docs/windows-vm-prep.md`** (see list above).
7. **Draft customer-facing response to Erick** once FLR + load-test evidenced.

**Lab state at end of 2026-05-28:**
- Cluster: `ocp-px`. Eval grace: ends 2026-06-03 16:27 (6 days, 4 rearms).
- `mssql-vss-lab/win2k22-aqua-junglefowl-90` — original, Running on
  `worker-0-frqj5`. `demo_db` ONLINE.
- `mssql-vss-restore/win2k22-aqua-junglefowl-90` — restored, Running on
  `worker-0-frqj5`. `demo_db` ONLINE, smoke-test row intact.
- Backup `mssql-vss-backup-2phcr` Available · Restore
  `mssql-vss-restore-cj6vp` Completed.
- Reach restored VM: `ssh administrator@172.31.1.56 -p 30539`, RDP `:30123`.

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

**Finding — VSS callback gap (carried forward; validated under quiet load
on 2026-05-27):**
- **7× Event 18264** (`I/O is frozen on database…`) at 01:45:31 local.
- **0× Event 18265** (the matching thaw — none).
- **VSS Event 8194** *(Informational)*: `Unexpected error querying for the
  IVssWriterCallback interface. hr = 0x80070005, Access is denied.`
- **Hypothesis:** workgroup VM → VSS requester (driven from QGA) can't
  satisfy the `IVssWriterCallback` ACL → VSS can't notify SQL Writer of the
  post-snapshot thaw → SQL never logs 18265 → SQL's internal IO-freeze
  timeout (~60s) expires and SQL auto-resumes silently. Snapshot captured
  during freeze, so quiet-load result is consistent (confirmed 2026-05-27 via
  restore + data check). **Under load this could degrade to crash-consistent.**
  Python generator under load is the real test.
- **Blog narrative:** document both the success path AND the gap — don't sanitize.

### Earlier sessions
*Bootstrap (2026-05-06) → cluster/VM stand-up (2026-05-07/08) details have
aged out of relevance. Durable facts live in **Project Status** above; all
the journey is in `git log`. Notable historic notes baked into
`docs/windows-vm-prep.md`: Secure Boot off for the golden image, stuck-stop
ghost-record recovery, service-selector gotcha, Sysprep password placeholder,
Datacenter-Eval `slmgr /rearm` quirk.*
