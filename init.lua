-- language/brainforth.lua
--
-- implements a very smart dialect of forth

local sutil = require("text/utils")

local m = {}

local inline = {}
m.inline = inline

local function sanitize(name)
  return "WORD_" .. name:gsub("%W", function(s)
    return ("_%02x"):format(s:byte(1))
  end)
end
m.sanitize = sanitize

local function PUSH_RETADDR(asm)
  asm.store('ra', 'sp', 0)
  asm.addi('sp', 'sp', 1)
end

local function POP_RETADDR(asm)
  asm.addi('sp', 'sp', -1)
  asm.load('ra', 'sp', 0)
end

local function POP_DATA(asm, reg)
  asm.addi('dp', 'dp', -1)
  asm.load(reg or 'top', 'dp', 0)
end

local function PUSH_DATA(asm, reg)
  asm.store(reg or 'top', 'dp', 0)
  asm.addi('dp', 'dp', 1)
end

local function PUSH_DATA_LIT(asm, val, reg)
  asm.li(reg or 'top', val)
  PUSH_DATA(asm, reg or 'top')
end

local function PUSH_DATA_FUNCTION_POINTER(asm, fname)
  asm.aipc('top', sanitize(fname))
  PUSH_DATA(asm, 'top')
end

inline["!"] = function(asm) -- store
  asm.load('addr', 'dp', -1)
  asm.load('top', 'dp', -2)
  asm.addi('dp', 'dp', -2)
  asm.store('top', 'addr', 0)
end

inline["@"] = function(asm) -- fetch
  POP_DATA(asm, 'addr')
  asm.load('top', 'addr', 0)
  PUSH_DATA(asm, 'top')
end


inline[">r"] = function(asm) -- data stack to return stack
  asm.load('top', 'dp', -1)
  asm.store('top', 'sp', 0)
  asm.addi('dp', 'dp', -1)
  asm.addi('sp', 'sp', 1)
end

inline["r>"] = function(asm) -- return stack to data stack
  asm.load('top', 'sp', -1)
  asm.store('top', 'dp', 0)
  asm.addi('sp', 'sp', -1)
  asm.addi('dp', 'dp', 1)
end

inline["r@"] = function(asm) -- push return on to data stack
  asm.load('top', 'sp', -1)
  asm.store('top', 'dp', 0)
  asm.addi('dp', 'dp', 1)
end

inline["dup"] = function(asm)
  asm.load('top', 'dp', -1)
  PUSH_DATA(asm, 'top')
end

inline["over"] = function(asm)
  asm.load('top', 'dp', -2)
  PUSH_DATA(asm, 'top')
end

inline["rot"] = function(asm)
  --  -3  -2  -1
  -- bot addr top <-
  -- addr top bot
  asm.load('bot', 'dp', -3)
  asm.load('addr', 'dp', -2)
  asm.load('top', 'dp', -1)
  asm.store('addr', 'dp', -3)
  asm.store('top', 'dp', -2)
  asm.store('bot', 'dp', -1)
end

inline["pick"] = function(asm)
  asm.load('top', 'dp', -1)
  asm.sub('top', 'dp', 'top')
  asm.load('top', 'top', -2)
  asm.store('top', 'dp', -1)
end

inline["drop"] = function(asm)
  POP_DATA(asm, 'zero')
end

inline["swap"] = function(asm)
  asm.load('top', 'dp', -1)
  asm.load('bot', 'dp', -2)
  asm.store('top', 'dp', -2)
  asm.store('bot', 'dp', -1)
end

inline["sync"] = function(asm)
  asm.sync()
end

inline["bye"] = function(asm)
  asm.halt()
end

inline["coreid"] = function(asm)
  asm.crid('top')
  PUSH_DATA(asm, 'top')
end

inline["exec"] = function(asm, tail)
  POP_DATA(asm, 'addr')
  if tail then
    asm.jalr('zero', 'addr', 0)
  else
    PUSH_RETADDR(asm)
    asm.jalr('ra', 'addr', 0)
    POP_RETADDR(asm)
  end
end

local function wrap_binop(wordname, opname)
  inline[wordname] = function(asm)
    asm.load('top', 'dp', -2)
    asm.load('bot', 'dp', -1)
    asm.addi('dp', 'dp', -1)
    asm[opname]('top', 'top', 'bot')
    asm.store('top', 'dp', -1)
  end
end
wrap_binop("+", "add")
wrap_binop("-", "sub")
wrap_binop("*", "mul")
wrap_binop("/", "div")
wrap_binop("%", "mod")
wrap_binop("^", "pow")
wrap_binop("==", "eq")
wrap_binop("!=", "neq")
wrap_binop(">=", "geq")
wrap_binop("<=", "leq")
wrap_binop(">", "gt")
wrap_binop("<", "lt")
wrap_binop("&", "and")
wrap_binop("|", "or")
wrap_binop("xor", "xor")

local function CALL(ctx, asm, wordname, tail)
  if m.inline[wordname] then 
    m.inline[wordname](asm, tail)
  elseif tail then
    asm.jal('zero', sanitize(wordname))
  else -- non-tail, non-inline call
    PUSH_RETADDR(asm)
    asm.jal('ra', sanitize(wordname))
    POP_RETADDR(asm)
  end
end

local function TAIL_COND_CALL(ctx, asm, wordname)
  ctx.cond_idx = (ctx.cond_idx or 0) + 1
  local skip_label = "_" .. ctx.cur_word .. "_CND_" .. ctx.cond_idx
  POP_DATA(asm, 'top')
  asm.beq('zero', 'top', skip_label)
  if m.inline[wordname] then 
    m.inline[wordname](asm, true)
    asm.jalr('zero', 'ra', 0)
  else
    asm.jal('zero', sanitize(wordname))
  end
  asm.label(skip_label)
end

function m.compile_special(ctx, asm, special)
  -- only 'asm' special supported ATM
  if special[1] ~= "asm" then 
    error("Unsupported special " .. special[1])
  end
  for _, line in ipairs(special[2]) do
    asm.emit(line)
  end
end

function m.compile_subword(ctx, wordname, body)
  local safe_name = sanitize(wordname)

  local function gen(ctx, asm)
    ctx.cond_idx = 0
    ctx.cur_word = safe_name
    for idx, w in ipairs(body) do
      if type(w) == 'table' then
        m.compile_special(ctx, asm, w)
      elseif tonumber(w) then
        PUSH_DATA_LIT(asm, tonumber(w))
      elseif w:sub(1,1) == "'" and w:sub(-1,-1) == "'" then
        -- character literal
        if #w ~= 3 then error("char literals must be a single character!") end
        PUSH_DATA_LIT(asm, w:byte(2)) -- just turn into ascii value
      elseif w:sub(1,1) == '$' then
        local mapval = ctx.memmap[w:sub(2,-1)]
        if not mapval then error("Undefined constant: " .. w) end
        PUSH_DATA_LIT(asm, mapval)
      elseif w:sub(1,1) == '&' then
        PUSH_DATA_FUNCTION_POINTER(asm, w:sub(2,-1))
      elseif w:sub(1,1) == '?' then
        if idx < #body - 1 then
          error("Conditional call only allowed in last or second-to-last position!")
        end
        TAIL_COND_CALL(ctx, asm, w:sub(2,-1))
      else
        CALL(ctx, asm, w, idx == #body)
      end
    end
  end

  ctx.words[wordname] = {
    label_name = safe_name,
    needs_compile = true, -- ???
    gen = gen
  }
end

local function worditer(lines)
  return coroutine.wrap(function()
    local in_block = false
    for _, line in ipairs(lines) do
      print(line)
      local stripped = sutil.strip(line)
      if stripped and #stripped > 0 then
        if stripped:match("^[%w]+{$") then 
          in_block = true
          coroutine.yield(stripped)
        elseif in_block then
          in_block = stripped ~= "}"
          coroutine.yield(stripped)
        else
          local words = sutil.split_words(stripped)
          for _, w in ipairs(words) do
            if (not in_block) and w == "\\" then break end
            coroutine.yield(w)
          end
        end
      end
    end
  end)
end

local function parse_special(iter, close)
  local accum = {}
  for w in iter do
    if w == close then return accum end
    table.insert(accum, w)
  end
end

local function parse_worddef(iter)
  local name = iter()
  local body = {}
  for w in iter do
    if w == ";" then 
      return name, body
    elseif w == "(" then
      parse_special(iter, ")")
    elseif w == "asm{" then
      table.insert(body, {"asm", parse_special(iter, "}")})
    else
      table.insert(body, w)
    end
  end
  error("Unclosed definition")
end

function m.parse(src, memmap, meta)
  local words = {}
  local iter = worditer(src)
  for w in iter do
    if w ~= ":" then
      error("Top level must only be definitions! Got " .. w)
    end
    local name, body = parse_worddef(iter)
    words[name] = body
  end
  return {words = words, meta = meta, memmap = memmap}
end

function m.print_ast(ast)
  local frags = {}
  for wname, body in pairs(ast.words) do
    table.insert(frags, ":" .. " " .. wname)
    for _, w in ipairs(body) do
      if type(w) == 'table' then
        table.insert(frags, w[1] .. "{")
        table.insert(frags, table.concat(w[2], "\n"))
        table.insert(frags, "}")
      else
        table.insert(frags, "  " .. tostring(w))
      end
    end
    table.insert(frags, ";")
  end
  return table.concat(frags, "\n")
end

function m.compile_old(ast, asm)
  local ctx = {words = {}, cond_idx = 0, memmap = ast.memmap}
  for wname, body in pairs(ast.words) do
    m.compile_subword(ctx, wname, body)
  end

  -- ra is register 1 -- return address
  -- sp is register 2 -- one past the top of the return stack
  asm.comment('BRAINFORTH')
  asm.alias('dp', 3)  -- one past the top of the data stack
  asm.alias('top', 4) -- it's just a temp value
  asm.alias('bot', 5) -- it's just a temp value
  asm.alias('addr', 6) -- addr is just a temp
  -- put stacks at the bottom
  local stacktop = ast.meta.stacktop or 256*256
  local dstacksize = ast.meta.dstacksize or 256
  local rstacksize = ast.meta.rstacksize or 256
  local totalstack = dstacksize + rstacksize
  asm.crid('top')
  asm.muli('top', 'top', totalstack)
  asm.li('addr', stacktop)
  asm.sub('addr', 'addr', 'top')
  asm.subi('sp', 'addr', rstacksize)
  asm.subi('dp', 'sp', dstacksize)
  asm.li('top', 0)
  asm.li('addr', 0)
  asm.jal('zero', 'WORD_ENTRY')
  asm.halt()
  for _, word in pairs(ctx.words) do
    if word.needs_compile then
      asm.label(word.label_name)
      word.gen(ctx, asm)
      asm.jalr('zero', 'ra', 0) -- ???
    end
  end
end

function m.compile(ast, asm)
  if ast.meta.new_compiler and ast.meta.new_compiler ~= "false" then
    require("language/brainforth/advcompiler").compile(ast, asm)
  else
    m.compile_old(ast, asm)
  end
end

local debugger = {}

function debugger:install(emu, log)
  self.emu = emu
  self.print = log
end

function debugger:has_hit_breakpoint()
  for idx = 0, self.emu.raw:get_enabled_core_count()-1 do
    if self.emu.cores[idx].status == 0x40000000 then
      return idx
    end
  end
  return false
end

function debugger:on_io()
  local broke_core = self:has_hit_breakpoint()
  if broke_core then
    self.emu:set_fullscreen(false, true) -- no fullscreen, yes pause
    self.print(("Core [%d] triggered breakpoint @ %d"):format(
      broke_core, self.emu.cores[broke_core].pc))
    self:datastack(broke_core)
  end
end

local FORMATTERS = {
  ascii = function(v)
    if v > 0 and v <= 128 then
      return string.char(v)
    else
      return ("\\x%02x"):format(v)
    end
  end,
  hex = function(v) return ("%x"):format(v) end,
  dec = tostring
}

function debugger:_print_stack(register, core, format, depth)
  if not self.emu then 
    self.print("Not attached to VM")
    return
  end
  local spos = self.emu.cores[core or 0].registers[register]
  depth = depth or 8
  format = format or tostring
  if type(format) == 'string' then format = FORMATTERS[format] end
  local frags = {}
  for mempos = spos-depth, spos-1 do
    table.insert(frags, format(self.emu.memory[mempos]))
  end
  table.insert(frags, (" > %04x"):format(spos))
  self.print(table.concat(frags, " "))
end

function debugger:continue(unpause, core)
  if not self.emu then
    self.print("Not attached to VM")
    return
  end
  if not core then 
    self.emu.raw:resume(0x40000000)
    if unpause then self.emu:pause(false) end
    return
  end
  if self.emu.cores[core].status ~= 0x40000000 then
    self.print("Core is not at a breakpoint.")
    return
  end
  self.emu.raw:resume_core(core, 0x40000000)
  if unpause then self.emu:pause(false) end
end

function debugger:datastack(core, format, depth)
  return self:_print_stack(3, core, format, depth)
end
debugger.ds = debugger.datastack

function debugger:returnstack(core, format, depth)
  return self:_print_stack(2, core, format, depth)
end
debugger.rs = debugger.returnstack

function m.get_debugger(meta, macros)
  debugger.meta, debugger.macros = meta, macros
  return debugger
end

function m.get_tools()
  return debugger
end

return m