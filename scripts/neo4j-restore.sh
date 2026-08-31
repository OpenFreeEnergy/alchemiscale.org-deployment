#!/usr/bin/env bash
#
# Restore a neo4j logical dump from S3 into a deployment, overwriting whatever
# is in that namespace's database.
#
#   scripts/neo4j-restore.sh <deployment> <s3-uri> [-c prod|test] [-n <namespace>]
#   scripts/neo4j-restore.sh asap s3://alchemiscale-backups-000000000000/asap/20260817T090000Z.dump
#
# This is the second half of the EC2 -> EKS migration path: dump on the EC2 host
# with the existing docker-compose tooling, copy to S3, restore here.
#
# The database is offline for the duration and its current contents are
# destroyed — the script asks before doing either.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

[ $# -ge 2 ] || usage
deployment="$1"
source_uri="$2"
shift 2

[[ "${source_uri}" == s3://* ]] || die "expected an s3:// URI, got '${source_uri}'"

cluster="prod"
namespace=""
image=""

while getopts ":c:n:i:h" opt; do
  case "${opt}" in
    c) cluster="${OPTARG}" ;;
    n) namespace="${OPTARG}" ;;
    i) image="${OPTARG}" ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done

namespace="${namespace:-${deployment}}"
without_scheme="${source_uri#s3://}"
bucket="${without_scheme%%/*}"
key="${without_scheme#*/}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
job="neo4j-restore-${stamp,,}"

use_cluster "${cluster}"
namespace_exists "${namespace}" || die "namespace ${namespace} does not exist"

neo4j_image="$(kubectl get statefulset "${NEO4J_STATEFULSET}" -n "${namespace}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
if [ -z "${image}" ]; then
  image="$(kubectl get deploy alchemiscale-client-api -n "${namespace}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
fi

cat <<EOF >&2

  deployment: ${deployment} (namespace ${namespace}, cluster ${cluster})
  source:     ${source_uri}

This DESTROYS the current contents of ${deployment}'s database and replaces them
with the dump. neo4j will be offline for the duration.
EOF
read -r -p "type the deployment name to continue: " confirm
[ "${confirm}" = "${deployment}" ] || die "aborted"

scale_neo4j "${namespace}" 0

cleanup() {
  scale_neo4j "${namespace}" 1
}
on_exit cleanup

info "running restore job ${job}"
kubectl apply -n "${namespace}" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  labels:
    app.kubernetes.io/part-of: alchemiscale
    app.kubernetes.io/component: neo4j-restore
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: alchemiscale
      securityContext:
        fsGroup: 7474
      initContainers:
        - name: download
          image: ${image}
          command:
            - /usr/local/bin/_entrypoint.sh
            - python
            - -u
            - -c
            - |
              import os
              import boto3

              destination = "/dump/neo4j.dump"
              print(f"downloading s3://{os.environ['BUCKET']}/{os.environ['KEY']}", flush=True)

              boto3.client("s3").download_file(os.environ["BUCKET"], os.environ["KEY"], destination)
              print(f"downloaded {os.path.getsize(destination)} bytes", flush=True)
          env:
            - name: BUCKET
              value: ${bucket}
            - name: KEY
              value: ${key}
            - name: AWS_DEFAULT_REGION
              value: ${AWS_REGION}
          volumeMounts:
            - name: dump
              mountPath: /dump
      containers:
        - name: load
          image: ${neo4j_image}
          command:
            - neo4j-admin
            - database
            - load
            - neo4j
            - --from-path=/dump
            - --overwrite-destination=true
          volumeMounts:
            - name: data
              mountPath: /data
            - name: dump
              mountPath: /dump
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${NEO4J_PVC}
        - name: dump
          emptyDir: {}
EOF

if run_job "${namespace}" "${job}"; then
  info "restore complete; neo4j is coming back up"
  kubectl delete job "${job}" -n "${namespace}" --ignore-not-found >/dev/null
  cat <<EOF >&2

The dump carries the database only, not neo4j's own user store — this instance
keeps the credentials in its Kubernetes Secret. Identities and scopes stored in
the alchemiscale database come across with the dump.
EOF
else
  die "restore job failed; neo4j will be scaled back up, the job is left in place for inspection"
fi
