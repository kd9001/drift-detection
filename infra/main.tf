provider "aws" {
  region = "us-east-1"
}

terraform {
  backend "s3" {
    bucket = "drift-detection-tfstate-deepak"
    key    = "drift-demo/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_security_group" "demo_sg" {
  name        = "drift-demo-sg"
  description = "Monitored SG for drift detection demo"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "drift-demo-sg"
    ManagedBy = "terraform"
  }
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/drift-detection"
  retention_in_days = 7
}

resource "aws_iam_role" "cloudtrail_cw_role" {
  name = "cloudtrail-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "cloudtrail_cw_policy" {
  name = "cloudtrail-cloudwatch-policy"
  role = aws_iam_role.cloudtrail_cw_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
      }
    ]
  })
}

resource "aws_cloudtrail" "main" {
  name                          = "drift-detection-trail"
  s3_bucket_name                = "drift-detection-cloudtrail-deepak"
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_cw_role.arn
}


resource "aws_s3_bucket_policy" "cloudtrail_bucket_policy" {
  bucket = "drift-detection-cloudtrail-deepak"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = "arn:aws:s3:::drift-detection-cloudtrail-deepak"
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::drift-detection-cloudtrail-deepak/AWSLogs/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_metric_filter" "sg_changes" {
  name           = "sg-manual-changes"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  pattern = "{ ($.eventName = AuthorizeSecurityGroupIngress) || ($.eventName = RevokeSecurityGroupIngress) || ($.eventName = AuthorizeSecurityGroupEgress) || ($.eventName = RevokeSecurityGroupEgress) }"

  metric_transformation {
    name      = "SGManualChangeCount"
    namespace = "DriftDetection"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "sg_drift_alarm" {
  alarm_name          = "ec2-sg-manual-change-detected"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "SGManualChangeCount"
  namespace           = "DriftDetection"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Triggered when someone manually changes SG via console"
  alarm_actions       = [aws_sns_topic.alarm_trigger.arn]
}

resource "aws_lambda_function" "drift_trigger" {
  function_name    = "drift-detection-trigger"
  filename         = "../lambda/trigger_codebuild.zip"
  source_code_hash = filebase64sha256("../lambda/trigger_codebuild.zip")
  handler          = "trigger_codebuild.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda_role.arn
  timeout          = 30

  environment {
    variables = {
      CODEBUILD_PROJECT_NAME = "terraform-drift-check"
    }
  }
}

resource "aws_sns_topic" "alarm_trigger" {
  name = "drift-alarm-trigger"
}

resource "aws_sns_topic_subscription" "lambda_trigger" {
  topic_arn = aws_sns_topic.alarm_trigger.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.drift_trigger.arn
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.drift_trigger.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alarm_trigger.arn
}


resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "AllowCloudWatchAlarm"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.drift_trigger.function_name
  principal     = "cloudwatch.amazonaws.com"
  source_arn    = aws_cloudwatch_metric_alarm.sg_drift_alarm.arn
}

resource "aws_iam_role" "lambda_role" {
  name = "drift-detection-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "drift-detection-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}


resource "aws_codebuild_project" "drift_check" {
  name          = "terraform-drift-check"
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 10

  source {
    type            = "GITHUB"
    location        = "https://github.com/kd9001/drift-detection"
    buildspec       = "codebuild/buildspec.yml"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "SNS_TOPIC_ARN"
      value = aws_sns_topic.drift_alerts.arn
    }
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }
}

resource "aws_iam_role" "codebuild_role" {
  name = "drift-detection-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "codebuild_policy" {
  name = "drift-detection-codebuild-policy"
  role = aws_iam_role.codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:GetBucketPolicy",
          "s3:GetBucketAcl",
          "s3:GetBucketLocation",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSecurityGroupRules",
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "sns:Publish",
          "sns:GetTopicAttributes",
          "sns:ListTagsForResource",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:ListTagsForResource",
          "logs:ListTagsLogGroup",
          "iam:GetRole",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:GetRolePolicy",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:GetMetricData",
          "cloudtrail:GetTrail",
          "cloudtrail:GetTrailStatus",
          "cloudtrail:ListTags",
          "lambda:GetFunction",
          "lambda:GetPolicy",
          "lambda:ListAliases",
          "lambda:ListVersionsByFunction"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_sns_topic" "drift_alerts" {
  name = "terraform-drift-alerts"
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.drift_alerts.arn
  protocol  = "email"
  endpoint  = "iamfearlessalways@gmail.com"
}

resource "aws_iam_role_policy_attachment" "codebuild_readonly" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "codebuild_sns" {
  name = "codebuild-sns-publish"
  role = aws_iam_role.codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "sns:Publish",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}