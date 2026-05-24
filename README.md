# mssql-with-vss

Lab POC demonstrating **application-consistent backup and restore of Microsoft
SQL Server** running inside a **Windows VM on OpenShift Virtualization (OCPv /
KubeVirt)**, using **Trilio for Kubernetes (TVK)**.

The lab proves the end-to-end **QEMU Guest Agent → Windows VSS Writer**
handshake: TVK signals freeze, SQL Server's VSS writer flushes and quiesces,
the CSI snapshot is taken on a consistent point, then thaw resumes writes.
On the restore side, we verify the database comes back clean (no recovery
state) and demonstrate **surgical file-level restore** of `.mdf` / `.ldf` /
`.bak` files from a backup.

## Stack

- OpenShift 4.18 + OpenShift Virtualization (CNV / KubeVirt)
- Trilio for Kubernetes 5.1.2
- Portworx CSI (snapshot-capable)
- Windows Server 2022 + MS SQL Server Developer Edition
- QEMU Guest Agent (in-guest)
- Python 3.13 (write generator driving continuous DB inserts during backup)

## Layout

- [`CLAUDE.md`](CLAUDE.md) — project context, decisions, current status
- [`docs/requirements.md`](docs/requirements.md) — lab spec and capture plan
- [`docs/windows-vm-prep.md`](docs/windows-vm-prep.md) — standalone Windows VM
  build guide (golden image → SQL ready) for OCPv
- `src/` — Python tooling (write generator, PDF inspector for collateral)
- `output/` — lab evidence: Event Viewer captures, Trilio UI screenshots,
  restore transcripts, diagrams. **Gitignored** — populated locally during
  lab runs.

## Status

Active. See [`CLAUDE.md`](CLAUDE.md) → *Project Status* for the live checklist.
