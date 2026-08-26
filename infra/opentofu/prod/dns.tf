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
  # `*.x` and `x` validate through the same record, so key by record name to
  # collapse the duplicate rather than fighting Route53 over it
  certificate_validations = merge([
    for name, cert in aws_acm_certificate.deployment : {
      for dvo in cert.domain_validation_options :
      "${name}|${dvo.resource_record_name}" => {
        zone_name = dvo.resource_record_name
        type      = dvo.resource_record_type
        record    = dvo.resource_record_value
      }
    }
  ]...)
}

resource "aws_route53_record" "certificate_validation" {
  for_each = local.certificate_validations

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.zone_name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "deployment" {
  for_each = var.deployments

  certificate_arn = aws_acm_certificate.deployment[each.key].arn

  validation_record_fqdns = [
    for key, record in aws_route53_record.certificate_validation :
    record.fqdn if startswith(key, "${each.key}|")
  ]
}
