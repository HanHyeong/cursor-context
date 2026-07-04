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
echo "자동 생성된 프로젝트 스냅샷입니다. 아래 정보를 바탕으로 별도 탐색 없이 프로젝트 맥락을 파악하세요."
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
  echo "- 현재 브랜치: $(git branch --show-current 2>/dev/null || echo 'detached HEAD')"
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
  # 신선도 검사: 파일 상단의 generated-at-commit 마커 기준
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    gen_commit=$(sed -n 's/.*generated-at-commit: *\([0-9a-f]\{7,40\}\).*/\1/p' "$CTX_FILE" | head -1)
    if [ -n "$gen_commit" ] && git cat-file -e "$gen_commit" 2>/dev/null; then
      commits_since=$(git rev-list --count "$gen_commit"..HEAD 2>/dev/null || echo 0)
      echo "- 자동 생성 문서 존재 (생성 시점 이후 커밋 수: $commits_since)"
      if [ "${commits_since:-0}" -gt 20 ]; then
        echo "- ⚠️ 자동 생성 문서가 오래되었습니다 (내용이 실제 코드와 다를 수 있으니 맹신하지 마세요)."
        echo "- 자동 갱신 지시: 사용자의 현재 요청을 먼저 완료한 뒤, 같은 턴에서 사용자에게 묻지 말고 context-refresh 스킬 절차에 따라 $CTX_FILE 을 조용히 갱신하세요. CLAUDE.md는 건드리지 마세요. 최종 보고 끝에 '프로젝트 문서를 최신화했다'는 한 줄만 덧붙이세요."
      fi
    else
      echo "- 자동 생성 문서 존재 (신선도 마커 없음)"
    fi
  fi
  echo ""
  echo "### 자동 생성된 프로젝트 문서 ($CTX_FILE)"
  head -"$MAX_CTX_LINES" "$CTX_FILE"
else
  echo "- ⚠️ 자동 생성 프로젝트 문서($CTX_FILE) 없음."
  echo "- 자동 생성 지시: 사용자의 현재 요청을 먼저 완료한 뒤, 같은 턴에서 사용자에게 묻지 말고 project-onboard 스킬 절차에 따라 $CTX_FILE 을 조용히 생성하세요. CLAUDE.md는 절대 건드리지 마세요. 작업 중 이미 파악한 코드베이스 지식을 재활용해 추가 탐색을 최소화하고, 최종 보고 끝에 '프로젝트 문서를 생성했다'는 한 줄만 덧붙이세요. 단, 사용자의 요청이 코드베이스와 무관한 단순 질문이면 생성을 건너뛰세요."
fi
echo "</project-context-snapshot>"

exit 0
