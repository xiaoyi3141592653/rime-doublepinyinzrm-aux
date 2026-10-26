# Rime 双拼 + 自然码辅助码 配置

基于 [HowcanoeWang/rime-lua-aux-code](https://github.com/HowcanoeWang/rime-lua-aux-code) 改造，长期演进的个人 Rime 配置。
Mac 端用 Squirrel，手机端用 fcitx5-android（rime 插件），本仓库是两端共用的基准。

## 核心特性

### 1. 自然码双拼 + 辅助码（`lua/aux_code.lua`）

- **双拼方案**：自然码（`double_pinyin.schema.yaml`）
- **辅助码**：自然码形码（`lua/ZRM_Aux-code_4.3.txt`），单字候选显示辅助码注释
- **无引导符单辅码**：输入字母数为**奇数**时，末位字母自动当辅助码——单辅码场景不用按引导符
  - 例：`fzy` = `fz`（飞）+ `y`（辅助码），直接筛「飞」
- **引导符辅码**：`'` 后跟 1-2 个字母为辅助码（`key_binder/aux_code_trigger` 可改）
  - 例：`vsvi'au` = 「中值」+ 辅码 `au`
- **万能键**：`;` 等价于重复前一个字母（`m;` ≡ `mm`）
- **反转辅助码**：`ab` 与 `ba` 互为合法辅助码
- **期望词长**：按未上屏部分计算（`active_input_len`），选词后续输时超长候选（补全）直接丢弃——辅助码即精确输入

### 2. 上下文重排（`lua/context_reorder.lua`）

候选若能与**本 session 已上屏文字的末尾**组成词库中的词，则置前。

- **数据**：`build_ctx_words.py` 预编译全词库为 `ctx_words.txt`（221 万词，35MB，字节序排序）+ `ctx_words.idx`（首字索引），运行时二分查找
- **排序规则**：长度匹配（输入折算字数）→ 跨界成词的上下文长度 k → 拼接词的用户学习权重 → 静态词库权重 → 候选自身的用户学习权重 → 原顺序；学习权重与静态权重分开比较，不直接相加
- **userdb 联动**：仅按分析窗口内候选的原始拼音编码查询当前 `translator` 用户词库，同编码结果最多读取 128 条；上文有可靠编码时，也精确查询上文后缀与候选的拼接编码。保留原文及 OpenCC 转换后的权重键，同文本在本轮相关编码中取最高权重。无法取得编码时不扫描全库，仍保留静态重排
- **性能**：静态词表在 init 时加载；同编码查询复用缓存（最多 256 组），繁简转换复用独立缓存（最多 4096 词）。上屏或删词使权重查询缓存失效，但保留转换缓存；输入路径不再全库遍历。真实移动端耗时仍需复测
- **参数**：`context_reorder/max_context`（回看字数，默认 6）、`context_reorder/max_candidates`（分析窗口，默认 100）

### 3. octagram 语言模型

- Mac（Squirrel 自带）与手机端均已启用，`grammar/language: zh-hant-t-essay-bgw`（10MB 词级模型）
- 整句输入时按语言模型概率断句，词库里没有的搭配（如「拉格朗日中值定理」）也能整句出

## 词库

- **主词库**：`double_pinyin_plus.dict.yaml`，import 链合并以下来源
- **雾凇拼音**（[rime-ice](https://github.com/iDvel/rime-ice)）`cn_dicts/`：8105 字表、base/ext/tencent 词库——**上游持续维护，可定期同步**
- **个人词库**：`double_pinyin_plus.{xiaoyi,shenzhen,food,program,computer,life,life_chat}.dict.yaml`
- **历史词库**：`sougou_202409121330.dict.yaml`、根目录 `base/ext/tencent.dict.yaml`（旧版，与 cn_dicts 重复，待清理）

## 多端同步

两端配置有差异（手机端 14 键键盘有同键模糊匹配、`!` 精确模式、预编译辅助码数据），用 `phone/` 目录隔离：

```
├── *.yaml, lua/          # 两端共用（Mac 版为基准）
├── phone/                # 手机端特有/差异版本，加 .phone 后缀
│   ├── double_pinyin.schema.yaml.phone   # 手机版 schema（14键纠错）
│   ├── lua_aux_code.lua.phone            # 手机版 aux_code（功能超集）
│   └── ...
```

### 同步脚本（都在 `lua/` 下）

```bash
./lua/push_rime_to_phone.sh     # 仓库 → 手机（全量部署）
./lua/pull_rime_from_phone.sh   # 手机 → 仓库 phone/（备份手机端差异文件）
python3 lua/build_ctx_words.py  # 重建 context_reorder 词表数据
lua5.4 lua/test_context_reorder.lua  # context_reorder 单测
```

**注意**：`aux_code.lua` 两端功能不同，手机端版本只从 `phone/lua_aux_code.lua.phone` 推送。
Mac 端的修改要同步到手机时，需手动移植进 phone 副本（参考 `active_input_len` 的移植方式）。

## 日常维护

- **词库更新**：同步 rime-ice 上游 `cn_dicts/` → `python3 lua/build_ctx_words.py` → 重新部署
- **改 lua 后**：Mac 直接部署 Squirrel；手机跑 `push_rime_to_phone.sh` 后在 fcitx5-android 里重新部署
- **调试**：`aux_code.lua` 里的 `MyLog` 打开注释可写日志到 `~/aux_code.log`

## 部署

- **Mac**：Squirrel 菜单「重新部署」
- **手机**：fcitx5-android 通知栏 → 重新部署（需已装 rime 插件 `org.fcitx.fcitx5.android.plugin.rime`）
