local scontext_meta = {}

function scontext_meta:__index(k)
  if type(k) == 'number' then
    local dp = rawget(self, 'dp')
    local svals = rawget(self, '_lifted')
    local slot = dp - k
    if not svals[slot] then
      svals[slot] = self:_lift_stack(slot)
    end
    return svals[slot]
  else
    return scontext_meta[k]
  end
end

function scontext_meta:__newindex(k, v)
  if type(k) == 'number' then
    local dp = rawget(self, 'dp')
    local svals = rawget(self, '_lifted')
    local slot = dp - k
    if not svals[slot] then
      svals[slot] = self:_lift_stack(slot, v)
    end
  else
    rawset(self, k, v)
  end
end

function scontext_meta:_count_multiplicity(reg)
  local count = 0
  for _, val in pairs(self._lifted) do
    if type(val) == 'table' and val.reg == reg then
      count = count + 1
    end
  end
  return count
end

function scontext_meta:_assign_register()
  local reg = self._next_reg
  self._next_reg = self._next_reg + 1
  return ret
end

function scontext_meta:_lift_stack(slot, val)
  if val then return val end
  local reg = self:_assign_register()
  self.asm.load(reg, 'dp', slot)
  return {reg = reg}
end

function scontext_meta:init(self)
  self._lifted = {}
end

function scontext_meta:push(v)
  self[self.dp] = v
  self.dp = self.dp + 1
end

function scontext_meta:pop()
  self.dp = self.dp - 1
  local ret = self[self.dp]
  self[self.dp] = nil
  return ret
end

function scontext_meta:commit(self)
  for idx, v in pairs(self._lifted) do
    if idx < self.dp then
      if type(v) == 'number' then
        self.asm.li('top', v)
        self.asm.store('top', 'dp', idx)
      else
        self.asm.store(v.reg, 'dp', idx)
      end
    end
  end
  self.asm.addi('dp', 'dp', self.dp)
  self.dp = 0
  self._lifted = {}
end

local function StackContext()
  return setmetatable({}, scontext_meta):init()
end
