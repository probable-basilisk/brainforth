local class = require("class")
local m = {}

local Var = class("Var")
m.Var = Var

function Var:init(parent, src_slot)
  self.parent = parent
  self.src_slot = src_slot
  self.register = nil
end

function Var:reg()
  if not self.register then
    self.register = self.parent:claim_register()
    if self.src_slot then
      self.parent.asm.load(self.register, 'dp', self.src_slot)
    end
  end
  return self.register
end

function Var:li(val)
  self.parent.asm.li(self:reg(), val)
  return self
end

function Var:preflush(dest_slot)
  assert(dest_slot)
  if not self.register then
    if dest_slot == self.src_slot then
      -- elide noop of store(load(stack[pos]))
      return 
    elseif self.src_slot then
      -- a simple stack move
      self:reg()
    else
      error("Tried to flush Var with no associated register!") 
    end
  end
end

function Var:flush(dest_slot)
  -- HMM
  if self.register and dest_slot ~= self.src_slot then
    self.parent.asm.store(self.register, 'dp', dest_slot)
  end
end

function Var:release()
  if not self.register then return end
  self.parent:release_register(self.register) 
end

local Stack = class("Stack")
m.Stack = Stack

function Stack:init(asm, temp_registers)
  self.asm = asm
  self.stack = {}
  self.vars = {}
  self.dp = 0
  self._temp_registers = temp_registers
  self:_restore_registers()
end

function Stack:cleanup()
  local seen = {}
  for _, val in pairs(self.stack) do
    if type(val) ~= 'number' then
      seen[val] = true
    end
  end
  for var, _ in pairs(self.vars) do
    if not seen[var] then
      var:release()
      self.vars[var] = nil
    end
  end
end

function Stack:_restore_registers()
  self.registers = {}
  for _, reg in ipairs(self._temp_registers) do
    self.registers[reg] = true
  end
end

function Stack:create_var(abs_idx)
  local var = Var(self, abs_idx)
  self.vars[var] = true
  return var
end

function Stack:get(idx)
  local abs_idx = self.dp - idx
  if not self.stack[abs_idx] then
    self.stack[abs_idx] = self:create_var(abs_idx)
  end
  return self.stack[abs_idx]
end

function Stack:set(idx, v)
  local abs_idx = self.dp - idx
  self.stack[abs_idx] = v
end

function Stack:pop()
  self.dp = self.dp - 1
  return self:get(0)
end

-- forces the popped value to be in a register
function Stack:pop_in_register()
  local res = self:pop()
  if type(res) ~= 'number' then return res end
  return self:create_var():li(res)
end

function Stack:push(val)
  print("Pushing", val)
  self:set(0, val)
  self.dp = self.dp + 1
end

function Stack:flush()
  print("flushing")
  self.asm.comment("flush")
  -- preflush: complete all loads first
  for abs_idx, val in pairs(self.stack) do
    if type(val) == 'table' and abs_idx < self.dp then
      val:preflush(abs_idx)
    end
  end
  for abs_idx, val in pairs(self.stack) do
    -- only write values that are actually in the stack
    if abs_idx < self.dp then
      if type(val) == 'number' then
        self.asm.li('t0', val)
        self.asm.store('t0', 'dp', abs_idx)
      else
        val:flush(abs_idx)
      end
    end
  end
  if self.dp ~= 0 then
    self.asm.addi('dp', 'dp', self.dp)
  end
  self.vars = {}
  self.stack = {}
  self.dp = 0
  self:_restore_registers()
end

function Stack:claim_register()
  local reg = next(self.registers)
  if not reg then error("Ran out of temp registers!") end
  self.registers[reg] = nil
  return reg
end

function Stack:release_register(reg)
  self.registers[reg] = true
end

return m