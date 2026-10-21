#!/bin/bash
# push_rime_to_phone.sh — 推送仓库中的 rime 配置到手机 fcitx5-android
#
# 用法:
#   ./push_rime_to_phone.sh                    # 推送到所有已连接设备
#   ./push_rime_to_phone.sh <serial>...        # 只推送到指定设备
#   RIME_PHONE_DIR=/path ./push_rime_to_phone.sh  # 自定义手机端 rime 目录
#
# 推送规则:
#   1. 仓库根目录的 rime 配置 → 手机 rime 目录（两端共用的文件）
#   2. phone/*.phone 文件 → 手机 rime 目录（去掉 .phone 后缀；手机端特有版本）
#      - phone/lua_XXX.phone → 手机 rime/lua/XXX（lua_ 前缀表示 lua 子目录）
#   3. 不推送: build/、*.userdb/、*.userdb.txt、installation.yaml、user.yaml、
#              .phone_* 临时文件、gram 模型（体积大且手机已有）
#
# 注意: double_pinyin.custom.yaml 和 double_pinyin.schema.yaml 两端有差异，
#       手机端版本在 phone/ 下（.phone 后缀），推送时优先生效。

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RIME_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PHONE_RIME="${RIME_PHONE_DIR:-/sdcard/Android/data/org.fcitx.fcitx5.android.fx/files/data/rime}"

# 两端共用的文件（从仓库根目录推送）
SHARED_FILES=(
  base.dict.yaml
  ext.dict.yaml
  tencent.dict.yaml
  sougou_202409121330.dict.yaml
  double_pinyin_plus.dict.yaml
  double_pinyin_plus.xiaoyi.dict.yaml
  double_pinyin_plus.shenzhen.dict.yaml
  double_pinyin_plus.food.dict.yaml
  double_pinyin_plus.program.dict.yaml
  double_pinyin_plus.computer.dict.yaml
  double_pinyin_plus.life.dict.yaml
  double_pinyin_plus.life_chat.dict.yaml
  double_pinyin_abc.schema.yaml
  double_pinyin_flypy.schema.yaml
  double_pinyin_mspy.schema.yaml
  double_pinyin_pyjj.schema.yaml
  readme.md
)

# lua 目录下两端共用的文件
# 注意: aux_code.lua 两端功能不同（手机端有14键模糊/!精确模式/预编译数据），
#       手机端版本在 phone/lua_aux_code.lua.phone，不在此清单中
SHARED_LUA=(
  context_reorder.lua
  ctx_words.txt
  ctx_words.idx
  ZRM_Aux-code_4.3.txt
  log.lua
)

# cn_dicts 目录（两端共用）
CN_DICTS=(
  41448.dict.yaml
  8105.dict.yaml
  base.dict.yaml
  ext.dict.yaml
  others.dict.yaml
  tencent.dict.yaml
)

fail() { echo "[error] $*" >&2; exit 1; }

command -v adb >/dev/null 2>&1 || fail "找不到 adb，请先安装 Android platform-tools"

# ---- 设备列表 ----
if [[ $# -gt 0 ]]; then
  DEVICES=("$@")
else
  DEVICES=()
  while IFS= read -r s; do DEVICES+=("$s"); done < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')
fi
[[ ${#DEVICES[@]} -gt 0 ]] || fail "没有已连接的 adb 设备（adb devices 查看）"

push_one() { # push_one <serial> <local> <remote>
  local serial="$1" local_f="$2" remote_f="$3"
  adb -s "$serial" push "$local_f" "$PHONE_RIME/$remote_f" >/dev/null 2>&1
}

FAILED=0
for serial in "${DEVICES[@]}"; do
  echo "=== 设备 $serial ==="
  ok=0; fail_cnt=0

  # 1. phone/*.phone → 手机端（去掉后缀还原路径）
  for f in "$RIME_ROOT"/phone/*.phone; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f" .phone)"
    if [[ "$base" == lua_* ]]; then
      # lua_XXX → lua/XXX
      target="lua/${base#lua_}"
    else
      target="$base"
    fi
    if push_one "$serial" "$f" "$target"; then
      ((ok++)) || true
    else
      echo "  [error] push 失败: $base"
      ((fail_cnt++)) || true
    fi
  done

  # 2. 仓库根目录共用文件
  for f in "${SHARED_FILES[@]}"; do
    [[ -f "$RIME_ROOT/$f" ]] || continue
    if push_one "$serial" "$RIME_ROOT/$f" "$f"; then
      ((ok++)) || true
    else
      echo "  [error] push 失败: $f"
      ((fail_cnt++)) || true
    fi
  done

  # 3. lua 共用文件
  for f in "${SHARED_LUA[@]}"; do
    [[ -f "$RIME_ROOT/lua/$f" ]] || continue
    if push_one "$serial" "$RIME_ROOT/lua/$f" "lua/$f"; then
      ((ok++)) || true
    else
      echo "  [error] push 失败: lua/$f"
      ((fail_cnt++)) || true
    fi
  done

  # 4. cn_dicts
  for f in "${CN_DICTS[@]}"; do
    [[ -f "$RIME_ROOT/cn_dicts/$f" ]] || continue
    if push_one "$serial" "$RIME_ROOT/cn_dicts/$f" "cn_dicts/$f"; then
      ((ok++)) || true
    else
      echo "  [error] push 失败: cn_dicts/$f"
      ((fail_cnt++)) || true
    fi
  done

  echo "  [ok] 推送 $ok 个文件，失败 $fail_cnt 个"
  [[ $fail_cnt -gt 0 ]] && FAILED=1
done

echo ""
echo "完成。请在手机 fcitx5-android 中重新部署后生效。"
exit $FAILED
