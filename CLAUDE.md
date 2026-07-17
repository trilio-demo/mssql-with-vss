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
- [ ] **Bake parked `docs/windows-vm-prep.md` updates** (carried from 2026-05-25/28): ~~(a) ODBC 18 self-signed cert workaround~~ **DONE 2026-07-17** (`-C` added to § 6 verify commands + § 7 checklist, explained in both docs); (b)/(c) verified already covered — `Initialize-Disk` + CD-detach are in § 3/§ 4b + checklist, and § 6's installer-time `D:\MSSQL\*` data-dir guidance supersedes the `xp_instance_regwrite` relocation (still referenced in lab-guide troubleshooting for manual movers); (d) `type: Location` Restore CR pattern + cross-NS NodePort collision footnote + Routes-via-BackupPlan plan; (e) `micro` editor scp-from-Mac note; SSMS still deferred.
- [ ] Bundle evidence in `output/` for the blog-writing agent (backup #1 packet copied 2026-05-25; restore-verification + FLR + load-test + MVP-validation packets still pending)
- [ ] **Draft customer-facing technical response to the customer** — frame around the C+F MVP path (5-min RPO) with lab evidence citations + RPO/RTO positioning vs. crash-consistent baseline. Source material: `private-docs/research-tvk-mssql-vss-deep-dive.md`.
- [x] Repo shipped (bootstrap step 13): **https://github.com/trilio-demo/mssql-with-vss** (public, 2026-05-24)
- [x] **Lab guide published to public repo (2026-06-07).** `docs/lab-guide.md` — 12-step reproducible procedure with inline SQL + manifests + troubleshooting. Audience-widened (not just "Trilio colleagues"), scrubbed of internal taxonomy + competitive/roadmap framing. Internal-only companion docs (`flow.md`, `flow-prompt-claude-design.md`, `flow.pdf`) parked in `private-docs/`. `*.pdf` gitignored. Commit `a683311` on `origin/main`.
- [x] **Shareable VM-build recipe shipped (2026-06-08).** `docs/unattend.xml` (new, heavily commented Sysprep answer file) + restructured `docs/windows-vm-prep.md` (cluster-agnostic; § 4e SSH install rewritten as 3 paths — `Add-WindowsCapability` / GitHub zip / RDP drag-and-drop). Commit `7dda088` on `origin/main`. Validated end-to-end by spinning a fresh VM on a *different* cluster (the TopoLVM consume cluster, not the original Portworx evidence cluster) — see Session State for the new lab footprint.
- [x] **Sub-track 1 Phase 1 PASS (2026-07-04): TVK virt-launcher hook drives in-guest MSSQL.** Hook CR `mssql-anchor-hook` + BackupPlan `hookConfig` (podSelector `vm.kubevirt.io/name`, containerRegex `^compute$`) → pre-hook takes + verifies a `COPY_ONLY` anchor via QGA guest-exec as SYSTEM on every backup. Validated backup #7 `mssql-vss-backup-rlkmn` (clean 4s freeze, 7×3197/3198/18264). **Three TVK findings (cost backups #3–#6):** (1) ordering = pre → freeze → snapshot → post-hook → thaw, thaw WAITS for post-hook, and QGA disables guest-exec while frozen → post-hooks must be freeze-safe + fast (guest-ping only); (2) freeze held >60s trips the SQL VSS writer timeout (thaw at +60s, no 18264 completions); (3) TVK pins Hook resourceVersion into BackupPlan at admission — **CORRECTED 2026-07-16 via marker-based repro (`repro/hook-sequencing/`): execution follows the LIVE Hook content; the stale pin is an audit-trail bug (BackupPlan pin + Backup.status.hookStatus both report a hook version that didn't run). The 07-04 "backup #4 re-ran the old hook" inference was wrong — that failure was finding (1).** Evidence: `output/hook-poc-20260704.md` + 5 raw artifacts; manifests updated.
- [x] **Decision (2026-07-05): the `BACKUP LOG → S3` cadence is application/DBA-owned** (SQL Server Agent job), NOT Trilio-orchestrated — "Mechanism F" is now the primary shape. Options, rationale, and the pre-hook log-chain freshness-check idea (future work): `private-docs/log-backup-cadence-decision-20260705.md`. Customer-facing sources updated to match (cadence = DBA-owned; anchor = automatic): `output/trilio-mssql-app-consistency-approach.md` + `private-docs/flow-prompt-claude-design.md` — Vince refreshes the Cowork PPT + Claude Design visual from these.
- [x] **Hook-sequencing repro kit shipped to engineering (2026-07-16).** `repro/hook-sequencing/` — Windows-free minimal repro (Fedora VM + probe Hook; log = pass/fail oracle) validated end-to-end on the evidence cluster, pushed (`b130d7d`), zipped + attached to the hook-sequence JIRA with a clarifying comment (freeze *held* not failed; backward-compat trade-off of reorder-thaw vs `postUnquiesce`). Same session: **RV-pinning finding corrected via marker test** — live Hook content executes; defect is audit-trail misreport only. Repro ns torn down; Vince to verify the eventual fix (5.4.0) on the Windows VM.
- [x] **JIRA ticket filed (2026-07-05) for TVK hook improvements** from the hook POC — source: `private-docs/tvk-product-recommendations-hook-poc-20260704.md` (post-thaw hook point, native guestExecAction, stale-RV pinning fix, hook output capture, freeze-duration guardrail, docs).
- [ ] **Prototype in-guest VSS component requestor** — A2 path / "Mechanism E." POC scope: hardcoded MSSQL + `SqlServerWriter`, single SQL/Windows version. Drive via QGA-exec first. **Deferred design Q:** can it work via QGA freeze/thaw alone (no QGA-exec)? If yes, hook + VSS tracks collapse into one.
- [ ] **Demo POC to Trilio engineering** — handoff so engineering productionizes a multi-DB component requestor (VSS writer-GUID enumeration → Exchange, AD DS, etc.). Sales narrative: "one mechanism → n databases" vs. per-DB Explorer-style integrations.
- [ ] **Confluence article + blog** — org/customer narrative tying the hook mechanism + VSS POC together. Distinct from `docs/lab-guide.md` (which is the reproducibility guide for the today-proven path).
- [x] **Experiment 5 — BitLocker/vTPM backup+restore (2026-07-07/08, DONE).** Customer-driven question: does TVK back up/restore an OCPv Windows VM with a **persistent vTPM + BitLocker-encrypted C:** without falling back to the recovery key? **Result: no — by TVK's own design.** TVK 5.3.1 unconditionally excludes the KubeVirt `persistent-state-for` PVC (vTPM/EFI state) from backup data (confirmed via the Backup CR's own status message + a CRD-schema check for an override — none exists). Every restore mints a brand-new vTPM (proved via differing PVC suffix + differing `Get-Tpm` `OwnerAuth`); a BitLocker-sealed VM always hits the recovery screen, and the escrowed 48-digit recovery password is a full unconditional unlock (lab-verified end to end, screenshot captured). Architecture follow-up: for backup/DR-friendly encryption-at-rest, recommend storage-layer KMS (Portworx + Vault) over guest BitLocker+vTPM. Full evidence: [`output/exp5-tpm-bitlocker-20260708.md`](output/exp5-tpm-bitlocker-20260708.md). **Confluence article written:** [`output/confluence-bitlocker-vtpm-guide.md`](output/confluence-bitlocker-vtpm-guide.md) — SA/Support-facing replication guide + customer-expectation framing + architecture guidance. Design doc: [`docs/exp5-tpm-bitlocker.md`](docs/exp5-tpm-bitlocker.md). **Found while scoping:** ocp-px's stock `win2k25` DataSource was broken (PVC `NotFound`, no cron) — `manifests/exp5-win2k25-dataimportcron.yaml` fixed it with a distinct `win2k25-trilio-golden` DataSource, reusable beyond this experiment. **Decision (2026-07-12): not filing a feature-request JIRA for a BackupPlan-level opt-in** — TVK Product will instead document that the vTPM/EFI state PVC exclusion is intentional behavior. (Unrelated to the separately-filed hook-sequence JIRA, now targeted for 5.4.0 — see below.) Lab namespaces `tpm-lab`/`tpm-lab-restore` on ocp-px torn down (2026-07-12) — this experiment's lab footprint is fully cleaned up.
- [x] **Experiment 6 — plain freeze/thaw-only MSSQL backup/restore (2026-07-09, DONE).** Customer-driven question: does a *regular* Trilio VM backup (no custom hook, no guest-exec) leave MSSQL working after restore, or is some extra mechanism needed to bring it out of the frozen state? **Result: no extra mechanism needed — vanilla QGA freeze/thaw is sufficient.** Confirmed via a fresh, hook-free BackupPlan (`mssql-vss-backupplan-nohook`, additive — doesn't touch the Sub-track 1 hook-enabled one): standard 7×3197/7×3198/7×18264 signature fired automatically (4s freeze window), restore came back with `demo_db` ONLINE, marker row intact with exact original timestamp, **and a fresh write succeeded post-restore** (row 17→18) — proving full read/write health, not just readability. This reconfirms (with fresh, live, restorable evidence) what backup #1 already showed back on 2026-05-25 before the custom hook existed — that original backup was since pruned by retention. Full writeup: [`output/exp6-freeze-thaw-only-20260709.md`](output/exp6-freeze-thaw-only-20260709.md). Manifests: `manifests/backupplan-nohook.yaml`, `manifests/backup-nohook.yaml`, `manifests/restore-exp6.yaml`. Restore ns `mssql-vss-restore-exp6` torn down (2026-07-09); the no-hook BackupPlan + its backup remain on ocp-px for reference.
- [ ] **Experiment 7 (planned, 2026-07-09) — TVK 5.4.0 S3-streaming comparison.** TVK 5.4.0 ships significant S3 streaming improvements. Plan: repeat the MSSQL backup/restore tests (freeze/thaw timing, backup/restore wall-clock, data sizes) on 5.4.0 and compare against the 5.3.1 baseline already captured (backup #1, Exp-4, Exp-6). **Target cluster still TBD — Portworx evidence cluster (in-place upgrade) vs. a separate cluster** (avoids disturbing the live Sub-track 1 / hook-POC environment on ocp-px, but means rebuilding the SQL VM elsewhere). Decide before starting.

---

## Session State

*Forward-looking brief — read at start of each session. Backward-looking
archaeology (thread-by-thread detail, decisions + reasoning, ruled-out paths,
detailed per-cluster lab state) lives in `docs/session-state.md`.*

**Last session (2026-07-16 — engineering handoff: repro kit shipped; RV finding corrected):**
Engineering is duplicating the hook/QGA sequencing tests. Built + validated
`repro/hook-sequencing/` — a **Windows-free minimal repro** (Fedora VM + probe
Hook whose log is the pass/fail oracle, ~15 min end-to-end); validated live on
the evidence cluster (POST hook saw `frozen`, guest-exec rejected, thaw waited
<1 s after hook exit), then pushed (`b130d7d`), zipped + **attached to the
hook-sequence JIRA** with a clarifying comment (quiesce doesn't fail — the
freeze is *held*, silently degrading to crash-consistent past SQL's 60 s VSS
timeout; backward-compat trade-off: reorder-thaw vs. a `postUnquiesce` hook
point). **Do not reference the SA cluster in the ticket** — some engineers
can't reach it. **Finding 3 OVERTURNED by marker test:** backups execute the
LIVE Hook even with a stale RV pin; the real defect is audit-trail misreport
(pin + `Backup.status.hookStatus` show a version that didn't run) — the 07-04
"stale hook re-ran" was a misattribution (backup #5's post-re-pin failure was
the tell). Vince dropped the RV topic from the JIRA. Repro ns torn down.
**Vince committed (Slack) to verifying engineering's eventual fix against the
Windows/MSSQL evidence VM.**

**Prior session (2026-07-07 through 07-12 — Experiments 5 & 6, both DONE):**
Exp 5 (BitLocker/vTPM): TVK 5.3.1 unconditionally excludes the vTPM/EFI state
PVC → every restore mints a new vTPM; escrowed recovery password is a full
unlock. Confluence guide shared 07-08. Exp 6: plain hook-free freeze/thaw
backup restores MSSQL fully working (fresh-write verified). A second
MSSQL-interested prospect surfaced (see `CLAUDE.local.md`) — 2 customers now
care about this story. Detail: `docs/session-state.md`.

**Context for the week:** the **feature-readiness call (week of 07-06)** on the
partner-led re-entry (see `CLAUDE.local.md`) — check whether it already
happened / what came out of it, since this brief predates knowing the
outcome.

**Win (2026-07-17): engineering is adopting the MSSQL lab in their own
environment.** They asked for the repo (already shared) + install guidance —
the recipe docs are now serving engineering, not just the sales track. Docs
verified self-sufficient for the SQL install; the one gap (`sqlcmd -C`
unexplained / missing from § 6 verify commands) was baked same day.
Golden-image access decided (2026-07-17): **stays PAT-gated** — engineering
has repo access and can set up their own GHCR read-PAT per
`docs/ghcr-secret.example.yaml` + the prep docs. Handoff complete; nothing
further owed to them.

**Next session** — **Experiment 7 (TVK 5.4.0 S3-streaming comparison) is
explicitly parked — Vince confirmed nothing to do here for a couple of
weeks (as of 2026-07-12).** Don't pick a cluster or start setup unless he
raises it. **No Exp-5 JIRA to file** — Vince decided (2026-07-12) to hold
it; TVK Product will document the vTPM/EFI exclusion as intentional instead
(unrelated to the separate hook-sequence JIRA, already filed, now targeted
for 5.4.0). `tpm-lab`/`tpm-lab-restore` torn down (2026-07-12) — Experiment
5 is fully closed out, nothing left over. Then likely post-call
follow-ups, plus the natural MSSQL lab continuation: enable SQL Agent + the
5-min `BACKUP LOG TO URL` job on the evidence VM, add the pre-hook log-chain
freshness check (follow-on steps in the cadence decision doc), then Python
write generator → backup under load → FLR.

**Active lab footprints** (contexts, IPs, reach commands → `docs/session-state.md`):
- **Evidence cluster (Portworx)** — authoritative Exp-4 evidence env (BackupPlan, SQL
  CREDENTIAL, `demo_db` 18 rows post-Exp-6). **Now also the Sub-track 1 dev env
  (Vince, 2026-07-04)** — PX license renewed. Verified 2026-07-04: VM Running, SQL
  services healthy; **fixed guest MTU (1400) + activated eval (`slmgr /ato`,
  expires 12/31/2026)**. **Also carries:** the no-hook BackupPlan + backup
  from Experiment 6 (kept for reference; its restore ns already torn down).
  Experiment 5's `tpm-lab`/`tpm-lab-restore` fully torn down (2026-07-12).
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
0. **Verify engineering's hook-ordering fix when it lands (targeted TVK
   5.4.0):** first against the Fedora repro kit (`repro/hook-sequencing/`
   README defines the fixed-output oracle: POST sees `thawed`, guest-exec
   ALLOWED, `Unfreezed` before POST start), then a full acceptance run on
   the Windows/MSSQL evidence VM (Vince committed to this on Slack,
   2026-07-16). Nothing to do until engineering produces a candidate build.
1. **Experiment 7 (scoped 2026-07-09, PARKED 2026-07-12) — TVK 5.4.0
   S3-streaming comparison vs 5.3.1 baseline.** Vince confirmed nothing to
   do here for a couple of weeks — **do not start setup or pick a cluster
   unless he raises it.** When resumed: decide target cluster first
   (Portworx evidence cluster in-place upgrade vs. a separate cluster —
   trade-off is disturbing the live Sub-track 1 env vs. rebuilding the SQL
   VM elsewhere), then repeat the MSSQL backup/restore timing tests. **2
   customers now interested in the MSSQL story** (see `CLAUDE.local.md`) —
   this comparison feeds both.
2. **Experiments 5 & 6: DONE.** Exp 5 (BitLocker/vTPM) Confluence article
   shared 2026-07-08; Exp 6 (freeze/thaw-only consistency) evidence
   written 2026-07-09, restore ns already torn down. **No JIRA to file for
   Exp 5** — Vince decided 2026-07-12 to hold it; TVK Product will
   document the vTPM/EFI exclusion as intentional instead (see
   `output/exp5-tpm-bitlocker-20260708.md` Follow-ups section — do not
   confuse with the separate, already-filed hook-sequence JIRA now
   targeted for 5.4.0). `tpm-lab`/`tpm-lab-restore` torn down (2026-07-12)
   — both experiments are fully closed out, nothing left over.
3. **Lab continuation on the evidence VM:** SQL Agent 5-min `BACKUP LOG TO URL`
   job + pre-hook log-chain freshness check (follow-on list in
   `private-docs/log-backup-cadence-decision-20260705.md`; remember the
   BackupPlan RV re-pin after any Hook edit).
4. **Remaining POC tracks:** in-guest VSS component requestor ("Mechanism E";
   deferred Q: QGA freeze/thaw alone? Note: hook POC proved post-hooks run
   frozen — relevant to that design); restore-side hook automation; demo to
   engineering.
5. **Carried POC/evidence work:** Python write generator → backup under load →
   FLR demo → BackupPlan v2 (Routes + host-rewrite) → bundle `output/` for the
   blog agent → Confluence article + blog. (Detail in § Project Status.)
6. **Send the customer reply + internal status email** — drafts at
   `private-docs/2026-06-01-*.md`, never sent (may be superseded by the
   partner-call track).
7. **(Demoted) Install SQL Server on the consume `win2k25-mssql`** — was the
   Sub-track 1 gate, but the hook work moved to the evidence cluster; still
   useful for a second-cluster validation env.
8. **(Lower — golden-image infra, deprioritized):** lean golden image; 2022
   golden recipe port-based-rule fix (`collateral/configmap-win2k22-golden-v2.yaml`).

   *Optional cleanup: delete the superseded `:2026-06-16` ghcr tag. The 60Gi
   `win2k25-build-scratch` PVC (build cluster) is reusable — keep for next export.*

**Continuity reminders:**
- **Be deliberate about which cluster you touch** — three live footprints on
  different storage backends. The evidence cluster is now also the Sub-track 1
  dev env (Vince, 2026-07-04).
- **⚠️ Retention pruned the historical backups:** the latest-5 policy deleted
  backup #1 (`2phcr`) and the Exp-4 backup (`kcxdl`) from the target when this
  session's 5 hook-POC backups landed. Exp-4 *evidence* (files, LSNs) is safe
  in the repo, but the restorable Exp-4 backup no longer exists.
- **Announce backup/long-op launches loudly** (CR name, purpose, ETA) — Vince
  watches the Trilio UI in parallel (memory: `feedback_announce_cluster_runs`).
- Real cluster/VM/customer identifiers live in the gitignored `CLAUDE.local.md`
  (auto-loaded) + `docs/session-state.md` — refer to them here by role-label
  only. Caveat: prior commits already exposed some identifiers in public git
  history (scrubbing forward ≠ scrubbing the past).

Full archaeology: `docs/session-state.md` — consult when prior-thread depth,
decision reasoning, or ruled-out paths are needed.
