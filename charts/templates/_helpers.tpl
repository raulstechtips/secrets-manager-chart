{{/* Common labels for wrapper-owned objects. */}}
{{- define "infisical-wrapper.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Fail-to-render guards. Included at the top of the always-rendered configmap.yaml. */}}
{{- define "infisical-wrapper.validate" -}}
{{- $up := index .Values "infisical-standalone" | default dict -}}
{{- $inf := $up.infisical | default dict -}}
{{- if not .Values.siteUrl -}}
{{- fail "siteUrl must not be empty" -}}
{{- end -}}
{{- if not .Values.bootstrap.existingSecret -}}
{{- fail "bootstrap.existingSecret must not be empty" -}}
{{- end -}}
{{- if ne (toString $inf.kubeSecretRef) (toString .Values.bootstrap.existingSecret) -}}
{{- fail (printf "infisical-standalone.infisical.kubeSecretRef (%q) must equal bootstrap.existingSecret (%q)" (toString $inf.kubeSecretRef) .Values.bootstrap.existingSecret) -}}
{{- end -}}
{{- if .Values.smtp.enabled -}}
{{- $ref := .Values.infisical.authRef | default dict -}}
{{- if not $ref.name -}}{{- fail "infisical.authRef.name is required when smtp.enabled is true" -}}{{- end -}}
{{- if not $ref.namespace -}}{{- fail "infisical.authRef.namespace is required when smtp.enabled is true" -}}{{- end -}}
{{- if not .Values.infisical.projectSlug -}}{{- fail "infisical.projectSlug is required when smtp.enabled is true" -}}{{- end -}}
{{- if not .Values.infisical.environmentSlug -}}{{- fail "infisical.environmentSlug is required when smtp.enabled is true" -}}{{- end -}}
{{- end -}}
{{- if .Values.ingressRoute.enabled -}}
{{- if not .Values.ingressRoute.host -}}{{- fail "ingressRoute.host is required when ingressRoute.enabled is true" -}}{{- end -}}
{{- if not .Values.ingressRoute.tlsSecretName -}}{{- fail "ingressRoute.tlsSecretName is required when ingressRoute.enabled is true" -}}{{- end -}}
{{- end -}}
{{- if and .Values.bootstrap.generateKeys (not .Values.bootstrap.jobImage) -}}
{{- fail "bootstrap.jobImage must not be empty when bootstrap.generateKeys is true" -}}
{{- end -}}
{{- $siteCount := 0 -}}
{{- range ($inf.extraEnv | default list) -}}
{{- if eq .name "SITE_URL" -}}
{{- $siteCount = add1 $siteCount -}}
{{- $cm := dig "valueFrom" "configMapKeyRef" dict . -}}
{{- if or (ne (toString (get $cm "name")) "infisical-config") (ne (toString (get $cm "key")) "SITE_URL") -}}
{{- fail "infisical-standalone.infisical.extraEnv SITE_URL must reference configMapKeyRef infisical-config/SITE_URL" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if ne $siteCount 1 -}}
{{- fail (printf "infisical-standalone.infisical.extraEnv must contain exactly one SITE_URL entry (found %d)" $siteCount) -}}
{{- end -}}
{{- if .Values.smtp.enabled -}}
{{- range ($inf.extraEnv | default list) -}}
{{- if hasPrefix "SMTP_" .name -}}
{{- $sk := dig "valueFrom" "secretKeyRef" dict . -}}
{{- if ne (toString (get $sk "name")) $.Values.smtp.secretName -}}
{{- fail (printf "infisical-standalone.infisical.extraEnv %s must reference smtp.secretName (%q)" .name $.Values.smtp.secretName) -}}
{{- end -}}
{{- if not (hasKey $.Values.smtp.keys (toString (get $sk "key"))) -}}
{{- fail (printf "infisical-standalone.infisical.extraEnv %s key %q is not in smtp.keys" .name (toString (get $sk "key"))) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $ab := $inf.autoBootstrap | default dict -}}
{{- if $ab.enabled -}}
{{- $dest := $ab.secretDestination | default dict -}}
{{- if eq (toString $dest.name) (toString .Values.bootstrap.existingSecret) -}}
{{- fail "infisical-standalone.infisical.autoBootstrap.secretDestination.name must not equal bootstrap.existingSecret" -}}
{{- end -}}
{{- end -}}
{{- end -}}
