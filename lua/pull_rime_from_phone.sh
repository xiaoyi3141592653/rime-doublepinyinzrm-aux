#!/bin/bash
# pull_rime_from_phone.sh — 从手机拉取 rime 配置备份到仓库 phone/ 目录
#
# 用法:
#   ./pull_rime_from_phone.sh                    # 从第一个已连接设备拉取
#   ./pull_rime_from_phone.sh <serial>           # 指定设备
#   RIME_PHONE_DIR=/path ./pull_rime_from_phone.sh  # 自定义手机端 rime 目录
#
# 拉取规则（与 push_rime_to_phone.sh 对称）:
#   1. 两端共用的文件 → 不拉取（以仓库为基准）
#   2. 手机端特有/差异文件 → phone/<name>.phone
#      - lua/ 下的 → phone/lua_<name>.phone
#   3. 不拉取: build/、*.userdb/、*.userdb.txt、installation.yaml、user.yaml、
#              gram 模型（体积大，手机端不会修改）、trash/
#   4. 拉取后校验 md5，与远端一致才算成功
#
# 拉取清单 = push_rime_to_phone.sh 中 phone/*.phone 的文件集合。
# 新增手机端文件时，先手动拉一次到 phone/，之后 push 脚本会自动带上。

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RIME_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PHONE_RIME="${RIME_PHONE_DIR:-/sdcard/Android/data/org.fcitx.fcitx5.android.fx/files/data/rime}"
PHONE_DIR="$RIME_ROOT/phone"

fail() { echo "[error] $*" >&2; exit 1; }

command -v adb >/dev/null 2>&1 || fail "找不到 adb，请先安装 Android platform-tools"

# ---- 设备选择（拉取只需一台）----
if [[ $# -gt 0 ]]; then
  SERIAL="$1"
else
  SERIAL="$(adb devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
fi
[[ -n "$SERIAL" ]] || fail "没有已连接的 adb 设备（adb devices 查看）"
echo "=== 从设备 $SERIAL 拉取 ==="

mkdir -p "$PHONE_DIR"

# 手机端特有/差异文件清单（相对 rime 目录；lua/ 前缀的存为 phone/lua_*.phone）
PULL_FILES=(
  # schema 与配置（手机端差异版）
  default.custom.yaml
  double_pinyin.custom.yaml
  double_pinyin.schema.yaml
  double_pinyin_exact.custom.yaml
  double_pinyin_exact.schema.yaml
  # 手机端预置（Mac 从 SharedSupport 取，手机需自带）
  default.yaml
  bopomofo.schema.yaml
  bopomofo_express.schema.yaml
  bopomofo_tw.schema.yaml
  cangjie5.dict.yaml
  cangjie5.schema.yaml
  cangjie5_express.schema.yaml
  luna_pinyin.dict.yaml
  luna_pinyin.schema.yaml
  luna_pinyin_fluency.schema.yaml
  luna_pinyin_simp.schema.yaml
  luna_pinyin_tw.schema.yaml
  luna_quanpin.schema.yaml
  stroke.dict.yaml
  terra_pinyin.dict.yaml
  terra_pinyin.schema.yaml
  essay.txt
  grammar.yaml
  key_bindings.yaml
  pinyin.yaml
  punctuation.yaml
  squirrel.yaml
  symbols.yaml
  zhuyin.yaml
  double_pinyin.schema-xiaoyili-PC7.yaml
  # lua 目录（手机端特有/差异）
  lua/aux_code.lua
  lua/adjacent_corrector.lua
  lua/aux_code_data.lua
  lua/hanzi_shuangpin.txt
  lua/hanzi_shuangpin_data.lua
)

ok=0
fail_cnt=0
for rel in "${PULL_FILES[@]}"; do
  if [[ "$rel" == lua/* ]]; then
    # lua/XXX → phone/lua_XXX.phone
    base="${rel#lua/}"
    dest="$PHONE_DIR/lua_${base}.phone"
  else
    dest="$PHONE_DIR/${rel}.phone"
  fi

  if adb -s "$SERIAL" pull "$PHONE_RIME/$rel" "$dest" >/dev/null 2>&1; then
    # md5 校验
    remote_md5="$(adb -s "$SERIAL" shell md5sum "$PHONE_RIME/$rel" 2>/dev/null | awk '{print $1}')"
    local_md5="$(md5 -q "$dest")"
    if [[ "$remote_md5" == "$local_md5" ]]; then
      echo "  [ok] $rel → $(basename "$dest")"
      ok=$((ok + 1))
    else
      echo "  [error] $rel md5 不一致: 远端 $remote_md5 本地 $local_md5"
      fail_cnt=$((fail_cnt + 1))
    fi
  else
    echo "  [skip] $rel 手机端不存在"
  fi
done

echo ""
echo "完成: 成功 $ok 个, 失败 $fail_cnt 个, 跳过的不计入。"
echo "仓库 phone/ 目录已更新。提交前请 git diff 检查变更。"
exit "$fail_cnt"
