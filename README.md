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
                          │  │  200 GB gp3 encrypted               │    │
                          │  └─────────────────────────────────────┘    │
                          │                                              │
                          │  Private Subnet B (10.0.2.0/24) — Workers   │
                          │  ┌─────────────────────────────────────┐    │
                          │  │  Workers (t3.xlarge × 4)            │    │
                          │  │  350 GB gp3 encrypted each          │    │
                          │  │  ingress-nginx (NodePort 80/443)    │    │
                          │  └─────────────────────────────────────┘    │
                          │                                              │
                          │  NAT Gateway (EIP) — private node egress     │
                          └──────────────────────────────────────────────┘
```

### Key Parameters

| Parameter         | Value                                                                   |
|-------------------|-------------------------------------------------------------------------|
| VPC CIDR          | `10.0.0.0/16`                                                           |
| Pod CIDR          | `10.42.0.0/16`                                                        |
| Service CIDR      | `10.96.0.0/12`                                                          |
| CoreDNS IP        | `10.96.0.10`                                                            |
| Control Plane     | c5.2xlarge, 200 GB gp3                                                  |
| Workers           | t3.xlarge × 4, 350 GB gp3                                              |
| RKE2 Version      | v1.26.15+rke2r1                                                         |
| OS                | CIS Ubuntu Linux 24.04 Benchmark - Level 1 - v03 -prod-2o2sghfkrk7vk  |
| AMI ID            | ami-004ca9c8986f68ab5                                                   |

---

## Workstation Setup Help

1. Download RHEL 8 KVM/qcow2 from here and use it to create the AWS Workspace RHEL8 sim: https://access.redhat.com/downloads/content/rhel
2. Use the cloud-config-rehl8 cloud-init script in the setup folder to launch the qcow2 so it can be logged into with a ssh key 

```
sudo subscription-manager register --username <your_user> --password <your_password> --auto-attach
sudo dnf update -y
sudo dnf install git -y
git --version
git config --global user.name "Your Name"
git config --global user.email "youremail@example.com"
git clone git@gitlab.com:darksignal/devops/infra/rke2-aws-tf-toolshed.git
```

---

## ⚠️ Important Notes Before Deploying

1. **Run `scripts/bootstrap-rhel8.sh` first** — installs all tools and generates your SSH key
2. **Subscribe to the CIS Ubuntu 24.04 AMI** on AWS Marketplace before deploying — see [docs/deployment-guide.md](docs/deployment-guide.md)
3. **Restrict bastion SSH source** in `modules/securitygroups/main.tf` from `0.0.0.0/0` to your workspace's IP
4. **Single control plane is a SPOF** — set `control_plane_count = 3` for production HA
5. **RKE2 v1.26 is EOL** — plan upgrade to v1.28+ after initial deployment

---

## Quick Start

All steps run from a **RHEL 8 AWS Workspace** terminal. A single `terraform apply`
deploys the full stack — VPC, networking, bastion, and RKE2 cluster.

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
  --output table --region us-east-1

# 6. Edit terraform.tfvars — set ami_id, cluster_name, region
vi environments/prod/terraform.tfvars

# 7. Restrict bastion SSH source to your workspace IP in modules/securitygroups/main.tf
curl -s https://api.ipify.org   # find your IP
vi modules/securitygroups/main.tf

# 8. Deploy everything in one shot (~10-15 min)
cd environments/prod
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 9. Fetch kubeconfig and verify cluster
aws s3 cp $(terraform output -raw kubeconfig_s3_path) ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes

# 10. Deploy Helm charts (ingress-nginx, cert-manager, CoreDNS)
export ACME_EMAIL="your@email.com"
bash helm/deploy.sh
```

See [docs/deployment-guide.md](docs/deployment-guide.md) for the full step-by-step
runbook and [docs/coredns-guide.md](docs/coredns-guide.md) for DNS and ingress setup.

---

## File Structure

```
rke2-aws-infra/
├── environments/
│   └── prod/
│       ├── main.tf               # Provider, data sources, locals, all module calls, outputs
│       ├── variables.tf          # All input variables with descriptions
│       ├── terraform.tfvars      # Your environment values (gitignored in prod)
│       ├── iam.tf                # Bastion IAM role, policy, and instance profile
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
│   │   └── main.tf               # Bastion EC2 instance with cloud-init SSH hardening
│   └── rke2/
│       ├── main.tf               # RKE2 control plane + worker nodepool, app NLB wiring
│       ├── variables.tf
│       └── outputs.tf
├── scripts/
│   └── bootstrap-rhel8.sh        # Auto-installs all tools on RHEL 8; run first
├── helm/
│   ├── deploy.sh                 # Idempotent Helm deployment script
│   ├── ingress-nginx-values.yaml
│   ├── cert-manager-values.yaml
│   ├── coredns-values.yaml
│   └── coredns-helmchart-patch.yaml
└── docs/
    ├── deployment-guide.md       # Full step-by-step operator runbook (RHEL 8)
    └── coredns-guide.md          # CoreDNS setup + public ingress/egress guide
```

---

## Full Documentation

- [Deployment Guide](docs/deployment-guide.md) — prerequisites, step-by-step deploy, SSH tunnel, upgrade path
- [CoreDNS & Ingress Guide](docs/coredns-guide.md) — DNS setup, exposing apps, TLS, troubleshooting
