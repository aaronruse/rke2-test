# ============================================================
# Data Sources
# ============================================================

# Caller identity (for IAM policies, etc.)
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
