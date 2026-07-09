# 수동 테스트 체크리스트

`tests/*.bats` + CI(shellcheck)로 자동화할 수 없는 항목들이다. 릴리스 전
사람이 직접 확인한다.

## 1. 헤드리스 온보딩 E2E (install.sh 즉시 온보딩)

CI 러너에는 `claude` CLI의 API 인증이 없어 자동화가 불가능하다. `claude`
인증이 된 로컬 환경에서 확인한다.

- [ ] 신규 빈 프로젝트에 `./install.sh /path/to/target` 실행 (onboard 포함, `--no-onboard` 없이)
- [ ] 진행 표시(`.`)가 10초 간격으로 출력되는지 확인 (1-3 검증 — 무출력 구간으로
      "멈춘 줄 알았다"는 오해가 없는지)
- [ ] 완료 후 `.cursor-context/project-context.md`가 생성되었는지 확인
- [ ] 설치 스크립트가 이어서 실행하는 `context-benchmark.sh` 결과가 출력되고
      PASS인지 확인
- [ ] (1-2 검증) `--allowedTools`에 `Skill`이 포함되어 project-onboard 스킬이
      Skill 도구 경유로 정상 실행되는지 확인 (Skill 도구가 없는 구버전 CLI에서는
      프롬프트의 방어적 fallback 문구 — SKILL.md 직접 읽기 — 가 실제로 동작하는지도 확인)
- [ ] (1-3 검증) `claude`를 즉시 반환하지 않는 가짜 스크립트(sleep 700 등)로
      일시 교체해 600초 타임아웃 후 실제로 kill되고 "600초를 초과해
      중단되었습니다" 메시지가 뜨는지 확인 — bats로는 600초를 실제로 기다릴 수
      없어 자동화 불가
- [ ] macOS(`timeout` 명령 없음)에서도 위 타임아웃 루프가 정상 동작하는지 확인

## 2. 실제 Claude Code 세션에서의 훅 주입 확인

bats는 훅 스크립트 자체의 입출력만 검증한다. Claude Code 하네스가 훅의
종료 코드·stdout을 실제로 어떻게 처리하는지는 실제 세션에서만 확인 가능하다.

- [ ] 툴킷을 설치한 프로젝트에서 새 Claude Code 세션을 시작 → 스냅샷이
      컨텍스트에 자동 주입되는지 확인
- [ ] 세션 도중 프롬프트를 몇 번 보내며 매니페스트 파일을 수정 →
      prompt-freshness 경고가 실시간으로 뜨는지 확인
- [ ] 피드백/메트릭 임계값을 인위적으로 채운 뒤 턴을 종료 → evolve-gate가
      실제 하네스에서도 턴 종료를 차단(exit 2)하고 `/context-evolve` 실행을
      유도하는지 확인
- [ ] plan 모드(읽기 전용) 세션에서 임계값을 넘긴 채 턴을 종료 → 그대로
      종료되는지(차단되지 않는지), 이후 같은 세션의 다음 턴에서 sentinel로
      인해 재차단되지 않는지 확인 (1-1 회귀 시나리오 — bats에서는 훅
      스크립트만으로 시뮬레이션했고, 실제 세션에서의 "쓰기 부적절 판단"
      자체는 모델의 판단이라 하네스 레벨 확인이 별도로 필요)
- [ ] resume 세션에서는 SessionStart 훅이 스킵되는지, compact 후에는 다시
      주입되는지 확인

## 3. 플랫폼별 확인

- [ ] macOS에서 `shasum` 폴백 경로로 지문 기능이 정상 동작하는지
- [ ] Windows(Git Bash)에서 훅이 `bash -c` 래핑을 통해 정상 실행되는지
- [ ] Windows(Git Bash)에서 `install.sh`가 정상 실행되는지 (CI matrix는
      ubuntu-latest/macos-latest만 커버 — 네이티브 Windows는 미검증 상태 유지)
