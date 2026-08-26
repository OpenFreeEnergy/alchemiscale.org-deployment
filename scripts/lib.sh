#!/usr/bin/env bash
#
# Shared helpers for the operator scripts. Not executable on its own.

set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${PROD_CLUSTER:=alchemiscale-prod}"
: "${TEST_CLUSTER:=alchemiscale-test}"

die() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo "==> $*" >&2
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

# Resolve a cluster keyword (prod|test) to a cluster name.
cluster_name() {
  case "$1" in
    prod) echo "${PROD_CLUSTER}" ;;
    test) echo "${TEST_CLUSTER}" ;;
    *) die "unknown cluster '$1' (expected prod or test)" ;;
  esac
}

# Point kubectl at the requested cluster. Operators hold an admin access entry
# on both clusters; nothing here works without one.
use_cluster() {
  local cluster="$1"
  require aws
  require kubectl
  info "using cluster $(cluster_name "${cluster}")"
  aws eks update-kubeconfig \
    --name "$(cluster_name "${cluster}")" \
    --region "${AWS_REGION}" >/dev/null
}

namespace_exists() {
  kubectl get namespace "$1" >/dev/null 2>&1
}

# names fixed by the chart: one release per namespace, so these are stable
NEO4J_STATEFULSET="alchemiscale-neo4j"
# shellcheck disable=SC2034  # used by the dump/restore scripts that source this
NEO4J_PVC="data-alchemiscale-neo4j-0"

# `neo4j-admin database dump/load` needs the database offline, and the gp3 PVC
# is ReadWriteOnce — so both dump and restore open a short maintenance window in
# which the APIs error, exactly as they do during the equivalent operation on
# the EC2 hosts today.
scale_neo4j() {
  local namespace="$1" replicas="$2"

  info "scaling ${NEO4J_STATEFULSET} to ${replicas} in ${namespace}"
  kubectl scale statefulset "${NEO4J_STATEFULSET}" -n "${namespace}" --replicas="${replicas}"

  if [ "${replicas}" = "0" ]; then
    kubectl wait --for=delete "pod/${NEO4J_STATEFULSET}-0" -n "${namespace}" --timeout=5m 2>/dev/null || true
  else
    kubectl rollout status statefulset "${NEO4J_STATEFULSET}" -n "${namespace}" --timeout=10m
  fi
}

# Stream a Job's logs until it finishes, then report its outcome.
run_job() {
  local namespace="$1" job="$2" timeout="${3:-2h}"

  kubectl wait --for=condition=ready pod -l "job-name=${job}" -n "${namespace}" --timeout=10m 2>/dev/null || true
  kubectl logs -f -n "${namespace}" "job/${job}" --all-containers --pod-running-timeout=10m || true

  if kubectl wait --for=condition=complete "job/${job}" -n "${namespace}" --timeout="${timeout}"; then
    return 0
  fi

  kubectl describe "job/${job}" -n "${namespace}" >&2
  return 1
}
