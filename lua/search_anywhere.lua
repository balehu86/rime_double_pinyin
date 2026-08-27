local DELIM = '/'

-- 保留原有的单字查询函数：返回纯字符串列表
local function get_char_candidates(mem, pinyin)
    local texts = {}
    if pinyin and #pinyin > 0 and mem:dict_lookup(pinyin, false, 100) then
        for entry in mem:iter_dict() do
            if utf8.len(entry.text) == 1 then
                table.insert(texts, entry.text)
            end
        end
    end
    return texts
end

-- 查辅助码表：给定辅助码，返回哪些字对应这个码
local function get_aux_matched_chars(aux_mem, aux_code)
    local matched = {}
    if aux_code and #aux_code > 0 and aux_mem:dict_lookup(aux_code, true, 2000) then
        for entry in aux_mem:iter_dict() do
            matched[entry.text] = true
        end
    end
    return matched
end

-- 从用户词库中查找匹配整个（全拼）编码序列的词条
local function get_user_dict_candidates(mem, code_str)
    local result = {}
    if not code_str or code_str == '' then return result end
    if mem:dict_lookup(code_str, false, 10) then
        for entry in mem:iter_dict() do
            if utf8.len(entry.text) == 1 then
                table.insert(result, entry.text)
            end
        end
    end
    return result
end

local f = {}

-- 反查：给定单个汉字，返回它的全拼（多个读音取第一个）
-- REVERSE_DICT_NAME 需要和你 double_pinyin schema.yaml 里 translator/dictionary 的值一致
local REVERSE_DICT_NAME = 'rime_ice'
local reverse = nil

local function get_full_pinyin(ch)
    if not reverse or not ch then return nil end
    local ok, res = pcall(function() return reverse:lookup(ch) end)
    if not ok or not res or res == '' then return nil end
    -- 反查结果可能用换行或 ';' 分隔多个候选编码，只取第一个
    local first = res:match('^[^\n;]+')
    if first then
        first = first:gsub('%s+$', '')
    end
    return (first ~= '' and first) or nil
end

local function resolve(raw, env)
    while raw:sub(-1) == DELIM do
        raw = raw:sub(1, -2)
    end
    if not raw:find(DELIM, 1, true) then return nil end

    local tokens = {}
    for tok in (raw .. DELIM):gmatch('(.-)' .. DELIM) do
        if tok ~= "" then
            table.insert(tokens, tok)
        end
    end

    local has_incomplete_last = (#tokens % 2 == 1)
    local total_pairs = math.floor(#tokens / 2)

    local out, codes = {}, {}
    local i = 1

    while i <= total_pairs * 2 do
        local pinyin_i, aux_i = tokens[i], tokens[i + 1]
        local candidates = get_char_candidates(env.mem, pinyin_i)
        local matched = get_aux_matched_chars(env.aux_mem, aux_i)
        local picked = nil
        for _, ch in ipairs(candidates) do
            if matched[ch] then picked = ch break end
        end
        if not picked then return nil end
        table.insert(out, picked)
        -- 优先用反查到的全拼；反查不到就退回双拼 token，保证不会整体失败
        table.insert(codes, get_full_pinyin(picked) or pinyin_i)
        i = i + 2
    end

    if has_incomplete_last then
        local last_pinyin = tokens[#tokens]

        -- 先尝试用户词库：用已经解析出来的“全拼编码序列”作为前缀去查
        -- 注意：这里还没选出最后一个字，因此这一步主要覆盖“之前已造过的词”场景
        local prefix_code = table.concat(codes, ' ')
        local user_candidates = {}
        if prefix_code ~= '' then
            user_candidates = get_user_dict_candidates(env.mem, prefix_code)
        end

        local picked = nil
        if #user_candidates > 0 then
            picked = user_candidates[1]
        else
            local candidates = get_char_candidates(env.mem, last_pinyin)
            picked = candidates[1]
        end

        if picked then
            table.insert(out, picked)
            table.insert(codes, get_full_pinyin(picked) or last_pinyin)
        else
            return nil
        end
    end

    return table.concat(out), codes
end

function f.init(env)
    env.mem = Memory(env.engine, env.engine.schema)
    env.aux_mem = Memory(env.engine, Schema('radical_pinyin'))

    local ok, obj = pcall(function() return ReverseLookup(REVERSE_DICT_NAME) end)
    if ok then
        reverse = obj
        -- log.error('[aux_anywhere] ReverseLookup(' .. REVERSE_DICT_NAME .. ') loaded OK')
    else
        reverse = nil
        -- log.error('[aux_anywhere] ReverseLookup(' .. REVERSE_DICT_NAME .. ') FAILED: ' .. tostring(obj))
    end

    env.commit_notifier = env.engine.context.commit_notifier:connect(function(ctx)
        local raw = ctx.input
        if not raw then return end

        local text, codes = resolve(raw, env)
        if not text then return end

        -- log.error('[aux_anywhere] resolved on commit: raw=' .. raw .. ' text=' .. text .. ' codes=' .. table.concat(codes, ' '))

        local entry = DictEntry()
        entry.text = text
        entry.custom_code = table.concat(codes, ' ')
        if env.mem.start_session then env.mem:start_session() end
        env.mem:update_userdict(entry, 1, '')
        if env.mem.finish_session then env.mem:finish_session() end

        log.error('[aux_anywhere] write to userdict: ' .. text .. ' code=' .. entry.custom_code)
    end)
end

function f.func(input, seg, env)
    local raw = seg.original or input
    local composite, codes = resolve(raw, env)
    if not composite then return end
    local cand = Candidate('aux_anywhere', seg.start, seg.start + #raw, composite, '')
    cand.quality = 100
    yield(cand)
end

return f