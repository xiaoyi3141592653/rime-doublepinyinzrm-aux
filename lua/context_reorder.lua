-- context_reorder.lua
-- 上下文重排 filter：候选若能与本 session 已上屏文字的末尾组成词库中的词，则置前。
-- 排序依据：长度、上下文长度、上下文学习权重、静态权重、候选学习权重、原顺序。
-- 数据文件由 build_ctx_words.py 预编译生成（词库变更后重跑该脚本）。

local M = {}

local WORDS_FILE = "ctx_words.txt" -- 每行 "词\t权重"，UTF-8 字节序排序
local IDX_FILE = "ctx_words.idx"  -- 每行 "首字\tlo\thi"，[lo,hi) 为字节范围（1-based）

local TAIL_CHARS = 32 -- 追踪已上屏文字的末尾字数上限
local MAX_K = 6       -- 跨界成词时最多回看已上屏文字的字数
local MAX_CANDS = 100 -- 重排分析窗口：只分析前 N 个候选，窗口外原序放行（不丢弃）
local MAX_USER_RECORDS = 128
local MAX_QUERY_CACHE = 256
local MAX_CONVERT_CACHE = 4096

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

local function user_memory(env)
    if not env.user_memory then
        env.user_memory = Memory(env.engine, env.engine.schema, "translator")
        assert(env.user_memory.user_dict and env.user_memory.user_dict.loaded,
            "user dictionary unavailable")
        env.user_dictionary = env.user_memory.user_dict
        env.user_decoder = env.user_memory.dict
    end
    return env.user_dictionary
end

local function release_user_memory(env)
    env.user_dictionary, env.user_decoder = nil, nil
    if env.user_memory then env.user_memory:disconnect() end
    env.user_memory = nil
end

local function candidate_codes(env, candidate)
    local codes, seen = {}, {}
    if not candidate.get_genuines then return codes end
    for _, genuine in ipairs(candidate:get_genuines()) do
        local phrase = genuine:to_phrase()
        if phrase then
            local code = phrase.entry.custom_code
            if not code or code == "" then
                env.code_cache = env.code_cache or {}
                local numeric_code = phrase.code
                local cache_key = numeric_code:print()
                code = env.code_cache[cache_key]
                if not code then
                    user_memory(env)
                    code = table.concat(env.user_memory:decode(numeric_code), " ")
                    if (env.code_count or 0) >= MAX_QUERY_CACHE then
                        env.code_cache, env.code_count = {}, 0
                    end
                    env.code_cache[cache_key] = code
                    env.code_count = (env.code_count or 0) + 1
                end
            end
            code = code:gsub("%s+$", "")
            if code ~= "" and not seen[code] then
                seen[code] = true
                codes[#codes + 1] = code
            end
        end
    end
    return codes
end

local function converted_word(env, text)
    env.convert_cache = env.convert_cache or {}
    if env.convert_cache[text] then return env.convert_cache[text] end
    if not env.user_converter then
        local opencc = rawget(_G, "Opencc")
        if not opencc then return text end
        env.user_converter = assert(opencc(env.engine.schema.config:get_string("simplifier/opencc_config")
            or "t2s.json"), "user weight OpenCC converter unavailable")
    end
    local converted = env.user_converter:convert(text)
    if (env.convert_count or 0) >= MAX_CONVERT_CACHE then
        env.convert_cache, env.convert_count = {}, 0
    end
    env.convert_cache[text] = converted
    env.convert_count = (env.convert_count or 0) + 1
    return converted
end

local function query_user_code(env, code)
    if code == "" then return end
    local weights = env.user_queries[code]
    if not weights then
        weights = {}
        local dictionary = user_memory(env)
        for entry in dictionary:lookup_words(code .. " \t", true, MAX_USER_RECORDS):iter() do
            if entry.commit_count > 0 and #entry.text >= 6 then
                local converted = converted_word(env, entry.text)
                weights[entry.text] = math.max(weights[entry.text] or -math.huge, entry.weight)
                weights[converted] = math.max(weights[converted] or -math.huge, entry.weight)
            end
        end
        if env.query_count >= MAX_QUERY_CACHE then
            env.user_queries, env.query_count = {}, 0
        end
        env.user_queries[code] = weights
        env.query_count = env.query_count + 1
    end
    for text, weight in pairs(weights) do
        env.user_words[text] = math.max(env.user_words[text] or -math.huge, weight)
    end
end

function M.refresh_user_weights(env, candidates)
    if env.user_dirty or not env.user_queries then
        release_user_memory(env)
        env.user_queries, env.query_count = {}, 0
        env.user_dirty, env.user_error = false, nil
        env.memo = nil
    end
    local previous_words = env.user_words or {}
    env.user_words = {}
    if env.user_error then return end
    local ok, err = pcall(function()
        for _, candidate in ipairs(candidates) do
            if #candidate.text >= 6 then
                for _, code in ipairs(candidate_codes(env, candidate)) do
                    query_user_code(env, code)
                    local context_code = code
                    local tail_codes = env.tail_codes or {}
                    for count = 1, math.min(env.max_k, #tail_codes) do
                        local syllable = tail_codes[#tail_codes - count + 1]
                        if not syllable then break end
                        context_code = syllable .. " " .. context_code
                        query_user_code(env, context_code)
                    end
                end
            end
        end
    end)
    release_user_memory(env)
    if not ok then
        env.user_words = {}
        env.user_error = tostring(err)
        local rime_log = rawget(_G, "log")
        if rime_log then
            rime_log.warning("context_reorder: cannot read user weights: " .. tostring(err))
        end
    end
    for text, weight in pairs(previous_words) do
        if env.user_words[text] ~= weight then env.memo = nil; break end
    end
    for text, weight in pairs(env.user_words) do
        if previous_words[text] ~= weight then env.memo = nil; break end
    end
end

function M.record_commit(env, ctx)
    local text = ctx:get_commit_text()
    if not text or text == "" then return end
    local committed_codes, committed_text = {}, {}
    local ok = pcall(function()
        for _, segment in ipairs(ctx.composition:get_segments()) do
            local candidate = segment:get_selected_candidate()
            if not candidate then error("missing committed candidate") end
            committed_text[#committed_text + 1] = candidate.text
            local code = candidate_codes(env, candidate)[1] or ""
            local syllables = {}
            for syllable in code:gmatch("%S+") do syllables[#syllables + 1] = syllable end
            for position = 1, utf8.len(candidate.text) do
                committed_codes[#committed_codes + 1] =
                    (#syllables == utf8.len(candidate.text)) and syllables[position] or false
            end
        end
    end)
    release_user_memory(env)
    if not ok or table.concat(committed_text) ~= text then
        committed_codes = {}
        for position = 1, utf8.len(text) do committed_codes[position] = false end
    end
    local tail_codes = env.tail_codes or {}
    for _, code in ipairs(committed_codes) do tail_codes[#tail_codes + 1] = code end
    while #tail_codes > TAIL_CHARS do table.remove(tail_codes, 1) end
    env.tail_codes = tail_codes
    env.tail = tail_chars(env.tail .. text, TAIL_CHARS)
    env.memo, env.user_dirty = nil, true
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

    env.user_dirty = true

    env.tail_codes = {}
    env.notifier = env.engine.context.commit_notifier:connect(function(ctx)
        M.record_commit(env, ctx)
    end)
    env.delete_notifier = env.engine.context.delete_notifier:connect(function()
        env.user_dirty = true
    end)
end

-- 在词表中查词，返回权重或 nil；词表未命中时 fallback 到 userdb 自造词（权重 1）
function M.lookup(env, word)
    local first = head_chars(word, 1)
    local range = env.idx[first]
    if not range then
        return env.user_words and env.user_words[word] and 1 or nil
    end
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
    -- 首字组内未命中，再查 userdb
    return env.user_words and env.user_words[word] and 1 or nil
end

function M.func(input, env)
    if not env.enabled or env.tail == "" then
        for cand in input:iter() do yield(cand) end
        return
    end

    -- 只对前 max_cands 个候选做重排分析；窗口外的候选不丢弃，原序放行。
    -- （本 filter 可能位于 aux_code 之前，后续 filter 仍需见到完整候选流）
    local cands = {}
    local overflow = false
    for cand in input:iter() do
        cands[#cands + 1] = cand
        if #cands >= env.max_cands then
            overflow = true
            break
        end
    end

    M.refresh_user_weights(env, cands)

    local tail = env.tail
    local memo = env.memo or {}
    -- 输入折算的期望汉字长度（剔除辅助码后 2 字母/字）
    local expect_len = expected_char_len(env.engine.context.input, env.trigger_key)
    local boosted = {} -- {i, len_match, k, weight}
    for i, cand in ipairs(cands) do
        local text = cand.text
        if #text >= 6 then -- 至少 2 个汉字（6 字节），单字不参与重排（交给 aux_code）
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
                local context_weight = -math.huge
                local candidate_weight = -math.huge
                if env.user_words then
                    if k > 0 then
                        context_weight = env.user_words[tail_chars(tail, k) .. text] or -math.huge
                    end
                    candidate_weight = env.user_words[text] or -math.huge
                end
                boosted[#boosted + 1] = {
                    i = i, lm = len_match, k = k, w = w,
                    context_weight = context_weight, candidate_weight = candidate_weight,
                }
            end
        end
    end
    env.memo = memo

    table.sort(boosted, function(a, b)
        if a.lm ~= b.lm then return a.lm > b.lm end
        if a.k ~= b.k then return a.k > b.k end
        if a.context_weight ~= b.context_weight then return a.context_weight > b.context_weight end
        if a.w ~= b.w then return a.w > b.w end
        if a.candidate_weight ~= b.candidate_weight then return a.candidate_weight > b.candidate_weight end
        return a.i < b.i
    end)

    local boosted_set = {}
    for _, b in ipairs(boosted) do boosted_set[b.i] = true end
    for _, b in ipairs(boosted) do yield(cands[b.i]) end
    for i, cand in ipairs(cands) do
        if not boosted_set[i] then yield(cand) end
    end
    -- 窗口外的候选继续放行（iter 从上次中断处继续，不会重复）
    if overflow then
        for cand in input:iter() do yield(cand) end
    end
end

function M.fini(env)
    if env.notifier then env.notifier:disconnect() end
    if env.delete_notifier then env.delete_notifier:disconnect() end
    release_user_memory(env)
end

return M
