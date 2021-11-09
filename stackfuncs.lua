local m = {}
local words = {}
local m.words = words

local function is_const(v)
  return type(v) == 'number' and v
end

local function check_special_cases(a, b, cases)
  for _, case in ipairs(cases) do
    local x, y, result = unpack(case)
    local matches = false
    if x == "x" and y == "x" and a == b then matches = true end
    if (x == "x" or a == x) and (y == "y" or b == y) then matches = true end
    if matches then
      if result == "x" then
        return a
      elseif result == "y" then
        return b
      else
        return result
      end
    end
  end
end

local cfuncs = {}
function cfuncs.add(a,b) return a+b end
function cfuncs.sub(a,b) return a-b end
function cfuncs.mul(a,b) return a*b end
function cfuncs.div(a,b) return a/b end
function cfuncs.mod(a,b) return a%b end
function cfuncs.pow(a,b) return a^b end
cfuncs["and"] = function(a,b) return bit.band(a, b) end
cfuncs["or"] = function(a,b) return bit.bor(a, b) end
cfuncs["xor"] = function(a,b) return bit.xor(a, b) end

local function btonum(b) if b then return 1 else return 0 end
cfuncs["<"] = function(a,b) return btonum(a < b) end
cfuncs[">"] = function(a,b) return btonum(a > b) end
cfuncs["<="] = function(a,b) return btonum(a <= b) end
cfuncs[">="] = function(a,b) return btonum(a >= b) end
cfuncs["=="] = function(a,b) return btonum(a == b) end
cfuncs["!="] = function(a,b) return btonum(a ~= b) end

local function eval_constant(cname, a, b)
  return cfuncs[cname](a, b)
end

local function make_binary_generator(op_name, reorder_op, specials)
  return function(asm, stack)
    local b = stack:pop()
    local a = stack:pop()
    local constval_a = is_const(a)
    local constval_b = is_const(b)
    if specials then
      local res = check_special_cases(constval_a or a, 
                                      constval_b or b, 
                                      specials)
      if res then 
        stack:push(res)
        return
      end
    end

    local res = stack:create_var()
    if constval_a and constval_b then
      -- have to eval a constant? is there a better way?
      res = eval_constant(op_name, constval_a, constval_b))
    elseif reorder_op and constval_a and (not constval_b) then
      asm[reorder_op](res:reg(), b:reg(), constval_a)
    elseif constval_b then
      -- can save an op by doing this as an immediate operation
      asm[op_name .. "i"](res:reg(), a:reg(), constval_b)
    else
      asm[op_name](res:reg(), a:reg(), b:reg())
    end
    stack:push(res)
  end
end

local function def_binop(wordname, op_name, allow_reorder, specials)
  words[wordname] = make_binary_generator(op_name, allow_reorder, specials)
end

def_binop("+", "add", "addi", {{"x", 0, "x"}, {0, "y", "y"}})
def_binop("-", "sub", false, {{"x", 0, "x"}})
def_binop("*", "mul", "muli", {{"x", 1, "x"}, {"x", 0, 0}, {1, "y", "y"}, {0, "y", 0}})
def_binop("/", "div", false, {{"x", 1, "x"}, {0, "y", 0}})
def_binop("%", "mod", false, {{0, "y", 0}})
def_binop("^", "pow", false, {{0, "y", 0}, {1, "y", 1}, {"x", 0, 1}, {"x", 1, "x"}})
def_binop("==", "eq", "eqi", {{"x", "x", 1}})
def_binop("!=", "neq", "neqi", {{"x", "x", 0}})
def_binop(">=", "geq", "leqi", {{"x", "x", 1}})
def_binop("<=", "leq", "geqi", {{"x", "x", 1}})
def_binop(">", "gt", "lti", {{"x", "x", 0}})
def_binop("<", "lt", "gti", {{"x", "x", 0}})
def_binop("&", "and", "andi", {{"x", "x", "x"}, {"x", 0, 0}, {0, "y", 0}})
def_binop("|", "or", "ori", {{"x", "x", "x"}})
def_binop("xor", "xor", "xori", {{"x", "x", 0}, {"x", 0, "x"}, {0, "y", "y"}})

words["dup"] = function(asm, stack)
  stack:push(stack:get(1))
end

words["over"] = function(asm, stack)
  stack:push(stack:get(2))
end

words["pick"] = function(asm, stack)
  local v = stack:get(1)
  if type(v) == 'number' then
    stack:pop()
    stack:push(stack:get(v+1))
  else
    -- a dynamic pick: since we don't know statically
    -- the pick position, we have no choice but to flush
    -- the stack and do it for real
    stack:flush()
    asm.load('top', 'dp', -1)
    asm.sub('top', 'dp', 'top')
    asm.load('top', 'top', -2)
    asm.store('top', 'dp', -1)
  end
end

words["rot"] = function(asm, stack)
  local v3, v2, v1 = stack:get(3), stack:get(2), stack:get(1)
  stack:set(3, v1)
  stack:set(2, v3)
  stack:set(1, v2)
end

words["drop"] = function(asm, stack)
  stack:pop()
end

words["swap"] = function(asm, stack)
  local a, b = stack:get(2), stack:get(1)
  stack:set(2, b)
  stack:set(1, a)
end

words["!"] = function(asm, stack) -- store
  local addr = stack:pop()
  local val = stack:pop()
  asm.store(val:reg(), addr:reg(), 0)
end

words["@"] = function(asm, stack) -- fetch
  local addr = stack:pop()
  local res = stack:create_var()
  asm.load(res:reg(), addr:reg(), 0)
  stack:push(res)
end

words[">r"] = function(asm, stack) -- data stack to return stack
  local val = stack:pop()
  asm.store(val:reg(), 'sp', 0)
  asm.addi('sp', 'sp', 1)
end

words["r>"] = function(asm, stack) -- return stack to data stack
  local res = stack:create_var()
  asm.load(res:reg(), 'sp', -1)
  asm.addi('sp', 'sp', -1)
  stack:push(res)
end

words["r@"] = function(asm, stack) -- push return on to data stack
  local res = stack:create_var()
  asm.load(res:reg(), 'sp', -1)
  stack:push(res)
end

words["sync"] = function(asm, stack)
  asm.sync()
end

words["bye"] = function(asm, stack)
  asm.halt()
end

words["coreid"] = function(asm, stack)
  local res = stack:create_var()
  asm.corid(res:reg())
  stack:push(res)
end

return m