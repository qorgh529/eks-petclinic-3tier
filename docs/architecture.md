# 아키텍처

## 1. 개요 — 시스템 목적과 범위

`spring-framework-petclinic`(전통적인 Spring Framework 7.x / Jakarta EE 11 WAR 패키징 기반 동물병원 관리 웹 애플리케이션)을 AWS 서울 리전(`ap-northeast-2`)의 **Amazon EKS (`1.36`)** 환경 위에 고가용성(Multi-AZ: `2a`, `2c`), 정교한 자동 확장(HPA / KEDA / Karpenter), 계층별 네트워크·권한 격리, 3축 통합 관측성(Prometheus / Grafana / Alertmanager / CloudWatch Logs / OpenTelemetry + Grafana Tempo 분산 트레이싱)을 갖춘 클라우드 네이티브 아키텍처로 운영한다.

- **포함 범위 (In-Scope)**:
  - Route 53, ACM, AWS WAFv2, LBC 기반 internet-facing ALB(`target-type: ip`)를 통한 엣지 보안 및 TLS 종단
  - 공인 서비스 도메인의 루트 경로 `https://${DOMAIN_NAME}/`를 통한 반응형 정적 병원 랜딩 페이지 제공(Web Nginx 로컬 직접 서빙, 외부 CDN·웹폰트·지도 API 의존성 완전 배제, WAS/DB 무관 100% 무중단 서비스, 일관된 디자인의 404 커스텀 페이지 `error_page 404 /404.html` 내장)
  - 공인 서비스 도메인의 하위 경로 `https://${DOMAIN_NAME}/was/`를 통한 직원용 PetClinic 관리 애플리케이션 격리 및 `https://${DOMAIN_NAME}/grafana/`를 통한 Grafana 대시보드 안전한 외부 공개(AWS WAFv2 Priority 0 IP 화이트리스트 차단 규칙 `BlockUnauthorizedStaffAccess` + `GRAFANA_ALLOWED_CIDRS` IPSet, 3단계 정규화[`URL_DECODE` → `NORMALIZE_PATH` → `LOWERCASE`], 차단 시 전용 커스텀 403 HTML[`petclinic-staff-403`, `waf-staff-403.html`] 및 Web Nginx 공개 정적 이미지[`/resources/images/403.webp`] 지연 로딩 결합, `scripts/deploy-all.sh` 배포 전 WAF 검증 게이트 `staff_waf_ready`, 긴급 롤백 시 사이트 전체 선차단 `STAFF_WAF_SCOPE=all` 지원)
  - NGF Gateway API `HTTPRoute` 및 `ReferenceGrant` 기반 최장 접두사 일치 L7 라우팅, Grafana의 `server.serve_from_sub_path=true` 및 쿠키 `Path=/grafana/` 격리, `networkpolicy-grafana.yaml` 최소 권한 인입 격리
  - NGINX Gateway Fabric(NGF) `Gateway` 및 `HTTPRoute`를 이용한 L7 라우팅과 헤더(`X-Canary: always`) 검증 통과 후 100:0 → 90:10으로 여는 가중치 기반 카나리(Canary) 트래픽 분할 (Gateway API 최장 접두사 일치 규칙에 의해 `/grafana` 8자가 `/` 1자 카나리 분할보다 항상 우선 평가되어 상호 무간섭 보장)
  - `web`(Nginx 1.27 정적 서빙 + `/was/` 리버스 프록시, `X-Forwarded-Proto https` 및 `X-Forwarded-Port 443` 전달, `absolute_redirect off;`)과 `was`(Tomcat 11 언패킹 `webapps/was` + `RemoteIpValve` HTTPS 스키마 인식 + 1차 릴리스 호환 `RewriteValve` + JMX Exporter + OpenTelemetry Java Agent 무코드 자동 주입) 2-Tier 분리(롤링 배포 시 구버전 Pod 간섭을 차단하는 `matchLabelKeys: [pod-template-hash]` 기반 Multi-AZ 균등 분산 및 stable PDB `minAvailable: 1`) 및 각각 CPU 기반 HPA / Prometheus 요청률 기반 KEDA 오토스케일링
  - Spring MVC `redirect:` 시 리버스 프록시 뒤의 Tomcat이 프록시 HTTPS 종단을 인식하지 못해 발생하던 `http://` 302 → ALB `301 Moved Permanently`(`https://`) 왕복 지연 및 혼합 콘텐츠 보안 취약점을 Tomcat `RemoteIpValve`(사설 IP 대역 `internalProxies` 신뢰) 구성을 통해 근본적으로 해결
  - `was`와 `web`의 단계적 롤아웃 및 안전한 카나리 검증 순서 확립(`deploy-all.sh`에서 WAS를 먼저 배포하여 롤아웃 완료를 대기한 후 Web 매니페스트를 적용, `STABLE_IMAGE_TAG` 변경 시 `PROMOTE_STABLE=1` 명시적 승인 강제, `/was/owners` E2E 카나리 검증 후 트래픽 개방)
  - 롤링 업데이트 및 Pod 삭제 시 비동기 EndpointSlice 전파 시차(1~3초)로 인한 HTTP 502/504(Connection refused) 요청 단절을 방지하는 무중단 그레이스풀 셧다운(`lifecycle.preStop.sleep: 15s` 선언형 훅 및 `terminationGracePeriodSeconds` `web` 35초 / `was` 45초 적정 유예 시간 적용, `scripts/validate-manifests.sh` 회귀 방지 정적 검증)
  - 3-Tier 노드 분리: `np-app`(Karpenter On-Demand 기본 풀 + `np-app-spot` Spot 확장 풀), `ng-critical`(클러스터 컨트롤러·OpenTelemetry Operator 및 DB 초기화/백업 Job 전용 관리형 노드 그룹), `ng-platform`(모니터링·분산 트레이싱 스택 및 `gp3` PVC 전용 관리형 노드 그룹)
  - 프라이빗 DB 서브넷의 RDS MySQL 8.4 LTS Multi-AZ(Primary/Standby 동기 복제), S3 암호화 백업(`CronJob`), 역할별 DB 계정(admin/app/backup) 분리, AWS Secrets Manager + External Secrets Operator(ESO) 기반 시크릿 동기화
  - OpenTelemetry(Operator · Java Agent · Collector) + Grafana Tempo(전용 S3 버킷 IRSA 연동) 기반 분산 트레이싱(SDK 10% 헤드 샘플링), 100% 전수 RED 메트릭(`http_server_request_duration_seconds`) 및 Trace-based Exemplar(`trace_id`) 점프, Logback MDC(`trace_id`/`span_id`) 로그 상관분석
  - OpenTelemetry RED 메트릭 기반의 정밀한 WAS 5xx 에러율 감시 및 promtool 단위 테스트 체계 (Tomcat MBean의 4xx 포함 왜곡을 배제하고 `http_server_request_duration_seconds_count`의 `5..` 상태 코드 필터링을 적용하여 저트래픽·404 요청 시 오경보 방지, `scripts/test-prometheus-rules.sh` 오프라인 회귀 검증)
  - 업무 외 시간 비용 절감을 위한 일일 리소스 중지·기동 스크립트(`scripts/daily-stop.sh`, `scripts/daily-start.sh` — Karpenter 앱 노드, EKS 관리형 노드 그룹, RDS MySQL 일괄 제어 및 잔여 비용 안내)
  - 저장소 코드 기반의 완전한 VPC 및 네트워크 인프라 멱등 프로비저닝(`infra/aws/provision-aws-resources.sh vpc` — VPC `10.0.0.0/16`, 서브넷 6개, IGW, 라우트 테이블 4개, EIP 및 Multi-AZ NAT Gateway 2개 일괄 구성, `ap-northeast-2` 리전 강제 고정, 태그 기반 멱등 재사용 및 `.env` 설정 출력)과 업무 외 시간 NAT Gateway 삭제 및 EIP 반납을 통한 일일 약 $2.83(월 약 $85) 고정비 절감 스크립트(`scripts/nat-stop.sh`, `scripts/nat-start.sh` 및 `daily-stop.sh --stop-nat` / `daily-start.sh --start-nat` 연동)
  - AWS CodeBuild 기반 컨테이너 이미지 온디맨드 빌드 및 ECR 푸시 파이프라인(`scripts/build-and-push.sh`, `buildspec.yml` — 작업 서버의 rootless 컨테이너 제약을 격리하고 표준 클라우드 환경에서 `web`/`was` 멀티스테이지 이미지를 `linux/amd64`로 빌드·푸시, 전용 S3 소스 버킷 1일 만료, 최소 권한 IAM Role, 불변 태그 중복 차단 및 `latest` 금지)
- **제외 범위 (Out-of-Scope)**:
  - Spring Boot 내장 톰캣 JAR로의 전환 (외부 Tomcat 11 컨테이너 배포 구조 유지)
  - 멀티 리전 액티브-액티브 구성 (`ap-northeast-2` 단일 리전 Multi-AZ에 집중)
  - 기존 EKS 1.31 클러스터의 제자리 업그레이드 절차 (현재 구성은 1.36 새 클러스터 생성 기준, `docs/features/production-hardening/design.md` §1.3)
  - 비즈니스 도메인 엔티티 스키마 및 DB 테이블(DDL) 변경 (단, 외부 RDS 환경변수 바인딩, flatpickr `yyyy/MM/dd` 날짜 형식 호환 패치, 대시보드 전용 읽기 전용 `VisitSummary` 프로젝션 DTO 도입은 반영)
  - NGINX Gateway Fabric(NGF) 데이터 플레인 자체에 별도 `preStop` 주입 (AWS ALB의 `deregistration_delay` 및 워크로드 계층 `preStop`으로 충분)
  - `docker/web/nginx.conf`의 `proxy_next_upstream` 확장 및 `web` 컨테이너 이미지 재빌드(`v1.0.3`) 제외 (ClusterIP 가상 IP 환경에서 Service IP 재시도 한계 및 비멱등 POST 요청 중복 실행 위험 방지, WAS 계층의 `preStop`으로 상류 연결 거부 원천 차단)
  - CoreDNS TTL 강제 변경 또는 별도의 커스텀 셧다운 컨트롤러 도입 제외
  - 신규 서브도메인(`grafana.${DOMAIN_NAME}`) 및 신규 ACM 인증서 도입 제외 (단일 도메인 `${DOMAIN_NAME}` 하위 경로 방식을 일관되게 유지, `docs/features/grafana-public-path/design.md` §1.3)
  - 별도 ALB 생성 또는 IngressGroup을 통한 ALB 리스너 복잡화 제외 (L7 라우팅은 NGF에 전담시켜 ALB 리스너 수정 및 기존 서비스 중단 위험 방지, `docs/features/grafana-public-path/design.md` §1.3)
  - Grafana 외부 SSO(OAuth2/OIDC/Keycloak/Cognito) 연동 제외 (AWS Secrets Manager 동기화 관리자 자격증명 `grafana-admin` 체계 유지, `docs/features/grafana-public-path/design.md` §1.3)
  - 일일 중지 시 EKS 컨트롤 플레인, ALB(`Ingress`), `gp3` EBS PVC 삭제·재생성 및 EventBridge/Lambda 기반 자동 스케줄러 구축 (NAT Gateway는 기본 중지 대상에서는 제외하되, 선택적 `--stop-nat`/`--start-nat` 플래그 및 독립 실행 스크립트로 온디맨드 수명주기 제어 지원, `docs/features/daily-stop-start/design.md` §1.4, `docs/features/vpc-provisioning/design.md` §1.4)
  - Grafana Loki 도입, Tail-based Sampling, NGF·`web`(Nginx) 계층 트레이싱, `tempo-distributed`(마이크로서비스 모드 + Kafka) 전환 및 상용 APM 도입 (`docs/features/apm-tracing/design.md` §1.4, `docs/features/tempo-chart-migration/design.md` §1.4)
  - GitHub Webhook 및 AWS CodePipeline 자동 트리거 연동 (운영자/개발자가 검증된 태그로 필요 시 트리거하는 온디맨드 CLI 빌드 워크플로 유지, `docs/features/codebuild-image-build/design.md` §1.4)
  - WAS 애플리케이션 소스 코드 및 컨테이너 이미지 수정, OTel Agent/Collector 설정 변경, KEDA ScaledObject 쿼리(Tomcat 메트릭 유지) 변경 제외 (PrometheusRule 알림 수식 개선 및 promtool 테스트 확충에 집중, `docs/features/alert-5xx-accuracy/design.md` §1.5)

---

## 2. 구성 요소 — 각 컴포넌트의 역할

| 계층 | 구성 요소 | 역할 및 주요 특징 | 배치 위치 (네임스페이스 / 노드 티어) |
|---|---|---|---|
| **Edge / DNS** | Route 53, ACM, AWS WAFv2 | 도메인 A(Alias) 라우팅, 공인 TLS 인증서 발급·갱신, 최우선순위(Priority 0) 직원/운영자 전용 경로(`/was*`, `/grafana*`) 비인가 IP 차단 규칙(`BlockUnauthorizedStaffAccess` + `GRAFANA_ALLOWED_CIDRS` IPSet, URL 디코딩/경로 정규화) 및 전용 403 커스텀 응답 본문(`petclinic-staff-403`, `waf-staff-403.html`), 긴급 롤백 시 사이트 전면 보호를 위한 `STAFF_WAF_SCOPE=all` 지원, OWASP/SQLi/KnownBadInputs 관리형 규칙 필터링 | AWS 관리형 (`ap-northeast-2`) |
| **Network / VPC** | VPC, 서브넷(6개), IGW, 라우트 테이블(4개), NAT Gateway(2개), EIP | VPC `10.0.0.0/16`(DNS hostnames/support 활성화), Multi-AZ(`2a`, `2c`) 퍼블릭(ALB/NAT)·앱 프라이빗(EKS 노드)·DB 프라이빗(RDS) 서브넷 6개, IGW, 라우트 테이블 4개(퍼블릭 `0.0.0.0/0 -> IGW`, 앱 2a `0.0.0.0/0 -> NAT 2a`, 앱 2c `0.0.0.0/0 -> NAT 2c`, DB 격리 로컬 전용). 저장소 내 스크립트(`provision-aws-resources.sh vpc`)로 태그(`Name=petclinic-*`, `Project=petclinic`) 기반 멱등 프로비저닝, 리전(`ap-northeast-2`) 강제 고정 및 `.env` 출력. 업무 외 시간 비용 절감을 위한 온디맨드 NAT 삭제·복원(`scripts/nat-stop.sh`, `scripts/nat-start.sh`) 및 일일 스크립트 연동 | AWS VPC 및 EC2 네트워크 인프라 (`ap-northeast-2`) |
| **Ingress LB** | AWS ALB (AWS Load Balancer Controller) | HTTP(`80`)→HTTPS(`443`) 리다이렉트, TLS 1.3/1.2 종단, 비정상 헤더 드롭, `target-type: ip`로 NGF Pod에 직접 라우팅 | 퍼블릭 서브넷 (`2a`, `2c`) |
| **L7 Gateway** | NGINX Gateway Fabric 2.x (`nginx-gateway`) | Gateway API(`v1.6.3`). 컨트롤 플레인(2 Replicas)이 Gateway마다 데이터 플레인 `petclinic-gateway-nginx`(2 Replicas, AZ 분산, 차트 PDB `minAvailable: 1`, `ClusterIP`)를 생성. `gateway.yaml`의 `allowedRoutes`를 `petclinic`과 `nginx-gateway`로 허용하고, `HTTPRoute`로 `web` / `web-canary` 트래픽 분할(배포 중 100:0, 카나리 검증 후 90:10, `X-Canary: always`는 항상 `web-canary`) 및 `/grafana` 경로 전용 `HTTPRoute`(`httproute-grafana.yaml`)를 통해 최장 접두사 일치(8자 > 1자)로 카나리 간섭 없이 `monitoring` 네임스페이스의 Grafana Service(`:80`)로 L7 라우팅 | `nginx-gateway` / `np-app` (`workload-tier=app`) |
| **Web Tier** | `web`, `web-canary` (Nginx + Exporter) | 무외부의존 병원 공개 정적 랜딩 페이지(`/`, `index.html`, `landing.css`, `hospital.webp`)를 WAS/DB와 무관하게 로컬에서 직접 서빙하고, 정적 에셋(`/resources/*`, `/webjars/*`) 및 WAS 컨텍스트 정적 경로(`/was/resources/*`, `/was/webjars/*`)를 보안/캐시 만료 헤더와 함께 직접 서빙. 커스텀 404 안내 페이지(`error_page 404 /404.html`) 내장. 동적 직원 업무 요청(`/was/*`)을 각각 `was-stable:8080`, `was-canary:8080`으로 프록시(헤더 `X-Forwarded-Proto https`, `X-Forwarded-Port 443`, `Host`, `X-Real-IP`, `X-Forwarded-For` 전달 및 `absolute_redirect off`). 사이드카 `nginx-prometheus-exporter`(`:9113`) 내장. `topologySpreadConstraints` 기반 AZ 균등 분산(`topologyKey: topology.kubernetes.io/zone`, `maxSkew: 1`, `matchLabelKeys: [pod-template-hash]` — stable `DoNotSchedule`, canary `ScheduleAnyway`). CPU 60% 기준 HPA(`web` 2~10, `web-canary` 1~4), stable PDB(`minAvailable: 1`). `terminationGracePeriodSeconds: 35` 및 메인 `nginx`·사이드카 `nginx-exporter` 공통 `lifecycle.preStop.sleep: 15s` 적용으로 롤링 배포 시 엔드포인트 등록 해제 지연을 흡수하여 HTTP 502 방지 및 메트릭 수집 연속성 보장 | `petclinic` / `np-app` (`workload-tier=app`) |
| **WAS Tier** | `was-stable`, `was-canary` (Tomcat 11 + JMX Exporter + OTel Java Agent) | 사전 언패킹된 `webapps/was` 구동(`jpa` 프로필, 서블릿 컨텍스트 `/was`, 읽기 전용 루트 파일시스템), `server.xml`의 `RemoteIpValve`로 상류 사설 프록시 헤더(`X-Forwarded-Proto https`, `X-Forwarded-Port 443`)를 신뢰하여 Spring MVC 302 리다이렉트 시 `https://` Location 헤더 즉시 발급, 1차 릴리스 호환을 위한 `RewriteValve`(`rewrite.config`)로 비`/was` 요청 내부 재작성(k8s startup/readiness probe `/` 수용 및 신·구버전 이미지 상호 교체성 보장), `WelcomeController` 기반 직원 메인 대시보드(`/was/`, `/was/welcome` — 운영 통계 3종 및 `VisitSummary` 플랫 프로젝션 기반 최근 방문 5건 조회) 및 PetClinic 비즈니스 서블릿 처리, flatpickr 스타일/스크립트 링크의 `<spring:url>` 컨텍스트 상대 경로 자동 반영, JMX Exporter(`:9404/metrics`) 노출 및 OpenTelemetry Operator가 주입하는 Java Agent(`autoinstrumentation-java:2.12.0`)로 HTTP·Spring MVC·Hibernate/JDBC 자동 계측(`service.version=stable\|canary`), Logback ConfigMap 마운트로 MDC `trace_id`/`span_id` 출력. `topologySpreadConstraints` 기반 AZ 균등 분산(`topologyKey: topology.kubernetes.io/zone`, `maxSkew: 1`, `matchLabelKeys: [pod-template-hash]` — stable `DoNotSchedule`, canary `ScheduleAnyway`). Prometheus 요청률 기반 KEDA `ScaledObject`(`was-stable` 2~10·fallback 4, `was-canary` 1~3·fallback 2), stable PDB(`minAvailable: 1`), Tomcat JDBC 풀 최대 10. `terminationGracePeriodSeconds: 45` 및 `lifecycle.preStop.sleep: 15s` 적용으로 롤링 배포 시 엔드포인트 등록 해제 대기 후 Catalina 종료 훅 → Spring 웹 컨텍스트 종료 → Tomcat JDBC Pool 해제 → OTel 트레이스 플러시 순차적 정상 종료 보장 | `petclinic` / `np-app` (`workload-tier=app`) |
| **Cluster Controllers** | CoreDNS, LBC, Metrics Server, Karpenter, KEDA, ESO, EBS CSI, OpenTelemetry Operator | 클러스터 핵심 제어부, 오토스케일러·시크릿·스토리지 드라이버 및 `Instrumentation` CR 기반 Java Agent Mutating Webhook(`:9443`, `failurePolicy: Ignore`) | `kube-system`, `keda`, `external-secrets`, `opentelemetry-operator-system` / `ng-critical` (Taint: `node-role=critical:NoSchedule`) |
| **DB Jobs** | `db-init` (Job), `db-backup` (CronJob) | 배포 시 admin 계정으로 멱등 스키마/초기 데이터 적재(`schema.sql`, `data.sql`) 및 app/backup 계정 생성·권한 부여, 매일 03:00 KST `mysqldump` 압축본을 S3(`SSE-KMS`)에 업로드 | `petclinic` / `ng-critical` (Taint: `node-role=critical:NoSchedule`) |
| **Observability & Tracing** | Prometheus, Grafana, Alertmanager, OTel Collector, Grafana Tempo, kube-state-metrics, node-exporter, Fluent Bit | `ServiceMonitor` 기반 `web`(`:9113`)·`was`(`:9404`)·`otel-collector`(`:8889`, OpenMetrics Exemplar) 스크래핑, KEDA 스케일링 쿼리 제공, `gp3` 암호화 볼륨 영속화, Prometheus 2 Replicas(`exemplar-storage` 활성화) AZ 분산, `PrometheusRule`(DB 백업 미수행, KEDA 지표 오류, OTel RED 메트릭 기반 WAS 5xx 에러율 5% 초과 감시) → Alertmanager Webhook. Grafana는 `https://${DOMAIN_NAME}/grafana/` 하위 경로(subpath)를 통해 인가된 IP에 외부 공개(`server.serve_from_sub_path=true`, 쿠키 `Path=/grafana/` 격리, `cookie_secure`, `cookie_samesite=lax`, `allow_embedding=false`, 익명/회원가입 차단). `ReferenceGrant`로 `nginx-gateway` HTTPRoute의 접근을 허용하고, `NetworkPolicy`로 NGF 데이터 플레인 Pod(`petclinic-gateway`) 및 Prometheus 인입만 허용(:3000). Alertmanager는 `slack_configs`의 `api_url_file`로 Slack Incoming Webhook 시크릿을 읽어 알림 전송. OTel Collector(2 Replicas AZ 분산, `:4317`/`:4318` 수신)는 트레이스를 Tempo(`:4317` 수신, `:3200` 쿼리, `gp3` 10Gi WAL + 전용 S3 IRSA)로 전달하고 RED 메트릭+Exemplar를 `:8889`로 노출. `node-exporter` 및 Fluent Bit DaemonSet은 전 노드에서 메트릭·컨테이너 로그(→ CloudWatch Logs) 수집 | `monitoring` (`ng-platform`, Taint: `node-role=platform:NoSchedule`; `node-exporter`는 전 노드 Toleration) / `amazon-cloudwatch` (Fluent Bit 전 노드 Toleration) |
| **Build & CI/CD** | AWS CodeBuild Project (`${CODEBUILD_PROJECT_NAME}`), S3 소스 버킷(`${CODEBUILD_S3_BUCKET_NAME}`), Service Role (`CodeBuildServiceRole-${EKS_CLUSTER_NAME}`) | 작업 서버(LXC)의 rootless podman 제약 없이 AWS 관리형 x86_64(`BUILD_GENERAL1_MEDIUM`, `privilegedMode: true`) 환경에서 Docker in Docker로 `web`/`was` 멀티스테이지 컨테이너 이미지를 `linux/amd64`로 빌드하여 ECR에 푸시. 불변 태그 중복 사전 검증, `latest` 차단, 실행별 고유 S3 소스 키 및 1일 만료 수명주기 적용 | AWS 관리형 (`ap-northeast-2`) |
| **Data / Storage / Registry** | RDS MySQL 8.4 LTS, Secrets Manager, S3 (백업·Tempo·CodeBuild 소스 3개 버킷), ECR | Multi-AZ Primary/Standby RDB(`8.4.11`, `mysql8.4` 파라미터 그룹, `require_secure_transport=ON`), RDS(admin/app/backup)·Grafana·Alertmanager Webhook 시크릿 보관, DB 백업 버킷(`BACKUP_S3_BUCKET_NAME`, 버전 관리), Tempo 트레이스 전용 버킷(`TEMPO_S3_BUCKET_NAME`, 만료 Lifecycle), CodeBuild 소스 아카이브 버킷(`CODEBUILD_S3_BUCKET_NAME`, 1일 만료 Lifecycle; 3개 버킷 상호 이름 격리 검증), 불변 태그(`IMMUTABLE`) 및 KMS 암호화 컨테이너 레지스트리 | 프라이빗 DB 서브넷 (`2a`, `2c`) 및 AWS 관리형 서비스 |

---

## 3. 디렉터리 구조

```text
.
├── .env.example                          # 환경변수 템플릿 (GRAFANA_ALLOWED_CIDRS, CODEBUILD_*, BUILD_TARGET 포함, source 검증 통과)
├── .gitattributes                        # 셸 스크립트 LF 줄바꿈 및 실행 권한 유지
├── .gitignore                            # 빌드 산출물, .env, 로컬 시크릿, .daily-nodegroup-state.json 제외
├── AGENTS.md                             # Codex 코드 리뷰어 규칙
├── CLAUDE.md                             # Claude 구현 규칙
├── ORCA_WORKFLOW.md                      # 에이전트 역할 분담 및 워크플로 정의
├── README.md                             # 프로젝트 아키텍처 개요, 빠른 시작 가이드 및 Day-2 운영 런북 (VPC 프로비저닝, 일일 NAT 제어, CodeBuild 빌드 설명 포함)
├── buildspec.yml                         # AWS CodeBuild 빌드 명세서 (pre_build 태그 정규식·latest 검증 및 ECR 로그인 → build linux/amd64 → post_build ECR 푸시, 단계별 on-failure: ABORT)
├── docs/
│   ├── architecture.md                   # 시스템 전체 아키텍처 현황 (본 문서)
│   ├── architecture-overview.drawio      # 인프라 계층·설정값·포트 흐름 중심의 개요 다이어그램 원본 (서브넷 CIDR, 노드그룹 사양, RDS Multi-AZ, Edge, CI/CD·관측)
│   ├── architecture-overview.drawio.{svg,png} # 내보낸 개요 다이어그램 이미지 (draw.io 데스크톱에서 내보냄)
│   ├── architecture.drawio               # AWS·Kubernetes 공식 아이콘 기반 Pod 단위 아키텍처 다이어그램 원본 (AZ × 서브넷 격자, 노드별 Pod 배치, K8s 리소스 행, 범례)
│   ├── architecture.drawio.{svg,png}     # 내보낸 다이어그램 이미지 (Embedded XML 포함, draw.io 데스크톱에서 내보냄)
│   ├── design.md                         # 초기 구축 설계서
│   ├── review.md                         # 코드 리뷰 기록
│   ├── security.md                       # 보안·인프라 점검 기록
│   ├── daily/                            # 조율 에이전트 일일 작업 기록 (TEMPLATE.md, YYYY-MM-DD.md)
│   ├── archive/                          # 이전 다이어그램 백업 (architecture-2026-10-24.drawio{,.svg,.png} — Pod 상세화 이전 개요도)
│   └── features/                         # 기능 브랜치별 설계·리뷰·보안 점검 기록
│       ├── production-hardening/{design,review,security}.md
│       ├── daily-stop-start/{design,review,security}.md
│       ├── apm-tracing/{design,review,security}.md
│       ├── tempo-chart-migration/{design,review,security}.md
│       ├── architecture-pod-diagram/design.md   # 다이어그램 Pod 단위 상세화 설계 (Pod 배치 표, 선 규칙)
│       ├── codebuild-image-build/{design,review,security}.md  # CodeBuild 기반 컨테이너 이미지 빌드·푸시 설계·리뷰·보안 점검
│       ├── rds-mysql-84/{design,review,security}.md           # RDS MySQL 8.4 LTS 전환 설계·리뷰·보안 점검
│       ├── staff-dashboard/                  # 스태프 운영 대시보드(WelcomeController, VisitSummary) 설계·목업·리뷰·보안 점검
│       │   ├── mockup/main.html              # UI 프로토타입 원본
│       │   └── {design,review,security}.md
│       ├── spread-on-rollout/                # 롤링 업데이트 시 AZ 균등 분산 보장(matchLabelKeys) 설계·리뷰·보안 점검
│       │   └── {design,review,security}.md
│       ├── graceful-shutdown/                # 무중단 서비스 및 그레이스풀 셧다운(preStop.sleep, grace period) 설계·리뷰·보안 점검
│       │   └── {design,review,security}.md
│       ├── grafana-public-path/              # Grafana 하위 경로 오픈 및 WAF IP 화이트리스트 접근 제어 설계·리뷰·보안 점검
│       │   └── {design,review,security}.md
│       ├── vpc-provisioning/                 # VPC 멱등 프로비저닝 및 NAT 라이프사이클 관리 설계·리뷰·보안 점검
│       │   └── {design,review,security}.md
│       ├── vpc-provisioning/                 # VPC 멱등 프로비저닝 및 NAT 라이프사이클 관리 설계·리뷰·보안 점검
│       │   └── {design,review,security}.md
│       ├── alert-5xx-accuracy/               # WAS 5xx 에러율 경보 정확도 개선(OTel RED 메트릭 전환, promtool 단위 테스트) 설계·리뷰·보안 점검
│       │   └── {design,review,security}.md
│       └── landing-page/                     # 병원 랜딩 페이지 구축 및 직원용 PetClinic WAS 하위 경로(/was/) 격리 설계·리뷰·보안 점검
│           └── {design,review,security}.md
├── app/                                  # spring-framework-petclinic 소스 코드
│   ├── pom.xml                           # Maven WAR 빌드, MySQL/PostgreSQL/H2/HSQLDB 프로필
│   └── src/
│       ├── main/
│       │   ├── java/org/springframework/samples/petclinic/
│       │   │   ├── model/VisitSummary.java   # 대시보드 최근 방문 읽기 전용 플랫 프로젝션 DTO (EAGER 연관 N+1 방지)
│       │   │   ├── repository/{Owner,Pet,Visit}Repository.java # count 쿼리 및 findRecentVisits(limit) 지원 (jdbc, jpa, springdatajpa 3종 구현체)
│       │   │   ├── service/ClinicService{,Impl}.java # 대시보드 통계 및 최근 방문 읽기 전용(@Transactional(readOnly = true)) 서비스 파사드
│       │   │   └── web/WelcomeController.java # 직원 메인 대시보드(/was/, /was/welcome) 라우팅 및 모델 바인딩
│       │   ├── resources/
│       │   │   ├── db/mysql/{schema.sql,data.sql}
│       │   │   └── spring/{mvc-core-config.xml,data-access.properties,datasource-config.xml,...}
│       │   └── webapp/                   # 정적 리소스(resources/) 및 JSP 뷰(WEB-INF/jsp/ — welcome.jsp 대시보드, flatpickr <spring:url> 상대 경로 적용)
│       │       └── resources/images/     # hospital.webp(~260KB 병원 대표 사진), 403.webp(~200KB 직원 전용 안내 사진)
│       └── test/...                      # WelcomeControllerTests 및 AbstractClinicServiceTests 3종 프로필 회귀 테스트
├── docker/
│   ├── web/
│   │   ├── Dockerfile                    # Stage 1: 정적 에셋 추출 → Stage 2: nginx:1.27.2-alpine (랜딩 index.html, 404.html, css/landing.css 포함)
│   │   ├── nginx.conf                    # 루트 / 정적 랜딩 직접 서빙, /404.html 에러 페이지, /was/ 프록시(X-Forwarded-Proto https, absolute_redirect off)
│   │   └── static/                       # 정적 랜딩 및 안내 페이지 (index.html, 404.html, css/landing.css)
│   └── was/
│       ├── Dockerfile                    # Stage 1: WAR 빌드·was 언패킹(/webapps/was) → Stage 2: tomcat:11.0.2 (server.xml, rewrite.config 포함)
│       ├── jmx-exporter-config.yaml      # Tomcat GlobalRequestProcessor / ThreadPool / JVM JMX 수집 규칙
│       ├── rewrite.config                # 1차 릴리스 비/was 요청 내부 재작성 규칙 (k8s 프로브 / 및 신구 이미지 호환)
│       ├── server.xml                    # Tomcat RemoteIpValve(사설 프록시 헤더 신뢰) 및 RewriteValve 선언
│       └── setenv.sh                     # conf/Catalina emptyDir에 rewrite.config 복사, JMX Agent 및 JDBC 드라이버 프로퍼티 설정
├── infra/
│   ├── aws/
│   │   ├── provision-aws-resources.sh    # vpc, pre-cluster, cluster, post-cluster, grafana-waf(WAF IPSet 및 Priority 0 BlockUnauthorizedStaffAccess 규칙, petclinic-staff-403 본문 등록, STAFF_WAF_SCOPE=all 지원) 멱등 프로비저닝
│   │   ├── waf-staff-403.html            # WAF 커스텀 403 Forbidden HTML 본문 (인라인 반응형 스타일, /resources/images/403.webp 지연 로딩)
│   │   └── iam-policies/                 # lbc, karpenter-controller, karpenter-node-trust, eso, fluent-bit, db-backup, tempo, codebuild 최소 권한 JSON 및 codebuild-trust.json
│   ├── eksctl/
│   │   └── cluster.yaml                  # EKS 1.36 ClusterConfig (VPC 서브넷, IRSA [monitoring/tempo 포함], vpc-cni NetworkPolicy, EBS CSI 버전 고정, ng-critical, ng-platform)
│   └── karpenter/
│       ├── ec2nodeclass.yaml             # AL2023 고정 AMI(al2023@v20260930), IMDSv2(hop limit 1), gp3 30Gi 암호화 루트 볼륨
│       └── nodepool-app.yaml             # np-app(On-Demand, weight 100) 및 np-app-spot(Spot 오버플로 확장) NodePool
├── k8s/
│   ├── base/
│   │   ├── namespace.yaml                # 네임스페이스별 Pod Security Standards(restricted [petclinic, opentelemetry-operator-system] / baseline / privileged) 정의
│   │   ├── networkpolicy-petclinic.yaml  # petclinic 기본 거부(Ingress/Egress) 및 DNS·web→was·RDS(3306)·백업(443)·was→otel-collector(4317/4318) 허용 정책
│   │   └── storageclass-gp3.yaml         # EBS CSI gp3 암호화 StorageClass (WaitForFirstConsumer)
│   ├── secrets/
│   │   ├── secretstore.yaml              # ESO SecretStore (AWS Secrets Manager 연동)
│   │   └── externalsecret-rds.yaml       # Secrets Manager → admin/app/backup 역할별 3개 시크릿 동기화 (sslMode=REQUIRED 포함)
│   ├── jobs/
│   │   ├── job-db-init.yaml              # admin 계정으로 schema/data 적재 + app/backup 계정 생성·최소 권한 부여 Job (ng-critical, mysql:8.4.11, REQUIRE SSL)
│   │   └── cronjob-db-backup.yaml        # 일일 mysqldump(backup 계정) → S3(SSE-KMS) 업로드 CronJob (ng-critical, mysql:8.4.11, IRSA db-backup)
│   ├── web/
│   │   ├── deployment.yaml               # web(→was-stable) 및 web-canary(→was-canary) Deployment + nginx-exporter 사이드카 (리비전별 AZ 토폴로지 분산 matchLabelKeys, preStop.sleep 15초 및 terminationGracePeriodSeconds 35초 적용)
│   │   ├── service.yaml                  # web, web-canary Service (:80→:8080, :9113)
│   │   ├── hpa.yaml                      # web(2~10), web-canary(1~4) CPU 60% HPA
│   │   ├── pdb.yaml                      # web stable PodDisruptionBudget (minAvailable: 1)
│   │   └── networkpolicy.yaml            # web Ingress 허용 (nginx-gateway → 8080, Prometheus → 9113)
│   ├── was/
│   │   ├── instrumentation.yaml          # OpenTelemetry Instrumentation CR (petclinic-java) 및 Logback MDC 출력용 ConfigMap (petclinic-was-logback)
│   │   ├── deployment-stable.yaml        # was-stable Deployment (inject-java, service.version=stable, Logback 마운트, 1280Mi~2Gi, readiness initialDelaySeconds 20, 리비전별 AZ 토폴로지 분산 matchLabelKeys, preStop.sleep 15초 및 terminationGracePeriodSeconds 45초 적용)
│   │   ├── deployment-canary.yaml        # was-canary Deployment (inject-java, service.version=canary, Logback 마운트, 1280Mi~2Gi, readiness initialDelaySeconds 20, 리비전별 AZ 토폴로지 분산 matchLabelKeys, preStop.sleep 15초 및 terminationGracePeriodSeconds 45초 적용)
│   │   ├── service-stable.yaml           # was-stable Service (:8080, :9404)
│   │   ├── service-canary.yaml           # was-canary Service (:8080, :9404)
│   │   ├── service.yaml                  # was 통합 Service (:8080, :9404)
│   │   ├── keda-scaledobject.yaml        # was-stable(2~10, fallback 4) / was-canary(1~3, fallback 2) KEDA ScaledObject
│   │   ├── pdb.yaml                      # was stable PodDisruptionBudget (minAvailable: 1)
│   │   └── networkpolicy.yaml            # was Ingress 허용 (web → 8080, Prometheus → 9404)
│   ├── gateway/
│   │   ├── alb-ingress.yaml              # LBC internet-facing ALB Ingress → petclinic-gateway-nginx:80 (HTTPS 443, ACM, WAFv2, drop_invalid_header_fields)
│   │   ├── gateway.yaml                  # NGF Gateway (:80 HTTP, allowedRoutes: petclinic, nginx-gateway)
│   │   ├── httproute-canary.yaml         # PetClinic HTTPRoute (X-Canary: always → web-canary, 기본 가중치 ${STABLE_WEIGHT}:${CANARY_WEIGHT})
│   │   └── httproute-grafana.yaml        # Grafana HTTPRoute (/grafana Prefix → monitoring/kube-prometheus-stack-grafana:80)
│   ├── monitoring/
│   │   ├── dashboard-apm-tracing.yaml    # Grafana APM 대시보드 ConfigMap (grafana_dashboard: "1" — 버전별 요청량·에러율·p95/p99 Exemplar·Tempo 최근 트레이스)
│   │   ├── externalsecret-alertmanager.yaml # Alertmanager Slack Webhook URL ExternalSecret (api_url_file로 마운트)
│   │   ├── externalsecret-grafana.yaml   # Grafana 관리자 자격증명 ExternalSecret
│   │   ├── kube-prometheus-values.yaml   # Prometheus(2 Replicas AZ 분산, exemplar-storage), Grafana(grafana.ini subpath 서빙 및 보안 하드닝, Tempo 연동), Alertmanager(slack_configs) 설정
│   │   ├── networkpolicy-alertmanager.yaml # Alertmanager Egress 제한 (DNS, 피어 가십 :9094, HTTPS :443만, IMDS 제외)
│   │   ├── networkpolicy-grafana.yaml    # Grafana Ingress 제한 (NGF 데이터 플레인 및 Prometheus → :3000)
│   │   ├── networkpolicy-prometheus.yaml # Prometheus Ingress 제한 (KEDA·Grafana → :9090, 자기 자신 → :9090·:8080)
│   │   ├── prometheusrule-petclinic.yaml # 백업 실패(첫 성공 없음 포함), KEDA 지표 오류, OTel RED 메트릭 기반 WAS 5xx 에러율(>5%) 알림 규칙
│   │   ├── referencegrant-grafana.yaml   # Gateway API ReferenceGrant (nginx-gateway의 HTTPRoute가 monitoring의 Grafana Service 참조 허용)
│   │   └── servicemonitor-petclinic.yaml # web(:9113), was(:9404), otel-collector(:8889, OpenMetricsText1.0.0) 스크래핑 ServiceMonitor
│   ├── tracing/
│   │   ├── otel-operator-values.yaml     # OpenTelemetry Operator Helm values (ng-critical, 자체 서명 인증서, Pod webhook failurePolicy: Ignore)
│   │   ├── otel-collector-values.yaml    # OpenTelemetry Collector Helm values (ng-platform, Deployment 2 Replicas AZ 분산, OTLP→Tempo / Prometheus :8889 OpenMetrics)
│   │   ├── tempo-values.yaml             # Grafana Tempo Helm values (grafana-community/tempo 3.2.1 단일 바이너리, ng-platform, S3 IRSA SA monitoring/tempo, gp3 10Gi WAL)
│   │   └── networkpolicy-tracing.yaml    # otel-collector 및 tempo Ingress/Egress 최소 권한 NetworkPolicy
│   └── logging/
│       └── fluent-bit-values.yaml        # aws-for-fluent-bit DaemonSet 설정 (전 노드 Toleration → CloudWatch Logs)
├── tests/
│   ├── monitoring/petclinic-rules.test.yaml  # PrometheusRule promtool 단위 테스트 (DB 백업 실패 및 4xx 배제/저트래픽/실제 5xx WAS 에러율 3종 시나리오)
│   ├── scripts/daily-stop-start.test.sh  # daily-stop.sh / daily-start.sh 오프라인 회귀 테스트 (가짜 aws/kubectl, opentelemetry-operator 순서 포함)
│   ├── scripts/build-and-push.test.sh    # build-and-push.sh 오프라인 단위 테스트 (가짜 aws CLI 기반 태그/타깃/실행별 고유 소스 키/아카이브 필터/버킷 격리 검증)
│   ├── scripts/grafana-waf-ready.test.sh # staff_waf_ready 오프라인 단위 테스트 (가짜 aws CLI 기반 WebACL /grafana·/was 규칙 순서·변환·IPSet 매핑 검증)
│   └── scripts/vpc-provisioning.test.sh  # VPC/서브넷 생성, 멱등 재사용, 리전 서울 고정, NAT 시작/종료 오프라인 모의 테스트
└── scripts/
    ├── lib.sh                            # 공통 환경변수 로드(.env), 필수 변수 검증, envsubst 렌더링 함수 (TEMPO_*, OTEL_*, CODEBUILD_* 포함, 명령줄 IMAGE_TAG/BUILD_TARGET 보존, staff_waf_ready 사전 검증)
    ├── nat-start.sh                      # AZ별 EIP 할당, NAT Gateway 생성 대기, 앱 라우트 연결 스크립트 (--dry-run 지원)
    ├── nat-stop.sh                       # VPC 잔여 EC2 종료 대기 안전장치 포함 NAT Gateway 삭제 및 EIP 반납 스크립트 (--dry-run, --force 지원)
    ├── build-and-push.sh                 # AWS CodeBuild 원격 빌드 호출 및 상태 추적 스크립트 (소스 패키징 [.git, .env*, 키 파일 제외] → 전용 S3 업로드 [실행별 고유 키] → CodeBuild 실행 및 상태 폴링, --local 지원)
    ├── deploy-all.sh                     # 애드온/트레이싱/매니페스트 배포, 배포 전 WAF 검증(staff_waf_ready), PROMOTE_STABLE=1 승격 가드, WAS 선배포 후 Web 배포, 카나리 100:0 고정 후 롤아웃, Route 53 연결, /was/owners 카나리 E2E 및 랜딩 검증 후 STABLE_WEIGHT:CANARY_WEIGHT 개방
    ├── set-canary-weight.sh              # 재배포 없이 카나리 비율 변경 (0 = 긴급 롤백, 100 = 전체 카나리)
    ├── rotate-db-secrets.sh              # Secrets Manager DB 비밀번호 변경 반영 (ESO 강제 동기화 확인 → db-init → was 재시작)
    ├── daily-stop.sh                     # 퇴근 전 앱/Karpenter 노드·RDS·관리형 노드그룹 일괄 중지 및 잔여 비용 안내 (--dry-run, --stop-nat 연동 지원)
    ├── daily-start.sh                    # 출근 시 RDS·관리형 노드그룹·컨트롤러(opentelemetry-operator 포함)·Karpenter·워크로드/오토스케일러/CronJob 일괄 복원 (--dry-run, --start-nat 연동 지원)
    ├── test-prometheus-rules.sh          # promtool로 PrometheusRule 단위 테스트 실행
    └── validate-manifests.sh             # YAML 문법, 고정 이미지/애드온 버전, 평문 시크릿 부재, 노드 티어/비루트, 역할별 DB 시크릿·PDB·KEDA fallback, 워크로드 리비전별 AZ 분산(matchLabelKeys: [pod-template-hash], maxSkew 1, zone), 그레이스풀 셧다운(preStop.sleep 15초 이상, web 35초 / was 45초 grace period), Grafana subpath/보안·ReferenceGrant·NetworkPolicy 정합성, CodeBuild, daily-stop/start, vpc-provisioning 회귀 테스트, 정적 랜딩(/) 및 /was 컨텍스트/server.xml/WAF 규칙 정합성 검증기
```

---

## 4. 데이터 흐름 — Draw.io 아키텍처 다이어그램

### 개요 다이어그램 (인프라 계층 및 설정값 조망)

> 원본 파일: [`docs/architecture-overview.drawio`](./architecture-overview.drawio) · 이미지: [`docs/architecture-overview.drawio.svg`](./architecture-overview.drawio.svg) / [`docs/architecture-overview.drawio.png`](./architecture-overview.drawio.png)

![AWS EKS 기반 Spring Framework PetClinic 아키텍처 개요](./architecture-overview.drawio.svg)

**개요도 읽는 법**
- **좌우 계층 구조**: 사용자 브라우저(좌측) → 엣지 보안(Route 53, WAFv2, ACM, IGW) → Multi-AZ VPC `10.0.0.0/16`(퍼블릭·앱·DB 서브넷) → 완전 격리 DB(RDS MySQL Multi-AZ)로 이어지며, 하단에는 AWS 관리형 운영·CI/CD·관측 서비스가 배치된다.
- **핵심 포트 흐름**: 사용자 HTTPS `:443` (HTTP `:80` 리다이렉트) → 인터넷 페이싱 ALB → NGF Gateway `:80` (`target-type: ip`) → Web Tier `:8080` (정적 랜딩 `/` 직접 서빙, 카나리 90:10 분할 및 `X-Canary: always` 헤더 라우팅, `/grafana` 최장 접두사 분기) → WAS Tier `:8080` (`/was/` 리버스 프록시) → RDS MySQL Primary `:3306` (TLS 암호화 연결).
- **서브넷 CIDR 및 네트워크 설정값**: 퍼블릭 서브넷(`10.0.0.0/24`, `10.0.1.0/24`, AZ별 NAT Gateway `petclinic-nat-2a`/`2c`), 앱 프라이빗 서브넷(`10.0.16.0/20`, `10.0.32.0/20`, EKS 1.36 워커 노드), DB 프라이빗 서브넷(`10.0.48.0/24`, `10.0.49.0/24`, 인터넷 라우트 없는 Air-Gapped 로컬 전용).
- **노드 그룹 구성**: 애플리케이션 워크로드 `np-app`(Karpenter On-Demand c6i/m6i/t3) & `np-app-spot`(Spot 확장 풀), 클러스터 핵심 컨트롤러 `ng-critical`(`m6i.large` ×2, Taint: critical), 관측성 및 스토리지 전용 `ng-platform`(`m6i.large` ×2, Taint: platform).
- **RDS Multi-AZ**: RDS MySQL 8.4.11 Multi-AZ Primary(`ap-northeast-2a`, `:3306 TLS`, `require_secure_transport=ON`)와 Standby(`ap-northeast-2c`) 간 동기식 복제.

---

### 상세 다이어그램 (Pod 단위 배치 및 K8s 리소스)

> 원본 파일: [`docs/architecture.drawio`](./architecture.drawio) · 편집 가능 이미지(Embedded XML): [`docs/architecture.drawio.svg`](./architecture.drawio.svg) / [`docs/architecture.drawio.png`](./architecture.drawio.png)

![AWS EKS 기반 Spring Framework PetClinic 아키텍처](./architecture.drawio.svg)

**상세 다이어그램 읽는 법**
- **선 종류**: 실선 = 사용자 요청 경로(①~⑥, 남색 stable / 주황 canary), 자홍 점선 = 관측(메트릭·트레이스·로그), 회색 점선 = 생성·설정·권한(컨트롤, RDS Multi-AZ 동기 복제 포함).
- **배치**: VPC를 `2a` / `2c` 두 열 × 퍼블릭·앱 프라이빗·DB 프라이빗 서브넷 행으로 나누고, EKS 클러스터 안에 AZ별 노드 박스(`np-app`/`np-app-spot`, `ng-critical`, `ng-platform`)와 그 위의 Pod를 `이름 ×기본 레플리카 (종류)` 로 그린다. 퍼블릭 서브넷(`10.0.0.0/24`, `10.0.1.0/24`)은 IGW로 향하는 라우트(`petclinic-rt-public`)를 통해 ALB와 NAT Gateway가 배치되며, 앱 프라이빗 서브넷(`10.0.16.0/20`, `10.0.32.0/20`)은 각 AZ별 NAT(`petclinic-nat-2a`, `petclinic-nat-2c`)를 통해 아웃바운드 인터넷 통신을 수행하고, DB 프라이빗 서브넷(`10.0.48.0/24`, `10.0.49.0/24`)은 외부 라우트 없이 VPC 로컬(`10.0.0.0/16`) 경로만 존재하는 완전 격리(Air-Gapped) 구조다. 배치는 `k8s/`·`infra/`·`scripts/deploy-all.sh` 기준의 의도된 배치이며 실클러스터 조회 결과가 아니다.
- **AZ 표기**: 레플리카 2개 이상이면서 zone 분산 제약이 있는 워크로드는 두 AZ에 1개씩 그린다. `AZ 비고정` 이 붙은 Pod(레플리카 1개이거나 AZ 제약 없음)는 그려진 AZ가 예시 위치다. `web` 및 `was` 워크로드는 `topologySpreadConstraints`에 `matchLabelKeys: [pod-template-hash]`를 적용하여 롤링 업데이트 시에도 구버전 ReplicaSet 간섭 없이 신규 Pod가 `2a`와 `2c`에 1개씩 균등하게 스케줄링된다 (단, K8s 스케줄러 특성상 신규 배치 시점에만 평가되므로 HPA/KEDA 스케일다운 후 불균형 발생 시에는 `rollout restart`로 재분산한다).
- **경로 단순화**: ③→④→⑤는 같은 AZ 안에서 세로로 그렸지만 실제 Service 로드밸런싱은 AZ를 넘을 수 있다. 모든 노드에 뜨는 DaemonSet(`aws-node`, `kube-proxy`, `ebs-csi-node`, `prometheus-node-exporter`, `aws-for-fluent-bit`)은 클러스터 안 띠 하나에 모아 그리고, 클러스터 하단에 주요 K8s 리소스(Ingress·Gateway·HTTPRoute·Service·HPA·ScaledObject·ConfigMap·Secret·ExternalSecret·PVC 등, CRD는 `crd` 아이콘)를 AZ 열별 두 상자로 나눠 둔다. 선이 Pod 라벨을 가로지르지 않도록 NGF 컨트롤 플레인 → 데이터 플레인 설정 배포, ESO → Secret, EBS CSI → PVC, OTel Operator → `was` 주입 경로는 선 대신 Pod 설명(또는 라벨 없는 선)으로 표시한다.

### 단계별 트래픽, 분산 트레이싱 및 제어 흐름 (① ~ ⑥)
1. **① DNS 조회**: 사용자 브라우저가 서비스 도메인 질의 시 **Amazon Route 53**에서 ALB의 A(Alias) 레코드를 반환한다.
2. **② HTTPS 접속 및 WAF 필터링**: 브라우저는 `443` 포트로 접속하며, **AWS WAFv2**의 최우선순위(Priority 0) 커스텀 규칙 `BlockUnauthorizedStaffAccess`에서 `/grafana` 또는 `/was`로 시작하는 요청(`URL_DECODE` → `NORMALIZE_PATH` → `LOWERCASE` 정규화 적용)이 `GRAFANA_ALLOWED_CIDRS` IPSet에 속하지 않는 경우 AWS 엣지에서 즉시 전용 커스텀 응답 본문(`petclinic-staff-403`, `infra/aws/waf-staff-403.html`)과 함께 HTTP 403 Forbidden으로 차단한다. WAF 본문에는 경량 인라인 스타일과 홈 복귀 버튼만 포함되며, 대표 사진(`<img src="/resources/images/403.webp">`)은 WAF 차단 대상이 아닌 공개 Web Nginx 경로에서 브라우저가 지연 로딩한다. 인가된 IP의 요청 및 일반 공개 트래픽(`/`, `/resources/*`, `/webjars/*`)은 Priority 1~3 관리형 규칙(Common / SQLi / KnownBadInputs)을 거쳐 통과한 후 **Application Load Balancer(ALB)** 에서 **AWS ACM** 공인 인증서로 TLS 종단 처리된다.
3. **③ ALB → NGF Gateway (`target-type: ip`)**: AWS Load Balancer Controller(LBC)가 구성한 ALB가 NodePort 없이 `np-app` 노드풀의 **NGF Gateway Pod** 프라이빗 IP(`:80`)로 직접 라우팅한다.
4. **④ NGF Gateway → `web` / `web-canary` (`HTTPRoute` 카나리 분할) 및 `/grafana` (Grafana 라우팅)**:
   - **`/grafana` 하위 경로 요청 (`https://${DOMAIN_NAME}/grafana/`)**: Gateway API 최장 접두사 일치(Longest Prefix Match) 원칙에 따라 `/grafana`(8자)가 PetClinic 카나리 라우트 `/`(1자)보다 항상 우선 평가된다. 요청 헤더에 `X-Canary: always`가 포함되어 있더라도 카나리 가중치 분할(90:10)이나 헤더 라우팅에 걸리지 않고 100% `nginx-gateway`의 `httproute-grafana.yaml`로 매칭된다. NGF는 `monitoring` 네임스페이스의 `ReferenceGrant`(`allow-nginx-gateway-to-grafana`)를 통해 교차 네임스페이스 참조 권한을 확인하고 `monitoring/kube-prometheus-stack-grafana:80` Service로 트래픽을 전달한다. `monitoring` 네임스페이스의 NetworkPolicy(`grafana-ingress`)는 인입 출발지가 `nginx-gateway`의 데이터 플레인 Pod(`gateway.networking.k8s.io/gateway-name: petclinic-gateway`) 또는 Prometheus Pod인 경우에만 Grafana 포트(`TCP 3000`)를 허용한다. Grafana는 `server.serve_from_sub_path = true` 설정에 따라 정적 에셋 및 로그인 화면을 응답하며, 세션 쿠키는 `Path=/grafana/`, `Secure`, `SameSite=Lax`로 브라우저에 격리 발급된다.
   - **일반 애플리케이션 및 정적 랜딩 요청 (`https://${DOMAIN_NAME}/`, `/was/` 등)**: 배포 중에는 `web` 100%로 고정되고, 카나리 동적 경로(`/was/owners`) 검증을 통과하면 `web`(90%)과 `web-canary`(10%)로 가중치 분배되며, `X-Canary: always` 헤더가 포함된 요청은 100% `web-canary`로 전달된다.
   - `web`/`web-canary` Deployment는 Metrics Server(`metrics.k8s.io`)의 CPU 사용률(60%)을 기준으로 **HPA**가 각각 2~10개 / 1~4개 Pod로 자동 수평 확장한다.
5. **⑤ `web` 정적 서빙 및 `was` 리버스 프록시 (`:8080`) 및 APM 트레이싱 · RED 메트릭 · Exemplar 수집**:
   - **공개 정적 메인 화면 (`/`)**: 사용자 브라우저가 `https://${DOMAIN_NAME}/`에 접속하면 Web Nginx Pod가 로컬 디스크의 `index.html`과 `css/landing.css`를 직접 응답한다. 외부 CDN·웹폰트·지도 API 의존성이 전혀 없으며, WAS(Tomcat)나 DB(RDS)를 거치지 않아 백엔드 점검이나 장애 시에도 병원 소개, 진료과목, 의료진, 진료시간, 오시는 길 안내가 100% 무중단 서비스된다. 존재하지 않는 경로 요청 시 `error_page 404 /404.html`로 커스텀 404 페이지를 직접 반환한다.
   - **정적 에셋 서빙**: 정적 리소스(`/resources/*`, `/webjars/*`) 및 WAS 컨텍스트 정적 에셋(`/was/resources/*`, `/was/webjars/*`)은 Web Nginx 컨테이너에서 보안 헤더 및 캐시 만료 헤더와 함께 직접 응답한다.
   - **직원용 PetClinic WAS 동적 프록시 (`/was/`)**: 인가된 직원이 `/was/`로 접근하면 Web Nginx가 `was-stable:8080/was/` 또는 `was-canary:8080/was/`로 프록시하며, 이때 `proxy_set_header X-Forwarded-Proto https;` 및 `X-Forwarded-Port 443;`을 전달하고 `absolute_redirect off;`로 Nginx 자체 리다이렉트 스키마를 상대 경로로 유지한다.
   - **Tomcat `RemoteIpValve` 및 리다이렉트 HTTPS 정합성**: Tomcat 11은 `server.xml`의 `RemoteIpValve`를 통해 VPC/Pod 사설 대역(`internalProxies`)에서 전달된 프록시 헤더를 신뢰하여 `request.isSecure() == true`, `request.getScheme() == "https"`로 인식한다. 보호자 검색 후 Spring MVC의 `redirect:/was/owners/1` 실행 시 Location 헤더가 즉시 `https://${DOMAIN_NAME}/was/owners/1`로 발급되어 기존의 `http://` 302 → ALB `https://` 301 리다이렉트 루프가 완전히 소멸된다.
   - **1차 릴리스 호환을 위한 `RewriteValve`**: Tomcat `server.xml`에 `RewriteValve`(`rewrite.config`)가 구성되어 `/was`로 시작하지 않는 요청(예: `GET /` 프로브)을 내부적으로 `/was/`로 재작성한다. 이를 통해 k8s Deployment의 `startupProbe`/`readinessProbe`를 `path: /`로 유지하면서 신규 이미지와 구버전 이미지 간 상호 교체 가능성(Canary 및 이미지 롤백)을 보장한다.
   - **직원 대시보드 (`/was/`, `/was/welcome`)**: 직원 포털 메인 접속 시 `WelcomeController`가 `ClinicService` 파사드를 호출하여 통계 지표(보호자 수, 반려동물 및 종류 수, 총 방문 수, 활성 수의사 명단)와 최근 방문 목록을 조회한다. 이때 최근 방문은 `Pet.visits`의 `FetchType.EAGER` 컬렉션으로 인한 N+1 SELECT 부하를 방지하기 위해 읽기 전용 플랫 프로젝션 DTO인 `VisitSummary`로 상한 5건(`limit=5`)을 단일 바운디드 쿼리로 조회한 뒤 `welcome.jsp` 대시보드로 렌더링된다. flatpickr 날짜 선택 경로는 `<spring:url>`로 자동 컨텍스트 경로(`/was/`)가 반영된다.
   - `ng-platform`의 **Prometheus**가 `was` JMX Exporter(`:9404/metrics`) 지표를 수집하고, `ng-critical`의 **KEDA**가 PromQL 요청률(`> 50 req/s`)을 조회하여 `was-stable`을 2~10개, `was-canary`를 1~3개 Pod로 수평 확장한다. Prometheus 조회가 3회 연속 실패하면 fallback 레플리카(4 / 2)를 유지한다.
   - `ng-critical`의 **OpenTelemetry Operator**(`:9443` Mutating Webhook)가 `was-stable`/`was-canary` Pod 생성 시 `Instrumentation` CR(`petclinic-java`)에 따라 `autoinstrumentation-java:2.12.0` init container와 `JAVA_TOOL_OPTIONS`를 무코드·무재빌드로 주입한다.
   - Java Agent는 `parentbased_traceidratio`(`${OTEL_TRACES_SAMPLER_ARG}`, 기본 `0.1` = 10%)로 헤드 샘플링된 HTTP·Spring MVC·Hibernate/JDBC 트레이스 스팬과, 샘플링 없이 **100% 전수 집계된 RED 메트릭**(`http.server.request.duration` + 샘플링된 트레이스에 한해 부착되는 `trace_based` Exemplar `trace_id`)을 OTLP HTTP(`:4318`)로 `ng-platform`의 **OpenTelemetry Collector**(2 Replicas AZ 분산)에 전송한다.
   - **OpenTelemetry Collector**는 `memory_limiter` → `batch` 처리 후 트레이스를 **Grafana Tempo**(`:4317` OTLP gRPC)로 전달하고, RED 메트릭과 Exemplar는 Prometheus Exporter(`:8889/metrics`, `enable_open_metrics: true`, `resource_to_telemetry_conversion.enabled: true`)로 노출하여 **Prometheus**(`enableFeatures: [exemplar-storage]`, `OpenMetricsText1.0.0`)가 스크래핑한다.
   - **Grafana Tempo**(단일 바이너리)는 Live-Store 로컬 WAL(`gp3` 10Gi PVC `/var/tempo`)을 거쳐 IRSA(`monitoring/tempo`)로 전용 **Amazon S3** 버킷(`${TEMPO_S3_BUCKET_NAME}`)에 트레이스 블록을 적재하고 `backend_scheduler`·`backend_worker`로 보존 기간(`${TEMPO_RETENTION_HOURS}`)을 관리하며, **Grafana**의 `PetClinic APM - Service & Canary Tracing` 대시보드(`service_version="stable|canary"`별 요청량·5xx 에러율·p95/p99 지연)에서 Exemplar 점(Dot)을 클릭하면 `trace_id`로 Tempo(`:3200`)의 해당 트레이스 워터폴로 즉시 이동한다.
   - **Prometheus**는 1분 주기로 `PrometheusRule`(`k8s/monitoring/prometheusrule-petclinic.yaml`)을 평가한다. 특히 WAS 에러율 경보(`PetClinicHttp5xxRateHigh`, `severity: critical`)는 HTTP 상태 코드 400 이상을 일괄 합산하는 Tomcat MBean(`tomcat_errorcount_total`) 대신 OTel Collector가 노출하는 전수 RED 메트릭(`http_server_request_duration_seconds_count{service_name="petclinic-was", http_response_status_code=~"5.."}`)을 사용하여 404 등 정상적인 클라이언트 오류로 인한 오경보를 배제하고, 5분 지속(`for: 5m`) 순수 WAS 5xx 에러율이 5%를 초과할 때만 **Alertmanager**(`:9093`)를 거쳐 Slack(`#aws-alert`) 채널로 발송한다.
6. **⑥ `was` 및 DB 관리 워크로드 → RDS MySQL 8.4 LTS (`:3306` TLS)**:
   - `was`는 **ESO**가 **AWS Secrets Manager**에서 동기화한 app 계정 시크릿 `petclinic-rds-secret`(SELECT/INSERT/UPDATE/DELETE 권한)을 주입받아 프라이빗 DB 서브넷의 **RDS MySQL Primary**에 TLS(`require_secure_transport=ON`, `sslMode=REQUIRED`)로 연결한다 (`caching_sha2_password` 기본 인증, Connector/J `8.4.0`). 대시보드 통계 및 최근 방문 조회를 포함한 모든 읽기 로직은 `ClinicServiceImpl`의 `@Transactional(readOnly = true)`로 격리되어 최소 권한 원칙 하에 안전하게 수행된다.
   - `ng-critical`의 `db-init` Job(`mysql:8.4.11`)은 admin 계정 시크릿(`petclinic-rds-admin-secret`)으로 스키마·초기 데이터를 적재하고 app/backup 계정을 생성(`caching_sha2_password` 및 `REQUIRE SSL`)하며, `db-backup` CronJob(`mysql:8.4.11`)은 읽기 전용 backup 계정 시크릿(`petclinic-rds-backup-secret`)으로 일일 `mysqldump` 후 **Amazon S3** 백업 버킷(`BACKUP_S3_BUCKET_NAME`, `SSE-KMS`)에 업로드한다. 모두 TLS로만 연결한다.
   - `was`는 ConfigMap(`petclinic-was-logback`)을 `/etc/petclinic-logging/logback.xml`로 마운트하여 컨테이너 표준 출력 로그에 `[trace_id=... span_id=...]`를 함께 기록하며, 모든 노드의 컨테이너 로그와 RDS 에러/슬로우쿼리 로그는 **Fluent Bit DaemonSet** 및 RDS 로그 내보내기를 통해 **Amazon CloudWatch Logs**로 수집된다.

### 일일 리소스 중지·기동 제어 흐름 (`scripts/daily-stop.sh` · `scripts/daily-start.sh`)
- **퇴근 전 중지 (`scripts/daily-stop.sh [--dry-run] [--stop-nat]`)**:
  1. **앱 계층 및 Karpenter 노드 축소 (`ng-critical`의 Karpenter 컨트롤러가 살아 있을 때 먼저 수행)**: `cronjob/db-backup`을 `suspend: true`로 전환 → KEDA `ScaledObject`(`was-stable`, `was-canary`)에 `paused-replicas=0` 어노테이션 설정 및 `web`/`web-canary` HPA 삭제 → `web`/`was`와 NGF(`nginx-gateway` 컨트롤 플레인 먼저, 이어서 `petclinic-gateway-nginx` 데이터 플레인) Deployment를 `replicas=0`으로 축소 → Karpenter `NodePool`(`np-app`, `np-app-spot`) `limits`를 `cpu=0, memory=0Gi`로 패치하고 `nodeclaim --all` 삭제 완료를 대기하여 앱 EC2 노드를 모두 종료한다 (`NotFound`만 건너뛰며 `Forbidden`·인증·연결 오류 시 즉시 중단).
  2. **RDS MySQL 중지**: `${RDS_INSTANCE_ID:-${EKS_CLUSTER_NAME}-mysql}` 상태가 `available`이면 `stop-db-instance`를 호출한다 (`stopping`/`stopped`이면 멱등 건너뜀).
  3. **관리형 노드 그룹 축소 및 선택적 NAT 회수**: `ng-critical`, `ng-platform`의 현재 `minSize`/`desiredSize`/`maxSize`를 조회해 `desiredSize > 0`이면 `.daily-nodegroup-state.json`(`umask 077`)에 백업한 뒤 `minSize=0, desiredSize=0`으로 축소하고, 각 update ID를 `describe-update`로 조회해 `Successful`을 확인한다(`Failed`/`Cancelled`/15분 초과 시 오류 종료). 만약 `--stop-nat` 플래그가 지정된 경우 관리형 노드 그룹 축소 완료 직후 `scripts/nat-stop.sh`를 호출하여 VPC 내 잔여 EC2 인스턴스 종료를 확인한 후 NAT Gateway 2개 삭제 및 EIP 반납을 실행한다. 마지막으로 기본 실행 시 중지되지 않는 잔여 리소스(EKS 컨트롤 플레인, ALB, 스토리지 및 `--stop-nat` 미지정 시의 NAT Gateway) 및 RDS 7일 자동 재시작 안내를 출력한다.
- **출근 시 기동 (`scripts/daily-start.sh [--dry-run] [--start-nat]`)**:
  1. **선택적 NAT 복원 선행 및 사전 검증**: `--start-nat` 플래그가 전달된 경우 **가장 먼저** `scripts/nat-start.sh`를 호출하여 AZ별 EIP 할당, NAT Gateway 생성 대기(`available`), 및 앱 라우트 테이블(`petclinic-rt-app-2a/c`)의 `0.0.0.0/0` 라우트를 신규 NAT ID로 갱신하여 워커 노드 기동 전 아웃바운드 인터넷 통신 경로를 선확보한다. 이어서 변경 전 `.daily-nodegroup-state.json`(없으면 `NG_*` 환경변수 또는 기본값 `2/2/4`)의 `minSize`/`desiredSize`/`maxSize` 정수·범위(`1 <= desiredSize`, `minSize <= desiredSize <= maxSize`)를 검증하고, 가장 느린 RDS를 먼저 시작(`stopped`이면 즉시 `start-db-instance`, `stopping`이면 `db-instance-stopped` 대기 후 시작)하여 노드 그룹 복원과 병렬로 진행한다.
  2. **관리형 노드 그룹 및 컨트롤러 복원**: `ng-critical`, `ng-platform`의 `minSize`/`desiredSize`/`maxSize`를 복원(update ID별 `describe-update` `Successful` 확인)하고, `coredns`, `karpenter`, `aws-load-balancer-controller`, `external-secrets`, `keda-operator`, `opentelemetry-operator`(`opentelemetry-operator-system` — Pod 주입 Webhook이 `failurePolicy: Ignore`이므로 `was` 기동 전에 반드시 Ready여야 함)의 `rollout status`를 확인한다.
  3. **RDS `available` 대기 및 앱 계층 복원**: `db-instance-available` 확인 후 `infra/karpenter/nodepool-app.yaml` 재적용으로 Karpenter `NodePool` 한도를 복원하고, NGF(최소 2), KEDA 일시중지 어노테이션 해제, `was-stable`(최소 2)/`was-canary`(최소 1)/`web`(최소 2)/`web-canary`(최소 1) 스케일 업(현재 레플리카가 최소치 이상이면 유지), `k8s/web/hpa.yaml` 재적용, Deployment `rollout status` 확인 후 `cronjob/db-backup`을 `suspend: false`로 재개한다 (필수 리소스 부재·오류 시 즉시 실패 처리).

### VPC 네트워크 프로비저닝 및 NAT 라이프사이클 관리 (`provision-aws-resources.sh vpc` · `nat-stop.sh` · `nat-start.sh`)

과거 저장소 외부 임시 스크립트로 구축되었던 네트워크 기반 인프라를 저장소 내부 코드로 일원화하여, 단일 명령으로 100% 동일한 VPC 및 서브넷 환경을 멱등하게 재현한다. 또한 상시 가동 시 하루 약 $2.83(월 약 $85)의 고정 비용을 발생시키는 NAT Gateway 2개와 EIP 2개를 업무 종료 시 안전하게 회수하고 업무 시작 시 자동으로 재생성·라우팅 복원하는 라이프사이클 관리 체계를 구축한다.

```mermaid
sequenceDiagram
    autonumber
    actor Ops as 운영자 / daily-stop.sh / daily-start.sh
    participant Script as nat-stop.sh / nat-start.sh
    participant EC2 as AWS EC2 API (ap-northeast-2)
    participant RT as Route Tables (petclinic-rt-app-2a / 2c)

    rect rgb(255, 240, 240)
    Note over Ops,RT: [퇴근 시 NAT 게이트웨이 정지 및 비용 절감 흐름 (nat-stop.sh)]
    Ops->>Script: ./scripts/nat-stop.sh [--dry-run] [--force]
    Script->>EC2: describe-instances (VPC 내 pending/running/stopping EC2 확인)
    alt EC2 인스턴스가 남아 있는 경우
        Script->>Script: 최대 300초(NAT_STOP_INSTANCE_WAIT) 동안 10초 간격 종료 대기 (노드 egress 보호)
    end
    Script->>EC2: describe-nat-gateways (Project=petclinic, available|pending)
    Script->>EC2: delete-nat-gateway (AZ별 NAT 2개 삭제 요청)
    Script->>EC2: wait nat-gateway-deleted (삭제 완료 대기)
    Script->>EC2: release-address (삭제된 NAT에 연결됐던 EIP 및 미연결 petclinic-nat EIP만 반납)
    Script-->>Ops: NAT 게이트웨이 삭제 및 EIP 반납 완료 (일일 고정비 절감 시작)
    end

    rect rgb(240, 255, 240)
    Note over Ops,RT: [출근 시 NAT 게이트웨이 기동 및 라우팅 복원 흐름 (nat-start.sh)]
    Ops->>Script: ./scripts/nat-start.sh [--dry-run]
    loop AZ = 2a → 2c 순차 처리
        Script->>EC2: describe-nat-gateways (Name=petclinic-nat-2<az>, available|pending)
        alt 이미 존재하는 경우
            Script-->>Ops: 기존 NAT Gateway 재사용
        else 존재하지 않는 경우
            Script->>EC2: describe-addresses (미연결 petclinic-nat-2<az> EIP 확인)
            alt 미연결 EIP 부재 시
                Script->>EC2: allocate-address (Domain=vpc, Tag: petclinic-nat-2<az>)
            end
            Script->>EC2: create-nat-gateway (Subnet: petclinic-public-2<az>, EIP 할당)
        end
        Script->>EC2: wait nat-gateway-available (가용 상태 대기)
        Script->>RT: replace-route / create-route (0.0.0.0/0 -> NatGatewayId)
        Script-->>Ops: 해당 AZ NAT 가용 확인 및 앱 라우트 0.0.0.0/0 갱신 완료
    end
    Script-->>Ops: 전 가용영역 NAT 프로비저닝 및 아웃바운드 경로 선확보 완료
    end
```

- **멱등 프로비저닝 및 태그 일관성 (`provision-aws-resources.sh vpc`)**:
  - `Name=petclinic-*`, `Project=petclinic` 태그를 기반으로 기존 자원을 사전 조회하여, VPC·서브넷·IGW·라우트 테이블·NAT가 이미 존재하면 중복 생성하지 않고 재사용한다.
  - 실행 완료 시 `.env`에 즉시 반영할 수 있는 형태(`VPC_ID`, 서브넷 6개 ID)를 터미널에 표준 출력한다.
  - 기존 리소스가 태그는 같으나 CIDR/AZ/연결 상태가 상이하거나 다수 존재하는 경우, 실환경 자원을 임의로 덮어쓰지 않고 즉시 중단(Fail-Closed)한다.
- **NAT 온디맨드 회수 시 안전장치 (`nat-stop.sh`)**:
  - VPC 내에 종료되지 않은 EC2 인스턴스가 남아 있을 때 NAT가 먼저 삭제되면 노드 드레인 및 EKS 컨트롤 플레인 통신이 단절되므로, 인스턴스가 완전히 소멸할 때까지 최대 300초(`NAT_STOP_INSTANCE_WAIT`) 동안 대기한 후 삭제를 진행한다.
  - EIP 반납 시 `Project=petclinic`의 다른 자원이 오반납되는 사고를 차단하기 위해, 삭제 대상 NAT에 실제로 붙어 있던 할당 ID와 실패한 실행이 남긴 `petclinic-nat-2a/2c` 태그의 미연결 주소만 엄격히 선별하여 해제한다.
- **NAT 온디맨드 기동 및 블랙홀 경로 복구 (`nat-start.sh`)**:
  - AZ 2a → 2c 순서로 하나씩 순차 처리(EIP 재사용 또는 할당 → NAT 생성 → `nat-gateway-available` 대기 → 앱 라우트 `0.0.0.0/0` 생성/교체)하여 프로비저닝 및 라우팅 복구를 완료한다.
  - 이전 중지로 인해 앱 라우트 테이블의 `0.0.0.0/0`이 삭제된 NAT를 가리켜 발생한 `blackhole` 라우트를 `replace-route`로 신규 NAT 게이트웨이 ID로 정상 교체한다.

### 컨테이너 이미지 빌드 및 ECR 푸시 파이프라인 (`scripts/build-and-push.sh` · AWS CodeBuild)

```mermaid
sequenceDiagram
    autonumber
    actor Dev as 개발자 / 운영자 (LXC 작업 서버)
    participant Script as scripts/build-and-push.sh
    participant S3 as Amazon S3 (${CODEBUILD_S3_BUCKET_NAME})
    participant CB as AWS CodeBuild (${CODEBUILD_PROJECT_NAME})
    participant ECR as Amazon ECR (petclinic-web / petclinic-was)
    participant CW as CloudWatch Logs (/aws/codebuild/...)

    Dev->>Script: IMAGE_TAG=... ./scripts/build-and-push.sh (BUILD_TARGET=all|web|was)
    Script->>Script: IMAGE_TAG 정규식 검증 (!= latest) 및 호출자 BUILD_TARGET 보존
    Script->>Script: S3 소스 버킷 이름이 백업/Tempo 버킷과 상이한지 격리 검증
    Script->>ECR: 대상 리포지토리에 동일 태그 존재 여부 사전 확인 (이미 존재 시 중단)
    Script->>Script: 소스 패키징 (.git, .env*, *.key, *.pem, *.secret, target/ 등 민감·임시 파일 제외)
    Script->>S3: aws s3 cp source.zip s3://${CODEBUILD_S3_BUCKET_NAME}/source/${IMAGE_TAG}-<timestamp>-<uuid>.zip
    Script->>CB: aws codebuild start-build (고유 소스 위치 및 환경변수 오버라이드 전달)
    CB->>S3: 소스 아카이브 다운로드 및 압축 해제
    CB->>CW: 빌드 로그 스트림 시작

    critical CodeBuild 빌드 컨테이너 실행 (buildspec.yml)
        CB->>CB: pre_build: 태그 형식 유효성 검사 및 ECR 로그인 (aws ecr get-login-password)
        CB->>CB: build: target별 docker build --platform linux/amd64 (on-failure: ABORT)
        CB->>ECR: post_build: docker push was & web 불변 태그 푸시 (on-failure: ABORT)
    end

    loop 10초 주기 빌드 상태 확인
        Script->>CB: aws codebuild batch-get-builds --ids <build-id>
        CB-->>Script: buildStatus (IN_PROGRESS)
    end

    CB-->>Script: buildStatus (SUCCEEDED)
    Script->>Dev: 빌드 및 푸시 성공 보고 (이미지 URI 및 태그 안내)
```

- **사전 검증 및 불변 태그 중복 방지**: 스크립트 실행 시 `IMAGE_TAG` 필수 여부와 `latest` 금지, 도커 태그 정규식(`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$`)을 검증하고, 소스 S3 버킷이 백업·Tempo 버킷과 다른지 확인한다. 이어 ECR에 대상 태그가 이미 존재하는지 먼저 조회하여, 이미 배포된 불변 태그를 재빌드하느라 빌드 시간을 낭비하거나 푸시 단계에서 실패하는 일을 사전에 차단한다.
- **소스 아카이빙 및 민감 파일 배제**: 작업 서버에 `zip` 유틸리티가 없는 환경을 지원하기 위해 `git ls-files`와 Python `zipfile`을 조합하여 소스를 패키징한다. 이때 `.git/`, `.env*`(`.env.example` 제외), `*.secret`, `*.key`, `*.pem`, `*.pfx`, `*.p12`, `id_*` 등 모든 시크릿·키 파일 및 로컬 산출물(`app/target/`, `.daily-nodegroup-state.json`)을 엄격히 제외한다.
- **실행별 고유 키 S3 업로드**: 소스 zip을 `${CODEBUILD_S3_BUCKET_NAME}`에 `source/${IMAGE_TAG}-<UTC시각>-<UUID>.zip` 형식의 고유 키로 업로드하여, 동일한 `IMAGE_TAG`로 여러 작업 트리에서 동시 빌드하거나 재시도할 때 발생하는 S3 객체 덮어쓰기 경합(Race Condition / TOCTOU)을 방지한다. 소스 버킷의 객체는 S3 수명주기 정책에 따라 1일 후 자동 삭제된다.
- **CodeBuild 원격 빌드 및 단계별 중단 (Fail-Fast)**: `aws codebuild start-build`로 빌드를 트리거하며, CodeBuild는 `LINUX_CONTAINER`(`BUILD_GENERAL1_MEDIUM`, `privilegedMode: true`) 환경에서 `buildspec.yml`을 실행한다. `pre_build`, `build`, `post_build` 각 단계에 `on-failure: ABORT`가 지정되어 있어 빌드 실패 시 푸시 단계를 건너뛰고, WAS 푸시 실패 시 Web 푸시를 중단하여 부분 배포(half-release)를 방지한다. 타겟 아키텍처는 Karpenter 노드(`np-app`, `np-app-spot`)와 일치하도록 `docker build --platform linux/amd64`로 고정한다.
- **실시간 폴링 및 디버깅 경로 안내**: 스크립트는 10초 주기로 `aws codebuild batch-get-builds`를 호출하여 빌드 페이즈(`currentPhase`)와 상태를 터미널에 출력하고, 빌드 실패 시 전용 CloudWatch Logs 그룹(`/aws/codebuild/${CODEBUILD_PROJECT_NAME}`) 경로를 안내하여 즉시 원인을 분석할 수 있도록 지원한다.

### 무중단 롤링 배포 및 그레이스풀 셧다운 흐름 (`lifecycle.preStop.sleep`)

롤링 업데이트(`rollout restart`), HPA/KEDA 축소(Scale-in), 또는 Karpenter 노드 통합(Consolidation)에 의해 Pod가 종료될 때, Kubernetes 컨트롤 플레인은 비동기(병렬)로 엔드포인트 등록 해제와 Pod 프로세스 종료를 시작한다:
1. **엔드포인트 등록 해제**: `kube-apiserver` → EndpointSlice 컨트롤러 → NGF 컨트롤러/데이터 플레인 및 노드별 `kube-proxy`로 전달되어 로드밸런서 업스트림 목록 및 iptables 라우팅 테이블에서 제거된다 (전파 및 리로드에 통상 1~3초 소요).
2. **컨테이너 종료 시작**: 노드의 `kubelet`이 Pod 내 컨테이너에 즉시 `SIGTERM` 신호를 전송한다.

`lifecycle.preStop` 지연이 없으면 프로세스가 즉시 Listen 소켓을 닫고 종료에 들어가며, 엔드포인트 테이블이 갱신되는 1~3초 동안 인입된 신규 트래픽은 이미 닫힌 소켓으로 전달되어 TCP RST(`111: Connection refused`) 및 HTTP 502/504 에러가 발생한다. 이를 방지하기 위해 네이티브 선언형 `lifecycle.preStop.sleep: { seconds: 15 }` 액션과 계층별 적정 유예 시간(`terminationGracePeriodSeconds`)을 선언하여 엔드포인트 격리와 프로세스 종료 간 순서를 엄격히 제어한다.

```mermaid
sequenceDiagram
    autonumber
    actor Admin as 운영자 / 컨트롤러 (rollout restart / 축소)
    participant APISrv as Kubernetes API Server
    participant EPC as EndpointSlice Controller
    participant NGF as NGF Data Plane / kube-proxy
    participant Kubelet as Kubelet (Node Worker)
    participant WebPod as web Pod (Nginx & Exporter)
    participant WASPod as was Pod (Tomcat 11)

    Admin->>APISrv: Pod 삭제 요청 (Terminating 전환, deletionTimestamp 기록)
    
    par [비동기 엔드포인트 격리]
        APISrv->>EPC: Pod Terminating 이벤트 감지
        EPC->>NGF: EndpointSlice 갱신 (Terminating Pod IP 제거)
        NGF->>NGF: 1~3초 내 업스트림 목록 및 iptables 라우팅 갱신<br/>(신규 요청을 Healthy Pod로만 라우팅)
    and [비동기 Kubelet 생명주기 훅 실행]
        APISrv->>Kubelet: Pod 삭제 지시 (GracePeriod 타이머 시작: web 35s / was 45s)
        Kubelet->>WebPod: lifecycle.preStop.sleep (15초 대기 시작)
        Kubelet->>WASPod: lifecycle.preStop.sleep (15초 대기 시작)
    end

    Note over NGF,WASPod: 15초 대기 시간 동안:<br/>- 이미 유입 중이던 연결 및 NGF/kube-proxy 전파 중 도착한 요청 정상 수락 및 처리<br/>- Nginx 및 Tomcat 프로세스는 정상 가동 상태 유지

    Kubelet->>WebPod: preStop 15초 만료 → SIGQUIT (Nginx) / SIGTERM (Exporter) 전송
    WebPod->>WebPod: Nginx 워커: 신규 연결 수신 차단, 활성 연결 완료 후 정상 종료 (SIGQUIT)<br/>nginx-exporter: 메트릭 수집 종료 후 정상 종료 (SIGTERM)
    WebPod-->>Kubelet: 컨테이너 정상 종료 완료 (Exit 0)

    Kubelet->>WASPod: preStop 15초 만료 → SIGTERM (Tomcat/JVM catalina.sh) 전송
    WASPod->>WASPod: Catalina 종료 훅 실행 → 커넥터 수신 차단<br/>웹 컨텍스트 종료 (DispatcherServlet / ContextLoaderListener close)<br/>Tomcat JDBC Pool 커넥션 안전 해제 (DataSource.close())<br/>OTel Java Agent JVM 셧다운 훅 잔여 span 플러시
    WASPod-->>Kubelet: 컨테이너 정상 종료 완료 (Exit 0)

    Kubelet->>APISrv: Pod 리소스 완전 제거 (요청 실패 0건 / 100% 무중단 달성)
```

- **선언형 `lifecycle.preStop.sleep` 채택**: EKS 1.36(K8s 1.32+ GA)의 네이티브 `sleep` 액션을 사용하여 컨테이너 내부 `exec`(`/bin/sh -c sleep 15`) 방식과 달리 컨테이너 내부 쉘·바이너리 의존성이 없으며, 쉘이 없는 최소 이미지인 `nginx-prometheus-exporter` 사이드카에도 완벽히 동일하게 동작한다. 프로세스 포크 오버헤드 없이 Kubelet 데몬 내부 타이머로 관리된다.
- **사이드카 생명주기 일치**: `web` Pod 내 메인 `nginx` 컨테이너뿐만 아니라 사이드카인 `nginx-exporter`에도 동일한 15초 sleep을 선언하여, Kubernetes의 컨테이너 병렬 종료 특성으로 인해 exporter가 메인 컨테이너보다 먼저 종료되어 배포 중 Prometheus 스크래핑 실패 및 알림이 발생하는 현상을 방지한다.
- **유예 시간(`terminationGracePeriodSeconds`) 산정 근거**:
  - `web` 계층 (**35초**): preStop sleep(15s) + Nginx 워커 활성 연결 드레인 및 정적 리소스 서빙 완료(~2s) + 버퍼(18s)
  - `was` 계층 (**45초**): preStop sleep(15s) + 활성 서블릿 트랜잭션 처리(최대 5s) + Spring ApplicationContext 종료 및 Tomcat JDBC Pool 반환(~3s) + OTel Collector 트레이스 플러시(~2s) + JVM 안전 종료 버퍼(20s)
- **외부 Tomcat WAR 및 Tomcat JDBC Pool 수명주기 부합**: Spring Boot 내장 톰캣과 달리 본 애플리케이션은 외부 Tomcat 11에 배포된 Jakarta EE WAR이므로 `registerShutdownHook()`이나 HikariCP가 아닌, Catalina 프로세스 종료 훅 → 서블릿 컨텍스트 언로드(`PetclinicInitializer`의 `DispatcherServlet` 및 Spring 컨텍스트 닫힘) → `org.apache.tomcat.jdbc.pool.DataSource` 빈 `close()` → OTel Java Agent JVM 종료 훅의 실제 런타임 종료 경로에 맞춰 안전하게 자원이 회수된다.
- **Nginx `proxy_next_upstream` 미사용 원칙**: ClusterIP 환경에서 Nginx 자체 재시도만으로는 iptables 목적지 Pod 전환을 제어하기 어렵고, 비멱등 `POST` 요청(신규 등록 등) 재시도로 인한 데이터 중복 생성 위험이 발생한다. WAS 계층에 `preStop.sleep: 15s`를 적용하여 iptables에서 Pod IP가 먼저 제거된 후 프로세스가 종료되므로 소스 설정 변경(`docker/web/nginx.conf`)이나 이미지 재빌드(`v1.0.3`) 없이 인프라 선언형 매니페스트만으로 상류 연결 거부를 완벽히 차단한다.

---

## 5. 실행 환경 — 런타임, 컨테이너/클라우드 리소스, 환경변수 목록

### 5.1 런타임 및 주요 컴포넌트 버전

| 구분 | 컴포넌트 | 고정 버전 / 이미지 |
|---|---|---|
| **Application** | Spring Framework PetClinic | `7.0.3` (Spring Framework `7.0.9`, Hibernate `7.4.11.Final`, Java `17` 타겟 / Java `21` 런타임, 서블릿 컨텍스트 `/was`, `RemoteIpValve` 및 `RewriteValve` 적용) |
| **Network / VPC / NAT** | Amazon VPC, Subnets, IGW, Route Tables, NAT Gateway | VPC `10.0.0.0/16`, 서브넷 6개(퍼블릭 `10.0.0.0/24`·`10.0.1.0/24`, 앱 `10.0.16.0/20`·`10.0.32.0/20`, DB `10.0.48.0/24`·`10.0.49.0/24`), IGW(`petclinic-igw`), 라우트 테이블 4개, AWS Managed NAT Gateway 2개 (AZ `2a`, `2c`) 및 Elastic IP 2개 |
| **Build Container** | Maven (Multi-stage Build) | `maven:3.9.9-eclipse-temurin-21` |
| **Build Host / Container** | AWS CodeBuild Managed Image | `aws/codebuild/amazonlinux2-x86_64-standard:5.0` (`LINUX_CONTAINER`, `BUILD_GENERAL1_MEDIUM` [4 vCPU, 7 GiB], `privilegedMode: true`) |
| **Build Target Architecture** | Docker Platform | `linux/amd64` (x86_64) |
| **Web Container** | Nginx + Exporter Sidecar | `nginx:1.27.2-alpine` (정적 랜딩 `/`, 커스텀 `/404.html`, `/was/` 리버스 프록시, `X-Forwarded-Proto https`, `absolute_redirect off`), `nginx/nginx-prometheus-exporter:1.3.0` |
| **WAS Container** | Apache Tomcat 11 + JMX Exporter + OTel Java Agent | `tomcat:11.0.2-jre21-temurin-noble` (`webapps/was` 사전 언패킹, `server.xml` `RemoteIpValve`, `rewrite.config`), `jmx_prometheus_javaagent:1.0.1`, `autoinstrumentation-java:2.12.0` (init container 주입) |
| **DB Jobs** | MySQL Client / AWS CLI | `mysql:8.4.11`, `amazon/aws-cli:2.18.0` |
| **Kubernetes** | Amazon EKS | `1.36` (AL2023 AMI `al2023@v20260930`, K8s 1.36 PodTopologySpread `matchLabelKeys` GA 및 선언형 `lifecycle.preStop.sleep` GA 활용, 새 클러스터 생성 기준) |
| **Gateway API** | Gateway API CRDs / NGF | CRDs `v1.6.3` (standard), `nginx-gateway-fabric` Helm `2.8.0` (`allowedRoutes: [petclinic, nginx-gateway]`, `ReferenceGrant` v1) |
| **Edge / WAF** | AWS WAFv2 | Regional WebACL (Priority 0 커스텀 규칙 `BlockUnauthorizedStaffAccess` [`/grafana` 및 `/was` URL 디코딩·경로 정규화 + IPSet] + 관리형 규칙 3종 [Priority 1~3], 커스텀 403 본문 `petclinic-staff-403`, `STAFF_WAF_SCOPE=all` 긴급 롤백 차단 지원) |
| **Autoscaling** | Karpenter / KEDA / Metrics Server | Karpenter `1.15.0` (+ `karpenter-crd`), KEDA `2.21.0`, Metrics Server Helm `3.14.0` (`v0.9.0`) |
| **Ingress / Storage / Secrets** | LBC / EBS CSI / ESO | `aws-load-balancer-controller` Helm `3.6.1` (`v3.6.1`), `aws-ebs-csi-driver` `${EBS_CSI_ADDON_VERSION}`(환경별 고정), `external-secrets` `2.13.0` (API `v1`) |
| **Observability** | kube-prometheus-stack / Fluent Bit | `kube-prometheus-stack` `92.11.0` (Prometheus `v3.15.0` `exemplar-storage`, Grafana 차트 `14.0.1` [App `13.2.4`, `grafana.ini` subpath 서빙 및 보안 하드닝], Alertmanager `slack_configs`), `aws-for-fluent-bit` Helm `0.2.0` (이미지 `3.2.1`) |
| **APM Tracing** | OpenTelemetry Operator / Collector / Grafana Tempo | `opentelemetry-operator` Helm `0.105.0` (`0.144.0`, `kube-rbac-proxy:v0.20.0`), `opentelemetry-collector` Helm `0.116.0` (`otel/opentelemetry-collector-contrib:0.120.0`), `grafana-community/tempo` Helm `3.2.1` (`grafana/tempo:3.1.1`) |
| **Database** | Amazon RDS for MySQL | `8.4.11` LTS (`db.t3.medium`, Multi-AZ, `gp3` 20GB 암호화, `mysql8.4` 파라미터 그룹) |

### 5.2 클러스터 노드 그룹 및 NodePool 구성

| 이름 | 관리 주체 | 용량 / 인스턴스 전략 | Taint | Label | 역할 |
|---|---|---|---|---|---|
| **`np-app`** | Karpenter `NodePool` (`weight: 100`) | **On-Demand 전용** (`c6i`/`m6i`/`t3` `large`~`2xlarge`, 한도 `16 vCPU / 64Gi`, 일일 중지 시 `0`) | 없음 | `workload-tier=app` | 앱 워크로드(`NGF`, `web`, `was` [1280Mi~2Gi]) 기본 용량 수용 |
| **`np-app-spot`** | Karpenter `NodePool` | **Spot 전용** (`c6i`/`m6i`/`t3` `large`~`2xlarge`, 한도 `48 vCPU / 192Gi`, 일일 중지 시 `0`) | 없음 | `workload-tier=app` | `np-app` 한도 초과 시 앱 워크로드 Spot 확장 수용 |
| **`ng-critical`** | EKS Managed NodeGroup | On-Demand (`m6i.large`, Min 2 / Desired 2 / Max 4, Multi-AZ, 일일 중지 시 Min 0 / Desired 0) | `node-role=critical:NoSchedule` | `workload-tier=critical` | 클러스터 컨트롤러(`CoreDNS`, `LBC`, `Metrics Server`, `Karpenter`, `KEDA`, `ESO`, `EBS CSI`, `OpenTelemetry Operator`) 및 `db-init` / `db-backup` 실행 |
| **`ng-platform`** | EKS Managed NodeGroup | On-Demand (`m6i.large`, Min 2 / Desired 2 / Max 4, Multi-AZ, 일일 중지 시 Min 0 / Desired 0) | `node-role=platform:NoSchedule` | `workload-tier=platform` | Prometheus(50Gi × 2), Grafana(10Gi), Alertmanager(10Gi), OTel Collector(× 2), Grafana Tempo(10Gi WAL) 및 `gp3` PVC |

### 5.3 환경변수 목록 (`.env.example` 기준 — 실제 값은 저장소에 기재하지 않음)

| 카테고리 | 변수명 | 용도 |
|---|---|---|
| **AWS / 클러스터** | `AWS_REGION`, `AWS_ACCOUNT_ID`, `EKS_CLUSTER_NAME`, `EBS_CSI_ADDON_VERSION` | 리전, 계정 ID, EKS 클러스터 식별자, EBS CSI 애드온 고정 버전 |
| **VPC 서브넷** | `VPC_ID`, `PUBLIC_SUBNET_A_ID`, `PUBLIC_SUBNET_C_ID`, `APP_PRIVATE_SUBNET_A_ID`, `APP_PRIVATE_SUBNET_C_ID`, `DB_PRIVATE_SUBNET_A_ID`, `DB_PRIVATE_SUBNET_C_ID` | `2a`/`2c` 퍼블릭(ALB/NAT), 앱 프라이빗(EKS 노드), DB 프라이빗(RDS) 서브넷 ID (`./infra/aws/provision-aws-resources.sh vpc` 실행 결과로 출력되어 `.env`에 반영) |
| **엣지 / 도메인** | `DOMAIN_NAME`, `ROUTE53_HOSTED_ZONE_ID`, `ACM_CERTIFICATE_ARN`, `WAF_WEB_ACL_ARN`, `GRAFANA_ALLOWED_CIDRS`, `STAFF_WAF_SCOPE` | Route 53 도메인·호스팅 영역, ACM 인증서 ARN, WAFv2 WebACL ARN, Grafana 및 직원용 WAS(`https://${DOMAIN_NAME}/was/`, `/grafana/`) 접속 허용 소스 IPv4 CIDR 목록 (쉼표 구분, 예: `203.0.113.7/32`, 공백 허용). 빈 값일 경우 WAF에서 `/grafana` 및 `/was` 경로 접근 전체 차단 (`provision-aws-resources.sh grafana-waf`로 멱등 적용). `STAFF_WAF_SCOPE`는 차단 범위 제어(`staff` [기본값: `/grafana` + `/was`] 또는 `all` [긴급 롤백 시 `/resources/` 제외 사이트 전체 차단]) |
| **컨테이너 이미지 / 카나리** | `ECR_WEB_REPOSITORY_URI`, `ECR_WAS_REPOSITORY_URI`, `IMAGE_TAG`, `STABLE_IMAGE_TAG`, `CANARY_IMAGE_TAG`, `STABLE_WEIGHT`, `CANARY_WEIGHT`, `PROMOTE_STABLE` | `web`/`was` ECR 리포지토리 URI, 빌드 태그, stable/canary 배포 태그, 카나리 검증 통과 후 여는 `HTTPRoute` 가중치(비우면 90:10, 합 100). 검증 전에는 항상 100:0이며, 배포 후 비율 변경은 `scripts/set-canary-weight.sh`. `PROMOTE_STABLE=1`은 stable 이미지 태그 변경 승격 시 필수 요구되는 명시적 승인 가드 변수 |
| **CodeBuild (이미지 빌드)** | `CODEBUILD_PROJECT_NAME`, `CODEBUILD_S3_BUCKET_NAME`, `BUILD_TARGET` | CodeBuild 프로젝트명(기본 `${EKS_CLUSTER_NAME}-image-build`), 소스 아카이브용 전용 S3 버킷명(기본 `${EKS_CLUSTER_NAME}-codebuild-${AWS_ACCOUNT_ID}`, 1일 만료 Lifecycle), 빌드 대상 이미지(`all`, `web`, `was` / 기본값 `all`). `scripts/build-and-push.sh`는 호출 시점에 지정된 `IMAGE_TAG` 및 `BUILD_TARGET`을 `.env`의 빈 기본값보다 우선 보존함 |
| **애플리케이션** | `SPRING_PROFILES_ACTIVE`, `JAVA_OPTS`, `WAS_UPSTREAM_HOST`, `WAS_UPSTREAM_PORT` | Spring 런타임 프로필(`jpa`), JVM 옵션, Nginx 업스트림 호스트/포트 |
| **DB / 시크릿** | `RDS_SECRET_NAME`, `RDS_APP_SECRET_NAME`, `RDS_BACKUP_SECRET_NAME`, `RDS_HOST`, `RDS_PORT`, `RDS_DB_NAME`, `JDBC_URL`, `JDBC_USERNAME`, `JDBC_PASSWORD`, `JDBC_DRIVER_CLASS_NAME` | admin/app/backup 계정별 Secrets Manager 시크릿 경로(`petclinic/*`), ESO가 생성하는 시크릿 키 및 MySQL JDBC 드라이버 클래스명 |
| **관측성 / 백업** | `CW_LOG_GROUP_NAME`, `PROMETHEUS_SERVER_URL`, `GRAFANA_ADMIN_SECRET_NAME`, `ALERTMANAGER_WEBHOOK_SECRET_NAME`, `ALERTMANAGER_WEBHOOK_URL`, `BACKUP_S3_BUCKET_NAME` | CloudWatch 로그 그룹, Prometheus 쿼리 URL, Grafana 관리자 시크릿(`petclinic/grafana-admin`), Alertmanager Slack Incoming Webhook 시크릿(`petclinic/alertmanager-webhook`, ESO가 동기화하여 `slack_configs`의 `api_url_file`로 마운트), Slack Incoming Webhook URL(post-cluster에서 시크릿 생성 시에만 사용; Alertmanager는 `slack_configs` 전용이며 일반 webhook 미지원), 백업용 S3 버킷명 |
| **분산 트레이싱 (APM)** | `TEMPO_S3_BUCKET_NAME`, `TEMPO_RETENTION_DAYS`, `OTEL_TRACES_SAMPLER_ARG`, `OTEL_DEPLOYMENT_ENVIRONMENT` (및 `deploy-all.sh`가 파생하는 `TEMPO_RETENTION_HOURS`) | Tempo 트레이스 블록 저장용 전용 S3 버킷명(`BACKUP_S3_BUCKET_NAME`과 중복 금지), S3 만료 Lifecycle 및 Tempo 블록 보존 일수(기본 `14`일 → `336h`), OTel Java Agent 헤드 샘플링 비율(`0`~`1`, 기본 `0.1`), `deployment.environment` 리소스 속성(기본 `production`) |
| **일일 중지·기동 (선택)** | `RDS_INSTANCE_ID`, `NG_CRITICAL_DESIRED_SIZE`, `NG_PLATFORM_DESIRED_SIZE` (및 `NG_CRITICAL_MIN_SIZE`, `NG_CRITICAL_MAX_SIZE`, `NG_PLATFORM_MIN_SIZE`, `NG_PLATFORM_MAX_SIZE`) | `daily-stop.sh` / `daily-start.sh` 대상 RDS 식별자(기본 `${EKS_CLUSTER_NAME}-mysql`) 및 `.daily-nodegroup-state.json` 미존재 시 관리형 노드 그룹 복원 기본 용량(기본 `2 / 2 / 4`) |
| | `NAT_STOP_INSTANCE_WAIT` | `nat-stop.sh` 실행 시 VPC 내 잔여 EC2 인스턴스(노드) 종료 대기 제한 시간(초, 기본값 `300`) |

---

## 6. 외부 의존성 — 외부 API, DB, 서비스

- **AWS 관리형 서비스**:
  - **Amazon EC2 VPC / NAT Gateway**: VPC `10.0.0.0/16`, 퍼블릭 서브넷 2개(`10.0.0.0/24`, `10.0.1.0/24`), 앱 프라이빗 서브넷 2개(`10.0.16.0/20`, `10.0.32.0/20`), DB 프라이빗 서브넷 2개(`10.0.48.0/24`, `10.0.49.0/24`), 인터넷 게이트웨이(IGW), 관리형 NAT Gateway 2개 및 Elastic IP 2개 (저장소 내 `provision-aws-resources.sh vpc`로 멱등 프로비저닝 및 업무 외 시간 온디맨드 회수·복원 지원)
  - **AWS CodeBuild (`${CODEBUILD_PROJECT_NAME}`)**: 온디맨드 컨테이너 이미지 빌드 서비스 (`BUILD_GENERAL1_MEDIUM`, Docker in Docker, AL2023/x86_64 표준 컨테이너 환경, 전용 CloudWatch Logs 그룹 `/aws/codebuild/${CODEBUILD_PROJECT_NAME}` 보존 기간 30일)
  - **Amazon RDS for MySQL (`8.4.11` LTS)**: 애플리케이션 영속 데이터 저장소 (`:3306`, Multi-AZ, `mysql8.4` 파라미터 그룹, `require_secure_transport=ON`, `error`/`slowquery` CloudWatch 로그 내보내기, 삭제 보호 활성화, 일일 중지 후 7일 경과 시 AWS 정책에 따라 자동 재시작)
  - **AWS Secrets Manager**: RDS 계정별 접속 정보(`$RDS_SECRET_NAME` admin, `$RDS_APP_SECRET_NAME` app, `$RDS_BACKUP_SECRET_NAME` backup), Grafana 관리자 자격증명(`$GRAFANA_ADMIN_SECRET_NAME`), Alertmanager Slack Webhook URL(`$ALERTMANAGER_WEBHOOK_SECRET_NAME`) 보관
  - **Amazon S3**:
    - **DB 백업 버킷 (`$BACKUP_S3_BUCKET_NAME`)**: `db-backup` CronJob의 `mysqldump` 백업 파일 저장소 (퍼블릭 액세스 완전 차단, SSE-KMS 기본 암호화, 버전 관리 활성화)
    - **Tempo 트레이스 전용 버킷 (`$TEMPO_S3_BUCKET_NAME`)**: Grafana Tempo 트레이스 블록 저장소 (퍼블릭 액세스 완전 차단, SSE-KMS 기본 암호화, 비버전 관리, `${TEMPO_RETENTION_DAYS:-14}`일 만료 및 미완료 멀티파트 1일 중단 Lifecycle 규칙)
    - **CodeBuild 임시 소스 버킷 (`$CODEBUILD_S3_BUCKET_NAME`)**: `scripts/build-and-push.sh`가 업로드하는 소스 zip 아카이브 임시 보관소 (퍼블릭 액세스 완전 차단, SSE-S3 AES256 기본 암호화, 비버전 관리, 1일 만료 및 미완료 멀티파트 1일 중단 Lifecycle 규칙, 백업·Tempo 버킷과 이름 상호 격리 필수)
  - **Amazon ECR**: `petclinic-web`, `petclinic-was` 컨테이너 이미지 저장소 (`IMMUTABLE` 태그, 푸시 시 자동 스캔, KMS 암호화)
  - **Amazon CloudWatch Logs**: Fluent Bit가 전송하는 클러스터 컨테이너 로그(`trace_id`/`span_id` MDC 포함) 및 RDS 에러/슬로우쿼리 로그 보관 (보존 기간 30일)
  - **알림 수신처 (Slack Incoming Webhook)**: Alertmanager가 HTTPS(`443`)로 알림을 전송하는 전용 Slack Incoming Webhook 채널 (`slack_configs` 전용 계약으로 전송, generic `webhook_configs` 미사용)
  - **Amazon Route 53 / AWS Certificate Manager (ACM) / AWS WAFv2**: DNS 관리, DNS 검증 기반 TLS 인증서, 리전 WebACL(최우선순위 Priority 0 `BlockUnauthorizedStaffAccess` 규칙 [`/grafana` 및 `/was` `URL_DECODE` → `NORMALIZE_PATH` → `LOWERCASE` 정규화 + `GRAFANA_ALLOWED_CIDRS` IPSet 차단, 커스텀 403 본문 `petclinic-staff-403`, `STAFF_WAF_SCOPE=all` 긴급 롤백 지원] 및 관리형 규칙 3종 `AWSManagedRulesCommonRuleSet`, `AWSManagedRulesSQLiRuleSet`, `AWSManagedRulesKnownBadInputsRuleSet`)
- **외부 아티팩트 / Helm 차트 레지스트리 (빌드·배포 시점)**:
  - Maven Central (`com.mysql:mysql-connector-j:8.4.0`, `io.prometheus.jmx:jmx_prometheus_javaagent:1.0.1` SHA256 검증 포함, WebJars)
  - GitHub Releases / GHCR (`gateway-api` `v1.6.3` `standard-install.yaml`, `ghcr.io/open-telemetry/opentelemetry-operator/{opentelemetry-operator:0.144.0,autoinstrumentation-java:2.12.0}`)
  - Helm / OCI 레지스트리 (`eks-charts`, `metrics-server`, `kedacore`, `external-secrets`, `prometheus-community`, `open-telemetry`, `grafana-community`, `oci://public.ecr.aws/karpenter/karpenter`, `oci://ghcr.io/nginx/charts/nginx-gateway-fabric`)

---

## 7. 보안 구조 — 인증, 권한, 시크릿 관리 방식

1. **엣지 및 전송 구간 암호화 (TLS Everywhere)**:
   - 외부 트래픽은 ALB에서 ACM 인증서(`ELBSecurityPolicy-TLS13-1-2-2021-06`)로 TLS 종단하며 HTTP(`80`)는 HTTPS(`443`)로 강제 리다이렉트한다.
   - ALB에 `routing.http.drop_invalid_header_fields.enabled=true` 및 AWS WAFv2 WebACL을 적용하고, Nginx(`web`)에서 `server_tokens off`와 보안 응답 헤더(`X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: strict-origin-when-cross-origin`)를 일관되게 반환한다.
   - AWS WAFv2 WebACL 최우선순위(Priority 0)에 `BlockUnauthorizedStaffAccess` 규칙(`URL_DECODE` → `NORMALIZE_PATH` → `LOWERCASE` 3단계 정규화 + `GRAFANA_ALLOWED_CIDRS` IPSet)을 적용하여 비인가 외부 IP의 `/was*` 및 `/grafana*` 접근을 AWS 엣지에서 즉시 전용 커스텀 응답 본문(`petclinic-staff-403`, `waf-staff-403.html`)과 함께 HTTP 403 Forbidden으로 원천 차단하며, 인가된 IP의 요청만 Priority 1~3 관리형 규칙의 정밀 검사를 통과하도록 다층 방어한다.
   - WAF 16KB 용량 한계를 극복하기 위해 403 HTML 본문에는 반응형 인라인 스타일과 홈 복귀 버튼만 포함하고, 대표 사진(`<img src="/resources/images/403.webp">`)은 WAF 차단 대상이 아닌 Web Nginx의 공개 경로에서 브라우저가 지연 로딩하도록 설계하여 WAF 초과 오류 없이 풍부한 사용자 안내 화면을 제공한다.
   - Nginx-Tomcat 간 HTTPS 스키마 정합성 보장: Web Nginx 프록시 설정에 `proxy_set_header X-Forwarded-Proto https` 및 `X-Forwarded-Port 443`을 명시하고, Tomcat `server.xml`의 `RemoteIpValve`(`internalProxies`로 사설 IP 대역만 신뢰)를 활성화하여 Spring MVC `redirect:` 시 `Location` 헤더가 즉시 `https://${DOMAIN_NAME}/was/...`로 발급되도록 조치함으로써 불필요한 `http://` 302 → ALB `https://` 301 리다이렉트 루프 및 평문 다운그레이드/혼합 콘텐츠 보안 취약점을 완전히 제거한다. Nginx 자체 리다이렉트(`location = /was`)는 `absolute_redirect off;`로 상대 경로(`/was/`)를 발급한다.
   - 긴급 롤백 시 사이트 전체 선차단 통제: 루트(`/`)를 내부 앱으로 프록시하던 구버전 Web Nginx 이미지로 긴급 롤백해야 하는 경우, `STAFF_WAF_SCOPE=all`을 통해 롤백 수행 전 사이트 전체(공개 이미지 `/resources/` 제외)를 WAF 허용 IP 뒤로 먼저 차단하는 절차를 수립하여, 롤백 도중 내부 직원용 환자/보호자 개인정보가 외부에 무방비로 노출되는 보안 공백을 원천 방지한다.
   - Grafana가 PetClinic과 동일 출처(`https://${DOMAIN_NAME}:443`)를 공유함에 따라 발생할 수 있는 동일 출처 정책(Same-Origin) 위험을 완화하기 위해 `server.serve_from_sub_path = true`를 활성화하여 모든 세션 쿠키를 `Path=/grafana/`로 자동 격리하고, `cookie_secure = true`, `cookie_samesite = lax`를 강제하여 쿠키 유출 및 CSRF 공격을 차단한다. 또한 `allow_embedding = false`를 적용하여 `X-Frame-Options: deny` 및 CSP `frame-ancestors`를 강제함으로써 iframe을 통한 클릭재킹을 원천 방어한다.
   - RDS MySQL은 `mysql8.4` 파라미터 그룹에서 `require_secure_transport=ON`을 강제하고, `was`(`sslMode=REQUIRED`), `db-init`(`--ssl-mode=REQUIRED`), `db-backup`(`--ssl-mode=REQUIRED`) 모두 암호화 연결만 사용한다. Tempo → S3 구간도 HTTPS(`insecure: false`)와 `SSE-KMS` 암호화를 강제하며, CodeBuild 소스 버킷도 SSE-S3(`AES256`) 암호화 및 HTTPS 전송을 강제한다.
2. **네트워크 격리 (VPC SG & Kubernetes NetworkPolicy)**:
   - **계층별 서브넷 라우팅 및 DB 에어갭(Air-Gapped) 격리**: 퍼블릭 서브넷(`2a`/`2c`)은 IGW로 향하는 기본 경로(`0.0.0.0/0 -> IGW`)만 보유하여 외부 인입 ALB 및 아웃바운드 NAT 게이트웨이만 배치된다. 앱 프라이빗 서브넷(`2a`/`2c`)은 공인 IP가 없으며, 아웃바운드 통신은 각 가용영역의 독립 NAT 게이트웨이(`petclinic-nat-2a`, `petclinic-nat-2c`)로만 라우팅된다. DB 프라이빗 서브넷(`2a`/`2c`)은 인터넷 게이트웨이나 NAT 게이트웨이로 향하는 라우트가 전혀 없는 완전 격리(Air-Gapped) 라우트 테이블(`petclinic-rt-db`, 로컬 `10.0.0.0/16`만 존재)에 연결되어 외부 인터넷과의 직접적인 연결 및 원격 침해 위협이 원천 차단된다. 스크립트 실행 시 기존 DB 라우트 테이블에 인터넷 경로(`0.0.0.0/0`)가 감지되면 즉시 실패 처리(Fail-Closed)한다.
   - RDS 보안 그룹은 오직 EKS 클러스터 보안 그룹에서 오는 `TCP 3306`만 허용하며 퍼블릭 접근(`--no-publicly-accessible`)을 차단한다.
   - Amazon VPC CNI의 `enableNetworkPolicy: "true"` 및 `enablePolicyEventLogs: "true"`를 활성화한다.
   - `petclinic` 네임스페이스는 `default-deny-all`(Ingress/Egress 기본 차단) 정책을 기반으로 DNS(`53`), `nginx-gateway`→`web`(`8080`), `web`→`was`(`8080`), `Prometheus`→`web`(`9113`)/`was`(`9404`), `was`→`otel-collector`(`4317`, `4318`), `was`·`db-init`·`db-backup`→RDS(`3306`), `db-backup`→S3/STS(`443`) 통신만 명시적으로 허용한다.
   - `monitoring` 네임스페이스의 Grafana(`:3000`)는 `networkpolicy-grafana.yaml`(`grafana-ingress`)을 통해 오직 `nginx-gateway` 네임스페이스의 데이터 플레인 Pod(`gateway.networking.k8s.io/gateway-name: petclinic-gateway`)와 Prometheus Pod로부터의 인입만 허용하고, 동일 네임스페이스의 컨트롤 플레인 Pod나 타 워크로드의 불필요한 접근을 최소 권한으로 격리한다.
   - Kubernetes Gateway API `ReferenceGrant`(`allow-nginx-gateway-to-grafana`)를 통해 `nginx-gateway` 네임스페이스의 HTTPRoute가 `monitoring` 네임스페이스의 `kube-prometheus-stack-grafana` Service만을 안전하게 참조하도록 교차 네임스페이스 권한을 명시적으로 제어하며, Gateway 리스너의 `allowedRoutes`도 `petclinic`과 `nginx-gateway` 네임스페이스로 엄격히 한정한다.
   - `monitoring` 네임스페이스의 Prometheus(`:9090`)는 `prometheus-ingress` NetworkPolicy를 통해 KEDA, Grafana, Prometheus 자체 Pod(`:9090`, `:8080`)에서의 접근만 허용하고, Alertmanager는 `alertmanager-egress` NetworkPolicy로 DNS(`53`), 피어 가십(`9094`), HTTPS(`443`, IMDS `169.254.169.254/32` 제외) 송신만 허용한다.
   - `monitoring` 네임스페이스의 `otel-collector`는 `networkpolicy-tracing.yaml`을 통해 Ingress(`was`→`4317`/`4318`, `prometheus`→`8889`)와 Egress(DNS `53`, `tempo`→`4317`)만 허용하고, `tempo`는 Ingress(`otel-collector`→`4317`/`4318`, `grafana`→`3200`)와 Egress(DNS `53`, 외부 S3/STS `443` [IMDS `169.254.169.254/32` 제외])만 허용한다 (`reportingEnabled: false`로 외부 사용량 리포팅도 비활성화).
3. **최소 권한 IAM (IRSA) 및 IMDS 차단**:
   - VPC 프로비저닝 및 NAT 제어 스크립트 실행 시 작업 환경 셸에 타 리전(예: `AWS_REGION=us-east-1`)이 설정되어 있더라도 서울 리전(`ap-northeast-2`) 고유의 AZ(`2a`, `2c`) 하드코딩과 충돌하거나 타 리전에 리소스가 오발주되지 않도록, `provision-aws-resources.sh`의 `vpc` 서브명령어 함수 및 `nat-start.sh`/`nat-stop.sh` 내부에서 `export AWS_REGION=ap-northeast-2 AWS_DEFAULT_REGION=ap-northeast-2`를 강제 고정한다.
   - 모든 관리형 노드 그룹(`ng-critical`, `ng-platform`)에 `disableIMDSv1: true`, `disablePodIMDS: true`를 설정하고, Karpenter `EC2NodeClass`(`np-app`)에 `httpTokens: required`, `httpPutResponseHopLimit: 1`을 설정하여 일반 Pod가 노드 IAM Role 자격증명을 탈취하지 못하게 차단한다.
   - 컨트롤러, 백업 잡 및 Tempo는 정적 AWS 액세스 키 없이 전용 IRSA ServiceAccount를 사용하며, 리소스 범위를 최소한으로 제한한다 (ESO는 `secret:petclinic/*` 읽기만, `db-backup`은 `s3:::${BACKUP_S3_BUCKET_NAME}/petclinic/*`의 `s3:PutObject`만, `monitoring/tempo`는 전용 버킷 `s3:::${TEMPO_S3_BUCKET_NAME}`의 `ListBucket` 및 `${TEMPO_S3_BUCKET_NAME}/*`의 `Put/Get/Delete/Tagging`만, Fluent Bit는 지정된 로그 그룹 쓰기만 허용).
   - CodeBuild 서비스 역할(`CodeBuildServiceRole-${EKS_CLUSTER_NAME}`)은 `codebuild-trust.json`(`codebuild.amazonaws.com` 신뢰 + `aws:SourceAccount` 조건으로 혼동된 대리인 방지)과 `codebuild-policy.json`으로 구성되며, ECR(`petclinic-web`, `petclinic-was` 2개 리포지토리 푸시/풀만 허용), S3(전용 소스 버킷 `${CODEBUILD_S3_BUCKET_NAME}` 읽기만 허용), CloudWatch Logs(전용 프로젝트 로그 그룹 쓰기만 허용)로 권한을 엄격히 한정한다. RDS, Secrets Manager, EKS 제어 권한은 일절 부여하지 않는다.
   - K8s API 접근이 불필요한 애플리케이션 Pod(`web`, `was`, `db-init`)는 `automountServiceAccountToken: false`로 토큰 마운트를 비활성화한다.
4. **시크릿 외부화, 입력 검증 및 로그·트레이스 개인정보 보호**:
   - 소스 코드, `pom.xml`의 모든 프로필, `Dockerfile`, K8s 매니페스트, Tempo Helm values 어디에도 평문 패스워드나 정적 `access_key`/`secret_key`를 저장하지 않으며(`scripts/validate-manifests.sh`로 검증), AWS CLI 호출 시에도 비밀번호가 프로세스 인자(`argv`)에 노출되지 않도록 `jq` 표준 입력(`file:///dev/stdin`)으로 전달한다.
   - `provision-aws-resources.sh` 및 `deploy-all.sh`는 `TEMPO_S3_BUCKET_NAME != BACKUP_S3_BUCKET_NAME`, `TEMPO_RETENTION_DAYS` 양의 정수, `OTEL_TRACES_SAMPLER_ARG`(`0`~`1` 소수), `OTEL_DEPLOYMENT_ENVIRONMENT`(`^[A-Za-z0-9._-]+$`)를 사전에 검증하여 백업 버킷 오염이나 매니페스트/속성 인젝션을 차단한다. 또한 `provision-aws-resources.sh` 및 `build-and-push.sh`는 `CODEBUILD_S3_BUCKET_NAME`이 백업 및 Tempo 버킷과 상이한지 사전에 강제 검증하여 소스 버킷의 1일 만료 Lifecycle 및 SSE-S3 암호화가 백업/트레이스 데이터를 조기 삭제하거나 암호화 설정을 덮어쓰는 위험을 원천 차단한다.
   - `buildspec.yml`과 `build-and-push.sh`는 `IMAGE_TAG` 정규식(`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$`) 및 `latest` 차단을 이중 검증하며, `build`와 `post_build` 단계에 `on-failure: ABORT`를 적용하여 단일 이미지 빌드/푸시 실패 시 부분 릴리스를 방지한다. 소스 패키징 시에도 `.env*`, `*.secret`, `*.key`, `*.pem`, `id_*`, `*.pfx`, `*.p12` 등 모든 자격증명·개인키 파일을 배제한다.
   - `scripts/deploy-all.sh`는 배포 전 `staff_waf_ready` 게이트를 실행하여 WebACL 내 최우선순위(Priority 0) `BlockUnauthorizedStaffAccess` 규칙(Block 액션, UriPath STARTS_WITH `/grafana` 및 `/was`, AND 하위 NOT IPSet 매핑, 커스텀 403 본문 매핑)의 존재 및 구조적 정합성을 확인하고, 규칙 부재 시 배포를 중단하여 관리자 및 직원 전용 경로가 비인가 IP에 무방비로 공개되는 사고를 원천 방지한다.
   - `deploy-all.sh`는 신규 WAS를 먼저 배포하여 롤아웃을 확인한 후 Web 매니페스트를 적용하는 안전한 배포 순서를 강제하고, 검증되지 않은 stable 이미지 태그 변경 사고를 방지하기 위해 `PROMOTE_STABLE=1` 환경변수를 필수로 요구한다.
   - 정적 랜딩 페이지는 외부 CDN, 외부 웹폰트, 외부 지도 API 등 일체의 외부 네트워크 의존성 및 서드파티 JavaScript 없이 순수 HTML5/CSS3 및 시스템 폰트 스택으로 구축하여 서플라이 체인 공격, 스크립트 인젝션, CSP 복잡화 위험을 원천 차단한다. 메인 및 403 페이지의 연락처 이메일(`contact@`, `privacy@`)은 포트폴리오/데모 성격을 명시하고 사용자 결정에 따라 서비스 도메인으로 안내한다.
   - ESO가 AWS Secrets Manager의 시크릿을 주기적으로 동기화하여 `petclinic-rds-admin-secret`(db-init 전용), `petclinic-rds-secret`(was), `petclinic-rds-backup-secret`(db-backup), `grafana-admin`, `alertmanager-webhook`을 생성한다. Alertmanager Webhook URL은 Slack Incoming Webhook 전용 규격에 맞춰 `slack_configs`의 `api_url_file: /etc/alertmanager/secrets/alertmanager-webhook/url`로 읽어 generic webhook 불일치 오류(`400 no_text`)를 방지한다.
   - Grafana 인증 보안: 익명 접속 차단(`auth.anonymous.enabled=false`), 회원가입 차단(`users.allow_sign_up=false`), Grafana 내장 무차별 대입 방어(`security.disable_brute_force_login_protection=false`, 5분 내 5회 실패 시 계정 임시 잠금), 세션 비활성 수명(`login_maximum_inactive_lifetime_duration: 4h`), 최대 세션 수명(`login_maximum_lifetime_duration: 24h`)을 강제한다. 초기 관리자 패스워드는 기존과 동일하게 AWS Secrets Manager에서 ESO(`externalsecret-grafana.yaml`)를 통해 동기화되는 `grafana-admin` Secret을 사용한다.
   - DB 계정은 역할별로 분리한다: admin(스키마 관리, db-init만 사용), app(`SELECT/INSERT/UPDATE/DELETE`), backup(`SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, PROCESS`). 모든 계정은 MySQL 8.4 기본 규격인 `caching_sha2_password` 인증 및 `REQUIRE SSL`이 적용되며(TLS 터널 상에서 동작하므로 별도 RSA 공개키 교환 불필요), 비밀번호 변경은 `scripts/rotate-db-secrets.sh`로 반영한다(ESO 동기화가 확인되지 않으면 db-init 전에 중단).
   - 대시보드(`welcome.jsp`)에 출력되는 보호자 성명·연락처, 반려동물 및 진료 메모 등 개인정보(PII)는 JSTL `<c:out value="..."/>` 및 Spring 태그 `htmlEscape="true"`를 철저히 적용하여 Cross-Site Scripting(XSS)을 원천 차단한다.
   - 대시보드 조회(`GET /`, `/welcome`)는 외부 사용자 파라미터 수신 없이 정해진 상한(`limit=5`)으로 실행되며, 모든 쿼리는 JPA 파라미터 바인딩 및 JDBC NamedParameter 바인딩을 적용해 SQL Injection을 방어한다. 또한 `Pet.visits` EAGER 연관 로딩으로 인한 N+1 다중 쿼리 및 대규모 엔티티 그래프 메모리 점유(CWE-400 리소스 고갈)를 방어하기 위해 전용 프로젝션 DTO(`VisitSummary`)를 사용하여 단 1회의 바운디드 쿼리로 DB 커넥션 풀(최대 10)과 WAS 힙 메모리를 보호한다.
   - 운영 로그(CloudWatch Logs)에 고객 개인정보(Owner 이름·주소·전화번호)가 포함된 SQL문이 유출되지 않도록 `jpa.showSql=false`를 기본값으로 유지하고, OTel Java Agent의 JDBC 스팬도 파라미터화된 쿼리(`?`)만 기록하며 DB 비밀번호는 별도 `JDBC_PASSWORD` 환경변수로 분리한다.
5. **컨테이너 및 네임스페이스 하드닝**:
   - 모든 네임스페이스에 워크로드 특성에 맞는 Pod Security Standards(`petclinic`·`opentelemetry-operator-system`: `enforce: restricted`, `nginx-gateway`/`external-secrets`/`keda`: `enforce: baseline`, `monitoring`/`amazon-cloudwatch`: `enforce: privileged`) 레이블을 적용한다.
   - `web`, `was`, `db-init`, `db-backup`, `otel-collector`, `tempo`는 비루트 사용자(`UID/GID 10001`, `opentelemetry-operator`는 `65532`), `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities: { drop: ["ALL"] }`, `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true`(`otel-operator` 제외)로 실행되며, 런타임 쓰기가 필요한 경로만 `emptyDir` 또는 PVC 볼륨으로 마운트한다.
   - CodeBuild 환경에서 빌드되는 `web` 및 `was` 이미지는 멀티스테이지 빌드를 통해 빌드 도구와 임시 파일을 배제하고, `UID 10001` 비루트 사용자로 구동되며, JMX Exporter JAR은 SHA256 체크섬 고정 검증을 거친다. 빌드 시 `--platform linux/amd64`를 강제하여 Karpenter 노드(`np-app`, `np-app-spot`)의 x86_64 아키텍처와 일치시킨다.
   - `web` 및 `was` 워크로드에 `matchLabelKeys: [pod-template-hash]` 기반 가용영역 토폴로지 분산 제약을 적용하여 롤링 업데이트 중 특정 AZ 편중으로 인한 가용성 침해(단일 AZ 장애 시 서비스 단절)를 방지함으로써 클라우드 인프라의 장애 복원력과 고가용성(HA)을 보장한다. 별도의 특권 컨트롤러(Descheduler 등)나 RBAC 권한 상승 없이 EKS 내장 스케줄러 기능으로 동작하여 공격 표면(Attack Surface) 확장을 차단하고 최소 권한 격리 규격을 유지한다.
   - 선언형 `lifecycle.preStop.sleep` 액션은 Kubelet 데몬 내부 타이머로 실행되므로 `exec` 방식(`/bin/sh -c sleep 15`)과 달리 컨테이너 내부 쉘 바이너리 실행이나 프로세스 포크, 추가 권한 요구 없이 `Restricted` PSS 및 `readOnlyRootFilesystem: true` 보안 규격을 완벽히 유지한다. 또한 `terminationGracePeriodSeconds`를 `web: 35s`, `was: 45s`로 엄격히 제한하여 15초 안전 대기 후 비정상 프로세스 지연(hang) 상태가 발생하더라도 최대 45초 이내에 SIGKILL로 강제 회수되도록 보장함으로써 노드 드레인 및 Karpenter 통폐합 시 클러스터 리소스 고갈(DoS) 위험을 차단한다.
6. **일일 중지·기동 스크립트 최소 권한 및 무결성 보호 (`scripts/daily-stop.sh` · `scripts/daily-start.sh` · `nat-stop.sh` · `nat-start.sh`)**:
   - 두 스크립트는 AWS 컨트롤 플레인(`eks:DescribeCluster`, `eks:DescribeNodegroup`, `eks:UpdateNodegroupConfig`, `eks:DescribeUpdate`, `rds:DescribeDBInstances`, `rds:StopDBInstance`, `rds:StartDBInstance`)과 K8s 스케일링·롤아웃 API(`petclinic`·`nginx-gateway` 리소스 제어, 클러스터 범위 `nodepools`/`nodeclaims` 제어, `kube-system`·`external-secrets`·`keda`·`opentelemetry-operator-system` `deployments` 조회)만 사용하며, DB 비밀번호나 K8s `Secret` 값을 읽거나 출력하지 않는다.
   - 관리형 노드 그룹 스케일 백업 파일(`.daily-nodegroup-state.json`)은 `.gitignore`로 추적에서 제외하고 `umask 077`로 생성하며, 기동 시 모든 변경(RDS 시작 포함) 전에 JSON 유효성과 `minSize`/`desiredSize`/`maxSize` 정수·범위(`desiredSize >= 1`, `minSize <= desiredSize <= maxSize`)를 검증해 손상된 상태 파일이나 잘못된 환경변수로 인한 비정상 스케일링·부분 기동을 차단한다.
   - `nat-stop.sh`는 EKS 워커 노드 등 VPC 내 잔여 EC2 인스턴스가 `pending/running/stopping` 상태로 남아 있는 경우 egress 차단으로 인한 노드 종료 장애를 막기 위해 최대 300초(`NAT_STOP_INSTANCE_WAIT`) 동안 인스턴스 완전 종료를 대기한 뒤 NAT 삭제를 진행한다 (`--force` 옵션으로 무시 가능). EIP 반납 시에는 `Project=petclinic`의 모든 주소를 무차별 해제하지 않고, 삭제 대상 NAT에 실제로 붙어 있던 할당 ID와 실패한 실행이 남긴 `petclinic-nat-2a/2c` 태그의 미연결 주소만 선별 반납하여 타 리소스의 EIP 오반납을 방지한다. 또한 VPC 프로비저닝 시 기존 자원이 다른 CIDR, 다른 AZ, 다른 라우트 테이블 연결 상태이거나 `petclinic-vpc`가 다수 감지되는 등 설정 드리프트가 감지되면 임의로 수정하지 않고 즉시 실행을 중단(Fail-Closed)한다.

---

## 8. 설계 결정 기록

- `petclinic-eks-implementation`: 카나리 트래픽 분할(90:10 및 `X-Canary: always`)을 `HTTPRoute`에서 `web`→`was-stable`, `web-canary`→`was-canary` 두 경로로 분리하여 구현하고 기본 `was` 통합 Service도 함께 유지함 / NGF의 Gateway API `HTTPRoute` 가중치 분배를 그대로 활용하면서 카나리 배포 시 정적·동적 경로 모두 독립적으로 검증하기 위함
- `petclinic-eks-implementation`: KEDA `ScaledObject`에서 빈 `TriggerAuthentication` 리소스를 생략하고 대신 `networkpolicy-prometheus.yaml`로 Prometheus `:9090` 인그레스를 KEDA와 Grafana로 제한함 / 클러스터 내부 Prometheus가 무인증으로 동작하므로 불필요한 더미 인증 리소스 대신 네트워크 정책으로 접근 주체를 통제하는 것이 실질적인 보안을 제공함
- `petclinic-eks-implementation`: `createOrUpdatePetForm.jsp`와 `createOrUpdateVisitForm.jsp`의 flatpickr 초기화 옵션에 `{dateFormat: "Y/m/d"}`를 지정함 / 업스트림 flatpickr 기본 형식(`Y-m-d`)과 도메인 모델 `@DateTimeFormat(pattern = "yyyy/MM/dd")` 간 불일치로 인해 날짜 선택 시 폼 제출이 거절되는 기능 버그를 도메인 모델 변경 없이 해결하기 위함
- `petclinic-eks-implementation`: Karpenter 앱 노드풀을 `np-app`(On-Demand 전용, `weight: 100`, `16 vCPU` 한도)과 `np-app-spot`(Spot 전용, `48 vCPU` 한도) 두 개의 `NodePool`로 분리함 / 단일 NodePool에 `on-demand`와 `spot`을 함께 나열하면 Karpenter가 비용 최적화를 위해 Spot을 우선 선택하므로, 기본 용량은 On-Demand에 보장하고 초과 부하만 Spot으로 확장하려는 설계 의도를 정확히 구현하기 위함
- `petclinic-eks-implementation`: MySQL 프로필 빌드 시 Spring 기동 단계의 `<jdbc:initialize-database>`를 비활성화(`jdbc.initEnabled=false`)하고 `ng-critical`의 `db-init` Job이 스키마·데이터 초기화를 전담하도록 분리함 / `was` Pod가 오토스케일링이나 카나리 배포로 기동될 때마다 RDS에 중복 DDL/DML을 실행하는 경합 조건을 방지하기 위함
- `petclinic-eks-implementation`: `docker/was/Dockerfile` 빌드 단계에서 `petclinic.war`를 `webapps/ROOT`로 사전 언패킹하고 Tomcat 런타임 쓰기 디렉터리(`work`, `temp`, `logs`, `conf/Catalina`, `/tmp`)를 `emptyDir`로 마운트함 / Tomcat 11 컨테이너에서도 `readOnlyRootFilesystem: true`를 강제하여 런타임 파일시스템 변조를 차단하기 위함
- `production-hardening`: EKS를 1.31에서 1.33이 아닌 표준 지원 `1.36`으로 올리고, 1.36을 지원하지 않는 Karpenter·KEDA·ESO·AMI만 함께 올림 / 1.33은 2026-07-29부터 확장 지원 구간이라 표준 지원이 긴 버전을 택했고(`docs/design.md` Q4), 나머지 애드온(NGF, LBC, kube-prometheus-stack 등)은 이후 Q7 결정으로 함께 상향함. 기존 클러스터의 제자리 업그레이드는 다루지 않음
- `production-hardening`: 배포 시 `HTTPRoute`를 먼저 100:0으로 적용하고 Gateway의 수용(`Accepted`, 현재 generation)을 확인한 뒤에 워크로드를 롤아웃하며, `X-Canary: always` 동적 경로 검증 후에만 90:10으로 개방함 / 이전 배포의 90:10 상태에서 재배포하더라도 검증 전 카나리 Pod가 일반 트래픽을 받지 않게 하기 위함
- `production-hardening`: Alertmanager Webhook URL을 `.env` → envsubst 주입 대신 Secrets Manager + ESO로 전달하고 `url_file`로 읽음 / 토큰이 포함된 URL이 Helm release values와 Alertmanager 설정 Secret에 평문으로 남지 않게 하기 위함
- `production-hardening`: DB 계정을 `petclinic_admin`(`db-init` 전용), `petclinic_app`(WAS DML 전용), `petclinic_backup`(`db-backup` 읽기/덤프 전용) 3개로 분리하고 Tomcat JDBC Pool 상한(`maxActive=10`)을 설정함 / 애플리케이션 침해 시 과도한 DB 권한 노출을 막고 최대 스케일 아웃 시에도 RDS `max_connections` 한도를 초과하지 않도록 보장하기 위함
- `production-hardening`: Prometheus를 2 Replicas(AZ 분산 + 개별 `gp3` PVC)로 다중화하고 `was-stable`/`was-canary` KEDA `ScaledObject`에 `fallback`(4 / 2 레플리카)을 추가함 / 단일 AZ 장애나 Prometheus 일시 불능 시에도 모니터링과 WAS 오토스케일링 안전 용량이 유지되도록 하기 위함
- `production-hardening`: 서비스 오픈 전에 NGF `2.8.0`(Gateway API `v1.6.3`), LBC `v3.6.1`, kube-prometheus-stack `92.11.0`, metrics-server `3.14.0`, aws-for-fluent-bit `0.2.0`까지 1.36 기준으로 상향함 / NGF 2.x 재설치·CRD 메이저 변경은 운영 중이면 다운타임이 생기므로, 사용자 트래픽이 없을 때 신규 클러스터 기준으로 맞춰 두기 위함. NGF 2.x에서 데이터 플레인 Service가 `petclinic-gateway-nginx`로 바뀌어 ALB 백엔드를 변경하고, 차트가 PDB를 제공하므로 별도 `pdb-nginx-gateway.yaml`은 삭제함
- `production-hardening`: 카나리 개방 비율을 운영자가 정하도록 `STABLE_WEIGHT`/`CANARY_WEIGHT`(기본 90:10)를 받고, 재배포 없이 비율만 바꾸는 `scripts/set-canary-weight.sh`를 둠 (설계 Q8) / 배포 위험도에 따라 처음 여는 비율을 고르고 지표를 보며 넓히거나 즉시 100:0으로 되돌리는 것이 카나리를 택한 목적이기 때문. 검증 전 100:0 고정은 설정으로 바꿀 수 없음
- `daily-stop-start`: 퇴근 전 중지(`scripts/daily-stop.sh`) 시 `ng-critical` 관리형 노드 그룹보다 앱 워크로드(NGF 컨트롤 플레인 먼저 → 데이터 플레인·`web`·`was`)와 Karpenter `NodePool`(`np-app`, `np-app-spot` 한도 `0`)을 먼저 축소하고 `NodeClaim` 종료를 대기함 / Karpenter 컨트롤러가 `ng-critical`에서 실행되므로 관리형 노드를 먼저 내리면 앱 EC2 인스턴스가 정리되지 않고 밤새 과금되기 때문
- `daily-stop-start`: 출근 시 기동(`scripts/daily-start.sh`)에서 `.daily-nodegroup-state.json` 및 `NG_*` 목표 용량(`minSize`/`desiredSize`/`maxSize`)을 최우선 검증한 뒤 가장 느린 RDS 시작 요청(`stopping`이면 `db-instance-stopped` 대기 후 시작)과 관리형 노드 그룹 복원을 병렬 진행하고, 핵심 컨트롤러와 RDS `available` 확인 후 앱 계층을 복원함 / 잘못된 설정으로 인한 부분 기동을 막고 Multi-AZ RDS 기동 대기 시간을 단축하면서 WAS 초기 기동 시 DB 연결 실패를 방지하기 위함
- `daily-stop-start`: 일일 중지 대상에서 EKS 컨트롤 플레인, NAT Gateway, ALB(`Ingress`), `gp3` EBS PVC를 제외하고 스크립트 출력으로 잔여 비용 및 RDS 7일 자동 재시작 정책만 안내함 / 삭제·재생성 시 수십 분의 프로비저닝 지연, ALB DNS·ACM·WAF 재연결, 모니터링 데이터 유실이 발생하여 일일 온오프 목적에 맞지 않기 때문
- `daily-stop-start`: `daily-stop.sh`는 K8s 리소스 조회 시 `NotFound`만 건너뛰고 권한·인증·연결 오류는 즉시 중단하며, `daily-start.sh`는 필수 컨트롤러·워크로드 부재를 포함한 모든 조회·복원 실패 시 즉시 중단하도록 구현하고 가짜 `aws`/`kubectl` 기반 오프라인 회귀 테스트(`tests/scripts/daily-stop-start.test.sh`)로 검증함 / RBAC 누락이나 인증 만료 상태에서 관리형 노드 그룹만 0으로 내려가거나 워크로드 미복원 상태가 정상 복원으로 오인되는 것을 방지하기 위함
- `apm-tracing`: ECR `IMMUTABLE` 이미지를 재빌드하지 않고 `ng-critical`의 OpenTelemetry Operator(`Instrumentation/petclinic-java`)로 `was-stable`/`was-canary`에 Java Agent init container(`JAVA_TOOL_OPTIONS`)를 주입하며 `petclinic-was-logback` ConfigMap을 `-Dlogback.configurationFile`로 마운트함 / 기존 `CATALINA_OPTS`의 JMX Exporter(`:9404`, KEDA 스케일링용)와 충돌 없이 무코드 자동 계측과 MDC(`trace_id`/`span_id`) 로그 출력을 달성하고, Pod 주입 Webhook은 `failurePolicy: Ignore`(fail-open)로 설정하되 `deploy-all.sh`와 `daily-start.sh`에서 Operator 준비 완료 후 `was`를 기동하도록 순서를 보장함
- `apm-tracing`: 트레이스 헤드 샘플링(`parentbased_traceidratio`, 기본 `0.1`)은 SDK(Java Agent)에서 수행하고, 버전(`service.version=stable|canary`)별 RED 메트릭(`http_server_request_duration_seconds`)은 샘플링 없이 100% 전수 집계하되 `trace_based` 필터로 샘플링된 트레이스에만 Exemplar(`trace_id`)를 부착하여 Collector(`:8889`, `OpenMetricsText1.0.0`) → Prometheus(`exemplar-storage`)로 수집함 / Collector `spanmetrics` + 사후 샘플링이나 Tempo `metrics-generator`를 쓰면 Exemplar의 90%가 Tempo에 없는 트레이스(404 Dead Link)를 가리키거나 카나리 트래픽(10% × 10% = 1%)의 RED 통계가 왜곡되는 문제를 방지하기 위함
- `apm-tracing`: Grafana Tempo 블록 스토리지로 기존 `BACKUP_S3_BUCKET_NAME`을 공유하지 않고 비버전 관리·만료 Lifecycle(`${TEMPO_RETENTION_DAYS}`일, Tempo `retention: ${TEMPO_RETENTION_HOURS}`와 동일 변수에서 파생)이 적용된 전용 S3 버킷(`${TEMPO_S3_BUCKET_NAME}`)과 전용 IRSA(`monitoring/tempo`)를 분리함 / DB 백업 버킷은 덮어쓰기·삭제 방지를 위해 `s3:PutObject`만 허용하고 Versioning을 켜 둔 반면 Tempo Compactor는 `s3:DeleteObject`/`s3:ListBucket`이 필수라 버킷 공유 시 최소 권한 원칙이 깨지고 Noncurrent Version 누적으로 S3 비용이 급증하기 때문
- `apm-tracing`: 듀얼 Java Agent(JMX Exporter + OTel Java Agent) 주입에 맞춰 `was-stable`/`was-canary`의 메모리를 `1280Mi`(Request) / `2Gi`(Limit), `-XX:MaxRAMPercentage=65.0`, `readinessProbe.initialDelaySeconds: 20`으로 조정함 / OTel Agent의 Non-Heap(Metaspace·CodeCache·OTLP 배치 버퍼) 증가로 인한 cgroup `OOMKilled` 및 바이트코드 변환 중 조기 Readiness 실패를 방지하기 위함
- `tempo-chart-migration`: deprecated 처리된 `grafana/tempo` `1.24.4`(`grafana/tempo:2.9.0`)를 업스트림 이관 저장소의 `grafana-community/tempo` `3.2.1`(`grafana/tempo:3.1.1`)로 교체하고 Tempo 3.0에서 삭제된 `-mem-ballast-size-mbs` 플래그 오버라이드(`memBallastSizeMbs: 0`)를 제거함 / 업스트림 지원이 중단된 차트 경고를 해소하고, `backend_scheduler`와 `backend_worker` 양쪽에 `block_retention`(`${TEMPO_RETENTION_HOURS}`)이 동시에 반영되는 차트 `3.2.1`로 S3 Lifecycle 보존 기간 정합성을 유지하기 위함
- `tempo-chart-migration`: Tempo 3.x 전환 시 마이크로서비스 차트(`tempo-distributed`)로 분리하지 않고 단일 바이너리(`grafana-community/tempo`, `replicas: 1`) 구성을 유지함 / SDK 10% 헤드 샘플링 기준 유입량이 초당 수십~수백 스팬 수준으로 단일 프로세스 처리 용량 내에 충분하며, `tempo-distributed`가 필수로 요구하는 외부 Kafka 클러스터 및 6종 이상의 컴포넌트 분리로 인한 `ng-platform` 노드 증설·운영 복잡도를 방지하기 위함
- `architecture-pod-diagram`: 아키텍처 다이어그램을 다중 페이지로 분리하지 않고 단일 페이지(`2400 × 1800`) 내에서 Pod 단위 상세화로 전면 개편하며 기존 다이어그램은 `docs/archive/`에 백업함 (D1) / `docs/architecture.md`는 단일 SVG 임베드 구조이므로 다중 페이지 분리 시 상세 배치가 문서에 보이지 않으며, 백업 보존으로 변경 이력을 온전히 추적할 수 있기 때문
- `architecture-pod-diagram`: 레플리카 2개 이상이면서 AZ 분산 제약(topologySpreadConstraints/anti-affinity)이 있는 워크로드는 `2a`와 `2c`에 1개씩 배치하고, 레플리카 1개이거나 AZ 제약이 없는 Pod는 특정 노드에 배치하되 `· AZ 비고정` 표기를 명시함 (D3) / 실제 스케줄러 위치가 고정되지 않은 Pod를 특정 AZ에 고정된 것으로 오인하지 않도록 사실에 부합하게 표현하기 위함
- `architecture-pod-diagram`: ① DNS 조회 및 ④ 카나리 트래픽(10% 및 `X-Canary`)을 포함한 모든 사용자 요청 데이터 경로를 번호(①~⑥)가 부여된 실선으로 통일하고, 점선은 컨트롤(생성·설정·권한) 및 관측(메트릭·트레이스·로그) 전용으로 정립함 (D5, D6) / 이전 다이어그램에서 카나리/DNS가 점선으로 혼용되어 제어·수집 경로와 의미 충돌이 발생하던 문제를 해결하고 데이터 흐름의 시인성을 높이기 위함
- `architecture-pod-diagram`: 전 노드 DaemonSet 5종은 노드 박스마다 반복하지 않고 클러스터 공통 가로 띠로 일원화하고, K8s 리소스 행은 통로 확보를 위해 AZ 열별 두 상자로 분리 배치함 (D4) / 6개 노드에 30개 이상의 중복 아이콘 배치를 피해 다이어그램 가독성을 유지하고, 선이 Pod 라벨을 가로지르지 않는 정돈된 라우팅 경로를 확보하기 위함
- `codebuild-image-build`: 작업 서버(LXC 컨테이너)의 rootless podman 제약(newuidmap 권한 거부)을 해결하기 위해 로컬 도커 빌드 대신 AWS CodeBuild 원격 빌드로 전환하고 임시 S3 소스 버킷(1일 만료 Lifecycle)과 전용 IAM 역할을 구성함 / 로컬 컨테이너 권한 상승 없이도 표준화된 x86_64 클라우드 환경에서 재현 가능한 불변 이미지 빌드·푸시를 보장하고 외부 Git 자격증명 연동 없이 안전하게 동작하기 위함
- `codebuild-image-build`: GitHub Webhook / CodePipeline 자동 트리거를 연동하지 않고 `scripts/build-and-push.sh`에서 소스 아카이브를 패키징해 S3에 업로드하고 `aws codebuild start-build`를 호출하는 온디맨드 CLI 방식으로 구현함 / 검증된 특정 태그(`IMAGE_TAG`)로 필요 시에만 빌드·푸시하는 수동 통제 배포 워크플로에 부합하고 불필요한 파이프라인 상시 유지 비용 및 자격증명 노출을 방지하기 위함
- `codebuild-image-build`: `CODEBUILD_S3_BUCKET_NAME`이 기존 `BACKUP_S3_BUCKET_NAME` 및 `TEMPO_S3_BUCKET_NAME`과 동일하지 않은지 프로비저닝과 빌드 스크립트 초입에서 강제 검증함 / 소스 버킷의 1일 만료 Lifecycle 및 SSE-S3 암호화가 백업이나 Tempo 버킷에 덮어씌워져 데이터가 조기 삭제되거나 KMS 암호화 설정이 다운그레이드되는 인프라 파괴를 원천 차단하기 위함
- `codebuild-image-build`: S3 소스 아카이브 객체 키에 고유 식별자(`source/${IMAGE_TAG}-<UTC시각>-<UUID>.zip`)를 부여하고 `start-build`에 전달함 / 동일한 `IMAGE_TAG`로 여러 작업 트리에서 빌드를 동시 실행하거나 재시도할 때 첫 빌드가 다운로드하기 전 소스가 덮어써져 의도와 다른 코드가 빌드되는 경합 조건(TOCTOU)을 방지하기 위함
- `codebuild-image-build`: `buildspec.yml`의 `pre_build`·`build`·`post_build` 전 단계에 `on-failure: ABORT`를 설정하고 `IMAGE_TAG` 정규식 검증 및 ECR 불변 태그 사전 조회를 적용함 / 빌드 실패 후 빈 이미지가 푸시되거나 was 푸시 실패 후 web만 푸시되는 부분 배포(half-release)를 방지하고 이미 존재하는 태그로 인한 불필요한 빌드 시간 낭비를 차단하기 위함
- `codebuild-image-build`: `build-and-push.sh` 및 `lib.sh`에서 호출 시점에 지정된 `IMAGE_TAG`와 `BUILD_TARGET`을 `.env`의 빈 기본값보다 우선 보존하도록 처리함 / 사용자가 단일 대상(`BUILD_TARGET=web` 등)을 명시적으로 빌드하려 할 때 `.env`의 빈 값으로 덮어써져 전체 이미지가 빌드·푸시되거나 기존 태그 충돌로 작업이 중단되는 결함을 방지하기 위함
- `rds-mysql-84`: 서울 리전(`ap-northeast-2`)에서 8.0.39 신규 생성이 불가능하고 MySQL 8.0 표준 지원이 2026-07 종료됨에 따라, RDS MySQL 엔진 버전을 5년간 표준 지원이 보장되는 최신 8.4 LTS(`8.4.11`)로 고정하고 DB 파라미터 그룹 패밀리를 `mysql8.4`로 전환함 / Extended Support 추가 과금을 방지하고 2029년 7월까지 장기적인 운영 안정성을 확보하기 위함
- `rds-mysql-84`: MySQL 8.4에서 `mysql_native_password`가 기본 비활성화됨에 따라 기본 인증 방식인 `caching_sha2_password`를 적용하고, 애플리케이션 JDBC 드라이버를 `mysql-connector-j` `8.4.0`으로 상향함 / 전 구간 TLS(`require_secure_transport=ON`, `sslMode=REQUIRED`, `REQUIRE SSL`)가 강제되므로 추가 RSA 공개키 교환(`allowPublicKeyRetrieval=true`) 없이 안전하고 호환성 높은 인증을 달성하기 위함
- `rds-mysql-84`: `db-init` Job 및 `db-backup` CronJob의 클라이언트 컨테이너 이미지를 RDS 엔진과 일치하는 `mysql:8.4.11`로 변경하고 `scripts/validate-manifests.sh`에 엔진·파라미터 그룹·이미지·드라이버 정적 검증을 추가함 / 클라이언트-서버 간 메이저 버전 불일치로 인한 프로토콜 경고 및 mysqldump 호환성 문제를 방지하고 버전 드리프트를 배포 전 차단하기 위함
- `staff-dashboard`: 메인 화면(`/` 및 `/welcome`)을 정적 뷰 컨트롤러(`<mvc:view-controller>`)에서 `@Controller` 기반 `WelcomeController`로 전환하고 `ClinicService` 파사드를 통해 핵심 통계 3종(보호자·반려동물·방문 수)과 수의사 명단, 보호자 검색 폼을 제공하는 운영 대시보드로 개편함 / 병원 스태프가 첫 화면에서 병원 운영 지표와 최근 진료 흐름을 즉시 파악하고 신속 검색과 방문 등록으로 바로 연계할 수 있는 콘솔을 제공하기 위함
- `staff-dashboard`: 대시보드 최근 방문 목록(`findRecentVisits`) 조회 시 `Visit` 엔티티 대신 읽기 전용 플랫 프로젝션 DTO(`VisitSummary`)를 도입함 / `Pet.visits` 컬렉션의 `FetchType.EAGER` 매핑으로 인해 fetch join 시에도 반려동물별 전체 방문 이력이 N+1 추가 조회되는 부하를 원천 차단하고 단 1회의 상한 제한(`limit=5`) 쿼리로만 필요한 필드를 로딩하기 위함 (design.md의 `List<Visit>` 엔티티 그래프 대신 `VisitSummary` 프로젝션 적용)
- `staff-dashboard`: DB 스키마(DDL) 변경 없이 기존 테이블 구조를 유지하고, 목업의 담당 수의사(Assigned Vet)·당직 상태(On Duty) 및 당일 방문(Visits Today) 대신 수의사 전문 분야 명단과 전체 누적 방문 수로 대체함 / 사용자 요구사항에 따라 DB 스키마 수정을 일절 배제하고 과거 시점(2008~2011) 샘플 데이터 환경에서도 빈 화면 없이 일관된 통계를 제공하기 위함
- `staff-dashboard`: 목업의 전역 신규 방문/반려동물 등록 버튼 대신 최근 방문 행별 개별 등록 링크(`/owners/{ownerId}/pets/{petId}/visits/new`)를 제공함 / PetClinic 도메인 구조상 방문 등록은 반드시 특정 보호자 및 반려동물 컨텍스트 하에서만 유효하여 유효하지 않은 전역 엔드포인트 오류를 방지하기 위함
- `spread-on-rollout`: 롤링 업데이트 시 구버전 ReplicaSet Pod와의 라벨 간섭으로 인한 AZ 편중을 방지하기 위해 `web`·`was` stable/canary 매니페스트에 EKS 1.36 내장 스케줄러 기능인 `matchLabelKeys: [pod-template-hash]`를 적용함 / 별도 Descheduler 데몬 설치 없이 Deployment 컨트롤러가 주입하는 고유 해시 기준으로만 zone 스큐를 계산하여 롤아웃 중 및 완료 후에도 `2a`와 `2c` 간 AZ 균등 분산(maxSkew 1)을 안정적으로 보장하기 위함
- `spread-on-rollout`: `topologyKey`로 가용영역(`topology.kubernetes.io/zone`) 분산만 적용하고 호스트명(`kubernetes.io/hostname`) 단위 분산은 제외함 / 현재 `np-app` 노드가 AZ별 1대씩 운영되어 AZ 분산만으로 노드 분산이 동시 달성되며, 노드 단위 `DoNotSchedule` 설정 시 HPA/KEDA 스케일아웃마다 Karpenter가 인스턴스를 무조건 신규 생성하여 발생하는 과도한 인프라 비용 낭비 및 빈 패킹 정책과의 경합을 방지하기 위함
- `spread-on-rollout`: stable 워크로드에는 엄격한 `whenUnsatisfiable: DoNotSchedule`을, canary 워크로드에는 유연한 `whenUnsatisfiable: ScheduleAnyway` 정책을 분리 유지함 / stable은 프로덕션 무중단 HA를 위해 단일 AZ 몰림을 원천 차단하고, canary는 적은 레플리카 수(1개 등) 및 임시 검증 특성상 스케줄링 유연성을 확보하여 단일 노드 환경에서도 롤아웃이 블록되지 않도록 하기 위함
- `spread-on-rollout`: `topologySpreadConstraints`가 신규 Pod 배치 시점에만 평가되는 Kubernetes 스케줄러 한계(스케일다운 시 ReplicaSet이 AZ 균형을 고려하지 않음)를 명시하고, `scripts/validate-manifests.sh`에 `matchLabelKeys` 리스트 타입(`isinstance(..., list)`) 및 zone 분산 필수 검증을 추가함 / HPA/KEDA 축소 후 2:0 등 편중 발생 시 `rollout restart` 기반 자가 치유 운영 방안을 정립하고, 잘못된 스칼라 문자열 설정이나 분산 누락으로 인한 가용성 회귀를 배포 전 정적 검사로 차단하기 위함 (design.md의 축소 시 대칭 보장 가정을 실제 K8s 한계 기준으로 정정 반영)
- `graceful-shutdown`: 롤링 업데이트 시 EndpointSlice 비동기 전파 시차(1~3초)로 인한 HTTP 502/504(Connection refused) 에러를 방지하기 위해 `web`·`was` stable/canary 4개 Deployment의 모든 컨테이너에 `lifecycle.preStop.sleep: { seconds: 15 }`와 `terminationGracePeriodSeconds`(`web` 35초, `was` 45초)를 적용함 / Pod 삭제 즉시 엔드포인트 목록에서 제외된 후 네트워크 라우팅(NGF 및 kube-proxy iptables)이 수렴할 때까지 기존 프로세스를 정상 가동 상태로 유지하여 롤링 재시작 중 요청 실패 0건(100% 무중단)을 달성하기 위함
- `graceful-shutdown`: `preStop` 구현 방식으로 컨테이너 내부 `exec`(`/bin/sh -c sleep 15`) 대신 EKS 1.36(K8s 1.32+ GA) 네이티브 선언형 `lifecycle.preStop.sleep`을 채택함 / 컨테이너 내 쉘·바이너리 의존성이 없어 쉘이 없는 경량 사이드카(`nginx-prometheus-exporter`)에도 동일 적용 가능하며, 프로세스 포크 오버헤드 없이 Kubelet 자체 타이머로 안전하게 동작하기 위함
- `graceful-shutdown`: `web` Pod 내 메인 `nginx` 컨테이너뿐만 아니라 사이드카인 `nginx-exporter` 컨테이너에도 동일하게 `lifecycle.preStop.sleep: 15`를 적용함 / Kubernetes가 컨테이너별 preStop 및 종료 신호를 병렬 처리하므로 메트릭 수집 사이드카가 조기 종료되어 배포 중 Prometheus 스크래핑 오류가 발생하는 것을 방지하기 위함
- `graceful-shutdown`: `web` Nginx에 `proxy_next_upstream`을 추가하거나 Nginx 이미지를 재빌드(`v1.0.3`)하지 않고 K8s 워크로드 수명주기 제어만으로 해결함 / Kubernetes ClusterIP 가상 IP 환경에서 Nginx 자체 재시도만으로는 iptables 목적지 Pod 전환을 제어하기 어렵고 비멱등(`POST`) 요청 중복 실행 위험이 있으며, WAS 계층의 `preStop.sleep`으로 Nginx가 종료 중인 Pod로 연결을 시도하는 상황 자체가 원천 차단되기 때문
- `graceful-shutdown`: WAS 프로세스 종료 시 Spring Boot 및 HikariCP 가정 대신 실제 패키징인 외부 Tomcat 11 WAR 및 Tomcat JDBC Pool(`org.apache.tomcat.jdbc.pool.DataSource`) 수명주기에 맞춰 Catalina 셧다운 훅 → 웹 컨텍스트 `DispatcherServlet` 종료 → `DataSource.close()` 풀 정리 → OTel Java Agent JVM 셧다운 훅 플러시 경로를 기준으로 45초 유예 시간을 산정함 / 실제 런타임 아키텍처(Spring Framework 7.x WAR 배포)에 정확히 부합하는 정상 드레인 순서를 확립하고 남은 유예 시간(30초) 동안 안전한 트랜잭션 완료와 트레이스 플러시를 보장하기 위함 (design.md 초기 기술의 Spring Boot/HikariCP 가정을 실제 구현 기준으로 정정 반영)
- `graceful-shutdown`: `scripts/validate-manifests.sh`에 `lifecycle.preStop.sleep.seconds` 15초 이상 및 `terminationGracePeriodSeconds`(`web` 35초, `was` 45초) 정적 검증 규칙(§11)을 추가함 / 배포 전 매니페스트 레벨에서 셧다운 지연 누락이나 grace period 역전(grace period <= preStop)으로 인한 조기 SIGKILL 강제 종료 결함을 사전에 차단하기 위함
- `grafana-public-path`: 별도 서브도메인 대신 기존 도메인 하위 경로(`https://${DOMAIN_NAME}/grafana/`)와 NGF `HTTPRoute` + Gateway API `ReferenceGrant` 방식을 채택함 / 신규 ACM 인증서 발급이나 Route 53 레코드 추가 없이 기존 엔드포인트를 재활용하고, ALB IngressGroup 방식과 달리 기존 ALB 리스너를 변경하지 않아 메인 서비스 중단 위험을 배제하며 Gateway API 표준 교차 네임스페이스 접근 제어를 준수하기 위함
- `grafana-public-path`: Gateway API 최장 접두사 일치(Longest Prefix Match) 원칙에 따라 `/grafana`(8자)를 `/`(1자) 카나리 라우트와 분리하고, WAF 최우선순위(Priority 0)에 IPSet 기반 차단 규칙(`BlockUnauthorizedGrafanaAccess`)을 배치함 / `X-Canary: always` 헤더나 카나리 가중치 분할(90:10)과 상호 간섭 없이 100% Grafana로 독립 라우팅되도록 보장하고, 비인가 IP 요청을 AWS 엣지에서 즉시 403으로 차단하며 인가된 요청만 Managed Rules를 거치도록 다층 방어하기 위함
- `grafana-public-path`: WAF 경로 비교 시 `URL_DECODE` → `NORMALIZE_PATH` → `LOWERCASE` 3단계 텍스트 변환을 순차 적용하고 SearchString을 raw(`--cli-binary-format raw-in-base64-out`)로 전송함 / NGF(Nginx)가 `%67rafana`, `//grafana`, `/./grafana` 등을 모두 `/grafana`로 정규화하여 프록시하므로 단순 대소문자 무시만으로는 발생할 수 있는 인코딩/경로 우회 취약점을 원천 차단하고 AWS CLI v2의 base64 오변환을 방지하기 위함 (design.md 초기 안의 대소문자 무시를 실제 Nginx 동작 기준 정규화로 고도화 반영)
- `grafana-public-path`: Grafana 로그인 시도 제한은 비표준 `auth.max_login_attempts` 대신 Grafana 내장 무차별 대입 방어(`security.disable_brute_force_login_protection = false`, 5분 내 5회 실패 시 계정 임시 잠금)를 사용하고 `users.auto_assign_org_role`은 생략함 / Grafana 설정 스펙에 존재하지 않는 무효 키를 제거하고 회원가입 차단(`allow_sign_up = false`) 상태에 부합하도록 설정을 정제하기 위함 (design.md의 `auth.max_login_attempts` 설정을 실제 Grafana 지원 설정 기준으로 정정 반영)
- `grafana-public-path`: `networkpolicy-grafana.yaml`에서 `nginx-gateway` 네임스페이스 전체 대신 데이터 플레인 Pod(`gateway.networking.k8s.io/gateway-name: petclinic-gateway`)와 Prometheus Pod로만 인입을 제한함 / 동일 네임스페이스의 NGF 컨트롤 플레인 Pod나 타 Pod가 Grafana Pod(:3000)에 불필요하게 접근하는 것을 차단하여 최소 권한 네트워크 격리를 달성하기 위함 (design.md의 네임스페이스 전체 허용을 실제 데이터 플레인 Pod 선택자로 정밀화 반영)
- `grafana-public-path`: WAF 적용을 `pre-cluster` 내 일괄 실행 대신 별도 멱등 하위 명령(`provision-aws-resources.sh grafana-waf`)으로 분리하고 `deploy-all.sh` 초입에 `grafana_waf_ready` 게이트를 추가함 / `WAF_WEB_ACL_ARN` 생성 순서 의존성을 해소하고 허용 IP 변경 시 가볍게 재실행할 수 있도록 하며, WAF 규칙 미적용 상태에서 `/grafana` 경로가 모든 외부에 무방비로 공개되는 사고를 배포 전 정적 검증으로 차단하기 위함
- `grafana-public-path`: Alertmanager 알림 채널을 일반 Webhook에서 Slack Incoming Webhook 전용 규격(`slack_configs`, `api_url_file`)으로 정정함 / Slack Incoming Webhook은 `webhook_configs`의 일반 JSON 페이로드를 `400 no_text`로 거부하므로 Slack이 요구하는 텍스트/첨부 포맷 계약을 충족하고 평문 노출 없이 시크릿 파일에서 URL을 안전하게 읽도록 하기 위함
- `vpc-provisioning`: 10-26 구축 당시 저장소 밖 임시 스크립트로 생성되었던 VPC·서브넷·IGW·라우트테이블을 멱등성과 서울 리전 강제 고정을 갖춘 저장소 공식 스크립트(`provision-aws-resources.sh vpc`)로 코드화하고, 일일 약 $2.83의 비용을 유발하는 NAT 게이트웨이를 온디맨드로 제어하는 전용 스크립트(`nat-stop.sh`, `nat-start.sh`) 및 `daily-stop/start` 연동을 구축함 / 저장소만으로 완전한 네트워크 인프라 재현성을 확보하고 비업무 시간 고정비를 최소화하기 위함
- `vpc-provisioning`: 리전 강제 고정을 `provision-aws-resources.sh` 최상단 전역이 아닌 `vpc` 서브명령어 함수 내부 및 `nat-start.sh`/`nat-stop.sh` 내부로 한정함 / `pre-cluster` 등 스크립트의 타 단계는 `.env`에 정의된 `AWS_REGION` 값을 정상 활용해야 하므로 불필요한 전역 환경변수 간섭을 방지하고 서울 리전 AZ(`2a`, `2c`)가 하드코딩된 네트워크 스크립트만 안전하게 격리하기 위함 (design.md 최상단 고정 방식을 실제 서브명령어/스크립트별 격리 구현으로 정제 반영)
- `vpc-provisioning`: 퍼블릭 및 앱 서브넷에 `kubernetes.io/role/elb` 및 `internal-elb` 태그를 부여하지 않고 10-26 실환경과 100% 동일하게 유지함 / 10-26 구축 당시 태그가 없었으며, ALB Ingress 매니페스트(`alb-ingress.yaml`)에서 서브넷 ID를 어노테이션으로 명시적 직접 지정하므로 불필요한 추가 태그 없이 실환경 정합성을 보장하기 위함 (design.md 참고 항목의 태그 부여를 실제 구현 기준으로 미부여 반영)
- `vpc-provisioning`: 태그 기반 조회 시 기존 VPC·서브넷·IGW·라우트테이블이 다른 CIDR/AZ/연결 상태이거나 다수 존재할 경우 임의로 수정하지 않고 즉시 실행을 중단(Fail-Closed)하며, DB 라우트 테이블 재사용 시 인터넷 라우트(`0.0.0.0/0`)가 감지되면 즉시 중단하도록 구현함 / 정상 운영 중인 실환경 네트워크 설정을 조용히 변경하거나 DB 계층의 에어갭 격리가 훼손되는 사고를 방지하기 위함 (단, 삭제된 NAT를 가리키는 앱 라우트의 blackhole 경로는 replace-route로 자동 복구)
- `vpc-provisioning`: `vpc` 서브명령어의 NAT 생성·라우트 연결 로직을 독자 구현하지 않고 `scripts/nat-start.sh`를 직접 호출하며, `nat-start.sh`는 `.env`가 아닌 태그(`Name=petclinic-vpc`)로 VPC를 탐색하도록 구현함 / 코드 중복을 제거하고 단일 책임 원칙을 준수하며 신규 VPC 프로비저닝 직후 `.env`를 채우기 전 단계에서도 NAT 기동 스크립트가 독립적으로 완결 동작하도록 보장하기 위함
- `vpc-provisioning`: `nat-stop.sh`에 VPC 내 잔여 EC2 인스턴스 종료 대기 안전장치(`NAT_STOP_INSTANCE_WAIT`, 기본 300초)를 추가하고, EIP 반납 범위를 삭제 대상 NAT의 EIP 및 미연결 `petclinic-nat-2a/2c` 주소로만 한정함 / 노드 인스턴스가 종료되기 전에 NAT가 조기 삭제되어 노드 egress 및 EKS 통신 장애가 발생하는 것을 방지하고, 동일 프로젝트 태그를 가진 타 리소스의 EIP 오반납을 원천 차단하기 위함 (design.md의 무조건 즉시 삭제 및 EIP 일괄 반납을 실제 안전 대기 및 정밀 선별 반납으로 고도화 반영)
- `vpc-provisioning`: `daily-stop.sh`와 `daily-start.sh`의 기존 워크플로를 보존하면서 선택적 플래그(`--stop-nat` / `--start-nat`)를 제공하고, `nat-start.sh`와 `nat-stop.sh`에 `--dry-run` 플래그를 구현함 / 일일 운영 편의성을 극대화하는 동시에 오프라인 매니페스트 정적 검증(`validate-manifests.sh`) 및 단위 테스트가 실제 AWS API 호출 없이 안전하게 실행되도록 지원하기 위함
- `alert-5xx-accuracy`: `PetClinicHttp5xxRateHigh` 알림 규칙의 메트릭 소스를 Tomcat JMX MBean(`tomcat_errorcount_total`)에서 OpenTelemetry RED 메트릭(`http_server_request_duration_seconds_count{service_name="petclinic-was", http_response_status_code=~"5.."}`)으로 전환함 / Tomcat의 `errorCount`는 400 이상 모든 응답(404 등 클라이언트 에러)을 합산하여 기동 직후나 저트래픽 환경에서 의도된 404 요청만으로도 5xx critical 오경보가 울리는 문제를 방지하고, Grafana APM 대시보드와 동일한 상태 코드 필터링 지표를 공유하여 관측성 일관성을 유지하기 위함
- `alert-5xx-accuracy`: 알림 PromQL 수식에 최소 트래픽 가드(`and sum(rate) >= 1`)를 결합하지 않고 순수 5xx 비율(`sum(rate(5xx)) / sum(rate(total)) > 0.05`)과 `for: 5m` 지속 평가 조건을 유지함 / 5xx 전용 메트릭 전환만으로 4xx 유입 시 분자가 0이 되어 오경보가 원천 차단되며, 트래픽 가드를 강제할 경우 야간·한산 시간대(0.1~0.5 req/s)에 DB 장애 등으로 100% 500 에러가 발생해도 경보가 누락되는 감시 사각지대를 방지하기 위함
- `alert-5xx-accuracy`: `tests/monitoring/petclinic-rules.test.yaml`에 기존 DB 백업 실패 외에 4xx 전용 유입(30% 404), 저트래픽 환경(0.17 req/s + 30% 404), 실제 5xx 장애 발화 및 해제(10% 500) 시나리오 3종을 promtool 단위 테스트로 추가함 / WAS 에러율 알림 규칙 변경 시 4xx 노이즈 차단과 저트래픽 환경 안전성을 오프라인 회귀 테스트(`scripts/test-prometheus-rules.sh`)로 100% 지속 검증하기 위함
- `landing-page`: `https://${DOMAIN_NAME}/` 루트를 외부 네트워크·CDN·API 의존성이 없는 순수 HTML5/CSS3 정적 병원 랜딩 페이지로 교체하고 Web Nginx가 로컬 직접 서빙하도록 구현함 / WAS(Tomcat)나 DB(RDS) 장애·점검 시에도 병원 소개, 진료과목, 의료진, 진료시간, 오시는 길 안내의 100% 가용성을 보장하기 위함
- `landing-page`: 기존 직원용 PetClinic 관리 애플리케이션을 하위 경로 `/was/`로 이동하고 Tomcat 서블릿 컨텍스트를 `webapps/was`로 재배치함 / 일반 대외 공개 영역과 내부 환자·진료 관리 업무 시스템의 네트워크·보안 경계를 명확히 분리하기 위함
- `landing-page`: `/was/` 접근 제어를 별도 규칙으로 분리하지 않고 AWS WAFv2 최우선순위(Priority 0) 단일 규칙 `BlockUnauthorizedStaffAccess` 내에서 `/grafana`와 함께 단일 `OrStatement`로 결합하여 관리함 / 추가 WAF 규칙 요금(월 $1.00 절감) 및 WCU 낭비 없이 관리자 및 직원 전용 경로를 동일한 IP 화이트리스트(`GRAFANA_ALLOWED_CIDRS`)와 403 커스텀 응답으로 일원화 통제하기 위함
- `landing-page`: WAF 커스텀 응답 본문(`petclinic-staff-403`)에는 경량 인라인 스타일 HTML만 담고 200KB급 안내 사진은 Web Nginx의 공개 경로(`/resources/images/403.webp`)에서 브라우저가 지연 로딩하도록 분리함 / AWS WAFv2의 16KB 커스텀 응답 본문 용량 제한을 우회하면서도 시각적으로 완성도 높은 친근한 출입 제한 안내 화면을 제공하기 위함
- `landing-page`: Web Nginx에 `error_page 404 /404.html`을 신설하고 시스템 폰트와 통일된 레이아웃의 전용 404 페이지를 Nginx 레벨에서 직접 서빙함 / 존재하지 않는 경로 요청 시 WAS로의 불필요한 트래픽 유입을 차단하고 403 페이지와 일관된 브랜드 경험을 제공하기 위함
- `landing-page`: Tomcat `server.xml`에 `RemoteIpValve`(`internalProxies`로 사설 IP 대역 지정)를 구성하고 Web Nginx에서 `X-Forwarded-Proto https` 및 `X-Forwarded-Port 443`을 전달하도록 구현함 / Spring MVC `redirect:` 시 `request.getScheme()`이 HTTPS로 올바르게 인식되어 `Location` 헤더가 즉시 `https://${DOMAIN_NAME}/was/...`로 발급됨으로써 기존의 302 → ALB 301 리다이렉트 루프를 근본적으로 해결하기 위함
- `landing-page`: Web Nginx의 자체 리다이렉트(`location = /was`)에 `absolute_redirect off;`를 설정함 / Nginx가 8080 포트나 비TLS 스키마가 포함된 절대 URL을 임의 생성하지 않고 브라우저에 상대 경로(`/was/`)를 반환하도록 보장하기 위함
- `landing-page`: `/was/` 경로 이전을 2단계 릴리스로 나누고 1차 단계에서는 Tomcat `server.xml`에 `RewriteValve`(`rewrite.config`)를 배치하여 비`/was` 요청을 `/was/`로 내부 재작성하며 k8s Deployment 프로브 경로를 `/`로 유지함 / 공유 매니페스트 환경에서 신규 WAS 이미지가 구버전 Web Nginx 및 구버전 프로브와 호환되어 카나리 배포와 이미지 롤백 시 서비스 단절을 방지하기 위함 (design.md 초기 프로브 `/was/` 즉시 변경 대신 1차 릴리스 호환을 위한 실제 구현 기준 반영)
- `landing-page`: k8s `conf/Catalina`가 `emptyDir`로 마운트되어 이미지 내부 `rewrite.config`가 가려지는 문제를 `docker/was/setenv.sh` 기동 시점에 `conf/Catalina/localhost/rewrite.config`로 복사하도록 조치함 / 읽기 전용 루트 파일시스템 규격을 지키면서도 Tomcat RewriteValve가 런타임에 재작성 규칙을 정상 로드하도록 보장하기 위함
- `landing-page`: `scripts/deploy-all.sh`에서 신규 WAS를 먼저 배포하고 롤아웃을 확인한 뒤 Web 매니페스트를 적용하도록 순서를 정립하고, `STABLE_IMAGE_TAG` 변경 시 `PROMOTE_STABLE=1` 명시적 승인 가드를 강제함 / 신규 Web이 구버전 WAS로 `/was/` 요청을 보내 404가 발생하는 사고를 차단하고 검증되지 않은 stable 이미지 조기 승격을 방지하기 위함
- `landing-page`: 구버전 Web으로 긴급 롤백 시 내부 직원용 시스템 노출을 막기 위해 `STAFF_WAF_SCOPE=all`로 사이트 전체(공개 이미지 제외)를 WAF 허용 IP 뒤로 선차단하는 비상 절차를 마련하고, `staff_waf_ready` 게이트가 `all` 스코프에서도 통과하도록 지원함 / 롤백 및 재배포 과도기 중 내부 환자·진료 개인정보가 외부에 무방비로 노출되는 보안 공백을 원천 차단하기 위함
- `landing-page`: JSP 뷰 레이어(`createOrUpdatePetForm.jsp`, `createOrUpdateVisitForm.jsp`)의 flatpickr CSS/JS 하드코딩 경로를 `<spring:url>` 태그 기반의 컨텍스트 상대 경로로 수정함 / 서블릿 컨텍스트가 `/was`로 이동함에 따라 발생하던 flatpickr 정적 리소스 404 및 날짜 선택 UI 기능 장애를 도메인 로직 변경 없이 해결하기 위함
