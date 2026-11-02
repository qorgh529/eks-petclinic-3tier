#!/usr/bin/env bash
# Project close: delete every AWS resource this repo created in ap-northeast-2, plus the Route 53 hosted zone.
# Scoped by the names in .env and the Project=petclinic tag; other projects in the account are left alone.
# Irreversible: RDS goes without a final snapshot, S3/ECR/Secrets/logs are purged.
# Order: in-cluster AWS objects (ALB, EBS PVs, Karpenter nodes) -> cluster -> RDS -> NAT -> VPC -> edge -> the rest.
# Idempotent. --dry-run still reads AWS but prints every delete instead of running it.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() { echo "usage: $0 [--dry-run] [--keep-dns] [-h|--help]"; }
DRY_RUN=0 KEEP_DNS=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --keep-dns) KEEP_DNS=1 ;;  # keep the ACM certificate and the Route 53 hosted zone
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

export AWS_REGION=ap-northeast-2 AWS_DEFAULT_REGION=ap-northeast-2
require AWS_ACCOUNT_ID EKS_CLUSTER_NAME VPC_ID DOMAIN_NAME ROUTE53_HOSTED_ZONE_ID \
  BACKUP_S3_BUCKET_NAME TEMPO_S3_BUCKET_NAME RDS_SECRET_NAME RDS_APP_SECRET_NAME RDS_BACKUP_SECRET_NAME \
  GRAFANA_ADMIN_SECRET_NAME ALERTMANAGER_WEBHOOK_SECRET_NAME
C=$EKS_CLUSTER_NAME DB="${EKS_CLUSTER_NAME}-mysql"
CODEBUILD_PROJECT_NAME="${CODEBUILD_PROJECT_NAME:-${C}-image-build}"
CODEBUILD_S3_BUCKET_NAME="${CODEBUILD_S3_BUCKET_NAME:-${C}-codebuild-${AWS_ACCOUNT_ID}}"

run() { if (( DRY_RUN )); then echo "[DRY-RUN] $*" >&2; else "$@"; fi; }
# Lookups that may legitimately find nothing print "" instead of failing the script.
q() { local out; out=$("$@" 2>/dev/null) || true; [ "$out" = None ] && out=""; echo "$out"; }
step() { echo; echo "== $*"; }

# The VPC must be ours before anything inside it is touched.
[ "$(q aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].Tags[?Key==`Project`].Value | [0]' --output text)" = petclinic ] \
  || [ -z "$(q aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].VpcId' --output text)" ] \
  || { echo "VPC_ID is not tagged Project=petclinic: refusing" >&2; exit 1; }

step "1. In-cluster AWS objects: ALB (Ingress), EBS volumes (PVC), Karpenter nodes"
VOLS=""
if [ "$(q aws eks describe-cluster --name "$C" --query cluster.status --output text)" = ACTIVE ]; then
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$C" >/dev/null
  VOLS=$(kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}' | grep '^vol-' || true)
  echo "EBS volumes behind PVs: $(echo $VOLS)"
  run kubectl delete ingress -A --all --wait=true --timeout=300s
  run kubectl delete svc -A --field-selector spec.type=LoadBalancer --wait=true --timeout=300s
  # Workloads and PDBs first: otherwise PDBs block the Karpenter drain (pods have nowhere to go)
  # and StatefulSets recreate the PVCs.
  for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    case "$ns" in kube-system|kube-public|kube-node-lease|default) continue ;; esac
    run kubectl -n "$ns" delete scaledobject,hpa,pdb --all --ignore-not-found
    # prometheus-operator recreates these StatefulSets until its CRs are gone.
    [ "$ns" = monitoring ] && run kubectl -n "$ns" delete alertmanager,prometheus --all --ignore-not-found
    run kubectl -n "$ns" delete statefulset,deployment --all --wait=true --timeout=300s
  done
  for np in $(kubectl get nodepool -o name 2>/dev/null); do
    run kubectl patch "$np" --type merge -p '{"spec":{"limits":{"cpu":"0","memory":"0Gi"}}}'
  done
  run kubectl delete nodeclaim --all --wait=true --timeout=300s
  run kubectl delete pvc -A --all --wait=true --timeout=300s
  if (( ! DRY_RUN )); then
    for _ in $(seq 60); do
      n=$(aws elbv2 describe-load-balancers --query "length(LoadBalancers[?VpcId=='$VPC_ID'])" --output text)
      [ "$n" = 0 ] && break; echo "waiting for $n load balancer(s) in the VPC"; sleep 10
    done
  fi
else
  echo "cluster $C not active: skipping"
fi

step "2. EKS cluster $C (node groups, IRSA roles, eksctl stacks)"
if [ -n "$(q aws eks describe-cluster --name "$C" --query cluster.name --output text)" ]; then
  run eksctl delete cluster --name "$C" --region "$AWS_REGION" --wait --disable-nodegroup-eviction
else
  echo "no cluster"
fi
# Karpenter's own leftovers: instances it never got to drain, and its launch templates.
ids=$(q aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag-key,Values=karpenter.sh/nodepool" \
  Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$ids" ]; then
  run aws ec2 terminate-instances --instance-ids $ids >/dev/null
  (( DRY_RUN )) || aws ec2 wait instance-terminated --instance-ids $ids
fi
for lt in $(q aws ec2 describe-launch-templates --filters "Name=tag:karpenter.k8s.aws/cluster,Values=$C" \
    --query 'LaunchTemplates[].LaunchTemplateId' --output text); do
  run aws ec2 delete-launch-template --launch-template-id "$lt" >/dev/null
done
for v in $VOLS; do
  [ "$(q aws ec2 describe-volumes --volume-ids "$v" --query 'Volumes[0].State' --output text)" = available ] \
    && run aws ec2 delete-volume --volume-id "$v"
done

step "3. RDS $DB (no final snapshot)"
if [ -n "$(q aws rds describe-db-instances --db-instance-identifier "$DB" --query 'DBInstances[0].DBInstanceStatus' --output text)" ]; then
  run aws rds modify-db-instance --db-instance-identifier "$DB" --no-deletion-protection --apply-immediately >/dev/null
  run aws rds delete-db-instance --db-instance-identifier "$DB" --skip-final-snapshot --delete-automated-backups >/dev/null
  (( DRY_RUN )) || aws rds wait db-instance-deleted --db-instance-identifier "$DB"
fi
[ -n "$(q aws rds describe-db-subnet-groups --db-subnet-group-name "${DB}-subnets" --query 'DBSubnetGroups[0].DBSubnetGroupName' --output text)" ] \
  && run aws rds delete-db-subnet-group --db-subnet-group-name "${DB}-subnets"
[ -n "$(q aws rds describe-db-parameter-groups --db-parameter-group-name "${DB}-params" --query 'DBParameterGroups[0].DBParameterGroupName' --output text)" ] \
  && run aws rds delete-db-parameter-group --db-parameter-group-name "${DB}-params"

step "4. NAT gateways and their EIPs"
if (( DRY_RUN )); then "$(dirname "$0")/nat-stop.sh" --dry-run; else "$(dirname "$0")/nat-stop.sh" --force; fi

step "5. VPC $VPC_ID"
if [ -n "$(q aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].VpcId' --output text)" ]; then
  for e in $(q aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --query 'VpcEndpoints[].VpcEndpointId' --output text); do
    run aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$e" >/dev/null
  done
  for eni in $(q aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" Name=status,Values=available \
      --query 'NetworkInterfaces[].NetworkInterfaceId' --output text); do
    run aws ec2 delete-network-interface --network-interface-id "$eni"
  done
  sgs=$(q aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)
  # SGs that reference each other cannot go until those rules are gone.
  for sg in $sgs; do
    for dir in ingress egress; do
      key=IpPermissions; [ $dir = egress ] && key=IpPermissionsEgress
      perms=$(aws ec2 describe-security-groups --group-ids "$sg" --query "SecurityGroups[0].$key[?UserIdGroupPairs]" --output json)
      [ "$perms" != "[]" ] && run aws ec2 "revoke-security-group-$dir" --group-id "$sg" --ip-permissions "$perms" >/dev/null
    done
  done
  for sg in $sgs; do run aws ec2 delete-security-group --group-id "$sg"; done
  for s in $(q aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text); do
    run aws ec2 delete-subnet --subnet-id "$s"
  done
  for rt in $(q aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
      --query 'RouteTables[?!(Associations[?Main])].RouteTableId' --output text); do
    run aws ec2 delete-route-table --route-table-id "$rt"
  done
  for igw in $(q aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
      --query 'InternetGateways[].InternetGatewayId' --output text); do
    run aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID"
    run aws ec2 delete-internet-gateway --internet-gateway-id "$igw"
  done
  run aws ec2 delete-vpc --vpc-id "$VPC_ID"
fi

step "6. WAF WebACL and IP set"
waf_delete() {  # <list-cmd> <get-cmd> <delete-cmd> <name>
  local id lock
  id=$(q aws wafv2 "$1" --scope REGIONAL --query "${5}[?Name=='$4'].Id | [0]" --output text)
  [ -z "$id" ] && { echo "no $4"; return; }
  lock=$(aws wafv2 "$2" --scope REGIONAL --name "$4" --id "$id" --query LockToken --output text)
  run aws wafv2 "$3" --scope REGIONAL --name "$4" --id "$id" --lock-token "$lock"
}
waf_delete list-web-acls get-web-acl delete-web-acl "${C}-web-acl" WebACLs
waf_delete list-ip-sets get-ip-set delete-ip-set "${C}-grafana-allowed-ips" IPSets

step "7. ACM certificate and Route 53 hosted zone $DOMAIN_NAME"
if (( KEEP_DNS )); then
  echo "--keep-dns: skipping"
else
  for arn in $(q aws acm list-certificates --query "CertificateSummaryList[?DomainName=='$DOMAIN_NAME'].CertificateArn" --output text); do
    run aws acm delete-certificate --certificate-arn "$arn"
  done
  if [ -n "$(q aws route53 get-hosted-zone --id "$ROUTE53_HOSTED_ZONE_ID" --query HostedZone.Id --output text)" ]; then
    changes=$(aws route53 list-resource-record-sets --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" --output json \
      | jq --arg apex "${DOMAIN_NAME%.}." '[.ResourceRecordSets[]
          | select(.Name != $apex or (.Type != "NS" and .Type != "SOA")) | {Action: "DELETE", ResourceRecordSet: .}]')
    if [ "$changes" != "[]" ]; then
      run aws route53 change-resource-record-sets --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" \
        --change-batch "{\"Changes\":$changes}" >/dev/null
    fi
    run aws route53 delete-hosted-zone --id "$ROUTE53_HOSTED_ZONE_ID" >/dev/null
  fi
fi

step "8. ECR, S3, CodeBuild, CloudWatch Logs, Secrets Manager"
for r in petclinic-web petclinic-was; do
  [ -n "$(q aws ecr describe-repositories --repository-names "$r" --query 'repositories[0].repositoryName' --output text)" ] \
    && run aws ecr delete-repository --repository-name "$r" --force >/dev/null
done
for b in "$BACKUP_S3_BUCKET_NAME" "$TEMPO_S3_BUCKET_NAME" "$CODEBUILD_S3_BUCKET_NAME"; do
  aws s3api head-bucket --bucket "$b" >/dev/null 2>&1 || { echo "no bucket $b"; continue; }
  # Versioned: every version and delete marker has to go before the bucket.
  while :; do
    objs=$(aws s3api list-object-versions --bucket "$b" --max-items 1000 --output json \
      | jq '{Objects: [((.Versions // []) + (.DeleteMarkers // []))[] | {Key, VersionId}], Quiet: true}')
    [ "$(jq '.Objects | length' <<<"$objs")" = 0 ] && break
    if (( DRY_RUN )); then echo "[DRY-RUN] delete $(jq '.Objects | length' <<<"$objs")+ object versions in $b"; break; fi
    aws s3api delete-objects --bucket "$b" --delete "$objs" >/dev/null
  done
  run aws s3api delete-bucket --bucket "$b"
done
[ "$(q aws codebuild batch-get-projects --names "$CODEBUILD_PROJECT_NAME" --query 'length(projects)' --output text)" = 1 ] \
  && run aws codebuild delete-project --name "$CODEBUILD_PROJECT_NAME"
for lg in $(q aws logs describe-log-groups --query 'logGroups[].logGroupName' --output text); do
  case "$lg" in
    "/aws/codebuild/$CODEBUILD_PROJECT_NAME"|/aws/eks/"$C"/*|/aws/rds/instance/"$DB"/*|"${CW_LOG_GROUP_NAME:-/nonexistent}")
      run aws logs delete-log-group --log-group-name "$lg" ;;
  esac
done
for s in "$RDS_SECRET_NAME" "$RDS_APP_SECRET_NAME" "$RDS_BACKUP_SECRET_NAME" "$GRAFANA_ADMIN_SECRET_NAME" "$ALERTMANAGER_WEBHOOK_SECRET_NAME"; do
  [ -n "$(q aws secretsmanager describe-secret --secret-id "$s" --query Name --output text)" ] \
    && run aws secretsmanager delete-secret --secret-id "$s" --force-delete-without-recovery >/dev/null
done

step "9. IAM roles and policies created outside eksctl"
for role in "KarpenterNodeRole-$C" "CodeBuildServiceRole-$C"; do
  [ -z "$(q aws iam get-role --role-name "$role" --query Role.RoleName --output text)" ] && continue
  for p in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
    run aws iam detach-role-policy --role-name "$role" --policy-arn "$p"
  done
  for p in $(aws iam list-role-policies --role-name "$role" --query PolicyNames --output text); do
    run aws iam delete-role-policy --role-name "$role" --policy-name "$p"
  done
  # Karpenter creates instance profiles for its node role on the fly.
  for ip in $(aws iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[].InstanceProfileName' --output text); do
    run aws iam remove-role-from-instance-profile --instance-profile-name "$ip" --role-name "$role"
    run aws iam delete-instance-profile --instance-profile-name "$ip"
  done
  run aws iam delete-role --role-name "$role"
done
for name in lbc karpenter-controller eso fluent-bit db-backup tempo codebuild-policy; do
  arn="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${C}-${name}"
  aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1 || continue
  for e in $(aws iam list-entities-for-policy --policy-arn "$arn" --query 'PolicyRoles[].RoleName' --output text); do
    run aws iam detach-role-policy --role-name "$e" --policy-arn "$arn"
  done
  for v in $(aws iam list-policy-versions --policy-arn "$arn" --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    run aws iam delete-policy-version --policy-arn "$arn" --version-id "$v"
  done
  run aws iam delete-policy --policy-arn "$arn"
done

step "Leftovers (should all be empty)"
echo "IAM roles:  $(q aws iam list-roles --query "Roles[?contains(RoleName,'$C')].RoleName" --output text)"
echo "CFN stacks: $(q aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
  --query "StackSummaries[?starts_with(StackName,'eksctl-$C')].StackName" --output text)"
echo "EIPs:       $(q aws ec2 describe-addresses --filters Name=tag:Project,Values=petclinic --query 'Addresses[].AllocationId' --output text)"
