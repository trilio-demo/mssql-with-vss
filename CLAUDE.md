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
specific technical inquiry from a customer (named customer + competitive
context in the gitignored `CLAUDE.local.md`).

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
  Also: a customer-facing technical response once the lab is verified.

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

## Identifiers — local-only
Clusters, VMs, the golden-image registry, the S3 bucket, and the customer are
referenced below by **role-label** (e.g. *evidence cluster (Portworx)*,
*consume SQL VM*, *the lab S3 bucket*). Real names, URLs, IPs, NodePorts, and
credentials live in the gitignored `CLAUDE.local.md` (auto-loaded at session
start) + `docs/session-state.md`. Put new sensitive identifiers there, not here.

## Project Status
- [x] Demo scope locked: **DB-only with Python write generator (inside the Windows VM)**
- [x] Cluster locked: **the evidence cluster (Portworx)** (OCP 4.18.19, OCPv + Trilio already installed)
- [x] Python tooling set up (pyenv 3.13.13 + uv) — driver: `pyodbc` + MS ODBC Driver 18 (added when generator is written)
- [x] Trilio licensed on all clusters
- [x] Windows version: **Server 2022** (DataSource `win2k22` already defined on cluster)
- [x] VM storage class: **`px-csi-replicated`** (Portworx) — annotated `is-default-virt-class=true`; snapshots via `px-csi-snapclass`
- [x] Build approach: **fresh namespace `mssql-vss-lab`, fresh VM from Win2k22 golden image** via engineering's flow
- [x] PDF inspector tool: `src/pdf_inspect.py` (pymupdf) — reusable for any collateral PDF; supports `--render-all`
- [x] `docs/windows-vm-prep.md` rewritten for the golden-image flow (verbatim Sysprep `unattend.xml` from engineering guide, post-boot config, NodePort exposure, SQL install)
- [x] Golden image uploaded as DataVolume `win2k22` (Portworx, RWO block — Ceph SC was orphaned)
- [x] VM created from catalog template — **the evidence SQL VM** in `mssql-vss-lab`
- [x] Secure Boot + SMM patched off (image bootloader signing chain didn't match OVMF secboot trust); Windows booted, Sysprep ran clean
- [x] QGA verified running, RDP enabled, OpenSSH Server installed and running (password auth)
- [x] NodePort exposure: RDP + SSH on worker IPs (ports/IPs in `CLAUDE.local.md`)
- [x] SSH Service selector fixed (`vm.kubevirt.io/name: <evidence SQL VM>` — prep doc YAML had used `kubevirt.io/domain: mssql-lab` which doesn't match the launcher pod's labels)
- [x] MS SQL Developer Edition installed (**SQL Server 2025**, named instance `MSSQLSERVER01`, default instance was *not* selected) — confirmed via screenshot `collateral/MSSQL-installed-screen.png`
- [x] **Windows eval rearmed (2026-05-24).** Engineering golden image is Datacenter Evaluation, build `20348.fe_release.210507` (May 2021). `slmgr /rearm` + reboot took the VM out of `Notification` mode; `slmgr /xpr` now shows `Initial grace period ends 6/3/2026 4:27 PM` — only ~10 days, not the documented 180 (rearm-after-expiry quirk). Reboot loop expected to be dead; verify with `oc logs -n openshift-cnv deployment/virt-controller --since=2m | grep <vm>` over the next ~70 min. 4 rearms remaining.
- [x] **Data disk online (2026-05-25).** 20 GiB virtio disk `disk-copper-cheetah-64` initialized in Windows as **`D:`** (NTFS, label `Data`). CDs (`virtio-win`, `sysprep`) detached. SQL default Data/Log/Backup paths relocated to `D:\SQL{Data,Log,Backup}\` via `xp_instance_regwrite`. Smoke test passed: `demo_db.mdf` / `demo_db_log.ldf` / `demo_db_smoke.bak` all on D:.
- [ ] Hostname not renamed (still `WIN-1LU5F0AC846`). Cosmetic only; skip or rename later via `Rename-Computer`.
- [ ] SSMS install (deferred — `sqlcmd -C` works fine for everything we need; revisit if a customer-facing screenshot demands it).
- [x] Done-state verified: `SQLWriter` + `MSSQL$MSSQLSERVER01` services Running; `sqlcmd -S .\MSSQLSERVER01 -E -C` returns banner; `demo_db` ONLINE.
- [x] SSH public-key auth working — root cause was `administrators_authorized_keys` written as UTF-16 LE + BOM (PowerShell/editor default); rewritten as plain ASCII via `[System.IO.File]::WriteAllText(..., [System.Text.Encoding]::ASCII)`. Fix + verification baked into `docs/windows-vm-prep.md` § 4e.
- [x] **Trilio BackupPlan created (2026-05-25).** `mssql-vss-lab/mssql-vss-backupplan` — VM-scoped (gvkSelector → the evidence SQL VM), target `sa-nfs-cr-demo` (auto-replicated from `trilio-system`), retention `trilio-latest-retention-policy` (latest 5), **trigger-only** (no schedule). Manifests in `manifests/`.
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
- [x] **MVP-validation experiment 3 (2026-05-29): `BACKUP LOG ... TO URL='s3://...'` works end-to-end.** AWS S3 bucket + SQL CREDENTIAL created (the lab S3 bucket; details in `CLAUDE.local.md`). Driven via QGA-as-SYSTEM: 5 pages in 0.261s, validated via `RESTORE HEADERONLY` round-trip. Credentials in `collateral/aws-s3-bucket.txt` (rotate after lab work). Mechanism C + F primitive proven end-to-end.
- [x] **MVP-validation experiment 4 (2026-06-01): end-to-end log-replay restore via Path A — PASS.** Trilio backup `mssql-vss-backup-kcxdl` (7m31s / 19.7 GiB; same 7×3197/7×3198/7×18264/2×8194 signature as backup #1) + COPY_ONLY `.bak` anchor on D: (LastLSN `44000000136300001`) + post-anchor `BACKUP LOG TO URL` (FirstLSN `44000000119800001` → LastLSN `44000000140000001`) → cross-NS restore `mssql-vss-restore-exp4-xb295` (9m10s, ns `mssql-vss-restore-exp4`) → in-guest `RESTORE DATABASE WITH NORECOVERY, REPLACE` + `RESTORE LOG WITH RECOVERY` (~300ms combined) → final **16 rows** = 1 smoke + 10 pre-anchor + 5 post-anchor; post-anchor timestamps preserved (proves log replay, not crash-consistent rewind). Mechanism C end-to-end primitive proven. Evidence: `output/exp4-*` (8 files), manifests `manifests/restore-exp4*.yaml`. Restored VM/ns torn down post-validation.
- [x] **Prep-doc naming fix (2026-06-12).** `docs/windows-vm-prep.md` § 3 now sets **explicit short VM/disk names** (VM `mssql`, disk `data`) instead of accepting the catalog's random `adjective-animal-NN` names. Root cause: some CSI backends (DRBD/LINSTOR observed on a lab cluster) derive an internal volume name from namespace + VM name + disk name + `drbd-` prefix + `-<random>` suffix, capped at **63 chars**; the auto-generated names overflowed it (`drbd-mssql-vss-lab-dv-win2k22-coffee-rat-79-disk-amaranth-turkey-13-a5vdrk`) and provisioning failed. Added length-cap callout + budget math (~34 chars for VM+disk after fixed overhead + namespace); renumbered § 3 steps; § 3a uses `VM=mssql` directly; fixed `§ 3.4`→`§ 3 step 5` cross-refs. **Backend is expected to handle long names natively later — treat as a hard constraint for now.** Open Q on rebuild: confirm the console doesn't append a random suffix to the add-on disk even when named `data`; if it does, switch to a YAML `dataVolumeTemplate`.
- [ ] **Build own Win2k22 golden image from ISO/pipeline** — kills the 180-day eval clock (no more § 4f rearm dance) and lets sshd + QGA + virtio be baked in. When done, § 4e collapses to "sshd preinstalled — just upload your key" and § 4f disappears. **Bake-in checklist:** OpenSSH.Server capability (DISM healthy on fresh ISO build) + service Automatic + TCP/22 firewall rule + PowerShell DefaultShell; **delete `C:\ProgramData\ssh\ssh_host_*` before sysprep /generalize** (else all clones share host keys); do NOT bake `authorized_keys` into a shared image (key upload stays a per-clone step); **must still add virtio-win drivers + QEMU Guest Agent** (current golden image had QGA preinstalled — easy to forget, and QGA is load-bearing for the whole VSS lab). Hold prep-doc edits until image exists + bake confirmed. **Standalone bake-in brief: [`docs/golden-image-build.md`](docs/golden-image-build.md)** (created 2026-06-12). **⚠️ CORRECTED 2026-06-16: the "licensed edition kills the eval clock" premise was WRONG. The 10-day clock is the *activate-within-10-days* deadline; `slmgr /ato` (online activation) unlocks the full ~180-day eval — no licensed/VL ISO required. Per-clone activation is now baked into `docs/unattend.xml` Order 4. **`docs/golden-image-build.md` rewritten 2026-06-18 — now Server-2025-centric, eval-clock premise corrected (activation not licensed ISO), and includes the configmap + `windows-efi-installer` pipeline procedure.**
- [x] **Golden-image build pipeline working on the build cluster (2026-06-15/16).** Used Red Hat `windows-efi-installer` Tekton pipeline (v4.21.0) in the build namespace to build from ISO. **`win2k25` golden master built**: Server 2025 Standard **Desktop Experience** (build 26100.32230), **virtio + QGA + OpenSSH (GitHub-zip) baked**, unique per-clone host keys (host-key wipe before generalize). Validated on clone `golden-test-2k25`. Build answer file `windows2k25-autounattend-golden` (source in `collateral/win2k25-golden-*`). Key gotchas baked into knowledge: (a) `dism /Set-Edition` + sysprep = hang → never do edition conversion inline; (b) OpenSSH via GitHub-zip not Windows-Update FOD (egress); (c) edition selected via **`/IMAGE/INDEX`** not `/Image/Description` (refreshed ISO names drift); (d) **eval clock = activation, fixed by `slmgr /ato`**. A v2 **2022** golden configmap also exists (`collateral/configmap-win2k22-golden-v2.yaml`) but 2025 is the chosen lineage.
- [ ] **Distribute `win2k25` golden image to other clusters via containerDisk-in-a-registry.** Wrap disk as OCI containerDisk (disk at `/disk/`), push to a registry all clusters reach, consume as `containerDisk` volume. **Registry choice pending.** Prefer **in-cluster build** of the containerDisk (the Mac `virtctl vmexport download` is flaky on multi-GB pulls — ephemeral-port exhaustion).
- [ ] **(Lower priority) Build a new lean golden image.** The prep docs now
  right-size at *clone* time (1 vCPU / 4 Gi via instancetype, 32 Gi root, 10 Gi
  SQL data disk) — a workaround layered on the existing `win2k25-v1` golden
  (~21 Gi virtual, `u1.large`-era assumptions). A leaner golden baseline
  (minimal disk/feature footprint baked in, lean defaults) would let clones
  start lean without per-VM overrides. **Deferred — focus is now the MSSQL POC,
  not golden-image infra.** Specs landed in `docs/win2k25-vm-prep.md` +
  `docs/windows-vm-prep.md` (2026-06-19).
- [ ] **Bake parked `docs/windows-vm-prep.md` updates** (carried from 2026-05-25/28): (a) ODBC 18 self-signed cert workaround (`sqlcmd -C` / `TrustServerCertificate=yes`); (b) CD-detach + data-disk `Initialize-Disk` post-install §; (c) SQL default-path relocation via `xp_instance_regwrite`; (d) `type: Location` Restore CR pattern + cross-NS NodePort collision footnote + Routes-via-BackupPlan plan; (e) `micro` editor scp-from-Mac note; SSMS still deferred.
- [ ] Bundle evidence in `output/` for the blog-writing agent (backup #1 packet copied 2026-05-25; restore-verification + FLR + load-test + MVP-validation packets still pending)
- [ ] **Draft customer-facing technical response to the customer** — frame around the C+F MVP path (5-min RPO) with lab evidence citations + RPO/RTO positioning vs. crash-consistent baseline. Source material: `private-docs/research-tvk-mssql-vss-deep-dive.md`.
- [x] Repo shipped (bootstrap step 13): **https://github.com/trilio-demo/mssql-with-vss** (public, 2026-05-24)
- [x] **Lab guide published to public repo (2026-06-07).** `docs/lab-guide.md` — 12-step reproducible procedure with inline SQL + manifests + troubleshooting. Audience-widened (not just "Trilio colleagues"), scrubbed of internal taxonomy + competitive/roadmap framing. Internal-only companion docs (`flow.md`, `flow-prompt-claude-design.md`, `flow.pdf`) parked in `private-docs/`. `*.pdf` gitignored. Commit `a683311` on `origin/main`.
- [x] **Shareable VM-build recipe shipped (2026-06-08).** `docs/unattend.xml` (new, heavily commented Sysprep answer file) + restructured `docs/windows-vm-prep.md` (cluster-agnostic; § 4e SSH install rewritten as 3 paths — `Add-WindowsCapability` / GitHub zip / RDP drag-and-drop). Commit `7dda088` on `origin/main`. Validated end-to-end by spinning a fresh VM on a *different* cluster (the TopoLVM consume cluster, not the original Portworx evidence cluster) — see Session State for the new lab footprint.
- [ ] **Prototype Trilio hook into virt-launcher pod** — drive in-guest SQL flows (e.g. pre-backup `COPY_ONLY .bak`) automatically via QGA-exec lifecycle hooks. Closes the `[MANUAL]` gap that today's lab guide hands to the colleague.
- [ ] **Prototype in-guest VSS component requestor** — A2 path / "Mechanism E." POC scope: hardcoded MSSQL + `SqlServerWriter`, single SQL/Windows version. Drive via QGA-exec first. **Deferred design Q:** can it work via QGA freeze/thaw alone (no QGA-exec)? If yes, hook + VSS tracks collapse into one.
- [ ] **Demo POC to Trilio engineering** — handoff so engineering productionizes a multi-DB component requestor (VSS writer-GUID enumeration → Exchange, AD DS, etc.). Sales narrative: "one mechanism → n databases" vs. per-DB Explorer-style integrations.
- [ ] **Confluence article + blog** — org/customer narrative tying the hook mechanism + VSS POC together. Distinct from `docs/lab-guide.md` (which is the reproducibility guide for the today-proven path).

---

## Session State

*Forward-looking brief — read at start of each session. Backward-looking
archaeology (thread-by-thread detail, decisions + reasoning, ruled-out paths,
detailed per-cluster lab state) lives in `docs/session-state.md`.*

**Last session (2026-07-01 — intel + a partner-facing deliverable):** A
**partner-led re-entry of the customer opp is in motion** (who/what is
confidential — see `CLAUDE.local.md` § Customer context). Short version: the
customer's OCPv migration is struggling on a competitor's backup+DR stack, and a
**feature-readiness call (week of 07-06)** will evaluate swapping to Trilio.
Built the deliverable for that call: `output/trilio-mssql-app-consistency-approach.md`
— tightly MSSQL-app-consistency-focused, scrubbed for external sharing, dual-use
(readable + slide-extractable; Cowork produced a finished PPT from it). Also
detailed the **MSSQL-VSS POC track** into 3 sub-tracks and delivered a **Sub-track 1
(virt-launcher hook) build plan** — not started (gated on SQL install; deferred
behind the deliverable). No cluster/code work.

**Prior session (2026-06-19 — doc-only):** Trimmed VM-build recipes to a lean lab
profile (1 vCPU / 4 Gi / 32 Gi root / 10 Gi data; 32 Gi root = hard floor). Added
a lower-priority "build a lean golden" task. Detail in `docs/session-state.md`.

**Next session** — depends on how the call lands. Most likely: **start Sub-track 1**
— install SQL on the consume `win2k25-mssql` (open item 1, the gate for all hook
work), then prototype the TVK virt-launcher hook — plus any follow-up collateral
the call surfaces.

**Active lab footprints** (contexts, IPs, reach commands → `docs/session-state.md`):
- **Evidence cluster (Portworx)** — authoritative Exp-4 evidence env (BackupPlan, SQL
  CREDENTIAL, `demo_db` 16 rows). *Don't touch unless rerunning experiments.*
  State unverified since 2026-06-01; eval grace ended 2026-06-03.
- **Consume/validate cluster (LVMS/TopoLVM)** — `win2k25-mssql` **recreated via the
  UI from `:2026-06-18`**; SSH (NodePort → PowerShell, key auth) + RDP validated,
  **no § 5c needed**. **No SQL yet.** DataImportCron `win2k25-trilio-golden` now
  imports `:2026-06-18` (cron spec is immutable → delete+recreate to retag).
  sysprep ConfigMap `sysprep-win2k25-mssql-lsn0fz` exists standalone. **`D:` data
  disk confirmed present → SQL-ready** (next-session SQL install can proceed).
- **Build cluster (Ceph RBD)** — golden-image BUILD cluster. **`win2k25-v1` DV =
  the sole golden** (inbox SSH, validated; old `win2k25` DV deleted — the
  `:2026-06-16` ghcr tag is the only remaining fallback). Registry tag
  `:2026-06-18` pushed. Pipeline `windows-efi-installer` v4.21.0 in the build ns.

*Golden-image rebake → distribute → validate is DONE (2026-06-18). Below is what's left.*

**Open items (priority order — MSSQL POC is the focus now):**
1. **Install SQL Server** on the consume `win2k25-mssql` (it's SQL-ready: `D:`
   disk present) — § 6 of prep doc; BackupPlan/Restore then need adapting for the
   TopoLVM `VolumeSnapshotClass`.
2. **MSSQL-VSS POC tracks (primary deliverable, still untouched)** — Trilio
   virt-launcher hook (QGA-exec lifecycle); in-guest VSS component requestor
   ("Mechanism E"; deferred Q: does it work via QGA freeze/thaw alone?); demo to
   engineering.
3. **Send the customer reply + internal status email** — drafts at
   `private-docs/2026-06-01-*.md`, never sent.
4. **Carried POC/evidence work:** Python write generator → backup #2 under load →
   FLR demo → BackupPlan v2 (Routes + host-rewrite) → bundle `output/` for the
   blog agent → Confluence article + blog. (Detail in § Project Status.)
5. **(Lower — golden-image infra, deprioritized):** build a new lean golden image
   (§ Project Status); apply the port-based-rule fix to the 2022 golden recipe
   (gitignored `collateral/configmap-win2k22-golden-v2.yaml` — 2022 has no inbox
   OpenSSH, keeps GitHub-zip + a uniquely-named port-based `-Profile Any` rule).

   *Optional cleanup: delete the superseded `:2026-06-16` ghcr tag. The 60Gi
   `win2k25-build-scratch` PVC (build cluster) is reusable — keep for next export.*

**Continuity reminders:**
- **Be deliberate about which cluster you touch** — three live footprints on
  different storage backends; the evidence cluster is the protected env.
- The last several sessions have all been golden-image infrastructure; the POC
  tracks (item 3) are the real deliverable and keep getting deferred.
- Real cluster/VM/customer identifiers live in the gitignored `CLAUDE.local.md`
  (auto-loaded) + `docs/session-state.md` — refer to them here by role-label
  only. Caveat: prior commits already exposed some identifiers in public git
  history (scrubbing forward ≠ scrubbing the past).

Full archaeology: `docs/session-state.md` — consult when prior-thread depth,
decision reasoning, or ruled-out paths are needed.
