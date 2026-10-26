-- test_context_reorder.lua
-- 用本机 lua5.4 单测 context_reorder 的 lookup 与重排逻辑（脱离 librime-lua 环境）
-- 运行: lua5.4 lua/test_context_reorder.lua

local M = dofile("lua/context_reorder.lua")

-- 模拟 rime 环境
local env = { engine = { schema = { config = {} } } }
function rime_api_mock() end
local rime_api = { get_user_data_dir = function() return "." end }
_G.rime_api = rime_api

-- 手动 init（绕过 commit_notifier，测试环境没有 engine）
local dir = "lua/"
local wf = io.open(dir .. "ctx_words.txt", "r")
local idxf = io.open(dir .. "ctx_words.idx", "r")
assert(wf and idxf, "数据文件不存在，先跑 build_ctx_words.py")
env.words = wf:read("*a")
wf:close()
env.idx = {}
for line in idxf:lines() do
    local first, lo, hi = line:match("^(%S+)\t(%d+)\t(%d+)$")
    if first then env.idx[first] = { tonumber(lo), tonumber(hi) } end
end
idxf:close()
env.enabled = true
env.tail = ""
env.max_k = 6
env.max_cands = 40

-- ==== 测试 lookup ====
local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("FAIL: %s: expected %s, got %s",
            msg, tostring(expected), tostring(actual)), 0)
    end
    print("PASS: " .. msg)
end

assert_eq(M.lookup(env, "我们") ~= nil, true, "lookup 我们 命中")
assert_eq(M.lookup(env, "中值") ~= nil, true, "lookup 中值 命中")
assert_eq(M.lookup(env, "拉格朗日") ~= nil, true, "lookup 拉格朗日 命中")
assert_eq(M.lookup(env, "拉格朗日中值") ~= nil, false, "lookup 拉格朗日中值 未命中(词库无此词)")
assert_eq(M.lookup(env, "微分中值定理") ~= nil, true, "lookup 微分中值定理 命中")
assert_eq(M.lookup(env, "中值定理") ~= nil, true, "lookup 中值定理 命中")
assert_eq(M.lookup(env, "中值滤波") ~= nil, true, "lookup 中值滤波 命中")
assert_eq(M.lookup(env, "zzzz不存在的词") ~= nil, false, "lookup 不存在词 未命中")

-- ==== 测试重排逻辑（模拟 func 内核） ====
-- 场景: 已上屏「拉格朗日」，候选打 vsvi (zhong zhi)
env.tail = "拉格朗日"
local cands = { "中值", "宗旨", "种植", "重置", "中式" }
local boosted = {}
for i, text in ipairs(cands) do
    for k = math.min(env.max_k, utf8.len(env.tail)), 1, -1 do
        local suffix = env.tail:sub(utf8.offset(env.tail, utf8.len(env.tail) - k + 1) or 1)
        local w = M.lookup(env, suffix .. text)
        if w then
            boosted[#boosted + 1] = { i = i, k = k, w = w }
            break
        end
    end
end
assert_eq(#boosted, 0, "拉格朗日+候选 无成词(词库无拉格朗日中值)，不重排")

-- 场景: 已上屏「微分中值」，候选 dingli
env.tail = "微分中值"
local cands2 = { "定理", "定量", "鼎力", "独立" }
local boosted2 = {}
for i, text in ipairs(cands2) do
    for k = math.min(env.max_k, utf8.len(env.tail)), 1, -1 do
        local suffix = env.tail:sub(utf8.offset(env.tail, utf8.len(env.tail) - k + 1) or 1)
        local w = M.lookup(env, suffix .. text)
        if w then
            boosted2[#boosted2 + 1] = { i = i, k = k, w = w }
            break
        end
    end
end
assert_eq(#boosted2, 1, "微分中值+定理 成词(微分中值定理)")
assert_eq(boosted2[1].k, 4, "成词上下文 k=4")
assert_eq(boosted2[1].i, 1, "定理 是第1个候选")

-- 场景: 已上屏「中值」，候选 lvbo
env.tail = "中值"
local cands3 = { "滤波", "旅博", "吕波" }
local boosted3 = {}
for i, text in ipairs(cands3) do
    for k = math.min(env.max_k, utf8.len(env.tail)), 1, -1 do
        local suffix = env.tail:sub(utf8.offset(env.tail, utf8.len(env.tail) - k + 1) or 1)
        local w = M.lookup(env, suffix .. text)
        if w then
            boosted3[#boosted3 + 1] = { i = i, k = k, w = w }
            break
        end
    end
end
assert_eq(#boosted3, 1, "中值+滤波 成词(中值滤波)")
assert_eq(boosted3[1].k, 2, "成词上下文 k=2")

-- 场景: 已上屏「科学」，候选 yuan → 单字「院」虽成词「科学院」
-- 但规则要求候选至少 2 字，单字不参与重排（交给 aux_code 处理）
env.tail = "科学"
local cands4 = { "院", "元", "原", "圆" }
local boosted4 = {}
for i, text in ipairs(cands4) do
    if #text >= 6 then -- 至少 2 个汉字（6 字节）
        for k = math.min(env.max_k, utf8.len(env.tail)), 1, -1 do
            local suffix = env.tail:sub(utf8.offset(env.tail, utf8.len(env.tail) - k + 1) or 1)
            local w = M.lookup(env, suffix .. text)
            if w then
                boosted4[#boosted4 + 1] = { i = i, k = k, w = w }
                break
            end
        end
    end
end
assert_eq(#boosted4, 0, "单字候选(院) 不参与重排")

-- ==== 测试 expected_char_len（辅助码剔除 + 双拼折算）====
-- 复制 filter 内的折算函数逻辑做独立验证
local function expected_char_len(input_code, trigger_key)
    local code = input_code
    local tk = trigger_key or "'"
    local tk_pat = tk:gsub("%W", "%%%1")
    local before = code:match("^([^" .. tk_pat .. "]*)")
    if before == nil then before = "" end
    code = before
    if #code % 2 == 1 then
        code = code:sub(1, #code - 1)
    end
    if #code == 0 then return 0 end
    return math.floor(#code / 2)
end

assert_eq(expected_char_len("vsvi", "'"), 2, "vsvi(4字母) 折算 2 字")
assert_eq(expected_char_len("vsvia", "'"), 2, "vsvia(5字母,末位辅码) 折算 2 字")
assert_eq(expected_char_len("vsvi'au", "'"), 2, "vsvi'au(引导符+辅码) 折算 2 字")
assert_eq(expected_char_len("vs", "'"), 1, "vs(2字母) 折算 1 字")
assert_eq(expected_char_len("vsa", "'"), 1, "vsa(3字母,末位辅码) 折算 1 字")
assert_eq(expected_char_len("'au", "'"), 0, "纯辅码 折算 0 字")
assert_eq(expected_char_len("m;", "'"), 1, "m;(万能键) 折算 1 字")

-- ==== 测试排序: 长度匹配优先于权重 ====
-- 场景: 已上屏「科学」，输入 vsvia(折算2字)，候选「院」(1字) vs「学院」(2字)
-- 「科学院」k=2 w=105725;「科学学院」不在词库 → 只有「院」命中成词
-- 构造双命中场景: 已上屏「中值」，输入 vsvi(2字)，候选「定理」(2字,中值定理 w=1050)
-- vs「滤波」(2字,中值滤波 w=262) → 长度都匹配，权重高的「定理」在前
env.tail = "中值"
local cands5 = { "滤波", "定理" }
local boosted5 = {}
local expect5 = 2
for i, text in ipairs(cands5) do
    for k = math.min(env.max_k, utf8.len(env.tail)), 1, -1 do
        local suffix = env.tail:sub(utf8.offset(env.tail, utf8.len(env.tail) - k + 1) or 1)
        local w = M.lookup(env, suffix .. text)
        if w then
            local lm = (utf8.len(text) == expect5) and 1 or 0
            boosted5[#boosted5 + 1] = { i = i, k = k, lm = lm, w = w }
            break
        end
    end
end
table.sort(boosted5, function(a, b)
    if a.k ~= b.k then return a.k > b.k end
    if a.lm ~= b.lm then return a.lm > b.lm end
    if a.w ~= b.w then return a.w > b.w end
    return a.i < b.i
end)
assert_eq(boosted5[1].i, 2, "中值+定理(权重1050) 排在 滤波(262) 前")

-- ==== 测试排序: 长度匹配是第一优先级 ====
-- 场景: 已上屏「理论上」，打 jkuj(折算2字)
-- 「京」: 单字，被至少 2 字规则排除，不参与重排
-- 「经常」「经济」: 长度匹配(2字)，参与重排
env.tail = "理论上"
local cands6 = { "京", "经常", "经济" }
local boosted6 = {}
local expect6 = 2
for i, text in ipairs(cands6) do
    if #text >= 6 then -- 至少 2 个汉字（6 字节）
        local lm = (utf8.len(text) == expect6) and 1 or 0
        local k, w = 0, 0
        for kk = math.min(env.max_k, utf8.len(env.tail)), 1, -1 do
            local suffix = env.tail:sub(utf8.offset(env.tail, utf8.len(env.tail) - kk + 1) or 1)
            local ww = M.lookup(env, suffix .. text)
            if ww then k, w = kk, ww; break end
        end
        if lm == 1 or k > 0 then
            boosted6[#boosted6 + 1] = { i = i, lm = lm, k = k, w = w }
        end
    end
end
table.sort(boosted6, function(a, b)
    if a.lm ~= b.lm then return a.lm > b.lm end
    if a.k ~= b.k then return a.k > b.k end
    if a.w ~= b.w then return a.w > b.w end
    return a.i < b.i
end)
assert_eq(#boosted6, 2, "理论上场景 2 个候选参与重排(单字京被排除)")
assert_eq(boosted6[1].i, 2, "经常(长度匹配) 排第1")
assert_eq(boosted6[2].i, 3, "经济(长度匹配) 排第2")

local user_entries = {
    {text = "躲躲", commit_count = 6, weight = -2},
    {text = "躲躲", commit_count = 1, weight = -8},
    {text = "多多", commit_count = 1, weight = -5},
    {text = "删除词", commit_count = -1, weight = 10},
}
local read_count, disconnect_count, query_count, convert_count = 0, 0, 0, 0
local fail_user_read = false
local converter_count = 0
function env.engine.schema.config:get_string(path)
    assert_eq(path, "simplifier/opencc_config", "使用简化过滤器的转换配置")
    return nil
end
_G.Opencc = function(config_name)
    assert_eq(config_name, "t2s.json", "默认使用 Rime 繁转简配置")
    converter_count = converter_count + 1
    return {convert = function(_, text)
        convert_count = convert_count + 1
        return (text:gsub("還", "还"))
    end}
end
local text_codes = {
    ["躲躲"] = "duo duo", ["多多"] = "duo duo", ["朵朵"] = "duo duo",
    ["還是"] = "hai shi", ["还是"] = "hai shi", ["海事"] = "hai shi",
    ["今天"] = "jin tian", ["今天躲躲"] = "jin tian duo duo",
    ["今天多多"] = "jin tian duo duo", ["今天還是"] = "jin tian hai shi",
    ["今天海事"] = "jin tian hai shi",
}
local function mock_candidate(text)
    return {text = text, get_genuines = function()
        return {{to_phrase = function()
            return {entry = {custom_code = text_codes[text] or "unknown"}}
        end}}
    end}
end
_G.Memory = function(engine, schema, namespace)
    assert_eq(namespace, "translator", "使用当前 translator 的用户词库")
    read_count = read_count + 1
    local alive = true
    return {
        decode = function(_, code)
            assert(alive, "禁止 Memory 释放后解码")
            return code.syllables
        end,
        user_dict = {
            loaded = not fail_user_read,
            lookup_words = function(_, code, predictive, limit)
                assert(alive, "禁止 Memory 释放后访问词典")
                assert(code ~= "", "禁止空编码全库扫描")
                assert(code:sub(-2) == " \t", "必须精确到完整编码和词文本分隔符")
                assert(predictive and limit == 128, "同编码记录查询必须有上限")
                query_count = query_count + 1
                local matching = {}
                for _, entry in ipairs(user_entries) do
                    if (text_codes[entry.text] or "unknown") .. " \t" == code then
                        matching[#matching + 1] = entry
                    end
                end
                return {iter = function()
                    local position = 0
                    return function()
                        assert(alive, "禁止 Memory 释放后遍历词典")
                        position = position + 1
                        return matching[position]
                    end
                end}
            end,
        },
        disconnect = function()
            alive = false
            disconnect_count = disconnect_count + 1
        end,
    }
end
local function reorder(texts)
    local position, output = 0, {}
    local previous_yield = _G.yield
    _G.yield = function(candidate) output[#output + 1] = candidate.text end
    M.func({iter = function() return function()
        position = position + 1
        if texts[position] then return mock_candidate(texts[position]) end
    end end}, env)
    _G.yield = previous_yield
    return table.concat(output, ",")
end
env.engine.context = {input = "dodo"}
env.tail = "今天"
env.tail_codes = {"jin", "tian"}
env.user_dirty = true
assert_eq(reorder({"多多", "躲躲"}), "躲躲,多多", "今天后按候选学习权重提升躲躲")
assert_eq(env.user_words["躲躲"], -2, "同文本多编码取最高动态权重")
assert_eq(env.user_words["删除词"], nil, "删除记录不参与学习权重")
assert_eq(disconnect_count, 1, "完成本轮查询后才释放 Memory")
local previous_queries, previous_conversions = query_count, convert_count
local previous_memo = env.memo
reorder({"多多", "躲躲"})
assert_eq(read_count, 1, "输入期间复用学习权重快照")
assert_eq(query_count, previous_queries, "同音候选和重复输入不重复查询")
assert_eq(convert_count, previous_conversions, "缓存命中时不重复转换")
assert_eq(env.memo, previous_memo, "权重不变时复用上下文查词缓存")
assert_eq(query_count, 3, "只查询候选编码及两个上文后缀编码")
user_entries[3].weight = -1
env.user_dirty = true
assert_eq(reorder({"躲躲", "多多"}), "多多,躲躲", "学习后刷新动态权重")
user_entries = {
    {text = "今天躲躲", commit_count = 2, weight = -3},
    {text = "今天多多", commit_count = 1, weight = -6},
}
env.user_dirty = true
assert_eq(reorder({"多多", "躲躲"}), "躲躲,多多", "跨界用户词按真实学习权重排序")
env.max_cands = 1
assert_eq(reorder({"多多", "躲躲", "朵朵"}), "多多,躲躲,朵朵", "重排窗口外候选完整保留")
env.max_cands = 100
fail_user_read = true
env.user_dirty = true
assert_eq(reorder({"多多", "躲躲"}), "多多,躲躲", "用户库不可用时保持原有排序")
assert_eq(env.user_error ~= nil, true, "用户库不可用时保留错误原因")
fail_user_read = false
user_entries = {
    {text = "還是", commit_count = 16, weight = -2},
    {text = "海事", commit_count = 1, weight = -8},
    {text = "还是", commit_count = 1, weight = -6},
}
env.engine.context.input = "hlui"
env.user_dirty = true
assert_eq(reorder({"海事", "还是"}), "还是,海事", "繁体還是学习权重用于简体还是候选")
assert_eq(env.user_words["還是"], -2, "保留繁体原文权重")
assert_eq(env.user_words["还是"], -2, "繁简权重键冲突时保留最高权重")
assert_eq(reorder({"海事", "還是"}), "還是,海事", "繁体候选仍能使用学习权重")
user_entries = {
    {text = "今天還是", commit_count = 16, weight = -2},
    {text = "今天海事", commit_count = 1, weight = -8},
}
env.user_dirty = true
assert_eq(reorder({"海事", "还是"}), "还是,海事", "跨界成词同样匹配繁体用户记录")
user_entries = {{text = "還是", commit_count = -16, weight = -2}}
env.user_dirty = true
reorder({"海事", "还是"})
assert_eq(env.user_words["还是"], nil, "刷新后移除已删除词的简体权重键")
assert_eq(converter_count, 1, "刷新权重时复用 OpenCC 转换器")
user_entries = {{text = "還是", commit_count = 16, weight = -2}}
env.user_dirty = true
local before_refresh_conversions = convert_count
reorder({"海事", "还是"})
assert_eq(convert_count, before_refresh_conversions, "学习失效不清除繁简转换缓存")
local commit_context = {
    get_commit_text = function() return "今天" end,
    composition = {get_segments = function() return {
        {get_selected_candidate = function() return mock_candidate("今天") end},
    } end},
}
M.record_commit(env, commit_context)
assert_eq(env.tail_codes[#env.tail_codes], "tian", "上屏记录真实末字编码")
assert_eq(env.user_dirty, true, "上屏使权重查询缓存失效")
env.user_dirty = true
env.tail_codes = {}
local before_no_context = query_count
reorder({"海事", "还是"})
assert_eq(query_count - before_no_context, 1, "上文无编码时只查询候选，不退回全库扫描")
local before_no_code = query_count
M.refresh_user_weights(env, {{text = "无编码"}})
assert_eq(query_count, before_no_code, "无原始候选编码时不查询用户库")
env.user_dirty = true
local decoded_candidate = {text = "还是", get_genuines = function() return {
    {to_phrase = function() return {entry = {custom_code = ""}, code = {
        syllables = {"hai", "shi"}, print = function() return "123 456" end,
    }} end},
} end}
M.refresh_user_weights(env, {decoded_candidate})
assert_eq(env.user_words["还是"], -2, "从候选数字编码解码后精确查询学习权重")
assert_eq(env.user_dictionary, nil, "查询后不保留非持有型词典句柄")
local before_cached_decode = read_count
M.refresh_user_weights(env, {decoded_candidate})
assert_eq(read_count, before_cached_decode, "编码和权重均命中缓存时不创建 Memory")
M.fini(env)
assert_eq(env.user_memory, nil, "结束时释放查询句柄")
_G.Memory = nil
_G.Opencc = nil

print("\n全部测试通过")
