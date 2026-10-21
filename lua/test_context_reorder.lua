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

print("\n全部测试通过")
