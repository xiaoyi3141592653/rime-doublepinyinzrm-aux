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

-- 计算输入串折算的汉字长度（双拼 2 字母/字），并剔除辅助码部分。
-- 规则（与 aux_code.lua 对齐）：
--   1. 含引导符（默认 '）: 引导符之前是双拼码，之后是辅助码 → 长度只算引导符前
--   2. 无引导符且字母数为奇数: 末位字母是辅助码 → 剔除末位再折算
--   3. 万能键 ; 等同普通字母参与折算（m; ≡ mm，2 字母 1 字）
-- 返回: 期望汉字长度（0 表示无法折算，如纯辅助码）
local function expected_char_len(input_code, trigger_key)
    local code = input_code
    -- 剔除引导符及之后的辅助码
    local tk = trigger_key or "'"
    local tk_pat = tk:gsub("%W", "%%%1")
    local before = code:match("^([^" .. tk_pat .. "]*)")
    if before == nil then before = "" end
    code = before
    -- 奇数个字母: 末位是辅助码，剔除
    if #code % 2 == 1 then
        code = code:sub(1, #code - 1)
    end
    if #code == 0 then return 0 end
    return math.floor(#code / 2)
end

function M.init(env)
    env.tail = ""
    env.enabled = false

    local config = env.engine.schema.config
    env.max_k = config:get_int("context_reorder/max_context") or MAX_K
    env.max_cands = config:get_int("context_reorder/max_candidates") or MAX_CANDS
    -- 辅助码引导符，与 aux_code.lua 共用 key_binder/aux_code_trigger
    env.trigger_key = config:get_string("key_binder/aux_code_trigger") or "'"

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
    -- 输入折算的期望汉字长度（剔除辅助码后 2 字母/字）
    local expect_len = expected_char_len(env.engine.context.input, env.trigger_key)
    local boosted = {} -- {i, len_match, k, weight}
    for i, cand in ipairs(cands) do
        local text = cand.text
        if #text >= 3 then -- 至少 1 个汉字（3 字节）
            local len_match = (expect_len > 0 and utf8.len(text) == expect_len) and 1 or 0
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
            -- 长度匹配 或 成词，二者其一即参与重排
            if len_match == 1 or hit then
                local k, w = 0, 0
                if hit then k, w = hit[1], hit[2] end
                boosted[#boosted + 1] = { i = i, lm = len_match, k = k, w = w }
            end
        end
    end
    env.memo = memo

    if #boosted == 0 then
        for _, cand in ipairs(cands) do yield(cand) end
        return
    end

    -- 排序: 长度匹配优先 → 跨界成词 k 大优先 → 权重高优先 → 原顺序
    -- （长度是强信号: 打 4 字母意图就是 2 字词，不应被 k=1 的弱成词单字压过）
    table.sort(boosted, function(a, b)
        if a.lm ~= b.lm then return a.lm > b.lm end
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
