# 보안 및 인프라 점검 결과 (`docs/features/landing-page/security.md`)

## Security Round 1 — 2026-10-27 (대상 커밋: 0c70b54)

점검 범위: `git diff master...HEAD` 전체(`docker/was/Dockerfile`, `docker/was/server.xml`, `docker/web/Dockerfile`, `docker/web/nginx.conf`, `docker/web/static/*`, `infra/aws/provision-aws-resources.sh`, `infra/aws/waf-staff-403.html`, `k8s/was/deployment-stable.yaml`, `k8s/was/deployment-canary.yaml`, `scripts/deploy-all.sh`, `scripts/lib.sh`, `scripts/validate-manifests.sh`, `tests/scripts/grafana-waf-ready.test.sh`, `app/src/main/webapp/WEB-INF/jsp/pets/*`, `docs/daily/2026-10-27.md`, `docs/features/landing-page/design.md`, `docs/features/landing-page/review.md`), `docs/architecture.md` 보안 구조(§7) 및 `docs/features/landing-page/design.md` 보안 요구사항(§5) 준수 여부.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env` 파일은 `.gitignore`에 등록되어 안전하게 제외되어 있으며, 신규 커밋에 하드코딩된 API Key, DB 패스워드, AWS 자격증명 없음. DB 암호는 Kubernetes Secret `petclinic-rds-secret`의 `secretKeyRef` 방식을 유지함).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 보완 필요 (12자리 AWS 계정 ID, 실존 IAM/WAF ARN의 노출은 없으나, `docs/features/landing-page/design.md:12`에 실제 서비스 도메인 실값 `${DOMAIN_NAME}`이 하드코딩되어 노출됨. 또한 공개 데모 랜딩 페이지 `docker/web/static/index.html:119, 150`의 이메일 주소에도 동일 도메인이 기재되어 있음).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (신규 IAM 역할이나 과다 권한 생성 없음. WAF IPSet 및 NGF 라우팅을 통해 인가된 IP만 내부 직원용 애플리케이션에 도달하도록 통제함).
- **네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)**: 양호 (AWS WAF 최우선순위(Priority 0)에 `BlockUnauthorizedStaffAccess` 규칙을 배치하여 비인가 IP의 `/grafana*` 및 `/was*` 접근을 AWS 엣지에서 HTTP 403으로 원천 차단함. 루트 경로(`/`) 및 정적 에셋(`/resources/`, `/webjars/`, `/css/`)만 Nginx가 직접 서빙하여 외부에 공개됨. 다만 엣지 403 응답에 웹 보안 헤더 보완이 권장됨).
- **입력 검증 누락 (인젝션, 경로 조작, SSRF)**: 보완 필요 (WAF 규칙 생성부에서는 `URL_DECODE` → `NORMALIZE_PATH` → `LOWERCASE` 3단계 텍스트 변환 파이프라인을 정상 적용하여 `%2fwas`, `/./was`, `/WAS` 등의 인코딩/경로 조작 우회를 차단하도록 구성했으나, `scripts/lib.sh`의 배포 전 WAF 검증 게이트 `staff_waf_ready`에서 `LOWERCASE` 누락 및 변환 우선순위 검증이 빠져 있어 취약한 WAF 규칙이 게이트를 통과할 수 있는 결함이 존재함).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (Tomcat `11.0.2-jdk21-temurin-noble`, Maven `3.9.9-eclipse-temurin-21`, Nginx `1.27.2-alpine`, JMX Exporter `1.0.1` 등 특정 고정 태그 및 SHA256 체크섬을 사용하며 `latest` 태그 미사용).
- **Dockerfile/IaC (root 실행, latest 태그, 암호화 미설정)**: 양호 (Web 및 WAS 컨테이너 모두 UID 10001 비루트 전용 계정으로 구동되며, K8s 매니페스트 상 `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]` 보안 컨텍스트 강제 적용됨. 단, WAS `server.xml` 상의 불필요한 종료 포트 및 동적 배포 설정에 대한 강화 권고).
- **design.md 의 보안 요구사항 및 architecture.md 의 보안 구조 준수 여부**: 보완 필요 (`RemoteIpValve`의 `internalProxies`를 사설 IP 대역(`10.0.0.0/16` 등)으로 제한하여 외부 헤더 위조를 차단한 점, Web Nginx에서 `X-Forwarded-Proto https` 및 `X-Forwarded-Port 443`을 명시 주입하여 302 Location의 `http://` 다운그레이드 문제를 해결한 점 등은 우수하나, `scripts/deploy-all.sh`에서 사용자 및 설계와 합의된 "stable web 선적용 후 stable WAS 적용" 순서를 지키지 않고 동시 배포하여 재배포 시 공개 `/` 서비스가 404로 깨지는 가용성 결함이 존재함).

---

### Critical
지적 사항 없음.

### High
- [x] (4237983 design.md 는 `${DOMAIN_NAME}` 로 교체. 정적 페이지 이메일은 사용자 결정으로 유지 — 실제 서비스 도메인에서 내려가는 데모 연락처 표기이고 하단에 데모 문구 병기) `docs/features/landing-page/design.md:12` — **설계 문서 내 실제 서비스 도메인 실값 노출.** `docs/features/landing-page/design.md:12` 배경 설명에 실제 프로덕션 서비스 도메인(`${DOMAIN_NAME}`)이 하드코딩되어 있다(`현재 ${DOMAIN_NAME}의 루트 경로(/)에...`). `architecture.md` 및 프로젝트 표준에 맞추어 `${DOMAIN_NAME}` 플레이스홀더로 교체해야 한다. 아울러 공개 정적 페이지인 `docker/web/static/index.html:119, 150`의 이메일 주소(`contact@${DOMAIN_NAME}`, `privacy@${DOMAIN_NAME}`) 역시 실제 도메인이 노출되지 않도록 RFC 2606 예약 도메인(예: `example.com` 또는 `${DOMAIN_NAME}`)으로 교체할 것을 권고한다.
- [x] (4237983) `scripts/deploy-all.sh:154-158` — **배포 순서 역전에 따른 무중단 가용성 훼손 (설계 합의 Q2 위반).** 기존 `web`은 `/` 요청을 WAS(`:8080`)로 프록시한다. `deploy-all.sh` 154~155행에서 WAS와 web 매니페스트를 동시에 적용하고 156행에서 `deploy/was-stable`의 롤아웃을 먼저 대기하도록 되어 있는데, 새 `was-stable`이 먼저 준비될 경우 Tomcat에는 `/was` 컨텍스트만 존재하므로 기존 `web`을 통해 들어오는 공개 메인(`/`) 요청이 일시적으로 404를 반환하며 대외 서비스 중단이 발생한다. `design.md` §7.1 및 Q2에서 합의된 절차대로 "stable `web` 매니페스트 적용 및 롤아웃 대기 완료 후 stable `was` 매니페스트를 적용"하도록 배포 순서를 엄격히 분리해야 한다.

### Medium
- [x] (4237983) `scripts/lib.sh:62` — **배포 전 WAF 게이트(`staff_waf_ready`)의 텍스트 변환 검증 불완전.** `staff_waf_ready` 내 `contains(["URL_DECODE", "NORMALIZE_PATH"])` 로직은 텍스트 변환의 단순 포함 여부만 확인할 뿐, 대소문자 우회 차단을 위한 `LOWERCASE` 변환 존재 여부와 `Priority` 순서(0: `URL_DECODE` -> 1: `NORMALIZE_PATH` -> 2: `LOWERCASE`)를 검증하지 않는다. 만약 WAF 규칙에서 `LOWERCASE`가 누락되거나 변환 순서가 뒤바뀐 채 적용되더라도 배포 게이트를 통과하여 WAF 우회 공격에 노출될 위험이 있다. `TextTransformations`의 우선순위 및 3개 변환 항목이 설계와 완벽히 일치하는지 엄격히 검증하도록 jq 조건을 강화하고, `tests/scripts/grafana-waf-ready.test.sh`에 관련 실패 검증 케이스를 추가해야 한다.
- [x] (4237983) `infra/aws/provision-aws-resources.sh:550-551` — **WAF 엣지 403 차단 응답에 클릭재킹 및 MIME 스니핑 방지 보안 헤더 누락.** WAF Priority 0 규칙 `BlockUnauthorizedStaffAccess`의 `CustomResponse`에 `Cache-Control: no-store`만 설정되어 있다. WAF 엣지에서 생성되는 403 응답은 내부 Web Nginx를 거치지 않으므로 Nginx의 보안 헤더(`X-Frame-Options`, `X-Content-Type-Options`)가 적용되지 않는다. 비인가 접근 차단 화면이 타 사이트의 iframe 등에 삽입되거나 악용되지 않도록 WAF `CustomResponse.ResponseHeaders`에 `X-Frame-Options: DENY` 및 `X-Content-Type-Options: nosniff`를 추가할 것을 권고한다.

### Low
- [x] (4237983) `docker/was/server.xml:6` — **Tomcat 컨테이너 불필요한 TCP 종료 포트(8005) 활성화.** 컨테이너 및 쿠버네티스 환경에서는 프로세스 수명주기를 SIGTERM/SIGKILL 신호로 제어하므로 로컬 TCP 8005 포트 리스너가 불필요하다. 로컬 루프백(`127.0.0.1:8005`)에 기본 종료 문자열 `"SHUTDOWN"`이 수신 대기 상태로 남아 있으면, 동일 Pod 네트워크 네임스페이스 내 사이드카나 프로세스를 통한 의도치 않은 WAS 종료 리스크가 존재한다. `<Server port="-1" shutdown="SHUTDOWN">`으로 설정하여 TCP 종료 포트를 비활성화하는 CIS Tomcat 하드닝 권고를 적용할 것을 제안한다.
- [x] (4237983) `docker/was/server.xml:33` — **운영 환경 Tomcat `autoDeploy="true"` 활성화.** `readOnlyRootFilesystem: true`로 구동되는 불변 컨테이너 환경에서 런타임 디렉터리 동적 스캔 및 자동 배포(`autoDeploy="true"`)는 불필요한 파일시스템 감시 오버헤드를 발생시키고 잠재적인 불안정성을 야기할 수 있다. 프로덕션 환경에 맞게 `autoDeploy="false"` 및 `deployOnStartup="true"`로 명시적 고정을 권고한다.
- [x] (4237983) `infra/aws/provision-aws-resources.sh:527` — **WAF IPSet 설명 문구 리소스 범위 불일치.** `provision-aws-resources.sh`의 `create-ip-set` 실행 시 `--description "Allowed source IPs for /grafana"`로 작성되어 있으나, 현재 해당 IPSet은 `/grafana`와 `/was` 공용 직원 인가 IP 대역으로 기능이 확장되었다. 운영상 혼선을 방지하기 위해 `--description "Allowed source IPs for /grafana and /was staff access"`로 갱신을 제안한다.

---

### 총평
병원 공개 랜딩 페이지 도입 및 직원용 PetClinic WAS(`/was/`) 격리 아키텍처는 AWS WAFv2 최우선순위(Priority 0) 차단 규칙, 403 사용자 지정 응답, Tomcat `RemoteIpValve`와 Nginx 역방향 프록시 헤더 제어를 통해 전반적으로 우수한 다층 방어 체계를 갖추고 있다. 또한 민감 자격증명의 하드코딩이나 과다한 권한 부여는 발견되지 않았다.  
그러나 **(1) 설계 문서 내 실제 서비스 도메인 실값 노출** 및 **(2) 재배포 시 메인 페이지(`/`) 일시 중단을 유발하는 `deploy-all.sh`의 배포 순서 역전 결함**이 존재하므로, 해당 High 항목들에 대한 보완 조치가 완료되기 전까지는 프로덕션 배포가 불가하다.

배포 가능 여부: No

## Security Round 2 — 2026-10-27 (대상 커밋: ca90d5e)

점검 범위: `git diff master...HEAD` 전체 및 R1 피드백 반영 커밋(`4237983`, `08ae5c8`, `ca90d5e`), `docs/architecture.md`, `docs/features/landing-page/design.md`.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env`는 `.gitignore`로 제외되어 안전하게 관리되며, 하드코딩된 API Key, DB 패스워드, AWS 자격증명 없음. RDS 패스워드는 K8s Secret `petclinic-rds-secret`의 `secretKeyRef` 참조 유지).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 양호 (`docs/features/landing-page/design.md:12`의 실제 서비스 도메인 실값은 `${DOMAIN_NAME}` 플레이스홀더로 교체 완료됨. 정적 랜딩 페이지 `docker/web/static/index.html` 내 이메일 주소는 실제 서비스 도메인에서 내려가는 공식 데모 연락처 용도로 유지하기로 사용자 결정이 내려져 `docs/daily`에 승인 이력 기록됨. 12자리 AWS 계정 ID, 실존 IAM/WAF ARN, 개인 엔드포인트 노출 없음).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (신규 IAM 역할이나 과다 권한 생성 없음. WAF IPSet 및 NGF 라우팅을 통해 인가된 IP만 내부 직원용 애플리케이션에 도달하도록 통제함).
- **네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)**: 양호 (WAF Priority 0 `BlockUnauthorizedStaffAccess` 차단 규칙 유지, WAF 엣지 403 응답에 `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Cache-Control: no-store` 보안 헤더 추가 완료됨. Tomcat 컨테이너의 불필요한 TCP 종료 포트(8005)를 `port="-1"`로 비활성화하여 루프백 포트 노출을 제거함).
- **입력 검증 누락 (인젝션, 경로 조작, SSRF)**: 보완 필요 (WAF 텍스트 변환 검증 로직에 `URL_DECODE` -> `NORMALIZE_PATH` -> `LOWERCASE` 순서 및 타입 검증이 추가되었으나, `scripts/lib.sh`의 게이트 검사에서 `min_by(.Priority)`만 사용하고 `.Priority == 0` 조건을 명시 검증하지 않아 최우선 순위가 아닌 규칙도 통과할 수 있는 보안 검증 결함이 존재함).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (Tomcat `11.0.2-jdk21-temurin-noble`, Maven `3.9.9-eclipse-temurin-21`, Nginx `1.27.2-alpine`, JMX Exporter `1.0.1` SHA256 체크섬 등 고정 태그 및 불변 이미지 사양 준수).
- **Dockerfile/IaC (root 실행, latest 태그, 암호화 미설정)**: 양호 (Web 및 WAS 컨테이너 모두 UID 10001 비루트 전용 계정으로 구동되며, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false` 보안 컨텍스트 강제 적용됨. WAS `server.xml`에 `autoDeploy="false"`, `deployOnStartup="true"` 설정 적용 완료).
- **design.md 의 보안 요구사항 및 architecture.md 의 보안 구조 준수 여부**: 보완 필요 (긴급 롤백 시 이전 버전 WAS의 컨텍스트 경로(`/`)와 Deployment 매니페스트 상의 신규 프로브 경로(`/was/`) 불일치로 인한 복구 불능 장애 위험 존재, `deploy-all.sh`에서 카나리 사전 검증 게이트를 거치기 전에 stable 트랙이 프로덕션에 먼저 롤아웃되어 카나리 격리 안전망이 무력화되는 결함 존재).

---

### Critical
지적 사항 없음.

### High
- [x] (1f0c2b6 두 단계 릴리스 1차: 새 이미지도 `/` 처리, probe `/` 유지 → 이미지만 되돌려도 Ready. 롤백 순서 web → WAS, design.md Q7) `docs/features/landing-page/design.md:593` — **WAS 긴급 롤백 시 K8s 헬스체크 프로브(`/was/`) 불일치로 인한 복구 불능 장애 위험.** `design.md` §7.3의 긴급 롤백 절차는 `kubectl -n petclinic set image deployment/was-stable tomcat=...:${PREVIOUS_TAG}`로 이미지만 변경하도록 안내하고 있다. 그러나 `k8s/was/deployment-stable.yaml`의 `startupProbe`와 `readinessProbe`가 `path: /was/`로 수정되었으므로, 애플리케이션이 `ROOT`(`/`) 컨텍스트에 배포되어 있던 이전 버전 이미지를 기동하면 프로브 요청이 HTTP 404를 수신하여 지속적으로 실패한다. 이로 인해 롤백 Pod가 Ready 상태로 전이되지 못하고 `CrashLoopBackOff` 및 무한 재시작에 빠져 서비스 복구가 불가능해진다. 이미지 태그만 변경하는 것이 아니라 Deployment 매니페스트(프로브 경로)를 함께 롤백하거나 복원하는 절차를 `design.md`에 명시하고, web과 was-stable 간의 롤백 순서 및 복구 검증 절차를 보완해야 한다.
- [x] (1f0c2b6 카나리 기간 stable은 STABLE_IMAGE_TAG(예전 이미지) 그대로 — 새 이미지는 canary 트랙에만, 검증 후 승격. 1차 이미지는 공용 매니페스트와 호환, design.md Q7) `scripts/deploy-all.sh:155-163` — **카나리 사전 검증 완료 전 stable 프로덕션 노출 및 트랙 격리 원칙 위반.** `deploy-all.sh`는 `render_all "$K/web"` 및 `render_all "$K/was"`를 차례로 실행하여 `web-canary`뿐 아니라 `web`(stable)과 `was-stable`까지 신규 버전으로 롤아웃을 완료한 뒤 184행의 카나리 경로 검증(`X-Canary: always`)을 수행한다. 이로 인해 신규 이미지에 잠재적 결함이 있더라도 카나리 검증 게이트를 거치기 전에 이미 100%의 stable 사용자에게 신규 버전이 배포된다. 카나리 트랙(`web-canary`, `was-canary`)을 먼저 배포하여 사전 검증 게이트를 통과한 후에 stable 트랙을 순차 배포하도록 트랙 간 배포 단계를 분리해야 한다.

### Medium
- [x] (1f0c2b6) `scripts/lib.sh:64` — **배포 전 WAF 보안 게이트(`staff_waf_ready`)의 `Priority == 0` 명시 검증 누락.** `staff_waf_ready` 내 jq 조건은 `min_by(.Priority) | .Name == "BlockUnauthorizedStaffAccess"`를 검사하지만, 해당 규칙의 `.Priority`가 실제로 `0`인지는 검사하지 않는다. 만약 규칙이 Priority 1 이상으로 잘못 설정되어 단독 존재하거나 다른 최우선순위 허용 규칙이 0번으로 추가되는 구성 오류가 발생하더라도 최소 우선순위 규칙이라는 이유로 게이트를 통과할 수 있다. AWS WAF 최우선 차단 원칙을 보장하기 위해 `.Priority == 0` 조건을 명시하고 회귀 테스트(`grafana-waf-ready.test.sh`)에 우선순위 0 미만/초과 검증 케이스를 보완해야 한다.

### Low
지적 사항 없음.

---

### 총평
Round 1에서 지적되었던 설계 문서 내 실제 도메인 노출 제거, WAF 엣지 403 보안 헤더(`X-Frame-Options`, `X-Content-Type-Options`) 추가, Tomcat 불필요 종료 포트 비활성화(`port="-1"`) 및 `autoDeploy="false"` 적용, WAF 텍스트 변환 파이프라인 검증 강화는 모두 정상 반영되었다.
그러나 긴급 롤백 시 probe 경로 불일치로 인한 복구 불능 위험, 카나리 사전 검증 전 stable 선적용 문제, WAF 배포 게이트의 Priority 0 검증 누락이 확인되었으므로 보완 조치가 완료되기 전까지 배포는 불가하다.

배포 가능 여부: No

## Security Round 3 — 2026-10-27 (대상 커밋: 6e247a2)

점검 범위: `git diff master...HEAD` 전체 및 R2 피드백 반영 커밋(`1f0c2b6`, `9b577a6`, `6e247a2`), `docs/architecture.md`, `docs/features/landing-page/design.md`.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env` 파일은 `.gitignore`에 등록되어 커밋에서 제외되었으며, API 키, DB 패스워드, AWS 자격증명 하드코딩 없음. RDS 인증정보는 K8s Secret `petclinic-rds-secret`의 `secretKeyRef` 참조 방식 유지).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 양호 (`docs/features/landing-page/design.md`의 `${DOMAIN_NAME}` 플레이스홀더 사용 준수, `docs/daily/2026-10-27.md` 내 12자리 AWS 계정 ID, 실존 ARN, 개인 엔드포인트 노출 없음. 랜딩 페이지 정적 HTML 내 이메일 주소는 공식 데모 연락처 용도로 사용자 승인 하에 유지).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (신규 IAM 역할 및 과다 권한 생성 없음. WAF IPSet 및 NGF 라우팅을 통한 최소 권한 접근 제어 준수).
- **네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)**: 양호 (AWS WAF Priority 0 `BlockUnauthorizedStaffAccess` 규칙을 통한 비인가 IP 엣지 차단, WAF 403 커스텀 응답 헤더(`X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Cache-Control: no-store`) 적용 완료, Tomcat 포트 8005 비활성화(`port="-1"`), Nginx 보안 헤더 준수).
- **입력 검증 누락 (인젝션, 경로 조작, SSRF)**: 양호 (WAF 경로 일치 규칙의 `URL_DECODE` -> `NORMALIZE_PATH` -> `LOWERCASE` 변환 파이프라인 검증 통과. `scripts/lib.sh`의 배포 게이트 `staff_waf_ready`에 `.Priority == 0` 명시 검증 반영 및 단위 테스트 18건 전건 통과).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (Tomcat `11.0.2-jdk21-temurin-noble`, Maven `3.9.9-eclipse-temurin-21`, Nginx `1.27.2-alpine`, JMX Exporter `1.0.1` SHA256 체크섬 등 불변 태그 고정 준수).
- **Dockerfile/IaC (root 실행, latest 태그, 암호화 미설정)**: 양호 (UID 10001 비루트 계정, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]` 보안 컨텍스트 강제 적용됨. WAS `server.xml`에 `autoDeploy="false"`, `deployOnStartup="true"` 설정 유지).
- **design.md 의 보안 요구사항 및 architecture.md 의 보안 구조 준수 여부**: 양호 (1차 릴리스 호환을 위한 Tomcat `RewriteValve` 도입으로 구버전/신버전 이미지 간 프로브(`/`) 및 트래픽 상호 호환성 확보 완료. `deploy-all.sh`에서 WAS를 web보다 먼저 배포하고 100:0 가중치 격리 상태에서 카나리 E2E 검증 통과 후 트래픽을 개방하도록 구성됨).

---

### Critical
지적 사항 없음.

### High
지적 사항 없음.

### Medium
- [x] (design.md Q8: web 대기 후 WAS, 롤백 후 노출과 별도 차단 조치 명시) `docs/features/landing-page/design.md:593` — **긴급 롤백 절차 내 롤아웃 대기 누락 및 레거시 복원 시 보안 주의사항 명시 필요.**
  1. `design.md` §7.3의 긴급 롤백 절차에서 `kubectl -n petclinic set image deployment/web ...` 실행 후 `kubectl -n petclinic rollout status deployment/web --timeout=300s` 대기 단계가 누락되어 있다. 두 `set image` 명령을 연속 실행할 경우 WAS가 web보다 먼저 구버전(`ROOT` 컨텍스트)으로 전환되어, 아직 새 버전을 실행 중인 web에서 유입되는 `/was/` 요청이 일시적으로 404를 반환할 수 있다. Q7 결정에 맞추어 web 롤아웃 완료를 대기한 후 WAS를 롤백하도록 절차를 보완해야 한다.
  2. 이전 안정 버전(`PREVIOUS_TAG`)으로 롤백 시, 구버전 web은 `/` 및 `/owners` 등 전체 경로를 WAS로 직접 프록시하지만 WAF는 `/was`와 `/grafana`만 차단한다. 따라서 레거시 버전으로 복구되면 PetClinic 관리 시스템이 대외에 다시 공개되는 보안 특성을 갖게 된다. 운영자가 비인가 접근 차단을 유지해야 하는 비상 상황인 경우, WAF 규칙 조정 또는 점검 화면 전환 등의 추가 조치가 필요함을 롤백 가이드에 명시할 것을 권고한다.

### Low
- [-] (⑦ 단계에서 Antigravity가 갱신) `docs/architecture.md:9` — **아키텍처 문서 동기화 필요 (Step ⑦ 수행 과제).**
  현재 `docs/architecture.md`는 기존 `BlockUnauthorizedGrafanaAccess` WAF 규칙과 WAS `ROOT` 컨텍스트(`/`) 구조를 기준으로 기술되어 있다. 신규 `BlockUnauthorizedStaffAccess` WAF 규칙, 정적 랜딩 페이지(`/`), 그리고 `/was/` 서블릿 컨텍스트 구조에 대한 개요 다이어그램 및 본문 동기화가 필요하며, 이는 머지 직전 ⑦ 단계(Antigravity 아키텍처 문서 갱신)에서 최종 반영되어야 한다.

---

### 총평
Round 2에서 지적되었던 긴급 롤백 시 probe 경로 불일치 문제, 카나리 사전 검증 전 프로덕션 노출 결함, WAF 배포 게이트의 Priority 0 검증 누락이 커밋 `1f0c2b6`을 통해 모두 안전하게 해결되었다.  
Tomcat `RewriteValve`를 통한 두 단계 릴리스(1차: `/` 프로브 호환 유지 및 내부 리라이트) 설계는 무중단 호환성과 보안 격리를 양립시켰으며, 시크릿 누출이나 권한 과다 부여 없이 프로덕션 배포 기준을 충족한다.  
다만 긴급 롤백 매뉴얼의 롤아웃 대기 순서 및 레거시 노출 주의사항 보완(Medium)이 권고된다.

배포 가능 여부: Yes

## Security Round 4 — 2026-10-27 (대상 커밋: 1ab9d9b)

점검 범위: `git diff master...HEAD` 전체 및 R3 피드백 반영 커밋(`78152ec`, `36d122f`, `1ab9d9b`), `docs/architecture.md`, `docs/features/landing-page/design.md`.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env` 파일은 `.gitignore`에 등록되어 커밋에서 안전하게 제외되며, 신규 커밋에 하드코딩된 API Key, DB 패스워드, AWS 자격증명 없음. DB 암호는 Kubernetes Secret `petclinic-rds-secret`의 `secretKeyRef` 참조 유지).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 양호 (`docs/daily/2026-10-27.md` 및 `docs/features/landing-page/design.md` 내 12자리 AWS 계정 ID, 실존 IAM/WAF ARN, 개인 엔드포인트 노출 없음. 랜딩 페이지 정적 HTML 내 이메일 주소는 공식 데모 연락처 용도로 사용자 승인 하에 유지. 본 문서 R1 기록 내 언급되었던 도메인 실값 역시 `${DOMAIN_NAME}` 플레이스홀더로 교체 완료).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (신규 IAM 역할이나 권한 변경 없음. WAF IPSet과 NGINX Gateway Fabric 라우팅을 통해 최소 권한 네트워크 접근 제어 유지).
- **네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)**: 보완 필요 (AWS WAF Priority 0 `BlockUnauthorizedStaffAccess` 차단 규칙 정상 동작 및 WAF 403 커스텀 응답 헤더 유지. 단, Nginx `location = /was`의 301 리다이렉트 시 `absolute_redirect` 기본값(`on`)에 의해 내부 포트 `8080` 및 `http://` 스킴 절대 경로로 리다이렉트되어 포트 노출 및 외부 접속 단절 리스크 존재).
- **입력 검증 누락 (인젝션, 경로 조작, SSRF)**: 이상 없음 (WAF 경로 일치 규칙의 `URL_DECODE` -> `NORMALIZE_PATH` -> `LOWERCASE` 3단계 텍스트 변환 파이프라인 유지 및 `staff_waf_ready` 배포 게이트에서 `.Priority == 0` 엄격 검증. 단위 및 정적 검증 전건 통과).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (Tomcat `11.0.2-jdk21-temurin-noble`, Maven `3.9.9-eclipse-temurin-21`, Nginx `1.27.2-alpine`, JMX Exporter `1.0.1` SHA256 불변 체크섬 등 특정 고정 태그 사용 및 `latest` 태그 미사용).
- **Dockerfile/IaC (root 실행, latest 태그, 암호화 미설정)**: 양호 (Web 및 WAS 컨테이너 모두 UID 10001 비루트 전용 계정 구동, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]` 보안 컨텍스트 강제 적용 유지. WAS `server.xml` `port="-1"` 및 `autoDeploy="false"` 설정 유지).
- **design.md 의 보안 요구사항 및 architecture.md 의 보안 구조 준수 여부**: 보완 필요 (`scripts/deploy-all.sh:40-47`에 `PROMOTE_STABLE=1` 승격 가드가 추가되어 검증되지 않은 stable 이미지 전환 위험은 해결되었으나, 긴급 롤백 시 엣지 WAF 보호 공백으로 인한 내부 직원용 앱 및 개인정보 대외 노출 문제가 설계 상 선택적 고려사항으로만 남아 있어 필수 보안 통제 절차로 구체화되어야 함).

---

### Critical
지적 사항 없음.

### High
- [x] (8c22f6d `STAFF_WAF_SCOPE=all` 를 web 롤백 전 필수 단계로, 403 확인 후 롤백. design.md Q9) `docs/features/landing-page/design.md:648` — **긴급 롤백 시 엣지 WAF 차단 공백에 따른 내부 시스템(PetClinic) 및 개인정보 대외 전면 노출 위험.** 이전 버전 web 이미지(`PREVIOUS_TAG`)로 롤백 시, 구버전 Nginx는 `/` 및 `/owners` 등 전체 경로를 WAS로 직접 프록시하지만 엣지 WAF는 `/was*`와 `/grafana*`만 차단하도록 구성되어 있다. 따라서 롤백 즉시 비인가 인터넷 사용자에게 고객·반려동물 진료 정보가 담긴 PetClinic 관리 시스템 전체가 무방비로 노출된다. 현재 `design.md` Q8에서는 이를 운영자의 선택 사항("비상 시 공개를 막아야 하면 별도 조치... 롤백과 함께 판단")으로 기술하고 있으나, 개인정보 유출 방지 및 보안 원칙에 따라 구버전 web 롤백 전 엣지 경로 차단(예: `/` 경로 IP 제한 규칙 활성화 또는 점검 페이지 전환)을 선행 적용하고 검증하도록 필수 절차로 명시해야 한다.

### Medium
- [x] (8c22f6d) `docker/web/nginx.conf:62` — **`/was` 정규화 리다이렉트 시 비암호화 HTTP 및 내부 컨테이너 포트(`:8080`) 노출 (프로토콜 다운그레이드 / 접속 장애).** `location = /was { return 301 /was/; }` 블록에 `absolute_redirect off;`가 설정되어 있지 않다. Nginx 기본값(`absolute_redirect on;`) 작동 시 Nginx 수신 포트(`8080`)와 내부 HTTP 스킴을 결합한 `Location: http://$host:8080/was/` 절대 URI가 생성된다. 외부 클라이언트는 HTTPS(443)로 접근했으나 비암호화 내부 포트(8080)로 리다이렉트되어 브라우저 연결이 차단되거나 프로토콜 다운그레이드가 발생하므로, `server` 블록 또는 해당 `location`에 `absolute_redirect off;`를 명시하여 상대 경로(`Location: /was/`)로 응답하도록 수정해야 한다.

### Low
- [-] (⑦ 단계에서 Antigravity가 갱신) `docs/architecture.md:9` — **아키텍처 문서 동기화 필요 (Step ⑦ 수행 과제).**
  신규 `BlockUnauthorizedStaffAccess` WAF 규칙, 정적 랜딩 페이지(`/`), 그리고 `/was/` 서블릿 컨텍스트 구조에 대한 개요 다이어그램 및 본문 동기화가 필요하며, 이는 머지 직전 ⑦ 단계(Antigravity 아키텍처 문서 갱신)에서 최종 반영되어야 한다.

---

### 총평
커밋 `78152ec`를 통해 `PROMOTE_STABLE=1` 승격 가드가 도입되어 카나리 사전 검증 전 stable 이미지가 무단 교체되는 결함이 안전하게 차단되었으며, `security.md` 내 도메인 실값 노출도 정상 정리되었다.  
그러나 **(1) 구버전 web 롤백 시 엣지 WAF 보호 공백으로 인한 내부 시스템 및 개인정보 대외 노출 위험**이 설계 문서 상 필수 통제 절차로 수립되지 않았고, **(2) Nginx `/was` 리다이렉트 시 내부 포트 8080 및 HTTP 다운그레이드 결함(`absolute_redirect`)**이 존재하므로, 해당 항목들에 대한 보완 조치가 완료되기 전까지 프로덕션 배포는 불가하다.

배포 가능 여부: No


## Security Round 5 — 2026-10-27 (대상 커밋: 40b9f2a)

점검 범위: `git diff master...HEAD` 전체 및 R4 피드백 반영 커밋(`8c22f6d`, `b895549`, `40b9f2a`), `docs/architecture.md`, `docs/features/landing-page/design.md`.

### 점검 항목별 요약
- **시크릿/자격증명 하드코딩 및 `.env` 커밋 여부**: 이상 없음 (`.env` 파일은 `.gitignore`에 등록되어 커밋에서 안전하게 제외되며, 하드코딩된 API Key, DB 패스워드, AWS 자격증명 없음. DB 암호는 Kubernetes Secret `petclinic-rds-secret`의 `secretKeyRef` 참조 방식 유지).
- **문서(`docs/daily` 포함) 내 계정 ID·ARN·엔드포인트·개인 URL 실값 노출 여부**: 양호 (`docs/features/landing-page/security.md`, `design.md`, `docs/daily/2026-10-27.md` 전반에 걸쳐 12자리 AWS 계정 ID, 실존 IAM/WAF ARN, 개인 엔드포인트 실값 노출 없음. R4에서 지적된 보안 점검 문서 내 도메인 실값도 `${DOMAIN_NAME}` 플레이스홀더로 교체 완료됨. 정적 랜딩 페이지 내 이메일은 공식 데모 연락처 용도로 사용자 승인 하에 유지).
- **IAM/권한 과다 부여, 최소 권한 원칙 위반**: 이상 없음 (신규 IAM 역할이나 과다 권한 생성 없음. WAF IPSet 및 NGINX Gateway Fabric 라우팅을 통한 최소 권한 네트워크 접근 제어 유지).
- **네트워크 노출 (열린 포트, 0.0.0.0/0, 공개 버킷)**: 양호 (Nginx `absolute_redirect off;` 적용으로 `/was` 리다이렉트 시 비암호화 내부 포트 8080 및 HTTP 다운그레이드 결함 해결 완료. WAF Priority 0 `BlockUnauthorizedStaffAccess` 차단 규칙 및 403 보안 응답 헤더(`Cache-Control: no-store`, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`) 유지, WAS 포트 8005 비활성화 유지).
- **입력 검증 누락 (인젝션, 경로 조작, SSRF)**: 이상 없음 (WAF 경로 일치 규칙의 `URL_DECODE` -> `NORMALIZE_PATH` -> `LOWERCASE` 3단계 텍스트 변환 파이프라인 유지 및 `STAFF_WAF_SCOPE=all` 경로 매칭에도 동일 변환 파이프라인 적용됨. 단위 테스트 전건 통과).
- **의존성 취약점 및 고정되지 않은 버전**: 이상 없음 (Tomcat `11.0.2-jdk21-temurin-noble`, Maven `3.9.9-eclipse-temurin-21`, Nginx `1.27.2-alpine`, JMX Exporter `1.0.1` SHA256 체크섬 등 불변 고정 태그 준수 및 `latest` 태그 미사용).
- **Dockerfile/IaC (root 실행, latest 태그, 암호화 미설정)**: 양호 (UID 10001 비루트 전용 계정 구동, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]` 보안 컨텍스트 강제 적용 유지. WAS `server.xml` `port="-1"` 및 `autoDeploy="false"` 유지).
- **design.md 의 보안 요구사항 및 architecture.md 의 보안 구조 준수 여부**: 보완 필요 (R4 피드백에 따라 `STAFF_WAF_SCOPE=all`을 통한 롤백 전 사이트 전체 차단 절차가 `design.md` Q9에 반영되었으나, 롤백 후 수정 버전 재배포 시 새 web 롤아웃 전에 전체 차단을 선해제하도록 절차가 기술되어 있고 `staff_waf_ready` 게이트가 전체 차단 상태를 거부하여, 재배포 도중 구버전 web이 내부 앱 및 개인정보를 외부에 무방비로 노출하는 심각한 보안 공백 발생).

---

### Critical
지적 사항 없음.

### High
- [x] (6b2a31e `staff_waf_ready` 가 `all` 범위도 통과, 재배포는 전체 차단 유지 → 새 web 확인 → 직원 범위로 축소. design.md Q10) `docs/features/landing-page/design.md:661` — **롤백 후 재배포 과정에서 WAF 사이트 전체 차단 조기 해제 및 배포 게이트 거부로 인한 내부 시스템(PetClinic) 및 개인정보 대외 노출 위험.**
  `design.md:661`에서는 롤백 후 수정 이미지를 재배포할 때 `STAFF_WAF_SCOPE` 없이 `grafana-waf`를 다시 실행해 전체 차단을 먼저 풀도록 기술하고 있다. 그러나 롤백된 상태의 클러스터는 `/` 및 `/owners` 등 전체 경로를 WAS로 프록시하는 구버전 web을 실행 중이므로, 새 web이 완전히 롤아웃되기 전에 WAF를 `/grafana`·`/was` 차단 범위(`STAFF_WAF_SCOPE=staff`)로 환원하면 재배포 및 검증이 진행되는 수 분 동안 비인가 인터넷 사용자에게 내부 직원용 PetClinic 시스템 및 고객/반려동물 진료 정보가 전면 공개되는 심각한 보안 노출 공백이 발생한다.
  또한 `scripts/lib.sh:67-69`의 배포 게이트 `staff_waf_ready`가 `STAFF_WAF_SCOPE=all` 상태(전체 차단)를 허용하지 않고 차단(blocked)하도록 구현되어 있어, 운영자가 취약한 조기 해제를 수행하지 않고는 `deploy-all.sh`를 실행할 수 없도록 강제하고 있다.
  따라서 (1) `scripts/lib.sh`의 `staff_waf_ready`가 정상 범위(`staff`)뿐 아니라 사이트 전체 차단 범위(`all`) 상태에서도 유효한 보안 배포 상태로 통과할 수 있도록 검증 조건을 보완하고, (2) `design.md` Q9의 재배포 절차를 "전체 차단(`STAFF_WAF_SCOPE=all`) 상태를 유지한 채 새 web 및 WAS 롤아웃·사전 검증을 완료한 후, 안전하게 WAF를 직원 범위(`STAFF_WAF_SCOPE=staff`)로 축소"하도록 순서를 정정해야 한다.

### Medium
지적 사항 없음.

### Low
- [-] (⑦ 단계에서 Antigravity가 갱신) `docs/architecture.md:9` — **아키텍처 문서 동기화 필요 (Step ⑦ 수행 과제).**
  신규 `BlockUnauthorizedStaffAccess` WAF 규칙, 정적 랜딩 페이지(`/`), 그리고 `/was/` 서블릿 컨텍스트 구조에 대한 개요 다이어그램 및 본문 동기화가 필요하며, 이는 머지 직전 ⑦ 단계(Antigravity 아키텍처 문서 갱신)에서 최종 반영되어야 한다.

---

### 총평
Round 4에서 지적되었던 Nginx `/was` 리다이렉트 시 비암호화 내부 포트(:8080) 노출 결함(`absolute_redirect off;`)과 `security.md` 내 도메인 실값 노출은 완벽하게 수정되었다.  
그러나 **롤백 후 수정 버전 재배포 시 엣지 WAF 사이트 전체 차단을 새 web 배포 완료 전에 미리 해제하도록 절차가 수립되어 있고 배포 게이트(`staff_waf_ready`) 역시 전체 차단 상태를 거부함으로써, 재배포 진행 구간 동안 구버전 web을 통해 내부 PetClinic 관리 시스템 및 개인정보가 외부 인터넷에 무방비로 노출되는 중대한 보안 통제 공백**이 존재하므로, 해당 High 항목에 대한 보완 조치가 완료되기 전까지 프로덕션 배포는 불가하다.

배포 가능 여부: No
