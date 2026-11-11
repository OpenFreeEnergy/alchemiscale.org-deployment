#!/usr/bin/env bash
#
# Check that each deployment's chart values point at the object store that
# OpenTofu created for it.
#
# The bucket and prefix are set twice: in the prod OpenTofu `deployments`
# variable, which creates the bucket and scopes the deployment's Pod Identity
# role to <bucket>/<prefix>/*, and in deployments/<name>/values.yaml, which
# tells the API where to write. PR deploys override the values with a scratch bucket and
# release smoke tests are read-only, so a mismatch goes unnoticed until a
# compute service pushes its first result to production and gets a 500. This is
# the check that catches it.
#
# Only the deployments variable is evaluated, in a directory of its own, so no
# provider is configured and no credentials are needed. terraform.tfvars is
# gitignored, so an operator's copy is checked where it exists and the tracked
# terraform.tfvars.example everywhere else, CI included.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="${repo_root}/charts/alchemiscale"
prod="${repo_root}/infra/opentofu/prod"
status=0

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
tfvars="${prod}/terraform.tfvars"
[ -f "${tfvars}" ] || tfvars="${prod}/terraform.tfvars.example"
cp "${prod}/variables.tf" "${scratch}/"
cp "${tfvars}" "${scratch}/terraform.tfvars"
echo "checking against ${tfvars#"${repo_root}/"}"

# console prints the JSON as a quoted string, so it is decoded twice
declare -A expected=()
while read -r deployment bucket prefix; do
  expected["${deployment}"]="${bucket} ${prefix}"
done < <(
  echo 'jsonencode({for k, v in var.deployments : k => [v.s3_bucket, v.s3_prefix]})' |
    tofu -chdir="${scratch}" console |
    jq -r . | jq -r 'to_entries[] | "\(.key) \(.value[0]) \(.value[1])"'
)

for values in "${repo_root}"/deployments/*/values.yaml; do
  deployment="$(basename "$(dirname "${values}")")"

  # read what the chart renders rather than the values file, so chart defaults
  # count too
  rendered="$(
    helm template "${deployment}" "${chart}" --namespace "${deployment}" \
      --values "${values}" --set image.tag=check |
      awk '/name: AWS_S3_(BUCKET|PREFIX)$/ { getline; gsub(/.*value: |"/, ""); printf "%s ", $0 }' |
      awk '{ print $1, $2 }'
  )"

  if [ -z "${expected[${deployment}]+set}" ]; then
    echo "error: ${deployment}: has chart values but no entry in the prod OpenTofu deployments variable, so no bucket or role" >&2
    status=1
  elif [ "${rendered}" != "${expected[${deployment}]}" ]; then
    echo "error: ${deployment}: chart writes to ${rendered/ //}, but OpenTofu provisions ${expected[${deployment}]/ //}" >&2
    status=1
  else
    echo "${deployment}: s3://${rendered/ //}"
  fi
done

exit "${status}"
