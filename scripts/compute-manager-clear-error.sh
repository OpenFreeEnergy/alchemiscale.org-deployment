#!/usr/bin/env bash
#
# Clear a compute manager's ERROR registration on a deployment, so the manager
# can register again.
#
#   scripts/compute-manager-clear-error.sh <deployment> -m <manager name> [-c prod|test] [-n <namespace>]
#   scripts/compute-manager-clear-error.sh omsf -m nrp.omsf
#
# Prints the registration and its recorded error, then deletes it, as the
# compute API's clear_error does. Only a registration with the ERROR status is
# touched, so this is safe to re-run. A crash-looping manager registers on its
# next restart; nothing needs restarting.
#
# This goes to neo4j rather than through the compute API because it needs no
# compute identity key, and because servers before OpenFreeEnergy/alchemiscale#530
# return a 500 instead of a clear answer when there is nothing to clear.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

[ $# -ge 1 ] || usage
deployment="$1"
shift
[[ "${deployment}" == -* ]] && usage

cluster="prod"
namespace=""
manager=""

while getopts ":c:n:m:h" opt; do
  case "${opt}" in
    c) cluster="${OPTARG}" ;;
    n) namespace="${OPTARG}" ;;
    m) manager="${OPTARG}" ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done

[ -n "${manager}" ] || die "-m <manager name> is required"
require_manager_name "${manager}"

namespace="${namespace:-${deployment}}"

use_cluster "${cluster}"
namespace_exists "${namespace}" || die "namespace ${namespace} does not exist"

info "clearing ERROR registration of '${manager}' on ${deployment} (namespace ${namespace})"
cypher_exec "${namespace}" "
MATCH (cmr:ComputeManagerRegistration {name: '${manager}', status: 'ERROR'})
WITH cmr, cmr.uuid AS uuid, toString(cmr.last_status_update) AS last_status_update,
     cmr.detail AS detail
DETACH DELETE cmr
RETURN uuid, last_status_update, detail;"
