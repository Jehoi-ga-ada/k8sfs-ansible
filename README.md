# k8sfs-ansible

Builds a Kubernetes cluster the hard way — no kubeadm — inside Tart VMs running on
Apple Silicon Macs. It prepares the Mac hosts, runs
[Orchard](https://github.com/cirruslabs/orchard) to manage the VMs, bakes the VM
images, and installs etcd, the control plane, kubelets, Cilium and CoreDNS.

Creating the VMs themselves is [k8sfs-terraform](../k8sfs-terraform)'s job.

## What you end up with

Five VMs per environment: two control-plane nodes, two workers, and one load
balancer running haproxy in front of the apiservers. Control-plane hosts run
kubelet too, so they register as `control-plane` nodes; `lb-1` is not a
Kubernetes node.

| component | version |
|---|---|
| Kubernetes | v1.36.3 |
| etcd | v3.6.14 |
| containerd / runc | 2.3.3 / v1.5.1 |
| Cilium | 1.20.0 (kube-proxy replacement, L2 announcements, Gateway API) |
| CoreDNS | v1.14.6 |
| metrics-server | v0.9.0 |
| Gateway API CRDs | v1.6.1 |

Networking defaults: pods `10.244.0.0/16`, services `10.96.0.0/16`, cluster DNS
`10.96.0.10`, domain `cluster.local`, apiserver on `6443`. All set in
`inventory/group_vars/k8s.yml` and the relevant role vars.

## Layout

```
inventory/
  <env>.yml            one file per environment, selected with -i
  orchard_inv.py       dynamic inventory, queries the Orchard API
  group_vars/
    all/main.yml       Orchard defaults shared by every environment
    all/vault.yml      encrypted secrets
    k8s.yml            kube_version, CIDRs, SSH user for the VMs
playbooks/
  bootstrap.yml        prepare a bare Mac: CLT, sudo user, optional Tailscale
  prerequisite.yml     Homebrew, Orchard CLI, controller, worker
  node-images.yml      bake per-node VM images with static addresses
  site.yml             build the cluster
roles/                 21 roles; site.yml defines the order for the cluster build
```

## Prerequisites

**Control machine:** `ansible-core` >= 2.16, `make`, `kubectl`, `terraform`, and a
dedicated keypair:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ansible -C ansible
ansible-galaxy install -r requirements.yml
```

**Each Mac host:** Apple Silicon, macOS 14+, Remote Login enabled
(System Settings → General → Sharing), and an existing admin account whose
`authorized_keys` already contains your public key:

```bash
ssh-copy-id -i ~/.ssh/ansible.pub <admin>@<mac>
```

That step is not optional — the play that installs your key has to log in first.

Two things that look like hangs but are not. Command Line Tools installs silently
for 5–20 minutes. And on a Mac without CLT, `/usr/bin/python3` is a stub that
opens a GUI installer dialog and blocks forever over SSH — if
`ssh <mac> /usr/bin/python3 -V` hangs, run `sudo xcode-select --install` from the
Mac's own console first.

Capacity: each Orchard worker advertises `orchard_worker_vm_slots` (default 6) and
the VM memory comes out of the host's RAM. Sum your VM sizes and leave the host at
least 3 GB.

## Secrets

**Vault.** `inventory/group_vars/all/vault.yml` is committed encrypted and applies
to `all`, so every command needs the vault password — including
`ansible-inventory`.

```bash
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
ansible-vault encrypt inventory/group_vars/all/vault.yml
```

| variable | generate with |
|---|---|
| `orchard_bootstrap_admin_token` | `openssl rand -hex 32` |
| `orchard_terraform_token` | `openssl rand -hex 32` |
| `kubelet_bootstrap_token_id` | `openssl rand -hex 3` — exactly 6 chars |
| `kubelet_bootstrap_token_secret` | `openssl rand -hex 8` — exactly 16 chars |
| `tailscale_authkey` | Tailscale admin console → Settings → Keys |

The two kubelet values form the bootstrap token kubelets use to request their
certificates; it expires after 7 days, which only matters if you add a node later.
Leave `tailscale_authkey` as a placeholder unless an environment sets
`use_tailscale: true`.

**.env**, gitignored, for values that must be process environment. Start from the
template, which carries one block per environment:

```bash
cp env.example .env
set -a; source .env; set +a
```

Only one environment's block should be uncommented at a time — these are the
credentials `inventory/orchard_inv.py` uses, and it can only talk to one controller
per run. A plain `source` without `set -a` sets shell variables that the inventory
script never sees. With `ANSIBLE_VAULT_PASSWORD_FILE` set, the Makefile stops
prompting for the vault password.

## Environments

One inventory file per cluster. `ansible.cfg` sets no default inventory on
purpose, so a bare command fails rather than silently reconfiguring the wrong
cluster.

```bash
cp inventory/environment.yml.example inventory/<env>.yml
ansible-playbook -i inventory/<env>.yml playbooks/site.yml
```

Add `-i inventory/orchard_inv.py` as a second source where VM addresses come from
DHCP and have to be discovered. Both files share `inventory/group_vars/`, which
resolves relative to the inventory source.

Required groups — roles index `groups['master']`, `groups['lb']` and
`hostvars['lb-1']` directly, so the names are fixed:

| group | purpose |
|---|---|
| `bootstrap` | the pre-existing admin account, for first contact |
| `orchard_controller` | the Mac running `orchard controller` |
| `orchard_workers` | the Macs running `orchard worker` |
| `k8s` → `master`, `worker`, `lb` | the VMs; `site.yml` targets `k8s` |
| `control_plane` → `master` | consumed by the control-plane roles |

Set per environment under `all: vars:`:

| variable | why |
|---|---|
| `orchard_controller_host` | which host runs the controller |
| `cluster_name` | kubeconfig context; must differ per cluster |
| `kubectl_local_config` | where the kubeconfig lands locally |
| `lb_ip_pool_start` / `_stop` | Cilium LoadBalancer address range |
| `gateway_address` | the address you expect the Gateway to claim |
| `node_gateway` | default gateway baked into static images |
| `node_image_env` | image name prefix, must match Terraform |
| `use_tailscale` | only where the host uses Tailscale |
| `ansible_ssh_common_args` | `-o ProxyJump=...` on the `k8s` group, for NAT'd VMs |

**Set `lb_ip_pool_*` explicitly.** Left unset it derives `<master-prefix>.250`,
very likely an address you do not own, which Cilium will then ARP-announce onto
your LAN. For more than one pool, or pools selected by service labels, override
`lb_ip_pools` instead.

## Workflow

```
0. host prep (manual)      ssh-copy-id, enable Remote Login
1. make <env>-bootstrap    sudo user, your key, passwordless sudo
2. make <env>-prereq       Homebrew, Orchard CLI, controller, worker
3. node-images.yml         bake per-node images   (static-address envs only)
4. terraform apply         create the VMs         (k8sfs-terraform)
5. make <env>-site         build the cluster
```

**Step 1** targets the `bootstrap` group, installs Command Line Tools, creates the
`sudo_user` account (default `macos`) with your key and passwordless sudo, and
optionally joins Tailscale. From then on you connect as that account.

**Step 2** installs Homebrew and the Orchard CLI, then runs the controller and
worker as LaunchDaemons. It finishes by printing the worker list and the exact
`url`, `name` and `token` Terraform needs — copy those into
`k8sfs-terraform/terraform.tfvars`.

**Step 3** clones the base Debian image once per node, boots each in turn, writes a
static netplan config and your SSH key, and disables cloud-init. It exists because
Orchard has no field for a VM address and a rebuild reverts the disk, so the image
is the only place an address survives. Skip it if your LAN's DHCP serves the VMs.

```bash
ansible-playbook -i inventory/<env>.yml playbooks/node-images.yml
```

**Step 5** runs, in order: `cluster_hosts`, `cluster_ssh`, `cluster_tls`,
`cluster_config`, `cluster_encryption`, `etcd`, `control_plane`,
`container_runtime`, `worker`, `cluster_rbac`, `kubectl_access`, `cluster_cni`,
`cluster_dns`, `metrics_server`. It creates a `lan-gateway` Gateway in
`kube-system` with `allowedRoutes.namespaces.from: All`, so applications in any
namespace can attach an HTTPRoute, and fetches the kubeconfig to
`kubectl_local_config`.

Every role is tagged, so you can re-run one: `make <env>-site` with
`--tags cluster_cni`, and so on.

## Make targets

`<env>-bootstrap`, `<env>-prereq`, `<env>-site`, `<env>-inventory`, `<env>-ping`.
Not every environment defines all five — add the ones you need when you add an
environment. `VAULT` resolves to `--ask-vault-pass`
unless `ANSIBLE_VAULT_PASSWORD_FILE` is set.

## Verifying

```bash
export KUBECONFIG=~/.kube/<your-cluster>.config
kubectl get nodes -o wide     # 2 control-plane + 2 workers, all Ready
kubectl top nodes             # metrics API working
kubectl get pods -A           # cilium, coredns, metrics-server
kubectl get gateway -A        # lan-gateway with an address, PROGRAMMED True
```

## Troubleshooting

**`Attempting to decrypt but no vault secrets found`** — every command needs the
vault password. Use a Make target, or pass `--ask-vault-pass`.

**Dynamic inventory returns nothing** — `ORCHARD_*` is not exported. Check with
`env | grep ORCHARD`, and run `./inventory/orchard_inv.py` directly to see errors.

**HTTP 500 from `/v1/vms/{name}/ip`** — the VM has no address. On the host,
`tart ip --resolver arp <vm>` shows the real reason.

**Pods `ImagePullBackOff`** — nodes are arm64; an amd64-only image will not run.

**`kubectl` cannot reach the apiserver** — with NAT'd VMs it cannot, by design.
Forward through the host: `ssh -L 6443:<lb-vm-ip>:6443 <user>@<mac>`, then point
the kubeconfig at `https://127.0.0.1:6443`.
