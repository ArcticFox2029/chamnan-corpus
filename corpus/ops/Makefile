# المدخل الوحيد لكل ما يفعله فريق التشغيل بيده: بناء أداة ofctl، فحص ما قبل النشر، طرح خدمة،
# تطبيق تقدير إقليم، وفتح أدلّة الحوادث. الغرض أن يكون لكل عملية اسم واحد يُكتب في تقرير
# الحادثة ويُعاد تنفيذه حرفياً بعد ستّة أشهر، بدل سطر أنبوب طويل يُنسخ من ذاكرة أحدهم.
#
# كل هدف هنا يفشل بصوت عالٍ إن نقص متغيّر بيئة. الصمت أسوأ من الفشل في هذا المجلّد: هدف
# ينشر بنصف إعداد ينتهي بجرابات صحيّة تكتب في المكان الخطأ.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -o errexit -o nounset -o pipefail -c
.DEFAULT_GOAL := help

NIM         ?= nim
NIMBLE      ?= nimble
TERRAFORM   ?= terraform
KUBECTL     ?= kubectl
KUSTOMIZE   ?= kustomize

OF_ENVIRONMENT ?= local
OF_REGION_CODE ?= eu-west
IMAGE_TAG      ?= stable
NAMESPACE      ?= orbitalfreight

# مساحة عمل Terraform واحدة لكل إقليم. الأقاليم في §0.6 مقفلة، ومساحة عمل باسم آخر تعني
# حالة يتيمة لا يديرها أحد.
TF_DIR      := terraform
TF_VARFILE  := $(TF_DIR)/env/$(OF_ENVIRONMENT)-$(OF_REGION_CODE).tfvars

SERVICES := identity-service fleet-service container-registry telemetry-ingest \
            routing-service geo-service customs-service billing-service \
            document-service notification-service partner-portal-api \
            audit-ledger analytics-pipeline reconciliation-service

.PHONY: help
help: ## يعرض هذه القائمة
	@grep -hE '^[a-zA-Z0-9_./-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# ── أداة المشغّلين ──────────────────────────────────────────────────────────────────────

.PHONY: build
build: ## يبني ofctl للتطوير المحلّي
	cd cli && $(NIMBLE) --accept build

.PHONY: build-release
build-release: ## يبني ثنائياً ساكناً للنشر داخل صورة الأدوات
	cd cli && $(NIMBLE) --offline --accept release

.PHONY: check
check: ## فحص نحوي وثابت بلا ربط
	cd cli && $(NIM) check --hints:off src/ofctl.nim

.PHONY: test
test: ## يشغّل اختبارات الأداة
	cd cli && $(NIMBLE) --accept test

.PHONY: lint
lint: ## shellcheck على كل سكربتات النشر والحوادث
	shellcheck --external-sources --severity=warning lib/*.sh deploy/*.sh incident/*.sh

# ── فحوص ما قبل النشر ──────────────────────────────────────────────────────────────────

.PHONY: validate-env
validate-env: ## يطابق مجموعة متغيّرات OF_* المضبوطة مع §5 لكل الخدمات الأربع عشرة
	@for service in $(SERVICES); do \
	  echo "→ $$service"; \
	  python3 validate-env.py --service "$$service" --environment "$(OF_ENVIRONMENT)" --strict; \
	done

.PHONY: preflight
preflight: ## فحص ما قبل نشر خدمة واحدة — SERVICE=<name> IMAGE_TAG=<tag>
	@test -n "$(SERVICE)" || { echo "SERVICE مطلوب"; exit 64; }
	OF_ENVIRONMENT=$(OF_ENVIRONMENT) OF_REGION_CODE=$(OF_REGION_CODE) \
	  ./deploy/preflight.sh "$(SERVICE)" "$(IMAGE_TAG)"

.PHONY: doctor
doctor: ## مسح جاهزية الأربع عشرة: /healthz و/readyz و/version وتأخّر صندوق الصادر
	./cli/bin/ofctl health doctor --environment=$(OF_ENVIRONMENT) --format=table

# ── قاعدة البيانات ─────────────────────────────────────────────────────────────────────

.PHONY: migrate
migrate: ## يطبّق ترحيلات db/ حتى الأحدث؛ VERSION=<n> للتوقّف عند إصدار
	OF_ENVIRONMENT=$(OF_ENVIRONMENT) OF_REGION_CODE=$(OF_REGION_CODE) \
	  ./deploy/migrate.sh $(or $(VERSION),latest)

.PHONY: migrate-status
migrate-status: ## يقارن الترحيل المطبَّق بما تتوقّعه كل خدمة على /version
	@# أرقام مختلفة بعد انتهاء الطرح تعني نشراً نصفياً: خدمة تتوقّع مخطّطاً وأخرى تكتب بغيره.
	./cli/bin/ofctl health doctor --format=json \
	  | jq -r '.[] | "\(.service)\t\(.version)\tmigration=\(.migration)"' \
	  | column -t

# ── النشر ──────────────────────────────────────────────────────────────────────────────

.PHONY: rollout
rollout: preflight ## طرح تدريجي بكناري ومراقبة — SERVICE=<name> IMAGE_TAG=<tag>
	OF_ENVIRONMENT=$(OF_ENVIRONMENT) OF_REGION_CODE=$(OF_REGION_CODE) \
	  ./deploy/rollout.sh "$(SERVICE)" "$(IMAGE_TAG)"

.PHONY: rollback
rollback: ## تراجع فوري إلى النسخة السابقة — SERVICE=<name>
	$(KUBECTL) -n $(NAMESPACE) rollout undo deploy/$(SERVICE)
	$(KUBECTL) -n $(NAMESPACE) rollout status deploy/$(SERVICE) --timeout=5m

# ── التقدير ────────────────────────────────────────────────────────────────────────────

.PHONY: tf-init
tf-init: ## يهيّئ Terraform لمساحة عمل الإقليم
	cd $(TF_DIR) && $(TERRAFORM) init -reconfigure \
	  -backend-config="key=estate/$(OF_REGION_CODE)/terraform.tfstate"
	cd $(TF_DIR) && $(TERRAFORM) workspace select $(OF_REGION_CODE) \
	  || $(TERRAFORM) workspace new $(OF_REGION_CODE)

.PHONY: tf-plan
tf-plan: tf-init ## خطّة الإقليم؛ تُحفظ كي يُطبَّق ما رُوجع بالضبط لا ما أُعيد حسابه
	@test -f "$(TF_VARFILE)" || { echo "لا ملف قيم للزوج ($(OF_ENVIRONMENT), $(OF_REGION_CODE))"; exit 64; }
	cd $(TF_DIR) && $(TERRAFORM) plan \
	  -var-file="env/$(OF_ENVIRONMENT)-$(OF_REGION_CODE).tfvars" \
	  -var="image_tag=$(IMAGE_TAG)" \
	  -out="$(OF_REGION_CODE).tfplan"

.PHONY: tf-apply
tf-apply: ## يطبّق الخطّة المحفوظة وحدها — لا يعيد حساب شيء
	@test -f "$(TF_DIR)/$(OF_REGION_CODE).tfplan" || { echo "لا خطّة محفوظة؛ نفّذ tf-plan"; exit 64; }
	cd $(TF_DIR) && $(TERRAFORM) apply "$(OF_REGION_CODE).tfplan"
	rm -f "$(TF_DIR)/$(OF_REGION_CODE).tfplan"

.PHONY: tf-fmt
tf-fmt: ## تنسيق وتحقّق نحوي لكل وحدات HCL
	cd $(TF_DIR) && $(TERRAFORM) fmt -recursive -check
	cd $(TF_DIR) && $(TERRAFORM) validate

.PHONY: k8s-diff
k8s-diff: ## فرق طبقة الإقليم مقابل العنقود الحيّ قبل التطبيق
	$(KUSTOMIZE) build k8s/overlays/$(OF_ENVIRONMENT)-$(OF_REGION_CODE) \
	  | $(KUBECTL) diff -f - || true

.PHONY: k8s-apply
k8s-apply: ## يطبّق طبقة الإقليم — مساحة الأسماء والحصص وسياسات الشبكة والمهامّ المجدولة
	$(KUSTOMIZE) build k8s/overlays/$(OF_ENVIRONMENT)-$(OF_REGION_CODE) | $(KUBECTL) apply -f -

# ── الحوادث ────────────────────────────────────────────────────────────────────────────
# هذه الأهداف تقرأ ولا تكتب. لا واحد منها يعدّل صفّاً في قاعدة البيانات أو يغلق تنبيهاً؛
# القرار للمناوب، والسكربت يجمع الدليل ويعرض الخطوات.

.PHONY: incident-alert-storm
incident-alert-storm: ## فرز عاصفة تنبيهات telemetry — WINDOW=<minutes>
	OF_REGION_CODE=$(OF_REGION_CODE) ./incident/telemetry-alert-storm.sh $(or $(WINDOW),30)

.PHONY: incident-outbox
incident-outbox: ## يحدّد مُرحّل platform.outbox_messages المتوقّف وسببه
	./incident/outbox-backlog.sh

.PHONY: incident-ledger
incident-ledger: ## يتحقّق من سلسلة platform.audit_ledger_entries ويحدّد أول كسر — SUBJECT_TYPE=<type> للتضييق
	./incident/ledger-chain-break.sh $(SUBJECT_TYPE)

.PHONY: topics
topics: ## يعرض مواضيع §4 الستّة وتراكم كل مجموعة استهلاك عليها
	@for topic in of.identity.v1 of.freight.v1 of.telemetry.v1 of.customs.v1 of.billing.v1 of.platform.v1; do \
	  echo "── $$topic"; \
	  kafka-consumer-groups.sh --bootstrap-server "$(OF_KAFKA_BROKERS)" \
	    --describe --all-groups 2>/dev/null | grep -F "$$topic" || echo "  لا مستهلكين"; \
	done

.PHONY: dlq
dlq: ## يعدّ ما في قوائم الرسائل الميّتة الستّ — أي رقم غير صفر يستحقّ نظرة
	@for topic in of.identity.v1 of.freight.v1 of.telemetry.v1 of.customs.v1 of.billing.v1 of.platform.v1; do \
	  count=$$(kafka-run-class.sh kafka.tools.GetOffsetShell \
	    --bootstrap-server "$(OF_KAFKA_BROKERS)" --topic "$$topic.dlq" \
	    | awk -F: '{s += $$3} END {print s+0}'); \
	  printf '%-20s %s\n' "$$topic.dlq" "$$count"; \
	done

.PHONY: clean
clean: ## يحذف مخرجات البناء والخطط المحفوظة
	rm -rf cli/bin cli/nimcache
	rm -f $(TF_DIR)/*.tfplan
