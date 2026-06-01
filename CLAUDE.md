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

## Strategic context — MVP target

The lab POC validates the foundation; the **MVP design target** is the
path from "app-consistent VM backup" to **5-min RPO with point-in-time
restore**:

- **Primary: Mechanism C** — TVK orchestrates `BACKUP LOG` via QGA
  `guest-exec`, ships `.trn` to NooBaa S3, plus a `COPY_ONLY .bak`
  chain anchor at every Trilio backup (Path A).
- **Sibling: Mechanism F** — Customer's `BACKUP LOG TO URL='s3://...'`
  schedule + TVK orchestrates restore-side chain replay. This is the
  story when OpenShift policy blocks `guest-exec`.

Mechanism comparison, worked RPO/RTO scenarios, and roadmap for
Mechanisms D/E (phased restore + in-guest component-mode VSS
requestor) live in:

- `private-docs/research-tvk-mssql-vss-deep-dive.md` — TVK-focused
  MSSQL/VSS primer + RPO/RTO design (2026-05-29)
- `private-docs/research-t4o-mssql-vss-restore.md` — companion T4O
  research (2026-05-28); product narrative parity

Both are gitignored (`private-docs/` is local-only by policy and
contains internal positioning/roadmap material). Read them when a
question goes beyond the MVP framing above.

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
- [x] **MVP-validation experiment 1 (2026-05-29): `demo_db` already in Full recovery model** (default with our SQL install). Baseline captured: `.mdf`/`.ldf` 8 MB each, `log_reuse_wait_desc=NOTHING`, 1 row in `dbo.writes`, 0 prior log backups in msdb.
- [x] **MVP-validation experiment 2 (2026-05-29): SYSTEM-via-QGA-exec drives sqlcmd successfully.** `NT AUTHORITY\SYSTEM` was NOT in sysadmin by default — granted via `ALTER SERVER ROLE sysadmin ADD MEMBER [NT AUTHORITY\SYSTEM]`. `BACKUP LOG` via QGA-as-SYSTEM: 53 pages in 0.045s, file at `D:\SQLBackup\demo_db_exp2_via_qga_as_system.trn`. Customer-prod recommendation: dedicated SQL login with least-privilege, not SYSTEM-as-sysadmin.
- [x] **MVP-validation experiment 3 (2026-05-29): `BACKUP LOG ... TO URL='s3://...'` works end-to-end.** AWS S3 bucket `mssql-vss-lab` (us-east-1) + SQL CREDENTIAL `s3://mssql-vss-lab.s3.us-east-1.amazonaws.com/lab` created. Driven via QGA-as-SYSTEM: 5 pages in 0.261s, validated via `RESTORE HEADERONLY` round-trip. Credentials in `collateral/aws-s3-bucket.txt` (rotate after lab work). Mechanism C + F primitive proven end-to-end.
- [x] **MVP-validation experiment 4 (2026-06-01): end-to-end log-replay restore via Path A — PASS.** Trilio backup `mssql-vss-backup-kcxdl` (7m31s / 19.7 GiB; same 7×3197/7×3198/7×18264/2×8194 signature as backup #1) + COPY_ONLY `.bak` anchor on D: (LastLSN `44000000136300001`) + post-anchor `BACKUP LOG TO URL` (FirstLSN `44000000119800001` → LastLSN `44000000140000001`) → cross-NS restore `mssql-vss-restore-exp4-xb295` (9m10s, ns `mssql-vss-restore-exp4`) → in-guest `RESTORE DATABASE WITH NORECOVERY, REPLACE` + `RESTORE LOG WITH RECOVERY` (~300ms combined) → final **16 rows** = 1 smoke + 10 pre-anchor + 5 post-anchor; post-anchor timestamps preserved (proves log replay, not crash-consistent rewind). Mechanism C end-to-end primitive proven. Evidence: `output/exp4-*` (8 files), manifests `manifests/restore-exp4*.yaml`. Restored VM/ns torn down post-validation.
- [ ] **Bake parked `docs/windows-vm-prep.md` updates** (carried from 2026-05-25/28): (a) ODBC 18 self-signed cert workaround (`sqlcmd -C` / `TrustServerCertificate=yes`); (b) CD-detach + data-disk `Initialize-Disk` post-install §; (c) SQL default-path relocation via `xp_instance_regwrite`; (d) `type: Location` Restore CR pattern + cross-NS NodePort collision footnote + Routes-via-BackupPlan plan; (e) `micro` editor scp-from-Mac note; SSMS still deferred.
- [ ] Bundle evidence in `output/` for the blog-writing agent (backup #1 packet copied 2026-05-25; restore-verification + FLR + load-test + MVP-validation packets still pending)
- [ ] **Draft customer-facing technical response to Erick** — frame around the C+F MVP path (5-min RPO) with lab evidence citations + RPO/RTO positioning vs. crash-consistent baseline. Source material: `private-docs/research-tvk-mssql-vss-deep-dive.md`.
- [x] Repo shipped (bootstrap step 13): **https://github.com/trilio-demo/mssql-with-vss** (public, 2026-05-24)

---

## Session State
*(Updated at end of each session — read at start of each new session.)*

### Last session: 2026-06-01 (Exp 4 PASS — Mechanism C end-to-end proven)

**Accomplished:**
- **Exp 4 ✓** — full Path A chain validated: Trilio backup (7m31s/19.7 GiB) + COPY_ONLY `.bak` anchor on D: + post-anchor `BACKUP LOG TO URL` → cross-NS restore (9m10s) → in-guest `RESTORE DB WITH NORECOVERY` + `RESTORE LOG WITH RECOVERY` (~300 ms) → final 16 rows = 1 smoke + 10 pre + 5 post. Post-anchor timestamps preserved end-to-end (proves log replay, not crash-consistent rewind). VSS handshake signature on backup #2 matches backup #1. See Project Status entry + `output/exp4-summary.md`.
- **Internal status email + customer response to Erick** drafted (see below; not yet sent).

**Durable lab state changes (next session needs to know):**
- `dbo.writes` on original VM now has **16 rows** (1 smoke + 10 `exp4-pre-anchor-N` + 5 `exp4-post-anchor-N`).
- New artifacts: `D:\SQLBackup\demo_db_exp4_anchor.bak` (4.45 MB, COPY_ONLY) on original VM; `s3://mssql-vss-lab/lab/demo_db_exp4.trn` (266 KB) in S3. Exp 3's `demo_db_exp3.trn` kept as evidence.
- Trilio backup `mssql-vss-backup-kcxdl` exists on `sa-nfs-cr-demo` alongside `mssql-vss-backup-2phcr`. Retention is "latest 5" — both safe for now.
- `mssql-vss-restore-exp4` namespace torn down after evidence captured (restored VM gone). `mssql-vss-restore` (from 2026-05-28) still Running, untouched.
- Windows Application log was cleared as pre-flight at 2026-06-01 ~19:53Z; current events are all from the Exp 4 backup onward.

**Eval clock:** grace ends **2026-06-03 16:27** (~2 days, 4 rearms in reserve).

**Open items for next session (priority order):**
1. **Send internal status email + customer response to Erick** — drafts in this session's history; review, refine, send.
2. **Python write generator** — for continuous workload; needed for backup-under-load test.
3. **Backup #2 under load** — depends on (2). Verifies torn-write robustness of the freeze/thaw under sustained pressure.
4. **FLR demo** — pull `.mdf` / `.ldf` / `.bak` via Trilio UI/CLI; helper-pod path likely needed.
5. **BackupPlan v2** — Routes + restore-time host-rewrite transform (replaces ephemeral NodePort plumbing).
6. **Bake parked `docs/windows-vm-prep.md` updates** (5 items — see Project Status checkbox).

**Lab state at end of 2026-06-01:**
- Cluster: `ocp-px` (context `mssql-vss-lab/api-ocp-px-demo-presales-trilio-io:6443/kube:admin`).
- `mssql-vss-lab/win2k22-aqua-junglefowl-90` — Running on `worker-0-frqj5`. `demo_db` ONLINE (16 rows), Full recovery, SYSTEM sysadmin, S3 credential live.
- `mssql-vss-restore/win2k22-aqua-junglefowl-90` — still Running from 2026-05-28 restore test; `demo_db` ONLINE with original smoke-test row intact.
- Launcher pod (original VM): `virt-launcher-win2k22-aqua-junglefowl-90-nrtc7` — confirm with `oc get pods -n mssql-vss-lab` if needed (could roll).
- Reach original VM: `ssh -i ~/.ssh/vbky-temp-key.pem -p 31256 administrator@172.31.1.56`.
- QGA-driven exec pattern unchanged from previous session.
- S3: `s3://mssql-vss-lab/lab/` (us-east-1); creds in `collateral/aws-s3-bucket.txt`.

---

### Previous session: 2026-05-29 (MVP-validation experiments 1–3)

Exp 1 (Full recovery already set), Exp 2 (QGA-as-SYSTEM drives sqlcmd; SYSTEM granted sysadmin), Exp 3 (`BACKUP LOG TO URL='s3://...'` round-trip validated via `RESTORE HEADERONLY`). Durable artifacts: SYSTEM-sysadmin on `MSSQLSERVER01`, SQL CREDENTIAL for `s3://mssql-vss-lab.s3.us-east-1.amazonaws.com/lab` in master, AWS keys in `collateral/aws-s3-bucket.txt` (rotate after lab work), `s3://mssql-vss-lab/lab/demo_db_exp3.trn`. Full detail in `git log` and Project Status checkboxes.

---

### Earlier sessions
*2026-05-28 (cross-NS restore validated + QGA/VSS diagnostic — `mssql-vss-backup-2phcr` → `mssql-vss-restore`, 7m 59s, freeze/thaw IDs corrected to 3197/3198), 2026-05-25 (data disk online as D: + SQL paths relocated + backup #1 `mssql-vss-backup-2phcr` at 7m 52s / 17.85 GiB) and bootstrap (2026-05-06) → cluster/VM stand-up (2026-05-07/08) have aged out of context relevance. Durable facts live in **Project Status**; journey is in `git log` and `output/` artifacts. Notable historic notes baked into `docs/windows-vm-prep.md`: Secure Boot off for the golden image, stuck-stop ghost-record recovery, service-selector gotcha, Sysprep password placeholder, Datacenter-Eval `slmgr /rearm` quirk.*
