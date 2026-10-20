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

print("\n全部测试通过")
