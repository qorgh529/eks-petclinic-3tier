## Review Round 1 — 2026-10-27 (대상 커밋: 17a2618)

### Critical
- 지적 사항 없음.

### High
- [x] (4237983) `docs/features/landing-page/design.md:12` — 실제 서비스 도메인이 공개 저장소에 기록되어 있다. `${DOMAIN_NAME}` 같은 플레이스홀더로 바꾸고 변경된 문서 전반에서 실값 노출을 제거한다.
- [x] (4237983) `scripts/deploy-all.sh:154` — 기존 환경 재배포 시 WAS Deployment를 web보다 먼저 적용하고 두 롤아웃을 동시에 진행한다. 새 WAS가 먼저 준비되면 기존 web의 `/` 요청이 `/was`만 존재하는 Tomcat으로 전달되어 404가 발생한다. 사용자 승인된 순서대로 stable web 롤아웃 완료를 기다린 뒤 stable WAS를 적용하고, 이 순서를 검증하는 테스트를 추가한다.

### Medium / Low
- [x] (4237983) `scripts/lib.sh:62` — 배포 전 WAF 게이트는 변환의 종류만 확인하여 `LOWERCASE` 누락이나 변환 우선순위가 뒤바뀐 규칙도 통과시킨다. 설계의 세 변환과 순서를 정확히 검증하고 해당 실패 사례를 오프라인 테스트에 추가한다.

### 기존 아키텍처와의 차이
- [-] (⑦ 단계에서 Antigravity가 architecture.md 를 갱신, 구현 단계 범위 밖) `docker/was/Dockerfile:32` — WAS 컨텍스트가 기존 아키텍처의 `webapps/ROOT` 및 `/` 대시보드에서 `webapps/was`와 `/was/`로 변경되며, web 루트도 정적 페이지가 된다. 설계에서 의도한 변경이므로 머지 전 아키텍처 문서의 WAS·요청 흐름과 WAF 규칙 설명을 실제 구현에 맞게 갱신한다.

### 총평
공개 도메인 실값과 배포 순서 문제를 해결해야 한다. WAF 게이트 검증과 아키텍처 문서도 보완이 필요하다.

머지 가능 여부: No

## Review Round 2 — 2026-10-27 (대상 커밋: ca90d5e)

### Critical
- 지적 사항 없음.

### High
- [x] (1f0c2b6 두 단계 릴리스 1차: 새 이미지도 `/` 처리, probe `/` 유지 → 이미지만 되돌려도 Ready. 절차는 design.md Q7) `docs/features/landing-page/design.md:593` — 롤백 명령은 이미지만 이전 버전으로 바꾸지만 Deployment의 startup/readiness probe는 `/was/`로 남는다. 이전 WAS는 ROOT 컨텍스트만 제공하므로 새 롤백 Pod가 준비 상태가 되지 못해 복구가 멈춘다. 이전 Deployment 전체를 복원하는 절차와 순서를 명시하고 실제 롤백을 검증한다.
- [x] (1f0c2b6 카나리 기간 stable은 STABLE_IMAGE_TAG(예전 이미지) 그대로이고, 1차 이미지는 예전·새 web 모두와 호환. stable 적용은 WAS 먼저 → web, design.md Q7) `scripts/deploy-all.sh:155` — stable과 canary web을 함께 적용한 뒤 stable과 canary WAS를 함께 적용하므로, 설계의 카나리 사전 검증 전에 stable이 이미 신규 버전으로 전환된다. 신규 버전의 오류가 카나리 검사에서 발견되어도 stable 사용자에게 노출되고, web 롤아웃 후 기존 WAS를 향하는 `/was/` 요청은 WAS 전환이 끝날 때까지 404가 된다. 트랙을 분리해 카나리 검증 후 stable을 전환하고 버전 혼재 구간의 호환성도 확보한다.
- [x] (1f0c2b6) `scripts/lib.sh:64` — 게이트는 직원 차단 규칙이 존재하는 규칙 중 최저 우선순위인지만 확인하고 Priority 0인지 확인하지 않는다. 예를 들어 우선순위 1인 규칙만 있을 때 검증에 통과하므로 이후 우선순위 0에 Allow 규칙이 추가되면 보호 경로가 우회될 수 있다. 명시적으로 `.Priority == 0`을 검사하고 회귀 사례를 추가한다.

### Medium / Low
- 지적 사항 없음.

### 기존 아키텍처와의 차이
- [-] (⑦ 단계에서 Antigravity가 architecture.md 를 갱신, 구현 단계 범위 밖) `docker/was/Dockerfile:32` — WAS 컨텍스트가 기존 아키텍처의 `webapps/ROOT`에서 `webapps/was`로 변경되고 web 루트가 정적 페이지로 바뀐다. 의도된 변경이므로 머지 전 아키텍처 문서의 WAS·요청 흐름과 WAF 규칙 설명을 실제 구현에 맞게 갱신한다.

### 총평
이전 라운드의 도메인 제거, web 우선 적용 및 WAF 변환 순서 검증은 확인했다. 롤백 복구와 카나리 격리, WAF 우선순위 게이트를 보완해야 한다.

머지 가능 여부: No

## Review Round 3 — 2026-10-27 (대상 커밋: 9b577a6)

### Critical
- 지적 사항 없음.

### High
- [x] (78152ec 실행 중인 stable과 다른 STABLE_IMAGE_TAG 는 PROMOTE_STABLE=1 없이는 워크로드 변경 전에 중단) `scripts/deploy-all.sh:156` — 공용 매니페스트를 적용하면 `STABLE_IMAGE_TAG`가 기존 태그와 다른 경우 카나리 검사 전에 stable WAS와 web도 새 이미지로 전환된다. 100:0은 stable 트래픽을 그대로 전달하므로 검증 실패 시에도 신규 버전이 사용자에게 노출된다. 카나리만 먼저 적용하고 검증에 성공한 뒤 stable을 전환하거나, 별도의 승격 절차와 기존 stable 태그 유지 검증을 추가한다. 이전 라운드에서 처리된 항목이 일반적인 태그 변경 재배포에서는 여전히 재현된다.
- [x] (design.md Q8: 롤백 후 직원 앱이 이 기능 이전처럼 `/` 에 공개되는 점과 필요 시 별도 차단 조치를 롤백 절차에 명시) `docs/features/landing-page/design.md:593` — 롤백에서 이전 web을 먼저 복원하면 이전 web이 `/owners` 등 루트 경로를 WAS로 프록시하지만 WAF는 `/was`와 `/grafana`만 차단한다. 따라서 롤백 중과 완료 후 비인가 사용자도 직원 화면에 접근할 수 있다. 이전 경로를 보호하는 엣지 규칙을 먼저 적용하고 검증하는 롤백 절차를 마련한다.

### Medium / Low
- [x] (design.md Q8: web rollout status 대기 후 WAS) `docs/features/landing-page/design.md:593` — 두 `set image` 명령 사이에 web 롤아웃 완료 대기가 없다. WAS가 먼저 이전 이미지로 교체되면 아직 새 web을 사용하는 요청의 `/was/`가 404가 된다. web 롤아웃 완료를 기다린 후 WAS를 되돌리고 혼합 버전 구간을 검증한다.

### 기존 아키텍처와의 차이
- [-] (⑦ 단계에서 Antigravity가 architecture.md 를 갱신, 구현 단계 범위 밖) `docs/architecture.md:9` — 기존 문서는 Grafana 전용 `BlockUnauthorizedGrafanaAccess`와 `grafana_waf_ready`를 기술하지만 구현은 `/was`를 포함한 `BlockUnauthorizedStaffAccess`와 `staff_waf_ready`로 교체한다. 또한 WAS ROOT 컨텍스트와 루트 대시보드 설명이 현재 정적 랜딩 및 `/was` 배치와 다르므로 머지 전 요청 흐름과 WAF 설명을 갱신한다.

### 총평
정적 매니페스트 검증과 WAF 오프라인 테스트는 통과했다. 카나리 격리와 안전한 롤백 절차를 보완하고 아키텍처 문서를 갱신해야 한다.

머지 가능 여부: No

## Review Round 4 — 2026-10-27 (대상 커밋: 1ab9d9b)

### Critical
- 지적 사항 없음.

### High
- [x] (8c22f6d `STAFF_WAF_SCOPE=all` 사이트 전체 차단을 web 롤백 전 필수 단계로, 확인 후 롤백. design.md Q9) `docs/features/landing-page/design.md:642` — R3에서 처리된 것으로 표시한 롤백 노출 문제가 여전히 남아 있다. 이전 web을 복원하면 `/owners` 등 직원 앱 경로가 공개되는데 WAF는 `/was`와 `/grafana`만 차단한다. 별도 차단을 선택 사항으로 남기지 말고 이전 경로를 보호하는 규칙을 먼저 적용·검증한 뒤 web을 롤백하는 절차를 마련한다.
- [x] (7450d8d 보안 점검 작성자(Antigravity)가 R4에서 실값 제거, 현재 기능 문서에 도메인 실값 없음) `docs/features/landing-page/security.md:9` — 공개 저장소의 보안 점검 기록에 실제 서비스 도메인이 남아 있다. 실값을 플레이스홀더로 바꾸고 같은 문서의 다른 언급도 제거한다. 정적 페이지의 연락처는 사용자 유지 결정이 기록되어 있으나 이 문서의 실값 노출은 별개로 정리해야 한다.

### Medium / Low
- [x] (8c22f6d) `docker/web/nginx.conf:62` — `/was`의 Nginx 리다이렉트는 기본 `absolute_redirect` 설정에서 내부 HTTP 스킴과 수신 포트로 절대 URL을 생성하므로 외부 HTTPS 사용자가 `http://...:8080/was/`로 이동해 접속에 실패할 수 있다. 상대 Location을 사용하거나 외부 HTTPS 주소를 명시하고 프록시 경유 `/was` 요청을 검증한다.

### 기존 아키텍처와의 차이
- [-] `docs/architecture.md:9` — 현재 문서는 Grafana 전용 WAF 규칙과 게이트, WAS ROOT 컨텍스트 및 루트 대시보드를 설명한다. 구현은 직원 공통 WAF 규칙과 `/was` 컨텍스트, 정적 랜딩 페이지로 바뀌므로 머지 전 아키텍처 갱신 단계에서 요청 흐름과 구성 요소를 맞춘다.

### 총평
정적 매니페스트 검증과 WAF 오프라인 테스트는 통과했으며 stable 태그 가드와 롤아웃 대기는 확인했다. 롤백 경로 보호와 공개 문서 실값을 해결해야 한다.

머지 가능 여부: No

## Review Round 5 — 2026-10-27 (대상 커밋: 40b9f2a)

### Critical
- 지적 사항 없음.

### High
- [x] (6b2a31e 게이트가 사이트 전체 차단도 통과, 차단 유지 상태로 재배포 후 직원 범위로 축소. design.md Q10) `docs/features/landing-page/design.md:661` — 롤백 후 재배포를 위해 전체 차단을 해제하면 이전 web이 아직 `/owners` 등 루트 경로를 직원 앱으로 프록시하는 동안 허용 IP 밖에도 앱이 공개된다. `scripts/deploy-all.sh:31`의 게이트가 전체 차단 상태를 거부하므로 새 web 롤아웃 전에 차단을 풀어야 하는 문제도 있다. 전체 차단을 유지한 채 새 WAS와 web을 배포·검증하고 그 후 직원 경로 범위로 축소할 수 있는 절차와 게이트를 마련하고, 재배포 중 외부 접근 차단을 검증한다.

### Medium / Low
- 지적 사항 없음.

### 기존 아키텍처와의 차이
- [-] (⑦ 단계에서 Antigravity가 architecture.md 를 갱신, 구현 단계 범위 밖) `docs/architecture.md:9` — 기존 문서는 Grafana 전용 WAF 규칙과 게이트, WAS ROOT 컨텍스트 및 루트 대시보드를 설명한다. 구현은 직원 공통 WAF 규칙과 `/was` 컨텍스트, 정적 랜딩 페이지로 바뀌므로 머지 전 아키텍처 갱신 단계에서 요청 흐름과 구성 요소를 맞춘다.

### 총평
이전 라운드의 롤백 전 차단, 문서 실값 제거 및 상대 리다이렉트 수정을 확인했고 매니페스트와 WAF 오프라인 테스트는 통과했다. 롤백 후 재배포 시 차단 유지 절차가 필요하다.

머지 가능 여부: No
