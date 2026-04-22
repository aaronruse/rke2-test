# rke2-aws-infra

Terraform project that provisions a production-grade **RKE2 Kubernetes cluster** on AWS,
built on top of [rancherfederal/rke2-aws-tf](https://github.com/rancherfederal/rke2-aws-tf).

---

## Architecture

```
                          ┌──────────────────────────────────────────────┐
                          │                  AWS VPC (10.0.0.0/16)       │
                          │                                              │
  Internet ──────────────►│  Public Subnet (10.0.0.0/24)                │
                          │  ┌─────────────┐  ┌────────────────────┐   │
        SSH (port 22) ────►  │  Bastion     │  │  App NLB (EIP)     │   │
        HTTP/HTTPS ──────►   │  EC2 + EIP   │  │  Port 80/443       │   │
                          │  └──────┬──────┘  └────────┬───────────┘   │
                          │         │                   │               │
                          │  Private Subnet A (10.0.1.0/24) — CP        │
                          │  ┌─────────────────────────────────────┐    │
                          │  │  Control Plane (c5.2xlarge × 1)     │    │
                          │  │  Internal NLB (API + Supervisor)    │    │
                          │  │  200 GB gp3 encrypted (KMS)         │    │
                          │  └─────────────────────────────────────┘    │
                          │                                              │
                          │  Private Subnet B (10.0.2.0/24) — Workers   │
                          │  ┌─────────────────────────────────────┐    │
                          │  │  Workers (t3.xlarge × 4, Spot)      │    │
                          │  │  350 GB gp3 encrypted (KMS)         │    │
                          │  │  ingress-nginx (NodePort 80/443)    │    │
                          │  └─────────────────────────────────────┘    │
                          │                                              │
                          │  NAT Gateway (EIP) — private node egress     │
                          └──────────────────────────────────────────────┘
```

### Key Parameters

| Parameter         | Value                                                                  |
|-------------------|------------------------------------------------------------------------|
| VPC CIDR          | `10.0.0.0/16`                                                          |
| Pod CIDR          | `10.42.0.0/16`                                                         |
| Service CIDR      | `10.96.0.0/12`                                                         |
| Control Plane     | c5.2xlarge, 200 GB gp3 encrypted                                       |
| Workers           | t3.xlarge × 4 (Spot), 350 GB gp3 encrypted                            |
| RKE2 Version      | v1.26.15+rke2r1                                                        |
| OS                | CIS Ubuntu Linux 24.04 Benchmark Level 1                              |

---

## Deployment Overview

Deployment is split into two phases:

```
Phase 1 — Bootstrap (run once, never destroyed)
  └── environments/bootstrap/
      └── terraform apply  — creates S3 state bucket, DynamoDB lock table,
                             and a KMS key for state encryption.
                             State stored at ~/.terraform-bootstrap/rke2-prod.tfstate

Phase 2 — Cluster (apply / destroy freely)
  └── environments/prod/
      └── terraform apply  — deploys VPC, networking, bastion, RKE2 cluster,
                             KMS key for EBS encryption, and pushes SSH keys,
                             kubeconfig, and outputs to the S3 bucket.
```

The bootstrap bucket and its state are completely independent of the prod root.
`terraform destroy` in `environments/prod/` never touches the state bucket.

---

## ⚠️ Important Notes Before Deploying

1. **Run `environments/bootstrap/` first** — the S3 state bucket must exist before `terraform init` in `environments/prod/`
2. **Run `scripts/bootstrap-rhel8.sh`** — installs all tools and generates your SSH key
3. **Subscribe to the CIS Ubuntu 24.04 AMI** on AWS Marketplace before deploying — see [docs/deployment-guide.md](docs/deployment-guide.md)
4. **Restrict bastion SSH source** in `modules/securitygroups/main.tf` from `0.0.0.0/0` to your workspace's IP
5. **Single control plane is a SPOF** — set `control_plane_count = 3` for production HA
6. **RKE2 v1.26 is EOL** — plan upgrade to v1.28+ after initial deployment
7. **`terraform.tfvars` is gitignored in prod** — never commit it; it may contain sensitive values

---

## Quick Start

All steps run from a **RHEL 8 AWS Workspace** terminal.

```bash
# 1. Run the bootstrap script — installs terraform, kubectl, helm, aws cli,
#    generates your SSH key, and prints the public key to add to GitLab
chmod +x scripts/bootstrap-rhel8.sh
bash scripts/bootstrap-rhel8.sh

# 2. Add the printed public key to GitLab, then test:
ssh -T git@gitlab.com

# 3. Configure AWS credentials (skip if workspace has an IAM instance profile)
aws configure

# 4. Clone the repo
git clone git@gitlab.com:YOUR_NAMESPACE/rke2-aws-infra.git
cd rke2-aws-infra

# 5. Subscribe to CIS Ubuntu 24.04 AMI at:
#    https://aws.amazon.com/marketplace/pp/prodview-6l5e56nst6r3g
#    Then find your region's AMI ID:
aws ec2 describe-images \
  --owners aws-marketplace \
  --filters "Name=name,Values=*CIS*Ubuntu*24.04*Level 1*" \
  --query "sort_by(Images, &CreationDate)[-1].{ID:ImageId,Name:Name}" \
  --output table --region us-west-2

# 6. Deploy the bootstrap (S3 bucket + DynamoDB + KMS) — run once
cd environments/bootstrap
terraform init
terraform apply

# 7. Update the bucket name in the prod backend block
#    Copy the bucket_name output from step 6 into environments/prod/main.tf:
#    backend "s3" { bucket = "<bucket_name_from_output>" ... }

# 8. Edit terraform.tfvars — set ami_id, cluster_name, region
vi environments/prod/terraform.tfvars

# 9. Restrict bastion SSH source to your workspace IP
curl -s https://api.ipify.org   # find your IP
vi modules/securitygroups/main.tf

# 10. Deploy the cluster (~10-15 min)
cd environments/prod
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 11. Fetch kubeconfig and verify cluster
aws s3 cp s3://<your-tfstate-bucket>/kubeconfig/config ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes
```

See [docs/deployment-guide.md](docs/deployment-guide.md) for the full step-by-step runbook.

---

## Cluster Start / Stop

To save cost when the cluster is not in use, use the provided scripts. These
handle spot and on-demand instances correctly — the control plane is stopped
(preserving etcd data on EBS), while spot workers are terminated and rejoin
fresh on restart.

```bash
# Stop the cluster (preserves control plane EBS / etcd state)
bash scripts/cluster-stop.sh

# Start the cluster (resumes control plane, launches fresh spot workers,
# cleans up NotReady ghost nodes, and fetches fresh kubeconfig)
bash scripts/cluster-start.sh
```

State is saved to `~/.rke2-cluster-state/` between stop and start.

---

## S3 Bucket Contents

After a successful apply, the tfstate bucket contains:

| Path | Contents |
|------|----------|
| `state/terraform.tfstate` | Terraform remote state |
| `ssh/rke2_id_ed25519.pub` | SSH public key |
| `ssh/rke2_id_ed25519` | SSH private key (KMS encrypted) |
| `kubeconfig/config` | Cluster kubeconfig |
| `outputs/terraform.json` | Snapshot of all Terraform outputs |

---

## File Structure

```
rke2-aws-infra/
├── environments/
│   ├── bootstrap/
│   │   └── main.tf               # S3 bucket, DynamoDB lock, KMS key — run once
│   └── prod/
│       ├── main.tf               # Provider, backend, module calls, outputs
│       ├── variables.tf          # All input variables with descriptions
│       ├── terraform.tfvars      # Your environment values (gitignored)
│       ├── iam.tf                # Bastion IAM role/policy, EBS KMS key/alias
│       ├── s3.tf                 # S3 objects: SSH keys, kubeconfig, outputs
│       └── ssh_keys.tf           # AWS key pair from local public key file
├── modules/
│   ├── networking/
│   │   ├── main.tf               # VPC, subnets, IGW, NAT gateway, route tables, EIPs
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── securitygroups/
│   │   ├── main.tf               # SGs for bastion, control plane, and workers
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── bastion/
│   │   └── main.tf               # Bastion EC2 instance with SSH hardening
│   └── rke2/
│       ├── main.tf               # RKE2 control plane + worker nodepool, app NLB
│       ├── variables.tf          # Includes ebs_kms_key_arn input
│       └── outputs.tf
├── scripts/
│   ├── bootstrap-rhel8.sh        # Installs all tools on RHEL 8; run first
│   ├── cluster-stop.sh           # Stops cluster to save cost
│   └── cluster-start.sh         # Restarts cluster and cleans up ghost nodes
└── docs/
    └── deployment-guide.md       # Full step-by-step operator runbook
```

---

## Full Documentation

- [Deployment Guide](docs/deployment-guide.md) — prerequisites, step-by-step deploy, SSH tunnel, upgrade path
