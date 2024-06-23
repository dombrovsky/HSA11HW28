provider "aws" {
  region = "us-west-1"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "main-vpc"
  }
}

resource "aws_subnet" "subnet1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-west-1a"

  tags = {
    Name = "subnet1"
  }
}

resource "aws_subnet" "subnet2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-west-1b"

  tags = {
    Name = "subnet2"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main-igw"
  }
}

resource "aws_security_group" "allow_ssh_http" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_ssh_http"
  }
}

resource "aws_launch_template" "app" {
  name_prefix   = "app-launch-template-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = true
    subnet_id                   = aws_subnet.subnet1.id
  }

  user_data = base64encode(file("userdata.sh"))

  instance_market_options {
    market_type = "spot"
    spot_options {
      max_price = "0.03"
      instance_interruption_behavior = "terminate"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app" {
  desired_capacity     = 1
  max_size             = 10
  min_size             = 1
  vpc_zone_identifier  = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]
  target_group_arns         = ["${aws_lb_target_group.app_tg.arn}"]

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.app.id
        version            = "$Latest"
      }

      override {
        instance_type      = "t2.micro"
        weighted_capacity  = 1
      }

      override {
        instance_type      = "t2.small"
        weighted_capacity  = 2
      }
    }

    instances_distribution {
      on_demand_base_capacity                 = 1
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                = "lowest-price"
    }
  }

  tag {
    key                 = "Name"
    value               = "app-instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_policy" "scale_up_cpu" {
  name                   = "scale-up-cpu"
  adjustment_type        = "ChangeInCapacity"
  autoscaling_group_name = aws_autoscaling_group.app.name

  policy_type            = "SimpleScaling"
  scaling_adjustment     = 1
}

resource "aws_cloudwatch_metric_alarm" "request_count_high" {
  alarm_name          = "request-count-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "RequestCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 1000
  alarm_actions       = [aws_autoscaling_policy.scale_up_requests.arn]
  dimensions = {
    LoadBalancer = aws_lb.app_lb.arn
  }
}

resource "aws_autoscaling_policy" "scale_up_requests" {
  name                   = "scale-up-requests"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300  # Optional: Only applicable for SimpleScaling policies
  autoscaling_group_name = aws_autoscaling_group.app.name
}

resource "aws_lb" "app_lb" {
  name               = "app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_ssh_http.id]
  subnets            = [aws_subnet.subnet1.id, aws_subnet.subnet2.id]

  enable_deletion_protection = false

  tags = {
    Name = "app-lb"
  }
}

resource "aws_lb_target_group" "app_tg" {
  name     = "app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/"
    matcher             = "200"
  }

  tags = {
    Name = "app-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

output "load_balancer_dns_name" {
  value = aws_lb.app_lb.dns_name
}
