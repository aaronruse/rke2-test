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

# ---- Start ssh-agent with a persistent socket file --------------------------
# Using a fixed socket path (~/.ssh/ssh-agent.sock) means the same agent
# is reused across terminal sessions. The socket path is written to
# ~/.ssh/ssh-agent.env and sourced by ~/.bashrc on every new session so
# SSH_AUTH_SOCK is always set correctly.
SSH_AGENT_ENV="$HOME/.ssh/ssh-agent.env"
SSH_AGENT_SOCK="$HOME/.ssh/ssh-agent.sock"

start_agent() {
  info "Starting ssh-agent with persistent socket..."
  ssh-agent -a "${SSH_AGENT_SOCK}" > "${SSH_AGENT_ENV}"
  chmod 600 "${SSH_AGENT_ENV}"
  # shellcheck source=/dev/null
  source "${SSH_AGENT_ENV}" > /dev/null
}

if [[ -S "${SSH_AGENT_SOCK}" ]]; then
  # Socket exists — source the env file to get SSH_AUTH_SOCK/SSH_AGENT_PID
  if [[ -f "${SSH_AGENT_ENV}" ]]; then
    source "${SSH_AGENT_ENV}" > /dev/null
  fi
  # Verify the agent is still alive
  if ! ssh-add -l &>/dev/null 2>&1; then
    info "Existing ssh-agent socket found but agent is dead — restarting..."
    rm -f "${SSH_AGENT_SOCK}" "${SSH_AGENT_ENV}"
    start_agent
  else
    info "Reusing existing ssh-agent (socket: ${SSH_AGENT_SOCK})"
  fi
else
  start_agent
fi

# Load the RKE2 deploy key if not already loaded
if ! ssh-add -l 2>/dev/null | grep -q "${SSH_KEY}"; then
  info "Loading SSH key into agent..."
  ssh-add "${SSH_KEY}"
fi

info "SSH agent keys loaded:"
ssh-add -l

# ---- Persist ssh-agent auto-start in ~/.bashrc --------------------------------
# Sources the agent env file on every new terminal session so SSH_AUTH_SOCK
# is always set — required for SSH agent forwarding (-A) to work when
# jumping from the bastion to control plane / worker nodes.
BASHRC="$HOME/.bashrc"
AGENT_BLOCK="# --- rke2 ssh-agent auto-start (added by bootstrap-rhel8.sh) ---"

if grep -qF "$AGENT_BLOCK" "$BASHRC" 2>/dev/null; then
  info "ssh-agent block already present in ~/.bashrc — skipping"
else
  info "Adding ssh-agent auto-start to ~/.bashrc..."
  cat >> "$BASHRC" << 'BASHRC_EOF'

# --- rke2 ssh-agent auto-start (added by bootstrap-rhel8.sh) ---
# Reconnects to the persistent ssh-agent socket on every new terminal session.
# The agent is started once (by bootstrap-rhel8.sh) and reused across sessions.
SSH_AGENT_ENV="$HOME/.ssh/ssh-agent.env"
SSH_AGENT_SOCK="$HOME/.ssh/ssh-agent.sock"

if [[ -S "$SSH_AGENT_SOCK" ]]; then
  # Source the env file to restore SSH_AUTH_SOCK and SSH_AGENT_PID
  [[ -f "$SSH_AGENT_ENV" ]] && source "$SSH_AGENT_ENV" > /dev/null
  # If the agent is dead, restart it
  if ! ssh-add -l &>/dev/null 2>&1; then
    rm -f "$SSH_AGENT_SOCK" "$SSH_AGENT_ENV"
    ssh-agent -a "$SSH_AGENT_SOCK" > "$SSH_AGENT_ENV"
    chmod 600 "$SSH_AGENT_ENV"
    source "$SSH_AGENT_ENV" > /dev/null
  fi
else
  # No socket at all — start fresh
  ssh-agent -a "$SSH_AGENT_SOCK" > "$SSH_AGENT_ENV"
  chmod 600 "$SSH_AGENT_ENV"
  source "$SSH_AGENT_ENV" > /dev/null
fi

# Load the RKE2 deploy key if not already in the agent
if ! ssh-add -l 2>/dev/null | grep -q "rke2_id_ed25519"; then
  ssh-add "$HOME/.ssh/rke2_id_ed25519" 2>/dev/null
fi
# --- end rke2 ssh-agent auto-start ---
BASHRC_EOF
  info "ssh-agent block added to ~/.bashrc"
  info "Run 'source ~/.bashrc' or open a new terminal to activate"
fi

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
