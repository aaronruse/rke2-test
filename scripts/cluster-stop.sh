#!/bin/bash
# ============================================================
# cluster-stop.sh
# Stops the RKE2 cluster cleanly, handling spot and on-demand
# instances differently:
#
#   Control plane (on-demand) — ASG processes suspended, then
#     instance stopped. EBS volume and etcd data are preserved.
#     On start, the same instance resumes exactly where it left off.
#
#   Workers (spot) — spot requests cancelled and instances
#     terminated directly. One-time spot instances cannot be
#     stopped via the ASG or EC2 stop API — they must be
#     cancelled at the spot request level first, then terminated.
#     Workers are stateless and will rejoin on start using the
#     token stored in SSM by the rancherfederal module.
#
#   Bastion (on-demand) — stopped directly.
#
# State is saved to both ~/.rke2-cluster-state/ (local) and
# s3://<tfstate-bucket>/cluster-state/ so that collaborators
# can start the cluster from any machine with AWS access.
#
# Dependencies: aws CLI (no jq required — state is written via heredoc)
#
# Usage:
#   bash scripts/cluster-stop.sh
# ============================================================

set -euo pipefail

CLUSTER_NAME="rke2-prod"
REGION="us-west-2"
STATE_DIR="$HOME/.rke2-cluster-state"
TFSTATE_BUCKET="rke2-prod-tfstate-641275310402"
S3_STATE_PREFIX="s3://${TFSTATE_BUCKET}/cluster-state"

# ============================================================
# Dependency check
# ============================================================
if ! command -v aws &>/dev/null; then
  echo ""
  echo "ERROR: aws CLI is not installed but is required by this script."
  echo ""
  echo "  Install it by running the bootstrap script:"
  echo "    bash scripts/bootstrap-rhel8.sh"
  echo ""
  exit 1
fi

mkdir -p "$STATE_DIR"

# ---- Helper: save a state file locally and to S3 ----
save_state() {
  local filename="$1"
  local content="$2"
  echo "$content" > "$STATE_DIR/$filename"
  aws s3 cp "$STATE_DIR/$filename" "${S3_STATE_PREFIX}/${filename}" \
    --region "$REGION" > /dev/null
}

echo "==> Stopping cluster: $CLUSTER_NAME"

# ---- Find all ASGs ----
ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups \
  --region "$REGION" \
  --query "AutoScalingGroups[?contains(Tags[?Key=='Project'].Value, '${CLUSTER_NAME}')].AutoScalingGroupName" \
  --output text)

if [ -z "$ASG_NAMES" ]; then
  echo "==> No ASGs found for cluster: $CLUSTER_NAME"
  exit 1
fi

echo "==> Found ASGs:"
for ASG in $ASG_NAMES; do
  echo "      $ASG"
done

# ---- Identify control plane vs worker ASGs ----
CP_ASG=""
WORKER_ASG=""

for ASG in $ASG_NAMES; do
  if echo "$ASG" | grep -q "worker\|agent"; then
    WORKER_ASG="$ASG"
  else
    CP_ASG="$ASG"
  fi
done

echo ""
echo "==> Control plane ASG : $CP_ASG"
echo "==> Worker ASG        : $WORKER_ASG"

# ============================================================
# WORKERS — cancel spot requests + terminate instances directly
# ============================================================
echo ""
echo "==> [Workers] Reading current ASG sizes..."

WORKER_DESIRED=$(aws autoscaling describe-auto-scaling-groups \
  --region "$REGION" \
  --auto-scaling-group-names "$WORKER_ASG" \
  --query "AutoScalingGroups[0].DesiredCapacity" \
  --output text)

WORKER_MIN=$(aws autoscaling describe-auto-scaling-groups \
  --region "$REGION" \
  --auto-scaling-group-names "$WORKER_ASG" \
  --query "AutoScalingGroups[0].MinSize" \
  --output text)

WORKER_MAX=$(aws autoscaling describe-auto-scaling-groups \
  --region "$REGION" \
  --auto-scaling-group-names "$WORKER_ASG" \
  --query "AutoScalingGroups[0].MaxSize" \
  --output text)

# Only save state if the ASG is actually running — never overwrite good
# state with zeros. If desired is already 0 the cluster was previously
# stopped and state should already be saved from that run.
if [ "$WORKER_DESIRED" -gt 0 ]; then
  echo "==> [Workers] Saving ASG state (min=$WORKER_MIN max=$WORKER_MAX desired=$WORKER_DESIRED)..."

  cat > "$STATE_DIR/worker-asg-state.json" <<EOF
{
  "asg_name": "$WORKER_ASG",
  "min": $WORKER_MIN,
  "max": $WORKER_MAX,
  "desired": $WORKER_DESIRED
}
EOF

  aws s3 cp "$STATE_DIR/worker-asg-state.json" \
    "${S3_STATE_PREFIX}/worker-asg-state.json" \
    --region "$REGION" > /dev/null

  echo "      Saved locally and to S3."
else
  echo "==> [Workers] ASG desired is already 0 — skipping state save to preserve previous values."
  echo "      Existing saved state will be used by cluster-start.sh."
fi

# Ensure all ASG processes are resumed so the ASG can act
echo "==> [Workers] Ensuring all ASG processes are resumed..."
aws autoscaling resume-processes \
  --region "$REGION" \
  --auto-scaling-group-name "$WORKER_ASG" \
  --scaling-processes HealthCheck Launch Terminate ReplaceUnhealthy AZRebalance AlarmNotification ScheduledActions

# Scale ASG to 0 first so it won't launch replacements
echo "==> [Workers] Scaling ASG to 0..."
aws autoscaling update-auto-scaling-group \
  --region "$REGION" \
  --auto-scaling-group-name "$WORKER_ASG" \
  --min-size 0 \
  --max-size 0 \
  --desired-capacity 0

# Cancel spot requests directly
echo "==> [Workers] Cancelling spot instance requests..."
SPOT_REQUEST_IDS=$(aws ec2 describe-spot-instance-requests \
  --region "$REGION" \
  --filters \
    "Name=state,Values=active,open" \
    "Name=tag:aws:autoscaling:groupName,Values=${WORKER_ASG}" \
  --query "SpotInstanceRequests[].SpotInstanceRequestId" \
  --output text)

if [ -n "$SPOT_REQUEST_IDS" ]; then
  echo "      Cancelling spot requests: $SPOT_REQUEST_IDS"
  aws ec2 cancel-spot-instance-requests \
    --region "$REGION" \
    --spot-instance-request-ids $SPOT_REQUEST_IDS > /dev/null
  echo "      Spot requests cancelled."
else
  echo "      No active spot requests found."
fi

# Terminate worker instances directly
echo "==> [Workers] Terminating worker instances..."
WORKER_INSTANCE_IDS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:aws:autoscaling:groupName,Values=${WORKER_ASG}" \
    "Name=instance-state-name,Values=running,pending" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [ -n "$WORKER_INSTANCE_IDS" ]; then
  echo "      Terminating instances: $WORKER_INSTANCE_IDS"
  aws ec2 terminate-instances \
    --region "$REGION" \
    --instance-ids $WORKER_INSTANCE_IDS > /dev/null

  echo "      Waiting for worker instances to terminate..."
  aws ec2 wait instance-terminated \
    --region "$REGION" \
    --instance-ids $WORKER_INSTANCE_IDS

  echo "      Worker instances terminated."
else
  echo "      No running worker instances found."
fi

# ============================================================
# CONTROL PLANE — suspend ASG + stop instance
# ============================================================
echo ""
echo "==> [Control Plane] Suspending ASG processes to prevent instance replacement..."

aws autoscaling suspend-processes \
  --region "$REGION" \
  --auto-scaling-group-name "$CP_ASG" \
  --scaling-processes HealthCheck Launch Terminate ReplaceUnhealthy AZRebalance

echo "      ASG processes suspended."

CP_INSTANCE=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:aws:autoscaling:groupName,Values=${CP_ASG}" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [ -z "$CP_INSTANCE" ]; then
  echo "      No running control plane instance found — skipping stop."
else
  echo "==> [Control Plane] Stopping instance: $CP_INSTANCE"

  save_state "cp-instance-id.txt" "$CP_INSTANCE"
  save_state "cp-asg-name.txt" "$CP_ASG"

  aws ec2 stop-instances \
    --region "$REGION" \
    --instance-ids "$CP_INSTANCE" > /dev/null

  echo "      Waiting for instance to stop..."
  aws ec2 wait instance-stopped \
    --region "$REGION" \
    --instance-ids "$CP_INSTANCE"

  echo "      Control plane stopped. EBS and etcd data preserved."
fi

# ============================================================
# BASTION — stop directly
# ============================================================
echo ""
echo "==> [Bastion] Stopping bastion instance..."

BASTION_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:Project,Values=${CLUSTER_NAME}" \
    "Name=tag:Name,Values=*bastion*" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [ -n "$BASTION_ID" ]; then
  echo "      Stopping bastion: $BASTION_ID"
  save_state "bastion-instance-id.txt" "$BASTION_ID"
  aws ec2 stop-instances --region "$REGION" --instance-ids "$BASTION_ID" > /dev/null
  aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$BASTION_ID"
  echo "      Bastion stopped."
else
  echo "      No running bastion found — skipping."
fi

echo ""
echo "==> Cluster stopped successfully."
echo "    Control plane EBS/etcd data is preserved."
echo "    Workers terminated cleanly (stateless — this is fine)."
echo "    State files saved to: ${S3_STATE_PREFIX}/"
echo ""
echo "    To restart the cluster run:"
echo "      bash scripts/cluster-start.sh"
