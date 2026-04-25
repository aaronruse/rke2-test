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
#   Workers (spot) — spot requests cancelled, instances terminated,
#     and the worker ASG deleted entirely. Deleting the ASG means
#     terraform destroy will not hang waiting for it to drain.
#     The ASG definition remains in Terraform state so that
#     cluster-start.sh can recreate it cleanly via terraform apply.
#
#   Bastion (on-demand) — stopped directly.
#
# State is saved to both ~/.rke2-cluster-state/ (local) and
# s3://<tfstate-bucket>/cluster-state/ so that collaborators
# can start the cluster from any machine with AWS access.
#
# ⚠️  IMPORTANT: Always run cluster-start.sh before terraform destroy.
#     The CP ASG processes are suspended by this script. If you run
#     terraform destroy without starting first it will hang.
#
# Dependencies: aws CLI (no jq required)
#
# Usage (run from scripts/ directory):
#   bash cluster-stop.sh
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
  echo "    bash bootstrap-rhel8.sh"
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
# WORKERS — cancel spot requests, terminate instances, delete ASG
# The ASG is deleted entirely so terraform destroy does not hang
# waiting for it to drain. The ASG definition remains in Terraform
# state so cluster-start.sh can recreate it via terraform apply.
# ============================================================
echo ""

# Save worker ASG config before deleting it so start knows what to recreate
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
fi

# Ensure all ASG processes are resumed so the ASG can act
echo "==> [Workers] Ensuring all ASG processes are resumed..."
aws autoscaling resume-processes \
  --region "$REGION" \
  --auto-scaling-group-name "$WORKER_ASG" \
  --scaling-processes HealthCheck Launch Terminate ReplaceUnhealthy AZRebalance AlarmNotification ScheduledActions

# Scale to 0 first so the ASG won't launch replacements during deletion
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

# Delete the worker ASG entirely
echo "==> [Workers] Deleting worker ASG..."
aws autoscaling delete-auto-scaling-group \
  --region "$REGION" \
  --auto-scaling-group-name "$WORKER_ASG" \
  --force-delete

echo "      Worker ASG deleted. Terraform state still holds the definition"
echo "      so cluster-start.sh can recreate it via terraform apply."

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
echo "    Worker ASG deleted — will be recreated by cluster-start.sh."
echo "    State files saved to: ${S3_STATE_PREFIX}/"
echo ""
echo "    To restart the cluster run (from scripts/ directory):"
echo "      bash cluster-start.sh"
echo ""
echo "    ⚠️  To destroy the cluster, start it first then destroy:"
echo "      bash cluster-start.sh"
echo "      cd ../environments/prod && terraform destroy"
