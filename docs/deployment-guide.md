# RKE2 Cluster Deployment Guide

End-to-end runbook for deploying the RKE2 cluster on AWS from a **RHEL 8 AWS
Workspace** terminal session.

---

## Deployment Strategy

```
RHEL 8 AWS Workspace (terminal)
  └── Run bootstrap script       — installs git, terraform, kubectl, helm, aws cli
  └── Generate SSH key           — used for GitLab and all EC2 node access
  └── Clone repo from GitLab
  └── Phase 1: bootstrap apply   — creates S3 state bucket, DynamoDB lock, KMS key
  └── Phase 2: prod apply        — deploys VPC, bastion, RKE2 cluster in one shot
  └── Fetch kubeconfig from S3   — verify cluster
```

Deployment is split into two Terraform roots:

**`environments/bootstrap/`** — run once, never destroyed. Creates the S3 bucket
used as the remote backend for prod state, the DynamoDB lock table, and a
dedicated KMS key for state encryption. Bootstrap state is stored persistently
at `~/.terraform-bootstrap/rke2-prod.tfstate` so it survives across sessions.

**`environments/prod/`** — the main cluster. Can be applied and destroyed freely
without touching the bootstrap bucket. Creates the VPC, networking, bastion,
RKE2 cluster, a separate KMS key for EBS encryption, and pushes SSH keys,
kubeconfig, and a outputs snapshot to the S3 bucket.

---

## Prerequisites

Your RHEL 8 workspace needs outbound internet access to reach:
- `dnf` package repos (or a local mirror)
- `releases.hashicorp.com` (Terraform)
- `dl.k8s.io` (kubectl)
- `get.helm.sh` (Helm)
- `awscli.amazonaws.com` (AWS CLI)
- `github.com` (rancherfederal/rke2-aws-tf Terraform module)
- `gitlab.com` (your repo)

If your workspace is behind a proxy, set `http_proxy` / `https_proxy` before
running anything:

```bash
export http_proxy="http://your-proxy:3128"
export https_proxy="http://your-proxy:3128"
export no_proxy="169.254.169.254,localhost,127.0.0.1"
```

---

## Step 1 — Run the Bootstrap Script

```bash
chmod +x scripts/bootstrap-rhel8.sh
bash scripts/bootstrap-rhel8.sh
```

The script installs the following, skipping anything already present:

| Tool        | Version installed   | Purpose                        |
|-------------|---------------------|--------------------------------|
| git         | latest via dnf      | Source control                 |
| unzip/jq    | latest via dnf      | Utilities (jq required by cluster-start.sh) |
| AWS CLI v2  | latest              | AWS API access                 |
| Terraform   | 1.7.5               | Infrastructure provisioning    |
| kubectl     | v1.26.15            | Kubernetes cluster access      |

It also generates an Ed25519 SSH key at `~/.ssh/rke2_id_ed25519` if one does
not already exist, starts the `ssh-agent`, and loads the key.

At the end of the script your public key is printed to the terminal. Copy it —
you will need it in the next step.

---

## Step 2 — Add Your Public Key to GitLab

```bash
cat ~/.ssh/rke2_id_ed25519.pub
```

1. Log into GitLab
2. Click your **avatar → Preferences → SSH Keys → Add new key**
3. Paste the full public key line (starts with `ssh-ed25519 ...`)
4. Title: `rke2-rhel8-workspace`
5. Click **Add key**

Test the connection:

```bash
ssh -T git@gitlab.com
```

---

## Step 3 — Configure AWS Credentials

```bash
aws configure
# AWS Access Key ID:     <your-access-key>
# AWS Secret Access Key: <your-secret-key>
# Default region name:   us-west-2
# Default output format: json

# Verify
aws sts get-caller-identity
```

> If your RHEL 8 workspace has an IAM instance profile attached, skip
> `aws configure` — the AWS CLI picks up credentials from instance metadata
> automatically.

---

## Step 4 — Clone the Repo

```bash
git clone git@gitlab.com:YOUR_NAMESPACE/rke2-aws-infra.git
cd rke2-aws-infra
```

---

## Step 5 — Subscribe to the CIS Ubuntu 24.04 AMI

Before Terraform can launch instances from this AMI, your AWS account must
be subscribed:

1. Visit: https://aws.amazon.com/marketplace/pp/prodview-6l5e56nst6r3g
2. Click **Continue to Subscribe → Accept Terms**
3. Wait ~1-2 minutes for activation

Then find the AMI ID for your region:

```bash
aws ec2 describe-images \
  --owners aws-marketplace \
  --filters "Name=name,Values=*CIS*Ubuntu*24.04*Level 1*" \
  --query "sort_by(Images, &CreationDate)[-1].{ID:ImageId,Name:Name}" \
  --output table \
  --region us-west-2
```

Note the `ImageId` (format: `ami-XXXXXXXXXXXXXXXXX`).

> **Compatibility note**: RKE2 v1.26 was built against older kernels. Ubuntu
> 24.04 ships kernel 6.8. The `pre_userdata` scripts include the necessary
> kernel module loading and sysctl tuning to maximise compatibility. Validate
> in a non-production environment first.

---

## Step 6 — Deploy the Bootstrap (Run Once)

The bootstrap creates the S3 bucket and DynamoDB table used as the Terraform
remote backend for the prod environment, plus a KMS key to encrypt them.

```bash
cd environments/bootstrap
terraform init
terraform apply
```

Note the outputs — you will need `bucket_name` in the next step:

```
bucket_name         = "rke2-prod-tfstate-641275310402"
dynamodb_table_name = "rke2-prod-tfstate-lock"
kms_key_arn         = "arn:aws:kms:us-west-2:..."
aws_region          = "us-west-2"
```

Bootstrap state is stored at `~/.terraform-bootstrap/rke2-prod.tfstate`. This
file must be preserved — if it is lost, Terraform will try to recreate resources
that already exist and fail with `AlreadyExists` errors. Back it up if needed:

```bash
cp ~/.terraform-bootstrap/rke2-prod.tfstate \
   ~/.terraform-bootstrap/rke2-prod.tfstate.bak
```

> **Never run `terraform destroy` in the bootstrap directory** unless you
> intend to permanently delete all cluster state and artifacts.

---

## Step 7 — Configure the Prod Backend

Open `environments/prod/main.tf` and update the backend block with the
`bucket_name` output from Step 6:

```hcl
backend "s3" {
  bucket         = "rke2-prod-tfstate-641275310402"   # from bootstrap output
  key            = "state/terraform.tfstate"
  region         = "us-west-2"
  dynamodb_table = "rke2-prod-tfstate-lock"
  encrypt        = true
}
```

---

## Step 8 — Configure terraform.tfvars

```bash
vi environments/prod/terraform.tfvars
```

Set at minimum:

```hcl
aws_region   = "us-west-2"
cluster_name = "rke2-prod"       # max 24 characters
environment  = "prod"

ami_id              = "ami-XXXXXXXXXXXX"            # from Step 5
ssh_public_key_path = "~/.ssh/rke2_id_ed25519.pub"  # generated in Step 1

control_plane_instance_type = "c5.2xlarge"
worker_instance_type        = "t3.xlarge"
worker_spot                 = true    # spot workers — ~60-70% cost saving

rke2_version = "v1.26.15+rke2r1"    # EOL — plan upgrade to v1.28+ after deploy

pod_cidr     = "10.42.0.0/16"
service_cidr = "10.96.0.0/12"
```

> **`terraform.tfvars` is gitignored** — never commit it to the repo.

---

## Step 9 — Restrict the Bastion SSH Source CIDR

```bash
# Find your workspace's public egress IP
curl -s https://api.ipify.org
```

Edit `modules/securitygroups/main.tf` and replace `0.0.0.0/0` with your IP:

```hcl
ingress {
  description = "SSH from allowed source"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["203.0.113.42/32"]   # replace with your workspace IP
}
```

> Never leave this as `0.0.0.0/0` in production.

---

## Step 10 — Initialise Terraform

```bash
cd environments/prod
terraform init
```

When prompted whether to copy existing state to the new backend, type `yes`.

Expected output ends with: `Terraform has been successfully initialized!`

---

## Step 11 — Plan and Review

```bash
terraform plan -out=tfplan
```

Read through the plan before applying. You should see resources being created
for: VPC, subnets, IGW, NAT gateway, EIPs, security groups, SSH key pair,
KMS key and alias for EBS, bastion EC2, RKE2 server ASG, worker ASG, internal
control plane NLB, and the application-facing NLB.

---

## Step 12 — Deploy Everything

```bash
terraform apply tfplan
```

This deploys the complete stack in one shot. Expect **10-20 minutes** for the
cluster bootstrap to complete. The RKE2 control plane must initialise and upload
the join token to S3 before the worker ASG can boot and join. The CIS hardened
AMI takes longer to bootstrap than a standard image.

After apply, review all outputs:

```bash
terraform output
```

Key values:

| Output | Description |
|--------|-------------|
| `bastion_public_ip` | SSH jump host (EIP, stable) |
| `control_plane_lb_dns` | Internal NLB for the Kubernetes API (private only) |
| `app_nlb_public_ip` | Public EIP for application traffic — point DNS here |
| `kubeconfig_s3_path` | S3 path to the cluster kubeconfig |
| `ssh_public_key_s3_path` | S3 path to the SSH public key |
| `ssh_private_key_s3_path` | S3 path to the SSH private key (KMS encrypted) |
| `ebs_kms_key_arn` | ARN of the KMS key encrypting all cluster EBS volumes |

---

## Step 13 — Fetch kubeconfig and Verify the Cluster

```bash
mkdir -p ~/.kube
aws s3 cp s3://rke2-prod-tfstate-641275310402/kubeconfig/config ~/.kube/config
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

---

## Step 14 — SSH Into Cluster Nodes (via Bastion)

The control plane and workers are in private subnets — reach them by hopping
through the bastion. The ssh-agent loaded your key in Step 1 so agent
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

The SSH user on all nodes is **`ubuntu`**.

---

## Step 15 — Configure DNS and Expose Applications

```bash
terraform output app_nlb_public_ip
```

Point your domain's DNS A record to this IP.

---

## Day-2 Operations

### Viewing Terraform Outputs

At any time from `environments/prod`:

```bash
terraform output          # all outputs
terraform output -json    # JSON format
terraform output bastion_public_ip   # single value
```

### Applying Changes

```bash
cd environments/prod
git pull origin main
terraform plan -out=tfplan
terraform apply tfplan
```

### Stopping and Starting the Cluster

To save cost when the cluster is not in use, use the provided scripts. Because
the cluster mixes on-demand and spot instances, each instance type requires
different handling — a simple "stop all" approach does not work.

#### Why spot instances require special handling

AWS does not allow one-time spot instances to be stopped via the EC2 stop API —
attempting to do so returns an `UnsupportedOperation` error. Additionally,
simply setting ASG desired capacity to 0 is not enough on its own because if
the ASG has any processes suspended (from a previous run), it cannot act on
the capacity change and instances will remain running indefinitely.

The stop script handles workers by:

1. **Resuming all ASG processes** — clears any previously suspended state so
   the ASG can act
2. **Scaling the ASG to 0** — prevents the ASG from launching replacement
   instances during termination
3. **Cancelling spot requests directly** — cancels the underlying one-time
   spot instance requests via the EC2 API, which unblocks termination
4. **Terminating instances directly** — explicitly terminates the instances
   rather than waiting for the ASG, then waits for full termination before
   proceeding

#### Why the control plane is handled differently

The control plane runs on an on-demand instance and its EBS root volume holds
all etcd data, cluster certificates, and RKE2 configuration. Terminating it
would destroy all cluster state. Instead, the stop script:

1. **Suspends ASG health checks** — prevents the ASG from detecting the
   stopped instance as unhealthy and replacing it with a fresh one
2. **Stops the instance via the EC2 API** — the EBS volume remains attached
   and intact, preserving all cluster state

On start, the same instance is restarted and ASG processes are resumed. RKE2's
systemd service starts automatically and the cluster comes back up with full
etcd state — the same workloads, certificates, and configuration as before.

#### Ghost node cleanup

When spot workers are terminated and new ones launch, the old node objects
remain in the Kubernetes API server with `NotReady` status because nothing
removes them automatically. The new workers register under new node names,
leaving stale ghost entries behind. The start script waits for the expected
number of new workers to reach `Ready` state, then deletes all `NotReady`
node objects, leaving a clean cluster.

```bash
# Stop — suspends CP ASG, stops CP instance, cancels spot requests,
#         terminates workers, stops bastion
bash scripts/cluster-stop.sh

# Start — starts bastion and CP instance, resumes CP ASG, restores
#          worker ASG, waits for nodes to be Ready, removes ghost nodes,
#          fetches fresh kubeconfig
bash scripts/cluster-start.sh
```

State between stop and start is saved to `~/.rke2-cluster-state/`.

> **Note**: `jq` must be installed for `cluster-start.sh` to parse saved state.
> It is installed by `bootstrap-rhel8.sh` automatically.

### Keeping the SSH Agent Alive

The `ssh-agent` started by the bootstrap script lives only for that shell
session. If you reconnect to the workspace, reload the key:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/rke2_id_ed25519
```

To make this automatic on login, add to `~/.bashrc`:

```bash
if ! pgrep -u "$USER" ssh-agent > /dev/null; then
  eval "$(ssh-agent -s)"
fi
if [ -f "$HOME/.ssh/rke2_id_ed25519" ]; then
  ssh-add "$HOME/.ssh/rke2_id_ed25519" 2>/dev/null
fi
```

Then: `source ~/.bashrc`

---

## Destroy

```bash
# Destroy all cluster infrastructure (leaves bootstrap bucket intact)
cd environments/prod
terraform destroy
```

The S3 bucket, DynamoDB table, and bootstrap KMS key are **not** destroyed by
this — they are managed by `environments/bootstrap/` and intentionally
preserved.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `terraform init` fails — bucket does not exist | Bootstrap not run yet | Run `terraform apply` in `environments/bootstrap/` first |
| `AlreadyExists` on KMS alias during apply | Orphaned alias from previous failed destroy | Run `aws kms delete-alias --alias-name alias/rke2-prod-ebs --region us-west-2` then re-apply |
| `AlreadyExists` on KMS alias during bootstrap apply | Bootstrap state lost | Run `terraform import aws_kms_alias.state alias/rke2-prod-tfstate` then re-apply |
| Nodes stuck in `NotReady` after 20 min | Canal/VXLAN blocked or RKE2 bootstrap failed | SSH to control plane via bastion; check `sudo journalctl -u rke2-server -f` |
| Worker nodes not joining | S3 token fetch failed or IAM policy missing | Check worker userdata logs: `sudo cat /var/log/cloud-init-output.log` |
| `AccessDenied` on S3 kubeconfig download from bastion | Bastion role missing KMS decrypt permission | Run `terraform apply -target=aws_iam_role_policy.bastion` |
| Ghost nodes in `NotReady` after cluster start | Old node objects from terminated spot instances | Run `kubectl get nodes --no-headers \| awk '$2=="NotReady" {print $1}' \| xargs kubectl delete node` or use `cluster-start.sh` which does this automatically |
| Spot workers not terminating after `cluster-stop.sh` | ASG processes suspended or spot requests not cancelled | Resume ASG processes and cancel spot requests — see cluster-stop.sh comments |
| `kubectl` connection refused | kubeconfig stale after cluster restart | Re-fetch: `aws s3 cp s3://<bucket>/kubeconfig/config ~/.kube/config` |
| SSH to bastion fails | Bastion SG CIDR doesn't match workspace IP | Update `modules/securitygroups/main.tf` CIDR and run `terraform apply` |
| Spot worker interrupted, pod lost | Expected spot behaviour | Ensure app `replicas >= 2` and PodDisruptionBudget is set |

---

## ⚠️ Known Deviations and Best Practice Notes

| Item | Current Config | Industry Standard | Notes |
|------|----------------|-------------------|-------|
| Control plane count | 1 | 3 (etcd HA quorum) | Single CP is a SPOF. Set `control_plane_count = 3` for production. |
| RKE2 version | v1.26.15 | v1.28+ | v1.26 is EOL. Plan upgrade after initial deploy. |
| Ubuntu version | 24.04 + RKE2 1.26 | Ubuntu 22.04 + RKE2 1.26 | Kernel 6.8 is newer than RKE2 1.26 test matrix. Validate carefully. |
| Worker instances | Spot | On-Demand | Set `worker_spot = false` if workloads require guaranteed capacity. |
| Single AZ | Yes | Multi-AZ | All resources in one AZ. An AZ outage takes down the cluster. |

---

## Upgrade Path (RKE2 1.26 → 1.28)

```bash
# 1. Update rke2_version in environments/prod/terraform.tfvars:
#      rke2_version = "v1.28.15+rke2r1"

# 2. Plan and review launch template changes
cd environments/prod
terraform plan -out=tfplan

# 3. Apply
terraform apply tfplan

# 4. Validate
kubectl get nodes
```
