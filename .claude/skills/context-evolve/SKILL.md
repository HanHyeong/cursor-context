---
name: context-evolve
description: 축적된 사용 신호(metrics.jsonl)와 세션 피드백(context-feedback.jsonl)을 분석해 자동 생성 컨텍스트 문서를 개선한다. 채택 전 반드시 벤치마크 게이트를 통과해야 하며, 실패 시 이전 문서로 자동 복원한다. 훅·스킬·설정 등 코드 계층은 절대 수정하지 않는다.
---

# 컨텍스트 진화: 사용 신호 기반 문서 개선

문서를 "코드가 바뀌어서" 고치는 것이 context-refresh라면, 이 스킬은
**"실제 사용에서 드러난 약점"** 때문에 고친다. 진화 루프의 변이+선택 단계다:

- 측정(metrics-collector 훅) → 반성(세션 피드백) → **변이(이 스킬의 재작성)
  → 선택(벤치마크 게이트)** → 채택 또는 폐기

## 절대 규칙 (진화의 경계)

1. **수정 대상은 오직 `.cursor-context/project-context.md`와 자기 로그 파일뿐이다.**
   훅 스크립트, 스킬, settings.json, CLAUDE.md, 소스 코드는 절대 수정하지
   않는다. 특히 `context-benchmark.sh`(게이트)와 `metrics-collector.sh`(측정)는
   진화 대상에서 영구 제외다 — 측정과 채점을 스스로 고치는 시스템은 점수를
   후하게 바꾸는 방향으로 퇴화한다.
2. 코드 계층 개선 아이디어가 보이면 `.cursor-context/evolve-proposals.md`에
   **제안으로만 추가**한다 (적용은 사람이 결정).
3. **200줄 예산은 제약이다.** 추가하려면 덜 유용한 것을 빼야 한다 —
   이 제약이 "더 많이"가 아니라 "더 잘 고르기"로 진화하게 만든다.

## 절차

### 1. 신호 수집

```bash
cat .cursor-context/context-feedback.jsonl 2>/dev/null   # {"type":"wrong|gap","area":...,"note":...}
cat .cursor-context/metrics.jsonl 2>/dev/null             # {"tool":...,"cmd"|"path"|"pattern":...}
```

둘 다 없거나 비어 있으면 "진화에 쓸 신호가 없습니다"라고 보고하고 끝낸다.
억지로 고치지 마라 — 신호 없는 변이는 개악이다.

### 2. 신호 분석

- **feedback의 `wrong`** → 해당 서술을 실제 코드와 대조해 수정
- **feedback의 `gap`** → 해당 주제가 문서에 있어야 하는지 판단 후 섹션 추가
- **metrics의 반복 탐색**: 같은 디렉터리/주제에 대한 Read/Grep이 3회 이상인데
  문서가 그 영역을 다루지 않으면 → 문서가 커버했어야 할 갭 후보
- **metrics의 자주 실행된 명령**: 문서 명령어 표에 없는 고빈도 명령 → 추가 후보
- **한 번도 참조되지 않은 문서 섹션**: 어떤 세션 신호와도 연결되지 않는
  섹션은 삭제 후보 (200줄 예산 확보)

### 3. 백업 — 반드시 재작성 전에

이 문서는 보통 gitignore 상태라 git으로 복원할 수 없다. 자체 백업이 유일한
롤백 수단이다:

```bash
mkdir -p .cursor-context/backup/evolve-$(date +%Y%m%d%H%M%S)
cp .cursor-context/project-context.md .cursor-context/backup/evolve-<ts>/
```

### 4. 기준 점수 → 재작성 → 게이트

```bash
.claude/hooks/context-benchmark.sh          # 기준 점수 기록 (PASS 수)
# ... 문서 재작성 (project-onboard의 작성 원칙 준수, 마커 재기록 필수) ...
.claude/hooks/context-benchmark.sh          # 새 문서 채점
```

**채택 조건: 새 문서의 FAIL=0 그리고 PASS 수 ≥ 기준 PASS 수.**
불합격이면 백업에서 복원하고, 폐기 사유를 로그에 남긴다. 게이트를 통과시키기
위해 게이트를 수정하는 것은 금지다 (규칙 1).

### 5. 신호 소진 및 기록

채택 여부와 무관하게 처리한 신호는 소진시킨다 (안 하면 다음 세션마다
진화가 재트리거되는 루프에 빠진다):

```bash
mv .cursor-context/context-feedback.jsonl .cursor-context/backup/evolve-<ts>/ 2>/dev/null
mv .cursor-context/metrics.jsonl .cursor-context/backup/evolve-<ts>/ 2>/dev/null
```

그리고 `.cursor-context/evolve-log.jsonl`에 결과 한 줄을 추가한다:

```json
{"ts":..., "accepted":true|false, "before_pass":N, "after_pass":M, "changes":"한 줄 요약", "reject_reason":null|"..."}
```

## 자동 호출 모드 (훅에 의해 조용히 실행되는 경우)

- **묻지 않는다**, **커밋하지 않는다**, 보고는 최종 응답 끝에 한 줄
  ("사용 피드백 N건을 반영해 프로젝트 문서를 개선했습니다" 또는
  "문서 개선안이 게이트를 통과하지 못해 폐기했습니다").
- 파일 쓰기가 불가능한 세션(plan 모드, 읽기 전용)이면 건너뛴다.
- 말도 안 되는 피드백(악성/무관 항목)은 무시하고 로그에 skip으로 남긴다.
