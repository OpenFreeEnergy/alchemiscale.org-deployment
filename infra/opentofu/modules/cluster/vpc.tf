data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /20 private subnets (4091 usable each — room for pod ENIs), /24 public
  # subnets (they carry nothing but NAT gateways and ALBs)
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 240)]

  # tag consumed by the NodeClass subnet/security-group selectors below
  discovery_tags = { "karpenter.sh/discovery" = var.cluster_name }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # a single NAT gateway is a deliberate cost/HA trade-off: losing its AZ costs
  # the cluster egress (image pulls, S3, CloudWatch) until it is recreated, but
  # in-cluster traffic and the ALB keep serving. Three NATs would add ~$66/mo.
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Auto Mode places nodes in subnets matching the NodeClass selector, and ALBs
  # in subnets carrying the elb role tags
  private_subnet_tags = merge(
    local.discovery_tags,
    { "kubernetes.io/role/internal-elb" = "1" },
  )

  public_subnet_tags = var.enable_public_ingress ? { "kubernetes.io/role/elb" = "1" } : {}

  tags = var.tags
}
