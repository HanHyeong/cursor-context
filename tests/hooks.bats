#!/usr/bin/env bats
# session-context.sh(SessionStart), prompt-freshness.sh(UserPromptSubmit),
# evolve-gate.sh(Stop), metrics-collector.sh(PostToolUse) 검증.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_DIR="$(mktemp -d)"
  mkdir -p "$TEST_DIR/.claude/hooks" "$TEST_DIR/.claude/skills/context-evolve"
  cp "$REPO_ROOT"/.claude/hooks/*.sh "$TEST_DIR/.claude/hooks/"
  echo "ok" > "$TEST_DIR/.claude/skills/context-evolve/SKILL.md"
  chmod +x "$TEST_DIR/.claude/hooks/"*.sh
  cd "$TEST_DIR"
  git init -q
  git config user.email test@example.com
  git config user.name test
  echo '{"name":"x"}' > package.json
  # 실제 툴킷 사용과 동일하게 .cursor-context/를 gitignore해 둔다 — 안 그러면
  # 아래에서 만드는 config 파일 자체가 git status의 미추적 변경 건수에 잡혀
  # "몇 건 생략" 같은 개수 기반 단언이 테스트마다 어긋난다.
  echo ".cursor-context/" > .gitignore
  git add -A
  git commit -qm init
  export CLAUDE_PROJECT_DIR="$TEST_DIR"
  # 3-2(설정화) 이후 기본 언어는 en으로 바뀌었다. 이 스위트의 기존 단언은
  # 원래 동작(한국어 출력)을 그대로 검증하는 것이 목적이므로 LANG=ko를
  # 명시한다 — 영어 기본값과 임계값 설정은 아래 별도 테스트에서 확인한다.
  mkdir -p .cursor-context
  echo "LANG=ko" > .cursor-context/config
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------
# session-context.sh
# ---------------------------------------------------------------

@test "session-context.sh wraps its output in snapshot tags" {
  run .claude/hooks/session-context.sh
  [ "$status" -eq 0 ]
  [[ "$output" == "<project-context-snapshot>"* ]]
  [[ "$output" == *"</project-context-snapshot>" ]]
}

@test "session-context.sh detects the Node.js stack from package.json" {
  run .claude/hooks/session-context.sh
  [[ "$output" == *"## 기술 스택"* ]]
  [[ "$output" == *"Node.js 프로젝트"* ]]
}

@test "session-context.sh reports git branch and recent commits" {
  run .claude/hooks/session-context.sh
  [[ "$output" == *"## Git 상태"* ]]
  [[ "$output" == *"최근 커밋"* ]]
}

@test "session-context.sh instructs doc generation when no project doc exists yet" {
  run .claude/hooks/session-context.sh
  [[ "$output" == *"자동 생성 프로젝트 문서(.cursor-context/project-context.md) 없음"* ]]
}

@test "session-context.sh truncates uncommitted-changes listing past 20 and says how many were omitted" {
  for i in $(seq 1 25); do echo "x$i" > "file$i.txt"; done
  run .claude/hooks/session-context.sh
  [[ "$output" == *"커밋되지 않은 변경사항:"* ]]
  [[ "$output" == *"(…5건 생략…)"* ]]
}

@test "session-context.sh cleans up stale evolve-gate sentinels (older than a day) but keeps fresh ones" {
  mkdir -p .cursor-context
  touch -d "2 days ago" .cursor-context/.gate-fired-old 2>/dev/null \
    || touch -t "$(date -v-2d +%Y%m%d%H%M)" .cursor-context/.gate-fired-old
  touch .cursor-context/.gate-fired-fresh
  run .claude/hooks/session-context.sh
  [ "$status" -eq 0 ]
  [ ! -e .cursor-context/.gate-fired-old ]
  [ -e .cursor-context/.gate-fired-fresh ]
}

# ---------------------------------------------------------------
# prompt-freshness.sh
# ---------------------------------------------------------------

write_matching_doc() {
  mkdir -p .cursor-context
  {
    echo "# doc"
    echo "<!-- generated-at-commit: $(git rev-parse HEAD) -->"
    echo "<!-- context-fingerprint-begin"
    .claude/hooks/context-fingerprint.sh
    echo "context-fingerprint-end -->"
  } > .cursor-context/project-context.md
}

@test "prompt-freshness.sh prints nothing when the doc matches the working tree" {
  write_matching_doc
  run .claude/hooks/prompt-freshness.sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prompt-freshness.sh warns in real time when the working tree diverges from the doc" {
  write_matching_doc
  echo '{"name":"x","version":"2.0.0"}' > package.json
  run .claude/hooks/prompt-freshness.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"<context-freshness-alert>"* ]]
  [[ "$output" == *"package.json"* ]]
}

@test "prompt-freshness.sh stays silent when there is no project doc yet" {
  run .claude/hooks/prompt-freshness.sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------
# evolve-gate.sh (threshold + per-session sentinel — regression test for 1-1)
# ---------------------------------------------------------------

seed_signals() {
  mkdir -p .cursor-context
  echo "# doc" > .cursor-context/project-context.md
  : > .cursor-context/context-feedback.jsonl
  for _ in 1 2 3 4 5; do echo '{"type":"gap"}' >> .cursor-context/context-feedback.jsonl; done
}

@test "evolve-gate.sh passes when signal is below threshold" {
  mkdir -p .cursor-context
  echo "# doc" > .cursor-context/project-context.md
  echo '{"stop_hook_active": false, "session_id": "s1"}' > input.json
  run .claude/hooks/evolve-gate.sh < input.json
  [ "$status" -eq 0 ]
}

@test "evolve-gate.sh blocks the first Stop past threshold and writes a session sentinel" {
  seed_signals
  echo '{"stop_hook_active": false, "session_id": "session-A"}' > input.json
  run .claude/hooks/evolve-gate.sh < input.json
  [ "$status" -eq 2 ]
  [ -f .cursor-context/.gate-fired-session-A ]
}

@test "evolve-gate.sh passes every later turn in the same session once it has fired (bug 1-1)" {
  seed_signals
  echo '{"stop_hook_active": false, "session_id": "session-A"}' > input.json
  .claude/hooks/evolve-gate.sh < input.json || true
  # threshold is still crossed (nothing consumed the signal files) — before the
  # 1-1 fix this second Stop of a later turn would block again with exit 2.
  run .claude/hooks/evolve-gate.sh < input.json
  [ "$status" -eq 0 ]
}

@test "evolve-gate.sh blocks again in a brand new session" {
  seed_signals
  echo '{"stop_hook_active": false, "session_id": "session-A"}' > input-a.json
  echo '{"stop_hook_active": false, "session_id": "session-B"}' > input-b.json
  .claude/hooks/evolve-gate.sh < input-a.json || true
  run .claude/hooks/evolve-gate.sh < input-b.json
  [ "$status" -eq 2 ]
}

@test "evolve-gate.sh always passes when stop_hook_active is true" {
  seed_signals
  echo '{"stop_hook_active": true, "session_id": "session-A"}' > input.json
  run .claude/hooks/evolve-gate.sh < input.json
  [ "$status" -eq 0 ]
}

@test "evolve-gate.sh does nothing when there is no project doc yet" {
  echo '{"stop_hook_active": false, "session_id": "session-A"}' > input.json
  run .claude/hooks/evolve-gate.sh < input.json
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------
# metrics-collector.sh
# ---------------------------------------------------------------

@test "metrics-collector.sh logs a Read tool call with its path" {
  echo '{"tool_name":"Read","tool_input":{"file_path":"foo.txt"}}' > input.json
  run .claude/hooks/metrics-collector.sh < input.json
  [ "$status" -eq 0 ]
  grep -q '"tool": "Read"' .cursor-context/metrics.jsonl
  grep -q '"path": "foo.txt"' .cursor-context/metrics.jsonl
}

@test "metrics-collector.sh logs a Bash tool call with its command" {
  echo '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' > input.json
  run .claude/hooks/metrics-collector.sh < input.json
  [ "$status" -eq 0 ]
  grep -q '"cmd": "npm test"' .cursor-context/metrics.jsonl
}

@test "metrics-collector.sh records the session id when the hook input provides one" {
  echo '{"session_id":"sess-abc","tool_name":"Read","tool_input":{"file_path":"foo.txt"}}' > input.json
  run .claude/hooks/metrics-collector.sh < input.json
  [ "$status" -eq 0 ]
  grep -q '"sid": "sess-abc"' .cursor-context/metrics.jsonl
}

@test "metrics-collector.sh does not log toolkit self-observation (.cursor-context targets)" {
  rm -f .cursor-context/metrics.jsonl
  echo '{"tool_name":"Read","tool_input":{"file_path":".cursor-context/metrics.jsonl"}}' > input.json
  run .claude/hooks/metrics-collector.sh < input.json
  [ "$status" -eq 0 ]
  echo '{"tool_name":"Bash","tool_input":{"command":"cat .cursor-context/context-feedback.jsonl"}}' > input.json
  run .claude/hooks/metrics-collector.sh < input.json
  [ "$status" -eq 0 ]
  [ ! -f .cursor-context/metrics.jsonl ]
}

@test "metrics-collector.sh --digest aggregates hits and distinct sessions deterministically" {
  cat > .cursor-context/metrics.jsonl <<'EOF'
{"ts": 100, "tool": "Read", "sid": "s1", "path": "/p/src/a.js"}
{"ts": 200, "tool": "Read", "sid": "s2", "path": "/p/src/b.js"}
{"ts": 300, "tool": "Bash", "sid": "s1", "cmd": "npm test --silent"}
{"ts": 400, "tool": "Bash", "sid": "s2", "cmd": "npm test"}
{"ts": 500, "tool": "Grep", "sid": "s1", "pattern": "foo", "path": "src"}
{"ts": 600, "tool": "Bash", "sid": "s2", "cmd": "cd /tmp && npm test"}
not-json-garbage-line
EOF
  run .claude/hooks/metrics-collector.sh --digest
  [ "$status" -eq 0 ]
  [[ "$output" == *"6 entries, 2 sessions"* ]]
  # 게이트(awk, 비어 있지 않은 줄 수)와의 계수 차이가 보이도록 파싱 불가 줄 수를 보고한다
  [[ "$output" == *"1 unparsable lines skipped"* ]]
  # npm test: 체인 명령(cd /tmp && npm test)의 세그먼트 계수 포함 3회, 세션 2개
  echo "$output" | grep -qE '^ +3 +2 +npm test$'
  echo "$output" | grep -qE '^ +1 +1 +cd /tmp$'
  echo "$output" | grep -qE '^ +2 +2 +/p/src$'
  echo "$output" | grep -qE '^ +1 +1 +src$'
}

@test "metrics-collector.sh --digest ranks cross-session repetition above single-session hit counts" {
  # 4회지만 한 세션뿐인 항목보다 2회·2세션 항목이 위에 와야 한다 —
  # 세션 간 반복이 문서 갭의 핵심 증거라는 다이제스트의 존재 이유 그 자체.
  cat > .cursor-context/metrics.jsonl <<'EOF'
{"ts": 1, "tool": "Bash", "sid": "s1", "cmd": "make lint"}
{"ts": 2, "tool": "Bash", "sid": "s1", "cmd": "make lint"}
{"ts": 3, "tool": "Bash", "sid": "s1", "cmd": "make lint"}
{"ts": 4, "tool": "Bash", "sid": "s1", "cmd": "make lint"}
{"ts": 5, "tool": "Bash", "sid": "s1", "cmd": "make deploy-check"}
{"ts": 6, "tool": "Bash", "sid": "s2", "cmd": "make deploy-check"}
EOF
  run .claude/hooks/metrics-collector.sh --digest
  [ "$status" -eq 0 ]
  first_row=$(echo "$output" | grep -E '^ +[0-9]+ +[0-9]+ +make' | head -1)
  [[ "$first_row" == *"make deploy-check"* ]]
}

@test "metrics-collector.sh keeps a grep whose pattern mentions .cursor-context but targets real source" {
  rm -f .cursor-context/metrics.jsonl
  echo '{"tool_name":"Grep","tool_input":{"pattern":".cursor-context","path":"src/"}}' > input.json
  run .claude/hooks/metrics-collector.sh < input.json
  [ "$status" -eq 0 ]
  grep -q '"path": "src/"' .cursor-context/metrics.jsonl
}

@test "metrics-collector.sh does not log invocations of the toolkit's own scripts" {
  rm -f .cursor-context/metrics.jsonl
  echo '{"tool_name":"Bash","tool_input":{"command":".claude/hooks/context-benchmark.sh doc.md"}}' > input.json
  run .claude/hooks/metrics-collector.sh < input.json
  [ "$status" -eq 0 ]
  echo '{"tool_name":"Bash","tool_input":{"command":"bash .claude/hooks/metrics-collector.sh --digest"}}' > input.json
  run .claude/hooks/metrics-collector.sh < input.json
  [ "$status" -eq 0 ]
  [ ! -f .cursor-context/metrics.jsonl ]
}

@test "metrics-collector.sh redacts credential-shaped values in logged Bash commands" {
  echo '{"tool_name":"Bash","tool_input":{"command":"curl -H \"Authorization: Bearer abc123xyz\" --api-key=SUPERSECRET https://example.com && export DB_PASSWORD=hunter2 && npm test"}}' > input.json
  run .claude/hooks/metrics-collector.sh < input.json
  [ "$status" -eq 0 ]
  grep -q 'redacted' .cursor-context/metrics.jsonl
  ! grep -q 'SUPERSECRET' .cursor-context/metrics.jsonl
  ! grep -q 'abc123xyz' .cursor-context/metrics.jsonl
  ! grep -q 'hunter2' .cursor-context/metrics.jsonl
  # 명령의 형태(무엇을 하려 했는지)는 신호로 남아야 한다
  grep -q 'npm test' .cursor-context/metrics.jsonl
}

@test "metrics-collector.sh ignores tool calls it does not track" {
  echo '{"tool_name":"Write","tool_input":{"file_path":"foo.txt"}}' > input.json
  run .claude/hooks/metrics-collector.sh < input.json
  [ "$status" -eq 0 ]
  [ ! -f .cursor-context/metrics.jsonl ]
}

@test "metrics-collector.sh does not log while a benchmark run is in progress" {
  echo '{"tool_name":"Read","tool_input":{"file_path":"foo.txt"}}' > input.json
  run env CURSOR_CONTEXT_BENCH=1 .claude/hooks/metrics-collector.sh < input.json
  [ "$status" -eq 0 ]
  [ ! -f .cursor-context/metrics.jsonl ]
}

@test "metrics-collector.sh rotates the log instead of growing without bound (2,000-line cap)" {
  mkdir -p .cursor-context
  : > .cursor-context/metrics.jsonl
  for _ in $(seq 1 2500); do echo '{"ts": 1, "tool": "Read", "path": "x"}' >> .cursor-context/metrics.jsonl; done
  echo '{"tool_name":"Read","tool_input":{"file_path":"foo.txt"}}' > input.json
  for _ in $(seq 1 1000); do
    .claude/hooks/metrics-collector.sh < input.json >/dev/null 2>&1
  done
  total=$(wc -l < .cursor-context/metrics.jsonl | tr -d ' ')
  # 회전이 한 번도 안 걸렸다면 2500+1000=3500줄이 된다. 회전 검사는 호출당
  # 1% 확률로만 도니, 1000번 시도에서 한 번도 안 걸릴 확률은 0.99^1000 ≈
  # 0.00004로 사실상 0 — 총 줄 수가 그보다 훨씬 작아야 정상이다.
  [ "$total" -lt 3000 ]
}

# ---------------------------------------------------------------
# 3-2: 언어 기본값(en)과 설정값(.cursor-context/config) 반영 확인.
# 이 파일의 다른 테스트는 전부 setup()에서 LANG=ko를 명시해 기존 한국어
# 동작을 그대로 검증한다 — 여기서는 en 기본값과 설정 재정의만 확인한다.
# ---------------------------------------------------------------

@test "session-context.sh defaults to English when no config file is present" {
  rm -f .cursor-context/config
  run .claude/hooks/session-context.sh
  [[ "$output" == *"## Tech stack"* ]]
  [[ "$output" == *"Node.js project"* ]]
  [[ "$output" != *"## 기술 스택"* ]]
}

@test "prompt-freshness.sh defaults to English when no config file is present" {
  rm -f .cursor-context/config
  write_matching_doc
  echo '{"name":"x","version":"2.0.0"}' > package.json
  run .claude/hooks/prompt-freshness.sh
  [[ "$output" == *"<context-freshness-alert>"* ]]
  [[ "$output" == *"has diverged from the context doc"* ]]
}

@test "evolve-gate.sh defaults to English when no config file is present" {
  rm -f .cursor-context/config
  seed_signals
  echo '{"stop_hook_active": false, "session_id": "session-en"}' > input.json
  run .claude/hooks/evolve-gate.sh < input.json
  [ "$status" -eq 2 ]
  [[ "$output" == *"Accumulated usage signal"* ]]
}

@test "evolve-gate.sh honors FEEDBACK_THRESHOLD/METRICS_THRESHOLD from config" {
  mkdir -p .cursor-context
  echo "# doc" > .cursor-context/project-context.md
  : > .cursor-context/context-feedback.jsonl
  echo '{"type":"gap"}' >> .cursor-context/context-feedback.jsonl
  echo '{"type":"gap"}' >> .cursor-context/context-feedback.jsonl
  cat > .cursor-context/config << 'EOF'
FEEDBACK_THRESHOLD=2
EOF
  echo '{"stop_hook_active": false, "session_id": "session-cfg"}' > input.json
  run .claude/hooks/evolve-gate.sh < input.json
  # 기본값(5)이었다면 2건으로는 통과했을 것 — 설정으로 낮춘 임계값(2)이
  # 실제로 반영되어 차단되는지 확인한다.
  [ "$status" -eq 2 ]
}


# ---------------------------------------------------------------
# 3-1 (플러그인 패키징) 호환성 회귀 테스트: 훅이 $CLAUDE_PROJECT_DIR/.claude/hooks/
# 밖(예: 플러그인의 $CLAUDE_PLUGIN_ROOT/hooks/)에 있어도 형제 스크립트
# (context-fingerprint.sh, lib-config.sh)를 스스로 찾아내는지 확인한다.
# HOOK_DIR을 $BASH_SOURCE 기반 자기 위치 계산으로 바꾼 것에 대한 고정 테스트.
# ---------------------------------------------------------------

@test "context-benchmark.sh finds its sibling scripts even when installed outside .claude/hooks/ (plugin layout)" {
  PLUGIN_DIR="$(mktemp -d)/hooks"
  mkdir -p "$PLUGIN_DIR"
  cp "$REPO_ROOT"/.claude/hooks/context-benchmark.sh "$REPO_ROOT"/.claude/hooks/context-fingerprint.sh "$REPO_ROOT"/.claude/hooks/lib-config.sh "$PLUGIN_DIR/"
  chmod +x "$PLUGIN_DIR"/*.sh
  { echo "<!-- generated-at-commit: 0000000000000000000000000000000000000a -->"; yes "doc body" | head -n 20; } > doc.md
  run "$PLUGIN_DIR/context-benchmark.sh" doc.md
  [ "$status" -eq 0 ]
  # 지문 헬퍼를 못 찾았다면 "지문 검증 불가"가 아니라 "명령을 찾을 수 없음"류의
  # 에러가 났을 것이다 — WARN(지문 블록 없음)이 정상적으로 뜬다는 것은
  # context-fingerprint.sh를 성공적으로 찾아 호출했다는 뜻이다.
  [[ "$output" == *"지문 블록 없음"* ]]
  [[ "$output" != *"command not found"* ]]
  [[ "$output" != *"No such file"* ]]
}

@test "prompt-freshness.sh finds context-fingerprint.sh even when installed outside .claude/hooks/ (plugin layout)" {
  PLUGIN_DIR="$(mktemp -d)/hooks"
  mkdir -p "$PLUGIN_DIR"
  cp "$REPO_ROOT"/.claude/hooks/prompt-freshness.sh "$REPO_ROOT"/.claude/hooks/context-fingerprint.sh "$REPO_ROOT"/.claude/hooks/lib-config.sh "$PLUGIN_DIR/"
  chmod +x "$PLUGIN_DIR"/*.sh
  {
    echo "<!-- generated-at-commit: $(git rev-parse HEAD) -->"
    echo "<!-- context-fingerprint-begin"
    "$PLUGIN_DIR/context-fingerprint.sh"
    echo "context-fingerprint-end -->"
  } > .cursor-context/project-context.md
  echo '{"name":"x","version":"2.0.0"}' > package.json
  run "$PLUGIN_DIR/prompt-freshness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<context-freshness-alert>"* ]]
  [[ "$output" == *"package.json"* ]]
}

@test "evolve-gate.sh blocks under a plugin-only layout (skill beside the hook dir, no project .claude/)" {
  PLUGIN_ROOT="$(mktemp -d)"
  mkdir -p "$PLUGIN_ROOT/hooks" "$PLUGIN_ROOT/skills/context-evolve"
  cp "$REPO_ROOT"/.claude/hooks/evolve-gate.sh "$REPO_ROOT"/.claude/hooks/lib-config.sh "$PLUGIN_ROOT/hooks/"
  chmod +x "$PLUGIN_ROOT/hooks/"*.sh
  echo "ok" > "$PLUGIN_ROOT/skills/context-evolve/SKILL.md"
  rm -rf .claude   # 플러그인 단독 설치: 프로젝트에 .claude/가 없다
  seed_signals
  echo '{"stop_hook_active": false, "session_id": "plugin-sess"}' > input.json
  run "$PLUGIN_ROOT/hooks/evolve-gate.sh" < input.json
  [ "$status" -eq 2 ]
  [ -f .cursor-context/.gate-fired-plugin-sess ]
}

@test "metrics-collector.sh logs under a plugin-only layout (no project .claude/)" {
  PLUGIN_ROOT="$(mktemp -d)"
  mkdir -p "$PLUGIN_ROOT/hooks"
  cp "$REPO_ROOT"/.claude/hooks/metrics-collector.sh "$PLUGIN_ROOT/hooks/"
  chmod +x "$PLUGIN_ROOT/hooks/"*.sh
  rm -rf .claude   # 플러그인 단독 설치: 프로젝트에 .claude/가 없다
  echo '{"tool_name":"Read","tool_input":{"file_path":"foo.txt"}}' > input.json
  run "$PLUGIN_ROOT/hooks/metrics-collector.sh" < input.json
  [ "$status" -eq 0 ]
  grep -q '"path": "foo.txt"' .cursor-context/metrics.jsonl
}

@test "session-context.sh honors COMMIT_BACKSTOP from config" {
  echo "LANG=ko
COMMIT_BACKSTOP=2" > .cursor-context/config
  {
    echo "# doc"
    echo "<!-- generated-at-commit: $(git rev-parse HEAD) -->"
    echo "<!-- context-fingerprint-begin"
    .claude/hooks/context-fingerprint.sh
    echo "context-fingerprint-end -->"
  } > .cursor-context/project-context.md
  echo "extra1" > extra1.txt
  git add -A && git commit -qm c1
  echo "extra2" > extra2.txt
  git add -A && git commit -qm c2
  echo "extra3" > extra3.txt
  git add -A && git commit -qm c3
  run .claude/hooks/session-context.sh
  # 기본값(20)이라면 커밋 3개로는 백스톱이 걸리지 않았을 것 — COMMIT_BACKSTOP=2로
  # 낮췄으니 커밋이 3개 쌓인 지금 백스톱 안내가 떠야 한다.
  [[ "$output" == *"문서 생성 후 커밋이 3개 쌓였습니다"* ]]
}
