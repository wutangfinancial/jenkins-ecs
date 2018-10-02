resource "aws_security_group" "jenkins_8080" {
  name        = "jenkins8080"
  description = "Allow jenkins 8080"

  ingress {
    from_port   = 0
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "jenkins8080"
  }
}

resource "aws_iam_role" "ecs_role" {

  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:CreateTags"
            ],
            "Resource": [
                "arn:aws:ec2:*:*:instance/*"
            ],
            "Condition": {
                "ForAllValues:StringEquals": {
                    "aws:TagKeys": [
                        "aws:ec2sri:scheduledInstanceId"
                    ]
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:TerminateInstances"
            ],
            "Resource": "*",
            "Condition": {
                "StringLike": {
                    "ec2:ResourceTag/aws:ec2sri:scheduledInstanceId": "*"
                }
            }
        }
    ]
}
EOF
}

resource "aws_iam_role_policy" "ecs_policy" {
  role = "${aws_iam_role.ecs_role.id}"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:AttachNetworkInterface",
                "ec2:CreateNetworkInterface",
                "ec2:CreateNetworkInterfacePermission",
                "ec2:DeleteNetworkInterface",
                "ec2:DeleteNetworkInterfacePermission",
                "ec2:Describe*",
                "ec2:DetachNetworkInterface",
                "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
                "elasticloadbalancing:DeregisterTargets",
                "elasticloadbalancing:Describe*",
                "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
                "elasticloadbalancing:RegisterTargets",
                "route53:ChangeResourceRecordSets",
                "route53:CreateHealthCheck",
                "route53:DeleteHealthCheck",
                "route53:Get*",
                "route53:List*",
                "route53:UpdateHealthCheck",
                "servicediscovery:DeregisterInstance",
                "servicediscovery:Get*",
                "servicediscovery:List*",
                "servicediscovery:RegisterInstance",
                "servicediscovery:UpdateInstanceCustomHealthStatus"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}

resource "aws_vpc" "jenkins_vpc" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "dedicated"

  tags {
    Name = "jenkins"
  }
}

resource "aws_subnet" "jenkins_subnet" {
  vpc_id     = "${aws_vpc.jenkins_vpc.id}"
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags {
    Name = "jenkins"
  }
}

resource "aws_s3_bucket" "lb_logs" {
  bucket = "my-lb-log-bucket"
  acl    = "private"

  tags {
    Name        = "lb logs"
  }
}

resource "aws_lb" "jenkins_lb" {
  name               = "jenkins-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["${aws_security_group.jenkins_8080.id}"]
  subnets            = ["${aws_subnet.jenkins_subnet.*.id}"]

  enable_deletion_protection = true

  access_logs {
    bucket  = "${aws_s3_bucket.lb_logs.bucket}"
    prefix  = "jenkins-lb"
    enabled = true
  }
}

resource "aws_lb_target_group" "jenkins_lb_tg" {
  name     = "jenkins-lb-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = "${aws_vpc.jenkins_vpc.id}"
}

resource "aws_lb_listener" "jenkins_lb_listener" {
  load_balancer_arn = "${aws_lb.jenkins_lb.arn}"
  port              = "8080"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.jenkins_lb_tg.arn}"
  }
}

resource "aws_ecs_cluster" "jenkins_cluster" {
  name = "jenkins"
}

resource "aws_ecs_task_definition" "jenkins" {
  family                = "jenkins"
  container_definitions = "${file("task-definitions/jenkins.json")}"
  requires_compatibilities = ["FARGATE"]

  volume {
    name = "jenkins-storage"
    docker_volume_configuration {
        scope         = "shared"
        autoprovision = true
    }
  }
}

resource "aws_ecs_service" "jenkins" {
  name            = "jenkins"
  cluster         = "${aws_ecs_cluster.jenkins_cluster.id}"
  task_definition = "${aws_ecs_task_definition.jenkins.arn}"
  desired_count   = 1
  iam_role        = "${aws_iam_role.ecs_role.arn}"
  depends_on      = ["aws_iam_role_policy.ecs_policy"]

  ordered_placement_strategy {
    type  = "binpack"
    field = "cpu"
  }

  load_balancer {
    target_group_arn = "${aws_lb_target_group.jenkins_lb_tg.arn}"
    container_name   = "jenkins"
    container_port   = 8080
  }

  placement_constraints {
    type       = "memberOf"
    expression = "attribute:ecs.availability-zone in [us-east-1a]"
  }
}
