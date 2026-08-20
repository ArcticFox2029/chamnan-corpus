{{/*
=============================================================================
Pomocné šablony chartu of-service.

Nejsou to jen zkratky na jména. Tři z nich dělají skutečnou práci, kterou by
jinak musel dělat člověk při každém nasazení:

  * `of-service.validate` — odmítne nasazení služby, která není v §1 SPEC.md,
    a odmítne vypínací okno kratší než OF_SHUTDOWN_GRACE_SECONDS.
  * `of-service.addressEnv` — poskládá adresní proměnné podle grafu §1.1 a
    NIC navíc. Hrana, která v grafu není, se do prostředí nedostane.
  * `of-service.databaseUrl` — sestaví OF_DATABASE_URL se search_path
    vlastnícího schématu; služba bez schématu ji nedostane vůbec.
=============================================================================
*/}}

{{/* Základní jméno. Vždycky jméno služby ze §1 — žádné .Release.Name, aby
     se dvě instalace téhož chartu nerozešly v adresách. */}}
{{- define "of-service.name" -}}
{{- required "service.name je povinné a musí být jméno ze §1 SPEC.md" .Values.service.name -}}
{{- end -}}

{{- define "of-service.fullname" -}}
{{- include "of-service.name" . -}}
{{- end -}}

{{- define "of-service.labels" -}}
app.kubernetes.io/name: {{ include "of-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: orbitalfreight
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
orbitalfreight.net/restart-wave: {{ .Values.service.restartWave | quote }}
{{- if .Values.service.language }}
orbitalfreight.net/language: {{ .Values.service.language }}
{{- end }}
{{- end -}}

{{- define "of-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "of-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "of-service.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s/%s/%s:%s" .Values.image.registry .Values.image.repository (include "of-service.name" .) $tag -}}
{{- end -}}

{{/*
Katalog čtrnácti služeb ze §1 SPEC.md. Slouží ke dvěma věcem: ověření, že
nasazovaná služba vůbec existuje, a k překladu jména cíle na adresní proměnnou
podle §5. Rozšiřovat ho znamená nejdřív editovat SPEC.md — služba, která tam
není, podle pravidla 1 v §7 neexistuje.
*/}}
{{- define "of-service.catalogue" -}}
identity-service: {http: 8081, grpc: 9081, addrVar: OF_IDENTITY_GRPC_ADDR}
fleet-service: {http: 8082, grpc: 9082, addrVar: OF_FLEET_BASE_URL}
container-registry: {http: 8083, grpc: 9083, addrVar: OF_CONTAINER_REGISTRY_GRPC_ADDR}
telemetry-ingest: {http: 8084, grpc: 9084, addrVar: null}
routing-service: {http: 8085, grpc: null, addrVar: OF_ROUTING_BASE_URL}
geo-service: {http: 8086, grpc: 9086, addrVar: OF_GEO_GRPC_ADDR}
customs-service: {http: 8087, grpc: null, addrVar: OF_CUSTOMS_BASE_URL}
billing-service: {http: 8088, grpc: null, addrVar: OF_BILLING_BASE_URL}
document-service: {http: 8089, grpc: null, addrVar: OF_DOCUMENT_BASE_URL}
notification-service: {http: 8090, grpc: null, addrVar: null}
partner-portal-api: {http: 8091, grpc: null, addrVar: null}
audit-ledger: {http: 8092, grpc: 9092, addrVar: OF_AUDIT_LEDGER_GRPC_ADDR}
analytics-pipeline: {http: 8093, grpc: null, addrVar: OF_ANALYTICS_BASE_URL}
reconciliation-service: {http: 8094, grpc: null, addrVar: null}
{{- end -}}

{{/*
Kontroly, které mají nasazení zastavit dřív, než se pod vůbec naplánuje.
Obojí je chyba, která se za běhu projeví pozdě a nejasně: neznámá služba
jako 404 z DNS uvnitř clusteru, krátké vypínací okno jako událost, která se
publikovala až po restartu.
*/}}
{{- define "of-service.validate" -}}
{{- $catalogue := include "of-service.catalogue" . | fromYaml -}}
{{- $name := include "of-service.name" . -}}
{{- if not (hasKey $catalogue $name) -}}
{{- fail (printf "sluzba %q neni v §1 SPEC.md; katalog: %s" $name (keys $catalogue | sortAlpha | join ", ")) -}}
{{- end -}}
{{- $expected := index $catalogue $name -}}
{{- if ne (int .Values.service.httpPort) (int $expected.http) -}}
{{- fail (printf "%s ma podle §1 SPEC.md HTTP port %d, hodnoty rikaji %d" $name (int $expected.http) (int .Values.service.httpPort)) -}}
{{- end -}}
{{- $grace := int (default 25 (get .Values.env "OF_SHUTDOWN_GRACE_SECONDS")) -}}
{{- if le (int .Values.terminationGracePeriodSeconds) $grace -}}
{{- fail (printf "terminationGracePeriodSeconds (%d) musi byt nad OF_SHUTDOWN_GRACE_SECONDS (%d), jinak se ustrihne relay z platform.outbox_messages" (int .Values.terminationGracePeriodSeconds) $grace) -}}
{{- end -}}
{{- end -}}

{{/*
Adresní proměnné podle §1.1. Vypisuje jen cíle uvedené v `outbound`; cokoli
dalšího by byla nová hrana v grafu, a ty se přidávají editací SPEC.md, ne
souboru hodnot.
*/}}
{{- define "of-service.addressEnv" -}}
{{- $catalogue := include "of-service.catalogue" . | fromYaml -}}
{{- range .Values.outbound }}
{{- $target := index $catalogue . -}}
{{- if not $target -}}
{{- fail (printf "cil %q neni v §1 SPEC.md" .) -}}
{{- end }}
{{- if not $target.addrVar -}}
{{- fail (printf "na %q se podle §1.1 SPEC.md synchronne nevola; udalost misto volani" .) -}}
{{- end }}
- name: {{ $target.addrVar }}
{{- if hasPrefix "OF_" $target.addrVar }}
  valueFrom:
    configMapKeyRef:
      name: of-service-addresses
      key: {{ $target.addrVar }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
OF_DATABASE_URL se search_path vlastnícího schématu (§2). Služba bez vlastního
schématu — partner-portal-api — ji nedostane: data si bere přes API tří
služeb a přímý přístup do cizího schématu zakazuje pravidlo 2 v §7.

OF_DB_PASSWORD je jediná proměnná OF_*, kterou §5 SPEC.md nezná a která se
přesto nastavuje. Je to vstup pro $(VAR) rozvoj v kubeletu, ne konfigurace
služby; ops/validate-env.py ji má na výjimce. Další takovou výjimku nepřidávat.
*/}}
{{- define "of-service.databaseUrl" -}}
{{- if .Values.service.schema -}}
- name: OF_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: of-database-passwords
      key: {{ include "of-service.name" . }}
- name: OF_DATABASE_URL
  value: postgres://{{ include "of-service.name" . | replace "-" "_" }}:$(OF_DB_PASSWORD)@pg-primary.orbitalfreight.svc.cluster.local:5432/orbitalfreight?search_path={{ .Values.service.schema }}&application_name={{ include "of-service.name" . }}&sslmode=verify-full
{{- end -}}
{{- end -}}

{{/* Anotace, která vynutí restart podů při změně ConfigMapy služby. */}}
{{- define "of-service.configChecksum" -}}
{{- include (print $.Template.BasePath "/configmap.yaml") . | sha256sum -}}
{{- end -}}
