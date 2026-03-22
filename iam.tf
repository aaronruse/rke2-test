
# ============================================================
# IAM: Bastion Instance Profile
# Grants the bastion read access to the RKE2 S3 bucket
# so operators can fetch the kubeconfig after cluster bootstrap.
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

data "aws_iam_policy_document" "bastion_s3" {
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.cluster_name}*",
      "arn:aws:s3:::${var.cluster_name}*/*",
    ]
  }
}

resource "aws_iam_role_policy" "bastion_s3" {
  name   = "${var.cluster_name}-bastion-s3"
  role   = aws_iam_role.bastion.id
  policy = data.aws_iam_policy_document.bastion_s3.json
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.cluster_name}-bastion-profile"
  role = aws_iam_role.bastion.name

  tags = local.tags
}