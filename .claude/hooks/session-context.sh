#!/usr/bin/env bash
# SessionStart 훅: 세션 시작 시 프로젝트 스냅샷을 Claude의 컨텍스트로 자동 주입한다.
# 커서 IDE가 프로젝트를 자동 인덱싱하듯, Claude가 첫 질문 전에 이미
# 스택 / 구조 / 최근 변경사항을 알고 시작하게 만드는 것이 목적.
#
# stdout으로 출력한 내용은 Claude Code가 세션 컨텍스트에 추가한다.
# 실패해도 세션을 막지 않도록 항상 exit 0.

set -u
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0

# 출력량 제한 (컨텍스트 낭비 방지)
MAX_TREE_LINES=60
MAX_COMMITS=5
MAX_CHANGED=20

echo "<project-context-snapshot>"
echo "자동 생성된 프로젝트 스냅샷입니다. 프로젝트 맥락 파악과 간결한 요청의 의도 해석에 출발점으로 사용하세요."
echo "우선순위 규칙: (1) 이 스냅샷·문서는 보조 정보다 — 실제 코드와 다르면 항상 실제 코드가 우선이다. (2) 사용자 지침(CLAUDE.md)과 겹치거나 충돌하면 항상 CLAUDE.md가 우선이다."
echo ""

# ---------------------------------------------------------------
# 1. 기술 스택 감지
# ---------------------------------------------------------------
echo "## 기술 스택"
detected=0

if [ -f package.json ]; then
  detected=1
  echo "- Node.js 프로젝트 (package.json)"
  # 패키지 매니저 감지
  [ -f pnpm-lock.yaml ] && echo "  - 패키지 매니저: pnpm"
  [ -f yarn.lock ] && echo "  - 패키지 매니저: yarn"
  [ -f package-lock.json ] && echo "  - 패키지 매니저: npm"
  [ -f bun.lockb ] || [ -f bun.lock ] && echo "  - 패키지 매니저: bun"
  # 주요 프레임워크 감지 (dependencies 문자열 검색, jq 불필요)
  for fw in react next vue nuxt svelte @angular/core express fastify nestjs vite; do
    grep -q "\"$fw\"" package.json 2>/dev/null && echo "  - 프레임워크/도구: $fw"
  done
  # npm scripts 목록
  if command -v node >/dev/null 2>&1; then
    scripts=$(node -e 'const s=require("./package.json").scripts||{};Object.entries(s).forEach(([k,v])=>console.log(`  - npm run ${k}: ${v}`))' 2>/dev/null | head -15)
    if [ -n "$scripts" ]; then
      echo "  - 사용 가능한 스크립트:"
      echo "$scripts" | sed 's/^/  /'
    fi
  fi
fi

[ -f pyproject.toml ] && detected=1 && echo "- Python 프로젝트 (pyproject.toml)"
[ -f requirements.txt ] && detected=1 && echo "- Python 프로젝트 (requirements.txt)"
[ -f go.mod ] && detected=1 && echo "- Go 프로젝트 (go.mod: $(head -1 go.mod))"
[ -f Cargo.toml ] && detected=1 && echo "- Rust 프로젝트 (Cargo.toml)"
[ -f pom.xml ] && detected=1 && echo "- Java/Maven 프로젝트"
[ -f build.gradle ] || [ -f build.gradle.kts ] && detected=1 && echo "- Java·Kotlin/Gradle 프로젝트"
[ -f Gemfile ] && detected=1 && echo "- Ruby 프로젝트 (Gemfile)"
[ -f composer.json ] && detected=1 && echo "- PHP 프로젝트 (composer.json)"
[ -f Dockerfile ] && echo "- Dockerfile 존재"
[ -f docker-compose.yml ] || [ -f docker-compose.yaml ] || [ -f compose.yaml ] && echo "- Docker Compose 구성 존재"
ls .github/workflows/*.yml .github/workflows/*.yaml >/dev/null 2>&1 && echo "- GitHub Actions CI 구성 존재 ($(ls .github/workflows/ | tr '\n' ' '))"

[ "$detected" -eq 0 ] && echo "- 알려진 매니페스트 파일 없음 (직접 탐색 필요)"
echo ""

# ---------------------------------------------------------------
# 2. 디렉터리 구조 (git 추적 파일 기준, 깊이 2)
# ---------------------------------------------------------------
echo "## 디렉터리 구조 (깊이 2, 추적 파일 기준)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git ls-files 2>/dev/null \
    | awk -F/ 'NF==1{print $1} NF>=2{print $1"/"$2 (NF>2?"/…":"")}' \
    | sort -u | head -"$MAX_TREE_LINES" | sed 's/^/- /'
  total=$(git ls-files 2>/dev/null | wc -l | tr -d ' ')
  echo "(총 추적 파일 수: $total)"
else
  find . -maxdepth 2 -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/.venv/*' \
    | head -"$MAX_TREE_LINES" | sed 's|^\./||; s/^/- /'
fi
echo ""

# ---------------------------------------------------------------
# 3. Git 상태
# ---------------------------------------------------------------
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "## Git 상태"
  cur_branch=$(git branch --show-current 2>/dev/null)
  echo "- 현재 브랜치: ${cur_branch:-detached HEAD ($(git rev-parse --short HEAD 2>/dev/null))}"
  echo "- 최근 커밋:"
  git log --oneline -"$MAX_COMMITS" 2>/dev/null | sed 's/^/  - /'
  changed=$(git status --porcelain 2>/dev/null | head -"$MAX_CHANGED")
  if [ -n "$changed" ]; then
    echo "- 커밋되지 않은 변경사항:"
    echo "$changed" | sed 's/^/  - /'
  else
    echo "- 작업 트리 깨끗함"
  fi
  echo ""
fi

# ---------------------------------------------------------------
# 4. 자동 생성 프로젝트 문서 (.claude/project-context.md) 주입 및 신선도 검사
#    CLAUDE.md는 사용자 소유 지침 파일이므로 절대 자동 수정 대상이 아니다.
#    자동 생성 컨텍스트는 별도 파일에 두고, 여기서 직접 주입한다.
# ---------------------------------------------------------------
CTX_FILE=".claude/project-context.md"
MAX_CTX_LINES=250

echo "## 프로젝트 문서 상태"
if [ -f CLAUDE.md ]; then
  echo "- CLAUDE.md 존재: 이 파일은 **사용자가 관리하는 지침 파일**입니다. 자동 생성/갱신 대상이 아니며, 사용자가 명시적으로 요청하지 않는 한 절대 수정하지 마세요."
fi

if [ -f "$CTX_FILE" ]; then
  # 신선도 검사 — 커서의 머클 트리 비교처럼 "지금 작업 트리의 실제 내용"이
  # 문서 생성 시점과 같은지를 본다. 커밋·롤백·리베이스·브랜치 전환·미커밋
  # 변경 전부에 실시간으로 반응하며, 롤백으로 문서 시점 상태로 돌아오면
  # 지문이 다시 일치하므로 불필요한 갱신도 일어나지 않는다.
  #   1) 지문(구조적 파일 내용 해시 + 디렉터리 구조 해시) 불일치 → 즉시 갱신
  #   2) 지문 일치 시: 20커밋 백스톱 (컨벤션 등 점진적 드리프트용)
  #   3) 최신이어도 미세 갱신 규칙(발견한 불일치만 즉시 수정)은 항상 주입
  refresh_instructed=""
  FP_HELPER="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/context-fingerprint.sh"
  if [ -x "$FP_HELPER" ]; then
    # 비교 로직은 지문 생성기의 --changed 모드에 일원화되어 있다 (여기서 재구현 금지).
    # 종료 코드 3 = 비교 불가(해시 도구/마커 없음) — 이때 "검증됨"이라고 주장하면 안 된다.
    changed=$("$FP_HELPER" --changed "$CTX_FILE" 2>/dev/null)
    fp_rc=$?
    if [ "$fp_rc" -eq 3 ]; then
      echo "- 지문 검증 불가(해시 도구 또는 지문 마커 없음). 문서 신선도가 보장되지 않으니, 문서의 명령어·구조 정보는 사용 전에 실제 파일로 확인하세요. 다음 갱신 시 context-fingerprint.sh 출력을 마커로 기록하세요."
    elif [ -n "$changed" ]; then
      echo "- ⚠️ 구조적 상태가 문서 생성 시점과 다릅니다 (작업 트리 실시간 비교 — 미커밋 변경·롤백 포함). 달라진 항목:"
      echo "$changed" | sed 's/^/  - /'
      echo "- 신뢰 제한: 위 항목과 관련된 아래 문서 내용(명령어·스택·구조)은 이번 작업 중에도 신뢰하지 말고 실제 파일을 확인하세요."
      echo "- 자동 갱신 지시: 사용자의 현재 요청을 먼저 완료한 뒤, 같은 턴에서 사용자에게 묻지 말고 context-refresh 스킬 절차에 따라 위 항목과 관련된 섹션만 $CTX_FILE 에서 조용히 갱신하세요. 단, 파일 쓰기가 불가능하거나 부적절한 세션(plan 모드, 읽기 전용 검토)이면 갱신을 건너뛰세요 — 다음 쓰기 가능한 세션에서 자동으로 다시 감지됩니다. CLAUDE.md는 건드리지 마세요. 갱신했다면 최종 보고 끝에 '프로젝트 문서를 최신화했다'는 한 줄만 덧붙이세요."
      refresh_instructed=1
    else
      echo "- 자동 생성 문서가 현재 작업 트리와 일치합니다 (실시간 지문 검증됨)."
    fi
  else
    echo "- 지문 생성기(context-fingerprint.sh)가 없습니다. 문서 신선도가 보장되지 않으니 문서 정보는 실제 파일로 확인하세요."
  fi

  # 커밋 백스톱: 지문으로 못 잡는 점진적 드리프트(컨벤션 변화 등)용
  if [ -z "$refresh_instructed" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    gen_commit=$(sed -n 's/.*generated-at-commit: *\([0-9a-f]\{7,40\}\).*/\1/p' "$CTX_FILE" | head -1)
    if [ -n "$gen_commit" ] && git cat-file -e "$gen_commit" 2>/dev/null; then
      commits_since=$(git rev-list --count "$gen_commit"..HEAD 2>/dev/null || echo 0)
      if [ "${commits_since:-0}" -gt 20 ]; then
        echo "- ⚠️ 문서 생성 후 커밋이 ${commits_since}개 쌓였습니다. 구조는 같아도 컨벤션·패턴이 달라졌을 수 있습니다."
        echo "- 자동 갱신 지시: 사용자의 현재 요청을 먼저 완료한 뒤, 같은 턴에서 사용자에게 묻지 말고 context-refresh 스킬 절차에 따라 $CTX_FILE 을 조용히 갱신하세요. 단, 파일 쓰기가 불가능하거나 부적절한 세션(plan 모드, 읽기 전용 검토)이면 갱신을 건너뛰세요. CLAUDE.md는 건드리지 마세요. 갱신했다면 최종 보고 끝에 '프로젝트 문서를 최신화했다'는 한 줄만 덧붙이세요."
        refresh_instructed=1
      fi
    elif [ -n "$gen_commit" ]; then
      # 리베이스·스쿼시 머지로 마커 커밋이 히스토리에서 사라진 경우.
      # 지문이 구조 변경은 계속 감지하므로 강제 갱신은 하지 않되, 상태를 정직하게 알린다.
      echo "- 참고: 문서의 기준 커밋($gen_commit)이 현재 히스토리에 없습니다(리베이스/스쿼시 머지 추정). 구조 변경은 지문으로 계속 감지되지만 커밋 백스톱은 동작하지 않으니, 다음 문서 갱신 때 마커가 자동 재기록됩니다."
    fi
  fi

  if [ -z "$refresh_instructed" ]; then
    echo "- 미세 갱신 규칙: 이번 세션 작업 중 아래 문서와 실제 코드가 다른 부분을 발견하면, 작업 완료 후 사용자에게 묻지 말고 해당 부분만 조용히 고치고 마커(generated-at-commit, 지문 블록)를 갱신하세요. 불일치를 발견하지 못했으면 아무것도 하지 마세요."
  fi
  echo ""
  echo "### 자동 생성된 프로젝트 문서 ($CTX_FILE)"
  # 마커 블록(해시 목록·메타 주석)은 Claude에게 의미 없는 노이즈이므로 제거하고 주입.
  # 줄 단위 필터를 쓴다 — sed 범위 삭제는 블록 끝 표식이 깨져 있으면
  # 문서 전체를 조용히 삭제해버리므로 절대 사용하지 않는다.
  doc_body=$(grep -vE '^<!--|^[0-9a-f]{64} |^context-fingerprint-end -->' "$CTX_FILE")
  total_lines=$(printf '%s\n' "$doc_body" | wc -l | tr -d ' ')
  printf '%s\n' "$doc_body" | head -"$MAX_CTX_LINES"
  if [ "$total_lines" -gt "$MAX_CTX_LINES" ]; then
    echo "(주의: 문서가 ${MAX_CTX_LINES}줄에서 잘렸습니다 — $((total_lines - MAX_CTX_LINES))줄 생략. 완전한 내용이 필요하면 $CTX_FILE 을 직접 읽으세요.)"
  fi
else
  echo "- ⚠️ 자동 생성 프로젝트 문서($CTX_FILE) 없음."
  echo "- 자동 생성 지시: 사용자의 현재 요청을 먼저 완료한 뒤, 같은 턴에서 사용자에게 묻지 말고 project-onboard 스킬 절차에 따라 $CTX_FILE 을 조용히 생성하세요. CLAUDE.md는 절대 건드리지 마세요. 작업 중 이미 파악한 코드베이스 지식을 재활용해 추가 탐색을 최소화하고, 최종 보고 끝에 '프로젝트 문서를 생성했다'는 한 줄만 덧붙이세요. 건너뛰기 조건: 사용자의 요청이 코드베이스와 무관하거나, 읽기 전용 검토·분석·질문·계획 수립만 요청된 세션이거나, plan 모드인 경우 생성하지 마세요 — 이런 세션에서 파일을 만드는 것은 사용자 의도 위반입니다."
fi
echo "</project-context-snapshot>"

exit 0
