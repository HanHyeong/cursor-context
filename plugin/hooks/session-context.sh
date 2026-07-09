#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_<lang>_<key> 변수들은 msg()의 ${!varname} 간접 참조로만 쓰인다
# SessionStart 훅: 세션 시작 시 프로젝트 스냅샷을 Claude의 컨텍스트로 자동 주입한다.
# 커서 IDE가 프로젝트를 자동 인덱싱하듯, Claude가 첫 질문 전에 이미
# 스택 / 구조 / 최근 변경사항을 알고 시작하게 만드는 것이 목적.
#
# stdout으로 출력한 내용은 Claude Code가 세션 컨텍스트에 추가한다.
# 실패해도 세션을 막지 않도록 항상 exit 0.

set -u
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0
# 이 스크립트 자신이 어디 있는지로 형제 스크립트(예: context-fingerprint.sh,
# lib-config.sh)를 찾는다 — install.sh 배치($CLAUDE_PROJECT_DIR/.claude/hooks/)와
# 플러그인 배치($CLAUDE_PLUGIN_ROOT/hooks/) 둘 다에서 항상 옳다. 계산 실패 시에만
# 예전 방식(프로젝트 루트 기준 고정 경로)으로 폴백한다.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
[ -n "$HOOK_DIR" ] || HOOK_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks"


# 출력량 제한 (컨텍스트 낭비 방지)
MAX_TREE_LINES=60
MAX_COMMITS=5
MAX_CHANGED=20

# 기본값을 먼저 설정한 뒤 .cursor-context/config가 있으면 그 값으로 덮어쓴다
# (lib-config.sh가 없거나 로드 실패해도 아래 기본값으로 정상 동작한다).
COMMIT_BACKSTOP=20
DOC_LINE_BUDGET=200
FEEDBACK_THRESHOLD=5
METRICS_THRESHOLD=300
CTX_LANG=en
# shellcheck disable=SC1091
. "$HOOK_DIR/lib-config.sh" 2>/dev/null || true
MAX_CTX_LINES=$((DOC_LINE_BUDGET + 50))

# ${!varname} 간접 참조로 언어별 메시지를 고른다 (bash 3.2도 지원 — macOS 기본 bash 호환).
msg() {
  key="$1"
  varname="MSG_${CTX_LANG}_${key}"
  # 번역 누락 시 영어로 폴백하고, 그것도 없으면 빈 문자열을 낸다 —
  # set -u 환경에서 미정의 키의 간접 참조가 스크립트를 죽이지 못하게 한다.
  [ -n "${!varname-}" ] || varname="MSG_en_${key}"
  printf '%s' "${!varname-}"
}
# --는 printf에게 "다음부터는 옵션이 아니라 인자"라고 알린다. 이게 없으면
# "- 현재 브랜치: %s"처럼 대시로 시작하는 포맷 문자열을 옵션 플래그로
# 오인해 "invalid option" 에러가 난다.
# shellcheck disable=SC2059
msgf() { printf -- "$(msg "$1")\n" "${@:2}"; }

MSG_en_intro_note="This is an auto-generated project snapshot. Use it as a starting point for grasping project context and interpreting terse requests."
MSG_ko_intro_note="자동 생성된 프로젝트 스냅샷입니다. 프로젝트 맥락 파악과 간결한 요청의 의도 해석에 출발점으로 사용하세요."
MSG_en_priority_rule="Priority rules: (1) this snapshot/doc is auxiliary information -- if it disagrees with the actual code, the actual code always wins. (2) if it overlaps or conflicts with user instructions (CLAUDE.md), CLAUDE.md always wins."
MSG_ko_priority_rule="우선순위 규칙: (1) 이 스냅샷·문서는 보조 정보다 — 실제 코드와 다르면 항상 실제 코드가 우선이다. (2) 사용자 지침(CLAUDE.md)과 겹치거나 충돌하면 항상 CLAUDE.md가 우선이다."
MSG_en_stack_header="## Tech stack"
MSG_ko_stack_header="## 기술 스택"
MSG_en_node_project="- Node.js project (package.json)"
MSG_ko_node_project="- Node.js 프로젝트 (package.json)"
MSG_en_pkg_mgr="  - package manager: %s"
MSG_ko_pkg_mgr="  - 패키지 매니저: %s"
MSG_en_framework="  - framework/tool: %s"
MSG_ko_framework="  - 프레임워크/도구: %s"
MSG_en_scripts_header="  - available scripts:"
MSG_ko_scripts_header="  - 사용 가능한 스크립트:"
MSG_en_python_pyproject="- Python project (pyproject.toml)"
MSG_ko_python_pyproject="- Python 프로젝트 (pyproject.toml)"
MSG_en_python_requirements="- Python project (requirements.txt)"
MSG_ko_python_requirements="- Python 프로젝트 (requirements.txt)"
MSG_en_go_project="- Go project (go.mod: %s)"
MSG_ko_go_project="- Go 프로젝트 (go.mod: %s)"
MSG_en_rust_project="- Rust project (Cargo.toml)"
MSG_ko_rust_project="- Rust 프로젝트 (Cargo.toml)"
MSG_en_java_maven="- Java/Maven project"
MSG_ko_java_maven="- Java/Maven 프로젝트"
MSG_en_java_gradle="- Java/Kotlin (Gradle) project"
MSG_ko_java_gradle="- Java·Kotlin/Gradle 프로젝트"
MSG_en_ruby_project="- Ruby project (Gemfile)"
MSG_ko_ruby_project="- Ruby 프로젝트 (Gemfile)"
MSG_en_php_project="- PHP project (composer.json)"
MSG_ko_php_project="- PHP 프로젝트 (composer.json)"
MSG_en_dockerfile="- Dockerfile present"
MSG_ko_dockerfile="- Dockerfile 존재"
MSG_en_docker_compose="- Docker Compose config present"
MSG_ko_docker_compose="- Docker Compose 구성 존재"
MSG_en_gha_ci="- GitHub Actions CI config present (%s)"
MSG_ko_gha_ci="- GitHub Actions CI 구성 존재 (%s)"
MSG_en_no_manifest="- No known manifest file (needs direct exploration)"
MSG_ko_no_manifest="- 알려진 매니페스트 파일 없음 (직접 탐색 필요)"
MSG_en_dir_structure_header="## Directory structure (depth 2, tracked files)"
MSG_ko_dir_structure_header="## 디렉터리 구조 (깊이 2, 추적 파일 기준)"
MSG_en_tracked_total="(total tracked files: %s)"
MSG_ko_tracked_total="(총 추적 파일 수: %s)"
MSG_en_git_status_header="## Git status"
MSG_ko_git_status_header="## Git 상태"
MSG_en_current_branch="- Current branch: %s"
MSG_ko_current_branch="- 현재 브랜치: %s"
MSG_en_recent_commits="- Recent commits:"
MSG_ko_recent_commits="- 최근 커밋:"
MSG_en_uncommitted_changes="- Uncommitted changes:"
MSG_ko_uncommitted_changes="- 커밋되지 않은 변경사항:"
MSG_en_omitted_count="  (...%s more omitted...)"
MSG_ko_omitted_count="  (…%s건 생략…)"
MSG_en_clean_tree="- Working tree clean"
MSG_ko_clean_tree="- 작업 트리 깨끗함"
MSG_en_branch_intent="- This branch's accumulated work vs. the default branch (%s) (useful for interpreting terse requests):"
MSG_ko_branch_intent="- 기본 브랜치(%s) 대비 이 브랜치의 누적 작업 (간결한 요청의 의도 파악에 참고):"
MSG_en_truncated_middle="  (...omitted...)"
MSG_ko_truncated_middle="  (…중략…)"
MSG_en_doc_status_header="## Project doc status"
MSG_ko_doc_status_header="## 프로젝트 문서 상태"
MSG_en_claude_md_notice="- CLAUDE.md present: this file is a **user-managed instruction file**. It is not an auto-generation/refresh target -- never modify it unless the user explicitly asks."
MSG_ko_claude_md_notice="- CLAUDE.md 존재: 이 파일은 **사용자가 관리하는 지침 파일**입니다. 자동 생성/갱신 대상이 아니며, 사용자가 명시적으로 요청하지 않는 한 절대 수정하지 마세요."
MSG_en_fp_unverifiable_snapshot="- Fingerprint verification unavailable (no hash tool, or no fingerprint marker). Doc freshness is not guaranteed, so verify the doc's commands/structure against the real files before relying on them. Record context-fingerprint.sh's output as the marker on the next refresh."
MSG_ko_fp_unverifiable_snapshot="- 지문 검증 불가(해시 도구 또는 지문 마커 없음). 문서 신선도가 보장되지 않으니, 문서의 명령어·구조 정보는 사용 전에 실제 파일로 확인하세요. 다음 갱신 시 context-fingerprint.sh 출력을 마커로 기록하세요."
MSG_en_structural_diverged="- The structural state has diverged from when the doc was generated (live working-tree comparison -- includes uncommitted changes/rollbacks). Changed items:"
MSG_ko_structural_diverged="- ⚠️ 구조적 상태가 문서 생성 시점과 다릅니다 (작업 트리 실시간 비교 — 미커밋 변경·롤백 포함). 달라진 항목:"
MSG_en_trust_limit="- Trust limit: do not rely on the doc content related to the items above (commands/stack/structure) even during this task -- check the real files."
MSG_ko_trust_limit="- 신뢰 제한: 위 항목과 관련된 아래 문서 내용(명령어·스택·구조)은 이번 작업 중에도 신뢰하지 말고 실제 파일을 확인하세요."
MSG_en_auto_refresh_partial="- Auto-refresh instruction: finish the user's current request first, then in the same turn, without asking the user, quietly refresh only the sections of %s related to the items above via the context-refresh skill procedure. If writing is impossible or inappropriate in this session (plan mode, read-only review), skip the refresh -- it will be detected again automatically in the next writable session. Do not touch CLAUDE.md. If you refreshed it, append a one-line note like 'refreshed the project doc' at the end of your final report."
MSG_ko_auto_refresh_partial="- 자동 갱신 지시: 사용자의 현재 요청을 먼저 완료한 뒤, 같은 턴에서 사용자에게 묻지 말고 context-refresh 스킬 절차에 따라 위 항목과 관련된 섹션만 %s 에서 조용히 갱신하세요. 단, 파일 쓰기가 불가능하거나 부적절한 세션(plan 모드, 읽기 전용 검토)이면 갱신을 건너뛰세요 — 다음 쓰기 가능한 세션에서 자동으로 다시 감지됩니다. CLAUDE.md는 건드리지 마세요. 갱신했다면 최종 보고 끝에 '프로젝트 문서를 최신화했다'는 한 줄만 덧붙이세요."
MSG_en_doc_matches="- The auto-generated doc matches the current working tree (live fingerprint verified)."
MSG_ko_doc_matches="- 자동 생성 문서가 현재 작업 트리와 일치합니다 (실시간 지문 검증됨)."
MSG_en_no_fp_generator="- No fingerprint generator (context-fingerprint.sh). Doc freshness is not guaranteed -- verify doc info against the real files."
MSG_ko_no_fp_generator="- 지문 생성기(context-fingerprint.sh)가 없습니다. 문서 신선도가 보장되지 않으니 문서 정보는 실제 파일로 확인하세요."
MSG_en_commits_since_notice="- %s commits have accumulated since the doc was generated. Structure may be unchanged, but conventions/patterns may have shifted."
MSG_ko_commits_since_notice="- ⚠️ 문서 생성 후 커밋이 %s개 쌓였습니다. 구조는 같아도 컨벤션·패턴이 달라졌을 수 있습니다."
MSG_en_auto_refresh_full="- Auto-refresh instruction: finish the user's current request first, then in the same turn, without asking the user, quietly refresh %s via the context-refresh skill procedure. If writing is impossible or inappropriate in this session (plan mode, read-only review), skip it. Do not touch CLAUDE.md. If you refreshed it, append a one-line note like 'refreshed the project doc' at the end of your final report."
MSG_ko_auto_refresh_full="- 자동 갱신 지시: 사용자의 현재 요청을 먼저 완료한 뒤, 같은 턴에서 사용자에게 묻지 말고 context-refresh 스킬 절차에 따라 %s 을 조용히 갱신하세요. 단, 파일 쓰기가 불가능하거나 부적절한 세션(plan 모드, 읽기 전용 검토)이면 갱신을 건너뛰세요. CLAUDE.md는 건드리지 마세요. 갱신했다면 최종 보고 끝에 '프로젝트 문서를 최신화했다'는 한 줄만 덧붙이세요."
MSG_en_gen_commit_missing="- Note: the doc's baseline commit (%s) is not in the current history (likely a rebase/squash merge). Structural changes are still caught by the fingerprint, but the commit backstop won't work until the marker is re-recorded on the next doc refresh."
MSG_ko_gen_commit_missing="- 참고: 문서의 기준 커밋(%s)이 현재 히스토리에 없습니다(리베이스/스쿼시 머지 추정). 구조 변경은 지문으로 계속 감지되지만 커밋 백스톱은 동작하지 않으니, 다음 문서 갱신 때 마커가 자동 재기록됩니다."
MSG_en_micro_update_rule="- Micro-update rule: if you notice during this session's work that part of the doc below differs from the real code, quietly fix just that part after finishing the task (without asking the user) and refresh the markers (generated-at-commit, fingerprint block). If you find no discrepancy, do nothing."
MSG_ko_micro_update_rule="- 미세 갱신 규칙: 이번 세션 작업 중 아래 문서와 실제 코드가 다른 부분을 발견하면, 작업 완료 후 사용자에게 묻지 말고 해당 부분만 조용히 고치고 마커(generated-at-commit, 지문 블록)를 갱신하세요. 불일치를 발견하지 못했으면 아무것도 하지 마세요."
MSG_en_learning_rule="- Learning-log rule: if this session (a) fixed something wrong in the doc below, or (b) needed substantial exploration for a topic missing from the doc, append one JSON line of the form {\"type\":\"wrong\"|\"gap\",\"area\":\"topic\",\"note\":\"one-line description\"} to .cursor-context/context-feedback.jsonl after finishing the task. Do not log anything if neither applies."
MSG_ko_learning_rule="- 학습 기록 규칙: 이번 세션에서 (a) 아래 문서가 틀려서 고쳤거나 (b) 문서에 없어서 상당한 탐색이 필요했던 주제가 있으면, 작업 완료 후 .cursor-context/context-feedback.jsonl 에 {\"type\":\"wrong\"|\"gap\",\"area\":\"주제\",\"note\":\"한 줄 설명\"} 형식의 JSON 한 줄을 추가하세요. 해당 없으면 기록하지 마세요."
MSG_en_evolve_instruction="- Evolve instruction: enough usage signal has accumulated (%s feedback entries, %s metric lines). Finish the user's current request first, then in the same turn, without asking, run the context-evolve skill to improve the doc. If writing is impossible or inappropriate in this session (plan mode, read-only review), skip it."
MSG_ko_evolve_instruction="- 진화 지시: 사용 신호가 충분히 쌓였습니다 (피드백 %s건, 메트릭 %s건). 사용자의 현재 요청을 먼저 완료한 뒤, 같은 턴에서 묻지 말고 context-evolve 스킬을 실행해 문서를 개선하세요. 단, 파일 쓰기가 불가능하거나 부적절한 세션(plan 모드, 읽기 전용 검토)이면 건너뛰세요."
MSG_en_doc_section_header="### Auto-generated project doc (%s)"
MSG_ko_doc_section_header="### 자동 생성된 프로젝트 문서 (%s)"
MSG_en_doc_truncated_notice="(Note: the doc was truncated at %s lines -- %s lines omitted. Read %s directly if you need the full content.)"
MSG_ko_doc_truncated_notice="(주의: 문서가 %s줄에서 잘렸습니다 — %s줄 생략. 완전한 내용이 필요하면 %s 을 직접 읽으세요.)"
MSG_en_doc_missing_snapshot="- No auto-generated project doc (%s)."
MSG_ko_doc_missing_snapshot="- ⚠️ 자동 생성 프로젝트 문서(%s) 없음."
MSG_en_doc_gen_instruction="- Auto-generation instruction: finish the user's current request first, then in the same turn, without asking the user, quietly generate %s via the project-onboard skill procedure. Never touch CLAUDE.md. Reuse codebase knowledge already gathered during this task to minimize extra exploration, and append a one-line note like 'generated the project doc' at the end of your final report."
MSG_ko_doc_gen_instruction="- 자동 생성 지시: 사용자의 현재 요청을 먼저 완료한 뒤, 같은 턴에서 사용자에게 묻지 말고 project-onboard 스킬 절차에 따라 %s 을 조용히 생성하세요. CLAUDE.md는 절대 건드리지 마세요. 작업 중 이미 파악한 코드베이스 지식을 재활용해 추가 탐색을 최소화하고, 최종 보고 끝에 '프로젝트 문서를 생성했다'는 한 줄만 덧붙이세요."
MSG_en_doc_gen_when="  - When to generate: sessions that did code-change work, and sessions where the user asked about the project itself (what/structure/stack/commands/architecture) and it was already answered via exploration -- that exploration knowledge already exists, so keep it as a doc instead of discarding it."
MSG_ko_doc_gen_when="  - 생성하는 경우: 코드 변경 작업을 수행한 세션, 그리고 사용자가 프로젝트 자체(무엇인지·구조·스택·명령어·아키텍처)를 질문해 이미 탐색으로 답한 세션 — 탐색 지식이 이미 있으므로 버리지 말고 문서로 남기세요."
MSG_en_doc_gen_skip="  - When to skip: the request is unrelated to the codebase, writing is impossible or inappropriate (e.g. plan mode), or the session was pure code review/PR review."
MSG_ko_doc_gen_skip="  - 건너뛰는 경우: 요청이 코드베이스와 무관하거나, plan 모드 등 파일 쓰기가 불가능·부적절하거나, 순수 코드 리뷰/PR 검토만 요청된 세션."

# 진화 게이트(evolve-gate.sh) sentinel 정리. sentinel은 세션당 최대 1회 차단을
# 보장하는 장치라 세션이 끝나면 정리 대상이다. mtime +1(1일 초과)만 지워
# 같은 세션 안의 compact 이벤트(SessionStart가 startup|clear|compact에서 모두
# 실행됨)에서 방금 만든 sentinel이 지워지는 일을 방지한다.
find .cursor-context -maxdepth 1 -name '.gate-fired-*' -mtime +1 -delete 2>/dev/null

echo "<project-context-snapshot>"
msg intro_note; echo ""
msg priority_rule; echo ""
echo ""

# ---------------------------------------------------------------
# 1. 기술 스택 감지
# ---------------------------------------------------------------
msg stack_header; echo ""
detected=0

if [ -f package.json ]; then
  detected=1
  msg node_project; echo ""
  # 패키지 매니저 감지
  [ -f pnpm-lock.yaml ] && msgf pkg_mgr pnpm
  [ -f yarn.lock ] && msgf pkg_mgr yarn
  [ -f package-lock.json ] && msgf pkg_mgr npm
  [ -f bun.lockb ] || [ -f bun.lock ] && msgf pkg_mgr bun
  # 주요 프레임워크 감지 (dependencies 문자열 검색, jq 불필요)
  for fw in react next vue nuxt svelte @angular/core express fastify nestjs vite; do
    grep -q "\"$fw\"" package.json 2>/dev/null && msgf framework "$fw"
  done
  # npm scripts 목록
  if command -v node >/dev/null 2>&1; then
    # 이 안의 ${k}/${v}는 셸이 아니라 JS 템플릿 리터럴이다. node -e에 넘길
    # 문자열이므로 작은따옴표로 셸 확장을 막아야 한다.
    # shellcheck disable=SC2016
    scripts=$(node -e 'const s=require("./package.json").scripts||{};Object.entries(s).forEach(([k,v])=>console.log(`  - npm run ${k}: ${v}`))' 2>/dev/null | head -15)
    if [ -n "$scripts" ]; then
      msg scripts_header; echo ""
      # 여러 줄 각각의 맨 앞에 접두어를 붙이는 작업이라
      # ${var//search/replace}로는 안 되고(줄별 ^ 앵커 불가) sed가 맞다.
      # shellcheck disable=SC2001
      echo "$scripts" | sed 's/^/  /'
    fi
  fi
fi

[ -f pyproject.toml ] && detected=1 && { msg python_pyproject; echo ""; }
[ -f requirements.txt ] && detected=1 && { msg python_requirements; echo ""; }
[ -f go.mod ] && detected=1 && msgf go_project "$(head -1 go.mod)"
[ -f Cargo.toml ] && detected=1 && { msg rust_project; echo ""; }
[ -f pom.xml ] && detected=1 && { msg java_maven; echo ""; }
{ [ -f build.gradle ] || [ -f build.gradle.kts ]; } && detected=1 && { msg java_gradle; echo ""; }
[ -f Gemfile ] && detected=1 && { msg ruby_project; echo ""; }
[ -f composer.json ] && detected=1 && { msg php_project; echo ""; }
[ -f Dockerfile ] && { msg dockerfile; echo ""; }
{ [ -f docker-compose.yml ] || [ -f docker-compose.yaml ] || [ -f compose.yaml ]; } && { msg docker_compose; echo ""; }
if ls .github/workflows/*.yml .github/workflows/*.yaml >/dev/null 2>&1; then
  wf_names=""
  for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$wf" ] && wf_names="$wf_names $(basename "$wf")"
  done
  msgf gha_ci "$wf_names"
fi

[ "$detected" -eq 0 ] && { msg no_manifest; echo ""; }
echo ""

# ---------------------------------------------------------------
# 2. 디렉터리 구조 (git 추적 파일 기준, 깊이 2)
# ---------------------------------------------------------------
msg dir_structure_header; echo ""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git ls-files 2>/dev/null \
    | awk -F/ 'NF==1{print $1} NF>=2{print $1"/"$2 (NF>2?"/…":"")}' \
    | sort -u | head -"$MAX_TREE_LINES" | sed 's/^/- /'
  total=$(git ls-files 2>/dev/null | wc -l | tr -d ' ')
  msgf tracked_total "$total"
else
  find . -maxdepth 2 -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/.venv/*' \
    | head -"$MAX_TREE_LINES" | sed 's|^\./||; s/^/- /'
fi
echo ""

# ---------------------------------------------------------------
# 3. Git 상태
# ---------------------------------------------------------------
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  msg git_status_header; echo ""
  cur_branch=$(git branch --show-current 2>/dev/null)
  msgf current_branch "${cur_branch:-detached HEAD ($(git rev-parse --short HEAD 2>/dev/null))}"
  msg recent_commits; echo ""
  git log --oneline -"$MAX_COMMITS" 2>/dev/null | sed 's/^/  - /'
  changed=$(git status --porcelain 2>/dev/null)
  if [ -n "$changed" ]; then
    changed_total=$(printf '%s\n' "$changed" | wc -l | tr -d ' ')
    msg uncommitted_changes; echo ""
    printf '%s\n' "$changed" | head -"$MAX_CHANGED" | sed 's/^/  - /'
    if [ "$changed_total" -gt "$MAX_CHANGED" ]; then
      msgf omitted_count "$((changed_total - MAX_CHANGED))"
    fi
  else
    msg clean_tree; echo ""
  fi

  # 기본 브랜치 대비 이 브랜치의 누적 작업 — "계속해줘", "이거 마무리해줘" 같은
  # 간결한 프롬프트의 의도를 특정하는 가장 강한 신호다.
  db=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
  db=${db#origin/}
  if [ -z "$db" ]; then
    for cand in main master; do
      if git show-ref --verify -q "refs/remotes/origin/$cand" || git show-ref --verify -q "refs/heads/$cand"; then
        db=$cand; break
      fi
    done
  fi
  if [ -n "$db" ] && [ -n "$cur_branch" ] && [ "$cur_branch" != "$db" ]; then
    base=""
    if git show-ref --verify -q "refs/remotes/origin/$db"; then base="origin/$db"
    elif git show-ref --verify -q "refs/heads/$db"; then base="$db"; fi
    if [ -n "$base" ]; then
      diffstat=$(git diff --stat "$base"...HEAD 2>/dev/null)
      if [ -n "$diffstat" ]; then
        msgf branch_intent "$base"
        nl=$(printf '%s\n' "$diffstat" | wc -l | tr -d ' ')
        if [ "$nl" -gt 12 ]; then
          printf '%s\n' "$diffstat" | head -10 | sed 's/^/  /'
          msg truncated_middle; echo ""
          printf '%s\n' "$diffstat" | tail -1 | sed 's/^/  /'
        else
          printf '%s\n' "$diffstat" | sed 's/^/  /'
        fi
      fi
    fi
  fi
  echo ""
fi

# ---------------------------------------------------------------
# 4. 자동 생성 프로젝트 문서 (.cursor-context/project-context.md) 주입 및 신선도 검사
#    CLAUDE.md는 사용자 소유 지침 파일이므로 절대 자동 수정 대상이 아니다.
#    자동 생성 컨텍스트는 별도 파일에 두고, 여기서 직접 주입한다.
# ---------------------------------------------------------------
CTX_FILE=".cursor-context/project-context.md"

msg doc_status_header; echo ""
if [ -f CLAUDE.md ]; then
  msg claude_md_notice; echo ""
fi

if [ -f "$CTX_FILE" ]; then
  # 신선도 검사 — 커서의 머클 트리 비교처럼 "지금 작업 트리의 실제 내용"이
  # 문서 생성 시점과 같은지를 본다. 커밋·롤백·리베이스·브랜치 전환·미커밋
  # 변경 전부에 실시간으로 반응하며, 롤백으로 문서 시점 상태로 돌아오면
  # 지문이 다시 일치하므로 불필요한 갱신도 일어나지 않는다.
  #   1) 지문(구조적 파일 내용 해시 + 디렉터리 구조 해시) 불일치 → 즉시 갱신
  #   2) 지문 일치 시: COMMIT_BACKSTOP 커밋 백스톱 (컨벤션 등 점진적 드리프트용)
  #   3) 최신이어도 미세 갱신 규칙(발견한 불일치만 즉시 수정)은 항상 주입
  refresh_instructed=""
  FP_HELPER="$HOOK_DIR/context-fingerprint.sh"
  if [ -x "$FP_HELPER" ]; then
    # 비교 로직은 지문 생성기의 --changed 모드에 일원화되어 있다 (여기서 재구현 금지).
    # 종료 코드 3 = 비교 불가(해시 도구/마커 없음) — 이때 "검증됨"이라고 주장하면 안 된다.
    changed=$("$FP_HELPER" --changed "$CTX_FILE" 2>/dev/null)
    fp_rc=$?
    if [ "$fp_rc" -eq 3 ]; then
      msg fp_unverifiable_snapshot; echo ""
    elif [ -n "$changed" ]; then
      msg structural_diverged; echo ""
      # 여러 줄 각각에 접두어를 붙이는 작업이라
      # ${var//search/replace}로는 안 되고(줄별 ^ 앵커 불가) sed가 맞다.
      # shellcheck disable=SC2001
      echo "$changed" | sed 's/^/  - /'
      msg trust_limit; echo ""
      msgf auto_refresh_partial "$CTX_FILE"
      refresh_instructed=1
    else
      msg doc_matches; echo ""
    fi
  else
    msg no_fp_generator; echo ""
  fi

  # 커밋 백스톱: 지문으로 못 잡는 점진적 드리프트(컨벤션 변화 등)용
  if [ -z "$refresh_instructed" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    gen_commit=$(sed -n 's/.*generated-at-commit: *\([0-9a-f]\{7,40\}\).*/\1/p' "$CTX_FILE" | head -1)
    if [ -n "$gen_commit" ] && git cat-file -e "$gen_commit" 2>/dev/null; then
      commits_since=$(git rev-list --no-merges --count "$gen_commit"..HEAD 2>/dev/null || echo 0)
      if [ "${commits_since:-0}" -gt "$COMMIT_BACKSTOP" ]; then
        msgf commits_since_notice "$commits_since"
        msgf auto_refresh_full "$CTX_FILE"
        refresh_instructed=1
      fi
    elif [ -n "$gen_commit" ]; then
      # 리베이스·스쿼시 머지로 마커 커밋이 히스토리에서 사라진 경우.
      # 지문이 구조 변경은 계속 감지하므로 강제 갱신은 하지 않되, 상태를 정직하게 알린다.
      msgf gen_commit_missing "$gen_commit"
    fi
  fi

  if [ -z "$refresh_instructed" ]; then
    msg micro_update_rule; echo ""
  fi

  # 자기 평가 루프: 반성(피드백 적재) 규칙은 항상 주입, 진화는 임계값 도달 시만
  msg learning_rule; echo ""
  # 주의: grep -c는 "파일은 있는데 매치 0건"일 때 0을 출력하고 rc=1을 반환하므로
  # `|| echo 0`과 조합하면 "0\n0" 두 줄이 되어 정수 비교가 깨진다. awk로 계수한다.
  fb_count=$(awk 'NF{n++} END{print n+0}' .cursor-context/context-feedback.jsonl 2>/dev/null || echo 0)
  mt_count=$(awk 'NF{n++} END{print n+0}' .cursor-context/metrics.jsonl 2>/dev/null || echo 0)
  if [ -z "$refresh_instructed" ] && { [ "${fb_count:-0}" -ge "$FEEDBACK_THRESHOLD" ] || [ "${mt_count:-0}" -ge "$METRICS_THRESHOLD" ]; }; then
    msgf evolve_instruction "$fb_count" "$mt_count"
  fi
  echo ""
  msgf doc_section_header "$CTX_FILE"; echo ""
  # 마커 블록(해시 목록·메타 주석)은 Claude에게 의미 없는 노이즈이므로 제거하고 주입.
  # 줄 단위 필터를 쓴다 — sed 범위 삭제는 블록 끝 표식이 깨져 있으면
  # 문서 전체를 조용히 삭제해버리므로 절대 사용하지 않는다.
  doc_body=$(grep -vE '^<!--|^[0-9a-f]{64} |^context-fingerprint-end -->' "$CTX_FILE")
  total_lines=$(printf '%s\n' "$doc_body" | wc -l | tr -d ' ')
  printf '%s\n' "$doc_body" | head -"$MAX_CTX_LINES"
  if [ "$total_lines" -gt "$MAX_CTX_LINES" ]; then
    msgf doc_truncated_notice "$MAX_CTX_LINES" "$((total_lines - MAX_CTX_LINES))" "$CTX_FILE"
  fi
else
  msgf doc_missing_snapshot "$CTX_FILE"
  msgf doc_gen_instruction "$CTX_FILE"
  msg doc_gen_when; echo ""
  msg doc_gen_skip; echo ""
fi
echo "</project-context-snapshot>"

exit 0
