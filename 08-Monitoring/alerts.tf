# =============================================================================
# Prometheus Alerts + Alertmanager Configuration
# =============================================================================
# NO DUPLICATION WITH CLOUDWATCH:
#   CloudWatch = AWS infrastructure metrics (Aurora, ALB, node CPU, NAT, WAF)
#   Prometheus = Kubernetes-native metrics (container throttling, OOMKill,
#               HPA, PVC, API server, etcd, CoreDNS, deployment replicas)
#
# SPLIT RATIONALE:
#   If CPU > 80% on a NODE → CloudWatch fires (AWS-level)
#   If a CONTAINER is throttled at 50m CPU → Prometheus fires (K8s-level)
#   These are DIFFERENT problems with DIFFERENT fixes. No duplicate alerts.
# =============================================================================

# =============================================================================
# 1. ALERTMANAGER CONFIG — email + Slack notifications
# =============================================================================
# kube-prometheus-stack already installs Alertmanager. This configures WHERE
# alerts get sent. We use a Kubernetes Secret + AlertmanagerConfig CRD.
#
# ALERT FLOW:
#   Prometheus rule fires → Alertmanager receives → routes by severity:
#     critical → email + Slack immediately
#     warning  → Slack only
#     info     → Slack (deduplicated)
# =============================================================================
resource "kubernetes_manifest" "alertmanager_config" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1alpha1"
    kind       = "AlertmanagerConfig"
    metadata = {
      name      = "prometheus-alerts-routing"
      namespace = "monitoring"
      labels = {
        "app.kubernetes.io/name"       = "alertmanager-config"
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = {
      route = {
        receiver      = "default"
        groupBy       = ["alertname", "namespace", "severity"]
        groupWait     = "30s"
        groupInterval = "5m"
        repeatInterval = "4h"
        routes = [
          {
            matcher  = "severity = critical"
            receiver  = "critical-email-slack"
            groupWait = "10s"
          },
          {
            matcher  = "severity = warning"
            receiver  = "warning-slack"
          }
        ]
      }
      receivers = [
        {
          name = "default"
          slackConfigs = [{
            apiURL = {
              key      = "slack-webhook-url"
              name     = "slack-webhook-secret"
            }
            channel = "#monitoring"
            sendResolved = true
          }]
        },
        {
          name = "critical-email-slack"
          emailConfigs = [{
            sendResolved = true
            to           = var.alert_email
            from         = var.alert_email
            smarthost    = "email-smtp.${var.region}.amazonaws.com:587"
            authUsername = var.alert_email
            authPassword = {
              key  = "smtp-password"
              name = "slack-webhook-secret"
            }
            headers = [{
              key   = "Subject"
              value = "[CRITICAL] {{ .CommonLabels.alertname }} — {{ .CommonLabels.namespace }}"
            }]
          }]
          slackConfigs = [{
            apiURL = {
              key  = "slack-webhook-url"
              name = "slack-webhook-secret"
            }
            channel      = "#monitoring"
            sendResolved = true
          }]
        },
        {
          name = "warning-slack"
          slackConfigs = [{
            apiURL = {
              key  = "slack-webhook-url"
              name = "slack-webhook-secret"
            }
            channel      = "#monitoring"
            sendResolved = true
          }]
        }
      ]
    }
  }

  depends_on = [helm_release.prometheus_grafana]
}

# ── Secret holding Slack webhook URL + SMTP password ────────────────────────
# Set via kubectl after apply:
#   kubectl create secret generic slack-webhook-secret -n monitoring \
#     --from-literal=slack-webhook-url='https://hooks.slack.com/services/XXX/XXX/XXX'
#     --from-literal=smtp-password='your-ses-smtp-password'
resource "kubernetes_secret" "alertmanager_secrets" {
  metadata {
    name      = "slack-webhook-secret"
    namespace = "monitoring"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
  type = "Opaque"
  data = {
    slack-webhook-url = base64encode("https://hooks.slack.com/services/PLACEHOLDER")
    smtp-password     = base64encode("PLACEHOLDER")
  }

  depends_on = [helm_release.prometheus_grafana]
}

# =============================================================================
# 2. PROMETHEUS RULES — 30 alerts (15 app + 15 infra)
# =============================================================================
# All rules use Prometheus expressions on K8s-native metrics.
# NONE overlap with CloudWatch alarms (which use AWS/RDS, AWS/ApplicationELB,
# ContainerInsights, AWS/NATGateway namespaces).
# =============================================================================

resource "kubernetes_manifest" "prometheus_alerts" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "pip-project-ecommerce-alerts"
      namespace = "monitoring"
      labels = {
        "app.kubernetes.io/name"       = "prometheus-alerts"
        "app.kubernetes.io/managed-by" = "terraform"
        "prometheus"                   = "kube-prometheus-stack-prometheus"
      }
    }
    spec = {
      groups = [
        # =========================================================================
        # GROUP 1: APPLICATION-LEVEL ALERTS (15)
        # CloudWatch can't see these — they use K8s-native + app metrics
        # =========================================================================
        {
          name = "ecommerce-application"
          rules = [
            # 1. High HTTP 5xx error rate (per-service, not per-ALB)
            {
              alert  = "AppHigh5xxErrorRate"
              expr   = "sum(rate(http_requests_total{status=~\"5..\"}[5m])) by (service) / sum(rate(http_requests_total[5m])) by (service) > 0.05"
              for    = "5m"
              labels = { severity = "critical", category = "application" }
              annotations = {
                summary     = "{{ $labels.service }} has > 5% 5xx error rate"
                description = "Service {{ $labels.service }} is returning > 5% HTTP 5xx errors. Check application logs and recent deployments."
              }
            },
            # 2. High HTTP 4xx error rate (client errors)
            {
              alert  = "AppHigh4xxErrorRate"
              expr   = "sum(rate(http_requests_total{status=~\"4..\"}[5m])) by (service) / sum(rate(http_requests_total[5m])) by (service) > 0.20"
              for    = "10m"
              labels = { severity = "warning", category = "application" }
              annotations = {
                summary     = "{{ $labels.service }} has > 20% 4xx error rate"
                description = "Service {{ $labels.service }} is returning > 20% HTTP 4xx errors. May indicate bad client requests or missing routes."
              }
            },
            # 3. High P99 latency per service
            {
              alert  = "AppHighP99Latency"
              expr   = "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)) > 0.5"
              for    = "5m"
              labels = { severity = "warning", category = "application" }
              annotations = {
                summary     = "{{ $labels.service }} P99 latency > 500ms"
                description = "Service {{ $labels.service }} has P99 latency above 500ms. Check for slow queries, N+1 ORM calls, or external API timeouts."
              }
            },
            # 4. High P95 latency
            {
              alert  = "AppHighP95Latency"
              expr   = "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)) > 0.2"
              for    = "10m"
              labels = { severity = "warning", category = "application" }
              annotations = {
                summary     = "{{ $labels.service }} P95 latency > 200ms"
                description = "Service {{ $labels.service }} P95 latency above 200ms — SLO breach."
              }
            },
            # 5. Container OOMKilled (CloudWatch doesn't track this)
            {
              alert  = "AppContainerOOMKilled"
              expr   = "increase(kube_pod_container_status_last_terminated_reason{reason=\"OOMKilled\"}[5m]) > 0"
              for    = "0m"
              labels = { severity = "critical", category = "application" }
              annotations = {
                summary     = "Container OOMKilled in {{ $labels.namespace }}/{{ $labels.pod }}"
                description = "Container {{ $labels.container }} was OOMKilled. Increase memory request/limit or investigate memory leak."
              }
            },
            # 6. Pod CrashLoopBackOff
            {
              alert  = "AppPodCrashLooping"
              expr   = "increase(kube_pod_container_status_restarts_total[10m]) > 5"
              for    = "0m"
              labels = { severity = "critical", category = "application" }
              annotations = {
                summary     = "Pod {{ $labels.pod }} crash-looping (>5 restarts in 10m)"
                description = "Container {{ $labels.container }} in {{ $labels.namespace }} restarted > 5 times in 10 minutes. Check logs: kubectl logs {{ $labels.pod }} -n {{ $labels.namespace }}"
              }
            },
            # 7. Deployment replicas mismatch (desired != ready)
            {
              alert  = "AppDeploymentReplicasMismatch"
              expr   = "kube_deployment_spec_replicas != kube_deployment_status_replicas_available"
              for    = "10m"
              labels = { severity = "warning", category = "application" }
              annotations = {
                summary     = "Deployment {{ $labels.deployment }} has mismatched replicas"
                description = "Deployment {{ $labels.deployment }} in {{ $labels.namespace }} has {{ $value }} desired but not all ready replicas available. Pods may be failing to start."
              }
            },
            # 8. HPA at max replicas (can't scale further)
            {
              alert  = "AppHPAAtMaxReplicas"
              expr   = "kube_hpa_status_current_replicas == kube_hpa_spec_max_replicas and kube_hpa_status_current_replicas > 1"
              for    = "10m"
              labels = { severity = "warning", category = "application" }
              annotations = {
                summary     = "HPA {{ $labels.hpa }} at max replicas"
                description = "HPA {{ $labels.hpa }} in {{ $labels.namespace }} is running at max replicas ({{ $value }}). Service is at capacity — increase max_replicas or add resources."
              }
            },
            # 9. PVC usage high
            {
              alert  = "AppPVCUsageHigh"
              expr   = "kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.85"
              for    = "5m"
              labels = { severity = "warning", category = "application" }
              annotations = {
                summary     = "PVC {{ $labels.persistentvolumeclaim }} > 85% full"
                description = "PVC {{ $labels.persistentvolumeclaim }} in {{ $labels.namespace }} is > 85% full. Expand volume or clean up data."
              }
            },
            # 10. PVC almost full
            {
              alert  = "AppPVCAlmostFull"
              expr   = "kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.95"
              for    = "1m"
              labels = { severity = "critical", category = "application" }
              annotations = {
                summary     = "PVC {{ $labels.persistentvolumeclaim }} > 95% full"
                description = "PVC {{ $labels.persistentvolumeclaim }} is almost full. Pod writes will fail soon."
              }
            },
            # 11. Container CPU throttled > 50% (CloudWatch doesn't see this)
            {
              alert  = "AppContainerCPUThrottled"
              expr   = "rate(container_cpu_cfs_throttled_seconds_total[5m]) / rate(container_cpu_cfs_periods_total[5m]) > 0.5"
              for    = "10m"
              labels = { severity = "warning", category = "application" }
              annotations = {
                summary     = "Container {{ $labels.container }} CPU throttled > 50%"
                description = "Container {{ $labels.container }} in {{ $labels.namespace }} is being CPU-throttled > 50% of the time. Increase CPU limit."
              }
            },
            # 12. Container memory near limit
            {
              alert  = "AppContainerMemoryNearLimit"
              expr   = "container_memory_working_set_bytes / container_spec_memory_limit_bytes > 0.90 and container_spec_memory_limit_bytes > 0"
              for    = "5m"
              labels = { severity = "warning", category = "application" }
              annotations = {
                summary     = "Container {{ $labels.container }} using > 90% of memory limit"
                description = "Container {{ $labels.container }} in {{ $labels.namespace }} is using > 90% of its memory limit. About to be OOMKilled."
              }
            },
            # 13. K8s Job failed
            {
              alert  = "AppJobFailed"
              expr   = "kube_job_failed > 0"
              for    = "0m"
              labels = { severity = "warning", category = "application" }
              annotations = {
                summary     = "Job {{ $labels.job_name }} failed in {{ $labels.namespace }}"
                description = "Kubernetes Job {{ $labels.job_name }} has failed. Check job logs for details."
              }
            },
            # 14. Service has no ready endpoints (no pods backing the service)
            {
              alert  = "AppServiceNoReadyEndpoints"
              expr   = "kube_endpoint_address_available == 0 and kube_endpoint_address_not_ready > 0"
              for    = "2m"
              labels = { severity = "critical", category = "application" }
              annotations = {
                summary     = "Service {{ $labels.endpoint }} has no ready endpoints"
                description = "Service {{ $labels.endpoint }} in {{ $labels.namespace }} has 0 ready endpoints. All backing pods are down or not ready."
              }
            },
            # 15. Pod in Pending state > 5 min (CloudWatch has this but Prometheus is faster)
            {
              alert  = "AppPodStuckPending"
              expr   = "kube_pod_status_phase{phase=\"Pending\"} == 1"
              for    = "5m"
              labels = { severity = "warning", category = "application" }
              annotations = {
                summary     = "Pod {{ $labels.pod }} pending > 5 min"
                description = "Pod {{ $labels.pod }} in {{ $labels.namespace }} has been pending for > 5 min. Check: kubectl describe pod {{ $labels.pod }} -n {{ $labels.namespace }}"
              }
            }
          ]
        },

        # =========================================================================
        # GROUP 2: KUBERNETES INFRASTRUCTURE ALERTS (15)
        # CloudWatch sees AWS resources; these see K8s control plane internals
        # =========================================================================
        {
          name = "kubernetes-infrastructure"
          rules = [
            # 16. API server down
            {
              alert  = "KubeAPIServerDown"
              expr   = "up{job=\"apiserver\"} == 0"
              for    = "2m"
              labels = { severity = "critical", category = "infrastructure" }
              annotations = {
                summary     = "Kubernetes API server is down"
                description = "Prometheus can't reach the API server. Cluster may be unreachable."
              }
            },
            # 17. Kubelet down on a node
            {
              alert  = "KubeletDown"
              expr   = "up{job=\"kubelet\"} == 0"
              for    = "5m"
              labels = { severity = "critical", category = "infrastructure" }
              annotations = {
                summary     = "Kubelet down on {{ $labels.instance }}"
                description = "Kubelet is not responding on node {{ $labels.instance }}. Node may be unhealthy."
              }
            },
            # 18. Kube scheduler unhealthy
            {
              alert  = "KubeSchedulerDown"
              expr   = "up{job=\"kube-scheduler\"} == 0"
              for    = "5m"
              labels = { severity = "critical", category = "infrastructure" }
              annotations = {
                summary     = "Kube scheduler is down"
                description = "Kube scheduler is not responding. New pods won't be placed on nodes."
              }
            },
            # 19. Kube controller manager down
            {
              alert  = "KubeControllerManagerDown"
              expr   = "up{job=\"kube-controller-manager\"} == 0"
              for    = "5m"
              labels = { severity = "critical", category = "infrastructure" }
              annotations = {
                summary     = "Kube controller manager is down"
                description = "Controller manager not responding. Replica reconciliation, node status updates are stopped."
              }
            },
            # 20. etcd leader changes (indicates etcd instability)
            {
              alert  = "ETCDLeaderChanges"
              expr   = "increase(etcd_server_leader_changes_seen_total[1h]) > 0"
              for    = "0m"
              labels = { severity = "warning", category = "infrastructure" }
              annotations = {
                summary     = "etcd had {{ $value }} leader changes in 1h"
                description = "etcd leader changes indicate cluster instability. Investigate node health and network partitions."
              }
            },
            # 21. etcd high filesystem writes
            {
              alert  = "ETCDHighFSWrite"
              expr   = "rate(etcd_disk_wal_fsync_duration_seconds_sum[5m]) / rate(etcd_disk_wal_fsync_duration_seconds_count[5m]) > 0.025"
              for    = "5m"
              labels = { severity = "warning", category = "infrastructure" }
              annotations = {
                summary     = "etcd WAL fsync latency > 25ms"
                description = "etcd write latency is high. Disk I/O may be insufficient for the control plane."
              }
            },
            # 22. Node NotReady
            {
              alert  = "KubeNodeNotReady"
              expr   = "kube_node_status_condition{condition=\"Ready\",status=\"unknown\"} == 1 or kube_node_status_condition{condition=\"Ready\",status=\"false\"} == 1"
              for    = "5m"
              labels = { severity = "critical", category = "infrastructure" }
              annotations = {
                summary     = "Node {{ $labels.node }} is NotReady"
                description = "Node {{ $labels.node }} has been NotReady for > 5 min. Karpenter should replace it. Check node health."
              }
            },
            # 23. Kube-proxy down
            {
              alert  = "KubeProxyDown"
              expr   = "up{job=\"kube-proxy\"} == 0"
              for    = "5m"
              labels = { severity = "critical", category = "infrastructure" }
              annotations = {
                summary     = "kube-proxy is down on {{ $labels.instance }}"
                description = "kube-proxy not running. Service routing (ClusterIP → pod) is broken on this node."
              }
            },
            # 24. CoreDNS down
            {
              alert  = "CoreDNSDown"
              expr   = "up{job=\"kube-dns\"} == 0"
              for    = "2m"
              labels = { severity = "critical", category = "infrastructure" }
              annotations = {
                summary     = "CoreDNS is down"
                description = "CoreDNS not responding. In-cluster DNS resolution is broken — pods can't resolve service names."
              }
            },
            # 25. CoreDNS high error rate
            {
              alert  = "CoreDNSHighErrorRate"
              expr   = "sum(rate(coredns_dns_requests_total{rcode=\"SERVFAIL\"}[5m])) / sum(rate(coredns_dns_requests_total[5m])) > 0.05"
              for    = "10m"
              labels = { severity = "warning", category = "infrastructure" }
              annotations = {
                summary     = "CoreDNS error rate > 5%"
                description = "CoreDNS is returning SERVFAIL for > 5% of queries. Check upstream DNS config."
              }
            },
            # 26. Kubelet PLEG delay high (pod lifecycle event generator slow)
            {
              alert  = "KubeletPLEGDelayHigh"
              expr   = "node_kubelet_pleg_relist_duration_seconds{quantile=\"0.99\"} > 5"
              for    = "5m"
              labels = { severity = "warning", category = "infrastructure" }
              annotations = {
                summary     = "Kubelet PLEG delay > 5s on {{ $labels.node }}"
                description = "Pod lifecycle event generator is slow on node {{ $labels.node }}. Pods may be slow to start/stop."
              }
            },
            # 27. Kubelet volume mount failures
            {
              alert  = "KubeletVolumeMountFailed"
              expr   = "kubelet_volume_metric_collection_failed_total > 0"
              for    = "5m"
              labels = { severity = "warning", category = "infrastructure" }
              annotations = {
                summary     = "Volume mount failing on {{ $labels.node }}"
                description = "Kubelet can't collect metrics for a volume on {{ $labels.node }}. PVC may be stuck."
              }
            },
            # 28. API server high request latency (CloudWatch doesn't see K8s API internals)
            {
              alert  = "KubeAPIServerHighLatency"
              expr   = "histogram_quantile(0.99, sum(rate(apiserver_request_duration_seconds_bucket[5m])) by (le, verb)) > 1"
              for    = "10m"
              labels = { severity = "warning", category = "infrastructure" }
              annotations = {
                summary     = "API server P99 latency > 1s for {{ $labels.verb }}"
                description = "Kubernetes API server is slow for {{ $labels.verb }} requests. May indicate etcd issues or controller overload."
              }
            },
            # 29. API server error rate
            {
              alert  = "KubeAPIServerErrorRate"
              expr   = "sum(rate(apiserver_request_total{code=~\"5..\"}[5m])) / sum(rate(apiserver_request_total[5m])) > 0.01"
              for    = "10m"
              labels = { severity = "warning", category = "infrastructure" }
              annotations = {
                summary     = "API server returning > 1% 5xx errors"
                description = "Kubernetes API server is returning errors for > 1% of requests. Check control plane health."
              }
            },
            # 30. Certificate expiry — K8s internal certs (not ACM — that's CloudWatch)
            {
              alert  = "KubeCertExpiringSoon"
              expr   = "apiserver_client_certificate_expiration_seconds < 604800"
              for    = "0m"
              labels = { severity = "warning", category = "infrastructure" }
              annotations = {
                summary     = "K8s client certificate expires in < 7 days"
                description = "A Kubernetes client certificate expires in < 7 days. EKS auto-renews these, but check if rotation is stuck."
              }
            }
          ]
        }
      ]
    }
  }

  depends_on = [helm_release.prometheus_grafana, kubernetes_secret.alertmanager_secrets]
}
