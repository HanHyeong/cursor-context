#!/usr/bin/env bats
# context-fingerprint.sh 검증: 매니페스트 수정/롤백, 스크래치 파일 추가(불변),
# CRLF 마커 정규화, 지문 비교 불가 상태(exit 3).
#
# context-fingerprint.sh는 커밋 히스토리가 아니라 "지금 작업 트리의 실제
# 내용"을 지문으로 삼는다 — 이 스위트가 검증하는 것은 정확히 그 성질이다.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_DIR="$(mktemp -d)"
  cp "$REPO_ROOT/.claude/hooks/context-fingerprint.sh" "$TEST_DIR/context-fingerprint.sh"
  chmod +x "$TEST_DIR/context-fingerprint.sh"
  cd "$TEST_DIR"
  git init -q
  git config user.email test@example.com
  git config user.name test
  echo '{"name":"x","version":"1.0.0"}' > package.json
  git add -A
  git commit -qm init
  export CLAUDE_PROJECT_DIR="$TEST_DIR"
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
}

# project-onboard/context-refresh 스킬이 실제로 쓰는 마커 포맷과 동일하게 구성한다:
# <!-- context-fingerprint-begin 으로 열고 context-fingerprint-end --> 로 닫는
# 하나의 HTML 주석 블록이다 (session-context.sh / context-benchmark.sh가 이
# 정확한 포맷을 전제로 파싱한다).
write_doc_with_fingerprint() {
  {
    echo "# doc"
    echo "<!-- generated-at-commit: $(git rev-parse HEAD) -->"
    echo "<!-- context-fingerprint-begin"
    ./context-fingerprint.sh
    echo "context-fingerprint-end -->"
  } > project-context.md
}

@test "fingerprint is stable when nothing changed" {
  write_doc_with_fingerprint
  run ./context-fingerprint.sh --changed project-context.md
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "modifying a manifest file changes the fingerprint" {
  write_doc_with_fingerprint
  echo '{"name":"x","version":"2.0.0"}' > package.json
  run ./context-fingerprint.sh --changed project-context.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"package.json"* ]]
}

@test "an uncommitted (unstaged) manifest edit is caught too" {
  write_doc_with_fingerprint
  # git add 없이 작업 트리만 수정 — 지문은 커밋이 아니라 실제 파일 내용을 본다.
  echo '{"name":"x","version":"3.0.0"}' > package.json
  run ./context-fingerprint.sh --changed project-context.md
  [[ "$output" == *"package.json"* ]]
}

@test "rolling back a manifest edit makes the fingerprint match again" {
  write_doc_with_fingerprint
  cp package.json "$BATS_TEST_TMPDIR/pkg-backup.json"
  echo '{"name":"x","version":"2.0.0"}' > package.json
  run ./context-fingerprint.sh --changed project-context.md
  [[ "$output" == *"package.json"* ]]
  cp "$BATS_TEST_TMPDIR/pkg-backup.json" package.json
  run ./context-fingerprint.sh --changed project-context.md
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "adding a root-level scratch file does not trigger a false structure change" {
  write_doc_with_fingerprint
  echo "my scratch notes" > scratch-notes.txt
  run ./context-fingerprint.sh --changed project-context.md
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "adding a new top-level directory changes the directory-structure fingerprint" {
  write_doc_with_fingerprint
  mkdir -p newpkg
  echo 'console.log(1)' > newpkg/index.js
  run ./context-fingerprint.sh --changed project-context.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"directory-structure"* ]]
}

@test "CRLF fingerprint markers are normalized and do not cause perpetual mismatch" {
  write_doc_with_fingerprint
  awk 'BEGIN{ORS="\r\n"} {print}' project-context.md > project-context.crlf.md
  mv project-context.crlf.md project-context.md
  run ./context-fingerprint.sh --changed project-context.md
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--changed exits 3 when the doc has no fingerprint marker" {
  echo "# doc without any fingerprint marker" > project-context.md
  run ./context-fingerprint.sh --changed project-context.md
  [ "$status" -eq 3 ]
}

@test "--changed exits 3 when the doc file does not exist" {
  run ./context-fingerprint.sh --changed missing-doc.md
  [ "$status" -eq 3 ]
}

@test "default invocation (no args) prints a sorted hash listing" {
  run ./context-fingerprint.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"package.json"* ]]
  [[ "$output" == *"directory-structure"* ]]
}
