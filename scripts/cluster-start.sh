#!/bin/bash
# ============================================================
# cluster-start.sh
# Starts the RKE2 cluster:
#
#   Bastion (on-demand) — started directly.
#
#   Control plane (on-demand) — starts the stopped instance
#     and resumes ASG processes. etcd and cluster state are
#     fully intact from before the stop.
#
#   Workers (spot) — worker ASG was deleted by cluster-stop.sh.
#     terraform apply is run to recreate it from state. Fresh
#     spot instances launch and automatically rejoin the cluster
#     using the token in SSM Parameter Store.
#
#   Ghost node cleanup — after new workers have joined, any
#     NotReady nodes left over from the previous run are
#     removed from the Kubernetes API server.
#
# Reads state saved by cluster-stop.sh from S3 and
# ~/.rke2-cluster-state/. terraform apply is run from
# environments/prod/ relative to this script's location.
#
# Dependencies: aws CLI, jq, terraform, kubectl
#
# Usage (run from scripts/ directory):
#   bash cluster-start.sh
#
# Allow 5-10 minutes after running for RKE2 to fully come
# back up before running kubectl commands.
# ============================================================

set -euo pipefail

CLUSTER_NAME="rke2-prod"
REGION="us-west-2"
STATE_DIR="$HOME/.rke2-cluster-state"
TFSTATE_BUCKET="rke2-prod-tfstate-641275310402"
S3_STATE_PREFIX="s3://${TFSTATE_BUCKET}/cluster-state"
KUBECONFIG_PATH="$HOME/.kube/config"

# Path to environments/prod/ relative to scripts/
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../environments/prod"

# How long to wait for workers to join before cleaning up ghost nodes
WORKER_JOIN_WAIT_SECONDS=300

# ============================================================
# Dependency checks
# ============================================================
MISSING=""
for cmd in jq aws terraform kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING="$MISSING $cmd"
  fi
done

if [ -n "$MISSING" ]; then
  echo ""
  echo "ERROR: The following required tools are not installed:$MISSING"
  echo ""
  echo "  Run the bootstrap script to install them:"
  echo "    bash bootstrap-rhel8.sh"
  echo ""
  exit 1
fi

# ============================================================
# Pull state files from S3
# ============================================================
echo "==> Syncing cluster state from S3..."
mkdir -p "$STATE_DIR"

for FILE in cp-instance-id.txt cp-asg-name.txt bastion-instance-id.txt worker-asg-state.json; do
  if aws s3 cp "${S3_STATE_PREFIX}/${FILE}" "$STATE_DIR/$FILE" \
      --region "$REGION" > /dev/null 2>&1; then
    echo "      Downloaded: $FILE"
  else
    if [ -f "$STATE_DIR/$FILE" ]; then
      echo "      S3 not found, using local: $FILE"
    else
      echo "      WARNING: $FILE not found in S3 or locally"
    fi
  fi
done

echo "==> Starting cluster: $CLUSTER_NAME"

# ============================================================
# BASTION — start first so we have SSH access
# ============================================================
echo ""
echo "==> [Bastion] Starting bastion instance..."

if [ -f "$STATE_DIR/bastion-instance-id.txt" ]; then
  BASTION_ID=$(cat "$STATE_DIR/bastion-instance-id.txt")
else
  BASTION_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
      "Name=tag:Project,Values=${CLUSTER_NAME}" \
      "Name=tag:Name,Values=*bastion*" \
      "Name=instance-state-name,Values=stopped" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text)
fi

if [ -n "$BASTION_ID" ]; then
  echo "      Starting bastion: $BASTION_ID"
  aws ec2 start-instances --region "$REGION" --instance-ids "$BASTION_ID" > /dev/null
  aws ec2 wait instance-running --region "$REGION" --instance-ids "$BASTION_ID"
  BASTION_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$BASTION_ID" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)
  echo "      Bastion running. Public IP: $BASTION_IP"
else
  echo "      No stopped bastion found — may already be running."
fi

# ============================================================
# CONTROL PLANE — start instance + resume ASG processes
# ============================================================
echo ""
echo "==> [Control Plane] Starting control plane instance..."

if [ -f "$STATE_DIR/cp-instance-id.txt" ]; then
  CP_INSTANCE=$(cat "$STATE_DIR/cp-instance-id.txt")
else
  echo "      ERROR: No saved control plane instance ID found."
  echo "      Was cluster-stop.sh run before this? Cannot safely start control plane."
  exit 1
fi

if [ -f "$STATE_DIR/cp-asg-name.txt" ]; then
  CP_ASG=$(cat "$STATE_DIR/cp-asg-name.txt")
else
  echo "      ERROR: No saved control plane ASG name found."
  exit 1
fi

echo "      Starting instance: $CP_INSTANCE"
aws ec2 start-instances --region "$REGION" --instance-ids "$CP_INSTANCE" > /dev/null

echo "      Waiting for instance to be running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$CP_INSTANCE"
echo "      Control plane instance running."

echo "==> [Control Plane] Resuming ASG processes..."
aws autoscaling resume-processes \
  --region "$REGION" \
  --auto-scaling-group-name "$CP_ASG" \
  --scaling-processes HealthCheck Launch Terminate ReplaceUnhealthy AZRebalance

echo "      ASG processes resumed."

# ============================================================
# WORKERS — recreate ASG via terraform apply
# The worker ASG was deleted by cluster-stop.sh. Terraform still
# has the definition in state so apply will recreate it cleanly.
# ============================================================
echo ""
echo "==> [Workers] Recreating worker ASG via terraform apply..."
echo "      Working directory: $TF_DIR"

cd "$TF_DIR"

terraform apply \
  -target=module.rke2.module.rke2_workers.module.nodepool.aws_autoscaling_group.this \
  -target=module.rke2.aws_autoscaling_attachment.workers_http \
  -target=module.rke2.aws_autoscaling_attachment.workers_https \
  -auto-approve

echo "      Worker ASG recreated. Spot instances launching and will rejoin cluster."

cd "$SCRIPT_DIR"

# ============================================================
# KUBECONFIG — fetch from S3
# ============================================================
echo ""
echo "==> [Kubeconfig] Fetching kubeconfig from S3..."

mkdir -p "$(dirname "$KUBECONFIG_PATH")"
aws s3 cp "s3://${TFSTATE_BUCKET}/kubeconfig/config" "$KUBECONFIG_PATH" \
  --region "$REGION" > /dev/null
chmod 600 "$KUBECONFIG_PATH"
export KUBECONFIG="$KUBECONFIG_PATH"

echo "      Kubeconfig saved to $KUBECONFIG_PATH"

# ============================================================
# WAIT FOR WORKERS — poll until expected number of Ready nodes
# ============================================================
WORKER_DESIRED=4
if [ -f "$STATE_DIR/worker-asg-state.json" ]; then
  WORKER_DESIRED=$(jq -r '.desired' "$STATE_DIR/worker-asg-state.json")
fi

echo ""
echo "==> [Workers] Waiting up to $((WORKER_JOIN_WAIT_SECONDS / 60)) minutes for $WORKER_DESIRED workers to join..."

DEADLINE=$((SECONDS + WORKER_JOIN_WAIT_SECONDS))
READY_COUNT=0

while [ $SECONDS -lt $DEADLINE ]; do
  READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | \
    grep -v "control-plane\|master" | \
    awk '$2=="Ready" {count++} END {print count+0}')

  echo "      Ready workers: $READY_COUNT / $WORKER_DESIRED ($(( (DEADLINE - SECONDS) / 60 ))m remaining)"

  if [ "$READY_COUNT" -ge "$WORKER_DESIRED" ]; then
    echo "      All $WORKER_DESIRED workers are Ready."
    break
  fi

  sleep 30
done

if [ "$READY_COUNT" -lt "$WORKER_DESIRED" ]; then
  echo ""
  echo "      WARNING: Only $READY_COUNT / $WORKER_DESIRED workers joined within the timeout."
  echo "      Ghost node cleanup will still run. Check worker ASG activity for errors."
fi

# ============================================================
# GHOST NODE CLEANUP
# Wait until the API server is responding before attempting
# to delete nodes — the control plane may still be warming up.
# Errors are not suppressed so failures are visible.
# ============================================================
echo ""
echo "==> [Cleanup] Waiting for API server to be ready..."

API_READY=false
for i in $(seq 1 20); do
  if kubectl get nodes --no-headers > /dev/null 2>&1; then
    API_READY=true
    break
  fi
  echo "      API server not ready yet — retrying in 15s ($i/20)..."
  sleep 15
done

if [ "$API_READY" = false ]; then
  echo "      WARNING: API server did not become ready in time."
  echo "      Run this manually once the cluster is up:"
  echo "        kubectl get nodes --no-headers | awk '\$2==\"NotReady\" {print \$1}' | xargs kubectl delete node"
else
  echo "==> [Cleanup] Removing NotReady ghost nodes from previous run..."

  GHOST_NODES=$(kubectl get nodes --no-headers | \
    awk '$2=="NotReady" {print $1}')

  if [ -n "$GHOST_NODES" ]; then
    echo "      Found ghost nodes:"
    echo "$GHOST_NODES" | while read NODE; do
      echo "        - $NODE"
    done

    echo "$GHOST_NODES" | xargs -r kubectl delete node
    echo "      Ghost nodes removed."
  else
    echo "      No NotReady nodes found — cluster is clean."
  fi
fi

# ============================================================
# Final status
# ============================================================
echo ""
echo "==> Cluster is up. Current node status:"
echo ""
kubectl get nodes
echo ""
echo "==> Done. Kubeconfig is at $KUBECONFIG_PATH"
