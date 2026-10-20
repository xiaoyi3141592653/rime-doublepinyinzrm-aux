-- context_reorder.lua
-- 上下文重排 filter：候选若能与本 session 已上屏文字的末尾组成词库中的词，则置前。
-- 排序依据：跨界成词的上下文长度 k 优先，其次词库权重，最后保持原顺序。
-- 数据文件由 build_ctx_words.py 预编译生成（词库变更后重跑该脚本）。

local M = {}

local WORDS_FILE = "ctx_words.txt" -- 每行 "词\t权重"，UTF-8 字节序排序
local IDX_FILE = "ctx_words.idx"  -- 每行 "首字\tlo\thi"，[lo,hi) 为字节范围（1-based）

local TAIL_CHARS = 32 -- 追踪已上屏文字的末尾字数上限
local MAX_K = 6       -- 跨界成词时最多回看已上屏文字的字数
local MAX_CANDS = 40  -- 每次最多处理这么多候选，防止极端长句拖慢

-- 取字符串末尾 n 个 UTF-8 字符
local function tail_chars(s, n)
    if n <= 0 then return "" end
    local total = utf8.len(s)
    if not total or total <= n then return s end
    local offset = utf8.offset(s, total - n + 1)
    return s:sub(offset)
end

-- 取字符串开头 n 个 UTF-8 字符
local function head_chars(s, n)
    local total = utf8.len(s)
    if not total or total <= n then return s end
    local offset = utf8.offset(s, n + 1)
    return offset and s:sub(1, offset - 1) or s
end

function M.init(env)
    env.tail = ""
    env.enabled = false

    local config = env.engine.schema.config
    env.max_k = config:get_int("context_reorder/max_context") or MAX_K
    env.max_cands = config:get_int("context_reorder/max_candidates") or MAX_CANDS

    local dir = rime_api.get_user_data_dir() .. "/lua/"
    local wf = io.open(dir .. WORDS_FILE, "r")
    local idxf = io.open(dir .. IDX_FILE, "r")
    if not wf or not idxf then
        return -- 数据文件不存在，静默禁用
    end
    env.words = wf:read("*a") or ""
    wf:close()
    if env.words == "" then return end

    -- 解析首字索引: first -> {lo, hi}
    env.idx = {}
    for line in idxf:lines() do
        local first, lo, hi = line:match("^(%S+)\t(%d+)\t(%d+)$")
        if first then
            env.idx[first] = { tonumber(lo), tonumber(hi) }
        end
    end
    idxf:close()

    -- 自检：连「我们」都查不到说明数据文件异常，禁用
    if M.lookup(env, "我们") == nil then
        env.idx = nil
        env.words = nil
        return
    end
    env.enabled = true

    env.notifier = env.engine.context.commit_notifier:connect(function(ctx)
        local text = ctx:get_commit_text()
        if text and text ~= "" then
            env.tail = (env.tail .. text):sub(-TAIL_CHARS * 4) -- 4 字节/字上限截断
            env.tail = tail_chars(env.tail, TAIL_CHARS)
            env.memo = nil -- 上屏后清空查询缓存
        end
    end)
end

-- 在词表中查词，返回权重或 nil
function M.lookup(env, word)
    local first = head_chars(word, 1)
    local range = env.idx[first]
    if not range then return nil end
    local lo, hi = range[1], range[2]
    local words = env.words
    local target = word .. "\t"
    local n = #target
    -- 字节序二分：[lo, hi) 内找以 target 开头的行
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        -- 回退到行首
        local line_start = mid
        while line_start > 1 and words:byte(line_start - 1) ~= 10 do
            line_start = line_start - 1
        end
        local line_end = words:find("\n", line_start, true)
        if not line_end then line_end = #words + 1 end
        local line = words:sub(line_start, line_end - 1)
        if line < target then
            lo = line_end + 1
        elseif line:sub(1, n) == target then
            return tonumber(line:sub(n + 1)) or 0
        else
            hi = line_start - 1
        end
    end
    return nil
end

function M.func(input, env)
    if not env.enabled or env.tail == "" then
        for cand in input:iter() do yield(cand) end
        return
    end

    local cands = {}
    for cand in input:iter() do
        cands[#cands + 1] = cand
        if #cands >= env.max_cands then break end
    end

    local tail = env.tail
    local memo = env.memo or {}
    local boosted = {} -- {i, k, weight}
    for i, cand in ipairs(cands) do
        local text = cand.text
        if #text >= 6 then -- 至少 2 字
            local key = tail .. "\1" .. text
            local hit = memo[key]
            if hit == nil then
                local best_k, best_w = 0, nil
                for k = math.min(env.max_k, utf8.len(tail)), 1, -1 do
                    local w = M.lookup(env, tail_chars(tail, k) .. text)
                    if w then
                        best_k, best_w = k, w
                        break -- k 大者优先，找到即停
                    end
                end
                hit = best_w and { best_k, best_w } or false
                memo[key] = hit
            end
            if hit then
                boosted[#boosted + 1] = { i = i, k = hit[1], w = hit[2] }
            end
        end
    end
    env.memo = memo

    if #boosted == 0 then
        for _, cand in ipairs(cands) do yield(cand) end
        return
    end

    table.sort(boosted, function(a, b)
        if a.k ~= b.k then return a.k > b.k end
        if a.w ~= b.w then return a.w > b.w end
        return a.i < b.i
    end)

    local boosted_set = {}
    for _, b in ipairs(boosted) do boosted_set[b.i] = true end
    for _, b in ipairs(boosted) do yield(cands[b.i]) end
    for i, cand in ipairs(cands) do
        if not boosted_set[i] then yield(cand) end
    end
end

function M.fini(env)
    if env.notifier then env.notifier:disconnect() end
end

return M
