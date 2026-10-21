#!/bin/bash
# push_to_phone.sh — 推送 context_reorder filter 到手机 fcitx5-android
#
# 用法:
#   ./lua/push_to_phone.sh              # 推送到所有已连接设备
#   ./lua/push_to_phone.sh <serial>...  # 只推送到指定设备（adb devices 查看 serial）
#
# 流程:
#   1. 本地词表数据缺失时，自动运行 build_ctx_words.py 生成
#   2. 拉取手机端 double_pinyin.custom.yaml，动态合并出 .phone_double_pinyin.custom.yaml
#      （保留手机端已有 filter 如 adjacent_corrector，只追加 context_reorder）
#   3. 推送 4 个文件: 合并后的 custom.yaml + context_reorder.lua + ctx_words.txt/idx
#   4. 逐文件校验远端大小与本地一致
#
# 词库变更后: python3 lua/build_ctx_words.py && ./lua/push_to_phone.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RIME_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PHONE_RIME="/sdcard/Android/data/org.fcitx.fcitx5.android.fx/files/data/rime"
MERGED="$RIME_ROOT/.phone_double_pinyin.custom.yaml"

fail() { echo "[error] $*" >&2; exit 1; }

command -v adb >/dev/null 2>&1 || fail "找不到 adb，请先安装 Android platform-tools"

# ---- 1. 本地数据文件检查（缺失时自动构建）----
if [[ ! -f "$SCRIPT_DIR/ctx_words.txt" || ! -f "$SCRIPT_DIR/ctx_words.idx" ]]; then
  echo "[info] 词表数据文件缺失，运行 build_ctx_words.py 生成（约 8 秒）..."
  python3 "$SCRIPT_DIR/build_ctx_words.py" || fail "build_ctx_words.py 运行失败"
fi
for f in context_reorder.lua ctx_words.txt ctx_words.idx; do
  [[ -f "$SCRIPT_DIR/$f" ]] || fail "缺少 $SCRIPT_DIR/$f"
done

# ---- 2. 设备列表 ----
if [[ $# -gt 0 ]]; then
  DEVICES=("$@")
else
  DEVICES=()
  while IFS= read -r s; do DEVICES+=("$s"); done < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')
fi
[[ ${#DEVICES[@]} -gt 0 ]] || fail "没有已连接的 adb 设备（adb devices 查看）"

# 合并手机端 custom.yaml：确保 context_reorder 已注册、grammar/language 已设置。
# 保留手机端已有 filter（如 adjacent_corrector）与其余全部配置。
merge_custom_yaml() {
  local src="$1"
  local grammar_lang="zh-hant-t-essay-bgw"
  local need_filter=1 need_grammar=1
  grep -q 'lua_filter@\*context_reorder' "$src" && need_filter=0
  grep -q "^  grammar/language: $grammar_lang" "$src" && need_grammar=0

  if [[ $need_filter -eq 0 && $need_grammar -eq 0 ]]; then
    cp "$src" "$MERGED"
    echo "  [info] context_reorder 与 grammar/language 均已配置，custom.yaml 无需改动"
    return 0
  fi
  grep -q '^patch:' "$src" || { echo "  [error] 手机端 custom.yaml 无 patch: 段，请手动合并"; return 1; }

  awk -v need_filter="$need_filter" -v need_grammar="$need_grammar" -v grammar_lang="$grammar_lang" '
    { lines[++n] = $0 }
    /engine\/filters\/\+/ { in_filters = 1; next }
    in_filters {
      if ($0 ~ /^[ \t]*- /) last_filter = n
      else in_filters = 0
    }
    /^  grammar\/language:/ { grammar_line = n }
    END {
      if (need_filter && last_filter == 0) {
        print "no-filters-block" > "/dev/stderr"
        exit 1
      }
      for (i = 1; i <= n; i++) {
        # 已有 grammar/language 行: 原位替换为 bgw（避免 YAML 重复键）
        if (grammar_line && i == grammar_line) {
          print "  grammar/language: " grammar_lang
        } else {
          print lines[i]
        }
        if (need_filter && i == last_filter) print "    - lua_filter@*context_reorder"
      }
      if (need_filter) {
        print ""
        print "  # 上下文重排（数据文件由 lua/build_ctx_words.py 生成）"
        print "  context_reorder/max_context: 6"
        print "  context_reorder/max_candidates: 100"
      }
      # 无 grammar/language 行时才追加
      if (need_grammar && !grammar_line) {
        print ""
        print "  # octagram 语言模型"
        print "  grammar/language: " grammar_lang
      }
    }
  ' "$src" > "$MERGED" || { echo "  [error] 合并失败：custom.yaml 无 engine/filters/+ 列表，请手动合并"; return 1; }
  echo "  [info] 已合并，差异:"
  diff "$src" "$MERGED" | sed 's/^/    /'
  return 0
}

FAILED=0
for serial in "${DEVICES[@]}"; do
  echo "=== 设备 $serial ==="
  tmp="$(mktemp -d)"

  # 拉取手机端 custom.yaml 并合并（确保 context_reorder + grammar/language）
  if adb -s "$serial" pull "$PHONE_RIME/double_pinyin.custom.yaml" "$tmp/" >/dev/null 2>&1; then
    merge_custom_yaml "$tmp/double_pinyin.custom.yaml" || { FAILED=1; rm -rf "$tmp"; continue; }
  else
    cat > "$MERGED" <<'EOF'
patch:
  engine/filters/+:
    - lua_filter@*context_reorder

  context_reorder/max_context: 6
  context_reorder/max_candidates: 100
  grammar/language: zh-hant-t-essay-bgw
EOF
    echo "  [info] 手机端无 custom.yaml，使用最小模板"
  fi

  # 推送 4 个文件
  ok=1
  adb -s "$serial" push "$MERGED" "$PHONE_RIME/double_pinyin.custom.yaml" >/dev/null || ok=0
  for f in context_reorder.lua ctx_words.txt ctx_words.idx; do
    adb -s "$serial" push "$SCRIPT_DIR/$f" "$PHONE_RIME/lua/$f" >/dev/null || ok=0
  done
  [[ $ok -eq 1 ]] || { echo "  [error] push 失败"; FAILED=1; rm -rf "$tmp"; continue; }

  # 校验远端文件大小（stat -f%z 为 macOS 写法）
  for f in "double_pinyin.custom.yaml:$MERGED" \
           "lua/context_reorder.lua:$SCRIPT_DIR/context_reorder.lua" \
           "lua/ctx_words.txt:$SCRIPT_DIR/ctx_words.txt" \
           "lua/ctx_words.idx:$SCRIPT_DIR/ctx_words.idx"; do
    remote="${f%%:*}"; local_path="${f#*:}"
    want="$(stat -f%z "$local_path")"
    got="$(adb -s "$serial" shell stat -c%s "$PHONE_RIME/$remote" 2>/dev/null | tr -d '\r')"
    if [[ "$want" == "$got" ]]; then
      echo "  [ok] $remote ($want bytes)"
    else
      echo "  [error] $remote 大小不一致: 本地 $want 远端 $got"
      FAILED=1
    fi
  done

  rm -rf "$tmp"
done

echo ""
echo "完成。请在手机 fcitx5-android 中重新部署后生效。"
exit $FAILED
