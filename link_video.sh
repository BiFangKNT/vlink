#!/bin/bash

set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
LOGFILE="$SCRIPT_DIR/vlink_last_run.log"
PENDING_LOG="$LOGFILE.pending"
LOCK_DIR="$LOGFILE.lock"
LOCK_HELD=0
LOG_FORMAT="vlink-log-v2"
WORK_DIR=""
LOG_TEMP=""
MODE="interactive"
ACTION="link"
SRC=""
DST=""
START_SEQ=""
FILTER_REGEX=""
FILTER_EXCLUDE_REGEX=""
SEQ_REGEX='^s([0-9]+)e([0-9]+)([,-]s([0-9]+)e([0-9]+))?$'
FILES=()
DIRECTORIES=()
CREATED_ITEMS=()
RECORD_PATHS=()
RECORD_IDS=()
RECORD_KINDS=()

fail() {
  echo "$1" >&2
  exit "${2:-1}"
}

cleanup_work() {
  if [[ -n "$WORK_DIR" ]]; then
    rm -f -- "$WORK_DIR/files" "$WORK_DIR/directories" "$WORK_DIR/identities" "$WORK_DIR/link"
    rmdir -- "$WORK_DIR" || echo "未能清理临时目录: $WORK_DIR" >&2
    WORK_DIR=""
  fi
  if [[ -n "$LOG_TEMP" ]]; then
    rm -f -- "$LOG_TEMP"
    LOG_TEMP=""
  fi
}

on_signal() {
  echo "执行被中断；已发布的链接可通过 -undo 核对并撤销。" >&2
  exit 1
}

acquire_lock() {
  mkdir -- "$LOCK_DIR" 2>/dev/null || fail "创建锁失败: $LOCK_DIR；可能已有任务运行，或目录不可写。残留锁需确认原进程结束后手动移除。"
  LOCK_HELD=1
}

cleanup() {
  cleanup_work
  if ((LOCK_HELD)); then
    rmdir -- "$LOCK_DIR" || echo "未能释放锁: $LOCK_DIR" >&2
  fi
}

trap cleanup EXIT
trap on_signal SIGINT SIGTERM

show_help() {
  cat <<EOF
用法: $(basename "$0") [选项] <源路径> [目标路径] [起始序号 sXXeXX] [包含正则]

功能:
  为源目录当前层级的 .mp4、.mkv 文件创建硬链接，也可直接指定源文件。
  省略目标路径时仅预览；目标目录必须已存在。

选项:
  -h, --help           显示帮助
  -o, --original-name  视频原名硬链接，无重命名无交互（冲突跳过）
  -f                  默认模式一键执行（自动重命名，无交互，遇重名停止）
  -undo               撤销上次执行生成的文件
  -op, --origin-path   指定源路径
  -lp, --link-path     指定目标硬链接目录
  -sn, --sequence      指定起始/结束序号：sXXeXX 或 sXXeXX-sXXeYY（也支持逗号）
  -fi, --filter        包含正则，匹配文件名（含后缀）
  -fe, --filter-exclude 排除正则，跳过匹配文件名（含后缀）的文件

说明:
  默认起始序号为 s01e01；序号参数仅用于默认和快速模式。
  正则使用 Bash 扩展正则，区分大小写，使用引号包裹；多个条件可用 | 连接。
  位置参数中的目标路径固定在源路径之后；预览过滤请使用 -fi、-fe。
  创建前检查同一文件并提示退出；目标当前层级超过 1000 个文件时，仅检查队列目标路径。

示例:
  $(basename "$0") /源路径
  $(basename "$0") /源路径 /目标路径 s01e01
  $(basename "$0") -op /源路径 -lp /目标路径 -sn s01e01-s01e12 -fi '1080p' -fe 'Special|OVA'
  $(basename "$0") -o /源路径 /目标路径
  $(basename "$0") -f /源路径 /目标路径
  $(basename "$0") -undo
EOF
}

set_mode() {
  [[ "$MODE" == interactive || "$MODE" == "$1" ]] || fail "-f 不可和 -o 组合使用"
  MODE="$1"
}

parse_args() {
  local positional=()
  while (($# > 0)); do
    case "$1" in
    -h | --help)
      show_help
      exit 0
      ;;
    -o | --original-name)
      set_mode original
      shift
      ;;
    -f)
      set_mode fast
      shift
      ;;
    -undo)
      ACTION="undo"
      shift
      ;;
    -op | --origin-path | -lp | --link-path | -sn | --sequence | -fi | --filter | -fe | --filter-exclude)
      (($# >= 2)) || fail "$1 需要参数"
      case "$1" in
      -op | --origin-path) SRC="$2" ;;
      -lp | --link-path) DST="$2" ;;
      -sn | --sequence) START_SEQ="$2" ;;
      -fi | --filter) FILTER_REGEX="$2" ;;
      -fe | --filter-exclude) FILTER_EXCLUDE_REGEX="$2" ;;
      esac
      shift 2
      ;;
    --)
      shift
      positional+=("$@")
      break
      ;;
    -*) fail "未知选项 $1，使用 -h 查看帮助" ;;
    *)
      positional+=("$1")
      shift
      ;;
    esac
  done
  set -- "${positional[@]}"
  if [[ -z "$SRC" ]] && (($# > 0)); then
    SRC="$1"
    shift
  fi
  if [[ -z "$DST" ]] && (($# > 0)); then
    DST="$1"
    shift
  fi
  if [[ -z "$START_SEQ" ]] && (($# > 0)) && [[ "$1" =~ $SEQ_REGEX ]]; then
    START_SEQ="$1"
    shift
  fi
  if [[ -z "$FILTER_REGEX" ]] && (($# > 0)); then
    FILTER_REGEX="$1"
    shift
  fi
  (($# == 0)) || fail "无法识别的额外参数: $1"
  if [[ "$ACTION" == undo ]]; then
    [[ "$MODE" == interactive && -z "$SRC$DST$START_SEQ$FILTER_REGEX$FILTER_EXCLUDE_REGEX" ]] || fail "-undo 不可和创建参数组合使用"
  fi
}

validate_regex() {
  local status
  [[ -n "$2" ]] || return 0
  [[ "" =~ $2 ]]
  status=$?
  ((status != 2)) || fail "$1 的正则表达式无效: $2"
}

initialize_sequence() {
  CURR_S=1
  CURR_E=1
  S_DIGITS=2
  E_DIGITS=2
  HAS_END=0
  END_E=0
  [[ "$MODE" != original && -n "$START_SEQ" ]] || return 0
  [[ "$START_SEQ" =~ $SEQ_REGEX ]] || fail "序号格式错误，示例 s01e01 或 s01e01-s01e12" 4
  local season="${BASH_REMATCH[1]}" episode="${BASH_REMATCH[2]}"
  local end_season="${BASH_REMATCH[4]}" end_episode="${BASH_REMATCH[5]}"
  S_DIGITS=${#season}
  E_DIGITS=${#episode}
  CURR_S=$((10#$season))
  CURR_E=$((10#$episode))
  if [[ -n "$end_episode" ]]; then
    ((10#$end_season == CURR_S)) || fail "结束序号季数必须与起始序号相同" 4
    END_E=$((10#$end_episode))
    ((END_E > CURR_E)) || fail "结束序号集数必须大于起始序号" 4
    HAS_END=1
    ((${#end_season} <= S_DIGITS)) || S_DIGITS=${#end_season}
    ((${#end_episode} <= E_DIGITS)) || E_DIGITS=${#end_episode}
  fi
}

validate_inputs() {
  [[ -n "$SRC" ]] || fail "源路径不能为空，使用 -h 查看帮助"
  [[ -f "$SRC" || -d "$SRC" ]] || fail "源路径必须是文件或目录: $SRC" 2
  # 末尾标记防止命令替换丢失路径本身末尾的换行。
  SRC=$(realpath -e -- "$SRC" && printf '.') || fail "无法解析源路径" 2
  SRC=${SRC%$'\n.'}
  if [[ -n "$DST" ]]; then
    [[ -d "$DST" ]] || fail "目标路径必须是已存在目录: $DST" 3
    DST=$(realpath -e -- "$DST" && printf '.') || fail "无法解析目标路径" 3
    DST=${DST%$'\n.'}
  fi
  validate_regex -fi "$FILTER_REGEX"
  validate_regex -fe "$FILTER_EXCLUDE_REGEX"
  initialize_sequence
}

file_matches() {
  local name="${1##*/}"
  [[ -z "$FILTER_REGEX" || "$name" =~ $FILTER_REGEX ]] || return 1
  [[ -z "$FILTER_EXCLUDE_REGEX" || ! "$name" =~ $FILTER_EXCLUDE_REGEX ]]
}

collect_files() {
  local path
  WORK_DIR=$(mktemp -d) || fail "创建临时目录失败"
  if [[ -f "$SRC" ]]; then
    file_matches "$SRC" && FILES+=("$SRC")
  else
    find "$SRC" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mkv' \) -print0 | sort -z >"$WORK_DIR/files" || fail "读取源文件失败"
    while IFS= read -r -d '' path; do
      file_matches "$path" && FILES+=("$path")
    done <"$WORK_DIR/files"
    find "$SRC" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z >"$WORK_DIR/directories" || fail "读取源目录失败"
    while IFS= read -r -d '' path; do DIRECTORIES+=("$path"); done <"$WORK_DIR/directories"
  fi
}

preflight_named_targets() {
  local source episode="$CURR_E"
  for source in "${FILES[@]}"; do
    ((! HAS_END || episode <= END_E)) || break
    set_default_target "$source" "$CURR_S" "$episode"
    [[ ! "$source" -ef "$TARGET" ]] || fail "目标目录已存在同一文件（same file），停止执行: $source → $TARGET"
    [[ "$MODE" == original ]] || ((episode++))
  done
}

preflight_same_files() {
  local source target identity episode="$CURR_E" target_count=0
  local -A selected_sources=() target_paths=()
  ((${#FILES[@]} > 0)) || return 0
  # 索引设备号和 inode，不读取文件内容，也不依赖目标名称。
  find -L "$DST" -maxdepth 1 -type f -printf '%D:%i\0%p\0' >"$WORK_DIR/identities" || fail "检查目标文件身份失败: $DST"
  while IFS= read -r -d '' identity; do
    IFS= read -r -d '' target || fail "目标文件身份数据不完整"
    ((target_count++))
    if ((target_count > 1000)); then
      preflight_named_targets
      return
    fi
    target_paths["$identity"]="$target"
  done <"$WORK_DIR/identities"
  for source in "${FILES[@]}"; do
    ((! HAS_END || episode <= END_E)) || break
    selected_sources["$source"]=1
    [[ "$MODE" == original ]] || ((episode++))
  done
  find "$SRC" -maxdepth 1 -type f -printf '%D:%i\0%p\0' >"$WORK_DIR/identities" || fail "检查源文件身份失败: $SRC"
  while IFS= read -r -d '' identity; do
    IFS= read -r -d '' source || fail "源文件身份数据不完整"
    [[ -n "${selected_sources["$source"]+present}" ]] || continue
    if [[ -n "${target_paths["$identity"]+present}" ]]; then
      fail "目标目录已存在同一文件（same file），停止执行: $source → ${target_paths["$identity"]}"
    fi
  done <"$WORK_DIR/identities"
}

set_default_target() {
  local name="${1##*/}"
  if [[ "$MODE" == original ]]; then
    TARGET="$DST/$name"
  else
    printf -v TARGET '%s/%s - s%0*de%0*d.%s' "$DST" "${name%.*}" "$S_DIGITS" "$2" "$E_DIGITS" "$3" "${name##*.}"
  fi
}

preview() {
  local directory path count episode="$CURR_E"
  echo "===== 预览内容 ====="
  [[ -z "$FILTER_REGEX" ]] || echo "应用包含正则: $FILTER_REGEX"
  [[ -z "$FILTER_EXCLUDE_REGEX" ]] || echo "应用排除正则: $FILTER_EXCLUDE_REGEX"
  for directory in "${DIRECTORIES[@]}"; do
    count=0
    find "$directory" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mkv' \) -print0 >"$WORK_DIR/files" || fail "读取目录失败: $directory"
    while IFS= read -r -d '' path; do
      if file_matches "$path"; then ((count++)); fi
    done <"$WORK_DIR/files"
    [[ -z "$FILTER_REGEX$FILTER_EXCLUDE_REGEX" || $count -gt 0 ]] || continue
    printf '目录: %s (包含 %d 个文件)\n' "${directory##*/}" "$count"
  done
  for path in "${FILES[@]}"; do
    ((! HAS_END || episode <= END_E)) || break
    set_default_target "$path" "$CURR_S" "$episode"
    if [[ "$MODE" == original ]]; then
      printf '  %s\n' "${TARGET##*/}"
    else
      printf '  %s → %s\n' "${path##*/}" "${TARGET##*/}"
      ((episode++))
    fi
  done
  ((${#FILES[@]} > 0)) || echo "文件: (无匹配文件)"
  echo "===== 预览结束 ====="
}

# 先保存待提交快照，再发布链接；主记录提交失败时保留快照供撤销。
prepare_log() {
  [[ -n "$LOG_TEMP" ]] && return 0
  [[ ! -e "$LOGFILE" || -f "$LOGFILE" ]] || fail "运行记录路径不是文件: $LOGFILE"
  [[ ! -e "$PENDING_LOG" || -f "$PENDING_LOG" ]] || fail "待提交记录路径不是文件: $PENDING_LOG"
  LOG_TEMP=$(mktemp "$LOGFILE.XXXXXX") || fail "创建运行记录失败: $LOGFILE"
}

write_pending() {
  local i
  prepare_log
  {
    printf '%s\0' "$LOG_FORMAT" || fail "写入运行记录失败"
    for i in "${!RECORD_PATHS[@]}"; do
      [[ -n "${RECORD_PATHS[i]}" ]] || continue
      printf '%s\0%s\0%s\0' "${RECORD_PATHS[i]}" "${RECORD_IDS[i]}" "${RECORD_KINDS[i]}" || fail "写入运行记录失败"
    done
  } >"$LOG_TEMP" || fail "写入运行记录失败: $LOGFILE"
  mv -fT -- "$LOG_TEMP" "$PENDING_LOG" || fail "保存待提交记录失败: $PENDING_LOG"
  LOG_TEMP=""
}

commit_pending() {
  mv -fT -- "$PENDING_LOG" "$LOGFILE" || fail "提交运行记录失败；待提交记录已保留，请执行 -undo"
}

file_identity() {
  [[ -f "$1" && ! -L "$1" ]] || return 1
  # 创建时间不随硬链接计数变化，并能区分多数 inode 重用。
  stat -c '%d:%i:%w' -- "$1"
}

identity_matches() {
  local actual
  actual=$(file_identity "$1") || return 1
  [[ "$actual" == "$2" ]]
}

load_log() {
  local record="$LOGFILE" marker path identity kind descriptor
  if path_exists "$PENDING_LOG"; then record="$PENDING_LOG"; fi
  [[ -f "$record" ]] || fail "未找到可读取的运行记录，无法撤销"
  exec {descriptor}<"$record" || fail "读取运行记录失败"
  IFS= read -r -d '' marker <&"$descriptor" || fail "旧版记录缺少文件身份，不能安全自动撤销；请手动核对"
  [[ "$marker" != vlink-log-v1 ]] || fail "旧版记录缺少文件身份，不能安全自动撤销；请手动核对"
  [[ "$marker" == "$LOG_FORMAT" ]] || fail "无法识别运行记录格式"
  while IFS= read -r -d '' path <&"$descriptor"; do
    IFS= read -r -d '' identity <&"$descriptor" || fail "运行记录不完整，未执行撤销"
    IFS= read -r -d '' kind <&"$descriptor" || fail "运行记录不完整，未执行撤销"
    [[ "$path" == /* && "$path" != "$LOGFILE" && "$path" != "$PENDING_LOG" ]] || fail "运行记录包含无效路径，未执行撤销"
    [[ "$identity" =~ ^[0-9]+:[0-9]+: ]] || fail "运行记录包含无效文件身份，未执行撤销"
    [[ "$kind" == link || "$kind" == stage ]] || fail "运行记录包含无效对象类型，未执行撤销"
    RECORD_PATHS+=("$path")
    RECORD_IDS+=("$identity")
    RECORD_KINDS+=("$kind")
  done
  [[ -z "$path" ]] || fail "运行记录不完整，未执行撤销"
  exec {descriptor}<&-
}

undo() {
  local i path actual parent pending=0
  load_log
  echo "开始撤销..."
  write_pending
  for i in "${!RECORD_PATHS[@]}"; do
    path="${RECORD_PATHS[i]}"
    if path_exists "$path"; then
      actual=""
      if [[ -f "$path" && ! -L "$path" ]]; then
        if ! actual=$(file_identity "$path"); then
          echo "读取文件身份失败，保留撤销项: $path" >&2
          pending=1
          continue
        fi
      fi
      if [[ "$actual" == "${RECORD_IDS[i]}" ]]; then
        if ! rm -f -- "$path"; then
          pending=1
          continue
        fi
        echo "删除文件: $path"
      else
        echo "路径已被替换，保留当前对象并移除失效记录: $path" >&2
      fi
    fi
    if [[ "${RECORD_KINDS[i]}" == stage ]]; then
      parent=${path%/*}
      if [[ -d "$parent" ]] && ! rmdir -- "$parent"; then
        pending=1
        continue
      fi
    fi
    RECORD_PATHS[i]=""
    RECORD_IDS[i]=""
    RECORD_KINDS[i]=""
    write_pending
    commit_pending
  done
  if [[ -f "$PENDING_LOG" ]]; then commit_pending; fi
  ((! pending)) || fail "部分路径未删除，运行记录只保留未完成项。"
  rm -f -- "$LOGFILE" || fail "清理运行记录失败"
  echo "撤销完成。"
}

read_reply() {
  printf '%s' "$1" >&2
  IFS= read -r REPLY || fail "输入已结束，停止处理。"
}

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

choose_target() {
  local source="$1" name="${1##*/}" exists season episode
  DECISION="create"
  while :; do
    set_default_target "$source" "$CURR_S" "$CURR_E"
    exists=0
    path_exists "$TARGET" && exists=1
    if [[ "$MODE" != interactive && $exists == 0 ]]; then return 0; fi
    printf '源文件: %s\n目标文件: %s\n' "$source" "$TARGET"
    if ((exists)); then
      if [[ "$MODE" == interactive ]]; then
        read_reply '输入新名字（无后缀），pass 跳过，end 结束，回车覆盖: '
      elif [[ "$MODE" == fast ]]; then
        read_reply '输入新名字（无后缀），pass 跳过，end 结束: '
      else read_reply '输入新名字（无后缀），pass 跳过: '; fi
    else read_reply '回车接受默认，sXXeXX 改序号，pass 跳过，end 结束: '; fi
    if [[ "$REPLY" == pass ]]; then
      DECISION="skip"
      return 0
    fi
    if [[ "$REPLY" == end && "$MODE" != original ]]; then
      DECISION="end"
      return 0
    fi
    if [[ -z "$REPLY" ]]; then
      if [[ "$MODE" == interactive ]]; then
        ((! exists)) || DECISION="replace"
        return 0
      fi
      echo "文件名不能为空" >&2
      continue
    fi
    if ((! exists)) && [[ "$REPLY" =~ ^s([0-9]+)e([0-9]+)$ ]]; then
      season="${BASH_REMATCH[1]}"
      episode="${BASH_REMATCH[2]}"
      if ((HAS_END && (10#$season != CURR_S || 10#$episode > END_E))); then
        echo "新序号必须与起始季数相同，且不超过结束序号" >&2
        continue
      fi
      CURR_S=$((10#$season))
      CURR_E=$((10#$episode))
      ((${#season} <= S_DIGITS)) || S_DIGITS=${#season}
      ((${#episode} <= E_DIGITS)) || E_DIGITS=${#episode}
      continue
    fi
    ((exists)) || {
      echo "输入无效，请重试" >&2
      continue
    }
    [[ "$REPLY" != */* && "$REPLY" != *\\* ]] || {
      echo "请输入文件名，不要包含路径" >&2
      continue
    }
    TARGET="$DST/$REPLY.${name##*.}"
    if path_exists "$TARGET"; then
      echo "目标已存在，请重试: $TARGET" >&2
      continue
    fi
    return 0
  done
}

create_target() {
  local source="$1" identity stage_index
  [[ "$TARGET" != "$LOGFILE" && "$TARGET" != "$PENDING_LOG" ]] || fail "目标不能覆盖运行记录"
  [[ ! "$source" -ef "$TARGET" ]] || fail "源文件与目标指向同一文件（same file），停止执行: $source → $TARGET"
  prepare_log
  WORK_DIR=$(mktemp -d "$DST/.vlink.XXXXXX") || fail "创建临时目录失败"
  ln -T -- "$source" "$WORK_DIR/link" || fail "创建临时硬链接失败，保留原目标: $TARGET"
  identity=$(file_identity "$WORK_DIR/link") || fail "读取临时硬链接身份失败"
  stage_index=${#RECORD_PATHS[@]}
  RECORD_PATHS+=("$WORK_DIR/link")
  RECORD_IDS+=("$identity")
  RECORD_KINDS+=(stage)
  RECORD_PATHS+=("$TARGET")
  RECORD_IDS+=("$identity")
  RECORD_KINDS+=(link)
  write_pending
  if [[ "$DECISION" == replace ]]; then
    if mv -fT -- "$WORK_DIR/link" "$TARGET"; then
      :
    else
      identity_matches "$TARGET" "$identity" || rm -f -- "$PENDING_LOG"
      fail "替换硬链接失败，保留原目标: $TARGET"
    fi
  else
    if ln -T -- "$WORK_DIR/link" "$TARGET"; then
      :
    else
      identity_matches "$TARGET" "$identity" || rm -f -- "$PENDING_LOG"
      fail "创建硬链接失败: $TARGET"
    fi
  fi
  CREATED_ITEMS+=("$TARGET")
  cleanup_work
  if ! path_exists "${RECORD_PATHS[stage_index]%/*}"; then
    RECORD_PATHS[stage_index]=""
    RECORD_IDS[stage_index]=""
    RECORD_KINDS[stage_index]=""
  fi
  write_pending
  commit_pending
  echo "创建硬链接: $TARGET"
}

execute() {
  local source
  ! path_exists "$PENDING_LOG" || fail "存在未提交的运行记录，请先执行 -undo"
  preflight_same_files
  cleanup_work
  for source in "${FILES[@]}"; do
    ((! HAS_END || CURR_E <= END_E)) || break
    choose_target "$source"
    case "$DECISION" in
    skip) continue ;;
    end) break ;;
    esac
    create_target "$source"
    [[ "$MODE" == original ]] || ((CURR_E++))
  done
  printf '共生成 %d 个文件\n' "${#CREATED_ITEMS[@]}"
}

main() {
  if (($# == 0)); then
    show_help
    return
  fi
  parse_args "$@"
  if [[ "$ACTION" == undo ]]; then
    acquire_lock
    undo
    return
  fi
  validate_inputs
  [[ -z "$DST" ]] || acquire_lock
  collect_files
  if [[ -z "$DST" ]]; then preview; else execute; fi
}

main "$@"
