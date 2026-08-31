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

# One EXIT trap with a stack of hooks, because a second `trap … EXIT` silently
# replaces the first — and these scripts have more than one thing to undo (a
# temporary kubeconfig, a StatefulSet scaled to zero). Hooks run last-registered
# first, so teardown unwinds in the order it was set up: whatever still needs
# kubectl runs before the kubeconfig goes away.
_exit_hooks=()

on_exit() {
  _exit_hooks+=("$1")
}

_run_exit_hooks() {
  local status=$? i
  for ((i = ${#_exit_hooks[@]} - 1; i >= 0; i--)); do
    "${_exit_hooks[i]}" || true
  done
  return "${status}"
}

trap _run_exit_hooks EXIT

# Resolve a cluster keyword (prod|test) to a cluster name.
cluster_name() {
  case "$1" in
    prod) echo "${PROD_CLUSTER}" ;;
    test) echo "${TEST_CLUSTER}" ;;
    *) die "unknown cluster '$1' (expected prod or test)" ;;
  esac
}

# Expired SSO tokens are far and away the most common way these scripts fail,
# and the raw NoCredentials error arrives *after* "using cluster …" has printed,
# which reads as though it got further than it did.
require_credentials() {
  aws sts get-caller-identity >/dev/null 2>&1 && return 0

  local hint="aws sso login"
  [ -n "${AWS_PROFILE:-}" ] && hint="${hint} --profile ${AWS_PROFILE}"
  die "no valid AWS credentials for${AWS_PROFILE:+ profile ${AWS_PROFILE}} — try: ${hint}"
}

_remove_temp_kubeconfig() {
  [ -n "${_temp_kubeconfig:-}" ] && rm -f "${_temp_kubeconfig}"
}

# Point kubectl at the requested cluster, for the lifetime of this script only.
#
# `aws eks update-kubeconfig` writes the context *and* makes it current, so
# doing that to the caller's ~/.kube/config would silently retarget their shell:
# run an identity command against prod, then a plain `helm upgrade` later, and
# it lands on prod. Writing to a throwaway file and exporting KUBECONFIG keeps
# the effect inside the script, where it belongs.
#
# Operators hold an admin access entry on both clusters; nothing here works
# without one.
use_cluster() {
  local cluster="$1"
  require aws
  require kubectl
  require_credentials

  _temp_kubeconfig="$(mktemp -t alchemiscale-kubeconfig.XXXXXX)"
  export KUBECONFIG="${_temp_kubeconfig}"
  on_exit _remove_temp_kubeconfig

  info "using cluster $(cluster_name "${cluster}")"

  local err available
  if ! err="$(aws eks update-kubeconfig \
    --name "$(cluster_name "${cluster}")" \
    --region "${AWS_REGION}" \
    --kubeconfig "${_temp_kubeconfig}" 2>&1 >/dev/null)"; then

    # naming what is actually there turns "no such cluster" into an answer:
    # usually the cluster keyword was wrong, or the region is
    available="$(aws eks list-clusters --region "${AWS_REGION}" \
      --query 'clusters[]' --output text 2>/dev/null | tr '\t' ' ')"
    die "cannot reach $(cluster_name "${cluster}") in ${AWS_REGION}: ${err}${available:+ (clusters in ${AWS_REGION}: ${available})}"
  fi
}

# Run the alchemiscale CLI inside a deployment's client API pod.
#
# `kubectl exec` bypasses the image ENTRYPOINT, and these images keep the CLI in
# a conda environment that the entrypoint activates — exec'ing `alchemiscale`
# directly fails with "executable file not found in $PATH". Going through
# `_entrypoint.sh` activates the environment and then execs, which is also how
# every container in the chart starts.
alchemiscale_exec() {
  local namespace="$1"
  shift
  kubectl exec -n "${namespace}" deploy/alchemiscale-client-api -c client-api -- \
    /usr/local/bin/_entrypoint.sh alchemiscale "$@"
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
