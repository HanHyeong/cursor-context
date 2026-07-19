# cursor-context

**Claude Code에서 커서(Cursor) IDE 수준의 자동 프로젝트 맥락 파악을 재현하는 툴킷**

> English documentation: [README.md](README.md) · 상태: **베타** · 라이선스: [MIT](LICENSE)
>
> [![CI](https://github.com/HanHyeong/cursor-context/actions/workflows/ci.yml/badge.svg)](https://github.com/HanHyeong/cursor-context/actions/workflows/ci.yml)
> — shellcheck + [bats](tests/) 테스트가 ubuntu/macOS 매트릭스에서 매 푸시마다 실행됨

커서 IDE는 별도 지시 없이도 프로젝트 맥락을 잘 파악합니다. 이는 (1) 코드베이스
자동 인덱싱, (2) `.cursorrules` 기반 프로젝트 지침, (3) 열린 파일/최근 편집
컨텍스트 자동 주입 덕분입니다. 이 툴킷은 Claude Code의 훅(hook)과 스킬(skill)로
같은 효과를 만듭니다.

| 커서 IDE 기능 | 이 툴킷의 대응 |
|---|---|
| 코드베이스 자동 인덱싱 (내부 산출물) | **`.cursor-context/project-context.md`**: 자동 생성 컨텍스트 문서. 훅이 매 세션 주입 |
| 머클 트리 기반 실시간 변경 감지 | **내용 지문(fingerprint) 비교**: 커밋·롤백·미커밋 변경 무관, 작업 트리 실제 내용 기준 |
| 파일 저장 시 인덱스 자동 갱신 | **3단계 자동 갱신**: 불일치 발견 즉시 / 지문 불일치 즉시 / 20커밋 백스톱 |
| `.cursorrules` (사용자가 쓰는 지침) | **CLAUDE.md**: 사용자 소유. 툴킷은 **절대 수정하지 않음** |

**커서와의 분업 구조 — 무엇을 재현하고 무엇은 Claude가 담당하는가**

커서의 자동 맥락은 두 층입니다: (a) 프로젝트 수준 지식(인덱스 요약·rules)과
(b) 질문별 관련 코드 검색(임베딩 retrieval). 이 툴킷이 재현하는 것은 **(a)**
입니다. (b)는 재현하지 않습니다 — Claude Code는 Grep/Glob 기반 에이전틱
검색이 원래 강점이라 질문별 코드 탐색은 이미 잘합니다. 부족했던 것은 "탐색을
시작하기 전에 프로젝트가 뭔지 아는 상태"였고, 이 툴킷이 그 층을 채웁니다.
즉 **툴킷의 프로젝트 지식 + Claude 자체의 실시간 검색 ≈ 커서의 경험**입니다.

**파일 소유권 분리 — 이 툴킷의 핵심 설계**

커서의 인덱스는 사용자 파일과 분리된 내부 산출물이라 승인 없이 갱신해도
안전합니다. 같은 원리로 이 툴킷은 두 파일을 엄격히 구분합니다:

- **CLAUDE.md** — 사용자가 직접 작성·관리하는 지침. 툴킷은 읽기만 하고 절대
  건드리지 않습니다. 두 문서가 충돌하면 항상 이쪽이 우선입니다.
- **`.cursor-context/project-context.md`** — 기계가 생성하는 프로젝트 분석 문서.
  훅이 세션 시작 시 직접 컨텍스트에 주입하므로 CLAUDE.md에 import 한 줄
  추가할 필요도 없습니다. 커서의 인덱스처럼 커밋하지 않는 로컬 산출물이
  기본입니다(.gitignore에 자동 등록). **팀 규모가 크면 커밋해서 공유하는
  것이 경제적입니다** — 팀원마다 첫 세션에서 각자 생성하는 비용을 한 번으로
  줄일 수 있습니다 (.gitignore에서 해당 줄을 빼고 커밋하면 이후 갱신도
  공유됩니다).

**제로터치 설계**: 문서 생성·갱신은 사용자 승인 없이 자동으로 일어납니다.
문서가 없거나 오래된 세션에서는 Claude가 **사용자의 요청을 먼저 처리한 뒤**
그 과정에서 파악한 지식으로 같은 턴에서 조용히 생성/갱신합니다. 첫 응답이
느려지지 않고, 확인 질문도 없습니다.

## 구성 요소

```
.claude/                               # 코드 계층 (진화 대상 아님)
├── settings.json                      # 훅 4종 등록
├── hooks/
│   ├── session-context.sh             # 세션 시작: 스냅샷 주입 + 신선도 검사
│   ├── prompt-freshness.sh            # 매 프롬프트: 지문 재검사 (일치하면 침묵)
│   ├── context-fingerprint.sh         # 지문 계산·비교의 단일 진실 공급원
│   ├── metrics-collector.sh           # 도구 사용 신호 측정 (자기 평가용)
│   ├── evolve-gate.sh                 # Stop 게이트: 신호 임계 도달 시 진화 강제
│   ├── context-benchmark.sh           # 문서 품질 게이트 (진화 채택 심사)
│   └── lib-config.sh                  # .cursor-context/config 공유 로더 (훅 아님)
└── skills/
    ├── project-onboard/SKILL.md       # 문서 자동 생성
    ├── context-refresh/SKILL.md       # 문서 증분 갱신
    └── context-evolve/SKILL.md        # 사용 신호 기반 문서 진화
.cursor-context/                       # 데이터 계층 (기계 생성, gitignore 권장)
├── config                             # KEY=VALUE 설정 (LANG, 임계값 등 — 선택)
├── project-context.md                 # 자동 생성 컨텍스트 문서
├── metrics.jsonl / context-feedback.jsonl / evolve-log.jsonl
└── backup/                            # 진화 전 문서 백업 (롤백 수단)
install.sh                             # 다른 프로젝트에 설치 (또는 --uninstall로 제거)
plugin/                                # Claude Code 플러그인 배치 (install.sh의 대안)
├── .claude-plugin/plugin.json         # 플러그인 매니페스트
├── hooks/                             # .claude/hooks/*의 실파일 복사본 + hooks.json
└── skills/                            # .claude/skills/*의 실파일 복사본 (CI가 동기화 검증)
```

데이터 계층을 `.claude/` 밖에 두는 이유: Claude Code는 `.claude/` 내부 파일
쓰기를 민감 작업으로 보호하므로, 그 안에 데이터를 두면 자동 갱신마다 승인이
필요해져 제로터치가 깨집니다 (실세션 검증으로 확인된 사실).

### 1. SessionStart 훅 — 자동 스냅샷 주입

Claude Code 세션이 시작될 때마다 `session-context.sh`가 실행되어 다음 정보를
컨텍스트에 자동으로 넣습니다. **질문하기 전에 Claude가 이미 프로젝트를 알고
시작합니다.**

- 기술 스택 감지: Node/Python/Go/Rust/Java 등 매니페스트 기반 + 프레임워크 + npm scripts
- 디렉터리 구조: git 추적 파일 기준 깊이 2 트리
- Git 상태: 현재 브랜치, 최근 커밋 5개, 커밋되지 않은 변경사항
- **`.cursor-context/project-context.md` 내용 주입**: 자동 생성 문서가 있으면 통째로 주입 (250줄 한도)
- 신선도 검사: 문서에 저장된 내용 지문을 작업 트리의 현재 상태와 실시간
  비교하고(+ 20커밋 백스톱), 상황에 맞는 자동 갱신 지시(미세/구조적/전체)를 주입

출력은 컨텍스트 낭비를 막기 위해 항목별로 줄 수를 제한합니다. 또한 훅은
`startup|clear|compact` 이벤트에서만 실행됩니다 — 세션 재개(resume) 시에는
스냅샷이 이미 컨텍스트에 있으므로 중복 주입하지 않아 토큰을 아낍니다.
(compact 후에는 요약 과정에서 스냅샷이 유실될 수 있어 다시 주입하고,
resume 사이에 코드가 바뀐 경우는 아래 프롬프트 신선도 훅이 잡습니다.)

**프롬프트 신선도 훅(`prompt-freshness.sh`)**: 사용자가 프롬프트를 보낼
때마다 지문을 재검사합니다. 일치하면 아무것도 출력하지 않고(토큰 비용 0),
달라진 경우에만 달라진 항목과 "관련 문서 내용을 신뢰하지 말라"는 경고를
주입합니다. 세션 도중의 커밋·롤백·브랜치 전환이 다음 프롬프트에서 바로
반영되는, 이 툴킷의 실시간성을 담당하는 핵심 장치입니다.

### 2. `/project-onboard` — 프로젝트 문서 자동 생성

**설치 시점에 즉시 생성됩니다** — 설치는 곧 사용 의사이므로, `install.sh`가
설치 직후 헤드리스 Claude 세션을 띄워 문서를 바로 만듭니다 (1~3분, API 토큰
사용, `--no-onboard`로 건너뛰기 가능). 커서가 프로젝트를 여는 즉시 인덱싱하는
것과 같은 타이밍입니다. claude CLI가 없거나 실패하면 폴백으로 첫 실질 작업
완료 후(또는 프로젝트 자체를 질문해 이미 탐색이 이루어진 세션 후) 같은 턴에서
자동 생성됩니다 (수동 실행도 가능: `/project-onboard`). 명령어·아키텍처·
컨벤션·주의사항을 담으며, 이후 세션부터 훅이 이 문서를 자동 주입하므로
커서처럼 맥락을 알고 시작합니다.

- 명령어는 실제 실행으로 검증 후 기록 — 즉 온보딩 세션이 프로젝트의
  테스트·린트·타입체크·빌드 명령을 **실제로 실행할 수 있습니다**. 부작용
  없는 명령만 실행하도록 지시되며(배포·publish·마이그레이션 등 상태를
  바꾸는 명령은 존재 확인만), 설치 시점에 아무것도 실행되지 않길 원하면
  `--no-onboard`를 쓰세요
- 린터가 잡는 규칙은 제외하고, 도구가 못 잡는 판단 기준만 기록
- 200줄 이내로 유지 (긴 내용은 docs/로 분리)
- CLAUDE.md와 중복되는 내용은 쓰지 않으며, CLAUDE.md는 절대 수정하지 않음

### 3. `/context-refresh` — 문서 증분 갱신

코드는 바뀌는데 문서는 낡아가는 문제를 해결합니다. 커서의 증분 인덱싱처럼
"변경의 크기"가 아니라 **"변경의 성격"**으로 판단하고, 갱신은 작고 자주
일어납니다. 트리거는 3단계입니다:

1. **미세 갱신 (항상 활성)** — 작업 중 문서와 실제 코드의 불일치를 발견하면
   그 부분만 즉시 수정. 지식이 이미 컨텍스트에 있으므로 비용이 사실상 없음
2. **지문 불일치 감지 (프롬프트 단위 실시간)** — 문서 생성 시점에 구조적
   파일(매니페스트·CI·빌드 설정)의 내용 해시와 디렉터리 구조 해시를 지문으로
   저장하고, **세션 시작 시 + 사용자가 프롬프트를 보낼 때마다** 작업 트리의
   현재 내용과 비교합니다. 커서의 머클 트리 비교와 같은 원리라서 커밋 수와
   무관합니다: 미커밋 수정도 잡히고, 세션 도중의 커밋·롤백·브랜치 전환도
   다음 프롬프트에서 즉시 잡히고, 롤백으로 문서 시점 상태에 돌아오면 지문이
   다시 일치해 불필요한 갱신이 일어나지 않습니다. 프롬프트 훅은 **일치하면
   아무것도 출력하지 않으므로** 평상시 토큰 비용이 0입니다
3. **20커밋 백스톱** — 지문으로 잡히지 않는 점진적 드리프트
   (컨벤션 변화 등)를 위한 최후 방어선

**오도 방지 안전장치** — 이 기능은 Claude의 맥락 파악을 도와야지 방해하면
안 되므로, 다음을 보장합니다:

- 스냅샷·문서는 "보조 정보"로 명시 주입: 실제 코드와 다르면 실제 코드 우선,
  CLAUDE.md와 겹치면 CLAUDE.md 우선이라는 우선순위 규칙이 함께 주입됩니다
- 지문 불일치 시, 낡았을 수 있는 문서 섹션은 **현재 작업 중에도 신뢰하지
  말라**는 지시가 함께 주입됩니다 (갱신은 작업 후, 불신은 즉시)
- 문서 주입 시 해시 마커 블록은 제거되고, 250줄 초과 시 잘렸다는 사실이
  명시됩니다 (조용한 잘림 없음)
- 디렉터리 지문은 "디렉터리 목록"만 봅니다 — 메모·스크래치 파일 추가로는
  거짓 "구조 변경" 경고가 나지 않습니다
- `.cursor-context/` 자체(툴킷의 데이터 계층 — 문서·메트릭·진화 백업)는
  구조 해시에서 제외됩니다 — 툴킷의 자기 활동이 자기 갱신 알람을 울리지
  않으며, 디렉터리를 커밋하는 팀 공유 모드에서도 진화 백업이 거짓 "구조
  변경"을 만들지 않습니다
- macOS(`shasum`)·Linux(`sha256sum`) 모두 지원합니다. 해시 도구가 없으면
  거짓 경고나 거짓 "검증됨" 보증을 만드는 대신, 지문 기능이 꺼지고 세션
  스냅샷에 "지문 검증 불가 — 문서 정보는 실제 파일로 확인하라"는 안내가
  정직하게 표시됩니다

모든 갱신은 사용자 요청 완료 후 같은 턴에서 조용히 실행됩니다.

## 설치

### 이 저장소를 클론해서 다른 프로젝트에 설치

```bash
git clone https://github.com/HanHyeong/cursor-context.git
cd cursor-context
./install.sh /path/to/your/project
```

**설치는 비파괴적이며 병합까지 자동입니다** — 기존 환경에 영향을 주지 않습니다:

- 기존 `settings.json`이 있으면 **hooks 배열에만 자동으로 추가 병합**합니다
  (기존 키·훅의 의미 전부 보존, 병합 전 원본 백업, 재실행 시 중복 등록 없음.
  단, JSON 재직렬화로 들여쓰기 등 포맷은 정리될 수 있습니다).
  훅 등록은 배열 추가 방식이라 **기존 훅은 그대로 함께 실행**됩니다.
  python3가 없거나 JSON이 손상된 경우에만 원본을 건드리지 않고 병합용
  예시 파일 제공으로 폴백합니다
- 동명의 기존 훅·스킬은 내용이 다를 때만 `.claude/backup/` 아래로 백업 후
  교체합니다. 백업은 스킬 탐색 범위 밖이라 백업본이 스킬로 중복 등록되는
  일이 없습니다
- 재설치(업그레이드)는 멱등입니다 — 내용이 같으면 아무것도 바꾸지 않습니다
- 이 툴킷의 훅은 모든 경로에서 `exit 0`이므로 다른 훅이나 프롬프트 처리를
  차단하지 않습니다

### 플랫폼 지원

| 플랫폼 | 상태 |
|---|---|
| Linux | ✅ 지원 — 실제 Claude Code 세션에서 E2E 검증됨 + CI |
| macOS | ✅ 지원 — `shasum` 폴백을 macOS CI 러너에서 검증(`tests/fingerprint.bats`, `tests/hooks.bats`) |
| Windows (WSL) | ✅ 지원 — 리눅스와 동일 |
| Windows (네이티브) | ⚠️ 호환 설계, 실기기 미검증 |

네이티브 Windows의 경우: Claude Code가 Git for Windows(Git Bash)를 필수로
요구하므로 이 툴킷이 쓰는 bash·git·sha256sum·awk는 이미 설치되어 있습니다.
훅 명령은 cmd 경유 실행에서도 변수 확장이 되도록 `bash -c` 래핑 형식을
사용합니다. 다만 실제 Windows 기기에서의 검증은 아직 이루어지지 않았으므로
문제가 있으면 이슈로 알려주세요. `install.sh`는 Git Bash에서 실행하면 됩니다.

### 설정

`install.sh`가 설치 시점에 시스템 로케일로 `LANG`을 추정해
`.cursor-context/config`(KEY=VALUE, `#` 주석)를 생성합니다. 파일이나 개별
줄을 지우면 훅에 내장된 기본값으로 돌아갑니다 — 없어도 동작에 지장 없습니다.

| 키 | 기본값 | 의미 |
|---|---|---|
| `LANG` | `en` | `ko` 또는 `en` — 훅 주입 텍스트·설치 출력 언어 |
| `FEEDBACK_THRESHOLD` | `5` | 진화 게이트가 발동하는 피드백 건수 |
| `METRICS_THRESHOLD` | `300` | 진화 게이트가 발동하는 메트릭 줄 수 |
| `COMMIT_BACKSTOP` | `20` | 문서 생성 후 갱신을 요청하기까지의 커밋 수 |
| `DOC_LINE_BUDGET` | `200` | `context-benchmark.sh`가 강제하는 목표 줄 수 (+50에서 WARN, 그 이상 FAIL) |
| `DOC_MIN_LINES` | `10` | 본문 실질(비공백) 줄 수 하한 — 미만이면 벤치마크 FAIL, 내용을 다 지운 재작성은 채택 불가 |

`PASS`/`WARN`/`FAIL`과 `결과: PASS=x WARN=y FAIL=z` 요약 줄은 언어와 무관하게
항상 이 형태 그대로입니다 — `context-evolve`의 채택 기준이 이 정확한
토큰을 읽기 때문입니다.

### 수동 설치

`.claude/` 디렉터리를 대상 프로젝트 루트에 복사하고
`chmod +x .claude/hooks/*.sh` 후 Claude Code를 재시작하면 됩니다.
기존 `.claude/settings.json`이 있다면 `hooks` 섹션만 병합하세요
(배열에 추가하는 방식이라 기존 훅은 그대로 함께 실행됩니다).

### 플러그인 설치 (대안)

`install.sh` 없이, 프로젝트의 `.claude/`에 아무것도 쓰지 않고 설치하는
방법입니다. [`plugin/`](plugin/) 디렉터리가 Claude Code 플러그인 형식을
그대로 따릅니다:

```
/plugin marketplace add HanHyeong/cursor-context   # 또는 로컬 체크아웃 경로를 지정
/plugin install cursor-context
```

훅 스크립트·스킬 내용은 `install.sh`와 동일하고, 참조 방식만
`${CLAUDE_PROJECT_DIR}/.claude` 대신 `${CLAUDE_PLUGIN_ROOT}`를 씁니다.
기계 생성 데이터는 이 경우에도 프로젝트 루트의 `.cursor-context/`에
그대로 쌓입니다 — 플러그인이라고 별도 저장 위치를 쓰지 않으므로 두 설치
방식을 자유롭게 오갈 수 있습니다. 두 방식은 당분간 함께 유지되며,
`install.sh`는 플러그인 방식이 한두 릴리스 정도 검증된 뒤에야 폐기 절차를
밟습니다.

## 사용 흐름

```
1. install.sh로 설치 — 설치 직후 문서까지 즉시 자동 생성됨 (사용자가 하는 일은 이것뿐)
2. Claude Code 시작 → 스냅샷 + 문서 자동 주입 (훅)
3. 이후 모든 세션: 사용자 지침(CLAUDE.md) + 자동 문서 + 스냅샷 = 커서처럼 맥락 파악
4. 문서는 스스로 신선하게 유지됨: 불일치 발견 즉시 / 구조 변경 즉시 /
   20커밋 백스톱 — 전부 작업 완료 후 조용히 (CLAUDE.md는 절대 수정 안 됨)
5. 사용 신호가 쌓이면 문서가 스스로 진화함 (게이트 통과 시에만 채택)
```

## 자기 평가와 진화

이 툴킷은 신선도만 유지하는 게 아니라, **사용되는 방식에서 배웁니다**
(측정 → 반성 → 변이 → 선택 루프):

- **측정 (결정론적, 토큰 0)** — `PostToolUse` 훅이 Claude가 실행한 명령과
  탐색한 파일/패턴을 `.cursor-context/metrics.jsonl`에 기록합니다 (필드 절단,
  2,000줄 자동 회전, 로컬 전용). 순수 코드라 LLM이 측정을 오염시킬 수 없습니다.
  프라이버시 주석: 기록되는 명령은 평문입니다. 자격증명 형태의 값
  (`token=`, `password=`, `api-key=`, `Bearer …`)은 기록 전에 베스트 에포트로
  마스킹되지만 이는 안전망이지 보증이 아닙니다 — 시크릿을 CLI 인자로 직접
  넘기지 마세요. 이 파일은 gitignore되며 로컬을 벗어나지 않습니다.
- **반성 (비용 ≈ 0)** — 매 세션에 상시 규칙 주입: 문서가 틀렸거나 없어서
  탐색이 필요했던 주제가 있으면 작업 후 `.cursor-context/context-feedback.jsonl`에
  JSON 한 줄을 남깁니다.
- **진화 (게이트 통과 시만, 결정론적 강제)** — 신호가 쌓이면(피드백 5건 또는
  메트릭 300줄) `Stop` 훅(`evolve-gate.sh`)이 턴 종료를 차단하고 작업 완료 후
  `/context-evolve` 실행을 강제합니다 — "나중에 하라"는 주입 지시는 확률적
  보장뿐임이 실측으로 확인되어, 강제는 모델 준수가 아닌 하네스에 둡니다.
  분석은 원시 로그가 아니라 결정론적 요약(`metrics-collector.sh --digest`:
  명령·디렉터리별 횟수 + 고유 세션 수)에서 출발합니다 — 문서 갭의 진짜
  증거는 세션 간 반복이고, 집계는 순수 코드가 해야 정확합니다. 진화 내용:
  틀린 것 수정, 여러 세션이 재탐색한 것 추가, evolve-log 대조로 재발 검사
  (과거 진화가 고쳤다는 영역이 다시 나타나면 최우선 재처리 + 기록). 삭제는
  의도적으로 보수적입니다 — 틀렸거나 낡은 서술, CLAUDE.md 중복에 한정하며,
  **신호 부재는 삭제 근거가 아닙니다**: metrics는 사용이 아니라 갭을
  측정하므로, 잘 작동하는 섹션일수록 탐색 신호가 없습니다 — 침묵은 성공일
  수 있습니다 (200줄 예산은 여전히 "더 많이"가 아니라 "더 잘 고르기"를
  강제합니다). 진화가 **채택되면** 신호 파일이 소진되어 임계 조건 자체가
  해제되므로 차단은 임계값 교차당 최대 1회입니다(+ stop_hook_active 가드).
  기각된 재작성은 신호 파일을 증거로 보존합니다 — 그 경우와 진화를 건너뛴
  세션(plan 모드, 읽기 전용 등) 모두, 세션 단위
  sentinel(`.cursor-context/.gate-fired-<session_id>`)이 **세션당 최대
  1회**로 차단을 제한합니다 — 같은 세션의 다음 턴들은 통과하고, 새
  세션에서는 다시 1회 차단됩니다. 쓰기가 부적절한 세션은 그대로 종료를
  허용합니다.
- **선택 (결정론적 게이트)** — 새 문서 채택 전 `context-benchmark.sh`가
  검사: 줄 수 예산, 본문 실질 줄 수 하한(`DOC_MIN_LINES` — 내용을 다
  지워버리는 변이는 절대 채택될 수 없음), 마커·지문 유효성, 언급된
  `npm run`/`make` 명령의 실재, 언급 경로의 실재. **불합격이면 백업에서
  이전 문서 자동 복원.** 범위에 대한 정직한 주석: 이 게이트가 검증하는
  것은 형식과 "저장소로 확인 가능한 사실 주장"까지입니다 — 문서의 의미적
  유용성은 측정하지 못합니다. 그 판단은 재작성하는 모델의 몫이고, 게이트의
  역할은 그것을 경계 짓는 것(검증 가능한 속성의 회귀 방지, 퇴행 결과 차단)
  이지 문장 품질을 채점하는 것이 아닙니다. 게이트와 측정기는 진화 대상에서
  영구 제외 — 채점기를 스스로 고칠 수 있는 시스템은 퇴화합니다.

코드 계층(훅·스킬) 개선 아이디어는 `.cursor-context/evolve-proposals.md`에 **제안만**
쌓이고, 적용은 사람이 결정합니다. 진화 이력은 `.cursor-context/evolve-log.jsonl`에
남습니다.

## 테스트

```bash
shellcheck .claude/hooks/*.sh install.sh   # 경고 0건, CI에서 강제
bats tests/*.bats
```

- `tests/fingerprint.bats` — 지문 생성·비교: 매니페스트 수정/롤백, 스크래치
  파일 불변성, CRLF 마커 정규화
- `tests/install.bats` — 설치 멱등성, settings.json 병합·백업, python3 부재
  폴백, 타입 불일치 백업 처리
- `tests/hooks.bats` — 세션 스냅샷 구조, 신선도 훅의 무변경 시 침묵,
  evolve-gate 임계값 + 세션 단위 sentinel 동작, 메트릭 기록·회전
- `tests/benchmark.bats` — 줄 수 예산 판정, 존재하지 않는 npm/make 명령은
  FAIL, 존재하지 않는 경로는 WARN(FAIL 아님)
- `tests/MANUAL.md` — CI가 구조적으로 검증할 수 없는 항목 체크리스트
  (헤드리스 온보딩 E2E는 실제 API 인증 필요, 훅 주입 동작은 실제 Claude Code
  세션에서만 확인 가능)

`.github/workflows/ci.yml`이 매 푸시·PR마다 ubuntu-latest/macos-latest
매트릭스에서 shellcheck와 전체 bats 스위트를 실행하고, `plugin/`이
`.claude/`의 바이트 단위 동일 복사본인지(심볼릭 링크 금지 — 네이티브
Windows 체크아웃에서 깨짐)도 함께 검증합니다.

## 제거 방법

```bash
./install.sh /path/to/your/project --uninstall
```

이 툴킷의 훅·스킬을 제거하고, `.claude/settings.json`에서도 이 툴킷이 등록한
훅 4종만 골라 제거합니다 — 같은 이벤트에 등록된 다른 훅은 그대로 남습니다.
아무것도 완전히 삭제하지 않고 먼저 `.claude/backup/uninstall-<timestamp>/`로
옮긴 뒤 제거하므로 언제든 되돌릴 수 있습니다. `.cursor-context/`(생성된 문서와
메트릭 데이터)는 기본적으로 보존되며, 이것까지 지우려면 `--purge-data`를
추가하세요.

`python3`가 없으면 `settings.json`의 훅 항목을 자동으로 제거할 수 없습니다 —
이 경우 어떤 줄을 직접 지워야 하는지 안내가 출력됩니다.

수동 제거(스크립트 대신 직접 하고 싶다면, 동일한 결과):

```bash
rm .claude/hooks/session-context.sh .claude/hooks/prompt-freshness.sh \
   .claude/hooks/context-fingerprint.sh .claude/hooks/metrics-collector.sh \
   .claude/hooks/context-benchmark.sh .claude/hooks/evolve-gate.sh .claude/hooks/lib-config.sh
rm -rf .claude/skills/project-onboard .claude/skills/context-refresh .claude/skills/context-evolve
rm -rf .cursor-context
# 마지막으로 .claude/settings.json의 hooks 배열에서 session-context.sh /
# prompt-freshness.sh / metrics-collector.sh / evolve-gate.sh 네 항목을 제거하세요.
```

## 문제 해결

- **새 세션에 스냅샷이 안 보임** — `settings.json`에 훅 항목이 있는지(수동
  병합 안내가 나왔다면 `settings.hooks-example.json` 참고), 스크립트에 실행
  권한이 있는지, 그리고 재개(resume)가 아닌 **새 세션**인지 확인하세요
  (신선도는 resume 중에도 프롬프트 훅이 계속 검사합니다).
- **"지문 검증 불가" 표시** — 해시 도구가 없거나 문서에 지문 마커가 없는
  경우입니다. 무해하며, 다음 문서 갱신 때 마커가 자동 재기록됩니다.
- **문서 내용이 틀림** — 그냥 Claude에게 말하면 해당 부분만 고칩니다(미세
  갱신 규칙). 전면 재생성은 `/project-onboard`.
- **잠시 끄고 싶음** — `settings.json`에서 훅 항목 두 개만 제거하면 됩니다.
  파일은 그대로 둬도 무방합니다.

## 팁: 여기서 더 확장하려면

- **개인 전역 지침**: `~/.claude/CLAUDE.md`에 개인 코딩 스타일을 적으면 모든 프로젝트에 적용
- **디렉터리별 지침**: 모노레포라면 `apps/web/CLAUDE.md`처럼 하위 디렉터리에도 배치 가능 (해당 디렉터리 작업 시 자동 로드)
- **파일 임포트**: CLAUDE.md 안에서 `@docs/architecture.md` 형식으로 다른 문서를 임포트 가능
- 훅 상세: https://code.claude.com/docs/en/hooks — 스킬 상세: https://code.claude.com/docs/en/skills
