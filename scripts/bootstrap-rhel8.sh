#!/usr/bin/env bash
# =============================================================================
# bootstrap-rhel8.sh
# Installs all tools required to deploy the RKE2 cluster from a RHEL 8
# AWS Workspace terminal. Safe to re-run — skips anything already installed.
#
# Tools installed:
#   - git, unzip, jq, curl (via dnf)
#   - AWS CLI v2
#   - Terraform 1.7.5
#   - kubectl 1.26.15 (matches RKE2 version)
#   - Helm 3
#
# Usage:
#   chmod +x scripts/bootstrap-rhel8.sh
#   ./scripts/bootstrap-rhel8.sh
# =============================================================================
set -euo pipefail

# ---- colour helpers ----------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*"; exit 1; }
section() { echo -e "\n${CYAN}=== $* ===${NC}"; }

# ---- version pins ------------------------------------------------------------
TERRAFORM_VERSION="1.7.5"
KUBECTL_VERSION="v1.26.15"
HELM_INSTALL_SCRIPT="https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"

# ---- helper: check if a binary is already installed -------------------------
need_install() {
  local bin="$1"
  local version_flag="${2:---version}"
  if command -v "$bin" &>/dev/null; then
    info "$bin already installed: $($bin $version_flag 2>&1 | head -1)"
    return 1   # no install needed
  fi
  return 0     # install needed
}

# =============================================================================
section "System packages (git, unzip, jq, curl)"
# =============================================================================
PKGS=()
for pkg in git unzip jq curl wget; do
  rpm -q "$pkg" &>/dev/null || PKGS+=("$pkg")
done

if [[ ${#PKGS[@]} -gt 0 ]]; then
  info "Installing: ${PKGS[*]}"
  sudo dnf install -y "${PKGS[@]}"
else
  info "All system packages already present"
fi

# =============================================================================
section "AWS CLI v2"
# =============================================================================
if need_install aws; then
  info "Installing AWS CLI v2..."
  curl -sSL "$AWSCLI_URL" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/awscli-install
  sudo /tmp/awscli-install/aws/install --update
  rm -rf /tmp/awscliv2.zip /tmp/awscli-install
  info "AWS CLI installed: $(aws --version)"
fi

# Verify credentials are configured
if ! aws sts get-caller-identity &>/dev/null; then
  warn "AWS credentials not configured or not valid."
  warn "Run 'aws configure' before deploying."
  warn "You will need: Access Key ID, Secret Access Key, region (e.g. us-east-1)"
fi

# =============================================================================
section "Terraform ${TERRAFORM_VERSION}"
# =============================================================================
if need_install terraform version; then
  info "Installing Terraform ${TERRAFORM_VERSION}..."
  TF_ZIP="terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
  curl -sSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${TF_ZIP}" \
    -o "/tmp/${TF_ZIP}"
  unzip -q "/tmp/${TF_ZIP}" -d /tmp/terraform-install
  sudo install -o root -g root -m 0755 /tmp/terraform-install/terraform /usr/local/bin/terraform
  rm -rf "/tmp/${TF_ZIP}" /tmp/terraform-install
  info "Terraform installed: $(terraform version | head -1)"
fi

# =============================================================================
section "kubectl ${KUBECTL_VERSION}"
# =============================================================================
if need_install kubectl version; then
  info "Installing kubectl ${KUBECTL_VERSION}..."
  curl -sSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /tmp/kubectl
  sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm /tmp/kubectl
  info "kubectl installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
fi

# =============================================================================
section "Helm 3"
# =============================================================================
if need_install helm version; then
  info "Installing Helm 3..."
  curl -sSL "$HELM_INSTALL_SCRIPT" | bash
  info "Helm installed: $(helm version --short)"
fi

# =============================================================================
section "SSH key setup"
# =============================================================================
SSH_KEY="$HOME/.ssh/rke2_id_ed25519"

if [[ -f "${SSH_KEY}" ]]; then
  info "SSH key already exists at ${SSH_KEY} — skipping generation"
else
  info "Generating Ed25519 SSH key at ${SSH_KEY}..."
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -C "rke2-deploy-key" -f "${SSH_KEY}" -N ""
  info "Key generated. Public key:"
  echo ""
  cat "${SSH_KEY}.pub"
  echo ""
  warn "Add the above public key to GitLab before cloning the repo:"
  warn "  GitLab → User avatar → Preferences → SSH Keys → Add new key"
fi

# Ensure ssh-agent is running and key is loaded
if ! pgrep -u "$USER" ssh-agent &>/dev/null; then
  info "Starting ssh-agent..."
  eval "$(ssh-agent -s)"
fi

if ! ssh-add -l 2>/dev/null | grep -q "${SSH_KEY}"; then
  info "Loading SSH key into agent..."
  ssh-add "${SSH_KEY}"
fi

info "SSH agent keys loaded:"
ssh-add -l

# =============================================================================
section "Summary"
# =============================================================================
echo ""
info "All tools installed and verified:"
printf "  %-12s %s\n" "git:"       "$(git --version)"
printf "  %-12s %s\n" "aws:"       "$(aws --version 2>&1 | head -1)"
printf "  %-12s %s\n" "terraform:" "$(terraform version | head -1)"
printf "  %-12s %s\n" "kubectl:"   "$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>&1 | head -1)"
printf "  %-12s %s\n" "helm:"      "$(helm version --short)"
echo ""

# Check AWS credentials
if aws sts get-caller-identity &>/dev/null; then
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  ARN=$(aws sts get-caller-identity --query Arn --output text)
  info "AWS credentials valid:"
  printf "  %-12s %s\n" "Account:" "$ACCOUNT"
  printf "  %-12s %s\n" "Identity:" "$ARN"
else
  warn "AWS credentials not configured. Run 'aws configure' before proceeding."
fi

echo ""
info "Bootstrap complete. Next step: see docs/deployment-guide.md"
