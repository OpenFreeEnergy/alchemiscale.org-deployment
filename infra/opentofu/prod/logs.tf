# Container logs for the production cluster, shipped here by Fluent Bit.
#
# The test cluster's group is not here: it belongs to the identity layer, so
# neither the reaper nor a prod apply can take it away.

resource "aws_cloudwatch_log_group" "prod" {
  name              = var.log_group_name
  retention_in_days = var.log_retention_days

  lifecycle {
    prevent_destroy = true
  }
}
