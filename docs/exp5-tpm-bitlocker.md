# Experiment 5 — BitLocker on a persistent vTPM: does TPM state survive a TVK backup/restore?

*Designed 2026-07-07. Executed 2026-07-07/08. Status: **DONE — hypothesis
falsified, clean finding.** Full evidence + architecture discussion:
`output/exp5-tpm-bitlocker-20260708.md`. Customer/SA-facing writeup:
`output/confluence-bitlocker-vtpm-guide.md`.*

## Result summary (read this first)

TVK 5.3.1's backup controller **unconditionally excludes** the KubeVirt
persistent vTPM/EFI state PVC from backup data — confirmed via the `Backup`
CR's own status message (`type: KubeVirt backend storage PVC excluded`) and
by checking the `Backup`/`BackupPlan` CRD schemas for an override (none
exists). Our labelSelector-scoping hypothesis below was falsified: TVK
excludes this PVC regardless of how it's selected. Every restore of a
vTPM-backed VM gets a **brand-new vTPM** (proved by both a new PVC suffix
and a differing `Get-Tpm` `OwnerAuth` value). A VM with BitLocker sealed to
the old vTPM will **always** hit the recovery screen on restore — this is
expected, not a bug, and the escrowed 48-digit recovery password is a full,
unconditional unlock (it doesn't depend on TPM state at all). See the
evidence bundle for the full table of proof points and the architecture
discussion (vTPM sealing vs. storage-layer KMS encryption) that came out of
this.

## Question (customer-driven)

Can Trilio for Kubernetes back up and restore an OpenShift Virtualization
Windows VM whose OS disk is **BitLocker-encrypted and sealed to a persistent
vTPM**, such that the restored VM boots **without a BitLocker recovery key**?

## Background — what we already know (lab-verified 2026-07-07)

- The OCP Virtualization Windows catalog templates add
  `tpm: {persistent: true}` and persistent EFI to every Windows VM by
  default. Our lab VMs have a live, enabled vTPM even though we never
  configured one (`Get-Tpm` → Present/Ready/Enabled all True).
- KubeVirt stores the persistent vTPM (swtpm) + EFI nvram state in a **side
  PVC** labeled `persistent-state-for: <vm-name>` (name
  `persistent-state-for-<vm>-<random>`). This PVC is **not referenced in the
  VM spec's volumes**, so a VM-scoped BackupPlan never captures it.
- Our 2026-05-28 restore proved the consequence: the restored namespace's
  state PVC has a *different* random suffix, a creation timestamp equal to
  the restore day, and an ownerReference pointing at the restored VM —
  KubeVirt **minted a fresh, blank vTPM** at first boot. Windows didn't
  care, because BitLocker was off (on Windows *Server* the BitLocker feature
  isn't even installed by default).
- Device-level TPM restore is already proven — including a Windows 11 VM
  (which *requires* vTPM) backed up and restored **cross-cluster**, booting
  fine. The open question is purely about TPM *state*, which only matters
  once something (BitLocker) is sealed to it.

## Hypothesis

If the `persistent-state-for` PVC is added to the BackupPlan scope (via
labelSelector), TVK will capture its data, restore it alongside the VM, and
KubeVirt's backend-storage will **adopt** the restored PVC (label lookup)
instead of minting a fresh one — so the restored swtpm state matches, PCR
sealing holds, and BitLocker auto-unlocks.

## Arms

| Arm | Setup | Expected result |
|---|---|---|
| **A — experiment** | Restore the full backup (VM + disks + state PVC) into a fresh namespace | Boots to login **without** recovery prompt; `manage-bde -status C:` → Protection On; marker file present |
| **B — control** | On the restored VM: stop, **delete the state PVC**, start (KubeVirt mints a blank vTPM) | Boot halts at the **BitLocker recovery screen**; entering the escrowed 48-digit recovery password unlocks and boots |

Arm B doubles as the recoverability story: even in the worst case, the
escrowed recovery key gets the data back.

## PASS criteria (arm A)

1. The restore namespace's state PVC has the **same random suffix** as the
   source's (proves TVK restored it; KubeVirt-minted ones get a new suffix).
2. Exactly **one** state PVC exists in the restore namespace (no second,
   KubeVirt-minted one — proves adoption, not coexistence).
3. VM reaches the login screen with **no recovery prompt** (VNC screenshot).
4. In-guest: `Get-BitLockerVolume C:` → ProtectionStatus **On**, and the
   pre-backup marker file is intact.

## Test environment

- **Cluster:** the Portworx evidence cluster (OCP 4.18, OCPv + TVK, SC
  `px-csi-replicated`, snapshots via `px-csi-snapclass`).
- **Namespaces:** `tpm-lab` (source), `tpm-lab-restore` (restore).
- **Image:** win2k25 golden containerDisk
  `ghcr.io/trilio-demo/win2k25-golden:2026-06-18` (private — needs the
  `ghcr-cdi` pull secret; see `docs/ghcr-secret.example.yaml` +
  `docs/win2k25-vm-prep.md` § 1a).
  > **Finding (2026-07-07):** this cluster's stock `win2k25` DataSource
  > (`openshift-virtualization-os-images`) is broken — backing PVC
  > `NotFound`, no DataImportCron feeding it. Only `win2k22` is actually
  > present cluster-wide. `manifests/exp5-win2k25-dataimportcron.yaml` fixes
  > this with a **distinct** `win2k25-trilio-golden` DataSource fed from
  > ghcr (doesn't touch/clobber the broken stock one) — apply it before
  > `exp5-vm.yaml`, which clones from it via `sourceRef`.
- **VM:** `win2k25-tpm` — u1.medium (1 vCPU / 4 Gi), single 32 Gi root disk,
  `tpm: {persistent: true}`, persistent EFI, secureBoot off (matches the
  evidence VM; keeps the boot chain simple). No SQL, no data disk, no hooks.
- **Manifests:** `manifests/exp5-*.yaml`.

## Procedure

### Phase 0 — provision (one-time, ~45 min mostly waiting)

```bash
CTX=<evidence-cluster-context>
oc --context $CTX create ns tpm-lab
oc --context $CTX create ns tpm-lab-restore

# ghcr pull secret — needed in BOTH namespaces below (image is private):
export GHCR_USER=<github-username>
export GHCR_READ_PAT=<read:packages PAT>
envsubst < docs/ghcr-secret.example.yaml | oc --context $CTX apply -n openshift-virtualization-os-images -f -
envsubst < docs/ghcr-secret.example.yaml | oc --context $CTX apply -n openshift-cnv -f -   # cron's digest-poll job

# fix the cluster's broken win2k25 boot source (see finding above) — one-time,
# shared by any future win2k25 work on this cluster, not just this experiment:
oc --context $CTX apply -f manifests/exp5-win2k25-dataimportcron.yaml
oc --context $CTX get datasource win2k25-trilio-golden -n openshift-virtualization-os-images -w
#   wait for conditions: Ready=True (DV import ~20-30 min)

# sysprep answer file for the clone:
oc --context $CTX create configmap win2k25-tpm-sysprep -n tpm-lab \
  --from-file=unattend.xml=docs/unattend.xml

# VM (clones from the fixed DataSource; first boot + sysprep ~10 min):
oc --context $CTX apply -f manifests/exp5-vm.yaml
oc --context $CTX get dv -n tpm-lab -w

# SSH/RDP NodePorts + key upload + ACL fix: docs/win2k25-vm-prep.md § 5.
oc --context $CTX apply -f manifests/exp5-access-services.yaml   # tpm-lab services
```

Activation (`slmgr /ato`) per `docs/win2k25-vm-prep.md` § 4 — remember the
guest **MTU 1400** fix first (§ 4a); this cluster's overlay black-holes
large HTTPS transfers at guest MTU 1500.

### Phase 1 — enable BitLocker on C: (sealed to the vTPM)

All via SSH → PowerShell (or RDP). BitLocker is an optional feature on
Server and needs a reboot:

```powershell
Install-WindowsFeature BitLocker -IncludeAllSubFeature -IncludeManagementTools -Restart
```

After reboot:

```powershell
Get-Tpm    # expect Present/Ready/Enabled = True

# Recovery password first (escrow), then TPM protector + encryption:
Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector
(Get-BitLockerVolume -MountPoint C:).KeyProtector   # RECORD the RecoveryPassword
Enable-BitLocker -MountPoint C: -TpmProtector -UsedSpaceOnly -SkipHardwareTest

# poll until VolumeStatus=FullyEncrypted, ProtectionStatus=On (~10-20 min used-space-only):
Get-BitLockerVolume -MountPoint C:
```

**Escrow the recovery password** on the Mac in gitignored
`collateral/exp5-bitlocker-recovery.txt` — it is the arm-B unlock and the
only escape hatch if anything goes sideways.

Then prove the baseline and drop a marker:

```powershell
Set-Content C:\exp5-marker.txt "exp5 source $(Get-Date -Format o)"
Restart-Computer -Force
# after reboot: VM must reach login with NO recovery prompt (vTPM auto-unlock works at source)
```

### Phase 2 — backup

`manifests/exp5-backupplan.yaml` is the interesting part: the usual VM
gvkSelector **plus** a labelSelector that pulls the state PVC into scope:

```yaml
selectResources:
  gvkSelector:
    - groupVersionKind: {group: kubevirt.io, kind: VirtualMachine, version: v1}
      objects: [win2k25-tpm]
  labelSelector:
    - matchLabels:
        persistent-state-for: win2k25-tpm
```

```bash
oc --context $CTX apply -f manifests/exp5-backupplan.yaml
oc --context $CTX create -f manifests/exp5-backup.yaml     # generateName — announce the CR name
```

**Gate before proceeding:** confirm the backup's captured-resource list (TVK
UI or Backup CR status) includes the `persistent-state-for-win2k25-tpm-*`
PVC *with data snapshot*, not just metadata. If it's absent, stop — that's
finding #1 (fallback: add the PVC by exact name via a
`PersistentVolumeClaim` gvkSelector entry and re-run).

### Phase 3 — arm A (restore with state PVC)

```bash
# fill spec.source.location from: oc get backup <name> -n tpm-lab -o jsonpath='{.status.location}'
oc --context $CTX create -f manifests/exp5-restore.yaml
```

Immediately after the restore completes, **before judging boot behavior**:

```bash
oc --context $CTX get pvc -n tpm-lab-restore        # state PVC suffix must MATCH the source's; count must be 1
oc --context $CTX get pvc -n tpm-lab-restore -l persistent-state-for=win2k25-tpm \
  -o jsonpath='{range .items[*]}{.metadata.name}{" owner:"}{.metadata.ownerReferences}{"\n"}{end}'
```

⚠️ If an ownerReference survived the restore pointing at the *old* VM UID,
the garbage collector will delete the PVC — strip it fast and record the
finding.

Watch first boot on the VNC console (`virtctl vnc` or the web console) —
screenshot either outcome. Then in-guest verification (services in
`manifests/exp5-access-services.yaml`, tpm-lab-restore section):

```powershell
Get-BitLockerVolume -MountPoint C:      # ProtectionStatus On
Get-Content C:\exp5-marker.txt          # timestamp matches source
Get-Tpm
```

### Phase 4 — arm B (control: blank vTPM ⇒ recovery screen)

On the **restored** VM (arm A evidence is already captured):

```bash
virtctl --context $CTX stop win2k25-tpm -n tpm-lab-restore
oc --context $CTX delete pvc -n tpm-lab-restore -l persistent-state-for=win2k25-tpm
virtctl --context $CTX start win2k25-tpm -n tpm-lab-restore
# KubeVirt mints a fresh blank state PVC (new suffix) → BitLocker recovery screen expected
```

Screenshot the recovery screen (the money shot), then enter the escrowed
recovery password on the console to prove data recoverability; screenshot
the successful unlock. Optionally re-seal afterwards
(`manage-bde -protectors -add C: -tpm` after clearing the stale protector)
— not required for the experiment.

### Phase 5 — evidence + teardown

- Evidence bundle → `output/exp5-tpm-bitlocker-<date>.md` + raw artifacts
  (PVC listings with timestamps/suffixes, backup/restore CR yamls, console
  screenshots, in-guest transcripts).
- Teardown: delete `tpm-lab-restore` ns; keep `tpm-lab` + the backup until
  the Confluence article's screenshots are confirmed good.
- **Follow-up deliverable:** Confluence replication guide (CLI commands +
  screenshots) — customers are asking whether this works.

## Failure modes and what each one means

| Symptom | Diagnosis | Disposition |
|---|---|---|
| Backup captures state-PVC metadata but no data snapshot | TVK labelSelector scope doesn't data-snapshot standalone PVCs | Retry with explicit PVC gvkSelector; if still no → TVK JIRA |
| Restore-ns state PVC has a **new** suffix + recovery prompt | TVK never restored the PVC, KubeVirt minted fresh | Check Restore CR resource list; TVK finding |
| **Two** state PVCs in restore ns | KubeVirt didn't adopt the restored PVC (lookup/ordering issue) | virt-controller logs; likely KubeVirt version behavior — upstream finding |
| State PVC restored then **vanishes** | Stale ownerReference → garbage-collected | TVK finding (ownerRef handling); re-run stripping ownerRef |
| PVC adopted (same suffix, single) but **still** recovery prompt | PCR mismatch despite state restore (boot-chain measurement drift) | Deep-dive: compare OVMF/firmware config; may need `-UsedSpaceOnly` PCR profile analysis |
| Recovery password rejected in arm B | Transcription error in escrow | Re-check `collateral/exp5-bitlocker-recovery.txt` against `manage-bde -protectors -get C:` output taken at Phase 1 |

Every failure row is itself a publishable finding (and likely a JIRA /
upstream issue) — the experiment produces value either way.

## Out of scope (follow-ups)

- **Cross-cluster restore** of the BitLocker VM (swtpm state is plain files
  in the PVC — no host binding expected, but prove it separately).
- Secure Boot **on** (adds PCR 7 to the sealing profile — repeat arm A with
  `secureBoot: true` once the baseline passes).
- Windows 11 client-edition auto-encryption (customer-realistic variant of
  the same mechanism).
