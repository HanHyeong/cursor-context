#!/usr/bin/env bash
# cursor-context 설치 스크립트
# 사용법: ./install.sh /path/to/your/project
#
# 대상 프로젝트에 다음을 설치한다:
#   .claude/hooks/session-context.sh     — 세션 시작 시 프로젝트 스냅샷 주입
#   .claude/hooks/prompt-freshness.sh    — 매 프롬프트 지문 재검사 (일치 시 침묵)
#   .claude/hooks/context-fingerprint.sh — 지문 계산·비교 단일 진실 공급원
#   .claude/skills/project-onboard/      — 컨텍스트 문서 자동 생성 스킬
#   .claude/skills/context-refresh/      — 컨텍스트 문서 증분 갱신 스킬
#   .claude/settings.json                — 훅 등록 (기존 파일이 있으면 보존)
#
# 비파괴 원칙:
#   - 기존 settings.json은 절대 덮어쓰지 않는다 (예시 파일만 제공).
#   - 동명의 기존 훅·스킬은 내용이 다를 때만 .claude/backup/ 아래로 백업 후 교체.
#     백업 위치는 스킬 탐색 범위(.claude/skills/) 밖이어야 한다 — skills/ 안에
#     백업을 두면 백업본의 SKILL.md가 살아있는 스킬로 중복 등록되어 버린다.
#   - 내용이 동일하면(재설치) 백업을 만들지 않는다 (멱등).

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-}"

if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  echo "사용법: ./install.sh /path/to/your/project"
  echo "대상 디렉터리가 존재해야 합니다."
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
for h in session-context.sh context-fingerprint.sh prompt-freshness.sh; do
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
for s in project-onboard context-refresh; do
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

# settings.json: 기존 파일이 있으면 덮어쓰지 않고 예시 파일로 저장
if [ -f "$TARGET/.claude/settings.json" ]; then
  if cmp -s "$SRC_DIR/.claude/settings.json" "$TARGET/.claude/settings.json"; then
    echo "✓ .claude/settings.json (기존과 동일 — 변경 없음)"
  else
    cp "$SRC_DIR/.claude/settings.json" "$TARGET/.claude/settings.hooks-example.json"
    echo "⚠️ 기존 .claude/settings.json이 있어 덮어쓰지 않았습니다."
    echo "   .claude/settings.hooks-example.json의 hooks 항목을 기존 파일의 hooks에 '추가'하세요."
    echo "   훅은 배열에 추가하는 방식이라 기존 훅은 그대로 유지되고 함께 실행됩니다."
  fi
else
  cp "$SRC_DIR/.claude/settings.json" "$TARGET/.claude/settings.json"
  echo "✓ .claude/settings.json (SessionStart + UserPromptSubmit 훅 등록)"
fi

echo ""
echo "설치 완료! 다음 단계:"
echo "  1. 대상 프로젝트에서 Claude Code를 새로 시작하면 스냅샷이 자동 주입됩니다."
echo "  2. 컨텍스트 문서(.claude/project-context.md)는 첫 실질 작업 후 자동 생성됩니다."
[ -n "$backup_made" ] && echo "  3. 교체된 기존 파일 백업: $BACKUP_DIR"
exit 0
