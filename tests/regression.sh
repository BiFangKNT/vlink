#!/bin/bash
# 用隔离的脚本副本验证 CLI 行为，不触碰仓库运行记录。
# shellcheck disable=SC2329
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEMP_BASE=$(cd -- "${TMPDIR:-/tmp}" && pwd -P)
TEST_ROOT=$(mktemp -d "$TEMP_BASE/vlink-tests.XXXXXX")
COUNT=0

cleanup() {
  # 递归删除前确认绝对路径仍在本次专用临时目录范围内。
  if [[ "$TEST_ROOT" == "$TEMP_BASE"/vlink-tests.* && -d "$TEST_ROOT" && ! -L "$TEST_ROOT" ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

new_case() {
  NAME="$1"
  CASE_ROOT="$TEST_ROOT/$NAME"
  mkdir -p "$CASE_ROOT/src" "$CASE_ROOT/dst"
  cp "$REPO_DIR/link_video.sh" "$CASE_ROOT/link_video.sh"
  SCRIPT="$CASE_ROOT/link_video.sh"
}

fail() {
  echo "FAIL: $NAME: $*" >&2
  [[ ! -f "$CASE_ROOT/output" ]] || cat "$CASE_ROOT/output" >&2
  exit 1
}

run_ok() {
  timeout -s KILL 8 bash "$SCRIPT" "$@" >"$CASE_ROOT/output" 2>&1 || fail 'expected exit 0'
}

run_failure() {
  local expected="$1" status
  shift
  if timeout -s KILL 8 bash "$SCRIPT" "$@" >"$CASE_ROOT/output" 2>&1; then
    fail 'expected failure'
  else status=$?; fi
  [[ "$status" == "$expected" ]] || fail "expected exit $expected, got $status"
}

assert() { "$@" || fail "assertion: $*"; }
pass() {
  COUNT=$((COUNT + 1))
  echo "PASS: $NAME"
}

new_case help
run_ok
run_ok --help
[[ $(cat "$CASE_ROOT/output") != *recursive* ]] || fail 'stale help'
pass
for flag in -r --recursive; do
  new_case "removed_$flag"
  run_failure 1 "$flag" "$CASE_ROOT/src" "$CASE_ROOT/dst"
  assert test ! -e "$CASE_ROOT/vlink_last_run.log"
  pass
done
new_case missing_positional_target
touch "$CASE_ROOT/src/a.mkv"
run_failure 3 "$CASE_ROOT/src" "$CASE_ROOT/missing"
assert test ! -e "$CASE_ROOT/vlink_last_run.log"
pass
for flag in -fi -fe; do
  new_case "invalid_regex_$flag"
  touch "$CASE_ROOT/src/a.mkv"
  run_failure 1 -f "$CASE_ROOT/src" "$CASE_ROOT/dst" "$flag" '['
  [[ -z $(find "$CASE_ROOT/dst" -mindepth 1 -print) ]] || fail 'invalid regex wrote files'
  assert test ! -e "$CASE_ROOT/vlink_last_run.log"
  pass
done
for mode in default -o -f; do
  new_case "flat_$mode"
  mkdir -p "$CASE_ROOT/src/season/sub"
  touch "$CASE_ROOT/src/中文 视频.mkv" "$CASE_ROOT/src/movie.mp4" "$CASE_ROOT/src/notes.txt" "$CASE_ROOT/src/season/nested.mkv" "$CASE_ROOT/src/season/sub/deep.mp4"
  if [[ "$mode" == default ]]; then
    printf '\n\n' | run_ok "$CASE_ROOT/src" "$CASE_ROOT/dst"
  else run_ok "$mode" "$CASE_ROOT/src" "$CASE_ROOT/dst"; fi
  [[ $(find "$CASE_ROOT/dst" -type f | wc -l) == 2 ]] || fail 'unexpected file count'
  assert test ! -e "$CASE_ROOT/dst/season"
  assert test ! -e "$CASE_ROOT/dst/notes.txt"
  run_ok -undo
  [[ -z $(find "$CASE_ROOT/dst" -mindepth 1 -print) ]] || fail 'undo left files'
  pass
done
new_case preview_filter
mkdir "$CASE_ROOT/src/season"
touch "$CASE_ROOT/src/中文 1080p.mkv" "$CASE_ROOT/src/Special 1080p.mkv" "$CASE_ROOT/src/720p.mp4" "$CASE_ROOT/src/season/nested 1080p.mkv"
run_ok "$CASE_ROOT/src" -fi '1080p' -fe 'Special|OVA'
output=$(cat "$CASE_ROOT/output")
[[ "$output" == *'中文 1080p.mkv →'* && "$output" != *'Special 1080p.mkv →'* && "$output" != *'720p.mp4 →'* && "$output" != *'nested 1080p.mkv →'* ]] || fail 'preview filtering changed'
assert test ! -e "$CASE_ROOT/vlink_last_run.log"
pass
for mode in default -o -f; do
  new_case "literal_brackets_$mode"
  printf literal >"$CASE_ROOT/src/[A].mkv"
  printf plain >"$CASE_ROOT/src/A.mkv"
  if [[ "$mode" == default ]]; then
    printf '\n\n' | run_ok "$CASE_ROOT/src" "$CASE_ROOT/dst"
  else run_ok "$mode" "$CASE_ROOT/src" "$CASE_ROOT/dst"; fi
  for source in "$CASE_ROOT/src/"*; do
    linked=0
    for target in "$CASE_ROOT/dst/"*; do [[ ! "$source" -ef "$target" ]] || linked=1; done
    [[ "$linked" == 1 ]] || fail "source omitted: $source"
  done
  run_ok -undo
  [[ -z $(find "$CASE_ROOT/dst" -mindepth 1 -print) ]] || fail 'undo left bracket names'
  pass
done
new_case newline_filename
filename=$'中文\n视频.mkv'
touch "$CASE_ROOT/src/$filename"
run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
assert test "$CASE_ROOT/src/$filename" -ef "$CASE_ROOT/dst/$filename"
run_ok -undo
assert test ! -e "$CASE_ROOT/dst/$filename"
pass
new_case newline_target_directory
newline_dst="$CASE_ROOT/dst"$'\n'
mkdir "$newline_dst"
touch "$CASE_ROOT/src/a.mkv"
run_ok -o "$CASE_ROOT/src" "$newline_dst"
assert test "$CASE_ROOT/src/a.mkv" -ef "$newline_dst/a.mkv"
run_ok -undo
assert test ! -e "$newline_dst/a.mkv"
pass
new_case single_file
touch "$CASE_ROOT/src/a.mkv"
run_ok -o -op "$CASE_ROOT/src/a.mkv" -lp "$CASE_ROOT/dst"
assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/a.mkv"
pass
for mode in default -o -f; do
  new_case "eof_$mode"
  printf source >"$CASE_ROOT/src/a.mkv"
  target=a.mkv
  [[ "$mode" == -o ]] || target='a - s01e01.mkv'
  printf original >"$CASE_ROOT/dst/$target"
  if [[ "$mode" == default ]]; then
    run_failure 1 "$CASE_ROOT/src" "$CASE_ROOT/dst" </dev/null
  else run_failure 1 "$mode" "$CASE_ROOT/src" "$CASE_ROOT/dst" </dev/null; fi
  [[ $(cat "$CASE_ROOT/dst/$target") == original ]] || fail 'EOF overwrote target'
  pass
done
new_case eof_partial
touch "$CASE_ROOT/src/a.mkv" "$CASE_ROOT/src/b.mkv"
printf '\n' | run_failure 1 "$CASE_ROOT/src" "$CASE_ROOT/dst"
assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/a - s01e01.mkv"
assert test ! -e "$CASE_ROOT/dst/b - s01e02.mkv"
run_ok -undo
assert test ! -e "$CASE_ROOT/dst/a - s01e01.mkv"
pass
for mode in default -o -f; do
  new_case "link_failure_$mode"
  touch "$CASE_ROOT/src/a.mkv"
  (
    ln() { return 1; }
    export -f ln
    if [[ "$mode" == default ]]; then
      printf '\n' | run_failure 1 "$CASE_ROOT/src" "$CASE_ROOT/dst"
    else run_failure 1 "$mode" "$CASE_ROOT/src" "$CASE_ROOT/dst"; fi
  )
  assert test ! -e "$CASE_ROOT/vlink_last_run.log"
  [[ $(cat "$CASE_ROOT/output") != *'创建硬链接:'* ]] || fail 'false success output'
  pass
done
new_case partial_link_failure
touch "$CASE_ROOT/src/a.mkv" "$CASE_ROOT/src/b.mkv"
(
  ln() {
    local source="${*: -2:1}"
    [[ "$source" != */b.mkv ]] || return 1
    command ln "$@"
  }
  export -f ln
  run_failure 1 -f "$CASE_ROOT/src" "$CASE_ROOT/dst"
)
assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/a - s01e01.mkv"
assert test ! -e "$CASE_ROOT/dst/b - s01e02.mkv"
run_ok -undo
assert test ! -e "$CASE_ROOT/dst/a - s01e01.mkv"
pass
for failing_command in ln mv; do
  new_case "overwrite_failure_$failing_command"
  printf source >"$CASE_ROOT/src/a.mkv"
  printf original >"$CASE_ROOT/dst/a - s01e01.mkv"
  (
    if [[ "$failing_command" == ln ]]; then
      ln() { return 1; }
      export -f ln
    else
      mv() { return 1; }
      export -f mv
    fi
    printf '\n' | run_failure 1 "$CASE_ROOT/src" "$CASE_ROOT/dst"
  )
  [[ $(cat "$CASE_ROOT/dst/a - s01e01.mkv") == original ]] || fail 'original lost'
  assert test ! -e "$CASE_ROOT/vlink_last_run.log"
  [[ -z $(find "$CASE_ROOT/dst" -name '.vlink.*' -print) ]] || fail 'temporary directory leaked'
  pass
done
new_case overwrite_success
printf source >"$CASE_ROOT/src/a.mkv"
printf original >"$CASE_ROOT/dst/a - s01e01.mkv"
printf '\n' | run_ok "$CASE_ROOT/src" "$CASE_ROOT/dst"
assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/a - s01e01.mkv"
pass
for mode in default -f; do
  new_case "sequence_range_$mode"
  touch "$CASE_ROOT/src/a.mkv" "$CASE_ROOT/src/b.mkv" "$CASE_ROOT/src/c.mkv"
  if [[ "$mode" == default ]]; then
    printf '\n\n\n' | run_ok "$CASE_ROOT/src" "$CASE_ROOT/dst" s01e01-s01e02
  else run_ok -f "$CASE_ROOT/src" "$CASE_ROOT/dst" s01e01-s01e02; fi
  assert test "$CASE_ROOT/src/b.mkv" -ef "$CASE_ROOT/dst/b - s01e02.mkv"
  assert test ! -e "$CASE_ROOT/dst/c - s01e03.mkv"
  pass
done
new_case change_sequence
touch "$CASE_ROOT/src/a.mkv"
printf 's02e003\n\n' | run_ok "$CASE_ROOT/src" "$CASE_ROOT/dst"
assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/a - s02e003.mkv"
pass
new_case undo_retry
a="$CASE_ROOT/dst/a.mkv"
b="$CASE_ROOT/dst/b.mkv"
touch "$CASE_ROOT/src/a.mkv" "$CASE_ROOT/src/b.mkv"
run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
(
  FAILED_PATH="$b"
  export FAILED_PATH
  rm() {
    [[ "${*: -1}" != "$FAILED_PATH" ]] || return 1
    command rm "$@"
  }
  export -f rm
  run_failure 1 -undo
)
assert test ! -e "$a"
printf unrelated >"$a"
run_ok -undo
[[ $(cat "$a") == unrelated ]] || fail 'undo retry deleted new content'
assert test ! -e "$b"
pass
new_case corrupted_legacy_log
printf unrelated >"$CASE_ROOT/unrelated.mkv"
printf 'unrelated.mkv\n' >"$CASE_ROOT/vlink_last_run.log"
(
  cd "$CASE_ROOT"
  run_failure 1 -undo
)
assert test -f "$CASE_ROOT/unrelated.mkv"
pass
for mode in -o -f; do
  new_case "rename_retry_$mode"
  touch "$CASE_ROOT/src/a.mkv"
  target=a.mkv
  [[ "$mode" == -o ]] || target='a - s01e01.mkv'
  touch "$CASE_ROOT/dst/$target" "$CASE_ROOT/dst/taken.mkv"
  printf unrelated >"$CASE_ROOT/final.mkv"
  printf '\ntaken\nfinal\n' | run_ok "$mode" "$CASE_ROOT/src" "$CASE_ROOT/dst"
  assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/final.mkv"
  (
    cd "$CASE_ROOT"
    run_ok -undo
  )
  [[ $(cat "$CASE_ROOT/final.mkv") == unrelated ]] || fail 'rename polluted undo path'
  assert test ! -e "$CASE_ROOT/dst/final.mkv"
  pass
done
for mode in default -o -f; do
  new_case "rename_rejects_paths_$mode"
  printf source >"$CASE_ROOT/src/a.mkv"
  target=a.mkv
  [[ "$mode" == -o ]] || target='a - s01e01.mkv'
  printf original >"$CASE_ROOT/dst/$target"
  if [[ "$mode" == default ]]; then
    printf '%s\n' '../escaped-forward' '..\escaped-backward' 'final' | run_ok "$CASE_ROOT/src" "$CASE_ROOT/dst"
  else
    printf '%s\n' '../escaped-forward' '..\escaped-backward' 'final' | run_ok "$mode" "$CASE_ROOT/src" "$CASE_ROOT/dst"
  fi
  assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/final.mkv"
  [[ $(cat "$CASE_ROOT/dst/$target") == original ]] || fail 'invalid rename changed original target'
  assert test ! -e "$CASE_ROOT/escaped-forward.mkv"
  assert test ! -e "$CASE_ROOT/escaped-backward.mkv"
  run_ok -undo
  assert test ! -e "$CASE_ROOT/dst/final.mkv"
  [[ $(cat "$CASE_ROOT/dst/$target") == original ]] || fail 'undo changed original target'
  pass
done
new_case empty_run_keeps_previous_record
touch "$CASE_ROOT/src/a.mkv"
run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst" -fi 'never-match'
run_ok -undo
assert test ! -e "$CASE_ROOT/dst/a.mkv"
pass
new_case signal_preserves_record
touch "$CASE_ROOT/src/a.mkv"
run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
(
  read() { kill -TERM "$BASHPID"; }
  export -f read
  run_failure 1 "$CASE_ROOT/src"
)
run_ok -undo
assert test ! -e "$CASE_ROOT/dst/a.mkv"
pass
new_case record_path_is_directory
touch "$CASE_ROOT/src/a.mkv"
mkdir "$CASE_ROOT/vlink_last_run.log"
run_failure 1 -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
assert test ! -e "$CASE_ROOT/dst/a.mkv"
pass
new_case collection_failure_preserves_record
touch "$CASE_ROOT/src/a.mkv"
run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
(
  find() { return 1; }
  export -f find
  run_failure 1 "$CASE_ROOT/src"
)
run_ok -undo
assert test ! -e "$CASE_ROOT/dst/a.mkv"
pass
new_case named_parameters
touch "$CASE_ROOT/src/a 1080p.MP4" "$CASE_ROOT/src/b 1080p.mkv" "$CASE_ROOT/src/c Special 1080p.mkv" "$CASE_ROOT/src/d 720p.mkv"
run_ok -f -op "$CASE_ROOT/src" -lp "$CASE_ROOT/dst" -sn s03e01-s03e02 -fi '1080p' -fe 'Special|OVA'
assert test "$CASE_ROOT/src/a 1080p.MP4" -ef "$CASE_ROOT/dst/a 1080p - s03e01.MP4"
assert test "$CASE_ROOT/src/b 1080p.mkv" -ef "$CASE_ROOT/dst/b 1080p - s03e02.mkv"
[[ $(find "$CASE_ROOT/dst" -type f | wc -l) == 2 ]] || fail 'named filtering mismatch'
pass
new_case conflicting_modes
touch "$CASE_ROOT/src/a.mkv"
run_failure 1 -o -f "$CASE_ROOT/src" "$CASE_ROOT/dst"
run_failure 1 -f -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
assert test ! -e "$CASE_ROOT/dst/a.mkv"
pass

for format in line v1; do
  new_case "legacy_identity_missing_$format"
  touch "$CASE_ROOT/dst/a.mkv"
  if [[ "$format" == line ]]; then
    printf '%s\n' "$CASE_ROOT/dst/a.mkv" >"$CASE_ROOT/vlink_last_run.log"
  else printf 'vlink-log-v1\0%s\0' "$CASE_ROOT/dst/a.mkv" >"$CASE_ROOT/vlink_last_run.log"; fi
  run_failure 1 -undo
  assert test -f "$CASE_ROOT/dst/a.mkv"
  assert test -f "$CASE_ROOT/vlink_last_run.log"
  pass
done
new_case replaced_target
touch "$CASE_ROOT/src/a.mkv"
run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
rm -- "$CASE_ROOT/dst/a.mkv"
printf unrelated >"$CASE_ROOT/dst/a.mkv"
run_ok -undo
[[ $(cat "$CASE_ROOT/dst/a.mkv") == unrelated ]] || fail 'replacement deleted'
pass
new_case replaced_target_with_directory
touch "$CASE_ROOT/src/a.mkv"
run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
rm -- "$CASE_ROOT/dst/a.mkv"
mkdir "$CASE_ROOT/dst/a.mkv"
touch "$CASE_ROOT/dst/a.mkv/unrelated.txt"
run_ok -undo
assert test -f "$CASE_ROOT/dst/a.mkv/unrelated.txt"
pass
new_case creation_commit_failure
touch "$CASE_ROOT/src/a.mkv"
(
  FAILED_LOG="$CASE_ROOT/vlink_last_run.log"
  export FAILED_LOG
  mv() {
    [[ "${*: -1}" != "$FAILED_LOG" ]] || return 1
    command mv "$@"
  }
  export -f mv
  run_failure 1 -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
)
assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/a.mkv"
assert test -f "$CASE_ROOT/vlink_last_run.log.pending"
run_failure 1 -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
run_ok -undo
assert test ! -e "$CASE_ROOT/dst/a.mkv"
assert test ! -e "$CASE_ROOT/vlink_last_run.log.pending"
pass
new_case intent_commit_failure
touch "$CASE_ROOT/src/a.mkv"
(
  FAILED_LOG="$CASE_ROOT/vlink_last_run.log.pending"
  export FAILED_LOG
  mv() {
    [[ "${*: -1}" != "$FAILED_LOG" ]] || return 1
    command mv "$@"
  }
  export -f mv
  run_failure 1 -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
)
assert test ! -e "$CASE_ROOT/dst/a.mkv"
assert test ! -e "$CASE_ROOT/vlink_last_run.log.pending"
pass
new_case overwrite_commit_failure
printf source >"$CASE_ROOT/src/a.mkv"
printf original >"$CASE_ROOT/dst/a - s01e01.mkv"
(
  FAILED_LOG="$CASE_ROOT/vlink_last_run.log"
  export FAILED_LOG
  mv() {
    [[ "${*: -1}" != "$FAILED_LOG" ]] || return 1
    command mv "$@"
  }
  export -f mv
  printf '\n' | run_failure 1 "$CASE_ROOT/src" "$CASE_ROOT/dst"
)
assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/a - s01e01.mkv"
run_ok -undo
assert test ! -e "$CASE_ROOT/dst/a - s01e01.mkv"
pass
for signal in TERM KILL; do
  new_case "signal_after_publication_$signal"
  touch "$CASE_ROOT/src/a.mkv"
  (
    PUBLISHED_PATH="$CASE_ROOT/dst/a.mkv"
    SIGNAL="$signal"
    export PUBLISHED_PATH SIGNAL
    ln() {
      command ln "$@" || return
      [[ "${*: -1}" != "$PUBLISHED_PATH" ]] || kill -"$SIGNAL" "$BASHPID"
    }
    export -f ln
    expected=1
    [[ "$signal" != KILL ]] || expected=137
    run_failure "$expected" -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
  )
  assert test -f "$CASE_ROOT/dst/a.mkv"
  assert test -f "$CASE_ROOT/vlink_last_run.log.pending"
  if [[ "$signal" == KILL ]]; then
    # SIGKILL 不执行 EXIT 清理；确认被终止进程退出后手动释放残留锁。
    assert test -d "$CASE_ROOT/vlink_last_run.log.lock"
    rmdir -- "$CASE_ROOT/vlink_last_run.log.lock"
  else
    assert test ! -e "$CASE_ROOT/vlink_last_run.log.lock"
  fi
  run_ok -undo
  assert test ! -e "$CASE_ROOT/dst/a.mkv"
  [[ -z $(find "$CASE_ROOT/dst" -maxdepth 1 -type d -name '.vlink.*' -print) ]] || fail 'published operation left a staging directory'
  pass
done
for failure in commit checkpoint; do
  new_case "undo_record_failure_$failure"
  touch "$CASE_ROOT/src/a.mkv" "$CASE_ROOT/src/b.mkv"
  run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
  (
    FAILED_LOG="$CASE_ROOT/vlink_last_run.log"
    FAILURE="$failure"
    PENDING_WRITES=0
    export FAILED_LOG FAILURE PENDING_WRITES
    mv() {
      local destination="${*: -1}"
      if [[ "$FAILURE" == commit && "$destination" == "$FAILED_LOG" ]]; then return 1; fi
      if [[ "$FAILURE" == checkpoint && "$destination" == "$FAILED_LOG.pending" ]]; then
        PENDING_WRITES=$((PENDING_WRITES + 1))
        ((PENDING_WRITES != 2)) || return 1
      fi
      command mv "$@"
    }
    export -f mv
    run_failure 1 -undo
  )
  assert test ! -e "$CASE_ROOT/dst/a.mkv"
  printf unrelated >"$CASE_ROOT/dst/a.mkv"
  run_ok -undo
  [[ $(cat "$CASE_ROOT/dst/a.mkv") == unrelated ]] || fail 'retry deleted replacement'
  assert test ! -e "$CASE_ROOT/dst/b.mkv"
  pass
done
new_case signal_after_undo_deletion
touch "$CASE_ROOT/src/a.mkv" "$CASE_ROOT/src/b.mkv"
run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
(
  DELETED_PATH="$CASE_ROOT/dst/a.mkv"
  export DELETED_PATH
  rm() {
    command rm "$@" || return
    [[ "${*: -1}" != "$DELETED_PATH" ]] || kill -TERM "$BASHPID"
  }
  export -f rm
  run_failure 1 -undo
)
printf unrelated >"$CASE_ROOT/dst/a.mkv"
run_ok -undo
[[ $(cat "$CASE_ROOT/dst/a.mkv") == unrelated ]] || fail 'interrupted undo deleted replacement'
assert test ! -e "$CASE_ROOT/dst/b.mkv"
pass
new_case failed_identity_read
touch "$CASE_ROOT/src/a.mkv"
run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
(
  FAILED_PATH="$CASE_ROOT/dst/a.mkv"
  export FAILED_PATH
  stat() {
    [[ "${*: -1}" != "$FAILED_PATH" ]] || return 1
    command stat "$@"
  }
  export -f stat
  run_failure 1 -undo
)
assert test -f "$CASE_ROOT/dst/a.mkv"
run_ok -undo
assert test ! -e "$CASE_ROOT/dst/a.mkv"
pass
new_case concurrent_mutations
touch "$CASE_ROOT/src/a.mkv"
mkfifo "$CASE_ROOT/input"
exec {input_fd}<>"$CASE_ROOT/input"
(
  READY_PATH="$CASE_ROOT/ready"
  export READY_PATH
  read() {
    touch "$READY_PATH"
    builtin read -r "$@"
  }
  export -f read
  timeout -s KILL 8 bash "$SCRIPT" "$CASE_ROOT/src" "$CASE_ROOT/dst" <&"$input_fd" >"$CASE_ROOT/first-output" 2>&1
) &
first_job=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ ! -e "$CASE_ROOT/ready" ]] || break
  sleep 0.05
done
assert test -f "$CASE_ROOT/ready"
assert test -d "$CASE_ROOT/vlink_last_run.log.lock"
run_failure 1 -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
run_failure 1 -undo
# 预览不修改记录，无需阻塞。
run_ok "$CASE_ROOT/src"
assert test ! -e "$CASE_ROOT/dst/a - s01e01.mkv"
printf '\n' >&"$input_fd"
wait "$first_job" || fail 'first task failed'
exec {input_fd}>&-
assert test ! -e "$CASE_ROOT/vlink_last_run.log.lock"
assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/a - s01e01.mkv"
run_ok -undo
assert test ! -e "$CASE_ROOT/dst/a - s01e01.mkv"
pass
new_case lock_failure_has_no_effect
touch "$CASE_ROOT/src/a.mkv"
mkdir "$CASE_ROOT/vlink_last_run.log.lock"
run_failure 1 -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
assert test ! -e "$CASE_ROOT/dst/a.mkv"
assert test ! -e "$CASE_ROOT/vlink_last_run.log"
assert test -d "$CASE_ROOT/vlink_last_run.log.lock"
rmdir -- "$CASE_ROOT/vlink_last_run.log.lock"
run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
run_ok -undo
pass

for mode in default -o -f; do
  new_case "same_file_preflight_$mode"
  printf first >"$CASE_ROOT/src/a.mkv"
  printf second >"$CASE_ROOT/src/b.mkv"
  alias_name=$'已有\n副本[2].mkv'
  ln "$CASE_ROOT/src/b.mkv" "$CASE_ROOT/dst/$alias_name"
  if [[ "$mode" == default ]]; then
    run_failure 1 "$CASE_ROOT/src" "$CASE_ROOT/dst" </dev/null
  else run_failure 1 "$mode" "$CASE_ROOT/src" "$CASE_ROOT/dst" </dev/null; fi
  [[ $(cat "$CASE_ROOT/output") == *'same file'* ]] || fail 'preflight did not report same file'
  assert test "$CASE_ROOT/src/b.mkv" -ef "$CASE_ROOT/dst/$alias_name"
  assert test ! -e "$CASE_ROOT/dst/a.mkv"
  assert test ! -e "$CASE_ROOT/dst/a - s01e01.mkv"
  assert test ! -e "$CASE_ROOT/vlink_last_run.log"
  assert test ! -e "$CASE_ROOT/vlink_last_run.log.pending"
  assert test ! -e "$CASE_ROOT/vlink_last_run.log.lock"
  [[ $(find "$CASE_ROOT/dst" -maxdepth 1 -type f -printf x) == x ]] || fail 'preflight modified target directory'
  run_ok "$CASE_ROOT/src"
  pass
done
new_case same_file_keeps_previous_record
touch "$CASE_ROOT/src/previous.mkv"
run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
cp "$CASE_ROOT/vlink_last_run.log" "$CASE_ROOT/saved-log"
touch "$CASE_ROOT/src/a.mkv" "$CASE_ROOT/src/b.mkv"
ln "$CASE_ROOT/src/b.mkv" "$CASE_ROOT/dst/b - s01e02.mkv"
run_failure 1 -f "$CASE_ROOT/src" "$CASE_ROOT/dst" -fi '^[ab]\.mkv$'
assert cmp "$CASE_ROOT/saved-log" "$CASE_ROOT/vlink_last_run.log"
assert test ! -e "$CASE_ROOT/dst/a - s01e01.mkv"
assert test ! -e "$CASE_ROOT/vlink_last_run.log.pending"
run_ok -undo
assert test ! -e "$CASE_ROOT/dst/previous.mkv"
assert test "$CASE_ROOT/src/b.mkv" -ef "$CASE_ROOT/dst/b - s01e02.mkv"
pass
new_case same_file_single_source
source_name=$'中文\n[A].mkv'
touch "$CASE_ROOT/src/$source_name"
ln "$CASE_ROOT/src/$source_name" "$CASE_ROOT/dst/renamed.txt"
run_failure 1 -o "$CASE_ROOT/src/$source_name" "$CASE_ROOT/dst"
[[ $(cat "$CASE_ROOT/output") == *'same file'* ]] || fail 'single source was not checked'
assert test "$CASE_ROOT/src/$source_name" -ef "$CASE_ROOT/dst/renamed.txt"
assert test ! -e "$CASE_ROOT/vlink_last_run.log"
pass
for filter in -fi -fe; do
  new_case "same_file_filter_$filter"
  touch "$CASE_ROOT/src/a.mkv" "$CASE_ROOT/src/b.mkv"
  ln "$CASE_ROOT/src/b.mkv" "$CASE_ROOT/dst/renamed.mkv"
  pattern='^a'
  [[ "$filter" != -fe ]] || pattern='^b'
  run_ok -f "$CASE_ROOT/src" "$CASE_ROOT/dst" "$filter" "$pattern"
  assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/a - s01e01.mkv"
  run_ok -undo
  assert test "$CASE_ROOT/src/b.mkv" -ef "$CASE_ROOT/dst/renamed.mkv"
  pass
done
new_case same_file_outside_sequence_range
touch "$CASE_ROOT/src/a.mkv" "$CASE_ROOT/src/b.mkv" "$CASE_ROOT/src/c.mkv"
ln "$CASE_ROOT/src/c.mkv" "$CASE_ROOT/dst/renamed.mkv"
run_ok -f "$CASE_ROOT/src" "$CASE_ROOT/dst" s01e01-s01e02
assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/a - s01e01.mkv"
assert test "$CASE_ROOT/src/b.mkv" -ef "$CASE_ROOT/dst/b - s01e02.mkv"
run_ok -undo
assert test "$CASE_ROOT/src/c.mkv" -ef "$CASE_ROOT/dst/renamed.mkv"
pass
new_case same_content_different_files
printf identical >"$CASE_ROOT/src/a.mkv"
printf identical >"$CASE_ROOT/dst/renamed.mkv"
run_ok -f "$CASE_ROOT/src" "$CASE_ROOT/dst"
assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/a - s01e01.mkv"
run_ok -undo
[[ $(cat "$CASE_ROOT/dst/renamed.mkv") == identical ]] || fail 'unrelated file changed'
pass

for target_count in 1000 1001; do
  new_case "same_file_threshold_$target_count"
  touch "$CASE_ROOT/src/a.mkv"
  ln "$CASE_ROOT/src/a.mkv" "$CASE_ROOT/dst/renamed.mkv"
  for ((i = 1; i < target_count; i++)); do : >"$CASE_ROOT/dst/filler-$i.txt"; done
  if ((target_count == 1000)); then
    run_failure 1 -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
    [[ $(cat "$CASE_ROOT/output") == *'same file'* ]] || fail '1000 files must still check other names'
    assert test ! -e "$CASE_ROOT/vlink_last_run.log"
  else
    run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
    assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/a.mkv"
    run_ok -undo
    assert test ! -e "$CASE_ROOT/dst/a.mkv"
  fi
  assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/renamed.mkv"
  assert test ! -e "$CASE_ROOT/vlink_last_run.log.pending"
  pass
done
for mode in default -o -f; do
  new_case "same_file_large_named_$mode"
  touch "$CASE_ROOT/src/previous.mkv"
  run_ok -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
  cp "$CASE_ROOT/vlink_last_run.log" "$CASE_ROOT/saved-log"
  touch "$CASE_ROOT/src/a.mkv" "$CASE_ROOT/src/b.mkv"
  target='b - s02e004.mkv'
  [[ "$mode" != -o ]] || target=b.mkv
  ln "$CASE_ROOT/src/b.mkv" "$CASE_ROOT/dst/$target"
  for ((i = 1; i <= 999; i++)); do : >"$CASE_ROOT/dst/filler-$i.txt"; done
  if [[ "$mode" == default ]]; then
    run_failure 1 "$CASE_ROOT/src" "$CASE_ROOT/dst" -sn s02e003-s02e004 -fi '^[ab]\.mkv$' </dev/null
  else run_failure 1 "$mode" "$CASE_ROOT/src" "$CASE_ROOT/dst" -sn s02e003-s02e004 -fi '^[ab]\.mkv$' </dev/null; fi
  [[ $(cat "$CASE_ROOT/output") == *'same file'* ]] || fail 'large directory did not check the planned target'
  assert cmp "$CASE_ROOT/saved-log" "$CASE_ROOT/vlink_last_run.log"
  assert test ! -e "$CASE_ROOT/dst/a.mkv"
  assert test ! -e "$CASE_ROOT/dst/a - s02e003.mkv"
  assert test ! -e "$CASE_ROOT/vlink_last_run.log.pending"
  assert test ! -e "$CASE_ROOT/vlink_last_run.log.lock"
  run_ok -undo
  assert test "$CASE_ROOT/src/b.mkv" -ef "$CASE_ROOT/dst/$target"
  pass
done
new_case same_file_large_range_filter
touch "$CASE_ROOT/src/a.mkv" "$CASE_ROOT/src/b.mkv" "$CASE_ROOT/src/c.mkv" "$CASE_ROOT/src/OVA.mkv"
ln "$CASE_ROOT/src/c.mkv" "$CASE_ROOT/dst/c - s01e03.mkv"
ln "$CASE_ROOT/src/OVA.mkv" "$CASE_ROOT/dst/OVA - s01e01.mkv"
for ((i = 1; i <= 999; i++)); do : >"$CASE_ROOT/dst/filler-$i.txt"; done
run_ok -f "$CASE_ROOT/src" "$CASE_ROOT/dst" s01e01-s01e02 -fe '^OVA'
assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/a - s01e01.mkv"
assert test "$CASE_ROOT/src/b.mkv" -ef "$CASE_ROOT/dst/b - s01e02.mkv"
run_ok -undo
assert test "$CASE_ROOT/src/c.mkv" -ef "$CASE_ROOT/dst/c - s01e03.mkv"
assert test "$CASE_ROOT/src/OVA.mkv" -ef "$CASE_ROOT/dst/OVA - s01e01.mkv"
pass
new_case same_file_large_source_small_target
touch "$CASE_ROOT/src/a.mkv"
ln "$CASE_ROOT/src/a.mkv" "$CASE_ROOT/dst/renamed.mkv"
for ((i = 1; i <= 1000; i++)); do : >"$CASE_ROOT/src/filler-$i.mkv"; done
run_failure 1 -o "$CASE_ROOT/src" "$CASE_ROOT/dst"
[[ $(cat "$CASE_ROOT/output") == *'same file'* ]] || fail 'large source incorrectly changed the check scope'
assert test ! -e "$CASE_ROOT/vlink_last_run.log"
assert test "$CASE_ROOT/src/a.mkv" -ef "$CASE_ROOT/dst/renamed.mkv"
pass
printf 'ALL %d CASES PASSED\n' "$COUNT"
