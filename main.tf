
//
// Create an ECS Cluster
resource "aws_ecs_cluster" "self" {
  name = "task-iam-role"
}

//
// Lookup the "AMI" from rancher/os/README.md
data "aws_ami" "hvm" {
  owners = [ "605812595337" ]  # Rancher
  most_recent = true

  filter {
    name   = "image-id"
    values = ["ami-03383c16defb1ed02"]
  }
}
data "aws_ami" "amazon-ecs-optimized" {
  owners = [ "605812595337" ]  # Rancher
  most_recent = true

  filter {
    name = "image-id"
    values = ["ami-047c2cc8ce83362d5"]
  }
}

//
// Create a Private Key for Rancher
resource "tls_private_key" "self" {
  algorithm = "RSA"
  rsa_bits = 3072
}
resource "local_file" "foo" {
  content = "${tls_private_key.self.private_key_pem}"
  filename = "${path.module}/id_rsa"
  file_permission = "600"
}
resource "aws_key_pair" "self" {
  key_name = "task-iam-role"
  public_key = "${tls_private_key.self.public_key_openssh}"
}

//
// Create the EC2 InstanceRole for ECS
// ref: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/instance_IAM_role.html
data "aws_iam_policy" "self" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}
data "aws_iam_policy_document" "self" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "self" {
  name = "ecs-client-role"
  assume_role_policy = "${data.aws_iam_policy_document.self.json}"
}
resource "aws_iam_role_policy_attachment" "self" {
  role       = "${aws_iam_role.self.name}"
  policy_arn = "${data.aws_iam_policy.self.arn}"
}
resource "aws_iam_instance_profile" "self" {
  name = "ecs-client-profile"
  role = "${aws_iam_role.self.name}"
}

//
// Spin up an EC2 instance with the AMI
resource "aws_instance" "self" {
  ami = "${data.aws_ami.hvm.id}"
  instance_type = "t2.micro"
  iam_instance_profile = "${aws_iam_instance_profile.self.name}"

  key_name = "${aws_key_pair.self.id}"
  user_data = <<YAML
#cloud-config

# Steps from https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-agent-install.html
rancher:
  # Step 5
  sysctl:
    net.ipv4.conf.all.route_localnet: 1

  network:
    post_cmds:
      # Step 6 and 7
      - iptables -t nat -A PREROUTING -p tcp -d 169.254.170.2 --dport 80 -j DNAT --to-destination 127.0.0.1:51679
      - iptables -t nat -A OUTPUT -d 169.254.170.2 -p tcp -m tcp --dport 80 -j REDIRECT --to-ports 51679

      # And prevent docker traffic from accessing the instance metadata
      #   c.f. https://docs.aws.amazon.com/AmazonECS/latest/developerguide/instance_IAM_role.html
      - iptables --insert DOCKER-USER 1 --in-interface docker+ --destination 169.254.169.254/32 --jump DROP
      # Allow system-docker traffic to reach instance metadata
      - iptables --insert DOCKER-USER 1 --in-interface docker-sys --destination 169.254.169.254/32 --jump ACCEPT

  # Step 8 and 9
  environment:
    ECS_CLUSTER: ${aws_ecs_cluster.self.id}
    ECS_ENABLE_TASK_IAM_ROLE: true
    ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST: true

  # Step 10b applied to rancher/os-services/a/amazon-ecs-agent.yml
  services:
    ecs-agent:
      image: amazon/amazon-ecs-agent:latest
      restart: always
      volumes:
      - /var/run/:/var/run/
      - /var/log/ecs/:/log
      - /opt/var/lib/ecs/data:/data
      - /sys/fs/cgroup:/sys/fs/cgroup:ro
      - /var/run/docker/execdriver/native:/var/lib/docker/execdriver/native:ro
      net: host
      environment:
      - ECS_LOGFILE=/log/ecs-agent.log
      - ECS_LOGLEVEL=info
      - ECS_DATADIR=/data
      - ECS_HOST_DATA_DIR=/opt/var/lib/ecs
      - ECS_*
      - AWS_*
YAML

  provisioner "remote-exec" {
    connection {
      host = "${self.public_ip}"
      user = "rancher"
      private_key = "${tls_private_key.self.private_key_pem}"
    }
    inline = [
      "sudo system-docker exec network wget --spider -T 2 169.254.169.254",
      "docker run --rm busybox wget --spider -T 2 169.254.169.254 2>&1 | grep -q 'download timed out'",
      "wget http://169.254.170.2 2>&1 | grep -q '404 Not Found'"
    ]
  }
}

//
// Output Instructions on how to login
output "ssh" {
  description = "The ssh login command for the RancherOS instance"
  value = "ssh -i ${path.module}/id_rsa rancher@${aws_instance.self.public_ip}"
}

