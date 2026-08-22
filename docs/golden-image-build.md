# Golden Image Build — Windows Server 2025

How to build the lab's **Windows Server 2025** golden image from an ISO using
the Red Hat **`windows-efi-installer`** Tekton pipeline, so it drops cleanly
into the VM-prep flow. The point of building our own image (vs. the stock
engineering golden image) is to produce **self-sufficient clones**:

1. **virtio + QGA + OpenSSH baked in** — per-VM prep shrinks to "upload your
   key." QGA is load-bearing for the VSS lab (Trilio drives Windows VSS
   freeze/thaw through it); SSH is convenience.
2. **No reliance on a healthy in-image servicing stack or Microsoft Update
   egress at clone time** — everything that needs the network is done **once**,
   at bake time.

> Pairs with [`win2k25-vm-prep.md`](win2k25-vm-prep.md), which consumes the
> resulting image. This brief is the *build* side; that doc is the *clone* side.

**Source-of-truth files (edit these, then rebuild — see the procedure):**

| File | Role |
|---|---|
| [`win2k25-golden-autounattend.xml`](win2k25-golden-autounattend.xml) | Build answer file — windowsPE install → audit mode → `sysprep /generalize` → shutdown/capture. |
| [`win2k25-golden-post-install.ps1`](win2k25-golden-post-install.ps1) | Runs once in **audit mode**: virtio + QGA + OpenSSH + firewall + host-key wipe. |
| [`win2k25-golden-dataimportcron.yaml`](win2k25-golden-dataimportcron.yaml) | Downstream — publishes the distributed containerDisk as a catalog boot source. |

---

## ⚠️ The eval clock is solved by **activation**, not by a licensed ISO

This is the single most important correction over earlier (2022) thinking.

A freshly generalized **evaluation** clone boots into an "Initial grace period"
that is the **activate-within-10-days** deadline — *not* a 10-day eval. Running
**`slmgr /ato`** (online activation) flips it to the full **~180-day** timed
eval. **No licensed/VL ISO and no product key are required**, and you must
**not** try to convert the edition inline (see build-breakers below).

- **Build side:** leave the image **generalized and unactivated**. Do nothing
  about licensing here.
- **Clone side:** [`unattend.xml`](unattend.xml) Order 4 runs `slmgr /ato` on
  first boot (after the MTU fix, which the activation HTTPS call depends on).
  Each clone self-activates to ~180 days. See `win2k25-vm-prep.md` § 4.

The old `golden-image-build.md` premise — "install a licensed edition to kill
the eval clock" — was **wrong** and led to the `dism /Set-Edition` build-hang.
Do not reintroduce it.

---

## What the two answer files do

The PowerShell is in the repo files above; this is the *why* so you can review
a change before rebaking. Don't duplicate the scripts into procedure runbooks —
edit the files and rebuild.

### `win2k25-golden-autounattend.xml` (build answer file)
- **windowsPE**: wipes disk 0, lays EFI/MSR/Primary, injects the virtio
  `viostor` + `NetKVM` drivers from the mounted virtio ISO (`E:\…\2k25\amd64`),
  and selects the edition via **`/IMAGE/INDEX = 2`** (Standard, Desktop
  Experience). Empty `<ProductKey>` — eval, activated later by the clone.
- **oobeSystem** reseals into **Audit** mode.
- **auditUser** runs `F:\post-install.ps1` once, then **generalizes with
  `ForceShutdownNow`** — that shutdown is what the pipeline captures as the
  golden disk.

### `win2k25-golden-post-install.ps1` (audit-mode customize)
Everything here lands in the image:
- **virtio-win guest drivers** (KubeVirt disk/NIC) + **QEMU Guest Agent**.
- **NIC MTU → 1400, set early** (insurance). Generalize resets it, so it does
  *not* carry to the clone — clone-side MTU is `unattend.xml` Order 4's job (the
  effective fix for activation + large transfers; see win2k25-vm-prep.md § 4a).
  Kept in the bake as harmless early insurance.
- **OpenSSH Server: use the INBOX install.** Windows Server **2025 ships OpenSSH
  Server installed inbox** (`OpenSSH.Server` = Installed; binaries at
  `system32\OpenSSH`; `sshd` registered; a predefined firewall rule app-locked
  to `system32\OpenSSH\sshd.exe`). So the 2025 recipe does **not** download
  anything — it just sets `sshd` `Automatic` and broadens the existing
  (already app-matched) firewall rule to `-Profile Any` (the masquerade net is
  classified `Public`; a Private-only rule silently drops inbound SSH).
  **Do NOT GitHub-zip install on 2025** — it drops a second sshd in
  `C:\Program Files\OpenSSH` and repoints the service there, breaking the inbox
  rule's app-lock and silently blocking inbound SSH (caught 2026-06-18 by
  validating a clone before distribution). *Server **2022** does NOT ship OpenSSH
  inbox → its golden recipe keeps the **GitHub-zip + a uniquely-named,
  port-based (`-LocalPort 22`, no `-Program`) `-Profile Any` rule** instead.*
- **Host-key wipe** before generalize so every clone gets unique SSH host keys
  (the inbox capability install may have pre-generated host keys → wipe them).
  Does **not** bake `authorized_keys` (key upload stays per-clone).

---

## Build procedure (configmap + pipeline)

Run on a cluster with the **OpenShift Pipelines** operator. Pick a build namespace:

```bash
NS=win-golden-build
oc create namespace "$NS"
```

> **⚠️ Where the pipeline comes from changed.** Older OpenShift Virtualization
> shipped the KubeVirt Tekton tasks/pipelines into the cluster (via the SSP
> operator / a `deployTektonTaskResources` HCO feature gate). **OCPv 4.22 has
> dropped that integration entirely** — there is no such feature gate, SSP
> deploys nothing Tekton-related, and `oc get pipeline -A` shows only the stock
> s2i/buildah pipelines. The `windows-efi-installer` pipeline is now pulled at
> run time from the **`redhat-pipelines` ArtifactHub catalog** through the Tekton
> **hub resolver**. Pin the version to the cluster's OCPv version — the
> pipeline's internal `taskRef`s are pinned to the matching `v<x.y.z>` tasks, so
> mixing versions is asking for trouble.

### 1. Install the OpenShift Pipelines operator

```bash
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

# wait for the operator AND for TektonConfig to go Ready (it lags the CSV by
# a few minutes while it lays down the per-namespace `pipeline` ServiceAccount)
oc get csv -n openshift-operators | grep pipelines
oc get tektonconfig config
```

### 2. Build the answer-file ConfigMap

The pipeline mounts this ConfigMap as the sysprep CD (drive `F:`). It needs
**both** keys — `autounattend.xml` and `post-install.ps1` — keyed exactly so
(`F:\post-install.ps1` is hard-referenced from the answer file). Recreate it
straight from the repo files so the image always matches what's committed:

```bash
oc create configmap windows2k25-autounattend-golden \
  --from-file=autounattend.xml=docs/win2k25-golden-autounattend.xml \
  --from-file=post-install.ps1=docs/win2k25-golden-post-install.ps1 \
  -n "$NS" --dry-run=client -o yaml | oc apply -f -
```

> Re-run this after **any** edit to either source file, then re-run the
> pipeline. (Editing the file on your Mac alone changes nothing — the pipeline
> reads the ConfigMap, not your working tree.)

### 3. Grant the `pipeline` ServiceAccount namespace `admin`

Because the tasks now come from ArtifactHub as bare `Task` objects, **no RBAC
comes with them** — you supply it. Namespace-scoped `admin` is enough; it picks
up the aggregated KubeVirt/CDI rules, so the SA can create DataVolumes,
DataSources, VirtualMachines and VMIs:

```bash
oc adm policy add-role-to-user admin -z pipeline -n "$NS"
```

**`cluster-admin` is not needed** — don't grant it. Every step in every task
runs `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, all capabilities
dropped, so the default **restricted** SCC is sufficient too (the libguestfs
`modify-windows-iso-file` steps included).

### 4. Set `vmStateStorageClass` — or the build VM never starts

The `windows.2k25` **and** `windows.2k25.virtio` cluster preferences both
request a **persistent vTPM** (`preferredTPM: {persistent: true}`). Persistent
vTPM state needs KubeVirt *backend storage*, which needs a storage class
configured on the HyperConverged CR. Without it the VM cannot start and the
build dies in `wait-for-vmi-status` with nothing obvious in the pipeline logs.

```bash
oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv --type=merge \
  -p '{"spec":{"storage":{"vmStateStorageClass":"<an-sc-supporting-RWO-Filesystem>"}}}'
```

> **⚠️ The field moved.** On the HCO **`v1`** API (OCPv 4.22) it is
> `spec.storage.vmStateStorageClass`. The old `v1beta1` top-level
> `spec.vmStateStorageClass` is **silently pruned** — you get a
> `Warning: unknown field "spec.vmStateStorageClass"` and `patched`, the patch
> appears to succeed, and the value is simply not there. Always read the field
> back, and confirm it propagated to the KubeVirt CR:
> ```bash
> oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
>   -o jsonpath='{.spec.storage.vmStateStorageClass}{"\n"}'
> oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
>   -o jsonpath='{.spec.configuration.vmStateStorageClass}{"\n"}'
> ```
>
> Note this also means **every clone gets a persistent vTPM PVC**
> (`persistent-state-for-<vm>`). That is fine — but it is exactly the PVC TVK
> excludes from backup by design, so a restored clone always gets a *fresh*
> vTPM. Harmless unless something is sealed to it (see
> [`exp5-tpm-bitlocker.md`](exp5-tpm-bitlocker.md)).

### 5. Check the build's egress dependencies

Three off-cluster fetches must work, or the run fails early and confusingly.
Test them from a pod on the build cluster, not from your Mac:

| Host | Needed by |
|---|---|
| `artifacthub.io` | the **hub resolver**, to fetch the pipeline + every task |
| `raw.githubusercontent.com` | task 1 `import-autounattend-configmaps` (it `curl`s the stock ConfigMap YAML and `oc apply`s it — this happens even though we override `autounattendConfigMapName`, because the EULA gate lives in that task) |
| Microsoft's download CDN | task 2 `import-win-iso` |

```bash
oc run egress-check -n "$NS" --restart=Never --rm -i \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --command -- /bin/bash -c 'for u in \
      https://artifacthub.io/api/v1/packages/tekton-pipeline/redhat-pipelines/windows-efi-installer/4.22.6 \
      https://raw.githubusercontent.com/kubevirt/kubevirt-tekton-tasks/main/release/pipelines/windows-efi-installer/configmaps/windows-efi-installer-configmaps.yaml \
      ; do echo "$(curl -s -o /dev/null -w %{http_code} -L --max-time 25 $u) <- $u"; done'
```

### 6. Launch the run from the committed PipelineRun

Use [`../manifests/win2k25-golden-pipelinerun.yaml`](../manifests/win2k25-golden-pipelinerun.yaml)
rather than retyping the console form — it carries the version pin, the
parameter choices and the reasoning:

```bash
export WIN2K25_ISO_URL='<current Server 2025 eval ISO URL>'   # short-lived, never committed
envsubst < manifests/win2k25-golden-pipelinerun.yaml | oc create -f -
tkn pipelinerun logs -f -n "$NS"
```

The parameters that matter, and why:

| Parameter | Value | Why |
|---|---|---|
| `winImageDownloadURL` | current Server 2025 eval ISO | Eval-center links are short-lived/tokenized — inject, don't commit. |
| `acceptEula` | `"true"` | Task 1 hard-exits if empty. |
| `autounattendConfigMapName` | `windows2k25-autounattend-golden` | **Our** answer files, not the stock 2025 ConfigMap. |
| `preferenceName` | `windows.2k25.virtio` | The pipeline default is `windows.11.virtio` — always override. |
| `instanceTypeName` | `u1.large` | See the build-vs-clone size trap below. |
| `baseDvName` | a **fresh** name (e.g. `win2k25-v2`) | Never overwrite a known-good golden on a rebake. |
| `useBiosMode` | `"false"` | UEFI, so `modify-windows-iso-file` runs and strips the "press any key to boot" prompt. |
| `virtioContainerDiskName` | *omit* | The pipeline default matched this cluster's `virtio-win` ConfigMap image byte-for-byte; pinning it here only rots. |

**Two things you cannot set as parameters:**

- **The root disk is hardcoded at `20Gi`** inside the pipeline's
  `create-vm-root-disk` task manifest. There is no parameter for it. (Conveniently
  that *is* the lean target.) To build any other size you must vendor the
  pipeline locally and edit it.
- **The StorageClass** — the root DV carries no `storageClassName`, so it lands
  on the cluster's default (or default-virt) class.

> **⚠️ The build-vs-clone size trap.** `instanceTypeName` and `preferenceName`
> are used for the *build VM* **and** are stamped onto the output
> DataVolume/DataSource as `instancetype.kubevirt.io/default-instancetype` /
> `default-preference` — i.e. they become the **default size of every clone**.
> These two wants conflict: the build wants CPU (DISM `/ResetBase` is slow), the
> clone wants to be lean. Resolve it by **building at `u1.large` and relabelling
> afterwards**, rather than building at 1 vCPU and risking the 2h
> `wait-for-vmi-status` timeout:
> ```bash
> for o in datavolume/win2k25-v2 datasource/win2k25-v2; do
>   oc label -n "$NS" $o instancetype.kubevirt.io/default-instancetype=u1.medium --overwrite
> done
> ```

### 7. Monitor — and the two hangs you will hit

- **`wait-for-vmi-status` task hangs** after the build VM should have powered
  off (VMI finalizers don't release). Clear it by force-deleting the launcher
  pod:
  ```bash
  oc delete pod -l vm.kubevirt.io/name=<build-vm-name> -n "$NS" --grace-period=0 --force
  ```
- **Image-picker hang in windowsPE** (Setup sits on the edition-select screen).
  Microsoft refreshes the eval ISO periodically and the image *Description*
  strings drift — which is exactly why the answer file selects by
  **`/IMAGE/INDEX`** (index 2 = Standard Desktop Experience), not by
  `/Image/Description`. Catch a stuck install fast with a screenshot instead of
  waiting out the timeout:
  ```bash
  virtctl vnc screenshot <build-vm-name> -n "$NS" --output=/tmp/build.png
  ```
  If a future ISO reorders indexes, confirm with
  `dism /Get-ImageInfo /ImageFile:<install.wim>` and adjust `/IMAGE/INDEX`.

### 8. Output

A generalized, **unactivated** DataVolume — the golden master — plus a
same-named DataSource carrying the default instancetype/preference labels.
Verify it on a test clone (below), then distribute it.

---

## Image slimming — why it is split across two passes

Every byte in the golden image is paid for **four times**: the golden DV, the
containerDisk push/pull, every clone's root disk, and **every Trilio backup of
every clone**. (For scale: the 2026-05 golden backed up at 17.85 GiB in 7m52s,
and backup wall-time on this lab is data-transfer-bound.) So the bake trims
itself — but the trim cannot all happen in one place:

| Where | What | Why it has to be there |
|---|---|---|
| `win2k25-golden-autounattend.xml`, **`specialize`** pass | registry writes: `AutomaticManagedPagefile=0` + empty `PagingFiles` | An **active pagefile cannot be deleted**, and disabling one only takes effect after a reboot. Windows Setup reboots between `specialize` → `oobeSystem`(Reseal=Audit) → audit mode, so this borrows a reboot that already exists. Doing it in `post-install.ps1` would be too late — the file would still be in use. |
| `win2k25-golden-post-install.ps1`, **audit** mode | delete `pagefile.sys`/`swapfile.sys`, `powercfg /hibernate off`, DISM `/StartComponentCleanup /ResetBase`, purge `SoftwareDistribution\Download` + temp + CBS logs + recycle bin, **re-arm** `AutomaticManagedPagefile=1`, `Optimize-Volume -ReTrim` | By now the pagefile is released and deletable. `ReTrim` is what makes the deletions *real* — it tells the virtio blk layer those blocks are free, so they read as unallocated in the captured disk instead of as stale data. |

Two details worth not breaking:

- **Re-arming the pagefile matters.** `AutomaticManagedPagefile` goes back to `1`
  at the end of audit mode so **clones** get a proper pagefile (SQL Server wants
  one). Windows creates the file at *boot*, not on that registry write, so the
  captured image stays clean while every clone self-provisions one.
- `post-install.ps1` writes **`C:\golden-build-report.txt`** with C: free space
  before/after. Check it on a test clone to confirm the slimming pass actually
  ran, instead of inferring it from disk size.


## Build-breakers learned the hard way (do NOT reintroduce)

| Anti-pattern | What happens | Do instead |
|---|---|---|
| `dism /Set-Edition` (inline edition conversion) before sysprep | Set-Edition stages a pending-reboot; `sysprep /generalize` refuses (`hr=0x8007139f`); the VM never powers off → `wait-for-vmi-status` hangs forever | **No edition conversion.** Boot the eval ISO, pick the edition via `/IMAGE/INDEX`, activate per-clone with `slmgr /ato`. |
| GitHub-zip OpenSSH install on **Server 2025** | 2025 already ships OpenSSH Server inbox (`system32\OpenSSH`) with an app-locked firewall rule; a zip install drops a second sshd in `C:\Program Files\OpenSSH` and repoints the service there, breaking the rule's app-lock → inbound SSH silently blocked (caught 2026-06-18) | **2025: use the inbox install** — `Set-Service sshd Automatic` + broaden the existing rule to `-Profile Any`. No download. |
| OpenSSH via `Add-WindowsCapability` (Windows-Update FOD) on **Server 2022** | FOD endpoint (`fe2.update.microsoft.com`) is commonly blocked; on the old golden image DISM also lied (`Installed`, no binaries) | **2022 only** (it has no inbox OpenSSH): **GitHub release zip** + a uniquely-named, port-based `-Profile Any` rule — `github.com` + CDN reachable, no FOD/DISM dependency. |
| Treating the 10-day clock as the eval length | Wasted effort chasing licensed ISOs / `slmgr /rearm` | It's the **activate-by** deadline; `slmgr /ato` unlocks ~180 days. |
| Starting sshd during the build without wiping host keys | Every clone ships identical SSH host keys | Set sshd `Automatic` but don't start it; **wipe `C:\ProgramData\ssh\ssh_host_*`** before generalize. |
| Large download before setting MTU | Stalls/timeouts that look like an egress block | Set NIC **MTU 1400 first** (already first in `post-install.ps1`). |
| Expecting OpenShift Virtualization to ship the Tekton pipeline (hunting a `deployTektonTaskResources` HCO feature gate) | **OCPv 4.22 removed the SSP/Tekton integration** — the gate does not exist, SSP deploys nothing, and `oc get pipeline -A` shows only stock s2i/buildah pipelines. Easy to misread as a broken install | Pull `windows-efi-installer` from the **`redhat-pipelines` ArtifactHub catalog via the hub resolver**, pinned to the cluster's OCPv version (its internal `taskRef`s are pinned to matching `v<x.y.z>` tasks). |
| Patching `spec.vmStateStorageClass` on the HyperConverged CR | On the HCO **`v1`** API the field moved under `spec.storage`. The old top-level path is **silently pruned**: you get `Warning: unknown field` *and* `patched`, so it looks like it worked while the value is absent — then the build dies in `wait-for-vmi-status` because the persistent-vTPM VM can't start | Patch **`spec.storage.vmStateStorageClass`**, then **read it back** and confirm it reached the KubeVirt CR's `spec.configuration.vmStateStorageClass`. |
| Building at the lean clone instancetype (e.g. `u1.medium`) to get a lean clone default | `instanceTypeName` sizes the **build VM** *and* is stamped on the output DV/DataSource as every clone's default. At 1 vCPU, DISM `/ResetBase` + the Windows install can approach the 2h `wait-for-vmi-status` timeout — a 2h build lost to save two `oc label` calls | Build at **`u1.large`**, then **relabel** the DataVolume + DataSource `instancetype.kubevirt.io/default-instancetype=u1.medium`. |
| Granting the `pipeline` ServiceAccount `cluster-admin` | Unnecessary cluster-wide privilege; also masks which permissions the run actually needs | Namespace **`admin`** is sufficient (it picks up the aggregated KubeVirt/CDI rules). Every task step is `runAsNonRoot` with all caps dropped, so the **restricted** SCC works too. |

---

## Post-build verification (on a test clone, before blessing the image)

Provision one VM from `win2k25` via `win2k25-vm-prep.md` and confirm:

```powershell
Get-ComputerInfo | Select WindowsProductName, OsHardwareAbstractionLayer  # 2025, Desktop
Get-Service QEMU-GA      # Running / Automatic
Get-Service sshd         # Running / Automatic
slmgr /xpr               # after Order-4 /ato: ~180 days, NOT Notification mode
Get-NetFirewallRule -DisplayName 'OpenSSH*' | Select DisplayName, Profile, Enabled  # Profile = Any
```

Also confirm two clones present **different** SSH host keys (no `known_hosts`
collision) — proves the host-key wipe worked.

---

## After the image is built — package + push it (the "export")

The golden DV lives on the build cluster. To make it consumable everywhere,
wrap it as an OCI **containerDisk** (disk at `/disk/`) and push to a registry
all clusters reach (lab uses `ghcr.io/trilio-demo/win2k25-golden:<date-tag>`).

**There is no native CDI/KubeVirt export-to-registry primitive.** `DataImportCron`
is import-only; the only export CR, `VirtualMachineExport`, just serves the disk
over HTTP for download (the `virtctl vmexport download` path — unreliable on
multi-GB pulls from a Mac: ephemeral-port exhaustion). So the packaging step is a
**build**, run **in-cluster** with buildah.

### 1. One-time: push secret + builder ServiceAccount (build cluster)

Create a GitHub **classic PAT with `write:packages`** (separate from the read PAT
the consumers use). Never commit it — pass via env:

```bash
NS=<build-namespace>
export GHCR_USER=<github-username>          # your GH username, not email
export GHCR_WRITE_PAT=<token-with-write:packages>

# docker-registry push secret (the Job mounts this as REGISTRY_AUTH_FILE)
oc create secret docker-registry ghcr-push \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USER" \
  --docker-password="$GHCR_WRITE_PAT" \
  -n "$NS"

# builder SA (buildah needs privileged: it mounts the source PVC as a block
# device and runs the vfs storage driver)
oc create sa cdisk-builder -n "$NS"
oc adm policy add-scc-to-user privileged -z cdisk-builder -n "$NS"
```

(GHCR uses two least-privilege PATs: **write** here on the build host, **read**
on every consuming cluster — see `win2k25-vm-prep.md` § 1.)

### 2. Scratch PVC (60Gi — do not shrink)

The vfs storage driver **duplicates** the ~8 GB image layer during `buildah bud`,
so the scratch must hold the qcow2 **plus** the duplicated layer **plus** overhead:

```bash
# 60Gi, Filesystem, on any working SC
oc create -n "$NS" -f - <<'EOF'  # (or apply your own PVC manifest)
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: win2k25-build-scratch }
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  resources: { requests: { storage: 60Gi } }
EOF
```

### 3. Run the package+push Job

Use the committed, reusable Job
[`../manifests/golden-containerdisk-push.yaml`](../manifests/golden-containerdisk-push.yaml).
It runs **one** buildah/stable container that: `microdnf install qemu-img` →
`qemu-img convert` the source **Block** PVC → `/work/disk.qcow2` → `buildah bud`
(`FROM scratch` + `ADD disk.qcow2 /disk/`) → `buildah push --retry` (survives the
occasional http2 drop). Edit two fields per rebake — the **source PVC** (`volumes:
winsrc`, must be `volumeMode: Block`) and the **`IMAGE_TAG`** env — then:

```bash
oc create -f manifests/golden-containerdisk-push.yaml      # generateName -> unique
oc logs -f job/<generated-name> -n "$NS"                   # ~15 min: convert + build + push
```

### 4. Consume it

Point a `registry:` DataVolume or the catalog
[`win2k25-golden-dataimportcron.yaml`](win2k25-golden-dataimportcron.yaml) at the
new tag. Consume-side setup — the `ghcr-cdi` **read** pull secret and the
**two-namespace gotcha** (it must exist in *both* `openshift-virtualization-os-images`
**and** `openshift-cnv`) — is in `win2k25-vm-prep.md` § 1–2.

---

## What this retires in `win2k25-vm-prep.md`

Once a rebaked image is built **and** distributed, and a test clone passes:

- **§ 5c (firewall `-Profile Any`)** → becomes baked; drop it as a per-clone
  step. *(The currently-distributed `:2026-06-16` containerDisk predates the
  firewall fix, so § 5c is still required until the next rebake+push.)*
- **§ 5 SSH install** is already "baked — just upload your key"; nothing to
  change there.
- **§ 4 (MTU + activation)** stays — clone-side, still required.

Hold prep-doc edits until the rebaked image is live and verified.
