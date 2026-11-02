# Sourced by scripts/*.sh. Loads .env and provides require/render.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

require() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || { echo "missing required env: $v" >&2; exit 1; }
  done
}

# Only these are substituted; anything else (e.g. $RDS_HOST inside container commands) is left alone.
TEMPLATE_VARS='${AWS_REGION} ${AWS_ACCOUNT_ID} ${EKS_CLUSTER_NAME} ${PUBLIC_SUBNET_A_ID} ${PUBLIC_SUBNET_C_ID}
${DOMAIN_NAME} ${ACM_CERTIFICATE_ARN} ${WAF_WEB_ACL_ARN} ${ECR_WEB_REPOSITORY_URI} ${ECR_WAS_REPOSITORY_URI}
${IMAGE_TAG} ${STABLE_IMAGE_TAG} ${CANARY_IMAGE_TAG} ${STABLE_WEIGHT} ${CANARY_WEIGHT} ${RDS_SECRET_NAME} ${RDS_APP_SECRET_NAME} ${RDS_BACKUP_SECRET_NAME} ${GRAFANA_ADMIN_SECRET_NAME} ${PROMETHEUS_SERVER_URL} ${CW_LOG_GROUP_NAME} ${ALERTMANAGER_WEBHOOK_SECRET_NAME}
${BACKUP_S3_BUCKET_NAME} ${TEMPO_S3_BUCKET_NAME} ${TEMPO_RETENTION_HOURS} ${OTEL_TRACES_SAMPLER_ARG} ${OTEL_DEPLOYMENT_ENVIRONMENT}
${CODEBUILD_PROJECT_NAME} ${CODEBUILD_S3_BUCKET_NAME}'

render() { envsubst "$TEMPLATE_VARS" < "$1"; }

# Canary split: integers 0-100 that add up to 100.
check_weights() {
  [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] && (( $1 + $2 == 100 )) \
    || { echo "STABLE_WEIGHT/CANARY_WEIGHT must be integers 0-100 summing to 100 (got $1/$2)" >&2; exit 1; }
}

# Apply HTTPRoute petclinic with the given weights and wait until NGF accepts that generation
# (Accepted alone may be left over from the previous generation).
apply_route_weights() {
  STABLE_WEIGHT="$1" CANARY_WEIGHT="$2" render "$ROOT/k8s/gateway/httproute-canary.yaml" | kubectl apply -f -
  wait_route_accepted
}

wait_route_accepted() {
  local gen st _
  gen=$(kubectl -n petclinic get httproute petclinic -o jsonpath='{.metadata.generation}')
  for _ in $(seq 1 30); do
    st=$(kubectl -n petclinic get httproute petclinic \
      -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}/{.status.parents[0].conditions[?(@.type=="Accepted")].observedGeneration}')
    [ "$st" = "True/$gen" ] && return 0
    sleep 2
  done
  echo "HTTPRoute petclinic generation $gen not accepted by the gateway" >&2
  exit 1
}

# /grafana (k8s/gateway/httproute-grafana.yaml) and the staff app at /was may only go live behind the
# WAF allow-list: the WebACL's first rule must be BlockUnauthorizedStaffAccess, blocking both paths (or
# the whole site, during a rollback and the re-deploy after it) for IPs outside its IP set (infra/aws/provision-aws-resources.sh grafana-waf,
# docs/features/grafana-public-path/design.md, docs/features/landing-page/design.md).
staff_waf_ready() {
  local acl_id="${WAF_WEB_ACL_ARN##*/}" acl_name acl
  acl_name=$(aws wafv2 list-web-acls --scope REGIONAL --query "WebACLs[?Id=='$acl_id'].Name | [0]" --output text) \
    && [ -n "$acl_name" ] && [ "$acl_name" != None ] || return 1
  acl=$(aws wafv2 get-web-acl --scope REGIONAL --name "$acl_name" --id "$acl_id" --output json) || return 1
  # Structure, not just names: AND(paths, NOT in our IP set), where paths is OR(starts with /grafana,
  # with /was) or, in the site-wide scope used around a rollback (STAFF_WAF_SCOPE=all), NOT(starts with
  # /resources/); each path after decode, normalise, lowercase in that order. SearchString is a blob,
  # which CLI v2 prints base64-encoded ("/grafana" = L2dyYWZhbmE=, "/was" = L3dhcw==,
  # "/resources/" = L3Jlc291cmNlcy8=).
  jq -e --arg set "/${EKS_CLUSTER_NAME}-grafana-allowed-ips/" '
    def match($raw; $b64): .ByteMatchStatement | . != null and .FieldToMatch == {UriPath: {}}
      and .PositionalConstraint == "STARTS_WITH" and (.SearchString == $b64 or .SearchString == $raw)
      and (.TextTransformations | sort_by(.Priority) | map(.Type)) == ["URL_DECODE", "NORMALIZE_PATH", "LOWERCASE"];
    def path($raw; $b64): any(.[]; match($raw; $b64));
    .WebACL.Rules | min_by(.Priority)
    | .Priority == 0 and .Name == "BlockUnauthorizedStaffAccess" and (.Action | keys == ["Block"])
      and (.Statement | keys == ["AndStatement"])
      and (.Statement.AndStatement.Statements | length == 2
        and any(.[]; (.OrStatement.Statements // [] | path("/grafana"; "L2dyYWZhbmE=") and path("/was"; "L3dhcw=="))
          or (.NotStatement.Statement // {} | match("/resources/"; "L3Jlc291cmNlcy8=")))
        and any(.[]; .NotStatement.Statement.IPSetReferenceStatement.ARN // "" | contains($set)))' \
    <<<"$acl" >/dev/null
}

# Render every *.yaml in the given dirs/files as one multi-document stream.
render_all() {
  local f
  for f in $(find "$@" -name '*.yaml' | sort); do
    render "$f"
    printf '\n---\n'
  done
}
