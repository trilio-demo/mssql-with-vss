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
- [x] Cluster locked: **`ocp-px`** (OCP 4.18.19, OCPv + Trilio 5.1.2 already installed; Portworx storage)
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
- [ ] **Blocked — Windows eval expired.** Engineering golden image is Datacenter Evaluation, build `20348.fe_release.210507` (May 2021). VM force-reboots every ~61 min. Fix: `slmgr /rearm` + reboot, or upgrade to a real Datacenter/Standard key.
- [ ] **Blocked — no data disk.** Step 3.4 (Add disk) was missed at VM creation; only the two CD-ROMs (`virtio-win` on D:, `unattendCD` on E:) are attached. SQL installed onto `C:` instead of `D:`. Fix: detach both CDs, add 40 GiB blank data disk, then move SQL data/log/backup dirs to `D:`.
- [ ] Hostname not renamed (still `WIN-1LU5F0AC846`). Cosmetic only; skip or rename later via `Rename-Computer`.
- [ ] SSMS install (deferred — "Install SSMS" button still on installer completion screen)
- [ ] Verify done-state once unblocked: `SQLWriter` running, `sqlcmd -S .\MSSQLSERVER01` returns Developer Edition banner
- [x] SSH public-key auth working — root cause was `administrators_authorized_keys` written as UTF-16 LE + BOM (PowerShell/editor default); rewritten as plain ASCII via `[System.IO.File]::WriteAllText(..., [System.Text.Encoding]::ASCII)`. Fix + verification baked into `docs/windows-vm-prep.md` § 4e.
- [ ] Configure Trilio backup target on `ocp-px`
- [ ] Write Python write generator (continuous INSERTs into `demo_db`)
- [ ] Run backup; capture VSS freeze/thaw events from Windows Event Viewer
- [ ] Restore the VM end-to-end; verify SQL comes back clean (no recovery state)
- [ ] Demonstrate surgical FLR — pull a single `.mdf` / `.ldf` / `.bak` file from a backup
- [ ] (Negative control, optional) Repeat backup with QGA stopped — show crash-consistent gap
- [ ] Bundle evidence in `output/` for the blog-writing agent
- [ ] Draft customer-facing technical response to Erick
- [x] Repo shipped (bootstrap step 13): **https://github.com/trilio-demo/mssql-with-vss** (public, 2026-05-24)

---

## Session State
*(Updated at end of each session — read at start of each new session.)*

### Last session: 2026-05-24 (SSH key fix + repo ship + post-SQL-install diagnostics)

**Accomplished:**
- **SSH public-key auth fixed.** Root cause: `administrators_authorized_keys`
  was being written by PowerShell/editor defaults as **UTF-16 LE + BOM**;
  OpenSSH silently rejects that and falls back to password auth. Fix is to
  write the file via
  `[System.IO.File]::WriteAllText(..., $key.Trim() + "`n", [System.Text.Encoding]::ASCII)`
  and verify with `Format-Hex` (first bytes should be `73 73 68`, not
  `FF FE`). Procedure + verification baked into `docs/windows-vm-prep.md` § 4e.
- **Bootstrap step 13 completed: repo shipped.**
  → **https://github.com/trilio-demo/mssql-with-vss** (public).
  - Removed bootstrap artifacts (`CLAUDE.md.template`,
    `project-bootstrap-process.md`, three `.gitkeep`s).
  - Added `README.md`, added `.claude/` to `.gitignore`.
  - Reset history, fresh `git init`, single clean initial commit.
- **Vince installed MS SQL between sessions.** Reviewed evidence in
  `collateral/`: install screenshot, drive-list screenshot, config notes,
  `virt-controller` reboot logs. Three issues identified — see **Known
  issues** below.
- **`docs/windows-vm-prep.md` updated** with all three findings:
  - § Prerequisites: callout that engineering's golden image is **Datacenter
    Evaluation** and the 180-day clock started at image-capture, not boot.
  - § 3.4: data disk is mandatory, easy to miss; documented how to add
    post-create.
  - § 4b: rewritten — the catalog template attaches **two** CD-ROMs
    (`virtio-win` + `unattendCD`), not one. Detach both (preferred) or
    rename letters out of `D:`/`E:`.
  - § 4f (new): Windows activation check + `slmgr /rearm` recipe + how to
    recognize the 60-minute reboot loop in `virt-controller` logs.
  - § 6: default vs named instance — `sqlcmd -S .` vs `sqlcmd -S .\<INSTANCE>`.
  - § 7 done-state checklist: added activation-status row, clarified CDs.

**Known issues identified end-of-session (parked for tomorrow):**
1. **Windows eval expired → 60-min reboot loop.** `virt-controller` logs
   show VMI cycling `Running` → `Succeeded` → relaunch on a ~61-minute
   cadence (timestamps 17:39 / 18:40 / 19:41 ...). Classic Windows Server
   eval-expired forced-reboot signature.
2. **No data disk.** Only the two CD-ROMs are attached
   (D: `virtio-win-1.9.46`, E: `unattendCD`). SQL installed onto `C:` —
   muddies the FLR story.
3. **Install drift vs prep doc.** Vince got SQL **2025** Developer Edition
   with **named instance `MSSQLSERVER01`** (not default `MSSQLSERVER`).
   Connection string: `Server=localhost\MSSQLSERVER01;...`. Hostname is
   still the Sysprep-generated `WIN-1LU5F0AC846` (rename step was skipped).
   None of these are blockers — just need awareness for the generator config.

**Open items for next session (in priority order):**
1. **RDP into the VM before the next forced reboot** and run `slmgr /xpr`
   + `slmgr /dlv` to confirm eval state and rearm count. If rearms remain:
   `slmgr /rearm && Restart-Computer`. If not: convert to real key or
   rebuild the golden image. Reboot loop must be stopped before anything
   else.
2. **Add the data disk.** Console → VM → Disks → Add disk: `data`, Blank,
   40 GiB, default SC. Stop/start VM. Detach `unattendCD` (and
   optionally `virtio-win`). PowerShell `Initialize-Disk` /
   `New-Partition -DriveLetter D` / `Format-Volume`.
3. **Move SQL data dirs to `D:`.** `ALTER DATABASE master MODIFY FILE …`
   for system DBs, or detach/move/attach for user DBs. Restart the
   `MSSQL$MSSQLSERVER01` service. Re-verify `Get-Service SQLWriter`.
4. **Install SSMS** (deferred from this session).
5. **Configure Trilio backup target on `ocp-px`** — pick S3 vs NFS,
   confirm TVK namespace, set up target Secret + `Target` CR.
6. **Write the Python generator** (`src/write_generator.py`):
   `uv add pyodbc`, continuous INSERT loop into `demo_db`, package for
   the Windows VM (uv-on-Windows + MS ODBC Driver 18). Connection string
   must use `localhost\MSSQLSERVER01`.

### Previous session: 2026-05-06 (bootstrap)
**Accomplished:**
- Read conversation (`collateral/City-of-Delray-Beach-VSS-with-Trilio.md`)
  and customer environment notes (`collateral/about-City-of-Delray-Beach.txt`).
- Inferred project type: **app** (lab POC, no agent persona).
- Populated this CLAUDE.md from template.
- Wrote `docs/requirements.md` with lab spec, capture plan for blog agent.
- Removed `prompts/` (app project — no system prompt needed).
- **Locked open decisions with Vince:**
  - Demo scope: DB-only + Python write generator.
  - Cluster: existing 3-node `ocp-dev` lab.
  - Repo finalization (step 13): deferred until after first lab run.
- Set up Python tooling: `pyproject.toml`, `.python-version` (3.13.13),
  `uv.lock`, `.venv/` via `uv sync`. No deps added yet.

**In progress:** Nothing. Awaiting Vince's go-ahead to start lab stand-up.

**Decisions added this session (2026-05-07):**
- **Cluster swap: `ocp-dev` → `ocp-px`.** OCP 4.18.19, OCPv (CNV) + Trilio 5.1.2
  both already running. Portworx storage matches Delray's prod stack — bonus
  alignment for the blog narrative.
- **Win2k22** locked (DataSource already defined on cluster; matches engineering's guide).
- **`px-csi-replicated`** storage class for the VM disks; snapshots via `px-csi-snapclass`.
- **Fresh namespace, fresh VM from golden image** (not the orphaned 144-day-old
  `vbns-win2k22-i01` PVC). Golden image not yet imported — that's part of
  Vince's prep, per the engineering doc he dropped in `collateral/`.
- **PDF inspector tool added:** `src/pdf_inspect.py` (pymupdf). `uv add pymupdf`
  done. Reusable for future collateral.

**Resolved 2026-05-07:**
- Golden-image guide re-exported correctly (7 pages, full procedure).
- `px-csi-replicated` annotated `storageclass.kubevirt.io/is-default-virt-class=true`.
- `docs/windows-vm-prep.md` rewritten to follow engineering's golden-image flow.
- **Discovered:** `ocs-storagecluster-ceph-rbd-virtualization` on `ocp-px` is
  an orphaned shell (no `cephcluster` CRD, no `csi-rbdplugin-provisioner`).
  Switched upload to `px-csi-replicated` RWO block.
- `win2k22` DataVolume upload completed (multi-hour at ~1 MB/s).

**Resolved 2026-05-08 (and baked into `docs/windows-vm-prep.md`):**
- **Secure Boot off required** for engineering's Win2k22 golden image. Catalog
  template defaults Secure Boot on; image's bootloader signing chain doesn't
  match OVMF secboot trust → VM parks at TianoCore. Patch `secureBoot:false`
  + `smm.enabled:false` (KubeVirt couples them) before first start.
- **Stuck-stop / ghost-record recovery** documented as a callout: force-stop
  + strip VMI finalizers + restart virt-handler on the affected node clears
  the `can not add ghost record when entry already exists with differing UID`
  state.
- **Virtio drivers CD grabs `D:`** before the data disk is online — reassign
  to `X:` first, then format the data disk on `D:`.
- **Service selector gotcha** — catalog VMs' launcher pods have
  `kubevirt.io/domain` set to the **VM resource name**, not the Windows
  hostname. Prep doc § 5 now leads with the Console "Create RDP/SSH service"
  buttons and uses `vm.kubevirt.io/name` in the YAML alternative.
- **Password placeholder** in the Sysprep XML; AutoLogon + AdministratorPassword
  must match.

**Lab state at end of 2026-05-08:**
- Cluster: `ocp-px` (current `oc` context).
- Namespace: `mssql-vss-lab`.
- VM resource: `win2k22-aqua-junglefowl-90` (Running).
- Reach from Mac: RDP `172.31.1.56:31211`, SSH `administrator@172.31.1.56 -p 31256` (password auth).
- Vince running MS SQL install + post-config between sessions.

*(The 2026-05-08 open-items list has been superseded by the 2026-05-24
entry at the top of this Session State.)*
