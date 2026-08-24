# Observability, entirely CloudWatch-native: there is no self-hosted monitoring
# stack to operate, upgrade, or lose. Smoke tests catch deploy-time failure;
# everything here is aimed at day-3 degradation.
#
# Metric names under the ContainerInsights namespace come from enhanced
# Container Insights. Confirm them against the account once the add-on has
# reported for a few minutes (phase 4) — an alarm on a metric that is never
# published is an alarm that never fires.

resource "aws_sns_topic" "alerts" {
  name = "alchemiscale-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  alarm_actions = [aws_sns_topic.alerts.arn]

  # Every (deployment, api) pair that gets an outside-in health check — only for
  # instances marked live. A health check against a hostname that does not
  # resolve yet sits in ALARM from the moment it is created and pages about an
  # instance nobody has deployed.
  health_check_targets = merge([
    for name, hosts in local.deployment_hosts : {
      for role, host in hosts : "${name}-${role}" => {
        deployment = name
        role       = role
        host       = host
      }
    } if var.deployments[name].live
  ]...)
}

# ---------------------------------------------------------------------------
# outside-in: the authoritative "is it up" signal
#
# Deliberately independent of the cluster — DNS -> ALB -> pod, exercised from
# outside AWS. If the cluster dies entirely, this is what still pages.
# ---------------------------------------------------------------------------

resource "aws_route53_health_check" "api" {
  for_each = local.health_check_targets

  fqdn              = each.value.host
  type              = "HTTPS"
  port              = 443
  resource_path     = "/ping"
  failure_threshold = 3
  request_interval  = 30
  measure_latency   = true

  tags = {
    Name       = each.value.host
    deployment = each.value.deployment
  }
}

resource "aws_cloudwatch_metric_alarm" "health_check" {
  for_each = local.health_check_targets

  provider = aws.us_east_1

  alarm_name        = "alchemiscale-${each.key}-unreachable"
  alarm_description = "${each.value.host}/ping is failing from outside AWS"

  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.api[each.key].id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

# ---------------------------------------------------------------------------
# cluster health (Container Insights)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "container_restarts" {
  for_each = var.deployments

  alarm_name        = "alchemiscale-${each.key}-container-restarts"
  alarm_description = "Containers in the ${each.key} namespace are restarting — likely a crash loop"

  namespace   = "ContainerInsights"
  metric_name = "pod_number_of_container_restarts"
  dimensions = {
    ClusterName = var.cluster_name
    Namespace   = each.key
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 3
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "pods_pending" {
  for_each = var.deployments

  alarm_name        = "alchemiscale-${each.key}-pods-pending"
  alarm_description = "Pods in the ${each.key} namespace have been unschedulable for 15 minutes — capacity, PVC, or NodePool limit"

  namespace   = "ContainerInsights"
  metric_name = "pod_status_pending"
  dimensions = {
    ClusterName = var.cluster_name
    Namespace   = each.key
  }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "node_cpu" {
  alarm_name        = "alchemiscale-prod-node-cpu"
  alarm_description = "Sustained node CPU pressure across the production cluster"

  namespace           = "ContainerInsights"
  metric_name         = "node_cpu_utilization"
  dimensions          = { ClusterName = var.cluster_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "node_memory" {
  alarm_name        = "alchemiscale-prod-node-memory"
  alarm_description = "Sustained node memory pressure across the production cluster"

  namespace           = "ContainerInsights"
  metric_name         = "node_memory_utilization"
  dimensions          = { ClusterName = var.cluster_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

# A quietly filling neo4j disk is the most likely silent failure mode here. The
# metric is published by the sidecar in the chart's neo4j StatefulSet rather
# than inferred from Container Insights, so it exists whether or not enhanced
# observability covers PVC utilisation.
resource "aws_cloudwatch_metric_alarm" "neo4j_disk" {
  for_each = var.deployments

  alarm_name        = "alchemiscale-${each.key}-neo4j-disk"
  alarm_description = "The ${each.key} neo4j data volume is over 80% full"

  namespace   = "alchemiscale"
  metric_name = "neo4j_data_used_percent"
  dimensions = {
    ClusterName = var.cluster_name
    Namespace   = each.key
  }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

# ---------------------------------------------------------------------------
# logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "api_errors" {
  name           = "alchemiscale-errors"
  log_group_name = aws_cloudwatch_log_group.prod.name
  pattern        = "?ERROR ?CRITICAL ?Traceback"

  metric_transformation {
    name          = "ErrorCount"
    namespace     = "alchemiscale"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "error_spike" {
  alarm_name        = "alchemiscale-error-spike"
  alarm_description = "Elevated ERROR/Traceback volume in container logs"

  namespace           = "alchemiscale"
  metric_name         = aws_cloudwatch_log_metric_filter.api_errors.metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 25
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

# A dead log pipeline is otherwise invisible: no logs looks exactly like no
# problems.
resource "aws_cloudwatch_metric_alarm" "log_ingestion_stopped" {
  alarm_name        = "alchemiscale-log-ingestion-stopped"
  alarm_description = "No container logs have reached CloudWatch for 45 minutes — Fluent Bit or its credentials are broken"

  namespace           = "AWS/Logs"
  metric_name         = "IncomingLogEvents"
  dimensions          = { LogGroupName = aws_cloudwatch_log_group.prod.name }
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

# ---------------------------------------------------------------------------
# ALB (the layer between Route53 and the pods)
#
# The ALB is provisioned by EKS Auto Mode from the chart's Ingress, so it cannot
# be referenced until a deployment is actually serving; `enable_alb_alarms`
# gates a second apply once that is true.
# ---------------------------------------------------------------------------

data "aws_lb" "ingress" {
  count = var.enable_alb_alarms ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  count = var.enable_alb_alarms ? 1 : 0

  alarm_name        = "alchemiscale-alb-5xx"
  alarm_description = "The ingress ALB is returning 5xx responses of its own"

  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = data.aws_lb.ingress[0].arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_targets" {
  count = var.enable_alb_alarms ? 1 : 0

  alarm_name        = "alchemiscale-alb-unhealthy-targets"
  alarm_description = "The ingress ALB has unhealthy targets — API pods failing /ping"

  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = data.aws_lb.ingress[0].arn_suffix }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

# ---------------------------------------------------------------------------
# dashboards — one per deployment, the first place to look during an incident
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "deployment" {
  for_each = var.deployments

  dashboard_name = "alchemiscale-${each.key}"

  dashboard_body = jsonencode({
    widgets = concat(
      # only once the endpoint is live and has health checks to plot
      each.value.live ? [
        {
          type   = "metric"
          x      = 0
          y      = 0
          width  = 12
          height = 6
          properties = {
            title  = "API reachability (/ping)"
            region = "us-east-1"
            view   = "timeSeries"
            stat   = "Minimum"
            period = 60
            metrics = [
              for role in ["client", "compute"] : [
                "AWS/Route53", "HealthCheckStatus", "HealthCheckId",
                aws_route53_health_check.api["${each.key}-${role}"].id,
                { label = local.deployment_hosts[each.key][role] }
              ]
            ]
            yAxis = { left = { min = 0, max = 1 } }
          }
        },
      ] : [],
      [
        {
          type   = "metric"
          x      = 12
          y      = 0
          width  = 12
          height = 6
          properties = {
            title  = "neo4j data volume used (%)"
            region = var.region
            view   = "timeSeries"
            stat   = "Maximum"
            period = 300
            metrics = [
              ["alchemiscale", "neo4j_data_used_percent", "ClusterName", var.cluster_name, "Namespace", each.key]
            ]
            annotations = {
              horizontal = [{ label = "alarm", value = 80 }]
            }
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 6
          width  = 12
          height = 6
          properties = {
            title  = "pod restarts"
            region = var.region
            view   = "timeSeries"
            stat   = "Sum"
            period = 300
            metrics = [
              ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", var.cluster_name, "Namespace", each.key]
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 6
          width  = 12
          height = 6
          properties = {
            title  = "CPU / memory utilisation"
            region = var.region
            view   = "timeSeries"
            stat   = "Average"
            period = 300
            metrics = [
              ["ContainerInsights", "pod_cpu_utilization", "ClusterName", var.cluster_name, "Namespace", each.key],
              ["ContainerInsights", "pod_memory_utilization", "ClusterName", var.cluster_name, "Namespace", each.key],
            ]
          }
        },
        {
          type   = "log"
          x      = 0
          y      = 12
          width  = 24
          height = 6
          properties = {
            title  = "recent errors"
            region = var.region
            query  = "SOURCE '${aws_cloudwatch_log_group.prod.name}' | fields @timestamp, @logStream, @message\n| filter @logStream like /^${each.key}\\./ and @message like /ERROR|Traceback/\n| sort @timestamp desc\n| limit 50"
            view   = "table"
          }
        },
      ],
    )
  })
}
