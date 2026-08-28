# Container log group.
#
# The production group is the same `alchemiscale` group the EC2 hosts write to
# through the compose `awslogs` driver, so pre- and post-migration logs stay
# side by side. It almost certainly already exists — import it rather than
# letting the first apply fail:
#
#   tofu import aws_cloudwatch_log_group.prod alchemiscale
#
# The test cluster's group is not here: it belongs to the identity layer, which
# neither the reaper nor a prod apply can touch.

resource "aws_cloudwatch_log_group" "prod" {
  name              = var.log_group_name
  retention_in_days = var.log_retention_days

  lifecycle {
    prevent_destroy = true
  }
}
