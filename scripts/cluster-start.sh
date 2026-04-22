#!/bin/bash
# ============================================================
# cluster-start.sh
# Starts the RKE2 cluster, handling spot and on-demand
# instances differently:
#
#   Control plane (on-demand) — starts the stopped instance
#     and resumes ASG processes. etcd and cluster state are
#     fully intact from before the stop.
#
#   Workers (spot) — restores ASG to previous desired capacity.
#     Fresh spot instances launch and automatically rejoin the
#     cluster using the token in SSM Parameter Store.
#
#   Bastion (on-demand) — started directly.
#
#   Ghost node cleanup — after new workers have joined, any
#     NotReady nodes left over from the previous run are
#     removed from the Kubernetes API server.
#
# Reads state saved by cluster-stop.sh from ~/.rke2-cluster-state/
#
# Usage:
#   bash scripts/cluster-start.sh
#
# Allow 5-10 minutes after running for RKE2 to fully come
# back up before running kubectl commands.
# ============================================================

set -euo pipefail

CLUSTER_NAME="rke2-prod"
REGION="us-west-2"
STATE_DIR="$HOME/.rke2-cluster-state"
TFSTATE_BUCKET="rke2-prod-tfstate-641275310402"
KUBECONFIG_PATH="$HOME/.kube/config"

# How long to wait for workers to join before cleaning up ghost nodes.
# Increase this if your CIS hardened AMI takes longer to bootstrap.
WORKER_JOIN_WAIT_SECONDS=300

# ============================================================
# Dependency check — jq is required to parse saved ASG state.
# It is installed by scripts/bootstrap-rhel8.sh. If it is
# missing, install it before running this script:
#   sudo dnf install -y jq
# ============================================================
if ! command -v jq &>/dev/null; then
  echo ""
  echo "ERROR: jq is not installed but is required by this script."
  echo ""
  echo "  jq is used to parse the saved worker ASG state from:"
  echo "    $STATE_DIR/worker-asg-state.json"
  echo ""
  echo "  Install it with:"
  echo "    sudo dnf install -y jq"
  echo ""
  echo "  Or re-run the bootstrap script which installs it automatically:"
  echo "    bash scripts/bootstrap-rhel8.sh"
  echo ""
  exit 1
fi

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
  echo "      ERROR: No saved control plane instance ID found at $STATE_DIR/cp-instance-id.txt"
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
# WORKERS — restore ASG to previous desired capacity
# Fresh spot instances will launch and rejoin the cluster
# automatically using the token in SSM Parameter Store.
# ============================================================
echo ""
echo "==> [Workers] Restoring worker ASG..."

if [ -f "$STATE_DIR/worker-asg-state.json" ]; then
  WORKER_ASG=$(jq -r '.asg_name' "$STATE_DIR/worker-asg-state.json")
  WORKER_MIN=$(jq -r '.min' "$STATE_DIR/worker-asg-state.json")
  WORKER_MAX=$(jq -r '.max' "$STATE_DIR/worker-asg-state.json")
  WORKER_DESIRED=$(jq -r '.desired' "$STATE_DIR/worker-asg-state.json")
else
  echo "      No saved worker state found — using defaults (min=4 max=6 desired=4)"
  WORKER_ASG=$(aws autoscaling describe-auto-scaling-groups \
    --region "$REGION" \
    --query "AutoScalingGroups[?contains(Tags[?Key=='Project'].Value, '${CLUSTER_NAME}') && contains(AutoScalingGroupName, 'worker')].AutoScalingGroupName" \
    --output text)
  WORKER_MIN=4
  WORKER_MAX=6
  WORKER_DESIRED=4
fi

echo "      Restoring $WORKER_ASG -> min=$WORKER_MIN max=$WORKER_MAX desired=$WORKER_DESIRED"

aws autoscaling update-auto-scaling-group \
  --region "$REGION" \
  --auto-scaling-group-name "$WORKER_ASG" \
  --min-size "$WORKER_MIN" \
  --max-size "$WORKER_MAX" \
  --desired-capacity "$WORKER_DESIRED"

echo "      Worker ASG restored. Spot instances launching and will rejoin cluster."

# ============================================================
# KUBECONFIG — fetch from S3 so we can run kubectl
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
# GHOST NODE CLEANUP — remove NotReady nodes from previous run
# ============================================================
echo ""
echo "==> [Cleanup] Removing NotReady ghost nodes from previous run..."

GHOST_NODES=$(kubectl get nodes --no-headers 2>/dev/null | \
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

# ============================================================
# Final status
# ============================================================
echo ""
echo "==> Cluster is up. Current node status:"
echo ""
kubectl get nodes
echo ""
echo "==> Done. Kubeconfig is at $KUBECONFIG_PATH"
