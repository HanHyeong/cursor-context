#!/usr/bin/env bats
# context-benchmark.sh 문서 품질 게이트 검증: 줄 수 판정(PASS/WARN/FAIL),
# 존재하지 않는 npm/yarn 스크립트·make 타깃은 FAIL(정확 검사), 존재하지
# 않는 경로는 WARN(휴리스틱)만 — 게이트 완화 없이 정확히 이 등급대로.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_DIR="$(mktemp -d)"
  mkdir -p "$TEST_DIR/.claude/hooks" "$TEST_DIR/.cursor-context"
  cp "$REPO_ROOT/.claude/hooks/context-benchmark.sh" "$TEST_DIR/.claude/hooks/"
  cp "$REPO_ROOT/.claude/hooks/context-fingerprint.sh" "$TEST_DIR/.claude/hooks/"
  cp "$REPO_ROOT/.claude/hooks/lib-config.sh" "$TEST_DIR/.claude/hooks/"
  chmod +x "$TEST_DIR/.claude/hooks/"*.sh
  cd "$TEST_DIR"
  export CLAUDE_PROJECT_DIR="$TEST_DIR"
  # 3-2(설정화) 이후 기본 언어는 en으로 바뀌었다. 이 스위트의 기존 단언은
  # 원래 동작(한국어 출력)을 그대로 검증하는 것이 목적이므로 LANG=ko를
  # 명시한다 — 영어 기본값 자체는 아래 별도 테스트에서 확인한다.
  echo "LANG=ko" > .cursor-context/config
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
}

# 마커 존재 여부만 검사하는 항목(generated-at-commit)은 값이 실제 커밋일
# 필요가 없다 — 형식(7~40자 hex)만 맞으면 된다.
marker() { echo "<!-- generated-at-commit: 0000000000000000000000000000000000000a -->"; }

# N줄짜리 무해한 본문 생성 (마커 라인은 세지 않으므로 정확히 N줄이 본문에 더해진다)
body_of() { yes "line" | head -n "$1"; }

@test "a body under 200 lines PASSes the line budget" {
  { marker; body_of 50; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"PASS: 본문 50줄 (목표 200 이내)"* ]]
  [ "$status" -eq 0 ]
}

@test "a body between 201 and 250 lines WARNs but still passes the gate" {
  { marker; body_of 230; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"WARN: 본문 230줄 (200 초과 — 다이어트 권장)"* ]]
  [ "$status" -eq 0 ]
}

@test "a body over 250 lines FAILs and blocks adoption" {
  { marker; body_of 300; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"FAIL: 본문 300줄 — 250 초과, 주입 시 잘림"* ]]
  [ "$status" -eq 1 ]
}

@test "an effectively empty body FAILs the minimum-content floor (delete-everything mutation is never adoptable)" {
  # 마커만 있고 실질 본문이 거의 없는 문서 — 예산 상한만으로는 나머지 검사를
  # 전부 공허하게 PASS해(언급 명령·경로가 없으니) 채택될 수 있었던 퇴행 케이스다.
  { marker; echo "# t"; echo ""; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"FAIL: 본문 실질 1줄 — 최소 10 미만"* ]]
  [ "$status" -eq 1 ]
}

@test "DOC_MIN_LINES in the config file overrides the default floor of 10" {
  cat > .cursor-context/config << 'EOF'
LANG=ko
DOC_MIN_LINES=3
EOF
  { marker; body_of 5; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"PASS: 본문 실질 5줄 (최소 3 이상)"* ]]
  [ "$status" -eq 0 ]
}

@test "a missing generated-at-commit marker FAILs" {
  body_of 10 > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"FAIL: generated-at-commit 마커 없음"* ]]
  [ "$status" -eq 1 ]
}

@test "a missing doc file FAILs immediately with a PASS=0/WARN=0/FAIL=1 summary" {
  run .claude/hooks/context-benchmark.sh no-such-doc.md
  [[ "$output" == *"FAIL: 문서 없음"* ]]
  [[ "$output" == *"결과: PASS=0 WARN=0 FAIL=1"* ]]
  [ "$status" -eq 1 ]
}

@test "a documented npm script that exists PASSes" {
  echo '{"scripts": {"build": "tsc"}}' > package.json
  { marker; body_of 20; echo 'Run `npm run build`.'; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"PASS: 문서의 'npm run' 명령 전부 실재"* ]]
  [ "$status" -eq 0 ]
}

@test "a documented npm script that does not exist FAILs (exact check)" {
  echo '{"scripts": {"build": "tsc"}}' > package.json
  { marker; body_of 20; echo 'Run `npm run ghost-script`.'; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"FAIL: 문서가 언급한 존재하지 않는 npm 스크립트: ghost-script"* ]]
  [ "$status" -eq 1 ]
}

@test "yarn's run-omitted shorthand is checked too, without false-failing on yarn builtins" {
  echo '{"scripts": {"test": "jest"}}' > package.json
  { marker; body_of 20; echo 'Use `yarn test`, `yarn install`, and `yarn ghost`.'; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"FAIL: 문서가 언급한 존재하지 않는 npm 스크립트: ghost"* ]]
  [ "$status" -eq 1 ]
}

@test "a documented make target that exists PASSes" {
  printf 'build:\n\techo hi\n' > Makefile
  { marker; body_of 20; echo 'Run `make build`.'; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"PASS: 문서의 make 타깃 전부 실재"* ]]
  [ "$status" -eq 0 ]
}

@test "a documented make target that does not exist FAILs (exact check)" {
  printf 'build:\n\techo hi\n' > Makefile
  { marker; body_of 20; echo 'Run `make ghost-target`.'; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"FAIL: 문서가 언급한 존재하지 않는 make 타깃: ghost-target"* ]]
  [ "$status" -eq 1 ]
}

@test "a documented path that does not exist WARNs but does not fail the gate (heuristic)" {
  { marker; body_of 20; echo 'See `src/ghost/file.ts` for details.'; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"WARN: 문서가 언급했지만 존재하지 않는 경로"* ]]
  [[ "$output" == *"src/ghost/file.ts"* ]]
  [ "$status" -eq 0 ]
}

@test "a documented path that exists PASSes" {
  mkdir -p src
  echo "ok" > src/real.ts
  { marker; body_of 20; echo 'See `src/real.ts` for details.'; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"PASS: 문서 언급 경로 1개 전부 실재"* ]]
  [ "$status" -eq 0 ]
}

@test "overall summary line reflects the PASS/WARN/FAIL tally" {
  echo '{"scripts": {"build": "tsc"}}' > package.json
  { marker; echo 'Run `npm run build`.'; body_of 50; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"결과: PASS="*" WARN="*" FAIL=0"* ]]
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------
# 3-2: 언어 기본값(en)과 DOC_LINE_BUDGET 설정화 확인.
# PASS/WARN/FAIL 접두어와 "Result:"/"결과:" 자체는 번역 대상이지만, 두 값
# 모두 context-evolve/SKILL.md가 참조하는 "FAIL=0"/"PASS 수" 형식은 언어와
# 무관하게 고정이다(위 파일 상단 검사에서 이미 다룸) — 여기서는 설명
# 텍스트가 실제로 영어로 나오는지와 설정값 반영만 확인한다.
# ---------------------------------------------------------------

@test "English is the default language when no config file is present" {
  rm -f .cursor-context/config
  { marker; body_of 50; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"PASS: body: 50 lines (target: within 200)"* ]]
  [[ "$output" == *"Result: PASS="* ]]
  [ "$status" -eq 0 ]
}

@test "DOC_LINE_BUDGET in the config file overrides the default 200-line target" {
  cat > .cursor-context/config << 'EOF'
LANG=en
DOC_LINE_BUDGET=10
EOF
  { marker; body_of 15; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"WARN: body: 15 lines (over 10 -- trim recommended)"* ]]
  [ "$status" -eq 0 ]
}

@test "an invalid DOC_LINE_BUDGET in the config file is ignored, default still applies" {
  cat > .cursor-context/config << 'EOF'
LANG=en
DOC_LINE_BUDGET=not-a-number
EOF
  { marker; body_of 50; } > doc.md
  run .claude/hooks/context-benchmark.sh doc.md
  [[ "$output" == *"PASS: body: 50 lines (target: within 200)"* ]]
}
