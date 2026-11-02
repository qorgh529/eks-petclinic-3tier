#!/usr/bin/env bash
# Install cluster add-ons and apply all manifests in dependency order.
# Prereqs: infra/aws/provision-aws-resources.sh (all phases) and scripts/build-and-push.sh.
set -euo pipefail
# The opening split is a per-run choice: the command line wins over (usually empty) .env values.
caller_stable="${STABLE_WEIGHT:-}" caller_canary="${CANARY_WEIGHT:-}"
. "$(dirname "$0")/lib.sh"
STABLE_WEIGHT="${caller_stable:-${STABLE_WEIGHT:-}}" CANARY_WEIGHT="${caller_canary:-${CANARY_WEIGHT:-}}"

require AWS_REGION AWS_ACCOUNT_ID EKS_CLUSTER_NAME VPC_ID PUBLIC_SUBNET_A_ID PUBLIC_SUBNET_C_ID \
  DOMAIN_NAME ROUTE53_HOSTED_ZONE_ID ACM_CERTIFICATE_ARN WAF_WEB_ACL_ARN \
  ECR_WEB_REPOSITORY_URI ECR_WAS_REPOSITORY_URI STABLE_IMAGE_TAG CANARY_IMAGE_TAG \
  RDS_SECRET_NAME RDS_APP_SECRET_NAME RDS_BACKUP_SECRET_NAME GRAFANA_ADMIN_SECRET_NAME PROMETHEUS_SERVER_URL CW_LOG_GROUP_NAME BACKUP_S3_BUCKET_NAME \
  ALERTMANAGER_WEBHOOK_SECRET_NAME TEMPO_S3_BUCKET_NAME
export OTEL_TRACES_SAMPLER_ARG="${OTEL_TRACES_SAMPLER_ARG:-0.1}" OTEL_DEPLOYMENT_ENVIRONMENT="${OTEL_DEPLOYMENT_ENVIRONMENT:-production}"
# Rendered into manifests: a sampler ratio in [0, 1], an attribute value without ',' '=' or spaces,
# and the same retention days as the S3 lifecycle (provision-aws-resources.sh).
[[ "$OTEL_TRACES_SAMPLER_ARG" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] \
  || { echo "OTEL_TRACES_SAMPLER_ARG must be a number from 0 to 1 (got $OTEL_TRACES_SAMPLER_ARG)" >&2; exit 1; }
[[ "$OTEL_DEPLOYMENT_ENVIRONMENT" =~ ^[A-Za-z0-9._-]+$ ]] \
  || { echo "OTEL_DEPLOYMENT_ENVIRONMENT may only contain letters, digits, . _ -" >&2; exit 1; }
[[ "${TEMPO_RETENTION_DAYS:-14}" =~ ^[1-9][0-9]*$ ]] || { echo "TEMPO_RETENTION_DAYS must be a positive integer" >&2; exit 1; }
export TEMPO_RETENTION_HOURS="$(( ${TEMPO_RETENTION_DAYS:-14} * 24 ))h"

# Split opened after the canary check (Q8: chosen per release risk). Checked before anything changes.
OPEN_STABLE="${STABLE_WEIGHT:-90}" OPEN_CANARY="${CANARY_WEIGHT:-10}"
check_weights "$OPEN_STABLE" "$OPEN_CANARY"

"$ROOT/scripts/validate-manifests.sh"
# Stop before anything changes rather than publish /grafana or /was to every IP.
staff_waf_ready || { echo "WAF WebACL has no /grafana + /was allow-list rule at priority 0:" \
  "run ./infra/aws/provision-aws-resources.sh grafana-waf first" >&2; exit 1; }

K="$ROOT/k8s"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"

# Stable and canary share manifests, so a new STABLE_IMAGE_TAG reaches stable users before the canary
# check below. Changing it must be a deliberate promotion (PROMOTE_STABLE=1), normally to the tag that
# already passed as CANARY_IMAGE_TAG. A first deploy (no stable Deployment yet) needs no flag.
for d in was-stable web; do
  cur=$(kubectl -n petclinic get deploy "$d" --ignore-not-found -o jsonpath='{.spec.template.spec.containers[0].image}')
  if [ -n "$cur" ] && [ "${cur##*:}" != "$STABLE_IMAGE_TAG" ] && [ "${PROMOTE_STABLE:-}" != 1 ]; then
    echo "deploy/$d runs ${cur##*:} but STABLE_IMAGE_TAG is $STABLE_IMAGE_TAG: try new images as CANARY_IMAGE_TAG," \
      "then promote with PROMOTE_STABLE=1" >&2
    exit 1
  fi
done

# Placement for cluster controllers: ng-critical only.
CRITICAL=$(mktemp)
trap 'rm -f "$CRITICAL"' EXIT
cat > "$CRITICAL" <<'EOF'
nodeSelector:
  workload-tier: critical
tolerations:
  - { key: node-role, operator: Equal, value: critical, effect: NoSchedule }
EOF

echo "== Namespaces, StorageClass, Gateway API CRDs"
kubectl apply -f "$K/base/namespace.yaml"
kubectl apply -f "$K/base"
# v1.6.3 is the Gateway API version NGF 2.8.0 supports; server-side apply (CRDs exceed the client-side annotation limit).
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml

echo "== Helm repos"
helm repo add eks https://aws.github.io/eks-charts
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server
helm repo add kedacore https://kedacore.github.io/charts
helm repo add external-secrets https://charts.external-secrets.io
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update

echo "== Controllers on ng-critical (SAs with IRSA are created by eksctl)"
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 3.6.1 -n kube-system -f "$CRITICAL" \
  --set clusterName="$EKS_CLUSTER_NAME" --set region="$AWS_REGION" --set vpcId="$VPC_ID" \
  --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller \
  --set keepTLSSecret=true --wait
# Its mutating webhook intercepts every Service: --wait keeps the next chart from racing the pods, and
# keepTLSSecret stops a re-run from issuing a new webhook CA that the running pods do not serve.

# Resource Metrics API (metrics.k8s.io) for the web CPU HPA; EKS does not ship it.
helm upgrade --install metrics-server metrics-server/metrics-server \
  --version 3.14.0 -n kube-system -f "$CRITICAL"

# The karpenter chart only installs CRDs on first install; karpenter-crd keeps them current on upgrades.
helm upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd \
  --version 1.15.0 -n kube-system
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.15.0 -n kube-system -f "$CRITICAL" \
  --set settings.clusterName="$EKS_CLUSTER_NAME" \
  --set-json "controller.env=[{\"name\":\"AWS_REGION\",\"value\":\"$AWS_REGION\"}]" \
  --set serviceAccount.create=false --set serviceAccount.name=karpenter

helm upgrade --install external-secrets external-secrets/external-secrets \
  --version 2.13.0 -n external-secrets -f "$CRITICAL" \
  --set-json 'webhook.nodeSelector={"workload-tier":"critical"}' \
  --set-json 'webhook.tolerations=[{"key":"node-role","operator":"Equal","value":"critical","effect":"NoSchedule"}]' \
  --set-json 'certController.nodeSelector={"workload-tier":"critical"}' \
  --set-json 'certController.tolerations=[{"key":"node-role","operator":"Equal","value":"critical","effect":"NoSchedule"}]' \
  --set serviceAccount.create=false --set serviceAccount.name=external-secrets --wait

# Installs the Instrumentation CRD and the injection webhook; must be up before the was pods are created.
helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --version 0.105.0 -n opentelemetry-operator-system -f "$K/tracing/otel-operator-values.yaml" --wait

echo "== Karpenter np-app NodePool"
render_all "$ROOT/infra/karpenter" | kubectl apply -f -

echo "== NGF on np-app: control plane (2 replicas) + per-Gateway data plane petclinic-gateway-nginx"
# NGF 2.x provisions the data plane (Deployment + ClusterIP Service + PDB) when the Gateway is applied;
# the ALB targets its pod IPs. 2 replicas across AZs, minAvailable 1 during drains/consolidation.
helm upgrade --install nginx-gateway oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --version 2.8.0 -n nginx-gateway --set fullnameOverride=nginx-gateway \
  --set nginxGateway.replicas=2 \
  --set-json 'nginxGateway.nodeSelector={"workload-tier":"app"}' \
  --set-json 'nginxGateway.topologySpreadConstraints=[{"maxSkew":1,"topologyKey":"topology.kubernetes.io/zone","whenUnsatisfiable":"DoNotSchedule","labelSelector":{"matchLabels":{"app.kubernetes.io/name":"nginx-gateway-fabric","app.kubernetes.io/instance":"nginx-gateway"}}}]' \
  --set nginx.replicas=2 --set nginx.service.type=ClusterIP --set nginx.podDisruptionBudget.enable=true \
  --set-json 'nginx.pod.nodeSelector={"workload-tier":"app"}' \
  --set-json 'nginx.pod.topologySpreadConstraints=[{"maxSkew":1,"topologyKey":"topology.kubernetes.io/zone","whenUnsatisfiable":"DoNotSchedule","labelSelector":{"matchLabels":{"app.kubernetes.io/name":"petclinic-gateway-nginx"}}}]' \
  --wait

echo "== Secrets (ESO)"
render_all "$K/secrets" "$K/monitoring/externalsecret-grafana.yaml" "$K/monitoring/externalsecret-alertmanager.yaml" | kubectl apply -f -
kubectl -n petclinic wait --for=condition=Ready externalsecret/petclinic-rds-admin externalsecret/petclinic-rds externalsecret/petclinic-rds-backup --timeout=120s
kubectl -n monitoring wait --for=condition=Ready externalsecret/grafana-admin externalsecret/alertmanager-webhook --timeout=120s

echo "== Monitoring (ng-platform) and logging (all nodes)"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 92.11.0 -n monitoring -f <(render "$K/monitoring/kube-prometheus-values.yaml") --wait
kubectl apply -f "$K/monitoring/servicemonitor-petclinic.yaml" -f "$K/monitoring/networkpolicy-prometheus.yaml" \
  -f "$K/monitoring/networkpolicy-alertmanager.yaml" -f "$K/monitoring/prometheusrule-petclinic.yaml" \
  -f "$K/monitoring/networkpolicy-grafana.yaml" -f "$K/monitoring/referencegrant-grafana.yaml"

echo "== Tracing (ng-platform): Tempo (S3 via IRSA SA monitoring/tempo) + OTel collector"
kubectl apply -f "$K/tracing/networkpolicy-tracing.yaml" -f "$K/monitoring/dashboard-apm-tracing.yaml"
helm upgrade --install tempo grafana-community/tempo \
  --version 3.2.1 -n monitoring -f <(render "$K/tracing/tempo-values.yaml") --wait
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --version 0.116.0 -n monitoring -f <(render "$K/tracing/otel-collector-values.yaml") --wait
# After the monitoring stack: the operator-metrics ServiceMonitor needs its CRD (PetClinicKedaMetricsError).
helm upgrade --install keda kedacore/keda --version 2.21.0 -n keda -f "$CRITICAL" \
  --set prometheus.operator.enabled=true --set prometheus.operator.serviceMonitor.enabled=true
helm upgrade --install aws-for-fluent-bit eks/aws-for-fluent-bit \
  --version 0.2.0 -n amazon-cloudwatch -f <(render "$K/logging/fluent-bit-values.yaml")

echo "== DB init Job + backup CronJob"
kubectl -n petclinic create configmap petclinic-db-scripts \
  --from-file="$ROOT/app/src/main/resources/db/mysql/schema.sql" \
  --from-file="$ROOT/app/src/main/resources/db/mysql/data.sql" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n petclinic delete job db-init --ignore-not-found
render_all "$K/jobs" | kubectl apply -f -
kubectl -n petclinic wait --for=condition=Complete job/db-init --timeout=300s

echo "== Routing: close canary (100/0) before any workload changes"
# A re-deploy may start from 90/10; the new canary pods must not see user traffic before the check below.
STABLE_WEIGHT=100 CANARY_WEIGHT=0 render_all "$K/gateway" | kubectl apply -f -
wait_route_accepted

echo "== Workloads (canary held at 0% until it passes the check below)"
# WAS before web (docs/features/landing-page/design.md Q7): a /was WAS also serves / (rewrite), so it
# fits an old web, but a new web only proxies /was/, which an old WAS does not have.
# Instrumentation first: pods created before it exists start without the agent.
render "$K/was/instrumentation.yaml" | kubectl apply -f -
render_all "$K/was" | kubectl apply -f -
kubectl -n petclinic rollout status deploy/was-stable --timeout=600s
kubectl -n petclinic rollout status deploy/was-canary --timeout=600s
render_all "$K/web" | kubectl apply -f -
kubectl -n petclinic rollout status deploy/web --timeout=300s
kubectl -n petclinic rollout status deploy/web-canary --timeout=300s

echo "== Route 53 alias -> ALB"
alb=""
for _ in $(seq 1 60); do
  alb=$(kubectl -n nginx-gateway get ingress petclinic-alb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  [ -n "$alb" ] && break
  sleep 10
done
[ -n "$alb" ] || { echo "ALB hostname not assigned" >&2; exit 1; }
alb_zone=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancers[?DNSName=='$alb'].CanonicalHostedZoneId" --output text)
aws route53 change-resource-record-sets --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" --change-batch \
  "$(jq -n --arg name "$DOMAIN_NAME" --arg zone "$alb_zone" --arg alb "$alb" '{Changes: [{Action: "UPSERT",
      ResourceRecordSet: {Name: $name, Type: "A",
        AliasTarget: {HostedZoneId: $zone, DNSName: $alb, EvaluateTargetHealth: true}}}]}')" >/dev/null

# End-to-end canary check: web-canary /healthz does not touch WAS, so hit a page served by was-canary.
# /was is behind the WAF allow-list, which the deploy host may not be in: that page is fetched through
# web-canary's own Nginx (web-canary -> was-canary), and the landing page through the ALB, where
# X-Canary pins it to web-canary. --connect-to goes straight to the ALB (no wait on DNS) while TLS
# still validates against DOMAIN_NAME.
echo "== Canary path check (X-Canary: always)"
ok=""
for _ in $(seq 1 30); do
  if kubectl -n petclinic exec deploy/web-canary -c nginx -- \
      wget -q -O /dev/null "http://127.0.0.1:8080/was/owners?lastName=" \
    && curl -fsS -o /dev/null --max-time 10 --connect-to "$DOMAIN_NAME:443:$alb:443" \
      -H "X-Canary: always" "https://$DOMAIN_NAME/"; then ok=1; break; fi
  sleep 10
done
[ -n "$ok" ] || { echo "canary path check failed: /was/owners via web-canary or https://$DOMAIN_NAME/ via X-Canary: always; canary stays at 0%" >&2; exit 1; }

echo "== Open canary: $OPEN_STABLE/$OPEN_CANARY (later changes: scripts/set-canary-weight.sh)"
apply_route_weights "$OPEN_STABLE" "$OPEN_CANARY"

echo "Done: https://$DOMAIN_NAME"
