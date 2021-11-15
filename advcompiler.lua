-- brainforth/advcompiler.lua
--
-- more advanced compiler based on analyzing stack usage

local stackanalysis = require("language/brainforth/stackanalysis")
local primitives = require("language/brainforth/stackfuncs").words
local Queue = require("queue").Queue

local m = {}

-- TODO: refactor this into utils or something
local function sanitize(name)
  return "WORD_" .. name:gsub("%W", function(s)
    return ("_%02x"):format(s:byte(1))
  end)
end

local function PUSH_RETADDR(asm)
  asm.store('ra', 'sp', 0)
  asm.addi('sp', 'sp', 1)
end

local function POP_RETADDR(asm)
  asm.addi('sp', 'sp', -1)
  asm.load('ra', 'sp', 0)
end

local function wordname(s)
  if type(s) ~= 'string' or tonumber(s) then return nil end
  local prefix = s:sub(1,1)
  if prefix == "$" or prefix == "&" or prefix == "'" then return nil end
  if prefix == "?" then return s:sub(2,-1) end
  return s
end

local function find_children(body)
  local children = {}
  for _, w in ipairs(body) do
    local childname = wordname(w)
    if childname then children[childname] = true end
  end
  return children
end

local function link_children(ctx)
  for wname, winfo in pairs(ctx.words) do
    for cname, _ in pairs(winfo.children) do
      if ctx.words[cname] then
        winfo.children[cname] = ctx.words[cname]
      elseif primitives[cname] then
        winfo.children[cname] = nil
      else
        error("Unresolved word: [" .. cname .. "]")
      end
    end
  end
end

local function _is_cyclic(query, seen, word)
  if seen[word] then return false end
  seen[word] = true
  for _, child in pairs(word.children) do
    if child == query then return true end
    if _is_cyclic(query, seen, child) then return true end
  end
  return false
end

local function is_cyclic(word)
  if word.is_cyclic == nil then 
    word.is_cyclic = _is_cyclic(word, {}, word)
  end
  return word.is_cyclic 
end

local function has_conditional_calls(body)
  for _, w in ipairs(body) do
    if type(w) == 'string' and w:sub(1,1) == '?' then return true end
  end
  return false
end

local function analyze_word(ctx, wordname, body)
  ctx.words[wordname] = {
    name = wordname,
    wordname = wordname,
    body = body,
    label_name = sanitize(wordname),
    needs_compile = true,
    children = find_children(body),
    conditional = has_conditional_calls(body)
  }
end

local function compile_special(ctx, special)
  -- only 'asm' special supported ATM
  if special[1] ~= "asm" then 
    error("Unsupported special " .. special[1])
  end
  for _, line in ipairs(special[2]) do
    ctx.asm.emit(line)
  end
end

local inline_word

local function should_inline(ctx, wordname)
  local word = assert(ctx.words[wordname])
  return (#word.body < ctx.max_inline_size) and (not word.conditional) and (not is_cyclic(word))
end

local function request_compile(ctx, wordname)
  print("requesting compile for: " .. wordname)
  local word = assert(ctx.words[wordname])
  if not ctx.compiled[wordname] then ctx.compile_queue:push(wordname) end
  return word.label_name
end

local function CALL(idepth, ctx, asm, stack, wordname, tail)
  if tail then print("Compiling tail call: " .. wordname) end
  if primitives[wordname] then 
    primitives[wordname](asm, stack, tail)
    stack:cleanup()
  elseif idepth < ctx.max_inline_depth and should_inline(ctx, wordname) then
    inline_word(idepth+1, ctx, asm, stack, wordname, tail)
  elseif tail then
    request_compile(ctx, wordname)
    stack:flush()
    asm.jal('zero', sanitize(wordname))
  else -- non-tail, non-inline call
    request_compile(ctx, wordname)
    stack:flush()
    PUSH_RETADDR(asm)
    asm.jal('ra', sanitize(wordname))
    POP_RETADDR(asm)
  end
end

local function TAIL_COND_CALL(idepth, ctx, asm, stack, wordname)
  if idepth > 0 then error("Cannot tail call out of an inline that's ridiculous!") end
  ctx.cond_idx = (ctx.cond_idx or 0) + 1
  local skip_label = "_" .. ctx.cur_word .. "_CND_" .. ctx.cond_idx
  local condval = stack:pop() --:reg()
  if type(condval) == 'number' then -- statically choose a branch
    if condval ~= 0 then
      CALL(idepth, ctx, asm, stack, wordname, true)
    end
    return
  end
  condval = condval:reg() -- SUBTLE! We need to force this into a register *before flushing*
  stack:flush() -- TODO: we could potentially clone the stack?
  asm.beq('zero', condval, skip_label)
  if primitives[wordname] then 
    primitives[wordname](asm, stack, true)
    stack:flush()
    asm.jalr('zero', 'ra', 0)
  elseif idepth < ctx.max_inline_depth and should_inline(ctx, wordname) then
    inline_word(idepth+1, ctx, asm, stack, wordname)
    stack:flush()
    asm.jalr('zero', 'ra', 0)
  else
    request_compile(ctx, wordname)
    asm.jal('zero', sanitize(wordname))
  end
  asm.label(skip_label)
end

local function maybe_elide_exec(w, stack)
  local top = stack:peek(1)
  if top and type(top) == 'table' and top.sym then
    local symname = top.sym.name
    -- foo ?exec => ?foo
    if w:sub(1,1) == "?" then symname = "?" .. symname end
    stack:pop()
    return symname
  end
end

inline_word = function(idepth, ctx, asm, stack, wordname, inline_tail)
  local word = ctx.words[wordname]
  local bodysize = #word.body
  for idx, w in ipairs(word.body) do
    if w == 'exec' or w == '?exec' then -- HACK to specially deal with exec
      w = maybe_elide_exec(w, stack) or w 
    end 
    if type(w) == 'table' then
      stack:flush()
      compile_special(ctx, asm, w)
    elseif tonumber(w) then
      stack:push(tonumber(w))
    elseif w:sub(1,1) == "'" and w:sub(-1,-1) == "'" then
      -- character literal
      if #w ~= 3 then error("char literals must be a single character!") end
      stack:push(w:byte(2)) -- just turn into ascii value
    elseif w:sub(1,1) == '$' then
      local mapval = ctx.memmap[w:sub(2,-1)]
      if not mapval then error("Undefined constant: " .. w) end
      stack:push(mapval)
    elseif w:sub(1,1) == '&' then
      local refword = ctx.words[w:sub(2,-1)]
      if not refword then 
        error("Tried to produce function pointer for unknown word: " .. w:sub(2,-1))
      end
      --PUSH_FUNCPTR(asm, stack, refword)
      stack:push(stack:create_symbol(refword, ctx.resolve_symbol))
    elseif w:sub(1,1) == '?' then
      if idx < bodysize - 1 then
        error("Conditional call only allowed in last or second-to-last position!")
      end
      TAIL_COND_CALL(idepth, ctx, asm, stack, w:sub(2,-1))
    else
      CALL(idepth, ctx, asm, stack, w, inline_tail and idx == bodysize)
    end
  end
end

local function compile_subword(ctx, wordname, wordinfo)
  local safe_name = wordinfo.label_name
  local asm = ctx.asm
  local stack = stackanalysis.Stack(asm, ctx.temp_registers)

  print("---- Compiling " .. wordname .. " ----------")

  ctx.cond_idx = 0
  ctx.cur_word = safe_name
  asm.label(safe_name)
  inline_word(0, ctx, asm, stack, wordname, true)
  stack:flush()
  asm.jalr('zero', 'ra', 0)
end

function m.compile(ast, asm)
  asm.comment('ADVANCED BRAINFORTH COMPILER 0.1')
  asm.alias('dp', 3)  -- one past the top of the data stack
  asm.alias('t0', 4)  -- one past the top of the data stack
  local temp_registers = {}
  for idx = 1, tonumber(ast.meta.num_temp_registers or 16) do
    local tname = "t" .. idx
    asm.alias(tname, 4 + idx)
    table.insert(temp_registers, tname)
  end

  -- put stacks at the bottom
  local stacktop = ast.meta.stacktop or 256*256
  local dstacksize = ast.meta.dstacksize or 256
  local rstacksize = ast.meta.rstacksize or 256
  local totalstack = dstacksize + rstacksize
  asm.crid('t1')
  asm.muli('t1', 't1', totalstack)
  asm.li('t2', stacktop)
  asm.sub('t2', 't2', 't1')
  asm.subi('sp', 't2', rstacksize)
  asm.subi('dp', 'sp', dstacksize)
  asm.li('t1', 0)
  asm.li('t2', 0)
  asm.jal('zero', 'WORD_ENTRY')
  asm.halt()

  local ctx = {
    asm = asm,
    compiled = {},
    compile_queue = Queue(),
    words = {}, 
    cond_idx = 0, 
    memmap = ast.memmap,
    temp_registers = temp_registers,
    max_inline_depth = tonumber(ast.meta.max_inline_depth or 2),
    max_inline_size = tonumber(ast.meta.max_inline_size or 10)
  }
  ctx.resolve_symbol = function(sym)
    print("Resolving " .. sym.name)
    request_compile(ctx, sym.name)
    return sym.label_name
  end

  for wname, body in pairs(ast.words) do
    analyze_word(ctx, wname, body)
  end

  link_children(ctx)

  if ast.meta.dead_code_elimination ~= "false" then
    ctx.compile_queue:push("ENTRY")
  else
    for wname, _ in pairs(ctx.words) do
      ctx.compile_queue:push(wname)
    end
  end

  while ctx.compile_queue:length() > 0 do
    local wname = ctx.compile_queue:pop()
    if not ctx.compiled[wname] then
      ctx.compiled[wname] = true
      compile_subword(ctx, wname, ctx.words[wname])
    end
  end
end

return m