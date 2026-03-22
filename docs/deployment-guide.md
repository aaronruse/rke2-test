# RKE2 Cluster Deployment Guide

End-to-end runbook for deploying the RKE2 cluster on AWS from a **RHEL 8 AWS
Workspace** terminal session. Everything — tool installation, bastion, and the
full cluster — is deployed in a single phase directly from the workspace.

---

## Deployment Strategy

```
RHEL 8 AWS Workspace (terminal)
  └── Run bootstrap script  — installs git, terraform, kubectl, helm, aws cli
  └── Generate SSH key       — used for GitLab and all EC2 node access
  └── Clone repo from GitLab
  └── Configure variables
  └── terraform apply        — deploys VPC + bastion + RKE2 cluster in one shot
  └── Fetch kubeconfig       — verify cluster from the workspace
  └── helm/deploy.sh         — deploy ingress-nginx, cert-manager, CoreDNS patch
```

The control plane and worker nodes live in private subnets. The workspace
reaches them via the bastion, which is deployed as part of the same `terraform
apply`. There is no separate "Phase 1" — everything goes up together.

---

## Prerequisites

Your RHEL 8 workspace needs outbound internet access to reach:
- `dnf` package repos (or a local mirror)
- `releases.hashicorp.com` (Terraform)
- `dl.k8s.io` (kubectl)
- `get.helm.sh` (Helm)
- `awscli.amazonaws.com` (AWS CLI)
- `github.com` (rancherfederal/rke2-aws-tf Terraform module)
- `gitlab.com` (your repo — or your self-hosted GitLab hostname)

If your workspace is behind a proxy, set `http_proxy` / `https_proxy` before
running anything:

```bash
export http_proxy="http://your-proxy:3128"
export https_proxy="http://your-proxy:3128"
export no_proxy="169.254.169.254,localhost,127.0.0.1"
```

---

## Step 1 — Clone the Bootstrap Script

If you do not yet have the repo, grab just the bootstrap script first using
HTTPS (no key needed at this point):

```bash
# Option A: you already have the repo checked out
cd rke2-aws-infra

# Option B: bootstrap from scratch — download the script directly
curl -sSL https://gitlab.com/YOUR_NAMESPACE/rke2-aws-infra/-/raw/main/scripts/bootstrap-rhel8.sh \
  -o bootstrap-rhel8.sh
chmod +x bootstrap-rhel8.sh
bash bootstrap-rhel8.sh
```

The script will install all required tools, generate your SSH key if it does
not already exist, and print a summary. Proceed to Step 2 after it completes.

---

## Step 2 — Run the Bootstrap Script

```bash
chmod +x scripts/bootstrap-rhel8.sh
bash scripts/bootstrap-rhel8.sh
```

The script installs the following, skipping anything already present:

| Tool        | Version installed   | Purpose                        |
|-------------|---------------------|--------------------------------|
| git         | latest via dnf      | Source control                 |
| unzip/jq    | latest via dnf      | Utilities                      |
| AWS CLI v2  | latest              | AWS API access                 |
| Terraform   | 1.7.5               | Infrastructure provisioning    |
| kubectl     | v1.26.15            | Kubernetes cluster access      |
| Helm        | 3 (latest)          | Application chart deployments  |

It also generates an Ed25519 SSH key at `~/.ssh/rke2_id_ed25519` if one does
not already exist, starts the `ssh-agent`, and loads the key.

At the end of the script, your public key is printed to the terminal. Copy it —
you will need it in the next step.

---

## Step 3 — Add Your Public Key to GitLab

The public key printed by the bootstrap script must be added to GitLab so you
can clone the repo over SSH. If you missed it, print it again:

```bash
cat ~/.ssh/rke2_id_ed25519.pub
```

1. Log into GitLab
2. Click your **avatar (top right) → Preferences → SSH Keys**
3. Click **Add new key**
4. Paste the full public key line (starts with `ssh-ed25519 ...`)
5. Title: `rke2-rhel8-workspace`
6. Click **Add key**

Test the connection:

```bash
ssh -T git@gitlab.com
# First time: type "yes" to accept the host fingerprint
# Expected: "Welcome to GitLab, @yourusername!"
```

---

## Step 4 — Configure AWS Credentials

```bash
aws configure
# AWS Access Key ID:     <your-access-key>
# AWS Secret Access Key: <your-secret-key>
# Default region name:   us-east-1
# Default output format: json

# Verify
aws sts get-caller-identity
```

> **Workspace IAM role**: If your RHEL 8 workspace has an IAM instance profile
> attached, you can skip `aws configure` entirely — the AWS CLI will pick up
> credentials from the instance metadata automatically. Verify with
> `aws sts get-caller-identity` without configuring anything.

---

## Step 5 — Clone the Repo

```bash
git clone git@gitlab.com:YOUR_NAMESPACE/rke2-aws-infra.git
cd rke2-aws-infra
```

Replace `YOUR_NAMESPACE/rke2-aws-infra` with your actual GitLab project path
(found on the GitLab project page under **Clone → Clone with SSH**).

---

## Step 6 — Subscribe to the CIS Ubuntu 24.04 AMI

Before Terraform can use the AMI, your AWS account must be subscribed to it:

1. Visit: https://aws.amazon.com/marketplace/pp/prodview-6l5e56nst6r3g
2. Click **Continue to Subscribe** → **Accept Terms**
3. Wait ~1-2 minutes for activation

Then find the AMI ID for your region:

```bash
aws ec2 describe-images \
  --owners aws-marketplace \
  --filters "Name=name,Values=*CIS*Ubuntu*24.04*Level 1*" \
  --query "sort_by(Images, &CreationDate)[-1].{ID:ImageId,Name:Name}" \
  --output table \
  --region us-east-1
```

Note the `ImageId` (format: `ami-XXXXXXXXXXXXXXXXX`).

> **Compatibility note**: RKE2 v1.26 was built against older kernels. Ubuntu
> 24.04 ships kernel 6.8. The `pre_userdata` scripts include the necessary
> kernel module loading and sysctl tuning to maximise compatibility. Validate
> in a non-production environment first. Ubuntu 22.04 CIS (kernel 5.15) is a
> safer kernel pairing if containerd issues arise.

---

## Step 7 — Configure terraform.tfvars

Open `terraform.tfvars` with your preferred editor (`vi`, `nano`, `vim`):

```bash
vi terraform.tfvars
```

Set the following values at minimum:

```hcl
aws_region   = "us-east-1"           # Your AWS region
cluster_name = "rke2-prod"           # Max 24 characters
environment  = "prod"

ami_id              = "ami-XXXXXXXXXXXX"           # From Step 6
ssh_public_key_path = "~/.ssh/rke2_id_ed25519.pub" # Generated in Step 2

control_plane_instance_type = "c5.2xlarge"
worker_instance_type        = "t3.xlarge"
worker_spot                 = true   # Spot workers — ~60-70% cost saving

rke2_version = "v1.26.15+rke2r1"   # EOL — plan upgrade to v1.28+ after deploy
```

---

## Step 8 — Restrict the Bastion SSH Source CIDR

Open `security_groups.tf` and replace `0.0.0.0/0` in the bastion ingress rule
with the public IP of your RHEL 8 workspace. This locks SSH access to the
bastion down to your workspace only:

```bash
# Find your workspace's public egress IP
curl -s https://api.ipify.org
# e.g. 203.0.113.42
```

Then edit `security_groups.tf`:

```bash
vi security_groups.tf
```

Find and update this block:

```hcl
ingress {
  description = "SSH from allowed source"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["203.0.113.42/32"]   # replace with your workspace IP
}
```

> If your workspace is assigned a dynamic IP, use your organisation's egress
> NAT IP range instead of a single `/32`. Never leave this as `0.0.0.0/0`
> in production.

---

## Step 9 — Initialise Terraform

```bash
terraform init
```

This downloads the AWS, random, cloudinit, tls, and local providers, and fetches
the `rancherfederal/rke2-aws-tf` module from GitHub (pinned to `v2.5.1`).

Expected output ends with: `Terraform has been successfully initialized!`

---

## Step 10 — Plan and Review

```bash
terraform plan -out=tfplan
```

Read through the plan output before applying. You should see resources being
created for: VPC, subnets, IGW, NAT gateway, EIPs, security groups, SSH key
pair, bastion EC2, RKE2 server ASG, worker ASG, internal control plane NLB,
and the application-facing NLB.

Nothing is changed in AWS until you run `apply`.

---

## Step 11 — Deploy Everything

```bash
terraform apply tfplan
```

This deploys the complete stack in one shot — VPC, networking, bastion, and
the full RKE2 cluster. Expect **10-15 minutes** for the cluster bootstrap to
complete. The RKE2 control plane must initialise and upload the join token to
S3 before the worker ASG can boot and join.

After apply, review all outputs:

```bash
terraform output
```

Key values:
- `bastion_public_ip` — SSH jump host (EIP, stable)
- `control_plane_lb_dns` — internal NLB for the Kubernetes API (private only)
- `app_nlb_public_ip` — public EIP for application traffic; point DNS here
- `kubeconfig_s3_path` — S3 path to the generated kubeconfig

---

## Step 12 — Fetch kubeconfig and Verify the Cluster

```bash
KUBECONFIG_PATH=$(terraform output -raw kubeconfig_s3_path)
mkdir -p ~/.kube
aws s3 cp "${KUBECONFIG_PATH}" ~/.kube/config
chmod 600 ~/.kube/config

# Verify all 5 nodes are Ready (1 control plane + 4 workers)
kubectl get nodes -o wide
```

Expected output:

```
NAME                          STATUS   ROLES                       AGE   VERSION
ip-10-0-1-XXX.ec2.internal    Ready    control-plane,etcd,master   5m    v1.26.15+rke2r1
ip-10-0-2-AAA.ec2.internal    Ready    <none>                      4m    v1.26.15+rke2r1
ip-10-0-2-BBB.ec2.internal    Ready    <none>                      4m    v1.26.15+rke2r1
ip-10-0-2-CCC.ec2.internal    Ready    <none>                      4m    v1.26.15+rke2r1
ip-10-0-2-DDD.ec2.internal    Ready    <none>                      4m    v1.26.15+rke2r1
```

If nodes are not Ready after 15 minutes, see the Troubleshooting section below.

---

## Step 13 — SSH Into Cluster Nodes (via Bastion)

The control plane and workers are in private subnets — reach them by hopping
through the bastion. The ssh-agent loaded your key in Step 2, so agent
forwarding works automatically.

```bash
# SSH into the bastion
BASTION_IP=$(terraform output -raw bastion_public_ip)
ssh -A ubuntu@${BASTION_IP}

# From the bastion — list all node private IPs
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=rke2-prod" \
  --query "Reservations[*].Instances[*].[PrivateIpAddress,Tags[?Key=='Name'].Value|[0],State.Name]" \
  --output table

# SSH to control plane
ssh ubuntu@10.0.1.X

# SSH to a worker node
ssh ubuntu@10.0.2.X
```

The SSH user on every node is **`ubuntu`** — see the note on SSH users in
the README.

---

## Step 14 — Deploy Helm Charts

Run from your workspace (kubectl is already configured via Step 12):

```bash
cd ~/rke2-aws-infra

# Set your email for Let's Encrypt certificate issuers
export ACME_EMAIL="your@email.com"

chmod +x helm/deploy.sh
bash helm/deploy.sh
```

This deploys in order: cert-manager → ingress-nginx → CoreDNS patch →
Let's Encrypt ClusterIssuers.

Verify:

```bash
kubectl get pods -n cert-manager
kubectl get pods -n ingress-nginx
kubectl get nodes
```

---

## Step 15 — Configure DNS and Expose Applications

```bash
terraform output app_nlb_public_ip
```

Point your domain's DNS A record (or Route 53 record) to this IP, then follow
[coredns-guide.md](./coredns-guide.md) for the full Ingress and TLS walkthrough.

---

## Day-2 Operations — Applying Changes

When you update Terraform or Helm files:

```bash
cd ~/rke2-aws-infra

# Pull latest from GitLab
git pull origin main

# Review changes
terraform plan -out=tfplan

# Apply
terraform apply tfplan
```

For Helm chart updates:

```bash
bash helm/deploy.sh
# deploy.sh uses --upgrade --install so it is safe to re-run at any time
```

---

## Keeping the SSH Agent Alive Across Sessions

The `ssh-agent` started by the bootstrap script lives only for that shell
session. If you disconnect and reconnect to the workspace, reload the key:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/rke2_id_ed25519
ssh-add -l   # confirm key is loaded
```

To make this automatic on login, add these lines to `~/.bashrc`:

```bash
# Auto-start ssh-agent and load rke2 key
if ! pgrep -u "$USER" ssh-agent > /dev/null; then
  eval "$(ssh-agent -s)"
fi
if [ -f "$HOME/.ssh/rke2_id_ed25519" ]; then
  ssh-add "$HOME/.ssh/rke2_id_ed25519" 2>/dev/null
fi
```

Then reload: `source ~/.bashrc`

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `terraform init` fails with module download error | No outbound internet from workspace | Check proxy settings; confirm github.com is reachable |
| `aws configure` credentials rejected | Wrong keys or wrong region | Re-run `aws configure`; confirm with `aws sts get-caller-identity` |
| Nodes stuck in `NotReady` after 15 min | Canal/VXLAN blocked or RKE2 bootstrap failed | SSH to control plane via bastion; check `sudo journalctl -u rke2-server -f` |
| Worker nodes not joining | S3 token fetch failed or IAM policy missing | Check worker userdata logs: `sudo cat /var/log/cloud-init-output.log` |
| `kubectl` connection refused | kubeconfig server URL mismatch | Confirm `~/.kube/config` server points to the internal NLB DNS, not localhost |
| SSH to bastion fails | Bastion SG source CIDR doesn't match workspace IP | Update `security_groups.tf` CIDR and run `terraform apply` |
| Spot worker interrupted, pod lost | Expected spot behaviour | Ensure app `replicas >= 2` and PodDisruptionBudget is set |

---

## ⚠️ Known Deviations from Defaults / Best Practice Notes

| Item | Your Config | Industry Standard | Notes |
|------|-------------|-------------------|-------|
| Control plane count | 1 | 3 (etcd HA quorum) | Single CP is a SPOF. Set `control_plane_count = 3` for production. |
| RKE2 version | v1.26.15 | v1.28+ or v1.29+ | v1.26 is EOL. Plan upgrade. |
| Pod CIDR | 169.254.0.0/16 | 10.42.0.0/16 | Link-local range; monitor DNS reverse-lookup behaviour. |
| Ubuntu version | 24.04 + RKE2 1.26 | Ubuntu 22.04 + RKE2 1.26 | Kernel 6.8 is newer than RKE2 1.26 test matrix; validate carefully. |
| Bastion SSH CIDR | Workspace IP/32 | Org egress CIDR | Confirm locked down before deploying. |
| Worker instances | Spot | On-Demand | Set `worker_spot = false` in tfvars to revert if workloads need guaranteed capacity. |

---

## Upgrade Path (RKE2 1.26 → 1.28)

```bash
# 1. Update rke2_version in terraform.tfvars:
#      rke2_version = "v1.28.15+rke2r1"

# 2. Plan and review launch template changes
terraform plan -out=tfplan

# 3. Apply
terraform apply tfplan

# 4. Validate
kubectl get nodes
```

---

## Destroy

```bash
# Remove Helm releases first to avoid orphaned AWS load balancer resources
helm uninstall ingress-nginx -n ingress-nginx
helm uninstall cert-manager -n cert-manager

# Destroy all Terraform-managed infrastructure
terraform destroy
```
