# The hosted zone lives in this account (migrated from the legacy account along
# with the domain registration) but is not managed here — this infrastructure
# publishes records into it, it does not own its lifecycle. Records for
# instances that have not migrated yet keep pointing wherever they already
# point; DNS does not care which account a target address belongs to.
data "aws_route53_zone" "main" {
  name         = var.hosted_zone_name
  private_zone = false
}

# ---------------------------------------------------------------------------
# legacy record editor
#
# The zone moved accounts; the `root` and `asap` instances did not. This role
# lets their operators repoint their own records — and only those records —
# without an administrator in this account having to do it for them.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "legacy_dns_editor_trust" {
  count = length(var.legacy_dns_editor_account_ids) > 0 ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [for id in var.legacy_dns_editor_account_ids : "arn:${data.aws_partition.current.partition}:iam::${id}:root"]
    }
  }
}

data "aws_iam_policy_document" "legacy_dns_editor" {
  count = length(var.legacy_dns_editor_account_ids) > 0 ? 1 : 0

  statement {
    sid       = "EditLegacyRecordsOnly"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:${data.aws_partition.current.partition}:route53:::hostedzone/${data.aws_route53_zone.main.zone_id}"]

    # ForAllValues: every name in the change batch must be one of these, so a
    # batch that mixes a legacy record with anything else is refused
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = [for name in var.legacy_dns_names : lower(name)]
    }
  }

  statement {
    sid       = "ReadZone"
    effect    = "Allow"
    actions   = ["route53:ListResourceRecordSets", "route53:GetHostedZone", "route53:GetChange"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "legacy_dns_editor" {
  count = length(var.legacy_dns_editor_account_ids) > 0 ? 1 : 0

  name               = "alchemiscale-legacy-dns-editor"
  description        = "Cross-account: edit the DNS records of instances still running in the legacy account"
  assume_role_policy = data.aws_iam_policy_document.legacy_dns_editor_trust[0].json
}

resource "aws_iam_role_policy" "legacy_dns_editor" {
  count = length(var.legacy_dns_editor_account_ids) > 0 ? 1 : 0

  name   = "legacy-records"
  role   = aws_iam_role.legacy_dns_editor[0].id
  policy = data.aws_iam_policy_document.legacy_dns_editor[0].json
}

# One wildcard certificate per deployment covers api.<domain> and
# compute.<domain>. ACM renews automatically, which is why nothing below alerts
# on certificate expiry — and why Traefik + Let's Encrypt is retired.
resource "aws_acm_certificate" "deployment" {
  for_each = var.deployments

  domain_name               = "*.${each.value.domain}"
  subject_alternative_names = [each.value.domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "alchemiscale-${each.key}"
  }
}

locals {
  # One validation record per deployment. ACM issues a single CNAME covering
  # both `*.x` and `x` when they share a zone, so the two validation options a
  # certificate reports carry identical record names and values.
  #
  # Selected by `domain_name` rather than by taking the first element, because
  # `domain_validation_options` is a set and has no order. The key is the
  # deployment name — `for_each` keys must be known at plan time, and nothing
  # about a certificate that does not exist yet is.
  certificate_validation = {
    for name, dep in var.deployments : name => one([
      for dvo in aws_acm_certificate.deployment[name].domain_validation_options :
      dvo if dvo.domain_name == "*.${dep.domain}"
    ])
  }
}

resource "aws_route53_record" "certificate_validation" {
  for_each = var.deployments

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = local.certificate_validation[each.key].resource_record_name
  type            = local.certificate_validation[each.key].resource_record_type
  records         = [local.certificate_validation[each.key].resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "deployment" {
  for_each = var.deployments

  certificate_arn = aws_acm_certificate.deployment[each.key].arn

  validation_record_fqdns = [aws_route53_record.certificate_validation[each.key].fqdn]
}
