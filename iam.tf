# ============================================================
# IAM: Bastion Instance Profile
# Grants the bastion all permissions needed to manage an RKE2
# cluster — EC2, ASG, S3, ELB, SSM, EKS read, CloudWatch logs.
# ============================================================

data "aws_iam_policy_document" "bastion_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  name               = "${var.cluster_name}-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume_role.json

  tags = local.tags
}

data "aws_iam_policy_document" "bastion" {

  # ---- S3: kubeconfig + RKE2 bootstrap artifacts ----
  statement {
    sid    = "S3RKE2Artifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:ListAllMyBuckets",
      "s3:GetBucketLocation",
    ]
    resources = [
      "arn:aws:s3:::${var.cluster_name}*",
      "arn:aws:s3:::${var.cluster_name}*/*",
    ]
  }

  # ---- EC2: describe and manage cluster instances ----
  statement {
    sid    = "EC2ReadWrite"
    effect = "Allow"
    actions = [
      # Read
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeTags",
      "ec2:DescribeKeyPairs",
      "ec2:DescribeImages",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeVolumes",
      "ec2:DescribeVolumeStatus",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeNatGateways",
      "ec2:DescribeRouteTables",
      "ec2:DescribeAddresses",
      # Instance management
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:RebootInstances",
      "ec2:TerminateInstances",
      # Volume management
      "ec2:AttachVolume",
      "ec2:DetachVolume",
      "ec2:CreateVolume",
      "ec2:DeleteVolume",
      "ec2:ModifyVolume",
      # Tagging
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = ["*"]
  }

  # ---- ASG: manage control plane and worker node pools ----
  statement {
    sid    = "AutoScaling"
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribePolicies",
      "autoscaling:DescribeTags",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup",
      "autoscaling:EnterStandby",
      "autoscaling:ExitStandby",
    ]
    resources = ["*"]
  }

  # ---- ELB: inspect load balancers fronting the cluster ----
  statement {
    sid    = "ELBReadOnly"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTags",
    ]
    resources = ["*"]
  }

  # ---- IAM: read-only for auditing roles and policies ----
  statement {
    sid    = "IAMReadOnly"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetInstanceProfile",
      "iam:ListRoles",
      "iam:ListInstanceProfiles",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:GetRolePolicy",
    ]
    resources = ["*"]
  }

  # ---- SSM: Session Manager shell access + parameter store ----
  # Parameter store is used by rancherfederal/rke2-aws-tf for
  # cluster join tokens and bootstrap coordination.
  statement {
    sid    = "SSMSessionAndParameters"
    effect = "Allow"
    actions = [
      "ssm:StartSession",
      "ssm:TerminateSession",
      "ssm:ResumeSession",
      "ssm:DescribeSessions",
      "ssm:GetConnectionStatus",
      "ssm:DescribeInstanceInformation",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:DescribeParameters",
    ]
    resources = ["*"]
  }

  # ---- CloudWatch: view cluster and node logs/metrics ----
  statement {
    sid    = "CloudWatchReadOnly"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
    ]
    resources = ["*"]
  }

  # ---- Route53: useful for DNS-based ingress troubleshooting ----
  statement {
    sid    = "Route53ReadOnly"
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:GetHostedZone",
      "route53:ChangeResourceRecordSets",
    ]
    resources = ["*"]
  }

  # ---- STS: allow assuming other roles if needed ----
  statement {
    sid    = "STSGetCallerIdentity"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "bastion" {
  name   = "${var.cluster_name}-bastion-policy"
  role   = aws_iam_role.bastion.id
  policy = data.aws_iam_policy_document.bastion.json
}

# SSM managed instance core — required for Session Manager to work
resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.cluster_name}-bastion-profile"
  role = aws_iam_role.bastion.name

  tags = local.tags
}
