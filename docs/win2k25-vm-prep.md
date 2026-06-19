# Windows Server 2025 VM Prep — from the golden containerDisk image

How to stand up a **Windows Server 2025** VM on OpenShift Virtualization
(OCPv / KubeVirt) starting from the prebuilt **golden containerDisk image** in
a registry. The golden image already has **virtio drivers + QEMU Guest Agent +
OpenSSH Server** baked in (Standard, Desktop Experience, sysprep-generalized),
so per-VM prep is small: seed the image as a DataVolume, create the VM with the
clone-time `unattend.xml`, then finish SSH + activation.

> Companion to [`unattend.xml`](unattend.xml) (the clone-time answer file —
> shared with the 2022 flow and kept version-agnostic). This guide is
> cluster-agnostic; replace the `<...>` placeholders for your environment.

Set these once for the commands below:

```bash
NS=<your-namespace>                 # e.g. mssql-vss-lab
IMG=ghcr.io/trilio-demo/win2k25-golden:2026-06-16   # the golden image tag
SC_WFFC=<wffc-storageclass>         # a WaitForFirstConsumer SC (see § 2 note)
```

---

## 1. GitHub PATs + GHCR secrets (required — private package)

The golden image is a **private** ghcr package. Use **two classic PATs**
(least privilege — a read token sprayed to many clusters shouldn't be able to
overwrite the image):

| PAT | Scope | Used by | Wrapped as |
|---|---|---|---|
| **read token** | `read:packages` | every cluster that **consumes** the image | `ghcr-cdi` (§ 1a) |
| **write token** | `write:packages` (+`read:packages`) | the **build host** only | `ghcr-push` (§ 1c, `golden-image-build.md`) |

Create both at GitHub → **Settings → Developer settings → Personal access
tokens → Tokens (classic) → Generate new token (classic)**, copy each `ghp_…`,
and keep them in **environment variables** (or your own secret store) — never
hardcode a PAT in a committed file.

### 1a. Pull secret (`ghcr-cdi`) — every consuming cluster

CDI's `registry` source wants `accessKeyId` / `secretKey` keys (NOT a
dockerconfigjson). `accessKeyId` is your **GitHub username** (e.g. `vebutton`),
**not an email** — ghcr rejects an email. Supply the PAT via env var:

```bash
export GHCR_USER=<github-username>
export GHCR_READ_PAT=<read-PAT>
# from the committed template (safe — PAT comes from the env, not the file):
envsubst < docs/ghcr-secret.example.yaml | oc apply -n $NS -f -
# …or without a file:
oc create secret generic ghcr-cdi -n $NS \
  --from-literal=accessKeyId="$GHCR_USER" --from-literal=secretKey="$GHCR_READ_PAT"
```

> Apply it in **every namespace that pulls** the image. The DataImportCron
> (§ 2b) needs it in **two** places: `openshift-virtualization-os-images` (for
> the import DataVolume) **and** the CDI namespace **`openshift-cnv`** — the
> cron's registry digest-poll job runs there, and without the secret it fails
> with `CreateContainerConfigError: secret "ghcr-cdi" not found`.

### 1c. Push secret (`ghcr-push`) — build host only

Building/pushing the containerDisk (buildah) uses a **docker-registry** secret
made from the **write** PAT:

```bash
export GHCR_WRITE_PAT=<write-PAT>
oc create secret docker-registry ghcr-push -n <build-ns> \
  --docker-server=ghcr.io --docker-username="$GHCR_USER" --docker-password="$GHCR_WRITE_PAT"
```
(See `golden-image-build.md` for the build/push job that consumes it.)

---

## 2. Seed the golden image as a DataVolume

### 2a. One-shot import (simplest — per VM or per namespace)

```bash
oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: win2k25
  namespace: $NS
spec:
  source:
    registry:
      url: "docker://$IMG"
      secretRef: ghcr-cdi
  storage:
    storageClassName: $SC_WFFC
    resources:
      requests:
        storage: 21Gi
EOF
# watch: oc get dv win2k25 -n $NS -w   (Succeeded => ready to clone)
```

> **Storage class — use WaitForFirstConsumer (WFFC), not Immediate.**
> On node-local backends (e.g. TopoLVM/LVMS) an **Immediate**-binding SC
> provisions volumes before the pod is scheduled, and a multi-disk VM can end
> up with a volume whose device never materialises on the pod's node — the
> launcher hangs in `Init:0/3` with
> `FailedMapVolume ... special device /dev/topolvm/<uuid> does not exist`.
> WFFC provisions at pod-schedule time and avoids this. Check your SCs:
> `oc get sc -o custom-columns=NAME:.metadata.name,BINDING:.volumeBindingMode`.
>
> *This race only bites **multi-node** node-local clusters (volume on node A,
> pod on node B). On a **single-node** cluster it can't happen — but use the
> WFFC SC anyway; it's the safe default and harmless when there's one node.*

### 2b. (Optional) Catalog boot source via DataImportCron

To make the image selectable in the console's "create VM from template" flow,
register it as a managed boot source. **Use a DISTINCT `managedDataSource`
name** so you do not clobber a shared/engineering `win2k25` DataSource on the
cluster. See the ready manifest in
[`win2k25-golden-dataimportcron.yaml`](win2k25-golden-dataimportcron.yaml)
(`managedDataSource: win2k25-trilio-golden`, `secretRef: ghcr-cdi`, WFFC SC).

> The golden-image **build** recipe lives alongside this guide too:
> [`win2k25-golden-autounattend.xml`](win2k25-golden-autounattend.xml) and
> [`win2k25-golden-post-install.ps1`](win2k25-golden-post-install.ps1) are the
> two keys of the build ConfigMap consumed by the `windows-efi-installer`
> pipeline (virtio + QGA + OpenSSH + host-key wipe).

> **Why the catalog sometimes clones the "wrong" (old) image:** a template's
> default disk is a **DataSource**, fed by either a **DataImportCron** or a
> **static PVC**. If the cluster's `win2k25` DataSource is a stale static PVC
> (no cron), the template keeps cloning it regardless of what you uploaded.
> Either point a DataImportCron at your image (distinct DataSource), or create
> the VM against your DataVolume directly (§ 3) instead of the template default.

---

## 3. Create the VM

Clone the `win2k25` DV per VM and attach the clone-time `unattend.xml` as a
**sysprep** volume (a ConfigMap with key `unattend.xml`). Use **short, explicit
VM and disk names** (avoid the console's random `adjective-animal-NN` names).

```bash
# sysprep ConfigMap from the clone-time answer file:
oc create configmap win2k25-mssql-sysprep -n $NS \
  --from-file=unattend.xml=docs/unattend.xml
```

Then a VM (illustrative — adjust instancetype/preference, data-disk size):

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: win2k25-mssql            # short, explicit
  namespace: <your-namespace>
spec:
  runStrategy: Always
  instancetype: { name: u1.large, kind: VirtualMachineClusterInstancetype }
  preference:  { name: windows.2k25.virtio, kind: VirtualMachineClusterPreference }
  dataVolumeTemplates:
  - metadata: { name: win2k25-mssql-root }
    spec:
      source: { pvc: { namespace: <your-namespace>, name: win2k25 } }   # clone the seeded golden DV
      storage:
        storageClassName: <wffc-storageclass>
        resources: { requests: { storage: 21Gi } }
  template:
    spec:
      domain:
        devices:
          disks:
          - { name: rootdisk, disk: { bus: virtio } }
          - { name: sysprep,  cdrom: { bus: sata } }
      volumes:
      - name: rootdisk
        dataVolume: { name: win2k25-mssql-root }
      - name: sysprep
        sysprep: { configMap: { name: win2k25-mssql-sysprep } }
```

> **CRITICAL — the unattend must be edition/version-agnostic.** Do NOT leave a
> hardcoded `<ProductKey>` in the `specialize` pass. A WS2022 Datacenter GVLK
> applied to a 2025 Standard image makes Windows reject the whole pass with
> *"could not parse or process the unattend answer file for pass [specialize]
> ... Microsoft-Windows-Shell-Setup"* and setup loops on "computer restarted
> unexpectedly." `docs/unattend.xml` has no ProductKey — activation is handled
> at first boot (§ 4). Keep it that way.

First boot runs the unattend's `FirstLogonCommands`: data-disk init, RDP enable,
and `slmgr /ato` (activation, § 4).

---

## 4. Activation (ATO) — getting the full ~180-day eval

A freshly generalized eval clone boots into **"Initial grace period" with only
~10 days** — that 10 days is the *activate-within-10-days* deadline, **not** the
eval length. Online activation unlocks the full ~180-day timed eval. The
clone-time `unattend.xml` does this automatically (FirstLogonCommands: fix MTU,
then `slmgr /ato`), but to do it by hand:

```powershell
netsh interface ipv4 set subinterface "Ethernet" mtu=1400 store=persistent   # see § 4a — REQUIRED FIRST
slmgr /ato            # activate over the internet
slmgr /xpr            # verify: "Timebased activation will expire <date>" ~180 days out
```

### 4a. The MTU prerequisite (this is what actually blocks activation)

On OVN-Kubernetes the **overlay MTU is ~1400**, but **Windows ignores the
DHCP-advertised MTU and stays at 1500.** The guest then emits oversized packets:
small ones (TCP handshake, interactive SSH) pass, but the large TLS handshake /
activation exchange is dropped and PMTU discovery is black-holed — so
`slmgr /ato` just times out:

```
slmgr /ato
Error: 0x80072EE2   (ERROR_INTERNET_TIMEOUT)   <- looks like an egress block, ISN'T
```

**It is not an egress/firewall/proxy problem** (verified 2026-06-17 — the
activation endpoint serves a genuine Microsoft cert and TCP/443 connects fine;
only large payloads fail). Fix it entirely guest-side by matching the NIC MTU to
the overlay:

```powershell
# find the overlay MTU (from the host side): the launcher pod's eth0
#   oc exec <virt-launcher-pod> -c compute -- cat /sys/class/net/eth0/mtu   # e.g. 1400
netsh interface ipv4 set subinterface "Ethernet" mtu=1400 store=persistent
Get-NetIPInterface -InterfaceAlias Ethernet -AddressFamily IPv4 | Select NlMtu  # confirm 1400
```

Then `slmgr /ato` succeeds and `slmgr /xpr` shows ~180 days. (This also fixes
any other large-payload egress from the guest — big downloads, etc.)

> The same black-hole hits any large HTTPS transfer, not just activation —
> e.g. a GitHub OpenSSH-zip download. A/B verified on this cluster
> (2026-06-18): same URL/path, guest MTU **1500 → stalls, times out at 45 s**;
> **1400 → 4.6 MB in 1.4 s**. So a download that "hangs" while small requests
> to the same host succeed is the MTU signature, not an egress block.

> Diagnostic that distinguishes MTU from a real egress block: from a pod,
> `curl https://activation.sls.microsoft.com/` returning a genuine Microsoft
> cert + an HTTP status (e.g. 403) means egress is fine and the guest-side
> symptom is MTU. (A minimal container may report "unable to get local issuer
> certificate" simply because it lacks the Microsoft intermediate — that's a
> container trust-store quirk, **not** interception.)

If, separately, a cluster genuinely blocks/inspects `*.sls.microsoft.com`, then
activation needs a network exemption — but confirm MTU first; that's the common
cause.

---

## 5. SSH access

OpenSSH Server is **baked into the golden image** (service `sshd`
Running/Automatic, listening on 22). Per VM you only need to (a) install your
public key, (b) fix the key file's ACL, and (c) expose port 22.

### 5a. Install your public key

For the built-in **Administrator** (an admin account), Windows OpenSSH reads
**`C:\ProgramData\ssh\administrators_authorized_keys`**, *not* the user's
`~\.ssh\authorized_keys`. Write it as **plain ASCII (no BOM)** — a UTF-16/BOM
file (PowerShell's default redirection) silently breaks key auth:

```powershell
$pub = 'ssh-ed25519 AAAA...your-public-key... user@host'
[System.IO.File]::WriteAllText(
  'C:\ProgramData\ssh\administrators_authorized_keys', $pub + "`n",
  [System.Text.Encoding]::ASCII)
```

(For a non-admin user, use `C:\Users\<user>\.ssh\authorized_keys` instead.)

### 5b. Fix the ACL (the step that's easy to miss)

Windows OpenSSH **refuses** `administrators_authorized_keys` if any principal
other than `SYSTEM` and `Administrators` has access — otherwise auth silently
fails with *"Authentication refused: bad ownership or modes for file."* A file
created with default inheritance picks up `Authenticated Users: Read`, which
trips this. Strip inheritance and grant only SYSTEM + Administrators:

```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys `
  /inheritance:r /grant "SYSTEM:F" /grant "*S-1-5-32-544:F"
# *S-1-5-32-544 = BUILTIN\Administrators (language-independent)
```

Verify only those two principals remain:

```powershell
(Get-Acl C:\ProgramData\ssh\administrators_authorized_keys).Access |
  ForEach-Object { $_.IdentityReference.Value + ' : ' + $_.FileSystemRights }
```

No `sshd` restart is needed — it reads the file per authentication.

### 5c. Inbound 22 on the **Public** profile — baked in (normally no action)

KubeVirt's masquerade network is **always classified `Public`** in the guest, so
an OpenSSH rule scoped `Private`-only silently drops every inbound connection
(pod-IP, service, NodePort) while `sshd` still answers on loopback in-guest.
**The inbox-SSH golden image (`:2026-06-18` and later) already broadens its
firewall rule to `-Profile Any`** — validated end-to-end 2026-06-18 (a fresh
clone accepted inbound SSH over the NodePort with no per-clone step). So on a
current image **there's nothing to do here.**

<details>
<summary>Only if SSH hangs (older image with the Private-scoped rule)</summary>

If `sshd` answers on `127.0.0.1`/own-IP in-guest but every inbound connection
hangs with zero sshd-log entries, the rule is `Private`-only. Broaden it:

```powershell
Get-NetFirewallRule -DisplayName 'OpenSSH*' -EA SilentlyContinue | Set-NetFirewallRule -Profile Any
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP-Any' -DisplayName 'OpenSSH Server (sshd) Any' `
  -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any
```

Diagnostic: from a pod, `bash -c 'exec 3<>/dev/tcp/<vm-pod-ip>/22; head -c 50 <&3'`.
A `SSH-2.0-...` banner means the guest is reachable and the problem is external
(NodePort/edge firewall, § 5d); **no** banner with `sshd` listening in-guest ⇒
this Public-profile block.
</details>

### 5d. Expose port 22 (NodePort Service)

The Service selector must match the launcher pod label
**`vm.kubevirt.io/name: <vm>`** (not `kubevirt.io/domain`):

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: win2k25-mssql-ssh
  namespace: $NS
spec:
  type: NodePort
  selector:
    vm.kubevirt.io/name: win2k25-mssql
  ports:
  - { name: ssh, protocol: TCP, port: 22, targetPort: 22 }
EOF

# get the assigned NodePort + a worker IP:
oc get svc win2k25-mssql-ssh -n $NS -o jsonpath='{.spec.ports[0].nodePort}{"\n"}'
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name} {range .status.addresses[?(@.type=="InternalIP")]}{.address}{end}{"\n"}{end}'
# endpoints should list the VM pod IP (proves selector + sshd reachable):
oc get endpoints win2k25-mssql-ssh -n $NS
```

Connect from your workstation:

```bash
ssh -i <your-private-key> Administrator@<worker-ip> -p <nodeport>
```

(RDP works the same way on port 3389 if you prefer the desktop.)

---

## Gotchas seen in the field (all handled above)

| Symptom | Cause | Fix |
|---|---|---|
| `specialize` parse failure → "restarted unexpectedly" loop | version-mismatched `<ProductKey>` in unattend (2022 GVLK on 2025) | no ProductKey; activate via `slmgr /ato` (§ 3, § 4) |
| Launcher stuck `Init:0/3`, `FailedMapVolume ... device does not exist` | Immediate-binding SC on node-local storage | use a WFFC StorageClass (§ 2) |
| `slmgr /ato` → `0x80072EE2`; TCP/443 connects but HTTPS times out | guest NIC MTU 1500 > OVN overlay 1400 (Windows ignores DHCP MTU); large packets dropped | set guest MTU to overlay (`netsh … mtu=1400`) — §4a. NOT an egress/proxy issue |
| SSH/NodePort hangs, **zero** sshd connection logs, but sshd answers on 127.0.0.1/own-IP in-guest | OpenSSH rule scoped **Private**; masquerade net is **Public** → inbound dropped. *Baked `-Profile Any` as of `:2026-06-18`; only older images hit this* | broaden rule(s) to `-Profile Any` (§ 5c) |
| SSH key auth silently refused | `administrators_authorized_keys` bad ACL (or UTF-16/BOM) | ASCII write + `icacls /inheritance:r` SYSTEM+Administrators (§ 5b) |
| Catalog clones an old image | template DataSource is a stale static PVC | DataImportCron with a distinct DataSource, or build VM against your DV (§ 2) |
| ghcr pull `unauthorized` | private package + missing/!email creds | `ghcr-cdi` secret, GitHub username (not email) (§ 1) |
