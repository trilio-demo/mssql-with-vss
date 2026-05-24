# Requirements — restore-mssql-with-vss

## Purpose
Prove, in a lab, that Trilio for Kubernetes (TVK) takes **application-consistent**
backups of Microsoft SQL Server running in a Windows VM on OpenShift
Virtualization (OCPv / KubeVirt) — by coordinating with the QEMU Guest Agent
(QGA), which in turn drives the Windows Volume Shadow Copy Service (VSS) and
the MS SQL VSS Writer.

Why this lab exists: City of Delray Beach (lost to Veeam in October 2025) has
re-engaged through Erick Saidon with a specific question on VSS handling. A
verified lab demonstration neutralizes Veeam's main technical advantage in this
account and produces material for a public technical blog post.

## Hard Requirements (the lab must show all of these)

1. **VSS Freeze/Thaw events visible** in the Windows VM's Event Viewer,
   triggered by Trilio (not by a Veeam agent or any Trilio-installed guest
   software — only the standard QGA shipped by Red Hat for OCPv).
2. **Clean MS SQL recovery on restore** — after restoring the VM from a
   Trilio backup, MS SQL comes back online without entering recovery / repair
   mode and without lost committed transactions.
3. **Surgical File-Level Recovery (FLR)** — extract a single file (e.g. a
   specific `.mdf`, `.ldf`, or `.bak`) from a backup directly through the
   Trilio UI, without restoring the whole VM.
4. **No external Windows server** — the entire backup/restore workflow runs
   through the OpenShift API. No Veeam VBR-style external orchestrator.

## Lab Topology (target)

- **Cluster:** OpenShift with OpenShift Virtualization (OCPv) installed.
- **Storage:** CSI snapshot-capable backend (ODF/Ceph in lab; Portworx in
  customer prod). Backup target = S3 or NFS.
- **VM:** Windows Server (2019 or 2022), QGA installed, joined to a
  workgroup (no AD needed for the lab).
- **Database:** MS SQL Server Developer Edition (free, full feature set).
  At least one user database (`demo_db`) with a recognizable table.
- **Trilio:** TVK operator installed on the cluster, backup target configured.

## Locked Decisions (2026-05-06)

1. **Demo scope: DB-only with a Python write generator.**
   The generator runs a continuous INSERT loop against `demo_db` while the
   Trilio backup executes. No app on top — proving the QGA→VSS handshake is
   the lab's job, and the blog's claim doesn't need a UI to be credible.
2. **Cluster: `ocp-dev`** — existing 3-node OpenShift lab with OCPv. No new
   cluster provisioning. All work happens here.
3. **Python tooling set up:** pyenv 3.13.13 + uv. `pyproject.toml`,
   `.python-version`, `uv.lock` committed. No deps yet — SQL Server driver
   (`pymssql` vs `pyodbc`) gets added when we know where the generator runs.
4. **Repo finalization (bootstrap step 13): deferred** until after first
   successful lab run, so the first commit captures real artifacts, not
   just scaffolding.

## Still to Confirm Before Lab Stand-Up

- Access to `ocp-dev` (kubeconfig, cluster-admin or sufficient role,
  OCPv operator installed and healthy, a working `VolumeSnapshotClass`).
- A Windows Server source available on `ocp-dev` — DataVolume from a
  registry image, an ISO uploaded to a PVC, or a containerdisk reference.
- Trilio operator availability and a license / trial usable on `ocp-dev`.
- Where the Python write generator runs:
  - **Vince's Mac** — needs SQL endpoint exposed (NodePort/Route + TCP
    passthrough). Driver likely `pymssql` (FreeTDS via Homebrew).
  - **In-cluster pod** — driver likely `pymssql` on a Linux base image.
  - **Inside the Windows VM** — Python on Windows + `pyodbc` with the
    Microsoft ODBC driver. Highest fidelity to "real" workload.
  Pick after we see the cluster's network/exposure model.

## Capture Plan — for the Blog-Writing Agent

Everything below lands in `output/` as we go, named descriptively. The
blog-writing agent (separate project) will consume this bundle.

### Diagrams
- **Architecture diagram:** OCPv node, Windows VM, QGA, VSS Writer, CSI driver,
  Trilio control plane, S3/NFS target. Mermaid.
- **Sequence diagram:** the freeze → snapshot → thaw handshake. Mermaid.

### Lab evidence (raw)
- **Windows Event Viewer captures** showing VSS Writer freeze/thaw events
  (event IDs from `VSS` and `SQLWriter` sources), timestamped against the
  Trilio backup run.
- **Trilio UI screenshots:** target configured, backup policy, backup running,
  completed snapshot, FLR browse view, single-file restore in progress, restore
  complete.
- **`sqlcmd` transcripts:** pre-backup state of `demo_db` (row count, last
  inserted row), post-restore verification of the same.
- **Negative control (optional):** repeat the backup with QGA service stopped
  to capture what "crash-consistent" actually looks like — SQL coming back in
  recovery state, or with rolled-back transactions. This is the strongest
  visual contrast for the blog.

### Narrative notes
For each phase, a short markdown note in `output/notes/` covering:
- What we did (commands, manifests applied).
- What we expected.
- What we actually saw (link to the screenshot/log).
- What it proves about the QGA → VSS path.
- Anything surprising — those are the parts the blog will lead with.

### "What we did NOT need" — the differentiator
The blog's central claim is *the absence of the Veeam tax*. Capture explicitly:
- **No Trilio-installed software inside the VM** — only the standard Red Hat
  QGA. Verify with `Get-Service` in the Windows VM and a `tasklist` snapshot.
- **No external Windows VBR-style server** — show the `oc get pods -A`
  filtered for Trilio components, all running on the OCP cluster itself.
- **No proprietary backup format** — the backup is QCOW2 + JSON metadata,
  inspectable on the target.

## Customer Context (for prioritization)

- **Customer:** City of Delray Beach (FL) — municipal government.
- **Environment:** Migrating VMware → OCPv. Storage: Portworx CSI + Pure
  cluster storage + Exagrid (NFS or S3) for backup with replication to DR.
  9 hosts (5 prod / 4 DR), 70 production VMs (~90% Windows).
- **History:** Lost to Veeam in October 2025. Post-mortem cited Exagrid
  integration, Veeam management familiarity, and Veeam's OCPv file recovery.
- **Re-entry:** Erick Saidon (Infrastructure Engineer) asked specifically how
  Trilio handles MS SQL backup, VSS shadow copy, and quiescence. Classic
  technical wedge — likely hitting friction with Veeam's external Data Mover
  in the OCPv environment.

## Internal References (Trilio Confluence — auth required, not fetched here)

Listed in conversation; consult during write-up:
- *Trilio vs Kasten, where Trilio is better* — `triliodata.atlassian.net/wiki/spaces/SA/pages/4160061442/`
- *Trilio's OpenShift Virtualization SWOT Analysis* — `…/spaces/KUB/pages/4179460106/`
- *Trilio for OpenStack & Application-Consistent Backups* — `…/spaces/SA/pages/4701224962/`
  (principles transfer to TVK via QGA)
- *Trilio vs. Commvault for Kubernetes: Storytelling* — `…/spaces/SA/pages/4557438978/`
- *Near Real-time RPO with PostgreSQL and WAL* — `…/spaces/Blogs/pages/4993253377/`

## Out of Scope

- Writing the blog post itself — that's a separate agent with its own repo.
- Customer pricing, contracts, or Exagrid-specific compatibility testing.
- Production deployment of TVK at City of Delray Beach. This is a lab POC only.
- AD integration, Always On Availability Groups, or clustered SQL — single VM,
  single SQL instance is sufficient to prove the VSS coordination claim.
- Continuous Restore / near-zero RTO testing — referenced as a Trilio
  differentiator but not part of this lab's scope.
