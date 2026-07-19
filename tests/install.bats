#!/usr/bin/env bats
# install.sh 검증: 멱등성, 기존 settings.json 병합·백업, python3 부재 폴백,
# 훅/스킬 자리에 있는 타입 불일치 파일의 백업 처리.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOKS="session-context.sh context-fingerprint.sh prompt-freshness.sh metrics-collector.sh context-benchmark.sh evolve-gate.sh permission-gate.sh lib-config.sh"
SKILLS="project-onboard context-refresh context-evolve"

setup() {
  TARGET="$(mktemp -d)"
  # 3-2(설정화) 이후 install.sh 자신의 출력 언어는 설치자의 시스템 로케일로
  # 추정된다. 이 스위트의 기존 단언은 원래 동작(한국어 출력)을 그대로
  # 검증하는 것이 목적이므로 로케일을 한국어로 고정한다 — 영어 기본값은
  # 아래 별도 테스트에서 확인한다. (실제 ko_KR 로케일이 시스템에 설치돼
  # 있을 필요는 없다 — install.sh는 문자열 패턴만 비교한다.)
  export LC_ALL=ko_KR.UTF-8
  unset LANG LC_MESSAGES 2>/dev/null || true
}

teardown() {
  rm -rf "$TARGET"
}

# python3를 찾을 수 없는 PATH를 구성한다. /usr/bin, /bin, /usr/local/bin의
# 실행 파일을 python(3) 계열만 빼고 전부 심볼릭 링크로 옮겨, install.sh가
# 필요로 하는 다른 도구(mkdir, cp, cmp, mv, diff, chmod, date 등)는 그대로
# 쓸 수 있게 한다.
make_nopython_path() {
  local dir
  dir="$(mktemp -d)"
  for bindir in /usr/bin /bin /usr/local/bin; do
    [ -d "$bindir" ] || continue
    for f in "$bindir"/*; do
      base="$(basename "$f")"
      case "$base" in
        python3|python3.*|python) continue ;;
      esac
      [ -x "$f" ] && [ ! -e "$dir/$base" ] && ln -sf "$f" "$dir/$base" 2>/dev/null
    done
  done
  echo "$dir"
}

@test "install.sh requires an existing target directory" {
  run "$REPO_ROOT/install.sh" /no/such/directory-xyz
  [ "$status" -eq 1 ]
  [[ "$output" == *"사용법"* ]]
}

@test "install.sh refuses to install into the source repo itself" {
  run "$REPO_ROOT/install.sh" "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"설치할 필요가 없습니다"* ]]
}

@test "fresh install copies all hooks, skills, and a valid settings.json" {
  run "$REPO_ROOT/install.sh" "$TARGET" --no-onboard
  [ "$status" -eq 0 ]
  for h in $HOOKS; do
    [ -x "$TARGET/.claude/hooks/$h" ]
  done
  for s in $SKILLS; do
    [ -f "$TARGET/.claude/skills/$s/SKILL.md" ]
  done
  [ -f "$TARGET/.claude/settings.json" ]
  run python3 -c "import json; json.load(open('$TARGET/.claude/settings.json'))"
  [ "$status" -eq 0 ]
  # 스킬이 게이트 스크립트를 Bash 도구로 실행할 수 있게 하는 두 방어선 —
  # PreToolUse permission-gate.sh(결정론적, 플러그인 배치에서도 동작)와
  # 정적 permissions.allow 규칙(install.sh 배치 전용 보조 방어선). 둘 다
  # 없으면 권한이 막힌 세션에서 context-evolve가 스킵되어 Stop 게이트가
  # 새 세션마다 반복 발동한다.
  run python3 -c "
import json
d = json.load(open('$TARGET/.claude/settings.json'))
assert 'Bash(.claude/hooks/*)' in d['permissions']['allow']
assert any('permission-gate.sh' in h['command'] for m in d['hooks']['PreToolUse'] for h in m['hooks'])
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "re-running install.sh is idempotent: no diffs, no backups, no changes reported" {
  "$REPO_ROOT/install.sh" "$TARGET" --no-onboard >/dev/null
  run diff -rq "$REPO_ROOT/.claude/hooks" "$TARGET/.claude/hooks"
  [ "$status" -eq 0 ]
  run "$REPO_ROOT/install.sh" "$TARGET" --no-onboard
  [ "$status" -eq 0 ]
  [[ "$output" == *"변경 없음"* ]]
  [[ "$output" != *"백업"* ]]
  [ ! -d "$TARGET/.claude/backup" ]
}

@test "install merges hooks into an existing settings.json without losing custom keys" {
  mkdir -p "$TARGET/.claude"
  cat > "$TARGET/.claude/settings.json" << 'JSON'
{
  "customKey": "keep-me",
  "permissions": { "allow": [ "Bash(npm test)" ] },
  "hooks": {
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "echo custom-hook" } ] }
    ]
  }
}
JSON
  run "$REPO_ROOT/install.sh" "$TARGET" --no-onboard
  [ "$status" -eq 0 ]
  [[ "$output" == *"기존 설정 의미 보존"* ]]

  run python3 -c "
import json
d = json.load(open('$TARGET/.claude/settings.json'))
assert d['customKey'] == 'keep-me'
# 사용자가 이미 등록해 둔 PreToolUse 훅(다른 이벤트가 아니라 같은
# 이벤트!)이 그대로 남아 있어야 한다 — 우리 permission-gate.sh는 같은
# 배열에 '추가'되지, 대체하지 않는다.
assert d['hooks']['PreToolUse'][0]['hooks'][0]['command'] == 'echo custom-hook'
assert any('permission-gate.sh' in h['command'] for m in d['hooks']['PreToolUse'] for h in m['hooks'])
assert any('session-context.sh' in h['command'] for m in d['hooks']['SessionStart'] for h in m['hooks'])
assert any('evolve-gate.sh' in h['command'] for m in d['hooks']['Stop'] for h in m['hooks'])
assert any('prompt-freshness.sh' in h['command'] for m in d['hooks']['UserPromptSubmit'] for h in m['hooks'])
assert any('metrics-collector.sh' in h['command'] for m in d['hooks']['PostToolUse'] for h in m['hooks'])
assert 'Bash(npm test)' in d['permissions']['allow']
assert 'Bash(.claude/hooks/*)' in d['permissions']['allow']
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]

  backup_count=$(find "$TARGET/.claude/backup" -name settings.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$backup_count" -ge 1 ]
}

@test "re-running install after a merge reports settings.json as already registered" {
  # 커스텀 키가 있어야 병합 결과물이 저장소 원본 settings.json과 바이트 단위로
  # 달라져서 cmp -s 빠른 경로를 타지 않고, 실제로 merge_py의 "already" 판정
  # 경로(이미 등록된 훅인지 python으로 재확인)를 거치게 된다.
  mkdir -p "$TARGET/.claude"
  cat > "$TARGET/.claude/settings.json" << 'JSON'
{ "customKey": "keep-me", "hooks": {} }
JSON
  "$REPO_ROOT/install.sh" "$TARGET" --no-onboard >/dev/null
  run "$REPO_ROOT/install.sh" "$TARGET" --no-onboard
  [[ "$output" == *"훅 이미 등록됨"* ]]
}

@test "install falls back to an example file when python3 is unavailable, leaving the original untouched" {
  mkdir -p "$TARGET/.claude"
  echo '{"hooks": {}}' > "$TARGET/.claude/settings.json"
  cp "$TARGET/.claude/settings.json" "$BATS_TEST_TMPDIR/settings.orig.json"

  nopython="$(make_nopython_path)"
  PATH="$nopython" run "$REPO_ROOT/install.sh" "$TARGET" --no-onboard
  [ "$status" -eq 0 ]
  [[ "$output" == *"python3 없음"* ]]
  [ -f "$TARGET/.claude/settings.hooks-example.json" ]
  diff "$TARGET/.claude/settings.json" "$BATS_TEST_TMPDIR/settings.orig.json"
}

@test "a directory in place of a hook file is backed up (outside skills/) before replacement" {
  mkdir -p "$TARGET/.claude/hooks/session-context.sh"
  run "$REPO_ROOT/install.sh" "$TARGET" --no-onboard
  [ "$status" -eq 0 ]
  [[ "$output" == *"파일이 아님"* ]]
  [ -f "$TARGET/.claude/hooks/session-context.sh" ]
  [ ! -d "$TARGET/.claude/hooks/session-context.sh" ]
}

@test "a file in place of a skill directory is backed up before replacement" {
  mkdir -p "$TARGET/.claude/skills"
  echo "not a directory" > "$TARGET/.claude/skills/project-onboard"
  run "$REPO_ROOT/install.sh" "$TARGET" --no-onboard
  [ "$status" -eq 0 ]
  [[ "$output" == *"디렉터리가 아님"* ]]
  [ -d "$TARGET/.claude/skills/project-onboard" ]
  [ -f "$TARGET/.claude/skills/project-onboard/SKILL.md" ]
}

@test "backups of replaced hooks/skills never land inside .claude/skills (would double-register)" {
  mkdir -p "$TARGET/.claude/skills"
  echo "not a directory" > "$TARGET/.claude/skills/project-onboard"
  "$REPO_ROOT/install.sh" "$TARGET" --no-onboard >/dev/null
  run find "$TARGET/.claude/skills" -mindepth 1 -maxdepth 1 -type d
  # project-onboard, context-refresh, context-evolve 세 개만 있어야 하고
  # 백업본이 스킬 디렉터리인 척 섞여 들어가면 안 된다.
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 3 ]
}

@test "--no-onboard skips immediate document generation" {
  run "$REPO_ROOT/install.sh" "$TARGET" --no-onboard
  [[ "$output" == *"즉시 온보딩 건너뜀"* ]]
  [ ! -f "$TARGET/.cursor-context/project-context.md" ]
}

# ---------------------------------------------------------------
# 3-2: install.sh 자신의 출력 언어 기본값과 .cursor-context/config 생성 확인.
# 이 파일의 다른 테스트는 전부 setup()에서 LC_ALL=ko_KR.UTF-8을 강제해
# 기존 한국어 동작을 그대로 검증한다 — 여기서는 비-한국어 로케일(실제 CI
# 환경의 기본값과 같은 상황)에서 영어가 나오는지만 확인한다.
# ---------------------------------------------------------------

@test "install.sh defaults to English output under a non-Korean locale" {
  LC_ALL=C LANG=C run "$REPO_ROOT/install.sh" "$TARGET" --no-onboard
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installing into:"* ]]
  [[ "$output" == *"Install complete!"* ]]
  grep -q '^LANG=en$' "$TARGET/.cursor-context/config"
}

@test "install.sh writes .cursor-context/config with the guessed LANG and does not overwrite an existing one" {
  run "$REPO_ROOT/install.sh" "$TARGET" --no-onboard
  grep -q '^LANG=ko$' "$TARGET/.cursor-context/config"
  echo "LANG=en
FEEDBACK_THRESHOLD=42" > "$TARGET/.cursor-context/config"
  run "$REPO_ROOT/install.sh" "$TARGET" --no-onboard
  [[ "$output" == *"기존 파일 유지"* ]]
  grep -q '^FEEDBACK_THRESHOLD=42$' "$TARGET/.cursor-context/config"
}

# ---------------------------------------------------------------
# 3-3: install.sh --uninstall
# ---------------------------------------------------------------

@test "--uninstall removes hooks/skills and settings.json hook entries, backing everything up first" {
  "$REPO_ROOT/install.sh" "$TARGET" --no-onboard >/dev/null
  run "$REPO_ROOT/install.sh" "$TARGET" --uninstall
  [ "$status" -eq 0 ]
  for h in $HOOKS; do
    [ ! -e "$TARGET/.claude/hooks/$h" ]
  done
  for s in $SKILLS; do
    [ ! -e "$TARGET/.claude/skills/$s" ]
  done
  # backed up, not gone for good
  found_hook_backup=$(find "$TARGET/.claude/backup" -path "*/uninstall-*/hooks/session-context.sh" 2>/dev/null | wc -l | tr -d ' ')
  [ "$found_hook_backup" -ge 1 ]
  found_skill_backup=$(find "$TARGET/.claude/backup" -path "*/uninstall-*/skills/project-onboard" 2>/dev/null | wc -l | tr -d ' ')
  [ "$found_skill_backup" -ge 1 ]
  # settings.json: our 5 hook entries and permission rule gone, file still valid JSON
  run python3 -c "
import json
d = json.load(open('$TARGET/.claude/settings.json'))
h = d.get('hooks', {})
assert not any('session-context.sh' in hk.get('command','') for m in h.get('SessionStart', []) for hk in m.get('hooks', []))
assert not any('evolve-gate.sh' in hk.get('command','') for m in h.get('Stop', []) for hk in m.get('hooks', []))
assert not any('permission-gate.sh' in hk.get('command','') for m in h.get('PreToolUse', []) for hk in m.get('hooks', []))
assert 'Bash(.claude/hooks/*)' not in d.get('permissions', {}).get('allow', [])
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
  # .cursor-context/ (generated data) survives by default
  [ -d "$TARGET/.cursor-context" ]
}

@test "--uninstall preserves other hooks sharing the same event in settings.json" {
  "$REPO_ROOT/install.sh" "$TARGET" --no-onboard >/dev/null
  run python3 -c "
import json
p = '$TARGET/.claude/settings.json'
d = json.load(open(p))
d['hooks'].setdefault('PostToolUse', []).append({'matcher': 'Write', 'hooks': [{'type': 'command', 'command': 'echo my-own-hook'}]})
json.dump(d, open(p, 'w'), indent=2)
"
  [ "$status" -eq 0 ]
  run "$REPO_ROOT/install.sh" "$TARGET" --uninstall
  [ "$status" -eq 0 ]
  run python3 -c "
import json
d = json.load(open('$TARGET/.claude/settings.json'))
assert any(hk.get('command') == 'echo my-own-hook' for m in d['hooks'].get('PostToolUse', []) for hk in m.get('hooks', []))
assert not any('metrics-collector.sh' in hk.get('command','') for m in d['hooks'].get('PostToolUse', []) for hk in m.get('hooks', []))
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "--uninstall preserves the user's own PreToolUse hook while removing only permission-gate.sh" {
  "$REPO_ROOT/install.sh" "$TARGET" --no-onboard >/dev/null
  run python3 -c "
import json
p = '$TARGET/.claude/settings.json'
d = json.load(open(p))
d['hooks'].setdefault('PreToolUse', []).append({'matcher': 'Write', 'hooks': [{'type': 'command', 'command': 'echo my-own-pretooluse-hook'}]})
json.dump(d, open(p, 'w'), indent=2)
"
  [ "$status" -eq 0 ]
  run "$REPO_ROOT/install.sh" "$TARGET" --uninstall
  [ "$status" -eq 0 ]
  run python3 -c "
import json
d = json.load(open('$TARGET/.claude/settings.json'))
assert any(hk.get('command') == 'echo my-own-pretooluse-hook' for m in d['hooks'].get('PreToolUse', []) for hk in m.get('hooks', []))
assert not any('permission-gate.sh' in hk.get('command','') for m in d['hooks'].get('PreToolUse', []) for hk in m.get('hooks', []))
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "--uninstall removes only our permission rule, preserving the user's own allow entries" {
  "$REPO_ROOT/install.sh" "$TARGET" --no-onboard >/dev/null
  python3 -c "
import json
p = '$TARGET/.claude/settings.json'
d = json.load(open(p))
d['permissions']['allow'].append('Bash(git ls-remote *)')
json.dump(d, open(p, 'w'), indent=2)
"
  run "$REPO_ROOT/install.sh" "$TARGET" --uninstall
  [ "$status" -eq 0 ]
  run python3 -c "
import json
d = json.load(open('$TARGET/.claude/settings.json'))
allow = d.get('permissions', {}).get('allow', [])
assert 'Bash(git ls-remote *)' in allow
assert 'Bash(.claude/hooks/*)' not in allow
print('ok')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "--uninstall --purge-data also removes .cursor-context/" {
  "$REPO_ROOT/install.sh" "$TARGET" --no-onboard >/dev/null
  [ -d "$TARGET/.cursor-context" ]
  run "$REPO_ROOT/install.sh" "$TARGET" --uninstall --purge-data
  [ "$status" -eq 0 ]
  [ ! -d "$TARGET/.cursor-context" ]
}

@test "--uninstall on a project with nothing installed reports nothing to do" {
  run "$REPO_ROOT/install.sh" "$TARGET" --uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"제거할 것이 없습니다"* ]]
}

@test "re-running --uninstall after an uninstall reports no hook entries left to remove" {
  "$REPO_ROOT/install.sh" "$TARGET" --no-onboard >/dev/null
  "$REPO_ROOT/install.sh" "$TARGET" --uninstall >/dev/null
  mkdir -p "$TARGET/.claude/hooks"
  cp "$REPO_ROOT/.claude/hooks/session-context.sh" "$TARGET/.claude/hooks/"
  run "$REPO_ROOT/install.sh" "$TARGET" --uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"이 툴킷의 훅 등록이 없음"* ]]
}
