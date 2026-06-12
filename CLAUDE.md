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
- [x] **Prep-doc naming fix (2026-06-12).** `docs/windows-vm-prep.md` § 3 now sets **explicit short VM/disk names** (VM `mssql`, disk `data`) instead of accepting the catalog's random `adjective-animal-NN` names. Root cause: some CSI backends (DRBD/LINSTOR observed on a lab cluster) derive an internal volume name from namespace + VM name + disk name + `drbd-` prefix + `-<random>` suffix, capped at **63 chars**; the auto-generated names overflowed it (`drbd-mssql-vss-lab-dv-win2k22-coffee-rat-79-disk-amaranth-turkey-13-a5vdrk`) and provisioning failed. Added length-cap callout + budget math (~34 chars for VM+disk after fixed overhead + namespace); renumbered § 3 steps; § 3a uses `VM=mssql` directly; fixed `§ 3.4`→`§ 3 step 5` cross-refs. **Backend is expected to handle long names natively later — treat as a hard constraint for now.** Open Q on rebuild: confirm the console doesn't append a random suffix to the add-on disk even when named `data`; if it does, switch to a YAML `dataVolumeTemplate`.
- [ ] **Build own Win2k22 golden image from ISO/pipeline** — kills the 180-day eval clock (no more § 4f rearm dance) and lets sshd + QGA + virtio be baked in. When done, § 4e collapses to "sshd preinstalled — just upload your key" and § 4f disappears. **Bake-in checklist:** OpenSSH.Server capability (DISM healthy on fresh ISO build) + service Automatic + TCP/22 firewall rule + PowerShell DefaultShell; **delete `C:\ProgramData\ssh\ssh_host_*` before sysprep /generalize** (else all clones share host keys); do NOT bake `authorized_keys` into a shared image (key upload stays a per-clone step); **must still add virtio-win drivers + QEMU Guest Agent** (current golden image had QGA preinstalled — easy to forget, and QGA is load-bearing for the whole VSS lab). Hold prep-doc edits until image exists + bake confirmed. **Standalone bake-in brief: [`docs/golden-image-build.md`](docs/golden-image-build.md)** (created 2026-06-12).
- [ ] **Bake parked `docs/windows-vm-prep.md` updates** (carried from 2026-05-25/28): (a) ODBC 18 self-signed cert workaround (`sqlcmd -C` / `TrustServerCertificate=yes`); (b) CD-detach + data-disk `Initialize-Disk` post-install §; (c) SQL default-path relocation via `xp_instance_regwrite`; (d) `type: Location` Restore CR pattern + cross-NS NodePort collision footnote + Routes-via-BackupPlan plan; (e) `micro` editor scp-from-Mac note; SSMS still deferred.
- [ ] Bundle evidence in `output/` for the blog-writing agent (backup #1 packet copied 2026-05-25; restore-verification + FLR + load-test + MVP-validation packets still pending)
- [ ] **Draft customer-facing technical response to Erick** — frame around the C+F MVP path (5-min RPO) with lab evidence citations + RPO/RTO positioning vs. crash-consistent baseline. Source material: `private-docs/research-tvk-mssql-vss-deep-dive.md`.
- [x] Repo shipped (bootstrap step 13): **https://github.com/trilio-demo/mssql-with-vss** (public, 2026-05-24)
- [x] **Lab guide published to public repo (2026-06-07).** `docs/lab-guide.md` — 12-step reproducible procedure with inline SQL + manifests + troubleshooting. Audience-widened (not just "Trilio colleagues"), scrubbed of internal taxonomy + competitive/roadmap framing. Internal-only companion docs (`flow.md`, `flow-prompt-claude-design.md`, `flow.pdf`) parked in `private-docs/`. `*.pdf` gitignored. Commit `a683311` on `origin/main`.
- [x] **Shareable VM-build recipe shipped (2026-06-08).** `docs/unattend.xml` (new, heavily commented Sysprep answer file) + restructured `docs/windows-vm-prep.md` (cluster-agnostic; § 4e SSH install rewritten as 3 paths — `Add-WindowsCapability` / GitHub zip / RDP drag-and-drop). Commit `7dda088` on `origin/main`. Validated end-to-end by spinning a fresh VM on a *different* cluster (TopoLVM, not the original Portworx-on-`ocp-px`) — see Session State for the new lab footprint.
- [ ] **Prototype Trilio hook into virt-launcher pod** — drive in-guest SQL flows (e.g. pre-backup `COPY_ONLY .bak`) automatically via QGA-exec lifecycle hooks. Closes the `[MANUAL]` gap that today's lab guide hands to the colleague.
- [ ] **Prototype in-guest VSS component requestor** — A2 path / "Mechanism E." POC scope: hardcoded MSSQL + `SqlServerWriter`, single SQL/Windows version. Drive via QGA-exec first. **Deferred design Q:** can it work via QGA freeze/thaw alone (no QGA-exec)? If yes, hook + VSS tracks collapse into one.
- [ ] **Demo POC to Trilio engineering** — handoff so engineering productionizes a multi-DB component requestor (VSS writer-GUID enumeration → Exchange, AD DS, etc.). Sales narrative: "one mechanism → n databases" vs. per-DB Explorer-style integrations.
- [ ] **Confluence article + blog** — org/customer narrative tying the hook mechanism + VSS POC together. Distinct from `docs/lab-guide.md` (which is the reproducibility guide for the today-proven path).

---

## Session State
*(Updated at end of each session — read at start of each new session.)*

### Last session: 2026-06-12 (prep-doc naming fix shipped; ISO golden-image build queued)

**Accomplished:**
- Diagnosed a provisioning failure on a **DRBD/LINSTOR-backed** lab cluster: the backend derives an internal volume name from namespace + VM name + disk name + `drbd-` prefix + random suffix, capped at **63 chars**. The catalog's random `adjective-animal-NN` VM/disk names overflowed it (`drbd-mssql-vss-lab-dv-win2k22-coffee-rat-79-disk-amaranth-turkey-13-a5vdrk`, ~74 chars). Confirmed it **can't be renamed in place** (k8s object names immutable; the DRBD resource name follows the PVC) — fix is recreate with short names.
- Fixed `docs/windows-vm-prep.md` § 3: explicit short VM name (`mssql`) + disk name (`data`), length-cap callout + budget math (~34 chars for VM+disk after fixed overhead + namespace), renumbered steps, § 3a uses `VM=mssql`, fixed `§ 3.4`→`§ 3 step 5` cross-refs.
- Wrote new `docs/golden-image-build.md` — bake-in brief for building a Win2k22 golden image from ISO.
- Committed + pushed **`4fe7255`** on `origin/main`.

**Durable lab state changes:** None — Mac-side documentation only; no cluster resources touched today.

**Next session: likely week of 2026-06-15.** Vince is building the new ISO golden image offline between sessions.

**Open items for next session (priority order):**
1. **Build new Win2k22 golden image from ISO** (Vince doing offline) — follow `docs/golden-image-build.md`: licensed edition (kills the 180-day eval clock), bake virtio + QGA + OpenSSH, **delete SSH host keys before sysprep /generalize**, don't bake `authorized_keys`. On return: verify a test clone, then collapse prep-doc § 4e/§ 4f around the preinstalled services.
2. **Recreate the failed VM with short names** (`mssql` / `data`) once the image exists. On rebuild, confirm the OCP console doesn't append a random suffix to the add-on `data` disk; if it does, switch to a YAML `dataVolumeTemplate`.
3. **Everything in the 2026-06-08 open-items list below still applies** — POC tracks (hook + in-guest VSS requestor), the two-footprint cluster cautions (TopoLVM Trilio-operator check / `ocp-px` state verify), and the unsent internal email + Erick reply.

---

### Previous session: 2026-06-08 (shareable VM-build recipe shipped; new POC cluster online)

**Accomplished:**
- Resumed after an AUP-alert force-exit. Diagnosed the previous-session new-VM build failures: (a) CD-letter race blocked Order 1 data-disk init (D: held by `virtio-win` CD-ROM when `New-Partition -DriveLetter D` ran), (b) the DISM servicing stack on the golden image is broken — `Add-WindowsCapability OpenSSH.Server` returned `Installed` but binaries never deployed; `dism /Set-Edition` silently no-op'd.
- **Rebuilt VM on a different cluster** (`lvms-topolvm-immediate` TopoLVM, NOT `ocp-px` Portworx) — Vince was reusing the procedure on a fresh cluster to validate the shareable-recipe goal. New VM: `mssql-vss-lab/win2k22-coffee-rat-79`.
- First unattend revision (6 FirstLogonCommands incl. Orders 4-6 for GitHub-zip OpenSSH install): Orders 1-3 fired (D: formatted NTFS DATA, RDP enabled, DISM-broken edition fallback no-op'd) but **Orders 4-6 NEVER FIRED** — chain halted between Order 3 and Order 4 with no diagnostic surface. Compounding issue: cluster's egress allows `api.github.com` but blocks `objects.githubusercontent.com` (the release-download CDN), so even the GitHub-download approach was fragile from network alone.
- Workaround for *this* VM: RDP drag-and-drop of `OpenSSH-Win64.zip` from Mac → manual extract + `install-sshd.ps1` → SSH up. NodePort `mssql-lab-ssh` exposes port 22; SSH'd in from Mac with key.
- **Refactor for portability:** stripped Orders 4-6 from `docs/unattend.xml`; restructured `docs/windows-vm-prep.md` § 4e as a 3-path manual install (`Add-WindowsCapability` / GitHub zip / RDP drag-and-drop) so readers pick by their cluster's egress posture. Genericized prep doc — variables for storage class, IPs, IMG_PATH; no hardcoded `ocp-px`/`px-csi-replicated`. Tilde-expansion removed from doc command examples (`$HOME` / absolute paths). Moved `cscript //nologo //h:cscript //s` from a callout to an inline required step in § 4f.
- Memories added: `project_shareable_recipe.md`, `feedback_no_tilde_in_doc_paths.md`.
- Committed and pushed: **`7dda088`** on `origin/main` — "docs: ship shareable unattend.xml + restructure prep guide."

**Durable lab state changes:**
- **NEW cluster + new VM online:** `mssql-vss-lab/win2k22-coffee-rat-79` on a TopoLVM-backed OpenShift cluster (NOT `ocp-px`). D: formatted NTFS DATA (40 GiB), QGA Running, RDP + SSH both reachable. **SQL Server NOT yet installed** on this VM — § 6 of the prep doc is the next step if you continue lab work here.
- Old broken VM `win2k22-cyan-lungfish-79` deleted (cleanup commands applied in `mssql-vss-lab` on the new cluster).
- **Original `ocp-px` lab footprint untouched** today. `mssql-vss-lab/win2k22-aqua-junglefowl-90` + `mssql-vss-restore/win2k22-aqua-junglefowl-90` still as they were on 2026-06-01. Eval grace passed 2026-06-03; state unverified.

**Two parallel lab footprints now exist** — be deliberate about which you're touching:
- **`ocp-px` (Portworx):** authoritative Exp 4 evidence environment. Original BackupPlan, SQL CREDENTIAL, demo_db with 16 rows all live here. Don't touch unless rerunning experiments there.
- **New TopoLVM cluster:** recipe-validation environment. Used to prove the shareable unattend works elsewhere. No BackupPlan / SQL install yet. Trilio operator install status here is unverified.

**Open items for next session (priority order):**
1. **POC tracks queued from 2026-06-07 still primary** — Trilio hook into virt-launcher pod; in-guest VSS component requestor; deferred design Q (does VSS requestor work via QGA freeze/thaw alone). Today's shareable-recipe work was a sidequest; these tracks didn't move.
2. **If continuing lab work on the new TopoLVM cluster:** confirm Trilio operator is installed there first; install SQL Server on `win2k22-coffee-rat-79` (§ 6 of prep doc); then BackupPlan + Restore CR will need adapting for TopoLVM's `VolumeSnapshotClass` (not Portworx). Storage-class differences ripple into BackupPlan/Restore behavior — worth a thinking pass before deep work.
3. **If returning to `ocp-px`:** verify state of original VMs (eval grace ended 2026-06-03, 5+ days past; 3 rearms remain).
4. **Send internal status email + Erick reply** — drafts still at `private-docs/2026-06-01-*.md`, not sent.
5. (Items 6-10 from the 2026-06-07 next-session list still apply: Python generator, backup #2 under load, FLR, BackupPlan v2, parked prep-doc updates, Confluence article + blog.)

---

### Earlier sessions
*2026-06-07 (lab guide `docs/lab-guide.md` shipped to public repo as `a683311` — 12-step reproducible procedure, scrubbed of internal taxonomy/competitive/roadmap framing; internal companions parked in `private-docs/`; new POC tracks scoped — Trilio virt-launcher hook + in-guest VSS component requestor + deferred QGA-freeze/thaw design Q), 2026-06-03 (S3 cred-leak audit clean — no `AKIA`/`ASIA` or aws key strings in any tracked file or commit; secrets live only in `collateral/aws-s3-bucket.txt` on Vince's Mac + SQL CREDENTIAL in master), 2026-06-01 (Exp 4 PASS — full Path A end-to-end log-replay restore validated: backup `mssql-vss-backup-kcxdl` 7m31s/19.7 GiB + `COPY_ONLY .bak` anchor on D: + post-anchor `BACKUP LOG TO URL` → cross-NS restore 9m10s → in-guest `RESTORE DB WITH NORECOVERY` + `RESTORE LOG WITH RECOVERY` ~300ms → final 16 rows = 1 smoke + 10 pre-anchor + 5 post-anchor; post-anchor timestamps preserved. Email drafts staged at `private-docs/2026-06-01-*.md`, not yet sent.), 2026-05-29 (MVP-validation Exp 1-3: Full recovery already set, QGA-as-SYSTEM drives sqlcmd with SYSTEM granted sysadmin, `BACKUP LOG TO URL='s3://...'` round-trip validated — durable artifacts: SYSTEM-sysadmin on `MSSQLSERVER01`, SQL CREDENTIAL in master, AWS keys in `collateral/aws-s3-bucket.txt`), 2026-05-28 (cross-NS restore validated + QGA/VSS diagnostic — `mssql-vss-backup-2phcr` → `mssql-vss-restore`, 7m 59s, freeze/thaw IDs corrected to 3197/3198), 2026-05-25 (data disk online as D: + SQL paths relocated + backup #1 `mssql-vss-backup-2phcr` at 7m 52s / 17.85 GiB), bootstrap (2026-05-06) → VM stand-up (2026-05-07/08). Durable facts live in **Project Status**; journey is in `git log` and `output/` artifacts.*

**Persistent lab state on `ocp-px` (current as of 2026-06-01; not re-verified since — re-check before next deep work there):**
- Context: `mssql-vss-lab/api-ocp-px-demo-presales-trilio-io:6443/kube:admin`.
- `mssql-vss-lab/win2k22-aqua-junglefowl-90` — last known Running on `worker-0-frqj5`. `demo_db` ONLINE (16 rows), Full recovery, SYSTEM sysadmin, S3 credential live. **Eval clock past 2026-06-03 grace; verify state.**
- `mssql-vss-restore/win2k22-aqua-junglefowl-90` — still Running from 2026-05-28 restore test (untouched).
- Reach original VM: `ssh -i ~/.ssh/vbky-temp-key.pem -p 31256 administrator@172.31.1.56`.
- QGA-driven exec pattern: `virsh qemu-agent-command <vm> '{"execute":"guest-exec",...}'` via `oc exec` into virt-launcher pod, or directly on worker.
- S3: `s3://mssql-vss-lab/lab/` (us-east-1); creds in `collateral/aws-s3-bucket.txt`.

**Persistent lab state on the new TopoLVM cluster (as of 2026-06-08):**
- `mssql-vss-lab/win2k22-coffee-rat-79` — Running. D: NTFS DATA 40 GiB, QGA Running, sshd Running (binaries at `C:\Program Files\OpenSSH\`, manually installed via § 4e Path C). RDP + SSH NodePorts via `mssql-lab-rdp` / `mssql-lab-ssh`. **Edition: still Eval (DISM broken; initial grace started 2026-06-08 — verify expiry).** SQL Server NOT installed. No Trilio resources here yet.
