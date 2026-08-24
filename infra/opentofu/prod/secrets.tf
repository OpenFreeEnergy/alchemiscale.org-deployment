# Per-deployment secrets. The chart pulls these into the namespace through
# External Secrets Operator, so nothing here is ever copied into a repo file,
# a workflow secret, or a hand-edited `.env` on a host.
#
# Initial values are generated once; rotation is an out-of-band operator action
# (`aws secretsmanager put-secret-value`) and OpenTofu deliberately ignores
# subsequent changes to the value rather than reverting them.

resource "random_password" "neo4j" {
  for_each = var.deployments

  length  = 32
  special = false
}

resource "random_password" "jwt" {
  for_each = var.deployments

  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "neo4j" {
  for_each = var.deployments

  name                    = "alchemiscale/${each.key}/neo4j"
  description             = "neo4j credentials for the ${each.key} alchemiscale deployment"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret_version" "neo4j" {
  for_each = var.deployments

  secret_id = aws_secretsmanager_secret.neo4j[each.key].id
  secret_string = jsonencode({
    # neo4j community edition only supports the `neo4j` user
    NEO4J_USER = "neo4j"
    NEO4J_PASS = random_password.neo4j[each.key].result
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret" "jwt" {
  for_each = var.deployments

  name                    = "alchemiscale/${each.key}/jwt"
  description             = "API token signing key for the ${each.key} alchemiscale deployment"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret_version" "jwt" {
  for_each = var.deployments

  secret_id = aws_secretsmanager_secret.jwt[each.key].id
  secret_string = jsonencode({
    JWT_SECRET_KEY = random_password.jwt[each.key].result
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
