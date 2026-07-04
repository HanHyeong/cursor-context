# cursor-context

**Claude Code에서 커서(Cursor) IDE 수준의 자동 프로젝트 맥락 파악을 재현하는 툴킷**

커서 IDE는 별도 지시 없이도 프로젝트 맥락을 잘 파악합니다. 이는 (1) 코드베이스
자동 인덱싱, (2) `.cursorrules` 기반 프로젝트 지침, (3) 열린 파일/최근 편집
컨텍스트 자동 주입 덕분입니다. 이 툴킷은 Claude Code의 훅(hook)과 스킬(skill)로
같은 효과를 만듭니다.

| 커서 IDE 기능 | 이 툴킷의 대응 |
|---|---|
| 코드베이스 자동 인덱싱 | **SessionStart 훅**: 세션 시작마다 스택·구조·git 상태 스냅샷을 자동 주입 |
| `.cursorrules` 프로젝트 지침 | **`/project-onboard` 스킬**: 코드를 분석해 CLAUDE.md를 자동 생성 |
| 인덱스 자동 갱신 | **`/context-refresh` 스킬 + 신선도 감지**: 문서가 오래되면 훅이 자동으로 경고 |

## 구성 요소

```
.claude/
├── settings.json                      # SessionStart 훅 등록
├── hooks/
│   └── session-context.sh             # 프로젝트 스냅샷 생성기
└── skills/
    ├── project-onboard/SKILL.md       # CLAUDE.md 자동 생성
    └── context-refresh/SKILL.md       # CLAUDE.md 증분 갱신
install.sh                             # 다른 프로젝트에 설치
```

### 1. SessionStart 훅 — 자동 스냅샷 주입

Claude Code 세션이 시작될 때마다 `session-context.sh`가 실행되어 다음 정보를
컨텍스트에 자동으로 넣습니다. **질문하기 전에 Claude가 이미 프로젝트를 알고
시작합니다.**

- 기술 스택 감지: Node/Python/Go/Rust/Java 등 매니페스트 기반 + 프레임워크 + npm scripts
- 디렉터리 구조: git 추적 파일 기준 깊이 2 트리
- Git 상태: 현재 브랜치, 최근 커밋 5개, 커밋되지 않은 변경사항
- CLAUDE.md 신선도: 마지막 문서 갱신 이후 커밋 수를 세어 오래되면 갱신 제안

출력은 컨텍스트 낭비를 막기 위해 항목별로 줄 수를 제한합니다.

### 2. `/project-onboard` — 프로젝트 문서 자동 생성

CLAUDE.md가 없는 프로젝트에서 실행하면, Claude가 코드베이스를 병렬 탐색해서
명령어·아키텍처·컨벤션·주의사항을 담은 CLAUDE.md를 생성합니다. CLAUDE.md는
Claude Code가 **모든 세션에서 자동으로 읽는 파일**이므로, 한 번 생성하면
이후 세션은 커서의 `.cursorrules`처럼 동작합니다.

- 명령어는 실제 실행으로 검증 후 기록
- 린터가 잡는 규칙은 제외하고, 도구가 못 잡는 판단 기준만 기록
- 200줄 이내로 유지 (긴 내용은 docs/로 분리)

### 3. `/context-refresh` — 문서 증분 갱신

코드는 바뀌는데 문서는 낡아가는 문제를 해결합니다. CLAUDE.md의 마지막 커밋
이후 변경된 파일만 분석해서 영향받은 섹션만 수정합니다. 훅이 신선도를 감지해
20커밋 이상 밀리면 자동으로 갱신을 제안합니다.

## 설치

### 이 저장소를 클론해서 다른 프로젝트에 설치

```bash
git clone https://github.com/HanHyeong/cursor-context.git
cd cursor-context
./install.sh /path/to/your/project
```

### 수동 설치

`.claude/` 디렉터리를 대상 프로젝트 루트에 복사하고
`chmod +x .claude/hooks/session-context.sh` 후 Claude Code를 재시작하면 됩니다.
기존 `.claude/settings.json`이 있다면 `hooks` 섹션만 병합하세요.

## 사용 흐름

```
1. install.sh로 설치
2. Claude Code 시작 → 스냅샷 자동 주입됨 (훅)
3. 첫 세션에서 /project-onboard 실행 → CLAUDE.md 생성
4. 이후 모든 세션: CLAUDE.md(자동 로드) + 스냅샷(훅) = 커서처럼 맥락 파악
5. 코드가 많이 바뀌면 훅이 경고 → /context-refresh로 문서 갱신
```

## 팁: 여기서 더 확장하려면

- **개인 전역 지침**: `~/.claude/CLAUDE.md`에 개인 코딩 스타일을 적으면 모든 프로젝트에 적용
- **디렉터리별 지침**: 모노레포라면 `apps/web/CLAUDE.md`처럼 하위 디렉터리에도 배치 가능 (해당 디렉터리 작업 시 자동 로드)
- **파일 임포트**: CLAUDE.md 안에서 `@docs/architecture.md` 형식으로 다른 문서를 임포트 가능
- 훅 상세: https://code.claude.com/docs/en/hooks — 스킬 상세: https://code.claude.com/docs/en/skills
