{{/*
Deployment + Service + PodDisruptionBudget for one of the two API services.
They differ only in name, port, config file, and the CLI subcommand, so they
share this template rather than drifting apart in two near-identical files.

Call with:
  ctx        root context
  component  "client-api" | "compute-api"
  api        the clientApi/computeApi values block
  args       CLI arguments preceding the shared --host/--port/--workers set
  config     name of the config file in the ConfigMap
*/}}
{{- define "alchemiscale.api" -}}
{{- $ctx := .ctx -}}
{{- $name := printf "%s-%s" (include "alchemiscale.fullname" $ctx) .component -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  namespace: {{ $ctx.Release.Namespace }}
  labels:
    {{- include "alchemiscale.labels" $ctx | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  replicas: {{ .api.replicas }}
  selector:
    matchLabels:
      {{- include "alchemiscale.selectorLabels" (dict "ctx" $ctx "component" .component) | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "alchemiscale.labels" $ctx | nindent 8 }}
        app.kubernetes.io/component: {{ .component }}
        {{- with $ctx.Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      annotations:
        # roll the pods when the rendered config changes, which a ConfigMap
        # mount would otherwise not do
        checksum/config: {{ include (print $ctx.Template.BasePath "/configmap.yaml") $ctx | sha256sum }}
        {{- with $ctx.Values.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      serviceAccountName: {{ include "alchemiscale.serviceAccountName" $ctx }}
      {{- with $ctx.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ .component }}
          image: {{ include "alchemiscale.image" $ctx }}
          imagePullPolicy: {{ $ctx.Values.image.pullPolicy }}
          args:
            {{- range .args }}
            - {{ . | quote }}
            {{- end }}
            - "--host"
            - "0.0.0.0"
            - "--port"
            - {{ .api.port | quote }}
            - "--workers"
            - {{ .api.workers | quote }}
            - "--config-file"
            - {{ printf "/mnt/%s" .config | quote }}
          ports:
            - name: http
              containerPort: {{ .api.port }}
          env:
            {{- include "alchemiscale.env" $ctx | nindent 12 }}
          volumeMounts:
            - name: config
              mountPath: /mnt
              readOnly: true
          readinessProbe:
            httpGet:
              path: /ping
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /ping
              port: http
            initialDelaySeconds: 30
            periodSeconds: 30
            failureThreshold: 5
          resources:
            {{- toYaml .api.resources | nindent 12 }}
      volumes:
        - name: config
          configMap:
            name: {{ include "alchemiscale.fullname" $ctx }}-config
      {{- if and .api.topologySpread.enabled (gt (int .api.replicas) 1) }}
      topologySpreadConstraints:
        - maxSkew: {{ .api.topologySpread.maxSkew }}
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: {{ .api.topologySpread.whenUnsatisfiable }}
          labelSelector:
            matchLabels:
              {{- include "alchemiscale.selectorLabels" (dict "ctx" $ctx "component" .component) | nindent 14 }}
      {{- end }}
      {{- with $ctx.Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $ctx.Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $name }}
  namespace: {{ $ctx.Release.Namespace }}
  labels:
    {{- include "alchemiscale.labels" $ctx | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  type: ClusterIP
  selector:
    {{- include "alchemiscale.selectorLabels" (dict "ctx" $ctx "component" .component) | nindent 4 }}
  ports:
    - name: http
      port: {{ .api.port }}
      targetPort: http
{{- if and .api.podDisruptionBudget.enabled (gt (int .api.replicas) 1) }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ $name }}
  namespace: {{ $ctx.Release.Namespace }}
  labels:
    {{- include "alchemiscale.labels" $ctx | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  minAvailable: {{ .api.podDisruptionBudget.minAvailable }}
  selector:
    matchLabels:
      {{- include "alchemiscale.selectorLabels" (dict "ctx" $ctx "component" .component) | nindent 6 }}
{{- end }}
{{- end }}
