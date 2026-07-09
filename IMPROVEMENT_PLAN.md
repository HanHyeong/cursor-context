# cursor-context 개선 계획서

작성일: 2026-07-09 · 기준: 코드 리뷰(훅 6종, 스킬 3종, install.sh, settings.json, README) 결과

## 목표

버그성 이슈를 제거해 README의 보증(결정론적 게이트, 1회 차단, 검증된 동작)을 실제와 일치시키고,
테스트·CI로 신뢰 주장을 재현 가능하게 만들고, 배포·확장성을 한 단계 올린다.

## 단계 구성

| 단계 | 내용 | 성격 | 예상 규모 |
|------|------|------|-----------|
| Phase 1 | 버그 수정 5건 | 필수 | 각 수 줄~수십 줄 |
| Phase 2 | 테스트 + CI | 필수 (신뢰 기반) | 신규 파일 3~5개 |
| Phase 3 | 고도화 4건 | 선택 (우선순위순) | 항목별 상이 |

---

## Phase 1 — 버그 수정

### 1-1. evolve-gate 턴마다 반복 차단 수정

- **문제**: `stop_hook_active` 가드는 같은 턴 안에서만 유효. 진화를 건너뛴 세션(plan 모드,
  읽기 전용)에서는 신호가 소진되지 않아 이후 **모든 턴의 첫 Stop마다 exit 2 재발생**.
  README의 "임계값 교차당 최대 1회" 주장과 불일치.
- **해결**: 세션 단위 sentinel. 차단 시 `.cursor-context/.gate-fired-<session_id>` 생성,
  존재하면 통과. `session_id`는 훅 stdin JSON에서 추출(이미 python3로 파싱 중이므로 추가 비용 없음).
  sentinel 파일은 SessionStart 훅에서 정리(오래된 것 삭제).
- **변경 파일**: `.claude/hooks/evolve-gate.sh`, `.claude/hooks/session-context.sh`(정리 로직),
  README(동작 서술 갱신)
- **검증**: 임계 초과 상태에서 (a) 첫 Stop 차단 (b) 같은 세션 두 번째 턴 통과 (c) 새 세션에서 다시 1회 차단

### 1-2. install.sh 헤드리스 온보딩 allowedTools에 Skill 누락

- **문제**: `--allowedTools "Bash,Read,Grep,Glob,Write,Edit"`인데 프롬프트는 스킬 실행을 지시.
  스킬 호출이 Skill 도구를 거치는 버전에서 조용히 실패 → 폴백으로 빠짐.
- **해결**: allowedTools에 `Skill` 추가. 방어적으로 프롬프트에 "스킬 도구를 쓸 수 없으면
  .claude/skills/project-onboard/SKILL.md를 직접 읽고 절차를 따르라"를 덧붙여 이중화.
- **변경 파일**: `install.sh`
- **검증**: 수동 E2E — claude CLI + API 인증이 필요해 CI 자동화 불가.
  실제 설치를 돌려 문서 생성을 확인하고 결과를 PR에 기록한다.

### 1-3. 온보딩 진행 표시 + 이식 가능한 타임아웃

- **문제 (a)**: `>/dev/null 2>&1`로 1~3분간 출력이 없어 멈춘 것으로 오해 가능.
- **문제 (b)**: `timeout 600`은 `timeout` 명령이 있을 때만 적용되는데 **macOS에는
  기본적으로 없다** — macOS에서 온보딩이 무한 대기할 수 있다.
- **해결**: claude를 백그라운드로 실행하고 부모 셸에서 10초 간격 경과 표시 +
  600초 초과 시 `kill`하는 이식 가능한 타임아웃 루프로 교체 (coreutils 불필요,
  진행 표시와 타임아웃을 한 루프로 해결).
- **변경 파일**: `install.sh`
- **검증**: 수동 — 정상 완료 / 강제 지연(가짜 claude 스크립트) 시 타임아웃·킬 동작 확인

### 1-4. metrics-collector 오버헤드 절감

- **문제**: 도구 호출마다 회전 검사로 파일 전체 읽기 + 병렬 호출 시 append 경합(이론상).
- **해결**:
  - 회전 검사를 확률적으로 실행 — 회전 로직이 python 안에 있으므로 python
    `random.random() < 0.01` 게이트 사용 (또는 회전 전체를 SessionStart로 이동)
  - append는 O_APPEND 단일 write(한 줄)라 POSIX에서 실질적으로 원자적 — 주석으로 한계 명시만
- **변경 파일**: `.claude/hooks/metrics-collector.sh`
- **검증**: 2,000줄 초과 파일로 회전 동작 확인, 호출당 시간 측정치 README 갱신

### 1-5. 소소한 정확성 수정 (묶음)

- git status 20줄 잘림 시 "(…N건 생략)" 표시 — `session-context.sh`
- 20커밋 백스톱에 `--no-merges` 적용해 머지 커밋 과다 트리거 방지 — `session-context.sh`
- 벤치마크의 `yarn X`(run 생략형) 패턴 검출 추가 — `context-benchmark.sh`.
  **주의**: `install`, `add`, `remove`, `upgrade`, `dlx`, `create` 등 yarn 내장 명령을
  제외 목록으로 걸러야 함 — 안 그러면 문서의 `yarn install` 언급이 거짓 FAIL을 유발

---

## Phase 2 — 테스트 + CI

- **문제**: README가 "verified by tests"를 주장하지만 저장소에 테스트가 없음.
  신뢰성을 파는 프로젝트에서 가장 큰 공백.
- **구성**:
  1. `tests/` 디렉터리에 **bats** 테스트 스위트:
     - `fingerprint.bats` — 지문 생성·비교: 매니페스트 수정/롤백/스크래치 파일 추가(불변)/CRLF 마커
     - `install.bats` — 임시 디렉터리에 설치: 멱등성(재실행 무변경), 기존 settings.json 병합·백업,
       python3 부재 폴백, 타입 불일치 백업
     - `hooks.bats` — session-context 스냅샷 출력 구조, prompt-freshness 무변경 시 무출력,
       evolve-gate 임계·sentinel 동작(1-1 검증 포함), metrics-collector 기록·회전
     - `benchmark.bats` — 줄 수 판정, 존재하지 않는 npm 스크립트/make 타깃 FAIL, 경로 WARN
  2. `.github/workflows/ci.yml` — ubuntu + macos 매트릭스에서 shellcheck 전체 + bats 실행
     (macos 포함 이유: `shasum` 폴백 경로와 BSD 계열 도구 차이를 실기기로 검증)
  3. README의 검증 관련 서술을 CI 배지·테스트 경로로 교체
  4. **수동 테스트 체크리스트** `tests/MANUAL.md` — CI 불가 항목 명시:
     헤드리스 온보딩 E2E(1-2, API 필요), 실제 Claude Code 세션에서의 훅 주입 확인
- **참고**: 1-1의 sentinel 동작 등 Phase 1 수정 사항은 이 스위트에 테스트로 고정된다
- **변경 파일**: `tests/*.bats`(신규), `.github/workflows/ci.yml`(신규), `README.md`, `README.ko.md`
- **완료 기준**: CI 그린, shellcheck 경고 0(불가피한 것은 directive로 명시)

---

## Phase 3 — 고도화 (우선순위순)

### 3-1. Claude Code 플러그인 패키징

- **가치**: install.sh의 파일 복사·settings.json 병합(python3 의존 포함)이 통째로 사라지고
  설치·업데이트·제거가 표준화됨. 구조적으로 가장 큰 업그레이드.
- **작업**: `plugin.json` 매니페스트 작성, hooks/skills를 플러그인 규격 배치로 이동,
  마켓플레이스 등록 검토. **주의**: 플러그인 훅의 `$CLAUDE_PROJECT_DIR` 시맨틱과
  `.cursor-context/` 데이터 경로가 동일하게 동작하는지 최신 플러그인 문서로 먼저 확인.
- **호환**: 기존 install.sh 방식은 1~2 릴리스 동안 병행 유지 후 deprecation.

### 3-2. 임계값·언어 설정화

- **작업**: `.cursor-context/config`(KEY=VALUE, 없으면 기본값) 도입 —
  `FEEDBACK_THRESHOLD=5`, `METRICS_THRESHOLD=300`, `COMMIT_BACKSTOP=20`,
  `DOC_LINE_BUDGET=200`, `LANG=ko|en`.
- **언어**: 주입 텍스트·설치 출력의 영어 버전 작성. 기본값은 `en`(README가 영어 우선이므로),
  install.sh가 시스템 로케일로 초기 추정. 문자열을 훅 상단 함수로 모아 이중화 비용 최소화.
- **변경 파일**: 훅 전체, 스킬 3종(지시문 언어), install.sh

### 3-3. install.sh --uninstall

- **작업**: 훅·스킬 파일 제거 + settings.json에서 등록 항목만 python3로 제거(원본 백업)
  + `.cursor-context/` 삭제 여부는 물어보고 결정. README 수동 절차를 이것으로 교체.

### 3-4. 모노레포 지원

- **문제**: 지문·문서가 저장소 루트 단일 기준 — 대형 모노레포에서 200줄 예산 부족.
- **설계 방향**: 루트 문서 + 패키지별 `<pkg>/.cursor-context/project-context.md`.
  세션 훅은 루트 문서를 항상 주입하고, 최근 커밋·브랜치 diff가 집중된 패키지의 문서를
  선택 주입. 지문 생성기는 패키지 경로 스코프 인자를 받도록 확장.
- **비고**: 설계 검토 후 별도 계획으로 분리 권장 (본 계획서 범위에서는 착수하지 않음).

---

## 리스크 및 원칙

- **게이트·측정 계층 불가침 유지**: `context-benchmark.sh`, `metrics-collector.sh` 수정은
  Phase 1-4처럼 성능·정확성 개선에 한정하고, 판정 기준 완화는 하지 않는다.
- **비파괴 원칙 유지**: 모든 설치 경로 변경은 기존 백업·멱등 동작을 깨지 않아야 하며
  Phase 2 테스트가 이를 회귀 방지한다.
- **호환성**: 1-1의 sentinel 등 `.cursor-context/` 신규 파일은 기존 설치본과 충돌 없음
  (없으면 기존 동작). 플러그인 전환(3-1)만 마이그레이션 공지 필요.
- **순서 의존**: Phase 2는 Phase 1 완료 후(수정된 동작을 테스트로 고정).
  Phase 3-2의 언어 분리는 3-1 이전에 하면 플러그인 전환 시 재작업이 없다.

## 진행 체크리스트

- [x] 1-1 evolve-gate sentinel — 세션 단위 `.cursor-context/.gate-fired-<session_id>`, SessionStart에서 1일 경과분 정리. `tests/hooks.bats`로 회귀 고정
- [x] 1-2 allowedTools Skill 추가 — `install.sh`의 헤드리스 온보딩 호출에 `Skill` 추가 + SKILL.md 직접 폴백 지시문 이중화
- [x] 1-3 온보딩 진행 표시 — 백그라운드 실행 + 10초 간격 `.` 표시 + 600초 kill 루프로 교체 (coreutils `timeout` 불필요, macOS 포함)
- [x] 1-4 metrics 회전 최적화 — 회전 검사를 `random.random() < 0.01` 확률 게이트로 변경, O_APPEND 원자성 가정 주석화
- [x] 1-5 소소한 정확성 묶음 — git status 20줄 초과 시 생략 건수 표시, `--no-merges` 백스톱, yarn 축약 명령 검출(+ 내장 명령 제외 목록)
- [x] 2 bats 테스트 + CI + README 갱신 — `tests/*.bats` 4개 파일(71개 케이스) + `.github/workflows/ci.yml`(ubuntu/macos 매트릭스) + README 테스트/CI 서술
- [x] 3-1 플러그인 패키징 — `plugin/.claude-plugin/plugin.json` + `plugin/hooks/hooks.json`(`${CLAUDE_PLUGIN_ROOT}` 기준) + 훅 스크립트의 `$BASH_SOURCE` 기반 자기 위치 탐색(`HOOK_DIR`)으로 install.sh/플러그인 두 배치 방식 모두 지원. 심볼릭 링크로 단일 진실 공급원 유지. README에 대안 설치법으로 문서화, install.sh는 당분간 병행 유지
- [x] 3-2 설정화 + 영어화 — `.cursor-context/config`(`LANG`, `FEEDBACK_THRESHOLD`, `METRICS_THRESHOLD`, `COMMIT_BACKSTOP`, `DOC_LINE_BUDGET`) + `lib-config.sh` 공유 로더 + 훅 전체·install.sh 이중 언어화(기본값 `en`, 설치자 로케일로 초기 추정)
- [x] 3-3 --uninstall — `install.sh <target> --uninstall [--purge-data]`: 훅·스킬 제거(백업 후), settings.json은 이 툴킷이 등록한 훅 항목만 python3로 제거(다른 훅은 보존), `.cursor-context/`는 기본 보존(`--purge-data`로만 삭제). README 수동 절차를 이 명령으로 교체(수동 절차는 대안으로 유지)
- [x] 3-4 모노레포 (설계 검토만) — `docs/MONOREPO_DESIGN.md`에 설계 방향 기록(루트 문서 + 패키지별 문서, 지문 생성기 스코프 인자, 세션 훅의 패키지 선택 휴리스틱). 계획서 원문대로 **구현은 착수하지 않음** — 후속 별도 계획 대상
