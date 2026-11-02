#!/usr/bin/env bash
# Provision AWS resources around the EKS cluster. The VPC and its subnets are inputs (.env).
#
#   ./infra/aws/provision-aws-resources.sh vpc           # VPC, 6 subnets, IGW, route tables, NAT x2 (prints the .env lines)
#   ./infra/aws/provision-aws-resources.sh pre-cluster   # IAM, ECR, log group, backup/Tempo buckets, CodeBuild, WAF, ACM
#   ./infra/aws/provision-aws-resources.sh cluster       # eksctl create cluster + Karpenter discovery tags
#   ./infra/aws/provision-aws-resources.sh post-cluster  # RDS MySQL Multi-AZ + Secrets Manager secrets
#   ./infra/aws/provision-aws-resources.sh grafana-waf   # /grafana + /was IP allow-list (re-run when the IP changes)
#   STAFF_WAF_SCOPE=all ... grafana-waf                   # whole site behind the allow-list (before rolling back web)
#
# Idempotent: every step looks the resource up first and reuses (or updates) it, so a phase that
# stopped half-way can simply be run again. Existing resources are not reconfigured beyond what
# each step notes (e.g. an existing WAF WebACL or RDS instance keeps its settings).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

require() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || { echo "missing required env: $v" >&2; exit 1; }
  done
}

# Run an AWS call whose only acceptable failure is "already there" (matched by $1 in the error text).
tolerate() {
  local pattern=$1 out
  shift
  out=$("$@" 2>&1) && return 0
  grep -q "$pattern" <<<"$out" && return 0
  echo "$out" >&2
  return 1
}

random_password() {
  aws secretsmanager get-random-password --password-length 32 --exclude-punctuation \
    --query RandomPassword --output text
}

# Create a DB secret, or keep its password and refresh the connection fields.
# Passwords travel env -> jq -> stdin so they never appear in any process's argv.
upsert_db_secret() {
  local name=$1 user=$2 host=$3 current password
  if current=$(aws secretsmanager get-secret-value --secret-id "$name" --query SecretString --output text 2>/dev/null); then
    password=$(jq -r .password <<<"$current")
    PW="$password" jq -n --arg user "$user" --arg host "$host" --arg port "$RDS_PORT" --arg db "$RDS_DB_NAME" \
      '{username: $user, password: env.PW, host: $host, port: $port, dbname: $db}' \
      | aws secretsmanager put-secret-value --secret-id "$name" --secret-string file:///dev/stdin >/dev/null
  else
    password=$(random_password)
    PW="$password" jq -n --arg user "$user" --arg host "$host" --arg port "$RDS_PORT" --arg db "$RDS_DB_NAME" \
      '{username: $user, password: env.PW, host: $host, port: $port, dbname: $db}' \
      | aws secretsmanager create-secret --name "$name" --secret-string file:///dev/stdin >/dev/null
  fi
}

export AWS_DEFAULT_REGION="${AWS_REGION:-}"

# Network for the cluster (docs/features/vpc-provisioning/design.md). Everything is found by its
# Name tag inside petclinic-vpc and reused; a resource that exists with other settings (CIDR, AZ,
# route table association, IGW attachment) stops the run instead of being changed.
vpc() {
  # Subnet AZs are fixed to Seoul, so the region is too (a shell AWS_REGION=us-east-1 once built a VPC there).
  export AWS_REGION=ap-northeast-2 AWS_DEFAULT_REGION=ap-northeast-2
  local p=petclinic vpc_id cur igw rt_pub rt_db rt key name cidr az n
  local -A sub
  echo "== VPC $p-vpc (10.0.0.0/16, $AWS_REGION)"
  cur=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$p-vpc" "Name=tag:Project,Values=$p" \
    --query 'Vpcs[].[VpcId,CidrBlock]' --output text)
  n=$(grep -c . <<<"$cur" || true)
  if [ "$n" = 0 ]; then
    vpc_id=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications "$(vpc_tags vpc "$p-vpc")" \
      --query Vpc.VpcId --output text)
    aws ec2 wait vpc-available --vpc-ids "$vpc_id"
  elif [ "$n" = 1 ]; then
    read -r vpc_id cidr <<<"$cur"
    [ "$cidr" = 10.0.0.0/16 ] || { echo "$p-vpc $vpc_id is $cidr, not 10.0.0.0/16" >&2; exit 1; }
    echo "reusing $vpc_id"
  else
    echo "more than one VPC tagged $p-vpc: $(tr '\n\t' '  ' <<<"$cur")" >&2; exit 1
  fi
  aws ec2 modify-vpc-attribute --vpc-id "$vpc_id" --enable-dns-support '{"Value":true}'
  aws ec2 modify-vpc-attribute --vpc-id "$vpc_id" --enable-dns-hostnames '{"Value":true}'

  echo "== Subnets"
  # key name cidr az
  while read -r key name cidr az; do
    cur=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Name,Values=$name" \
      --query 'Subnets[].[SubnetId,CidrBlock,AvailabilityZone]' --output text)
    if [ -z "$cur" ]; then
      sub[$key]=$(aws ec2 create-subnet --vpc-id "$vpc_id" --cidr-block "$cidr" --availability-zone "$az" \
        --tag-specifications "$(vpc_tags subnet "$name")" --query Subnet.SubnetId --output text)
    else
      [ "$(cut -f2,3 <<<"$cur")" = "$cidr"$'\t'"$az" ] \
        || { echo "$name exists as $(cut -f2,3 <<<"$cur" | tr '\t' ' '), not $cidr $az" >&2; exit 1; }
      sub[$key]=$(cut -f1 <<<"$cur")
    fi
    echo "$name ${sub[$key]}"
  done <<EOF
PUBLIC_SUBNET_A_ID $p-public-2a 10.0.0.0/24 ap-northeast-2a
PUBLIC_SUBNET_C_ID $p-public-2c 10.0.1.0/24 ap-northeast-2c
APP_PRIVATE_SUBNET_A_ID $p-app-2a 10.0.16.0/20 ap-northeast-2a
APP_PRIVATE_SUBNET_C_ID $p-app-2c 10.0.32.0/20 ap-northeast-2c
DB_PRIVATE_SUBNET_A_ID $p-db-2a 10.0.48.0/24 ap-northeast-2a
DB_PRIVATE_SUBNET_C_ID $p-db-2c 10.0.49.0/24 ap-northeast-2c
EOF

  echo "== Internet gateway $p-igw"
  cur=$(aws ec2 describe-internet-gateways --filters "Name=tag:Name,Values=$p-igw" "Name=tag:Project,Values=$p" \
    --query 'InternetGateways[0].[InternetGatewayId,Attachments[0].VpcId]' --output text)
  read -r igw cur <<<"$cur"
  if [ -z "$igw" ] || [ "$igw" = None ]; then
    igw=$(aws ec2 create-internet-gateway --tag-specifications "$(vpc_tags internet-gateway "$p-igw")" \
      --query InternetGateway.InternetGatewayId --output text)
    cur=None
  fi
  case "$cur" in
    "$vpc_id") ;;
    None|"") aws ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc_id" ;;
    *) echo "$p-igw $igw is attached to $cur, not $vpc_id" >&2; exit 1 ;;
  esac

  echo "== Route tables (public -> IGW, app -> NAT in the same AZ, db: no internet route)"
  rt_pub=$(vpc_route_table "$vpc_id" "$p-rt-public")
  vpc_default_route "$rt_pub" --gateway-id "$igw"
  vpc_associate "$rt_pub" "${sub[PUBLIC_SUBNET_A_ID]}" "${sub[PUBLIC_SUBNET_C_ID]}"
  rt=$(vpc_route_table "$vpc_id" "$p-rt-app-2a"); vpc_associate "$rt" "${sub[APP_PRIVATE_SUBNET_A_ID]}"
  rt=$(vpc_route_table "$vpc_id" "$p-rt-app-2c"); vpc_associate "$rt" "${sub[APP_PRIVATE_SUBNET_C_ID]}"
  rt_db=$(vpc_route_table "$vpc_id" "$p-rt-db")
  # A reused table must still have no way out: the DB subnets are not attached to one that does.
  cur=$(aws ec2 describe-route-tables --route-table-ids "$rt_db" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].[GatewayId,NatGatewayId]" --output text)
  [ -z "$cur" ] || { echo "$p-rt-db $rt_db has a 0.0.0.0/0 route ($(tr '\t' ' ' <<<"$cur")): DB subnets must have none" >&2; exit 1; }
  vpc_associate "$rt_db" "${sub[DB_PRIVATE_SUBNET_A_ID]}" "${sub[DB_PRIVATE_SUBNET_C_ID]}"

  # EIP + NAT per AZ and the app route tables' 0.0.0.0/0, shared with the daily NAT start.
  "$ROOT/scripts/nat-start.sh"

  echo "== Add to .env:"
  echo "VPC_ID=$vpc_id"
  for key in PUBLIC_SUBNET_A_ID PUBLIC_SUBNET_C_ID APP_PRIVATE_SUBNET_A_ID APP_PRIVATE_SUBNET_C_ID \
             DB_PRIVATE_SUBNET_A_ID DB_PRIVATE_SUBNET_C_ID; do
    echo "$key=${sub[$key]}"
  done
}

vpc_tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=petclinic}]"; }

# Route table <name> in <vpc>, created when missing. Called as $(...), where set -e does not reach:
# a failed lookup must not read as "missing" (it would create a duplicate), so each call returns on failure.
vpc_route_table() {
  local id
  id=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$1" "Name=tag:Name,Values=$2" \
    --query 'RouteTables[0].RouteTableId' --output text) || return 1
  if [ -z "$id" ] || [ "$id" = None ]; then
    id=$(aws ec2 create-route-table --vpc-id "$1" --tag-specifications "$(vpc_tags route-table "$2")" \
      --query RouteTable.RouteTableId --output text) || return 1
  fi
  [ -n "$id" ] && [ "$id" != None ] || { echo "no route table id for $2" >&2; return 1; }
  echo "$id"
}

# Associate subnets with <rt>. A subnet already tied to another table is left alone and fails the run.
vpc_associate() {
  local rt=$1 s cur; shift
  for s in "$@"; do
    cur=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$s" \
      --query 'RouteTables[0].RouteTableId' --output text)
    case "$cur" in
      "$rt") ;;
      None|"") aws ec2 associate-route-table --route-table-id "$rt" --subnet-id "$s" >/dev/null ;;
      *) echo "subnet $s is associated with $cur, not $rt" >&2; exit 1 ;;
    esac
  done
}

# 0.0.0.0/0 in <rt> -> <--gateway-id|--nat-gateway-id> <id>: create, keep, or repoint (e.g. at a deleted NAT).
vpc_default_route() {
  local rt=$1 flag=$2 target=$3 cur
  cur=$(aws ec2 describe-route-tables --route-table-ids "$rt" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].[GatewayId,NatGatewayId]" --output text)
  if [ -z "$cur" ]; then
    aws ec2 create-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 "$flag" "$target" >/dev/null
  elif ! grep -qw -- "$target" <<<"$cur"; then
    aws ec2 replace-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 "$flag" "$target"
  fi
}

pre_cluster() {
  require AWS_REGION AWS_ACCOUNT_ID EKS_CLUSTER_NAME CW_LOG_GROUP_NAME BACKUP_S3_BUCKET_NAME TEMPO_S3_BUCKET_NAME DOMAIN_NAME ROUTE53_HOSTED_ZONE_ID
  # The Tempo lifecycle deletes objects: it must never land on the backup bucket.
  [ "$TEMPO_S3_BUCKET_NAME" != "$BACKUP_S3_BUCKET_NAME" ] \
    || { echo "TEMPO_S3_BUCKET_NAME must differ from BACKUP_S3_BUCKET_NAME" >&2; exit 1; }
  # The CodeBuild bucket gets a 1-day expiry and SSE-S3, and the build role may read it: never a shared bucket.
  export CODEBUILD_S3_BUCKET_NAME="${CODEBUILD_S3_BUCKET_NAME:-${EKS_CLUSTER_NAME}-codebuild-${AWS_ACCOUNT_ID}}"
  [ "$CODEBUILD_S3_BUCKET_NAME" != "$BACKUP_S3_BUCKET_NAME" ] && [ "$CODEBUILD_S3_BUCKET_NAME" != "$TEMPO_S3_BUCKET_NAME" ] \
    || { echo "CODEBUILD_S3_BUCKET_NAME must differ from BACKUP_S3_BUCKET_NAME and TEMPO_S3_BUCKET_NAME" >&2; exit 1; }
  local retention="${TEMPO_RETENTION_DAYS:-14}"
  [[ "$retention" =~ ^[1-9][0-9]*$ ]] || { echo "TEMPO_RETENTION_DAYS must be a positive integer" >&2; exit 1; }
  local dir="$ROOT/infra/aws/iam-policies" name arn doc v

  echo "== IAM policies (IRSA): create, or publish the current document as the default version"
  for name in lbc karpenter-controller eso fluent-bit db-backup tempo; do
    arn="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${EKS_CLUSTER_NAME}-${name}"
    doc=$(envsubst < "$dir/${name}-policy.json")
    if aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
      # IAM keeps at most 5 versions: drop the non-default ones before adding the new default.
      for v in $(aws iam list-policy-versions --policy-arn "$arn" \
          --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
        aws iam delete-policy-version --policy-arn "$arn" --version-id "$v"
      done
      aws iam create-policy-version --policy-arn "$arn" --policy-document "$doc" --set-as-default >/dev/null
    else
      aws iam create-policy --policy-name "${EKS_CLUSTER_NAME}-${name}" --policy-document "$doc" >/dev/null
    fi
  done

  echo "== Karpenter node role"
  local role="KarpenterNodeRole-${EKS_CLUSTER_NAME}"
  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    aws iam create-role --role-name "$role" \
      --assume-role-policy-document "file://$dir/karpenter-node-trust.json" >/dev/null
  fi
  for name in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly AmazonSSMManagedInstanceCore; do
    aws iam attach-role-policy --role-name "$role" --policy-arn "arn:aws:iam::aws:policy/$name"
  done

  echo "== ECR repositories"
  for name in petclinic-web petclinic-was; do
    aws ecr describe-repositories --repository-names "$name" \
        --query 'repositories[0].repositoryUri' --output text 2>/dev/null \
      || aws ecr create-repository --repository-name "$name" \
        --image-tag-mutability IMMUTABLE \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=KMS \
        --query repository.repositoryUri --output text
  done

  echo "== CloudWatch log group"
  tolerate ResourceAlreadyExistsException aws logs create-log-group --log-group-name "$CW_LOG_GROUP_NAME"
  aws logs put-retention-policy --log-group-name "$CW_LOG_GROUP_NAME" --retention-in-days 30

  echo "== Backup bucket (private, encrypted, versioned)"
  if ! aws s3api head-bucket --bucket "$BACKUP_S3_BUCKET_NAME" 2>/dev/null; then
    aws s3api create-bucket --bucket "$BACKUP_S3_BUCKET_NAME" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$BACKUP_S3_BUCKET_NAME" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$BACKUP_S3_BUCKET_NAME" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'
  aws s3api put-bucket-versioning --bucket "$BACKUP_S3_BUCKET_NAME" --versioning-configuration Status=Enabled

  # Not versioned: the Tempo compactor deletes blocks, and noncurrent versions would pile up.
  echo "== Tempo trace bucket (private, encrypted, expires after $retention days)"
  if ! aws s3api head-bucket --bucket "$TEMPO_S3_BUCKET_NAME" 2>/dev/null; then
    aws s3api create-bucket --bucket "$TEMPO_S3_BUCKET_NAME" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$TEMPO_S3_BUCKET_NAME" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$TEMPO_S3_BUCKET_NAME" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'
  aws s3api put-bucket-lifecycle-configuration --bucket "$TEMPO_S3_BUCKET_NAME" --lifecycle-configuration \
    "$(jq -n --argjson days "$retention" '{Rules: [{ID: "tempo-retention", Status: "Enabled", Filter: {},
        Expiration: {Days: $days}, AbortIncompleteMultipartUpload: {DaysAfterInitiation: 1}}]}')"

  codebuild

  echo "== WAFv2 WebACL (regional, AWS managed rules; an existing ACL is reused as-is)"
  local acl_name="${EKS_CLUSTER_NAME}-web-acl" acl_arn rules
  acl_arn=$(aws wafv2 list-web-acls --scope REGIONAL \
    --query "WebACLs[?Name=='$acl_name'].ARN | [0]" --output text)
  if [ "$acl_arn" = "None" ] || [ -z "$acl_arn" ]; then
    rules=$(jq -n '[$ARGS.positional | to_entries[] | {
        Name: .value, Priority: .key, OverrideAction: {None: {}},
        Statement: {ManagedRuleGroupStatement: {VendorName: "AWS", Name: .value}},
        VisibilityConfig: {SampledRequestsEnabled: true, CloudWatchMetricsEnabled: true, MetricName: .value}}]' \
      --args AWSManagedRulesCommonRuleSet AWSManagedRulesSQLiRuleSet AWSManagedRulesKnownBadInputsRuleSet)
    acl_arn=$(aws wafv2 create-web-acl --scope REGIONAL --name "$acl_name" \
      --default-action Allow={} \
      --visibility-config "SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=$acl_name" \
      --rules "$rules" --query Summary.ARN --output text)
  fi
  echo "$acl_arn"

  echo "== ACM certificate (DNS validation via Route 53; an issued or pending one is reused)"
  local cert_arn rr
  cert_arn=$(aws acm list-certificates --certificate-statuses ISSUED PENDING_VALIDATION \
    --query "CertificateSummaryList[?DomainName=='$DOMAIN_NAME'].CertificateArn | [0]" --output text)
  if [ "$cert_arn" = "None" ] || [ -z "$cert_arn" ]; then
    cert_arn=$(aws acm request-certificate --domain-name "$DOMAIN_NAME" --validation-method DNS \
      --query CertificateArn --output text)
  fi
  # The validation record shows up a few seconds after the request.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    rr=$(aws acm describe-certificate --certificate-arn "$cert_arn" \
      --query 'Certificate.DomainValidationOptions[0].ResourceRecord' --output json)
    [ "$rr" != "null" ] && break
    sleep 3
  done
  [ "$rr" != "null" ] || { echo "ACM validation record not available yet" >&2; exit 1; }
  aws route53 change-resource-record-sets --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" --change-batch \
    "$(jq -n --argjson rr "$rr" '{Changes: [{Action: "UPSERT", ResourceRecordSet:
        {Name: $rr.Name, Type: $rr.Type, TTL: 300, ResourceRecords: [{Value: $rr.Value}]}}]}')" >/dev/null
  aws acm wait certificate-validated --certificate-arn "$cert_arn"
  echo "$cert_arn"

  echo "Set ECR_*_REPOSITORY_URI, WAF_WEB_ACL_ARN and ACM_CERTIFICATE_ARN in .env from the output above."
}

# Image builds (docs/features/codebuild-image-build/design.md): source bucket, service role, project.
# Runs inside pre-cluster, before the ACM wait, so builds work while DNS delegation is still pending.
codebuild() {
  export CODEBUILD_PROJECT_NAME="${CODEBUILD_PROJECT_NAME:-${EKS_CLUSTER_NAME}-image-build}"
  export CODEBUILD_S3_BUCKET_NAME="${CODEBUILD_S3_BUCKET_NAME:-${EKS_CLUSTER_NAME}-codebuild-${AWS_ACCOUNT_ID}}"
  local dir="$ROOT/infra/aws/iam-policies" role="CodeBuildServiceRole-${EKS_CLUSTER_NAME}"
  local policy="${EKS_CLUSTER_NAME}-codebuild-policy" arn doc log_group="/aws/codebuild/${CODEBUILD_PROJECT_NAME}" v

  # Source archives are throwaway: CodeBuild reads each one once.
  echo "== CodeBuild source bucket (private, encrypted, expires after 1 day)"
  if ! aws s3api head-bucket --bucket "$CODEBUILD_S3_BUCKET_NAME" 2>/dev/null; then
    aws s3api create-bucket --bucket "$CODEBUILD_S3_BUCKET_NAME" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$CODEBUILD_S3_BUCKET_NAME" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$CODEBUILD_S3_BUCKET_NAME" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-bucket-lifecycle-configuration --bucket "$CODEBUILD_S3_BUCKET_NAME" --lifecycle-configuration \
    '{"Rules":[{"ID":"codebuild-source-expiry","Status":"Enabled","Filter":{},"Expiration":{"Days":1},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}'

  echo "== CodeBuild log group"
  tolerate ResourceAlreadyExistsException aws logs create-log-group --log-group-name "$log_group"
  aws logs put-retention-policy --log-group-name "$log_group" --retention-in-days 30

  echo "== CodeBuild service role (ECR push to web/was, source bucket read, own log group)"
  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    aws iam create-role --role-name "$role" \
      --assume-role-policy-document "$(envsubst '${AWS_ACCOUNT_ID}' < "$dir/codebuild-trust.json")" >/dev/null
  fi
  arn="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy}"
  doc=$(envsubst < "$dir/codebuild-policy.json")
  if aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    for v in $(aws iam list-policy-versions --policy-arn "$arn" \
        --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
      aws iam delete-policy-version --policy-arn "$arn" --version-id "$v"
    done
    aws iam create-policy-version --policy-arn "$arn" --policy-document "$doc" --set-as-default >/dev/null
  else
    aws iam create-policy --policy-name "$policy" --policy-document "$doc" >/dev/null
  fi
  aws iam attach-role-policy --role-name "$role" --policy-arn "$arn"

  echo "== CodeBuild project $CODEBUILD_PROJECT_NAME"
  # build-and-push.sh overrides the source location per build; this one only has to be valid.
  local args=(--name "$CODEBUILD_PROJECT_NAME"
    --source "type=S3,location=${CODEBUILD_S3_BUCKET_NAME}/source/build.zip,buildspec=buildspec.yml"
    --artifacts type=NO_ARTIFACTS
    --environment "type=LINUX_CONTAINER,image=aws/codebuild/amazonlinux2-x86_64-standard:5.0,computeType=BUILD_GENERAL1_MEDIUM,privilegedMode=true"
    --service-role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${role}"
    --logs-config "cloudWatchLogs={status=ENABLED,groupName=${log_group}}"
    --timeout-in-minutes 30)
  local verb=create-project out _
  if [ "$(aws codebuild batch-get-projects --names "$CODEBUILD_PROJECT_NAME" \
      --query 'length(projects)' --output text)" != "0" ]; then
    verb=update-project
  fi
  # A new role takes a few seconds before CodeBuild may assume it.
  for _ in 1 2 3 4 5 6; do
    out=$(aws codebuild "$verb" "${args[@]}" --query project.name --output text 2>&1) && { echo "$out"; return 0; }
    grep -q 'not authorized to perform: sts:AssumeRole' <<<"$out" || break
    sleep 10
  done
  echo "$out" >&2
  return 1
}

cluster() {
  require AWS_REGION AWS_ACCOUNT_ID EKS_CLUSTER_NAME VPC_ID PUBLIC_SUBNET_A_ID PUBLIC_SUBNET_C_ID APP_PRIVATE_SUBNET_A_ID APP_PRIVATE_SUBNET_C_ID EBS_CSI_ADDON_VERSION
  if aws eks describe-cluster --name "$EKS_CLUSTER_NAME" >/dev/null 2>&1; then
    echo "cluster $EKS_CLUSTER_NAME exists; skipping eksctl create, adding missing IRSA service accounts"
    # e.g. monitoring/tempo on a cluster created before apm-tracing; existing ones are left alone.
    envsubst < "$ROOT/infra/eksctl/cluster.yaml" | eksctl create iamserviceaccount -f - --approve
  else
    envsubst < "$ROOT/infra/eksctl/cluster.yaml" | eksctl create cluster -f -
  fi

  local sg
  sg=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" \
    --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)
  aws ec2 create-tags --resources "$APP_PRIVATE_SUBNET_A_ID" "$APP_PRIVATE_SUBNET_C_ID" "$sg" \
    --tags "Key=karpenter.sh/discovery,Value=$EKS_CLUSTER_NAME"
}

post_cluster() {
  require AWS_REGION EKS_CLUSTER_NAME VPC_ID DB_PRIVATE_SUBNET_A_ID DB_PRIVATE_SUBNET_C_ID RDS_SECRET_NAME RDS_APP_SECRET_NAME RDS_BACKUP_SECRET_NAME RDS_DB_NAME RDS_PORT GRAFANA_ADMIN_SECRET_NAME ALERTMANAGER_WEBHOOK_SECRET_NAME
  local s
  for s in "$RDS_SECRET_NAME" "$RDS_APP_SECRET_NAME" "$RDS_BACKUP_SECRET_NAME" "$GRAFANA_ADMIN_SECRET_NAME" "$ALERTMANAGER_WEBHOOK_SECRET_NAME"; do
    case "$s" in
      petclinic/*) ;;
      *) echo "secret names must start with petclinic/ (ESO IAM scope): $s" >&2; exit 1 ;;
    esac
  done
  local db_id="${EKS_CLUSTER_NAME}-mysql" cluster_sg rds_sg password host

  echo "== RDS security group: 3306 from the EKS cluster security group only"
  cluster_sg=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" \
    --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)
  rds_sg=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${db_id}-sg" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$rds_sg" = "None" ]; then
    rds_sg=$(aws ec2 create-security-group --group-name "${db_id}-sg" --vpc-id "$VPC_ID" \
      --description "PetClinic RDS MySQL - 3306 from EKS only" --query GroupId --output text)
  fi
  tolerate InvalidPermission.Duplicate aws ec2 authorize-security-group-ingress --group-id "$rds_sg" \
    --protocol tcp --port "$RDS_PORT" --source-group "$cluster_sg"

  aws rds describe-db-subnet-groups --db-subnet-group-name "${db_id}-subnets" >/dev/null 2>&1 \
    || aws rds create-db-subnet-group --db-subnet-group-name "${db_id}-subnets" \
      --db-subnet-group-description "PetClinic DB private subnets" \
      --subnet-ids "$DB_PRIVATE_SUBNET_A_ID" "$DB_PRIVATE_SUBNET_C_ID" >/dev/null

  echo "== RDS parameter group: TLS required"
  local family
  family=$(aws rds describe-db-parameter-groups --db-parameter-group-name "${db_id}-params" \
    --query 'DBParameterGroups[0].DBParameterGroupFamily' --output text 2>/dev/null) || family=""
  if [ -z "$family" ]; then
    aws rds create-db-parameter-group --db-parameter-group-name "${db_id}-params" \
      --db-parameter-group-family mysql8.4 --description "PetClinic MySQL 8.4 - require TLS" >/dev/null
  elif [ "$family" != mysql8.4 ]; then
    # A leftover 8.0 group cannot be attached to an 8.4 instance; never replace it silently.
    echo "parameter group ${db_id}-params is $family, not mysql8.4: delete it (or rename) and re-run" >&2; exit 1
  fi
  aws rds modify-db-parameter-group --db-parameter-group-name "${db_id}-params" \
    --parameters "ParameterName=require_secure_transport,ParameterValue=ON,ApplyMethod=immediate" >/dev/null

  # The master password is stored before the instance exists, so a run that dies in between
  # never loses it: the next run reads it back from the secret.
  echo "== Secrets Manager: $RDS_SECRET_NAME (petclinic_admin)"
  upsert_db_secret "$RDS_SECRET_NAME" petclinic_admin ""
  password=$(aws secretsmanager get-secret-value --secret-id "$RDS_SECRET_NAME" \
    --query SecretString --output text | jq -r .password)

  echo "== RDS MySQL 8.4 Multi-AZ (encrypted, private; an existing instance is reused as-is)"
  if ! aws rds describe-db-instances --db-instance-identifier "$db_id" >/dev/null 2>&1; then
    # aws-cli 2.x rejects --cli-input-json from a pipe ("Invalid JSON received"), so use a 600 temp file.
    local input
    input=$(mktemp); chmod 600 "$input"
    trap "rm -f '$input'" EXIT  # expanded now: $input is local and gone by the time EXIT runs
    PW="$password" jq -n '{MasterUserPassword: env.PW}' > "$input"
    aws rds create-db-instance --cli-input-json "file://$input" \
      --db-instance-identifier "$db_id" \
      --engine mysql --engine-version 8.4.11 \
      --db-instance-class db.t3.medium \
      --allocated-storage 20 --storage-type gp3 --storage-encrypted \
      --multi-az --no-publicly-accessible \
      --db-name "$RDS_DB_NAME" --port "$RDS_PORT" \
      --master-username petclinic_admin \
      --vpc-security-group-ids "$rds_sg" \
      --db-subnet-group-name "${db_id}-subnets" \
      --db-parameter-group-name "${db_id}-params" \
      --enable-cloudwatch-logs-exports '["error","slowquery"]' \
      --backup-retention-period 7 --copy-tags-to-snapshot --deletion-protection >/dev/null
    rm -f "$input"
  fi
  aws rds wait db-instance-available --db-instance-identifier "$db_id"
  host=$(aws rds describe-db-instances --db-instance-identifier "$db_id" \
    --query 'DBInstances[0].Endpoint.Address' --output text)
  echo "RDS endpoint: $host"

  # App/backup users are created in MySQL by the db-init Job from these secrets.
  echo "== Secrets Manager: DB secrets with endpoint $host"
  upsert_db_secret "$RDS_SECRET_NAME" petclinic_admin "$host"
  upsert_db_secret "$RDS_APP_SECRET_NAME" petclinic_app "$host"
  upsert_db_secret "$RDS_BACKUP_SECRET_NAME" petclinic_backup "$host"

  echo "== Secrets Manager: $GRAFANA_ADMIN_SECRET_NAME"
  if ! aws secretsmanager describe-secret --secret-id "$GRAFANA_ADMIN_SECRET_NAME" >/dev/null 2>&1; then
    password=$(random_password)
    PW="$password" jq -n '{username: "admin", password: env.PW}' \
      | aws secretsmanager create-secret --name "$GRAFANA_ADMIN_SECRET_NAME" --secret-string file:///dev/stdin >/dev/null
  fi

  # The URL comes from .env once and lives only in Secrets Manager; re-running with it set updates the secret.
  echo "== Secrets Manager: $ALERTMANAGER_WEBHOOK_SECRET_NAME"
  if [ -n "${ALERTMANAGER_WEBHOOK_URL:-}" ]; then
    case "$ALERTMANAGER_WEBHOOK_URL" in
      https://*) ;;
      *) echo "ALERTMANAGER_WEBHOOK_URL must be https:// (Alertmanager egress allows 443 only)" >&2; exit 1 ;;
    esac
    if aws secretsmanager describe-secret --secret-id "$ALERTMANAGER_WEBHOOK_SECRET_NAME" >/dev/null 2>&1; then
      jq -n '{url: env.ALERTMANAGER_WEBHOOK_URL}' | aws secretsmanager put-secret-value \
        --secret-id "$ALERTMANAGER_WEBHOOK_SECRET_NAME" --secret-string file:///dev/stdin >/dev/null
    else
      jq -n '{url: env.ALERTMANAGER_WEBHOOK_URL}' | aws secretsmanager create-secret \
        --name "$ALERTMANAGER_WEBHOOK_SECRET_NAME" --secret-string file:///dev/stdin >/dev/null
    fi
  elif ! aws secretsmanager describe-secret --secret-id "$ALERTMANAGER_WEBHOOK_SECRET_NAME" >/dev/null 2>&1; then
    echo "set ALERTMANAGER_WEBHOOK_URL to create $ALERTMANAGER_WEBHOOK_SECRET_NAME" >&2; exit 1
  fi
}

# /grafana and the staff app at /was are only for the staff IPs (docs/features/grafana-public-path/design.md,
# docs/features/landing-page/design.md): an IP set from GRAFANA_ALLOWED_CIDRS and one block rule at
# priority 0, ahead of the managed rule groups, answering with the designed 403 page (waf-staff-403.html;
# its image comes from web Nginx's public /resources/). The IP set keeps its original grafana name.
# Re-run alone after the allowed IP changes. An empty list blocks /grafana and /was for everyone.
# STAFF_WAF_SCOPE=all puts every path except /resources/ (the 403 page's image) behind the allow-list:
# a web image from before /was proxies / to the staff app, so it goes first in that rollback
# (docs/features/landing-page/design.md Q8). Run again without it to go back to /grafana + /was.
grafana_waf() {
  require AWS_REGION EKS_CLUSTER_NAME WAF_WEB_ACL_ARN
  local scope="${STAFF_WAF_SCOPE:-staff}"
  [[ "$scope" =~ ^(staff|all)$ ]] || { echo "STAFF_WAF_SCOPE must be staff or all (got $scope)" >&2; exit 1; }
  local set_name="${EKS_CLUSTER_NAME}-grafana-allowed-ips" rule=BlockUnauthorizedStaffAccess
  local old_rule=BlockUnauthorizedGrafanaAccess body_key=petclinic-staff-403 bodies
  local cidrs=() addrs c set_id set_arn lock acl_id="${WAF_WEB_ACL_ARN##*/}" acl_name acl rules
  local list="${GRAFANA_ALLOWED_CIDRS:-}"
  IFS=',' read -r -a cidrs <<<"${list//[[:space:]]/}"  # "a/32, b/32" is fine too
  addrs=("${cidrs[@]}"); [ "${#cidrs[@]}" -gt 0 ] || addrs=('[]')
  for c in "${cidrs[@]}"; do
    [[ "$c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] \
      || { echo "GRAFANA_ALLOWED_CIDRS: '$c' is not an IPv4 CIDR (e.g. 203.0.113.7/32)" >&2; exit 1; }
  done

  echo "== WAF IP set $set_name (${#cidrs[@]} CIDR)"
  set_id=$(aws wafv2 list-ip-sets --scope REGIONAL --query "IPSets[?Name=='$set_name'].Id | [0]" --output text)
  if [ "$set_id" = "None" ] || [ -z "$set_id" ]; then
    set_arn=$(aws wafv2 create-ip-set --scope REGIONAL --name "$set_name" --ip-address-version IPV4 \
      --description "Allowed source IPs for /grafana and /was staff access" --addresses "${addrs[@]}" \
      --query Summary.ARN --output text)
  else
    lock=$(aws wafv2 get-ip-set --scope REGIONAL --name "$set_name" --id "$set_id" --query LockToken --output text)
    aws wafv2 update-ip-set --scope REGIONAL --name "$set_name" --id "$set_id" --lock-token "$lock" \
      --addresses "${addrs[@]}" >/dev/null
    set_arn=$(aws wafv2 get-ip-set --scope REGIONAL --name "$set_name" --id "$set_id" --query IPSet.ARN --output text)
  fi

  echo "== WAF rule $rule (priority 0, scope $scope) in the WebACL"
  acl_name=$(aws wafv2 list-web-acls --scope REGIONAL --query "WebACLs[?Id=='$acl_id'].Name | [0]" --output text)
  acl=$(aws wafv2 get-web-acl --scope REGIONAL --name "$acl_name" --id "$acl_id")
  # Decode and normalise the path the way NGF's nginx does (%67rafana, //was, /./grafana), then
  # block it unless the client IP is in the set. The other rules keep their order behind it; the
  # /grafana-only rule this one replaces is dropped.
  rules=$(jq --arg rule "$rule" --arg old "$old_rule" --arg set "$set_arn" --arg key "$body_key" --arg scope "$scope" '
    def path($p): {ByteMatchStatement: {FieldToMatch: {UriPath: {}}, PositionalConstraint: "STARTS_WITH",
      SearchString: $p, TextTransformations: [
        {Priority: 0, Type: "URL_DECODE"}, {Priority: 1, Type: "NORMALIZE_PATH"},
        {Priority: 2, Type: "LOWERCASE"}]}};
    [.WebACL.Rules[] | select(.Name != $rule and .Name != $old)] | sort_by(.Priority)
    | to_entries | map(.value + {Priority: (.key + 1)})
    | [{Name: $rule, Priority: 0,
        Action: {Block: {CustomResponse: {ResponseCode: 403, CustomResponseBodyKey: $key,
          # Served by WAF, not web Nginx, so the Nginx security headers are set here too.
          ResponseHeaders: [{Name: "Cache-Control", Value: "no-store"}, {Name: "X-Frame-Options", Value: "DENY"},
            {Name: "X-Content-Type-Options", Value: "nosniff"}]}}},
        VisibilityConfig: {SampledRequestsEnabled: true, CloudWatchMetricsEnabled: true, MetricName: $rule},
        Statement: {AndStatement: {Statements: [
          if $scope == "all" then {NotStatement: {Statement: path("/resources/")}}
          else {OrStatement: {Statements: [path("/grafana"), path("/was")]}} end,
          {NotStatement: {Statement: {IPSetReferenceStatement: {ARN: $set}}}}]}}}] + .' <<<"$acl")
  # Other response bodies in the WebACL are kept. WAF sets Content-Type from ContentType.
  bodies=$(jq -c --arg key "$body_key" --rawfile html "$ROOT/infra/aws/waf-staff-403.html" \
    '(.WebACL.CustomResponseBodies // {}) + {($key): {ContentType: "TEXT_HTML", Content: $html}}' <<<"$acl")
  # SearchString is a blob: CLI v2 would base64-decode "/grafana" into bytes that never match.
  aws wafv2 update-web-acl --scope REGIONAL --name "$acl_name" --id "$acl_id" --cli-binary-format raw-in-base64-out \
    --lock-token "$(jq -r .LockToken <<<"$acl")" \
    --default-action "$(jq -c .WebACL.DefaultAction <<<"$acl")" \
    --visibility-config "$(jq -c .WebACL.VisibilityConfig <<<"$acl")" \
    --custom-response-bodies "$bodies" \
    --rules "$rules" >/dev/null
  aws wafv2 get-web-acl --scope REGIONAL --name "$acl_name" --id "$acl_id" \
    --query 'WebACL.Rules[].[Priority,Name]' --output text
}

case "${1:-}" in
  vpc) vpc ;;
  pre-cluster) pre_cluster ;;
  cluster) cluster ;;
  post-cluster) post_cluster ;;
  grafana-waf) grafana_waf ;;
  *) echo "usage: $0 {vpc|pre-cluster|cluster|post-cluster|grafana-waf}" >&2; exit 1 ;;
esac
