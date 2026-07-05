#!/usr/bin/env bash
# cursor-context 설치 스크립트
# 사용법: ./install.sh /path/to/your/project
#
# 대상 프로젝트에 다음을 설치한다:
#   .claude/hooks/  — 훅 6종: 세션 스냅샷, 프롬프트 신선도, 지문 생성기,
#                     메트릭 수집기, 진화 게이트(Stop), 문서 품질 게이트
#   .claude/skills/ — 스킬 3종: project-onboard, context-refresh, context-evolve
#   .claude/settings.json — 훅 4종 등록 (기존 파일이 있으면 자동 병합)
#   (기계 생성 데이터는 런타임에 .cursor-context/ 아래 생성됨)
#
# 비파괴 원칙:
#   - 기존 settings.json은 절대 덮어쓰지 않는다 (예시 파일만 제공).
#   - 동명의 기존 훅·스킬은 내용이 다를 때만 .claude/backup/ 아래로 백업 후 교체.
#     백업 위치는 스킬 탐색 범위(.claude/skills/) 밖이어야 한다 — skills/ 안에
#     백업을 두면 백업본의 SKILL.md가 살아있는 스킬로 중복 등록되어 버린다.
#   - 내용이 동일하면(재설치) 백업을 만들지 않는다 (멱등).

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET=""
NO_ONBOARD=""
for arg in "$@"; do
  case "$arg" in
    --no-onboard) NO_ONBOARD=1 ;;
    *) TARGET="$arg" ;;
  esac
done

if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  echo "사용법: ./install.sh /path/to/your/project [--no-onboard]"
  echo "대상 디렉터리가 존재해야 합니다."
  echo "  --no-onboard: 설치 직후의 즉시 문서 생성(Claude API 사용)을 건너뜁니다."
  exit 1
fi

TARGET="$(cd "$TARGET" && pwd)"
if [ "$TARGET" = "$SRC_DIR" ]; then
  echo "대상이 이 저장소 자신입니다. 설치할 필요가 없습니다."
  exit 0
fi
echo "설치 대상: $TARGET"

mkdir -p "$TARGET/.claude/hooks" "$TARGET/.claude/skills"

# 백업 디렉터리 (필요할 때만 생성). 스킬 탐색 범위 밖에 둔다.
BACKUP_DIR="$TARGET/.claude/backup/install-$(date +%Y%m%d%H%M%S)"
backup_made=""
ensure_backup_dir() {
  if [ -z "$backup_made" ]; then
    mkdir -p "$BACKUP_DIR"
    backup_made=1
  fi
}

# 훅 스크립트: 동명 파일이 있고 내용이 다르면 백업 후 교체.
# 동명이지만 파일이 아닌 것(디렉터리 등)이 있으면 cp가 실패해 설치가 중간에
# 중단되므로, 타입 불일치도 백업으로 옮긴 뒤 설치한다.
for h in session-context.sh context-fingerprint.sh prompt-freshness.sh metrics-collector.sh context-benchmark.sh evolve-gate.sh; do
  dst="$TARGET/.claude/hooks/$h"
  if [ -e "$dst" ] && [ ! -f "$dst" ]; then
    ensure_backup_dir
    mkdir -p "$BACKUP_DIR/hooks"
    mv "$dst" "$BACKUP_DIR/hooks/$h"
    echo "⚠️ 기존 $h (파일이 아님)을 $BACKUP_DIR/hooks/ 로 백업하고 교체합니다."
  elif [ -f "$dst" ] && ! cmp -s "$SRC_DIR/.claude/hooks/$h" "$dst"; then
    ensure_backup_dir
    mkdir -p "$BACKUP_DIR/hooks"
    cp -p "$dst" "$BACKUP_DIR/hooks/$h"
    echo "⚠️ 기존 훅 $h (내용 다름)을 $BACKUP_DIR/hooks/ 에 백업하고 교체합니다."
  fi
  cp "$SRC_DIR/.claude/hooks/$h" "$dst"
  chmod +x "$dst"
  echo "✓ .claude/hooks/$h"
done

# 스킬: 동명 디렉터리가 있고 내용이 다르면 백업 후 교체.
# 백업은 반드시 skills/ 밖으로 이동한다 (스킬 중복 등록 방지).
for s in project-onboard context-refresh context-evolve; do
  dst="$TARGET/.claude/skills/$s"
  if [ -e "$dst" ] && [ ! -d "$dst" ]; then
    ensure_backup_dir
    mkdir -p "$BACKUP_DIR/skills"
    mv "$dst" "$BACKUP_DIR/skills/$s"
    echo "⚠️ 기존 $s (디렉터리가 아님)을 $BACKUP_DIR/skills/ 로 백업하고 교체합니다."
  fi
  if [ -d "$dst" ]; then
    if diff -rq "$SRC_DIR/.claude/skills/$s" "$dst" >/dev/null 2>&1; then
      echo "✓ .claude/skills/$s (기존과 동일 — 변경 없음)"
      continue
    fi
    ensure_backup_dir
    mkdir -p "$BACKUP_DIR/skills"
    mv "$dst" "$BACKUP_DIR/skills/$s"
    echo "⚠️ 기존 스킬 $s (내용 다름)을 $BACKUP_DIR/skills/ 로 백업하고 교체합니다."
  fi
  cp -r "$SRC_DIR/.claude/skills/$s" "$dst"
  echo "✓ .claude/skills/$s"
done

# settings.json 훅 등록:
#   - 파일 없음 → 우리 설정 설치
#   - 파일 있음 → python3로 hooks 배열에만 '추가' 병합 (기존 키·훅 전부 보존,
#     이미 등록돼 있으면 무변경, 병합 전 원본 백업)
#   - python3 없음 / JSON 파싱 실패 → 예시 파일 제공으로 폴백 (원본 불가침)
merge_py() {
  python3 - "$TARGET/.claude/settings.json" "$1" <<'PY'
import json, sys
path, mode = sys.argv[1], sys.argv[2]
d = json.load(open(path))
if not isinstance(d, dict):
    sys.exit(1)
h = d.setdefault("hooks", {})
if not isinstance(h, dict):
    sys.exit(1)

def registered(event, frag):
    for m in h.get(event) or []:
        for k in m.get("hooks") or []:
            if frag in str(k.get("command", "")):
                return True
    return False

changed = False
# bash -c 래핑: 네이티브 Windows에서는 훅이 cmd 경유로 실행되어 .sh 직접
# 실행과 $VAR 확장이 안 되므로, 변수 확장을 bash에게 맡기는 크로스 플랫폼 형식.
if not registered("SessionStart", "session-context.sh"):
    h.setdefault("SessionStart", []).append({
        "matcher": "startup|clear|compact",
        "hooks": [{"type": "command",
                   "command": 'bash -c "\\"$CLAUDE_PROJECT_DIR\\"/.claude/hooks/session-context.sh"',
                   "timeout": 15}]})
    changed = True
if not registered("UserPromptSubmit", "prompt-freshness.sh"):
    h.setdefault("UserPromptSubmit", []).append({
        "hooks": [{"type": "command",
                   "command": 'bash -c "\\"$CLAUDE_PROJECT_DIR\\"/.claude/hooks/prompt-freshness.sh"',
                   "timeout": 10}]})
    changed = True
if not registered("Stop", "evolve-gate.sh"):
    h.setdefault("Stop", []).append({
        "hooks": [{"type": "command",
                   "command": 'bash -c "\\"$CLAUDE_PROJECT_DIR\\"/.claude/hooks/evolve-gate.sh"',
                   "timeout": 10}]})
    changed = True
if not registered("PostToolUse", "metrics-collector.sh"):
    h.setdefault("PostToolUse", []).append({
        "matcher": "Bash|Read|Grep|Glob",
        "hooks": [{"type": "command",
                   "command": 'bash -c "\\"$CLAUDE_PROJECT_DIR\\"/.claude/hooks/metrics-collector.sh"',
                   "timeout": 10}]})
    changed = True

if mode == "check":
    print("mergeable" if changed else "already")
    sys.exit(0)
if changed:
    with open(path, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write("\n")
print("merged" if changed else "already")
PY
}

settings_fallback() {
  cp "$SRC_DIR/.claude/settings.json" "$TARGET/.claude/settings.hooks-example.json"
  echo "⚠️ settings.json 자동 병합 불가($1). 기존 파일은 건드리지 않았습니다."
  echo "   .claude/settings.hooks-example.json의 hooks 항목을 기존 파일의 hooks에 '추가'하세요."
  echo "   훅은 배열에 추가하는 방식이라 기존 훅은 그대로 유지되고 함께 실행됩니다."
}

if [ ! -f "$TARGET/.claude/settings.json" ]; then
  cp "$SRC_DIR/.claude/settings.json" "$TARGET/.claude/settings.json"
  echo "✓ .claude/settings.json (훅 4종 등록: SessionStart, UserPromptSubmit, Stop, PostToolUse)"
elif cmp -s "$SRC_DIR/.claude/settings.json" "$TARGET/.claude/settings.json"; then
  echo "✓ .claude/settings.json (기존과 동일 — 변경 없음)"
elif ! command -v python3 >/dev/null 2>&1; then
  settings_fallback "python3 없음"
else
  status=$(merge_py check 2>/dev/null) || status=""
  case "$status" in
    already)
      echo "✓ .claude/settings.json (훅 이미 등록됨 — 변경 없음)"
      ;;
    mergeable)
      ensure_backup_dir
      cp -p "$TARGET/.claude/settings.json" "$BACKUP_DIR/settings.json"
      if [ "$(merge_py write 2>/dev/null)" = "merged" ]; then
        echo "✓ .claude/settings.json (기존 설정 의미 보존, 훅만 자동 추가 — JSON 포맷은 재정렬될 수 있으며 원본은 $BACKUP_DIR/settings.json 에 백업됨)"
      else
        cp -p "$BACKUP_DIR/settings.json" "$TARGET/.claude/settings.json"
        settings_fallback "병합 실패, 원본 복원됨"
      fi
      ;;
    *)
      settings_fallback "JSON 파싱 실패"
      ;;
  esac
fi

# ---------------------------------------------------------------
# 설치 즉시 온보딩 — 설치는 곧 이 기능을 쓰겠다는 의사 표시이므로,
# 커서가 프로젝트를 열자마자 인덱싱하듯 지금 바로 컨텍스트 문서를 생성한다.
# claude CLI가 없거나 실패하면 "첫 실질 작업 후 자동 생성"으로 폴백한다.
# ---------------------------------------------------------------
echo ""
if [ -n "$NO_ONBOARD" ]; then
  echo "ℹ️ 즉시 온보딩 건너뜀(--no-onboard). 문서는 첫 실질 작업 후 자동 생성됩니다."
elif [ -f "$TARGET/.cursor-context/project-context.md" ]; then
  echo "✓ 컨텍스트 문서가 이미 존재합니다 — 온보딩 생략."
elif command -v claude >/dev/null 2>&1; then
  echo "▶ 즉시 온보딩: 프로젝트를 분석해 컨텍스트 문서를 생성합니다 (1~3분, Claude API 토큰 사용)..."
  ONBOARD_PROMPT="project-onboard 스킬을 지금 실행해 .cursor-context/project-context.md 를 생성하라. 이것이 이 세션의 유일한 작업이다. 건너뛰기 조건은 적용하지 마라 — 사용자가 설치 시점에 생성을 명시적으로 요청했다."
  RUNNER="claude"
  command -v timeout >/dev/null 2>&1 && RUNNER="timeout 600 claude"
  ( cd "$TARGET" && $RUNNER -p "$ONBOARD_PROMPT" \
      --settings .claude/settings.json \
      --allowedTools "Bash,Read,Grep,Glob,Write,Edit" \
      --permission-mode acceptEdits ) >/dev/null 2>&1 || true
  if [ -f "$TARGET/.cursor-context/project-context.md" ]; then
    echo "✓ .cursor-context/project-context.md 생성 완료 — 다음 세션부터 자동 주입됩니다."
    ( cd "$TARGET" && .claude/hooks/context-benchmark.sh 2>/dev/null | tail -1 ) || true
  else
    echo "⚠️ 즉시 온보딩 실패(API 미인증 등). 문서는 첫 실질 작업 후 자동 생성으로 폴백됩니다."
  fi
else
  echo "ℹ️ claude CLI를 찾지 못해 즉시 온보딩을 건너뜁니다. 문서는 첫 실질 작업 후 자동 생성됩니다."
fi

echo ""
echo "설치 완료! 다음 단계:"
echo "  1. 대상 프로젝트에서 Claude Code를 새로 시작하면 스냅샷(+문서)이 자동 주입됩니다."
echo "  2. 이후 문서는 지문 기반으로 자동 갱신·진화합니다. 사용자가 할 일은 없습니다."
[ -n "$backup_made" ] && echo "  3. 교체된 기존 파일 백업: $BACKUP_DIR"
exit 0
