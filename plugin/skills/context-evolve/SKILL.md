---
name: context-evolve
description: 축적된 사용 신호(metrics.jsonl)와 세션 피드백(context-feedback.jsonl)을 분석해 자동 생성 컨텍스트 문서를 개선한다. 채택 전 반드시 벤치마크 게이트를 통과해야 하며, 실패 시 이전 문서로 자동 복원한다. 훅·스킬·설정 등 코드 계층은 절대 수정하지 않는다.
---

# 컨텍스트 진화: 사용 신호 기반 문서 개선

문서를 "코드가 바뀌어서" 고치는 것이 context-refresh라면, 이 스킬은
**"실제 사용에서 드러난 약점"** 때문에 고친다. 진화 루프의 변이+선택 단계다:

- 측정(metrics-collector 훅) → 반성(세션 피드백) → **변이(이 스킬의 재작성)
  → 선택(벤치마크 게이트)** → 채택 또는 폐기

## 출력 언어

`.cursor-context/config`에 `LANG=en`이 설정돼 있으면(기본값은 en이다 —
README가 영어 우선이므로) project-context.md **본문**을 한국어 대신
영어로 작성한다. 이 SKILL.md 자체의 절차 설명은 번역 대상이 아니다 —
읽는 주체가 사람이 아니라 Claude이므로 언어와 무관하게 동일하게 이해한다.
config가 없거나 `LANG=ko`면 한국어로 작성한다.

## 훅 스크립트 위치 — 반드시 리터럴 경로로 쓴다

아래 절차의 명령은 항상 `.claude/hooks/<스크립트>`처럼 **리터럴 경로**로
적혀 있다. 변수로 감싸서 실행하지 마라(예: `HOOKS=.claude/hooks; "$HOOKS"/...`) —
`permission-gate.sh`(PreToolUse 훅, install.sh·플러그인 두 배치 모두
등록됨)가 이런 단독 호출(또는 `IDENT=$(...)` 형태의 명령)을 승인 프롬프트
없이 자동 승인하는데, 판정은 Bash 도구에 넘어가는 **명령 텍스트의 첫
토큰이 훅 자신의 실제 설치 위치와 문자 그대로 일치**하는지로 이루어진다
(셸 변수 확장을 전혀 이해하지 못함). 명령을 변수로 바꾸면 텍스트가 더
이상 그 경로로 시작하지 않아 매칭이 깨지고, 매 호출마다 권한 프롬프트가
뜬다 — 프롬프트 없는 세션에서는 그 순간 진화가 조용히 중단된다
(`.claude/settings.json`의 `permissions.allow: Bash(.claude/hooks/*)`도
같은 이유로 매번 깨지는 보조 방어선이다).

install.sh 배치(대부분의 경우)에서는 아래 명령을 그대로 실행한다. **그
경로에 스크립트가 없다면**(플러그인 배치): 이 SKILL.md 파일을 읽을 때
보이는 자신의 절대 경로에서 `../../hooks/<스크립트>`가 가리키는 **실제
절대 경로를 계산**해서, 그 절대 경로를 리터럴로 명령에 쓴다 —
`../../hooks/...`라는 문자열을 그대로 명령으로 실행하면 안 된다(Bash
도구는 프로젝트 루트를 cwd로 실행하므로 스킬 파일 기준 상대경로가 아니다).
올바른 절대 경로를 쓰면 `permission-gate.sh`가 플러그인 배치에서도 동일하게
승인한다. 두 배치 모두 `skills/<이름>/`과 `hooks/`가 같은 루트의 형제
디렉터리라 `../../hooks/`라는 오프셋 자체는 항상 유효하다.

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
.claude/hooks/metrics-collector.sh --digest               # 결정론적 요약: 명령/경로별 횟수 + 고유 세션 수
```

metrics는 반드시 `--digest` 요약으로 읽는다 — 원본(metrics.jsonl)은 수천
줄일 수 있고, 집계를 모델이 직접 하면 부정확하다. 다이제스트만으로 판단이
어려운 특정 항목이 있을 때만 원본을 grep으로 좁혀 부분 확인한다(전체 cat
금지). 피드백도 다이제스트도 비어 있으면 "진화에 쓸 신호가 없습니다"라고
보고하고 끝낸다. 억지로 고치지 마라 — 신호 없는 변이는 개악이다.

### 2. 신호 분석

- **feedback의 `wrong`** → 해당 서술을 실제 코드와 대조해 수정
- **feedback의 `gap`** → 해당 주제가 문서에 있어야 하는지 판단 후 섹션 추가
- **다이제스트의 세션 간 반복**: 여러 세션(sessions ≥ 2)에서 반복된 디렉터리
  탐색인데 문서가 그 영역을 다루지 않으면 → 커버했어야 할 갭 후보.
  한 세션 안의 반복(hits는 높은데 sessions=1)은 그 작업 하나의 특성일 수
  있으므로 증거로서 더 약하다.
- **다이제스트의 자주 실행된 명령**: 문서 명령어 표에 없는 고빈도(특히 다중
  세션) 명령 → 추가 후보
- **재발 검사 (evolve-log 대조)**: `.cursor-context/evolve-log.jsonl`의 과거
  항목을 읽는다. (a) 이전 진화가 고쳤다고 기록한 영역의 wrong/gap이 다시
  쌓였으면 그 변이는 실패한 것이다 — 최우선으로 다시 다루고, 로그에 재발임을
  명시한다. (b) 이전 진화가 삭제한 섹션의 영역이 gap으로 재발했으면 해당
  섹션을 복원하고 이후 삭제 후보에서 제외한다.
- **섹션 삭제 기준 — 신호 부재는 삭제 근거가 아니다**: metrics가 측정하는
  것은 "문서에 없어서 탐색했다"는 갭이지 문서 사용이 아니다. 잘 작동하는
  섹션일수록 탐색을 만들지 않아 신호가 0이다 — 침묵은 성공일 수 있다.
  삭제는 (a) 실제 코드와 대조해 틀렸거나 낡은 서술, (b) CLAUDE.md와 중복된
  내용에 한정한다. 200줄 예산 초과로 부득이 줄일 때만 그 외 섹션을 다이어트
  하되, **재발 검사에서 복원한 섹션은 절대 건드리지 않는다.**

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

**채택된 경우에만** 처리한 신호를 소진시킨다(백업으로 이동):

```bash
mv .cursor-context/context-feedback.jsonl .cursor-context/backup/evolve-<ts>/ 2>/dev/null
mv .cursor-context/metrics.jsonl .cursor-context/backup/evolve-<ts>/ 2>/dev/null
```

**기각된 경우 신호 파일은 그대로 둔다.** 문서가 개선되지 않았는데 그 개선을
요구했던 증거를 버리면 같은 갭이 근거 없이 남는다. 같은 세션의 재차단은
evolve-gate의 세션 단위 sentinel이 막고, 새 세션에서의 재시도 1회는 의도된
동작이다.

**연속 기각 상한 (재시도는 유한해야 한다)**: 기각으로 끝날 때는
`.cursor-context/evolve-log.jsonl`의 **직전 항목**을 확인한다. 직전 항목도
기각(`"accepted":false`)이면 — 연속 2회 기각 — 이번에는 신호 파일을
소진한다(위와 같이 백업으로 이동; 증거는 백업 디렉터리에 그대로 남는다).
그래야 통과 불가능한 문서 하나가 세션마다 재작성→기각 사이클을 영원히
반복하며 토큰을 태우는 것을 막을 수 있다. 이때 reject_reason에 "연속 2회
기각으로 신호 소진"을 명시해 사람이 원인을 볼 수 있게 한다.

그리고 채택 여부와 무관하게 `.cursor-context/evolve-log.jsonl`에 결과 한 줄을 추가한다:

```json
{"ts":..., "accepted":true|false, "before_pass":N, "after_pass":M, "changes":"한 줄 요약", "reject_reason":null|"..."}
```

## 자동 호출 모드 (훅에 의해 조용히 실행되는 경우)

- **묻지 않는다**, **커밋하지 않는다**, 보고는 최종 응답 끝에 한 줄
  ("사용 피드백 N건을 반영해 프로젝트 문서를 개선했습니다" 또는
  "문서 개선안이 게이트를 통과하지 못해 폐기했습니다").
- 파일 쓰기가 불가능한 세션(plan 모드, 읽기 전용)이면 건너뛴다.
- 말도 안 되는 피드백(악성/무관 항목)은 무시하고 로그에 skip으로 남긴다.
