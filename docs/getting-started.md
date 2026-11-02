# 실행 가이드 (Getting Started)

> [README](../README.md)의 프로젝트 보고서에서 분리한 설치·배포·운영 절차입니다. 아래 명령은 저장소 루트에서 실행합니다.

## 1. 사전 준비 사항 (Prerequisites)

1. **로컬 CLI 도구**:
   - `aws` (AWS CLI v2), `eksctl`, `kubectl`, `helm`, `docker`, `jq`, `envsubst` (`gettext`), `curl`
   - 오프라인 검증 및 테스트용: `python3` (`PyYAML` 패키지 포함), `promtool` (또는 Docker)
2. **AWS 네트워크 리소스**: 없으면 `./infra/aws/provision-aws-resources.sh vpc` 로 만들 수 있습니다 (Step 2 참고).
   - 서울 리전(`ap-northeast-2`)의 VPC 및 `ap-northeast-2a` / `ap-northeast-2c` 가용 영역별 서브넷 ID:
     - 퍼블릭 서브넷 2개 (`PUBLIC_SUBNET_A_ID`, `PUBLIC_SUBNET_C_ID`)
     - 앱 프라이빗 서브넷 2개 (`APP_PRIVATE_SUBNET_A_ID`, `APP_PRIVATE_SUBNET_C_ID`)
     - DB 프라이빗 서브넷 2개 (`DB_PRIVATE_SUBNET_A_ID`, `DB_PRIVATE_SUBNET_C_ID`)
   - Route 53 Hosted Zone ID (`ROUTE53_HOSTED_ZONE_ID`) 및 도메인 이름 (`DOMAIN_NAME`)

---

## 2. 빠른 시작 가이드 (Quickstart)

### Step 1. 환경변수 파일(`.env`) 구성
템플릿을 복사한 뒤 실제 AWS 계정·VPC 서브넷·도메인 정보를 입력합니다 (`.env` 파일은 `.gitignore`에 의해 커밋되지 않습니다).
```bash
cp .env.example .env
# .env 파일을 열어 AWS_ACCOUNT_ID, VPC_ID, 서브넷 ID, DOMAIN_NAME, EBS_CSI_ADDON_VERSION 등을 입력
```

### Step 2. AWS 주변 인프라 및 EKS 클러스터 프로비저닝
각 단계는 멱등(Idempotent)하게 동작하므로 중간에 중단되더라도 안전하게 재실행할 수 있습니다.
```bash
# 0) VPC 10.0.0.0/16, 서브넷 6개(퍼블릭 10.0.0.0/24·10.0.1.0/24, 앱 10.0.16.0/20·10.0.32.0/20, DB 10.0.48.0/24·10.0.49.0/24),
#    IGW, 라우트 테이블 4개, AZ별 NAT 2개 생성 (리전은 ap-northeast-2 고정, Name=petclinic-* 태그로 찾아 재사용)
./infra/aws/provision-aws-resources.sh vpc
# 마지막에 출력된 VPC_ID 와 서브넷 ID 6개를 .env에 반영

# 1) IAM Policy/Role, ECR 리포지토리, CloudWatch Log Group, 백업용·Tempo용 S3 버킷, CodeBuild(소스 버킷·서비스 역할·프로젝트), WAFv2 WebACL, ACM 인증서 생성
./infra/aws/provision-aws-resources.sh pre-cluster
# 출력된 ECR_*_REPOSITORY_URI, WAF_WEB_ACL_ARN, ACM_CERTIFICATE_ARN을 .env에 반영

# 2) eksctl 기반 EKS 1.36 클러스터(ng-critical, ng-platform) 생성 및 Karpenter discovery 태그 부여
./infra/aws/provision-aws-resources.sh cluster

# 3) RDS MySQL 8.4 LTS Multi-AZ(TLS 강제) 및 Secrets Manager 시크릿(admin/app/backup, Grafana, Alertmanager) 생성
./infra/aws/provision-aws-resources.sh post-cluster

# 4) /grafana 접근 허용 IP: .env 의 GRAFANA_ALLOWED_CIDRS(예: 203.0.113.7/32)로 WAF IP set과 차단 규칙(우선순위 0) 적용.
#    필수 — 이 규칙이 없으면 deploy-all.sh 가 시작 전에 멈춥니다. 허용 IP가 바뀌면 이것만 다시 실행합니다.
./infra/aws/provision-aws-resources.sh grafana-waf
```
> Grafana는 `https://<DOMAIN_NAME>/grafana/` 에서 열리며, 허용 IP 밖에서는 WAF가 403을 돌려줍니다. 관리자 계정은 Secrets Manager의 `GRAFANA_ADMIN_SECRET_NAME` 입니다.

### Step 3. `web` / `was` 컨테이너 이미지 빌드 및 ECR 푸시
```bash
IMAGE_TAG=v1.0.0 ./scripts/build-and-push.sh
```
> 이미지는 AWS CodeBuild에서 빌드됩니다. 스크립트가 작업 트리(커밋 안 된 변경 포함, `.gitignore` 대상과 `.env*`·키 파일 제외)를 zip으로 묶어 CodeBuild 소스 버킷(1일 후 자동 삭제)에 올리고, `buildspec.yml` 로 `linux/amd64` 빌드 → ECR 푸시까지 진행 상황을 따라갑니다. 같은 태그가 이미 ECR에 있으면 빌드 전에 멈춥니다. 한 이미지만 빌드하려면 `BUILD_TARGET=web` 또는 `was`, 로컬 Docker로 빌드하려면 `--local` 을 붙입니다. 실패하면 출력된 CloudWatch Logs 그룹(`/aws/codebuild/<프로젝트명>`)에서 원인을 확인합니다.

### Step 4. 클러스터 애드온·워크로드 전체 배포 및 카나리 검증
```bash
STABLE_IMAGE_TAG=v1.0.0 CANARY_IMAGE_TAG=v1.0.0 ./scripts/deploy-all.sh
```
> `deploy-all.sh`는 매니페스트 정적 검증(`validate-manifests.sh`) → 네임스페이스/StorageClass/Gateway API CRD 설치 → 클러스터 컨트롤러(LBC, Metrics Server, Karpenter, ESO) 설치 → Karpenter `np-app` 및 NGF 배포 → ESO 시크릿 동기화 대기 → 모니터링(Prometheus/Grafana/Alertmanager)·트레이싱(Tempo/OTel Collector, Operator는 컨트롤러 단계) 및 KEDA/Fluent Bit 설치 → `db-init` Job 및 `db-backup` CronJob 배포 → `HTTPRoute` `100:0` 격리 후 `was`/`web` 롤아웃 → Route 53 연결 → `X-Canary: always` 동적 경로 검증 → 통과 시 `STABLE_WEIGHT:CANARY_WEIGHT`(기본 `90:10`) 개방까지 순서대로 수행합니다.

---

## 3. 운영 및 검증 런북 (Day-2 Operations)

### 1) 오프라인 매니페스트 및 보안 정책 정적 검증
클러스터 연결 없이 YAML 문법, 이미지 태그 고정(`:latest` 금지), 평문 시크릿 부재, 3-Tier 노드 배치(`nodeSelector`/`tolerations`), 비루트 `securityContext`, 역할별 DB 시크릿 분리, 커넥션 풀 상한(`maxActive <= 10`), KEDA `fallback`, Prometheus Multi-AZ HA, PDB 등을 일괄 검사합니다.
```bash
./scripts/validate-manifests.sh
```

### 2) Prometheus 알림 규칙 단위 테스트
`PetClinicDBBackupFailed`(첫 성공 없음 / 26시간 초과 / 복구 시 해제), `PetClinicKedaMetricsError`, `PetClinicHttp5xxRateHigh` 알림 규칙을 `promtool`로 검증합니다.
```bash
./scripts/test-prometheus-rules.sh
```

### 3) 카나리 배포 / 승격 / 롤백
```bash
# 새 후보 버전(v1.1.0) 빌드 및 푸시
IMAGE_TAG=v1.1.0 ./scripts/build-and-push.sh

# Stable(v1.0.0)은 유지하고 Canary(v1.1.0)를 0%에서 검증 후 개방 (위험한 변경이면 5%처럼 작게)
STABLE_IMAGE_TAG=v1.0.0 CANARY_IMAGE_TAG=v1.1.0 STABLE_WEIGHT=95 CANARY_WEIGHT=5 ./scripts/deploy-all.sh

# 지표를 보며 재배포 없이 확대
./scripts/set-canary-weight.sh 25

# 카나리 이상 징후 발생 시 즉시 0%로 차단(롤백)
./scripts/set-canary-weight.sh 0

# 승격: 카나리 태그를 Stable로 재배포
STABLE_IMAGE_TAG=v1.1.0 CANARY_IMAGE_TAG=v1.1.0 ./scripts/deploy-all.sh
```

### 4) DB 비밀번호 무중단 회전 (Secret Rotation)
AWS Secrets Manager에서 `petclinic_app` 또는 `petclinic_backup` 비밀번호를 변경한 뒤 아래 스크립트를 실행하면, ESO 강제 동기화(`refreshTime` 갱신 확인) → `db-init` Job 재실행(`ALTER USER`) → `was-stable`/`was-canary` 롤링 재시작을 자동으로 수행합니다.
```bash
./scripts/rotate-db-secrets.sh
```

### 5) 업무 외 시간 중지·기동 (비용 절감)
퇴근 시 앱 노드·RDS·관리형 노드 그룹을 내리고, `--stop-nat` 을 붙이면 마지막에 NAT Gateway 2개 삭제·EIP 반납까지 합니다(약 하루 USD 2.8 절감). 출근 시 `--start-nat` 은 노드보다 먼저 NAT를 만들고 앱 라우트 테이블을 새 NAT로 돌립니다.
```bash
./scripts/daily-stop.sh --stop-nat     # 또는 daily-stop.sh 후 ./scripts/nat-stop.sh
./scripts/daily-start.sh --start-nat   # 또는 ./scripts/nat-start.sh 후 daily-start.sh
```
> `nat-stop.sh` 는 VPC 안의 EC2가 종료되기를 최대 5분(`NAT_STOP_INSTANCE_WAIT`) 기다리고, 그래도 남아 있으면 멈춥니다(노드 egress 보호, `--force` 로 무시). EIP는 NAT에 붙어 있던 것과 `petclinic-nat-2a/2c` 이름의 남은 것만 반납합니다. 둘 다 `--dry-run` 을 지원합니다.

---
