local DELIM = '/'

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

local f = {}

-- 提取公共的"解析原始输入，拼出复合候选"逻辑，translator 和 select_notifier 都要用
local function resolve(raw, env)
    if not raw:find(DELIM, 1, true) then return nil end
    local tokens = {}
    for tok in (raw .. DELIM):gmatch('(.-)' .. DELIM) do
        table.insert(tokens, tok)
    end
    local out, codes = {}, {}
    local i = 1
    while i <= #tokens do
        local pinyin_i, aux_i = tokens[i], tokens[i + 1]
        if aux_i then
            local candidates = get_char_candidates(env.mem, pinyin_i)
            local matched = get_aux_matched_chars(env.aux_mem, aux_i)
            local picked = nil
            for _, ch in ipairs(candidates) do
                if matched[ch] then picked = ch break end
            end
            if not picked then return nil end  -- 有一段没解出来，整体放弃，交回正常翻译
            table.insert(out, picked)
            table.insert(codes, pinyin_i)
            i = i + 2
        else
            local candidates = get_char_candidates(env.mem, pinyin_i)
            local picked = candidates[1]
            if not picked then return nil end
            table.insert(out, picked)
            table.insert(codes, pinyin_i)
            i = i + 1
        end
    end
    return table.concat(out), codes
end

function f.init(env)
    env.mem = Memory(env.engine, env.engine.schema)
    env.aux_mem = Memory(env.engine, Schema('radical_pinyin'))

    -- 选中时：记下这次要造的词和它对应的正常拼音码序列
    env.select_notifier = env.engine.context.select_notifier:connect(function(ctx)
        local text, codes = resolve(ctx.input, env)
        env.pending_text, env.pending_codes = text, codes
    end)

    -- 上屏时：如果刚才选中的正好是我们拼出来的这个词，写入用户词库
    env.commit_notifier = env.engine.context.commit_notifier:connect(function(ctx)
        if env.pending_text and env.pending_codes and ctx:get_commit_text() == env.pending_text then
            local entry = DictEntry()
            entry.text = env.pending_text
            entry.custom_code = table.concat(env.pending_codes, ' ')
            if env.mem.start_session then env.mem:start_session() end
            env.mem:update_userdict(entry, 1, '')
            if env.mem.finish_session then env.mem:finish_session() end
        end
        env.pending_text, env.pending_codes = nil, nil
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