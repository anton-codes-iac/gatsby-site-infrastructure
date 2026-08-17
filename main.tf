terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.72.0"
    }
  }

  backend "s3" {
    bucket = "gatsby-site-tf-state"    # YOUR unique bucket name
    key    = "stage/terraform.tfstate" # The name of the file inside S3
    region = "us-east-2"
  }
}

provider "aws" {
  region = "us-east-2"
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

locals {
  public_subnets = {
    "us-east-2a" = "10.0.1.0/24"
    "us-east-2b" = "10.0.3.0/24"
  }

  private_subnets = {
    "us-east-2a" = "10.0.2.0/24"
    "us-east-2b" = "10.0.4.0/24"
  }
}

resource "aws_subnet" "public_subnet" {
  for_each = local.public_subnets

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value

  # This line makes it publicly accessible
  map_public_ip_on_launch = true
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public_rta" {
  for_each = aws_subnet.public_subnet

  route_table_id = aws_route_table.public_rt.id
  subnet_id      = each.value.id
}

resource "aws_lb" "web_lb" {
  name               = "gatsby-site-web-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [for subnet in aws_subnet.public_subnet : subnet.id]
}

resource "aws_lb_target_group" "web_tg" {
  name        = "gatsby-site-web-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "web_listener" {
  load_balancer_arn = aws_lb.web_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

/*
resource "aws_lb_listener" "web_listener_443" {
  load_balancer_arn = aws_lb.web_lb.arn
  port              = "443"
  protocol          = "HTTPS"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
} */

resource "aws_ecs_cluster" "web_cluster" {
  name = "gatsby-site-web-cluster"
}

resource "aws_ecr_repository" "web_repo" {
  name = "gatsby-site-web"
}

resource "aws_ecs_task_definition" "web_task_def" {
  family                   = "gatsby-site-web-task-def"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"

  execution_role_arn = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name  = "gatsby-site-web"
      image = "${aws_ecr_repository.web_repo.repository_url}:latest"
      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs_web.name
          "awslogs-region"        = "us-east-2"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "web_service" {
  name            = "gatsby-site-web-service"
  cluster         = aws_ecs_cluster.web_cluster.id
  task_definition = aws_ecs_task_definition.web_task_def.arn

  # The Sleep Switch: If true = 1 container. If false = 0 containers.
  desired_count = var.environment_active ? 1 : 0

  launch_type = "FARGATE"

  network_configuration {
    security_groups  = [aws_security_group.ecs_sg.id]
    subnets          = [for subnet in aws_subnet.public_subnet : subnet.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.web_tg.arn
    container_name   = "gatsby-site-web"
    container_port   = 80
  }
}

resource "aws_iam_role" "ecs_task_role" {
  name = "gatsby-site-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_policy_attachment" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_openid_connect_provider" "github" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["1b511abead59c6ce207077c0bf0e0043b1382612", "6938fd4d98bab03faadb97b34396831e3780aea1"]
  url             = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_actions_role" {
  name = "gatsby-site-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:sub" = var.github_oidc_subject,
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "github_actions_policy" {
  name = "gatsby-site-github-actions-policy"

  role = aws_iam_role.github_actions_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:PutImage",
        ]
        Resource = aws_ecr_repository.web_repo.arn
      },
      {
        Effect   = "Allow"
        Action   = "ecs:UpdateService"
        Resource = aws_ecs_service.web_service.arn
      }
    ]
  })
}

resource "aws_security_group" "alb_sg" {
  name        = "gatsby-site-alb-sg"
  description = "Allow HTTP inbound traffic to ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow ALB HTTP traffic"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow ALB outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_sg" {
  name        = "gatsby-site-ecs-sg"
  description = "Allow HTTP inbound traffic from the ALB to ECS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Allow ALB HTTP traffic"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    description = "Allow ALB outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

output "alb_dns_name" {
  description = "The public URL of your Application Load Balancer"
  value       = "http://${aws_lb.web_lb.dns_name}"
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = "gatsby-site-tf-state"

  lifecycle {
    prevent_destroy = true # Protects the bucket from accidental deletion
  }
}

resource "aws_s3_bucket_versioning" "enabled" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_cloudwatch_log_group" "ecs_web" {
  name              = "/aws/ecs/gatsby-site-web"
  retention_in_days = 14
}

output "rolearn" {
  value = aws_iam_role.github_actions_role.arn
}
