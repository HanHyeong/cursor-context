#!/usr/bin/env bash
# shellcheck disable=SC2034  # MSG_<lang>_<key> 변수들은 msg()의 ${!varname} 간접 참조로만 쓰인다 (파일 전체 적용)
# cursor-context installer / 설치 스크립트
# Usage / 사용법: ./install.sh /path/to/your/project [--no-onboard]
#                ./install.sh /path/to/your/project --uninstall [--purge-data]
#
# Installs into the target project / 대상 프로젝트에 다음을 설치한다:
#   .claude/hooks/  — 6 hooks (session snapshot, prompt freshness, fingerprint
#                     generator, metrics collector, evolve gate (Stop), doc
#                     quality gate) + a shared config loader (lib-config.sh;
#                     not a hook itself, but the hooks source it)
#   .claude/skills/ — 3 skills: project-onboard, context-refresh, context-evolve
#   .claude/settings.json — registers 4 hooks + a permissions.allow rule
#                     Bash(.claude/hooks/*) so skills can run the gate scripts
#                     via the Bash tool without a permission prompt
#                     (auto-merged if a file already exists)
#   (machine-generated data is created under .cursor-context/ at runtime)
#
# Non-destructive principles / 비파괴 원칙:
#   - An existing settings.json is never overwritten (only an example file is provided).
#   - Same-named hooks/skills are backed up under .claude/backup/ only when
#     their content differs. The backup location must be outside skill lookup
#     scope (.claude/skills/) -- a backup inside skills/ would get picked up
#     as a duplicate live skill.
#   - No backup is made when content is identical (idempotent re-install).

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET=""
NO_ONBOARD=""
UNINSTALL=""
PURGE_DATA=""
for arg in "$@"; do
  case "$arg" in
    --no-onboard) NO_ONBOARD=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --purge-data) PURGE_DATA=1 ;;
    *) TARGET="$arg" ;;
  esac
done

# 이 스크립트 자신의 출력 언어를 설치자의 시스템 로케일로 추정한다. 이후
# 대상 프로젝트에 써 주는 .cursor-context/config의 LANG 초기값도 동일한
# 판단을 재사용한다 — 설치자와 대상 프로젝트의 기본 언어를 다르게 추정할
# 이유가 없다.
CTX_LANG="en"
for _locale_var in "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
  case "$_locale_var" in
    ko|ko_*|ko.*) CTX_LANG="ko"; break ;;
  esac
done
unset _locale_var

MSG_en_usage="Usage: ./install.sh /path/to/your/project [--no-onboard]"
MSG_ko_usage="사용법: ./install.sh /path/to/your/project [--no-onboard]"
MSG_en_usage_target="The target directory must exist."
MSG_ko_usage_target="대상 디렉터리가 존재해야 합니다."
MSG_en_usage_onboard="  --no-onboard: skip immediate doc generation right after install (uses the Claude API)."
MSG_ko_usage_onboard="  --no-onboard: 설치 직후의 즉시 문서 생성(Claude API 사용)을 건너뜁니다."
MSG_en_usage_uninstall="  --uninstall: remove this toolkit's hooks/skills/hook-registrations from the target project (everything removed is backed up first, not deleted outright)."
MSG_ko_usage_uninstall="  --uninstall: 대상 프로젝트에서 이 툴킷의 훅·스킬·훅 등록을 제거합니다(완전 삭제 대신 먼저 백업)."
MSG_en_usage_purge="  --purge-data: with --uninstall, also delete .cursor-context/ (otherwise it is left in place)."
MSG_ko_usage_purge="  --purge-data: --uninstall과 함께 쓰면 .cursor-context/ 까지 삭제합니다(기본은 그대로 둠)."
MSG_en_self_install="Target is this repo itself -- nothing to install."
MSG_ko_self_install="대상이 이 저장소 자신입니다. 설치할 필요가 없습니다."
MSG_en_install_target="Installing into: %s"
MSG_ko_install_target="설치 대상: %s"
MSG_en_hook_type_backup="Existing %s (not a file) backed up to %s and replaced."
MSG_ko_hook_type_backup="기존 %s (파일이 아님)을 %s 로 백업하고 교체합니다."
MSG_en_hook_content_backup="Existing hook %s (different content) backed up to %s and replaced."
MSG_ko_hook_content_backup="기존 훅 %s (내용 다름)을 %s 에 백업하고 교체합니다."
MSG_en_hook_installed="Installed .claude/hooks/%s"
MSG_ko_hook_installed="✓ .claude/hooks/%s"
MSG_en_skill_type_backup="Existing %s (not a directory) backed up to %s and replaced."
MSG_ko_skill_type_backup="기존 %s (디렉터리가 아님)을 %s 로 백업하고 교체합니다."
MSG_en_skill_unchanged="✓ .claude/skills/%s (identical to existing -- no change)"
MSG_ko_skill_unchanged="✓ .claude/skills/%s (기존과 동일 — 변경 없음)"
MSG_en_skill_content_backup="Existing skill %s (different content) backed up to %s and replaced."
MSG_ko_skill_content_backup="기존 스킬 %s (내용 다름)을 %s 에 백업하고 교체합니다."
MSG_en_skill_installed="Installed .claude/skills/%s"
MSG_ko_skill_installed="✓ .claude/skills/%s"
MSG_en_settings_fallback="Cannot auto-merge settings.json (%s). The existing file was left untouched."
MSG_ko_settings_fallback="settings.json 자동 병합 불가(%s). 기존 파일은 건드리지 않았습니다."
MSG_en_settings_fallback_howto="   Add the hooks entries and the permissions.allow rule from .claude/settings.hooks-example.json into your existing file (append, don't replace)."
MSG_ko_settings_fallback_howto="   .claude/settings.hooks-example.json의 hooks 항목과 permissions.allow 규칙을 기존 파일에 '추가'하세요."
MSG_en_settings_fallback_note="   Hooks are appended to arrays, so your existing hooks keep working alongside them."
MSG_ko_settings_fallback_note="   훅은 배열에 추가하는 방식이라 기존 훅은 그대로 유지되고 함께 실행됩니다."
MSG_en_settings_fresh="Installed .claude/settings.json (registered 4 hooks: SessionStart, UserPromptSubmit, Stop, PostToolUse + permission rule Bash(.claude/hooks/*) so skills can run the gate scripts)"
MSG_ko_settings_fresh="✓ .claude/settings.json (훅 4종 등록: SessionStart, UserPromptSubmit, Stop, PostToolUse + 스킬이 게이트 스크립트를 실행할 수 있게 Bash(.claude/hooks/*) 허용 규칙 추가)"
MSG_en_settings_identical="✓ .claude/settings.json (identical to existing -- no change)"
MSG_ko_settings_identical="✓ .claude/settings.json (기존과 동일 — 변경 없음)"
MSG_en_settings_already="✓ .claude/settings.json (hooks already registered -- no change)"
MSG_ko_settings_already="✓ .claude/settings.json (훅 이미 등록됨 — 변경 없음)"
MSG_en_settings_merged="✓ .claude/settings.json (existing config semantics preserved, hooks + hook-script permission rule appended -- JSON formatting may be reordered; original backed up to %s)"
MSG_ko_settings_merged="✓ .claude/settings.json (기존 설정 의미 보존, 훅과 훅 스크립트 허용 규칙만 자동 추가 — JSON 포맷은 재정렬될 수 있으며 원본은 %s 에 백업됨)"
MSG_en_python3_missing="python3 missing"
MSG_ko_python3_missing="python3 없음"
MSG_en_merge_failed="merge failed, original restored"
MSG_ko_merge_failed="병합 실패, 원본 복원됨"
MSG_en_json_parse_failed="JSON parse failed"
MSG_ko_json_parse_failed="JSON 파싱 실패"
MSG_en_config_generated="✓ .cursor-context/config (LANG=%s -- guessed from the installer's system locale)"
MSG_ko_config_generated="✓ .cursor-context/config (LANG=%s — 설치자 시스템 로케일로 추정)"
MSG_en_config_kept="✓ .cursor-context/config (existing file kept -- untouched)"
MSG_ko_config_kept="✓ .cursor-context/config (기존 파일 유지 — 건드리지 않음)"
MSG_en_onboard_skipped="Immediate onboarding skipped (--no-onboard). The doc will be generated automatically after your first real task."
MSG_ko_onboard_skipped="즉시 온보딩 건너뜀(--no-onboard). 문서는 첫 실질 작업 후 자동 생성됩니다."
MSG_en_onboard_doc_exists="✓ Context doc already exists -- skipping onboarding."
MSG_ko_onboard_doc_exists="✓ 컨텍스트 문서가 이미 존재합니다 — 온보딩 생략."
MSG_en_onboard_running="Running immediate onboarding: analyzing the project to generate the context doc (1-3 min, uses Claude API tokens)..."
MSG_ko_onboard_running="즉시 온보딩: 프로젝트를 분석해 컨텍스트 문서를 생성합니다 (1~3분, Claude API 토큰 사용)..."
MSG_en_onboard_timed_out="Immediate onboarding was stopped after exceeding 600 seconds. The doc will be generated automatically after your first real task."
MSG_ko_onboard_timed_out="즉시 온보딩이 600초를 초과해 중단되었습니다. 문서는 첫 실질 작업 후 자동 생성으로 폴백됩니다."
MSG_en_onboard_done="✓ .cursor-context/project-context.md generated -- it will be auto-injected starting with your next session."
MSG_ko_onboard_done="✓ .cursor-context/project-context.md 생성 완료 — 다음 세션부터 자동 주입됩니다."
MSG_en_onboard_failed="Immediate onboarding failed (e.g. API not authenticated). The doc will be generated automatically after your first real task."
MSG_ko_onboard_failed="즉시 온보딩 실패(API 미인증 등). 문서는 첫 실질 작업 후 자동 생성으로 폴백됩니다."
MSG_en_no_claude_cli="claude CLI not found -- skipping immediate onboarding. The doc will be generated automatically after your first real task."
MSG_ko_no_claude_cli="claude CLI를 찾지 못해 즉시 온보딩을 건너뜁니다. 문서는 첫 실질 작업 후 자동 생성됩니다."
MSG_en_done_header="Install complete! Next steps:"
MSG_ko_done_header="설치 완료! 다음 단계:"
MSG_en_done_step1="  1. Start a new Claude Code session in the target project -- the snapshot (+ doc) is injected automatically."
MSG_ko_done_step1="  1. 대상 프로젝트에서 Claude Code를 새로 시작하면 스냅샷(+문서)이 자동 주입됩니다."
MSG_en_done_step2="  2. The doc auto-refreshes and evolves from here based on fingerprints. There is nothing else for you to do."
MSG_ko_done_step2="  2. 이후 문서는 지문 기반으로 자동 갱신·진화합니다. 사용자가 할 일은 없습니다."
MSG_en_done_step3="  3. Backup of replaced files: %s"
MSG_ko_done_step3="  3. 교체된 기존 파일 백업: %s"
MSG_en_uninstall_target="Uninstalling from: %s"
MSG_ko_uninstall_target="제거 대상: %s"
MSG_en_uninstall_nothing="Nothing to uninstall -- no .claude/hooks or .claude/skills found in this project."
MSG_ko_uninstall_nothing="제거할 것이 없습니다 — 이 프로젝트에 .claude/hooks 또는 .claude/skills가 없습니다."
MSG_en_uninstall_hook_removed="Removed .claude/hooks/%s (backed up to %s)"
MSG_ko_uninstall_hook_removed="✓ .claude/hooks/%s 제거 (백업: %s)"
MSG_en_uninstall_skill_removed="Removed .claude/skills/%s (backed up to %s)"
MSG_ko_uninstall_skill_removed="✓ .claude/skills/%s 제거 (백업: %s)"
MSG_en_uninstall_settings_removed="✓ .claude/settings.json (removed this toolkit's hook entries and its Bash(.claude/hooks/*) permission rule only -- your other hooks/settings are untouched; original backed up to %s)"
MSG_ko_uninstall_settings_removed="✓ .claude/settings.json (이 툴킷의 훅 등록과 Bash(.claude/hooks/*) 허용 규칙만 제거, 다른 훅·설정은 그대로 유지; 원본 백업: %s)"
MSG_en_uninstall_settings_none="✓ .claude/settings.json (no hook entries from this toolkit were found -- no change)"
MSG_ko_uninstall_settings_none="✓ .claude/settings.json (이 툴킷의 훅 등록이 없음 — 변경 없음)"
MSG_en_uninstall_settings_missing="No .claude/settings.json found -- nothing to remove there."
MSG_ko_uninstall_settings_missing=".claude/settings.json이 없습니다 — 제거할 것이 없습니다."
MSG_en_uninstall_settings_manual="Cannot auto-remove hook entries (%s). Manually remove any hooks entries referencing session-context.sh / prompt-freshness.sh / evolve-gate.sh / metrics-collector.sh, and the permissions.allow entry Bash(.claude/hooks/*), from .claude/settings.json."
MSG_ko_uninstall_settings_manual="훅 등록 자동 제거 불가(%s). .claude/settings.json에서 session-context.sh / prompt-freshness.sh / evolve-gate.sh / metrics-collector.sh를 참조하는 훅 항목과 permissions.allow의 Bash(.claude/hooks/*) 항목을 직접 제거하세요."
MSG_en_uninstall_data_kept="✓ .cursor-context/ left in place. Re-run with --purge-data to remove it too, or delete it manually."
MSG_ko_uninstall_data_kept="✓ .cursor-context/ 는 그대로 둡니다. 지우려면 --purge-data로 다시 실행하거나 직접 삭제하세요."
MSG_en_uninstall_data_purged="Removed .cursor-context/ (--purge-data)."
MSG_ko_uninstall_data_purged=".cursor-context/ 를 제거했습니다 (--purge-data)."
MSG_en_uninstall_data_absent="✓ .cursor-context/ was already absent -- nothing to purge."
MSG_ko_uninstall_data_absent="✓ .cursor-context/ 가 이미 없습니다 — 지울 것 없음."
MSG_en_uninstall_done="Uninstall complete. Backup of everything removed: %s"
MSG_ko_uninstall_done="제거 완료. 제거된 항목 백업: %s"
MSG_en_uninstall_done_nobackup="Uninstall complete (nothing needed backing up)."
MSG_ko_uninstall_done_nobackup="제거 완료(백업할 것 없음)."

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
# ✓/⚠️로 시작하지 않는 -로 시작하는 포맷 문자열이 옵션 플래그로 오인될 수 있다.
# shellcheck disable=SC2059
msgf() { printf -- "$(msg "$1")\n" "${@:2}"; }

# --uninstall 전용: settings.json의 hooks 배열에서 '이 툴킷이 등록한 항목만'
# 골라서 제거하고, 설치 때 추가한 permissions.allow의 Bash(.claude/hooks/*)
# 규칙도 함께 제거한다. 같은 이벤트에 사용자가 추가한 다른 훅이나 사용자의
# 다른 allow 항목은 그대로 남긴다 (merge_py의 반대 방향 연산).
unmerge_py() {
  python3 - "$TARGET/.claude/settings.json" "$1" <<'PY'
import json, sys
path, mode = sys.argv[1], sys.argv[2]
d = json.load(open(path))
if not isinstance(d, dict):
    sys.exit(1)

changed = False

OURS = ("session-context.sh", "prompt-freshness.sh", "evolve-gate.sh", "metrics-collector.sh")
h = d.get("hooks")
if isinstance(h, dict):
    for event in list(h.keys()):
        entries = h.get(event)
        if not isinstance(entries, list):
            continue
        kept_entries = []
        for entry in entries:
            hooks_list = entry.get("hooks") if isinstance(entry, dict) else None
            if not isinstance(hooks_list, list):
                kept_entries.append(entry)
                continue
            kept_hooks = [hk for hk in hooks_list if not any(s in str(hk.get("command", "")) for s in OURS)]
            if len(kept_hooks) != len(hooks_list):
                changed = True
            if kept_hooks:
                entry = dict(entry)
                entry["hooks"] = kept_hooks
                kept_entries.append(entry)
        if kept_entries:
            h[event] = kept_entries
        else:
            if event in h:
                del h[event]
    if not h:
        d.pop("hooks", None)

# 설치 때 추가한 허용 규칙 제거. 정확히 이 문자열 하나만 지우고, 사용자가
# 직접 추가한 다른 allow 항목은 보존한다. 비우고 나면 빈 컨테이너도 정리.
PERM = "Bash(.claude/hooks/*)"
perms = d.get("permissions")
if isinstance(perms, dict):
    allow = perms.get("allow")
    if isinstance(allow, list) and PERM in allow:
        allow[:] = [a for a in allow if a != PERM]
        changed = True
        if not allow:
            perms.pop("allow", None)
        if not perms:
            d.pop("permissions", None)

if mode == "check":
    print("removable" if changed else "none")
    sys.exit(0)
if changed:
    with open(path, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write("\n")
print("removed" if changed else "none")
PY
}

# --uninstall: 훅 파일·스킬 디렉터리·settings.json 등록을 제거한다. 아무것도
# 그냥 지우지 않고 .claude/backup/uninstall-<timestamp>/ 로 옮긴 뒤 제거하는
# 방식이라 실수로 지운 경우에도 되돌릴 수 있다. .cursor-context/(생성된 문서·
# 메트릭 데이터)는 기본적으로 보존하고, --purge-data를 줘야만 함께 지운다.
do_uninstall() {
  msgf uninstall_target "$TARGET"

  if [ ! -d "$TARGET/.claude/hooks" ] && [ ! -d "$TARGET/.claude/skills" ]; then
    msg uninstall_nothing; echo ""
    return 0
  fi

  local ubackup_made=""
  local ubackup_dir
  ubackup_dir="$TARGET/.claude/backup/uninstall-$(date +%Y%m%d%H%M%S)"
  ensure_ubackup_dir() {
    if [ -z "$ubackup_made" ]; then
      mkdir -p "$ubackup_dir"
      ubackup_made=1
    fi
  }

  for h in session-context.sh context-fingerprint.sh prompt-freshness.sh metrics-collector.sh context-benchmark.sh evolve-gate.sh lib-config.sh; do
    dst="$TARGET/.claude/hooks/$h"
    if [ -e "$dst" ]; then
      ensure_ubackup_dir
      mkdir -p "$ubackup_dir/hooks"
      mv "$dst" "$ubackup_dir/hooks/$h"
      msgf uninstall_hook_removed "$h" "$ubackup_dir/hooks/"
    fi
  done

  for s in project-onboard context-refresh context-evolve; do
    dst="$TARGET/.claude/skills/$s"
    if [ -e "$dst" ]; then
      ensure_ubackup_dir
      mkdir -p "$ubackup_dir/skills"
      mv "$dst" "$ubackup_dir/skills/$s"
      msgf uninstall_skill_removed "$s" "$ubackup_dir/skills/"
    fi
  done

  if [ ! -f "$TARGET/.claude/settings.json" ]; then
    msg uninstall_settings_missing; echo ""
  elif ! command -v python3 >/dev/null 2>&1; then
    msgf uninstall_settings_manual "$(msg python3_missing)"
  else
    status=$(unmerge_py check 2>/dev/null) || status=""
    case "$status" in
      none)
        msg uninstall_settings_none; echo ""
        ;;
      removable)
        ensure_ubackup_dir
        cp -p "$TARGET/.claude/settings.json" "$ubackup_dir/settings.json"
        if [ "$(unmerge_py write 2>/dev/null)" = "removed" ]; then
          msgf uninstall_settings_removed "$ubackup_dir/settings.json"
        else
          cp -p "$ubackup_dir/settings.json" "$TARGET/.claude/settings.json"
          msgf uninstall_settings_manual "$(msg json_parse_failed)"
        fi
        ;;
      *)
        msgf uninstall_settings_manual "$(msg json_parse_failed)"
        ;;
    esac
  fi

  if [ -n "$PURGE_DATA" ]; then
    if [ -d "$TARGET/.cursor-context" ]; then
      rm -rf "$TARGET/.cursor-context"
      msg uninstall_data_purged; echo ""
    else
      msg uninstall_data_absent; echo ""
    fi
  else
    msg uninstall_data_kept; echo ""
  fi

  echo ""
  if [ -n "$ubackup_made" ]; then
    msgf uninstall_done "$ubackup_dir"
  else
    msg uninstall_done_nobackup; echo ""
  fi
}

if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  msg usage; echo ""
  msg usage_target; echo ""
  msg usage_onboard; echo ""
  msg usage_uninstall; echo ""
  msg usage_purge; echo ""
  exit 1
fi

TARGET="$(cd "$TARGET" && pwd)"
if [ "$TARGET" = "$SRC_DIR" ]; then
  msg self_install; echo ""
  exit 0
fi

if [ -n "$UNINSTALL" ]; then
  do_uninstall
  exit 0
fi

msgf install_target "$TARGET"

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
for h in session-context.sh context-fingerprint.sh prompt-freshness.sh metrics-collector.sh context-benchmark.sh evolve-gate.sh lib-config.sh; do
  dst="$TARGET/.claude/hooks/$h"
  if [ -e "$dst" ] && [ ! -f "$dst" ]; then
    ensure_backup_dir
    mkdir -p "$BACKUP_DIR/hooks"
    mv "$dst" "$BACKUP_DIR/hooks/$h"
    msgf hook_type_backup "$h" "$BACKUP_DIR/hooks/"
  elif [ -f "$dst" ] && ! cmp -s "$SRC_DIR/.claude/hooks/$h" "$dst"; then
    ensure_backup_dir
    mkdir -p "$BACKUP_DIR/hooks"
    cp -p "$dst" "$BACKUP_DIR/hooks/$h"
    msgf hook_content_backup "$h" "$BACKUP_DIR/hooks/"
  fi
  cp "$SRC_DIR/.claude/hooks/$h" "$dst"
  chmod +x "$dst"
  msgf hook_installed "$h"
done

# 스킬: 동명 디렉터리가 있고 내용이 다르면 백업 후 교체.
# 백업은 반드시 skills/ 밖으로 이동한다 (스킬 중복 등록 방지).
for s in project-onboard context-refresh context-evolve; do
  dst="$TARGET/.claude/skills/$s"
  if [ -e "$dst" ] && [ ! -d "$dst" ]; then
    ensure_backup_dir
    mkdir -p "$BACKUP_DIR/skills"
    mv "$dst" "$BACKUP_DIR/skills/$s"
    msgf skill_type_backup "$s" "$BACKUP_DIR/skills/"
  fi
  if [ -d "$dst" ]; then
    if diff -rq "$SRC_DIR/.claude/skills/$s" "$dst" >/dev/null 2>&1; then
      msgf skill_unchanged "$s"
      continue
    fi
    ensure_backup_dir
    mkdir -p "$BACKUP_DIR/skills"
    mv "$dst" "$BACKUP_DIR/skills/$s"
    msgf skill_content_backup "$s" "$BACKUP_DIR/skills/"
  fi
  cp -r "$SRC_DIR/.claude/skills/$s" "$dst"
  msgf skill_installed "$s"
done

# settings.json 훅 등록 + Bash(.claude/hooks/*) 허용 규칙:
#   - 파일 없음 → 우리 설정 설치
#   - 파일 있음 → python3로 hooks 배열과 permissions.allow에만 '추가' 병합
#     (기존 키·훅·허용 항목 전부 보존, 이미 등록돼 있으면 무변경, 병합 전
#     원본 백업)
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

# Bash(.claude/hooks/*) 허용 규칙: 훅 자체는 권한 검사 없이 실행되지만,
# context-evolve 스킬은 Claude가 'Bash 도구로' context-benchmark.sh를 직접
# 실행해야 하고 이는 권한 게이트에 걸린다. 이 규칙이 없으면 권한이 허용되지
# 않은 세션에서 진화가 조용히 스킵되고, 신호가 소진되지 않아 Stop 게이트가
# 새 세션마다 반복 발동한다. permissions/allow가 dict/list가 아닌 비정상
# 형태면 건드리지 않는다 (사용자 설정 불가침 원칙).
PERM = "Bash(.claude/hooks/*)"
perms = d.setdefault("permissions", {})
if isinstance(perms, dict):
    allow = perms.setdefault("allow", [])
    if isinstance(allow, list) and PERM not in allow:
        allow.append(PERM)
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
  msgf settings_fallback "$1"
  msg settings_fallback_howto; echo ""
  msg settings_fallback_note; echo ""
}

if [ ! -f "$TARGET/.claude/settings.json" ]; then
  cp "$SRC_DIR/.claude/settings.json" "$TARGET/.claude/settings.json"
  msg settings_fresh; echo ""
elif cmp -s "$SRC_DIR/.claude/settings.json" "$TARGET/.claude/settings.json"; then
  msg settings_identical; echo ""
elif ! command -v python3 >/dev/null 2>&1; then
  settings_fallback "$(msg python3_missing)"
else
  status=$(merge_py check 2>/dev/null) || status=""
  case "$status" in
    already)
      msg settings_already; echo ""
      ;;
    mergeable)
      ensure_backup_dir
      cp -p "$TARGET/.claude/settings.json" "$BACKUP_DIR/settings.json"
      if [ "$(merge_py write 2>/dev/null)" = "merged" ]; then
        msgf settings_merged "$BACKUP_DIR/settings.json"
      else
        cp -p "$BACKUP_DIR/settings.json" "$TARGET/.claude/settings.json"
        settings_fallback "$(msg merge_failed)"
      fi
      ;;
    *)
      settings_fallback "$(msg json_parse_failed)"
      ;;
  esac
fi

# ---------------------------------------------------------------
# .cursor-context/config — 언어 초기값을 설치자의 시스템 로케일로 추정해
# 생성한다(위에서 이미 계산한 CTX_LANG 재사용). 파일이 이미 있으면 절대
# 건드리지 않는다(비파괴). 임계값들은 주석 처리된 기본값만 적어 두어 필요할
# 때 바로 무엇을 바꿀 수 있는지 보이게 한다 — 실제 기본값은 각 훅에 내장돼
# 있어 이 줄들이 없어도 동작한다.
# ---------------------------------------------------------------
CONFIG_FILE="$TARGET/.cursor-context/config"
if [ ! -f "$CONFIG_FILE" ]; then
  mkdir -p "$TARGET/.cursor-context" 2>/dev/null || true
  cat > "$CONFIG_FILE" << CFG
# cursor-context config -- KEY=VALUE, one per line. Delete this file or a
# single line to fall back to the defaults built into the hooks. Lines
# starting with # are comments.
LANG=$CTX_LANG
# FEEDBACK_THRESHOLD=5
# METRICS_THRESHOLD=300
# COMMIT_BACKSTOP=20
# DOC_LINE_BUDGET=200
# DOC_MIN_LINES=10
CFG
  msgf config_generated "$CTX_LANG"
else
  msg config_kept; echo ""
fi

# ---------------------------------------------------------------
# 설치 즉시 온보딩 — 설치는 곧 이 기능을 쓰겠다는 의사 표시이므로,
# 커서가 프로젝트를 열자마자 인덱싱하듯 지금 바로 컨텍스트 문서를 생성한다.
# claude CLI가 없거나 실패하면 "첫 실질 작업 후 자동 생성"으로 폴백한다.
# ---------------------------------------------------------------
echo ""
if [ -n "$NO_ONBOARD" ]; then
  msg onboard_skipped; echo ""
elif [ -f "$TARGET/.cursor-context/project-context.md" ]; then
  msg onboard_doc_exists; echo ""
elif command -v claude >/dev/null 2>&1; then
  msg onboard_running; echo ""
  if [ "$CTX_LANG" = "ko" ]; then
    ONBOARD_PROMPT="project-onboard 스킬을 지금 실행해 .cursor-context/project-context.md 를 생성하라. 이것이 이 세션의 유일한 작업이다. 건너뛰기 조건은 적용하지 마라 — 사용자가 설치 시점에 생성을 명시적으로 요청했다. Skill 도구를 쓸 수 없으면 .claude/skills/project-onboard/SKILL.md 를 직접 읽고 그 절차를 그대로 따르라."
  else
    ONBOARD_PROMPT="Run the project-onboard skill right now to generate .cursor-context/project-context.md. This is the only task for this session. Do not apply the usual skip conditions -- the user explicitly requested generation at install time. If the Skill tool is unavailable, read .claude/skills/project-onboard/SKILL.md directly and follow its procedure."
  fi
  # `timeout` 명령은 macOS 기본 설치에 없어(coreutils 별도 설치 필요) 이식성이
  # 없다. claude를 백그라운드로 돌리고 부모 셸이 10초 간격으로 진행 표시(.)를
  # 찍으며 600초 초과 시 직접 kill하는 루프로 대체 — 무출력 구간으로 인한
  # "멈춘 줄 알았다" 오해와 macOS 무한 대기 문제를 함께 해결한다.
  ( cd "$TARGET" && claude -p "$ONBOARD_PROMPT" \
      --settings .claude/settings.json \
      --allowedTools "Bash,Read,Grep,Glob,Write,Edit,Skill" \
      --permission-mode acceptEdits ) >/dev/null 2>&1 &
  onboard_pid=$!
  elapsed=0
  timed_out=""
  while kill -0 "$onboard_pid" 2>/dev/null; do
    sleep 10
    elapsed=$((elapsed + 10))
    if [ "$elapsed" -ge 600 ]; then
      timed_out=1
      kill "$onboard_pid" 2>/dev/null || true
      break
    fi
    printf '.'
  done
  wait "$onboard_pid" 2>/dev/null || true
  echo ""
  if [ -n "$timed_out" ]; then
    msg onboard_timed_out; echo ""
  elif [ -f "$TARGET/.cursor-context/project-context.md" ]; then
    msg onboard_done; echo ""
    ( cd "$TARGET" && .claude/hooks/context-benchmark.sh 2>/dev/null | tail -1 ) || true
  else
    msg onboard_failed; echo ""
  fi
else
  msg no_claude_cli; echo ""
fi

echo ""
msg done_header; echo ""
msg done_step1; echo ""
msg done_step2; echo ""
[ -n "$backup_made" ] && msgf done_step3 "$BACKUP_DIR"
exit 0
