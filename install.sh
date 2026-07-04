#!/usr/bin/env bash
# cursor-context 설치 스크립트
# 사용법: ./install.sh /path/to/your/project
#
# 대상 프로젝트에 다음을 설치한다:
#   .claude/hooks/session-context.sh   — 세션 시작 시 프로젝트 스냅샷 주입
#   .claude/skills/project-onboard/    — CLAUDE.md 자동 생성 스킬
#   .claude/skills/context-refresh/    — CLAUDE.md 증분 갱신 스킬
#   .claude/settings.json              — SessionStart 훅 등록 (기존 파일이 있으면 보존)

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-}"

if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  echo "사용법: ./install.sh /path/to/your/project"
  echo "대상 디렉터리가 존재해야 합니다."
  exit 1
fi

TARGET="$(cd "$TARGET" && pwd)"
echo "설치 대상: $TARGET"

mkdir -p "$TARGET/.claude/hooks" "$TARGET/.claude/skills"

# 훅 스크립트 복사 (스냅샷 생성기 + 지문 생성기)
cp "$SRC_DIR/.claude/hooks/session-context.sh" "$SRC_DIR/.claude/hooks/context-fingerprint.sh" "$TARGET/.claude/hooks/"
chmod +x "$TARGET/.claude/hooks/session-context.sh" "$TARGET/.claude/hooks/context-fingerprint.sh"
echo "✓ .claude/hooks/session-context.sh"
echo "✓ .claude/hooks/context-fingerprint.sh"

# 스킬 복사
cp -r "$SRC_DIR/.claude/skills/project-onboard" "$TARGET/.claude/skills/"
cp -r "$SRC_DIR/.claude/skills/context-refresh" "$TARGET/.claude/skills/"
echo "✓ .claude/skills/project-onboard"
echo "✓ .claude/skills/context-refresh"

# settings.json: 기존 파일이 있으면 덮어쓰지 않고 예시 파일로 저장
if [ -f "$TARGET/.claude/settings.json" ]; then
  cp "$SRC_DIR/.claude/settings.json" "$TARGET/.claude/settings.hooks-example.json"
  echo "⚠️ 기존 .claude/settings.json이 있어 덮어쓰지 않았습니다."
  echo "   .claude/settings.hooks-example.json의 hooks 섹션을 기존 파일에 직접 병합하세요."
else
  cp "$SRC_DIR/.claude/settings.json" "$TARGET/.claude/settings.json"
  echo "✓ .claude/settings.json (SessionStart 훅 등록)"
fi

echo ""
echo "설치 완료! 다음 단계:"
echo "  1. 대상 프로젝트에서 Claude Code를 새로 시작하면 스냅샷이 자동 주입됩니다."
echo "  2. CLAUDE.md가 없다면 첫 세션에서 /project-onboard 를 실행해 문서를 생성하세요."
