{{/*
Chart name, optionally overridden.
*/}}
{{- define "alchemiscale.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Resource name prefix. Releases are named for what they are — `omsf` in
production, `omsf-pr-123` in a PR namespace — so the release name alone is the
clearest prefix, but it is kept from doubling up the chart name.
*/}}
{{- define "alchemiscale.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "alchemiscale" }}
{{- end }}
{{- end }}

{{- define "alchemiscale.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Labels applied to every object.
*/}}
{{- define "alchemiscale.labels" -}}
helm.sh/chart: {{ include "alchemiscale.chart" . }}
app.kubernetes.io/name: {{ include "alchemiscale.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: alchemiscale
{{- if .Values.deployment }}
alchemiscale.org/deployment: {{ .Values.deployment }}
{{- end }}
{{- end }}

{{/*
Selector labels for a component; call as (dict "ctx" . "component" "client-api").
*/}}
{{- define "alchemiscale.selectorLabels" -}}
app.kubernetes.io/name: {{ include "alchemiscale.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Image reference. A digest, when set, wins over the tag: the tag is the
human-readable label, the digest is what actually rolls out.
*/}}
{{- define "alchemiscale.image" -}}
{{- $repo := required "image.repository must be set" .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repo .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repo (required "image.tag or image.digest must be set" .Values.image.tag) -}}
{{- end -}}
{{- end }}

{{- define "alchemiscale.neo4j.image" -}}
{{- printf "%s:%s" .Values.neo4j.image.repository .Values.neo4j.image.tag -}}
{{- end }}

{{- define "alchemiscale.serviceAccountName" -}}
{{- .Values.serviceAccount.name | default "alchemiscale" -}}
{{- end }}

{{/*
Name of the Secret holding neo4j credentials and the JWT signing key, whether
it came from Secrets Manager or was generated for a PR environment.
*/}}
{{- define "alchemiscale.secretName" -}}
{{- printf "%s-secrets" (include "alchemiscale.fullname" .) -}}
{{- end }}

{{- define "alchemiscale.neo4jServiceName" -}}
{{- printf "%s-neo4j" (include "alchemiscale.fullname" .) -}}
{{- end }}

{{- define "alchemiscale.neo4jUrl" -}}
{{- printf "bolt://%s:7687" (include "alchemiscale.neo4jServiceName" .) -}}
{{- end }}

{{/*
Environment shared by every container that talks to neo4j, S3, or issues tokens.
AWS credentials are deliberately absent: they come from EKS Pod Identity.
*/}}
{{- define "alchemiscale.env" -}}
- name: NEO4J_URL
  value: {{ include "alchemiscale.neo4jUrl" . | quote }}
- name: NEO4J_USER
  valueFrom:
    secretKeyRef:
      name: {{ include "alchemiscale.secretName" . }}
      key: NEO4J_USER
- name: NEO4J_PASS
  valueFrom:
    secretKeyRef:
      name: {{ include "alchemiscale.secretName" . }}
      key: NEO4J_PASS
- name: JWT_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "alchemiscale.secretName" . }}
      key: JWT_SECRET_KEY
- name: JWT_EXPIRE_SECONDS
  value: {{ .Values.jwt.expireSeconds | quote }}
- name: JWT_ALGORITHM
  value: {{ .Values.jwt.algorithm | quote }}
- name: AWS_S3_BUCKET
  value: {{ required "s3.bucket must be set" .Values.s3.bucket | quote }}
- name: AWS_S3_PREFIX
  value: {{ required "s3.prefix must be set" .Values.s3.prefix | quote }}
- name: AWS_DEFAULT_REGION
  value: {{ .Values.s3.region | quote }}
{{- end }}
