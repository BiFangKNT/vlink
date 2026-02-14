#!/bin/bash

LOGFILE="$(dirname "$0")/vlink_last_run.log"
declare -a CREATED_ITEMS=()

cleanup() {
  echo ""
  echo "捕获退出信号，写入已创建文件/目录列表到：$LOGFILE"
  printf '%s\n' "${CREATED_ITEMS[@]}" > "$LOGFILE"
  echo "已写入 ${#CREATED_ITEMS[@]} 条记录。"
  exit 1
}
trap cleanup SIGINT SIGTERM

show_help() {
  cat << EOF
用法: $(basename "$0") [选项] <源路径> [目标路径] [起始序号 sXXeXX] [过滤正则]

功能:
  硬链接管理工具，支持视频硬链接、递归、自动重命名交互及一键执行。

选项:
  -h, --help           显示帮助
  -o, --original-name  非递归，视频原名硬链接，无重命名无交互（冲突跳过）
  -r, --recursive      递归处理所有文件，保留目录结构，交互重名
  -f                   默认模式一键执行（自动重命名，无交互，遇重名停止）
  -undo                撤销上次执行生成的所有文件和目录
  -op, --origin-path   指定源路径（等同于第一个位置参数）
  -lp, --link-path     指定目标硬链接目录（等同于第二个位置参数）
  -sn, --sequence      指定起始/结束序号，格式 sXXeXX[-|,]sXXeYY
  -fi, --filter        指定过滤正则，使用引号包裹

参数:
  源路径：必须
  目标路径：撤销和预览除外必须
  起始序号：sXXeXX 或 sXXeXX,sXXeYY（sXXeXX-sXXeYY），仅默认模式有效，默认 s01e01
  过滤正则：可选，匹配文件名，使用引号包裹，无需额外转义，支持正则

示例:
  预览源路径待处理文件：
    $ $(basename "$0") /源路径

  自动重命名交互（默认）：
    $ $(basename "$0") /源路径 /目标路径 s01e01

  使用命名参数：
    $ $(basename "$0") -op /源路径 -lp /目标路径 -sn s01e01-s01e12 -fi "1080p"

  指定过滤正则（位置参数方式）：
    $ $(basename "$0") /源路径 /目标路径 s01e01 "1080p"

  原名硬链接无交互：
    $ $(basename "$0") -o /源路径 /目标路径

  递归保目录结构交互重名：
    $ $(basename "$0") -r /源路径 /目标路径

  自动重命名一键执行，无交互遇重名停：
    $ $(basename "$0") -f /源路径 /目标路径

  撤销上次执行：
    $ $(basename "$0") -undo

EOF
}

format_seq() { 
  printf "s%0${seq_s_digits}de%0${seq_e_digits}d" "$1" "$2"
}

USE_ORIGINAL=0
USE_RECURSIVE=0
CMD_UNDO=0
USE_FAST=0

# 序号格式化位数，默认2位
seq_s_digits=2
seq_e_digits=2
HAS_END_SEQ=0
end_s=0
end_e=0
SEQ_REGEX='^s([0-9]+)e([0-9]+)([,-]s([0-9]+)e([0-9]+))?$'
FILTER_REGEX=""

SRC=""
DST=""
START_SEQ=""
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    -o|--original-name)
      USE_ORIGINAL=1
      shift
      ;;
    -r|--recursive)
      USE_RECURSIVE=1
      shift
      ;;
    -undo)
      CMD_UNDO=1
      shift
      ;;
    -f)
      USE_FAST=1
      shift
      ;;
    -op|--origin-path)
      [[ $# -ge 2 ]] || { echo "-op 需要路径参数"; exit 1; }
      SRC="$2"
      shift 2
      ;;
    -lp|--link-path)
      [[ $# -ge 2 ]] || { echo "-lp 需要路径参数"; exit 1; }
      DST="$2"
      shift 2
      ;;
    -sn|--sequence)
      [[ $# -ge 2 ]] || { echo "-sn 需要序号参数"; exit 1; }
      START_SEQ="$2"
      shift 2
      ;;
    -fi|--filter)
      [[ $# -ge 2 ]] || { echo "-fi 需要正则参数"; exit 1; }
      FILTER_REGEX="$2"
      shift 2
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        POSITIONAL_ARGS+=("$1")
        shift
      done
      break
      ;;
    -*)
      echo "未知选项 $1，使用 -h 查看帮助"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ $CMD_UNDO -eq 1 ]]; then
  if [[ ! -f "$LOGFILE" ]]; then
    echo "未找到上次记录，无法撤销"
    exit 1
  fi
  echo "开始撤销..."
  while IFS= read -r item; do
    if [[ -d "$item" ]]; then
      echo "删除目录 $item"
      rm -rf "$item"
    elif [[ -f "$item" ]]; then
      echo "删除文件 $item"
      rm -f "$item"
    fi
  done < "$LOGFILE"
  echo "撤销完成。"
  rm -f "$LOGFILE"
  exit 0
fi

if [[ $USE_FAST -eq 1 && ($USE_ORIGINAL -eq 1 || $USE_RECURSIVE -eq 1 || $CMD_UNDO -eq 1) ]]; then
  echo "-f不可和其他选项组合使用"
  exit 1
fi

if [[ -z "$SRC" && ${#POSITIONAL_ARGS[@]} -gt 0 ]]; then
  SRC="${POSITIONAL_ARGS[0]}"
  POSITIONAL_ARGS=("${POSITIONAL_ARGS[@]:1}")
fi

for arg in "${POSITIONAL_ARGS[@]}"; do
  if [[ -z "$START_SEQ" && "$arg" =~ $SEQ_REGEX ]]; then
    START_SEQ="$arg"
    continue
  fi
  if [[ -z "$DST" && -d "$arg" ]]; then
    DST="$arg"
    continue
  fi
  if [[ -z "$FILTER_REGEX" ]]; then
    FILTER_REGEX="$arg"
    continue
  fi
  if [[ -z "$DST" ]]; then
    DST="$arg"
    continue
  fi
  echo "无法识别的额外参数: $arg"
  exit 1
done

if [[ -z "$SRC" ]]; then
  show_help
  exit 0
fi

if [[ ! -e "$SRC" ]]; then
  echo "源路径不存在"
  exit 2
fi

if [[ -n "$DST" ]]; then
  # 将相对路径转换为绝对路径
  DST=$(realpath "$DST" 2>/dev/null) || DST=$(cd "$(dirname "$DST")" && pwd)/$(basename "$DST")
  if [[ ! -d "$DST" ]]; then
    echo "目标路径必须是已存在目录"
    exit 3
  fi
fi

collect_files_and_dirs() {
  files=()
  dirs=()

  if [[ -f "$SRC" ]]; then
    files+=("$SRC")
  else
    if [[ $USE_RECURSIVE -eq 1 ]]; then
      while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$SRC" -type f -print0)
      while IFS= read -r -d '' d; do dirs+=("$d"); done < <(find "$SRC" -mindepth 1 -maxdepth 1 -type d -print0)
    else
      while IFS= read -r -d '' d; do dirs+=("$d"); done < <(find "$SRC" -mindepth 1 -maxdepth 1 -type d -print0)

      if [[ $USE_ORIGINAL -eq 1 ]]; then
        while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$SRC" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mkv" \) -print0)
      else
        while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$SRC" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mkv" \) -print0)
      fi
    fi
  fi

  apply_filter

  # 对文件和目录进行排序
  if [[ ${#files[@]} -gt 0 ]]; then
    IFS=$'\n' files=($(sort <<<"${files[*]}")); unset IFS
  fi
  if [[ ${#dirs[@]} -gt 0 ]]; then
    IFS=$'\n' dirs=($(sort <<<"${dirs[*]}")); unset IFS
  fi
}

count_files_in_dir() {
  local d="$1"
  local c=0
  if [[ $USE_RECURSIVE -eq 1 ]]; then
    if [[ -z "$FILTER_REGEX" ]]; then
      c=$(find "$d" -type f | wc -l)
    else
      while IFS= read -r -d "" f; do
        local base
        base=$(basename "$f")
        [[ "$base" =~ $FILTER_REGEX ]] && ((c++))
      done < <(find "$d" -type f -print0)
    fi
  else
    if [[ -z "$FILTER_REGEX" ]]; then
      c=$(find "$d" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mkv" \) | wc -l)
    else
      while IFS= read -r -d "" f; do
        local base
        base=$(basename "$f")
        [[ "$base" =~ $FILTER_REGEX ]] && ((c++))
      done < <(find "$d" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mkv" \) -print0)
    fi
  fi
  echo "$c"
}

apply_filter() {
  if [[ -z "$FILTER_REGEX" ]]; then return; fi
  local filtered=()
  for f in "${files[@]}"; do
    local base
    base=$(basename "$f")
    if [[ "$base" =~ $FILTER_REGEX ]]; then
      filtered+=("$f")
    fi
  done
  files=("${filtered[@]}")
}

preview_mode() {
  collect_files_and_dirs
  echo "===== 预览内容 ====="
  if [[ -n "$FILTER_REGEX" ]]; then
    echo "应用过滤正则: $FILTER_REGEX"
  fi
  if [[ ${#dirs[@]} -gt 0 ]]; then
    echo "目录："
    for d in "${dirs[@]}"; do
      n=$(count_files_in_dir "$d")
      if [[ -n "$FILTER_REGEX" && $n -eq 0 ]]; then
        continue
      fi
      echo "  $(basename "$d")   (包含 $n 个文件)"
    done
  fi
  if [[ ${#files[@]} -gt 0 ]]; then
    echo "文件："
    local temp_curr_s=$curr_s
    local temp_curr_e=$curr_e
    local printed=0
    for f in "${files[@]}"; do
      base=$(basename "$f")
      if [[ $USE_RECURSIVE -eq 0 && $USE_ORIGINAL -eq 0 && $HAS_END_SEQ -eq 1 && $temp_curr_e -gt $end_e ]]; then
        echo "  (达到结束序号 $(format_seq $start_s $end_e)，后续文件未展示)"
        printed=1
        break
      fi
      if [[ $USE_RECURSIVE -eq 0 && $USE_ORIGINAL -eq 0 ]]; then
        # 默认模式或快速模式，显示带序号的文件名
        ext="${base##*.}"
        name="${base%.*}"
        seqname="$(format_seq $temp_curr_s $temp_curr_e)"
        echo "  $base  →  ${name} - ${seqname}.${ext}"
        ((temp_curr_e++))
      else
        # 其他模式，显示原文件名
        echo "  $base"
      fi
      printed=1
    done
    if [[ $printed -eq 0 && -n "$FILTER_REGEX" ]]; then
      echo "  (过滤后无匹配文件)"
    fi
  elif [[ -n "$FILTER_REGEX" ]]; then
    echo "文件："
    echo "  (过滤后无匹配文件)"
  fi
  echo "===== 预览结束 ====="
}

declare -A exist_map=()
scan_target_one_level() {
  if [[ -z "$DST" ]]; then return; fi
  while IFS= read -r -d '' f; do exist_map["$(basename "$f")"]="file"; done < <(find "$DST" -mindepth 1 -maxdepth 1 -type f -print0)
  while IFS= read -r -d '' d; do exist_map["$(basename "$d")"]="dir"; done < <(find "$DST" -mindepth 1 -maxdepth 1 -type d -print0)
}

prompt_rename() {
  local oldname="$1"
  local base="${oldname%.*}"
  local ext="${oldname##*.}"
  local newbase=""
  while :; do
    read -p "输入新文件名（无后缀），输入 pass 跳过: " newbase
    [[ "$newbase" == "pass" ]] && { echo "skip"; return 1; }
    [[ -z "$newbase" ]] && { echo "文件名不能为空"; continue; }
    local candidate="${newbase}.${ext}"
    [[ -n "${exist_map[$candidate]}" ]] && { echo "冲突：$candidate 已存在，请重试"; continue; }
    echo "$candidate"
    return 0
  done
}

prompt_rename_dir() {
  local olddir="$1"
  local base=$(basename "$olddir")
  while :; do
    read -p "目录 '$base' 已存在，输入新目录名，或 pass 跳过: " newname
    [[ "$newname" == "pass" ]] && { echo "skip"; return 1; }
    [[ -z "$newname" ]] && { echo "目录名不能为空"; continue; }
    [[ -n "${exist_map[$newname]}" ]] && { echo "目录名已存在，重试"; continue; }
    echo "$newname"
    return 0
  done
}

add_created() {
  CREATED_ITEMS+=("$1")
}

check_skip_or_rename() {
  local targetpath="$1"
  local isdir="$2"
  local basename=$(basename "$targetpath")
  if [[ -n "${exist_map[$basename]}" ]]; then
    if [[ $isdir -eq 1 ]]; then
      echo "目标已有同名目录: $basename"
      local newname
      if newname=$(prompt_rename_dir "$basename"); then
        echo "$newname"
        return 0
      else
        return 1
      fi
    else
      echo "目标已有同名文件: $basename"
      local newname
      if newname=$(prompt_rename "$basename"); then
        echo "$newname"
        return 0
      else
        return 1
      fi
    fi
  else
    echo "$basename"
    return 0
  fi
}

fast_mode() {
  collect_files_and_dirs
  scan_target_one_level

  declare -A dir_targetname_map=()
  if [[ $USE_RECURSIVE -eq 1 ]]; then
    for d in "${dirs[@]}"; do
      base=$(basename "$d")
      if [[ -n "${exist_map[$base]}" ]]; then
        echo "一键执行模式遇目标目录重名: $base，必须处理"
        while :; do
          read -p "输入新目录名，或 pass 跳过: " newname
          [[ "$newname" == "pass" ]] && { echo "跳过目录 $base"; base=""; break; }
          [[ -z "$newname" ]] && { echo "不能为空"; continue; }
          [[ -n "${exist_map[$newname]}" ]] && { echo "已存在，重试"; continue; }
          base="$newname"
          break
        done
        [[ -z "$base" ]] && continue
      fi
      target_dir="$DST/$base"
      mkdir -p "$target_dir"
      echo "创建目录 $target_dir"
      add_created "$target_dir"
      exist_map["$base"]="dir"
      dir_targetname_map["$d"]="$target_dir"
    done
  fi

  for f in "${files[@]}"; do
    if [[ $HAS_END_SEQ -eq 1 && $curr_e -gt $end_e ]]; then
      echo "已达到结束序号 $(format_seq $start_s $end_e)，停止处理剩余文件。"
      break
    fi
    rel_path="${f#$SRC/}"
    top_dir="${rel_path%%/*}"

    target_base_dir="$DST"
    if [[ $USE_RECURSIVE -eq 1 && -n "$top_dir" && "$rel_path" != "$top_dir" ]]; then
      target_base_dir="${dir_targetname_map["$SRC/$top_dir"]}"
      sub_rel_dir="${rel_path#*/}"
      sub_rel_dir_dir=$(dirname "$sub_rel_dir")
      [[ "$sub_rel_dir_dir" != "." ]] && { target_base_dir="$target_base_dir/$sub_rel_dir_dir"; mkdir -p "$target_base_dir"; }
    fi

    basef=$(basename "$f")
    ext="${basef##*.}"
    name="${basef%.*}"

    while :; do
      seqname="$(format_seq $curr_s $curr_e)"
      newname="${name} - ${seqname}.${ext}"
      target_f="$target_base_dir/$newname"

      if [[ -e "$target_f" ]]; then
        echo "重名文件: $target_f，必须处理"
        read -p "输入新文件名(无后缀)或 pass跳过，end结束: " nn
        if [[ "$nn" == "end" ]]; then
          echo "结束剩余文件处理"
          target_f=""
          break 2
        fi
        [[ "$nn" == "pass" ]] && { echo "跳过文件 $f"; target_f=""; break; }
        [[ -z "$nn" ]] && { echo "文件名不能为空"; continue; }
        candidate="$target_base_dir/$nn.$ext"
        if [[ -e "$candidate" ]]; then
          echo "文件已存在，重试"
          continue
        fi
        target_f="$candidate"
        break
      else
        break
      fi
    done
    [[ -z "$target_f" ]] && continue

    ln "$f" "$target_f"
    echo "创建硬链接: $target_f"
    add_created "$target_f"
    exist_map["$(basename "$target_f")"]="file"
    ((curr_e++))
  done
  echo "一键执行完成，生成文件及目录列表："
  for item in "${CREATED_ITEMS[@]}"; do
    echo "$item"
  done
}

# 处理起始序号参数
start_s=1
start_e=1
if [[ $USE_RECURSIVE -eq 0 && $USE_ORIGINAL -eq 0 && -n "$START_SEQ" ]]; then
  if [[ "$START_SEQ" =~ $SEQ_REGEX ]]; then
    start_s_str="${BASH_REMATCH[1]}"
    start_e_str="${BASH_REMATCH[2]}"
    seq_s_digits=${#start_s_str}
    seq_e_digits=${#start_e_str}
    start_s=$((10#${start_s_str}))
    start_e=$((10#${start_e_str}))

    if [[ -n "${BASH_REMATCH[3]}" ]]; then
      end_s_str="${BASH_REMATCH[4]}"
      end_e_str="${BASH_REMATCH[5]}"
      end_s=$((10#${end_s_str}))
      end_e=$((10#${end_e_str}))
      if (( end_s != start_s )); then
        echo "结束序号季数必须与起始序号相同"
        exit 4
      fi
      if (( end_e <= start_e )); then
        echo "结束序号集数必须大于起始序号"
        exit 4
      fi
      HAS_END_SEQ=1
      if [[ ${#end_s_str} -gt $seq_s_digits ]]; then
        seq_s_digits=${#end_s_str}
      fi
      if [[ ${#end_e_str} -gt $seq_e_digits ]]; then
        seq_e_digits=${#end_e_str}
      fi
    fi
  else
    echo "序号格式错误 示例 s01e01 或 s01e01,s01e12"
    exit 4
  fi
fi
curr_s=$start_s
curr_e=$start_e

if [[ -z "$DST" ]]; then
  preview_mode
  exit 0
fi

scan_target_one_level

collect_files_and_dirs

if [[ $USE_FAST -eq 1 ]]; then
  fast_mode
  printf '%s\n' "${CREATED_ITEMS[@]}" > "$LOGFILE"
  exit 0
elif [[ $USE_RECURSIVE -eq 1 ]]; then
  declare -A dir_targetname_map=()
  for d in "${dirs[@]}"; do
    base=$(basename "$d")
    newname=$(check_skip_or_rename "$DST/$base" 1)
    if [[ "$newname" == "skip" ]]; then
      echo "跳过目录 $base"
      continue
    fi
    target_dir="$DST/$newname"
    [[ ! -d "$target_dir" ]] && { mkdir -p "$target_dir"; echo "创建目录: $target_dir"; add_created "$target_dir"; exist_map["$newname"]="dir"; }
    dir_targetname_map["$d"]="$target_dir"
  done
  for f in "${files[@]}"; do
    rel_path="${f#$SRC/}"
    top_dir="${rel_path%%/*}"
    [[ "$top_dir" == "$rel_path" ]] && target_base_dir="$DST" || {
      target_base_dir="${dir_targetname_map["$SRC/$top_dir"]}"
      sub_rel_dir="${rel_path#*/}"
      sub_rel_dir_dir=$(dirname "$sub_rel_dir")
      [[ "$sub_rel_dir_dir" != "." ]] && { target_base_dir="$target_base_dir/$sub_rel_dir_dir"; mkdir -p "$target_base_dir"; }
    }
    basef=$(basename "$f")
    target_f="$target_base_dir/$basef"
    if [[ -e "$target_f" ]]; then
      echo "文件重名: $target_f"
      while :; do
        read -p "输入新文件名(无后缀)或 pass跳过: " nn
        [[ "$nn" == "pass" ]] && { echo "跳过 $f"; target_f=""; break; }
        [[ -z "$nn" ]] && { echo "不能为空"; continue; }
        target_new="$target_base_dir/$nn.${basef##*.}"
        [[ -e "$target_new" ]] && { echo "已存在"; continue; }
        target_f="$target_new"
        break
      done
      [[ -z "$target_f" ]] && continue
    fi
    ln "$f" "$target_f"
    echo "创建硬链接: $target_f"
    add_created "$target_f"
  done
  echo "递归完成."
elif [[ $USE_ORIGINAL -eq 1 ]]; then
  for f in "${files[@]}"; do
    if [[ $HAS_END_SEQ -eq 1 && $curr_e -gt $end_e ]]; then
      echo "已达到结束序号 $(format_seq $start_s $end_e)，停止处理剩余文件。"
      break
    fi
    base=$(basename "$f")
    target="$DST/$base"
    if [[ -e "$target" ]]; then
      echo "重名文件: $base"
      newname=$(prompt_rename "$base")
      [[ $? -eq 1 ]] && { echo "跳过 $base"; continue; }
      target="$DST/$newname"
    fi
    ln "$f" "$target"
    echo "创建硬链接: $target"
    add_created "$target"
    exist_map["$(basename "$target")"]="file"
  done
else
  IFS=$'\n' sorted_files=($(printf '%s\n' "${files[@]##*/}" | sort))
  tmp_files=()
  for fbase in "${sorted_files[@]}"; do
    for ff in "${files[@]}"; do
      [[ "${ff##*/}" == "$fbase" ]] && { tmp_files+=("$ff"); break; }
    done
  done
  files=("${tmp_files[@]}")

  for f in "${files[@]}"; do
    base=$(basename "$f")
    ext="${base##*.}"
    name="${base%.*}"
    seqname="$(format_seq $curr_s $curr_e)"
    newname="${name} - ${seqname}.${ext}"
    target="$DST/$newname"
    while :; do
      echo ""
      echo "源文件: $base"
      echo "默认命名: $newname"
      if [[ -e "$target" ]]; then
        echo "目标已存在: $newname"
        read -p "输入新名字（无后缀）pass跳过，end结束，回车覆盖: " newbasename
        if [[ -z "$newbasename" ]]; then
          echo "覆盖文件 $newname"
          rm -f "$target"
          ln "$f" "$target"
          echo "创建硬链接: $target"
          add_created "$target"
          exist_map["$newname"]="file"
          ((curr_e++))
          break
        elif [[ "$newbasename" == "pass" ]]; then
          echo "跳过 $base"
          break
        elif [[ "$newbasename" == "end" ]]; then
          echo "结束剩余文件处理"
          break 2
        else
          candidate="${newbasename}.${ext}"
          [[ -e "$DST/$candidate" ]] && { echo "冲突 $candidate 重试"; continue; }
          target="$DST/$candidate"
          ln "$f" "$target"
          echo "创建硬链接: $target"
          add_created "$target"
          exist_map["$candidate"]="file"
          ((curr_e++))
          break
        fi
      else
        [[ $USE_FAST -eq 1 ]] && {
          ln "$f" "$target"
          echo "创建硬链接: $target"
          add_created "$target"
          exist_map["$newname"]="file"
          ((curr_e++))
          break
        }
        read -p "回车接受默认，sXXeXX改序号，pass跳过，end结束: " input
        if [[ -z "$input" ]]; then
          ln "$f" "$target"
          echo "创建硬链接: $target"
          add_created "$target"
          exist_map["$newname"]="file"
          ((curr_e++))
          break
        elif [[ "$input" =~ ^s([0-9]+)e([0-9]+)$ ]]; then
          new_seq_s="${BASH_REMATCH[1]}"
          new_seq_e="${BASH_REMATCH[2]}"
          new_s=$((10#${new_seq_s}))
          new_e=$((10#${new_seq_e}))
          if [[ $HAS_END_SEQ -eq 1 ]]; then
            expected_season=$(printf "s%0${seq_s_digits}d" "$start_s")
            if (( new_s != start_s )); then
              echo "季数必须保持为 ${expected_season}"
              continue
            fi
            if (( new_e > end_e )); then
              echo "已超过结束序号 $(format_seq $start_s $end_e)"
              continue
            fi
          fi
          if [[ ${#new_seq_s} -gt $seq_s_digits ]]; then
            seq_s_digits=${#new_seq_s}
          fi
          if [[ ${#new_seq_e} -gt $seq_e_digits ]]; then
            seq_e_digits=${#new_seq_e}
          fi
          curr_s=$new_s
          curr_e=$new_e
          seqname="$(format_seq $curr_s $curr_e)"
          newname="${name} - ${seqname}.${ext}"
          target="$DST/$newname"
          echo "序号重置为 $seqname"
        elif [[ "$input" == "pass" ]]; then
          echo "跳过 $base"
          break
        elif [[ "$input" == "end" ]]; then
          echo "结束剩余文件处理"
          break 2
        else
          echo "输入无效，请重试"
        fi
      fi
    done
  done
fi

echo "写入已创建文件和目录列表到 $LOGFILE"
printf '%s\n' "${CREATED_ITEMS[@]}" > "$LOGFILE"
echo "共生成 ${#CREATED_ITEMS[@]} 个文件/目录"

if [[ $USE_FAST -eq 0 ]]; then
  echo "生成的所有文件和目录路径:"
  for item in "${CREATED_ITEMS[@]}"; do
    echo "$item"
  done
fi

exit 0

