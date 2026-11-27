--[[
  Cheat Engine Model Context Protocol (MCP) Server
  Pure Cheat Engine Lua implementation (no external dependencies, no Python)
  Implements Model Context Protocol (MCP) specification version 2024-11-05.

  Supports dual transports:
    1. HTTP / Server-Sent Events (SSE): for Claude Desktop, Cursor, and web clients (http://127.0.0.1:20000/sse)
    2. Raw TCP line-delimited JSON-RPC stream: for direct socket clients, CLI bridges, and stdio-to-tcp proxies
]]

local jsonparser = require 'json'

-- Global server table
MCPServer = MCPServer or {}
MCPServer.version = "1.0.0"
MCPServer.protocolVersion = "2024-11-05"
MCPServer.port = 20000
MCPServer.localhostOnly = true
MCPServer.autoStart = false
MCPServer.running = false
MCPServer.serverTerminated = false
MCPServer.serverSocket = nil
MCPServer.serverThread = nil
MCPServer.heartbeatThread = nil
MCPServer.clients = {}
MCPServer.sseSessions = {}
MCPServer.tools = {}
MCPServer.scanners = {}
MCPServer.watchpoints = {}
MCPServer.lockCS = createCriticalSection()

-------------------------------------------------------------------------------
-- Helper Functions
-------------------------------------------------------------------------------

local function makeArray(t)
  t = t or {}
  setmetatable(t, {isArray = true})
  return t
end

local function runOnMainThread(fn)
  if inMainThread and inMainThread() then
    return fn()
  else
    return synchronize(fn)
  end
end

local function safeHex(addr)
  if addr == nil then return "0" end
  if type(addr) == "number" then
    return string.format("0x%X", addr)
  end
  return tostring(addr)
end

local function resolveAddress(addr)
  if addr == nil then return nil end
  if type(addr) == "number" then return addr end
  local str = tostring(addr):trim()
  local a = getAddressSafe(str)
  if a then return a end
  -- Try tonumber with hex
  if str:sub(1, 2) == "0x" or str:sub(1, 2) == "0X" then
    return tonumber(str:sub(3), 16)
  end
  return tonumber(str, 16) or tonumber(str)
end

local function byteTableToHexString(bytes)
  if not bytes or #bytes == 0 then return "" end
  local parts = {}
  for i = 1, #bytes do
    parts[i] = string.format("%02X", bytes[i])
  end
  return table.concat(parts, " ")
end

local function hexStringToByteTable(hexStr)
  local bytes = {}
  -- Remove 0x prefix if any, spaces, dashes, commas
  local clean = hexStr:gsub("0[xX]", ""):gsub("[%s%-,]", "")
  for i = 1, #clean, 2 do
    local b = tonumber(clean:sub(i, i + 1), 16)
    if b then
      table.insert(bytes, b)
    end
  end
  return bytes
end

local function generateSessionId()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  math.randomseed(os.time() + (os.clock() * 1000000 % 100000))
  return string.gsub(template, "[xy]", function(c)
    local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format("%x", v)
  end)
end

local function detectConfiguredPort()
  local home = os.getenv("HOME") or os.getenv("USERPROFILE")
  if home then
    local path = home .. "/.gemini/config/mcp_config.json"
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      if content then
        local p = content:match("http://127%.0%.0%.1:(%d+)/sse") or content:match("http://localhost:(%d+)/sse")
        if p and tonumber(p) then
          return tonumber(p)
        end
      end
    end
  end
  return nil
end

local function updateAntigravityConfig(port)
  local home = os.getenv("HOME") or os.getenv("USERPROFILE")
  if not home then return false end
  local dir = home .. "/.gemini/config"
  local path = dir .. "/mcp_config.json"

  local ok, res = pcall(function()
    local cfg = {
      mcpServers = {
        cheatengine = {
          serverUrl = string.format("http://127.0.0.1:%d/sse", port)
        }
      }
    }
    local f = io.open(path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      if content and content:trim() ~= "" then
        local decOk, existing = pcall(jsonparser.decode, content)
        if decOk and type(existing) == "table" then
          existing.mcpServers = existing.mcpServers or {}
          existing.mcpServers.cheatengine = existing.mcpServers.cheatengine or {}
          existing.mcpServers.cheatengine.serverUrl = string.format("http://127.0.0.1:%d/sse", port)
          cfg = existing
        end
      end
    end
    local fOut = io.open(path, "w")
    if fOut then
      fOut:write(jsonparser.encode(cfg))
      fOut:close()
      return true
    end
    return false
  end)
  return ok and res
end

-------------------------------------------------------------------------------
-- Tool Registration & Dynamic AITools Bridge
-------------------------------------------------------------------------------

function MCPServer.registerTool(name, description, properties, required, func)
  if not name or name == "" then
    error("Tool name cannot be empty")
  end

  local cleanProps = {}
  if properties then
    for k, v in pairs(properties) do
      local p = {}
      for pk, pv in pairs(v) do
        if pk == "type" and type(pv) == "string" then
          p[pk] = pv:lower() -- JSON Schema requires lowercase (string, integer, etc.)
        else
          p[pk] = pv
        end
      end
      cleanProps[k] = p
    end
  end

  local req = {}
  if required then
    for _, r in ipairs(required) do
      table.insert(req, r)
    end
  end
  makeArray(req)

  MCPServer.tools[name] = {
    name = name,
    description = description or "",
    inputSchema = {
      type = "object",
      properties = cleanProps,
      required = req
    },
    func = func
  }
end

function MCPServer.importAIToolsBridge()
  if _G.aitools and type(_G.aitools) == "table" then
    for name, t in pairs(_G.aitools) do
      if MCPServer.tools[name] == nil and t.functionToCall then
        local props = {}
        if t.parameters and t.parameters.properties then
          for pk, pv in pairs(t.parameters.properties) do
            local p = {}
            for field, val in pairs(pv) do
              if field == "type" and type(val) == "string" then
                p[field] = val:lower()
              else
                p[field] = val
              end
            end
            props[pk] = p
          end
        end

        local req = {}
        if t.parameters and t.parameters.required then
          for _, r in ipairs(t.parameters.required) do
            table.insert(req, r)
          end
        end
        makeArray(req)

        MCPServer.tools[name] = {
          name = name,
          description = t.description or "",
          inputSchema = {
            type = "object",
            properties = props,
            required = req
          },
          func = function(args)
            return t.functionToCall(args)
          end
        }
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Built-in Cheat Engine Tools
-------------------------------------------------------------------------------

-- 1. get_opened_process
MCPServer.registerTool(
  "get_opened_process",
  "Returns information about the currently opened target process in Cheat Engine.",
  {},
  {},
  function(args)
    local pid = getOpenedProcessID()
    local procName = process
    local is64 = targetIs64Bit and targetIs64Bit() or false
    local isArm = targetIsArm and targetIsArm() or false
    local isX86 = targetIsX86 and targetIsX86() or true
    return {
      processID = pid,
      processName = procName or (pid ~= 0 and ("PID " .. pid) or nil),
      isOpened = (pid ~= 0 and pid ~= nil),
      is64Bit = is64,
      architecture = isArm and "arm" or (isX86 and "x86" or "unknown")
    }
  end
)

-- 2. open_process
MCPServer.registerTool(
  "open_process",
  "Opens / attaches Cheat Engine to a target process by name or PID.",
  {
    process = { type = "string", description = "The name of the executable (e.g. 'game.exe') or the integer Process ID." }
  },
  { "process" },
  function(args)
    local target = args.process
    local pid = tonumber(target)
    if pid then
      openProcess(pid)
    else
      openProcess(tostring(target))
    end
    local curPid = getOpenedProcessID()
    if curPid ~= 0 and curPid ~= nil then
      return { success = true, processID = curPid, processName = process }
    else
      return { success = false, error = "Failed to open process: " .. tostring(target) }
    end
  end
)

-- 3. get_process_list
MCPServer.registerTool(
  "get_process_list",
  "Lists currently running processes on the system with their Process IDs and names.",
  {
    filter = { type = "string", description = "Optional filter substring to search for in process names." }
  },
  {},
  function(args)
    local filter = args.filter and tostring(args.filter):lower() or nil
    local pl = getProcesslist()
    local result = {}
    if pl then
      for pid, name in pairs(pl) do
        if not filter or tostring(name):lower():find(filter, 1, true) then
          table.insert(result, { pid = pid, name = name })
        end
      end
    end
    table.sort(result, function(a, b) return a.name:lower() < b.name:lower() end)
    makeArray(result)
    return { processes = result, count = #result }
  end
)

-- 4. pause_process / unpause_process
MCPServer.registerTool("pause_process", "Freezes / pauses the target process execution.", {}, {}, function(args)
  pause()
  return { status = "paused" }
end)

MCPServer.registerTool("unpause_process", "Resumes / unpauses the target process execution.", {}, {}, function(args)
  unpause()
  return { status = "resumed" }
end)

-- 5. read_memory
MCPServer.registerTool(
  "read_memory",
  "Reads a typed value (byte, int16, int32, int64, float, double, pointer, string) from an address or expression.",
  {
    address = { type = "string", description = "Target memory address or expression (e.g. '0x12345678', 'game.exe+0x1000', '[0x1234]+0x10')." },
    type = {
      type = "string",
      description = "Variable data type: 'byte', 'int16', 'int32', 'int64', 'float', 'double', 'pointer', 'string'.",
      enum = { "byte", "int16", "int32", "int64", "float", "double", "pointer", "string" }
    },
    length = { type = "integer", description = "For 'string' type: maximum number of characters to read (default: 50)." },
    is_wide = { type = "boolean", description = "For 'string' type: set true for wide UTF-16 string (default: false)." }
  },
  { "address", "type" },
  function(args)
    local addr = resolveAddress(args.address)
    if not addr then
      return { error = "Cannot resolve address: " .. tostring(args.address) }
    end

    local t = (args.type or "int32"):lower()
    local val = nil

    if t == "byte" then
      val = readByte(addr)
    elseif t == "int16" or t == "word" or t == "short" then
      val = readSmallInteger(addr)
    elseif t == "int32" or t == "int" or t == "dword" then
      val = readInteger(addr)
    elseif t == "int64" or t == "qword" then
      local qw = readQword(addr)
      val = qw and string.format("0x%X", qw) or nil
    elseif t == "float" or t == "single" then
      val = readFloat(addr)
    elseif t == "double" then
      val = readDouble(addr)
    elseif t == "pointer" then
      local ptr = readPointer(addr)
      val = ptr and string.format("0x%X", ptr) or nil
    elseif t == "string" then
      local len = tonumber(args.length) or 50
      local isWide = args.is_wide or false
      val = readString(addr, len, isWide)
    else
      return { error = "Unsupported type: " .. tostring(t) }
    end

    if val == nil then
      return { error = "Memory unreadable at address " .. safeHex(addr), address = safeHex(addr) }
    end

    return {
      address = safeHex(addr),
      type = t,
      value = val
    }
  end
)

-- 6. read_bytes
MCPServer.registerTool(
  "read_bytes",
  "Reads a sequence of raw bytes from a memory address or expression.",
  {
    address = { type = "string", description = "Address or expression to start reading from." },
    count = { type = "integer", description = "Number of bytes to read." }
  },
  { "address", "count" },
  function(args)
    local addr = resolveAddress(args.address)
    if not addr then return { error = "Invalid address: " .. tostring(args.address) } end
    local count = tonumber(args.count) or 16
    if count <= 0 or count > 65536 then
      return { error = "Count out of range (1-65536)" }
    end

    local bytes = readBytes(addr, count, true)
    if not bytes then
      return { error = "Failed to read memory at " .. safeHex(addr) }
    end

    makeArray(bytes)
    return {
      address = safeHex(addr),
      count = #bytes,
      hex = byteTableToHexString(bytes),
      bytes = bytes
    }
  end
)

-- 7. write_memory
MCPServer.registerTool(
  "write_memory",
  "Writes a typed value (byte, int16, int32, int64, float, double, pointer, string) to a memory address.",
  {
    address = { type = "string", description = "Target memory address or expression." },
    type = {
      type = "string",
      description = "Variable data type: 'byte', 'int16', 'int32', 'int64', 'float', 'double', 'pointer', 'string'.",
      enum = { "byte", "int16", "int32", "int64", "float", "double", "pointer", "string" }
    },
    value = { type = "string", description = "Value to write (formatted appropriately for the type)." },
    is_wide = { type = "boolean", description = "For 'string' type: set true for wide UTF-16 string." }
  },
  { "address", "type", "value" },
  function(args)
    local addr = resolveAddress(args.address)
    if not addr then return { error = "Invalid address: " .. tostring(args.address) } end

    local t = (args.type or "int32"):lower()
    local valStr = tostring(args.value)
    local ok = false

    if t == "byte" then
      ok = writeByte(addr, tonumber(valStr))
    elseif t == "int16" or t == "word" or t == "short" then
      ok = writeSmallInteger(addr, tonumber(valStr))
    elseif t == "int32" or t == "int" or t == "dword" then
      ok = writeInteger(addr, tonumber(valStr))
    elseif t == "int64" or t == "qword" then
      local n = tonumber(valStr) or tonumber(valStr, 16)
      ok = writeQword(addr, n)
    elseif t == "float" or t == "single" then
      ok = writeFloat(addr, tonumber(valStr))
    elseif t == "double" then
      ok = writeDouble(addr, tonumber(valStr))
    elseif t == "pointer" then
      local ptr = resolveAddress(valStr)
      ok = writePointer(addr, ptr)
    elseif t == "string" then
      local isWide = args.is_wide or false
      ok = writeString(addr, valStr, isWide)
    else
      return { error = "Unsupported type: " .. tostring(t) }
    end

    if ok then
      return { success = true, address = safeHex(addr), type = t, value = valStr }
    else
      return { success = false, error = "Write failed at " .. safeHex(addr) }
    end
  end
)

-- 8. write_bytes
MCPServer.registerTool(
  "write_bytes",
  "Writes raw bytes to a memory address. Bytes can be a hex string ('90 90 90') or array of integers.",
  {
    address = { type = "string", description = "Target memory address or expression." },
    bytes = { type = "string", description = "Hexadecimal byte string (e.g. '90 90 90' or '909090')." }
  },
  { "address", "bytes" },
  function(args)
    local addr = resolveAddress(args.address)
    if not addr then return { error = "Invalid address: " .. tostring(args.address) } end

    local byteTable
    if type(args.bytes) == "table" then
      byteTable = args.bytes
    else
      byteTable = hexStringToByteTable(tostring(args.bytes))
    end

    if #byteTable == 0 then
      return { error = "No valid bytes provided" }
    end

    local ok = writeBytes(addr, byteTable)
    if ok then
      return { success = true, address = safeHex(addr), count = #byteTable, hex = byteTableToHexString(byteTable) }
    else
      return { success = false, error = "Failed to write bytes at " .. safeHex(addr) }
    end
  end
)

-- 9. resolve_pointer_chain
MCPServer.registerTool(
  "resolve_pointer_chain",
  "Resolves a multilevel pointer chain: base address + list of offsets.",
  {
    base_address = { type = "string", description = "Base address or module expression (e.g. 'game.exe+0x1234')." },
    offsets = {
      type = "array",
      items = { type = "string" },
      description = "List of offsets to dereference (e.g. ['0x10', '0x20', '0x8'])."
    }
  },
  { "base_address", "offsets" },
  function(args)
    local cur = resolveAddress(args.base_address)
    if not cur then return { error = "Invalid base address: " .. tostring(args.base_address) } end

    local steps = {}
    table.insert(steps, { step = 0, address = safeHex(cur), description = "Base Address" })

    local offsets = args.offsets or {}
    for i = 1, #offsets do
      local offStr = tostring(offsets[i]):trim()
      local off = tonumber(offStr, 16) or tonumber(offStr) or 0

      local ptr = readPointer(cur)
      if ptr == nil or ptr == 0 then
        return {
          error = "Null or invalid pointer at step " .. i .. " (address: " .. safeHex(cur) .. ")",
          steps = steps,
          resolvedAtStep = i - 1
        }
      end

      cur = ptr + off
      table.insert(steps, {
        step = i,
        pointerValue = safeHex(ptr),
        offset = safeHex(off),
        targetAddress = safeHex(cur)
      })
    end

    makeArray(steps)
    return {
      success = true,
      finalAddress = safeHex(cur),
      steps = steps
    }
  end
)

-- 10. create_scan / refine_scan / get_scan_results / free_scan
local varTypeMap = {
  byte = vtByte,
  word = vtWord,
  ["2bytes"] = vtWord,
  dword = vtDword,
  ["4bytes"] = vtDword,
  qword = vtQword,
  ["8bytes"] = vtQword,
  float = vtSingle,
  single = vtSingle,
  double = vtDouble,
  string = vtString,
  bytearray = vtByteArray,
  aob = vtByteArray,
  all = vtAll
}

local scanOptionMap = {
  exact = soExactValue,
  bigger = soBiggerThan,
  smaller = soSmallerThan,
  between = soValueBetween,
  unknown = soUnknownValue,
  increased = soIncreasedValue,
  decreased = soDecreasedValue,
  changed = soChanged,
  unchanged = soUnchanged,
  increased_by = soIncreasedValueBy,
  decreased_by = soDecreasedValueBy
}

MCPServer.registerTool(
  "create_scan",
  "Starts a new memory scan in the target process. Returns a scan_id for refining or reading results.",
  {
    value = { type = "string", description = "Value to scan for (omit or empty for unknown initial value scan)." },
    value2 = { type = "string", description = "Secondary value for 'between' scan." },
    var_type = {
      type = "string",
      description = "Type: 'byte', '2bytes', '4bytes', '8bytes', 'float', 'double', 'string', 'bytearray', 'all'.",
      default = "4bytes"
    },
    scan_option = {
      type = "string",
      description = "Option: 'exact', 'bigger', 'smaller', 'between', 'unknown'.",
      default = "exact"
    },
    start_address = { type = "string", description = "Start address (default: 0)." },
    stop_address = { type = "string", description = "Stop address (default: 0x7FFFFFFFFFFFFFFF)." }
  },
  {},
  function(args)
    local ms = createMemScan()
    if not ms then return { error = "Failed to create memory scanner" } end

    local vt = varTypeMap[(args.var_type or "4bytes"):lower()] or vtDword
    local so = scanOptionMap[(args.scan_option or "exact"):lower()] or soExactValue

    local startAddr = args.start_address and resolveAddress(args.start_address) or 0
    local stopAddr = args.stop_address and resolveAddress(args.stop_address) or 0x7FFFFFFFFFFFFFFF

    local val = args.value and tostring(args.value) or ""
    local val2 = args.value2 and tostring(args.value2) or ""

    if (args.scan_option or ""):lower() == "unknown" or val == "" then
      so = soUnknownValue
    end

    ms.firstScan(so, vt, rtRounded, val, val2, startAddr, stopAddr, "+W-C", fsmNotAligned, "4", true, false, false, false)
    ms.waitTillDone()

    local scanId = #MCPServer.scanners + 1
    MCPServer.scanners[scanId] = { memScan = ms, varType = vt }

    local fl = createFoundList(ms)
    fl.initialize()
    local count = fl.Count

    local samples = {}
    local sampleCount = math.min(count, 10)
    for i = 0, sampleCount - 1 do
      table.insert(samples, { address = fl.Address[i], value = fl.Value[i] })
    end
    fl.deinitialize()
    fl.destroy()

    makeArray(samples)
    return {
      scan_id = scanId,
      found_count = count,
      sample_results = samples
    }
  end
)

MCPServer.registerTool(
  "refine_scan",
  "Filters / refines an existing memory scan with next scan criteria.",
  {
    scan_id = { type = "integer", description = "Scan ID returned from create_scan." },
    scan_option = {
      type = "string",
      description = "'exact', 'increased', 'decreased', 'changed', 'unchanged', 'bigger', 'smaller', 'between', 'increased_by', 'decreased_by'."
    },
    value = { type = "string", description = "Value to scan for." },
    value2 = { type = "string", description = "Secondary value for 'between'." }
  },
  { "scan_id", "scan_option" },
  function(args)
    local item = MCPServer.scanners[args.scan_id]
    if not item or not item.memScan then
      return { error = "Invalid scan_id: " .. tostring(args.scan_id) }
    end

    local ms = item.memScan
    local so = scanOptionMap[(args.scan_option or "exact"):lower()] or soExactValue
    local val = args.value and tostring(args.value) or ""
    local val2 = args.value2 and tostring(args.value2) or ""

    ms.nextScan(so, rtRounded, nil, val, val2, false, false, false, false, false, false)
    ms.waitTillDone()

    local fl = createFoundList(ms)
    fl.initialize()
    local count = fl.Count

    local samples = {}
    local sampleCount = math.min(count, 10)
    for i = 0, sampleCount - 1 do
      table.insert(samples, { address = fl.Address[i], value = fl.Value[i] })
    end
    fl.deinitialize()
    fl.destroy()

    makeArray(samples)
    return {
      scan_id = args.scan_id,
      found_count = count,
      sample_results = samples
    }
  end
)

MCPServer.registerTool(
  "get_scan_results",
  "Retrieves found addresses and values from a completed memory scan.",
  {
    scan_id = { type = "integer", description = "Scan ID." },
    start_index = { type = "integer", description = "Start index (default 0)." },
    count = { type = "integer", description = "Max results to return (default 50, max 500)." }
  },
  { "scan_id" },
  function(args)
    local item = MCPServer.scanners[args.scan_id]
    if not item or not item.memScan then
      return { error = "Invalid scan_id: " .. tostring(args.scan_id) }
    end

    local ms = item.memScan
    local fl = createFoundList(ms)
    fl.initialize()
    local total = fl.Count
    local startIndex = tonumber(args.start_index) or 0
    local maxCount = math.min(tonumber(args.count) or 50, 500)

    local results = {}
    for i = startIndex, math.min(startIndex + maxCount - 1, total - 1) do
      table.insert(results, { index = i, address = fl.Address[i], value = fl.Value[i] })
    end
    fl.deinitialize()
    fl.destroy()

    makeArray(results)
    return {
      scan_id = args.scan_id,
      total_count = total,
      returned_count = #results,
      results = results
    }
  end
)

MCPServer.registerTool(
  "free_scan",
  "Frees and cleans up a memory scan object.",
  {
    scan_id = { type = "integer", description = "Scan ID to free." }
  },
  { "scan_id" },
  function(args)
    local item = MCPServer.scanners[args.scan_id]
    if item and item.memScan then
      item.memScan.destroy()
      MCPServer.scanners[args.scan_id] = nil
      return { success = true }
    end
    return { error = "Scan not found" }
  end
)

-- 11. Disassembly & Assembly
MCPServer.registerTool(
  "disassemble",
  "Disassembles instructions at a given memory address or expression.",
  {
    address = { type = "string", description = "Starting address or symbol expression." },
    count = { type = "integer", description = "Number of instructions to disassemble (default 10, max 100)." }
  },
  { "address" },
  function(args)
    local addr = resolveAddress(args.address)
    if not addr then return { error = "Invalid address: " .. tostring(args.address) } end

    local count = math.min(tonumber(args.count) or 10, 100)
    local instructions = {}
    local cur = addr

    local d = createDisassembler()
    d.showSymbols = true
    d.showModules = true

    for i = 1, count do
      local s = d.disassemble(cur)
      local lastData = d.LastDisassembleData
      local size = #lastData.bytes
      local hexBytes = byteTableToHexString(lastData.bytes)

      table.insert(instructions, {
        address = safeHex(cur),
        addressString = getNameFromAddress(cur, true, true, false),
        bytes = hexBytes,
        opcode = lastData.opcode,
        parameters = lastData.parameters,
        full = lastData.opcode .. " " .. lastData.parameters,
        size = size
      })

      cur = cur + (size > 0 and size or 1)
    end

    d.destroy()
    makeArray(instructions)
    return {
      start_address = safeHex(addr),
      count = #instructions,
      instructions = instructions
    }
  end
)

MCPServer.registerTool(
  "assemble",
  "Assembles an instruction string. If address is provided, writes it to memory.",
  {
    instruction = { type = "string", description = "Assembly instruction (e.g. 'nop', 'mov eax, 1')." },
    address = { type = "string", description = "Optional target address to assemble at and write to." }
  },
  { "instruction" },
  function(args)
    local addr = args.address and resolveAddress(args.address) or nil
    local byteTable = assemble(args.instruction, addr)
    if not byteTable or #byteTable == 0 then
      return { error = "Failed to assemble: " .. tostring(args.instruction) }
    end

    makeArray(byteTable)
    return {
      success = true,
      instruction = args.instruction,
      address = addr and safeHex(addr) or nil,
      bytes = byteTable,
      hex = byteTableToHexString(byteTable)
    }
  end
)

MCPServer.registerTool(
  "auto_assemble",
  "Executes a Cheat Engine Auto Assembler (AA) script. Supports hooks, code caves, allocs, and symbol registrations.",
  {
    script = { type = "string", description = "Auto Assembler script content." }
  },
  { "script" },
  function(args)
    local ok, disableInfo, warnings = autoAssemble(args.script)
    if ok then
      return {
        success = true,
        warnings = warnings
      }
    else
      return {
        success = false,
        error = tostring(disableInfo)
      }
    end
  end
)

MCPServer.registerTool(
  "check_auto_assemble_syntax",
  "Checks the syntax of an Auto Assembler script without executing it.",
  {
    script = { type = "string", description = "Auto Assembler script content." }
  },
  { "script" },
  function(args)
    local ok, err = autoAssembleCheck(args.script, true, false)
    return {
      valid = ok,
      error = not ok and tostring(err) or nil
    }
  end
)

-- 12. Modules & Symbols
MCPServer.registerTool(
  "enum_modules",
  "Lists all loaded modules (DLLs/executables) in the target process with base address and size.",
  {},
  {},
  function(args)
    local mods = enumModules()
    local result = {}
    if mods then
      for i, m in ipairs(mods) do
        table.insert(result, {
          name = m.Name,
          address = safeHex(m.Address),
          size = m.Size or 0,
          path = m.PathToFile
        })
      end
    end
    makeArray(result)
    return { modules = result, count = #result }
  end
)

MCPServer.registerTool(
  "resolve_symbol",
  "Resolves a symbol or expression to its memory address (e.g. 'kernel32.dll!CreateFileW', 'game.exe+0x1000').",
  {
    symbol = { type = "string", description = "Symbol name or expression." }
  },
  { "symbol" },
  function(args)
    local addr = getAddressSafe(args.symbol)
    if addr then
      return {
        symbol = args.symbol,
        address = safeHex(addr),
        decimal = addr
      }
    else
      return { error = "Unable to resolve symbol: " .. tostring(args.symbol) }
    end
  end
)

MCPServer.registerTool(
  "get_symbol_from_address",
  "Retrieves symbolic or module+offset name for a memory address.",
  {
    address = { type = "string", description = "Memory address to inspect." }
  },
  { "address" },
  function(args)
    local addr = resolveAddress(args.address)
    if not addr then return { error = "Invalid address: " .. tostring(args.address) } end
    local name = getNameFromAddress(addr, true, true, false)
    return {
      address = safeHex(addr),
      name = name
    }
  end
)

MCPServer.registerTool(
  "get_function_range",
  "Estimates the start and end address of the function enclosing the given address.",
  {
    address = { type = "string", description = "Address within the function." }
  },
  { "address" },
  function(args)
    local addr = resolveAddress(args.address)
    if not addr then return { error = "Invalid address: " .. tostring(args.address) } end
    local startAddr, stopAddr = getFunctionRange(addr)
    if startAddr and stopAddr then
      return {
        address = safeHex(addr),
        start = safeHex(startAddr),
        ["stop"] = safeHex(stopAddr),
        size = stopAddr - startAddr
      }
    else
      return { error = "Could not determine function range for " .. safeHex(addr) }
    end
  end
)

-- 13. Address List / Cheat Table Records
MCPServer.registerTool(
  "get_address_list",
  "Retrieves all records from Cheat Engine's address list (the cheat table).",
  {},
  {},
  function(args)
    local al = getAddressList()
    local records = {}
    for i = 0, al.Count - 1 do
      local mr = al.MemoryRecord[i]
      table.insert(records, {
        id = mr.ID,
        description = mr.Description,
        address = mr.AddressString,
        currentAddress = safeHex(mr.CurrentAddress),
        varType = mr.VarType,
        value = mr.Value,
        active = mr.Active,
        isScript = (mr.VarType == "vtAutoAssembler")
      })
    end
    makeArray(records)
    return { count = #records, records = records }
  end
)

MCPServer.registerTool(
  "create_memory_record",
  "Creates a new record in Cheat Engine's address list (cheat table).",
  {
    description = { type = "string", description = "Description / label for the entry." },
    address = { type = "string", description = "Address or pointer expression." },
    var_type = {
      type = "string",
      description = "'byte', '2bytes', '4bytes', '8bytes', 'float', 'double', 'string', 'autoassembler'.",
      default = "4bytes"
    },
    script = { type = "string", description = "Auto Assembler script if var_type is autoassembler." },
    active = { type = "boolean", description = "Whether to activate / freeze the record immediately." }
  },
  { "description" },
  function(args)
    local al = getAddressList()
    local mr = al.createMemoryRecord()
    mr.Description = args.description or "New Record"

    local vt = (args.var_type or "4bytes"):lower()
    if vt == "autoassembler" or args.script then
      mr.VarType = "vtAutoAssembler"
      if args.script then mr.Script = args.script end
    else
      mr.Address = args.address or "0"
      if vt == "byte" then mr.VarType = "vtByte"
      elseif vt == "2bytes" or vt == "word" then mr.VarType = "vtWord"
      elseif vt == "4bytes" or vt == "dword" then mr.VarType = "vtDword"
      elseif vt == "8bytes" or vt == "qword" then mr.VarType = "vtQword"
      elseif vt == "float" then mr.VarType = "vtSingle"
      elseif vt == "double" then mr.VarType = "vtDouble"
      elseif vt == "string" then mr.VarType = "vtString"
      end
    end

    if args.active ~= nil then
      mr.Active = args.active
    end

    return {
      success = true,
      id = mr.ID,
      description = mr.Description
    }
  end
)

MCPServer.registerTool(
  "set_memory_record",
  "Updates an existing record in the address list (value, description, address, or active state).",
  {
    id = { type = "integer", description = "Memory Record ID." },
    value = { type = "string", description = "New value to write." },
    description = { type = "string", description = "New description." },
    address = { type = "string", description = "New address expression." },
    active = { type = "boolean", description = "Activate (freeze) or deactivate (unfreeze)." }
  },
  { "id" },
  function(args)
    local al = getAddressList()
    local mr = al.getMemoryRecordByID(args.id)
    if not mr then return { error = "Record ID not found: " .. tostring(args.id) } end

    if args.description then mr.Description = args.description end
    if args.address then mr.Address = args.address end
    if args.value then mr.Value = tostring(args.value) end
    if args.active ~= nil then mr.Active = args.active end

    return {
      success = true,
      id = mr.ID,
      description = mr.Description,
      value = mr.Value,
      active = mr.Active
    }
  end
)

MCPServer.registerTool(
  "delete_memory_record",
  "Deletes a record from the address list by ID.",
  {
    id = { type = "integer", description = "Memory Record ID." }
  },
  { "id" },
  function(args)
    local al = getAddressList()
    local mr = al.getMemoryRecordByID(args.id)
    if not mr then return { error = "Record ID not found: " .. tostring(args.id) } end
    mr.destroy()
    return { success = true, deleted_id = args.id }
  end
)

-- 14. Watchpoints
MCPServer.registerTool(
  "start_watchpoint",
  "Attaches debugger and monitors memory accesses/writes to an address (Cheat Engine 'Find what writes/accesses this address').",
  {
    address = { type = "string", description = "Address to watch." },
    size = { type = "integer", description = "Size in bytes (1, 2, 4, 8). Default: 1." },
    watch_type = { type = "string", description = "'write' or 'access'. Default: 'write'.", enum = { "write", "access" } }
  },
  { "address" },
  function(args)
    local addr = resolveAddress(args.address)
    if not addr then return { error = "Invalid address: " .. tostring(args.address) } end

    local size = tonumber(args.size) or 1
    local wtype = (args.watch_type == "access") and bptAccess or bptWrite

    local wpId = #MCPServer.watchpoints + 1
    local wpData = {
      id = wpId,
      address = addr,
      size = size,
      hits = {},
      stopped = false
    }
    MCPServer.watchpoints[wpId] = wpData

    local ok, bpId = debug_setBreakpoint(addr, size, wtype, function()
      local ctx = debug_getCurrentContextTable()
      local ip = nil
      if ctx then
        if targetIsX86() then
          ip = targetIs64Bit() and ctx.RIP or ctx.EIP
        elseif targetIsArm() then
          ip = ctx.PC
        end
      end

      if ip then
        local hitKey = safeHex(ip)
        if wpData.hits[hitKey] then
          wpData.hits[hitKey].count = wpData.hits[hitKey].count + 1
        else
          local d = createDisassembler()
          d.showSymbols = true
          d.showModules = true
          d.disassemble(ip)
          local op = d.LastDisassembleData.opcode .. " " .. d.LastDisassembleData.parameters
          d.destroy()

          wpData.hits[hitKey] = {
            instructionAddress = hitKey,
            instruction = op,
            count = 1,
            context = ctx
          }
        end
      end
    end)

    if ok then
      wpData.breakpointId = bpId
      return { success = true, watchpoint_id = wpId, address = safeHex(addr) }
    else
      MCPServer.watchpoints[wpId] = nil
      return { error = "Failed to set watchpoint: " .. tostring(bpId) }
    end
  end
)

MCPServer.registerTool(
  "get_watchpoint_results",
  "Retrieves instructions that have hit an active watchpoint, with hit counts and register values.",
  {
    watchpoint_id = { type = "integer", description = "Watchpoint ID." }
  },
  { "watchpoint_id" },
  function(args)
    local wp = MCPServer.watchpoints[args.watchpoint_id]
    if not wp then return { error = "Invalid watchpoint_id: " .. tostring(args.watchpoint_id) } end

    local list = {}
    for _, hit in pairs(wp.hits) do
      local regSummary = {}
      if hit.context then
        for k, v in pairs(hit.context) do
          if type(v) == "number" then
            regSummary[k] = safeHex(v)
          end
        end
      end
      table.insert(list, {
        instructionAddress = hit.instructionAddress,
        instruction = hit.instruction,
        hitCount = hit.count,
        registers = regSummary
      })
    end
    makeArray(list)
    return { watchpoint_id = args.watchpoint_id, hits = list, count = #list }
  end
)

MCPServer.registerTool(
  "stop_watchpoint",
  "Stops and removes an active watchpoint.",
  {
    watchpoint_id = { type = "integer", description = "Watchpoint ID." }
  },
  { "watchpoint_id" },
  function(args)
    local wp = MCPServer.watchpoints[args.watchpoint_id]
    if not wp then return { error = "Invalid watchpoint_id" } end
    if wp.breakpointId then
      debug_removeBreakpointByID(wp.breakpointId)
    end
    wp.stopped = true
    return { success = true, watchpoint_id = args.watchpoint_id }
  end
)

-- 15. Execute Lua
MCPServer.registerTool(
  "execute_lua",
  "Executes arbitrary Lua code inside Cheat Engine with full access to Cheat Engine's Lua API. Captures printed output and returned results.",
  {
    code = { type = "string", description = "Lua code to execute." }
  },
  { "code" },
  function(args)
    local captured = {}
    local oldPrint = print
    print = function(...)
      local n = select('#', ...)
      local parts = {}
      for i = 1, n do
        parts[i] = tostring(select(i, ...))
      end
      table.insert(captured, table.concat(parts, "\t"))
      if oldPrint then oldPrint(...) end
    end

    local f, ferr = loadstring(args.code)
    if not f then
      print = oldPrint
      return { success = false, error = "Syntax error: " .. tostring(ferr), output = table.concat(captured, "\n") }
    end

    local ok, res = try(f)
    print = oldPrint

    return {
      success = ok,
      result = ok and (res ~= nil and tostring(res) or nil) or nil,
      error = not ok and tostring(res) or nil,
      output = #captured > 0 and table.concat(captured, "\n") or nil
    }
  end
)

-------------------------------------------------------------------------------
-- MCP Protocol Handling (JSON-RPC 2.0)
-------------------------------------------------------------------------------

local function createResponse(id, result)
  return {
    jsonrpc = "2.0",
    id = id,
    result = result or {}
  }
end

local function createError(id, code, message, data)
  local err = { code = code, message = message }
  if data ~= nil then err.data = data end
  return {
    jsonrpc = "2.0",
    id = id,
    error = err
  }
end

local function handleJsonRpc(req)
  if type(req) ~= "table" then
    return createError(nil, -32600, "Invalid Request")
  end

  local id = req.id
  local method = req.method

  if not method or type(method) ~= "string" then
    return createError(id, -32600, "Invalid Request: method missing")
  end

  -- In JSON-RPC 2.0, requests without an id are notifications and must not receive a response
  if id == nil then
    return nil
  end

  -- Initialize
  if method == "initialize" then
    return createResponse(id, {
      protocolVersion = MCPServer.protocolVersion,
      capabilities = {
        tools = { listChanged = true },
        resources = { subscribe = false, listChanged = true },
        prompts = { listChanged = true },
        logging = {}
      },
      serverInfo = {
        name = "cheat-engine-mcp",
        version = MCPServer.version
      },
      instructions = "Cheat Engine MCP Server enables AI models to interact directly with Cheat Engine. It provides tools for inspecting processes, reading/writing memory, scanning memory, disassembling and assembling code, managing Cheat Engine address lists (cheat tables), debugging memory with watchpoints, and executing Cheat Engine Lua scripts."
    })
  end

  -- Ping
  if method == "ping" then
    return createResponse(id, {})
  end

  -- Tools List
  if method == "tools/list" then
    MCPServer.importAIToolsBridge()
    local toolList = {}
    for name, t in pairs(MCPServer.tools) do
      table.insert(toolList, {
        name = t.name,
        description = t.description,
        inputSchema = t.inputSchema
      })
    end
    table.sort(toolList, function(a, b) return a.name < b.name end)
    makeArray(toolList)
    return createResponse(id, { tools = toolList })
  end

  -- Tools Call
  if method == "tools/call" then
    local params = req.params or {}
    local toolName = params.name
    local toolArgs = params.arguments or {}

    MCPServer.importAIToolsBridge()
    local tool = MCPServer.tools[toolName]
    if not tool then
      return createError(id, -32601, "Tool not found: " .. tostring(toolName))
    end

    local execOk, execResult
    if toolName == "execute_lua" then
      -- execute_lua runs directly in the background worker thread.
      -- Scripts that need GUI access must call synchronize(...) themselves (AGENTS.md Rule 6).
      execOk, execResult = try(tool.func, toolArgs)
    else
      execOk, execResult = try(function()
        return runOnMainThread(function()
          return tool.func(toolArgs)
        end)
      end)
    end

    if not execOk then
      return createResponse(id, {
        content = makeArray({
          { type = "text", text = "Execution error: " .. tostring(execResult) }
        }),
        isError = true
      })
    end

    if type(execResult) == "table" and execResult.error then
      return createResponse(id, {
        content = makeArray({
          { type = "text", text = "Error: " .. tostring(execResult.error) }
        }),
        isError = true
      })
    end

    local outputText
    if type(execResult) == "table" then
      local okEncode, jsonText = pcall(jsonparser.encode, execResult)
      outputText = okEncode and jsonText or tostring(execResult)
    else
      outputText = tostring(execResult or "Success")
    end

    return createResponse(id, {
      content = makeArray({
        { type = "text", text = outputText }
      }),
      isError = false
    })
  end

  -- Resources List
  if method == "resources/list" then
    local resList = {
      {
        uri = "cheatengine://process",
        name = "Opened Process",
        description = "Information on the currently opened target process",
        mimeType = "application/json"
      },
      {
        uri = "cheatengine://addresslist",
        name = "Address List",
        description = "Current cheat table entries and their values",
        mimeType = "application/json"
      },
      {
        uri = "cheatengine://modules",
        name = "Modules List",
        description = "Loaded modules and libraries in the target process",
        mimeType = "application/json"
      },
      {
        uri = "cheatengine://version",
        name = "Cheat Engine Version",
        description = "Cheat Engine and MCP server version information",
        mimeType = "application/json"
      }
    }
    makeArray(resList)
    return createResponse(id, { resources = resList })
  end

  -- Resources Read
  if method == "resources/read" then
    local uri = req.params and req.params.uri or ""
    local data = {}

    if uri == "cheatengine://process" then
      data = {
        processID = getOpenedProcessID(),
        processName = process,
        is64Bit = targetIs64Bit and targetIs64Bit() or false
      }
    elseif uri == "cheatengine://addresslist" then
      local al = getAddressList()
      local recs = {}
      for i = 0, al.Count - 1 do
        local mr = al.MemoryRecord[i]
        table.insert(recs, { id = mr.ID, description = mr.Description, address = mr.AddressString, value = mr.Value })
      end
      makeArray(recs)
      data = { records = recs }
    elseif uri == "cheatengine://modules" then
      local mods = enumModules() or {}
      local ml = {}
      for _, m in ipairs(mods) do
        table.insert(ml, { name = m.Name, address = safeHex(m.Address), size = m.Size })
      end
      makeArray(ml)
      data = { modules = ml }
    elseif uri == "cheatengine://version" then
      data = {
        cheatEngineVersion = getCEVersion and getCEVersion() or "unknown",
        mcpServerVersion = MCPServer.version,
        protocolVersion = MCPServer.protocolVersion
      }
    else
      return createError(id, -32602, "Unknown resource URI: " .. tostring(uri))
    end

    local text = jsonparser.encode(data)
    return createResponse(id, {
      contents = makeArray({
        { uri = uri, mimeType = "application/json", text = text }
      })
    })
  end

  -- Prompts List
  if method == "prompts/list" then
    local promptList = {
      {
        name = "reverse_engineer_target",
        description = "Workflow for inspecting the target process architecture, modules, and memory.",
        arguments = makeArray({})
      },
      {
        name = "find_value_workflow",
        description = "Guidance on finding dynamic values (e.g. health, ammo, coordinates) using memory scans.",
        arguments = makeArray({
          { name = "description", description = "What value to search for", required = true }
        })
      }
    }
    makeArray(promptList)
    return createResponse(id, { prompts = promptList })
  end

  -- Prompts Get
  if method == "prompts/get" then
    local pName = req.params and req.params.name
    if pName == "reverse_engineer_target" then
      return createResponse(id, {
        description = "Reverse engineer target workflow",
        messages = makeArray({
          {
            role = "user",
            content = {
              type = "text",
              text = "Inspect the current target process using get_opened_process and enum_modules. Summarize its architecture, main executable base address, and key modules."
            }
          }
        })
      })
    elseif pName == "find_value_workflow" then
      local valDesc = req.params and req.params.arguments and req.params.arguments.description or "the value"
      return createResponse(id, {
        description = "Find value workflow",
        messages = makeArray({
          {
            role = "user",
            content = {
              type = "text",
              text = "Help me locate and freeze " .. valDesc .. " in the target process. Start by asking for the current in-game number, run create_scan, and guide me through refine_scan until we isolate the exact address."
            }
          }
        })
      })
    else
      return createError(id, -32602, "Prompt not found: " .. tostring(pName))
    end
  end

  return createError(id, -32601, "Method not found: " .. tostring(method))
end

function MCPServer.processMessageString(msgStr)
  if not msgStr or msgStr:trim() == "" then return nil end
  local ok, req = pcall(jsonparser.decode, msgStr)
  if not ok then
    return jsonparser.encode(createError(nil, -32700, "Parse error"))
  end

  -- Handle batch requests (array of requests)
  if req[1] ~= nil then
    local batchResp = {}
    for _, item in ipairs(req) do
      local r = handleJsonRpc(item)
      if r then table.insert(batchResp, r) end
    end
    if #batchResp > 0 then
      makeArray(batchResp)
      return jsonparser.encode(batchResp)
    end
    return nil
  else
    local resp = handleJsonRpc(req)
    if resp then
      return jsonparser.encode(resp)
    end
    return nil
  end
end

-------------------------------------------------------------------------------
-- Socket & Transport Layer (HTTP / SSE & Raw TCP Stream)
-------------------------------------------------------------------------------

local function sendHttpResponse(client, statusCode, statusText, headers, body, closeConnection)
  body = body or ""
  local lines = {}
  table.insert(lines, "HTTP/1.1 " .. statusCode .. " " .. statusText)
  if closeConnection then
    headers["Connection"] = "close"
  elseif not headers["Connection"] then
    headers["Connection"] = "keep-alive"
  end
  for k, v in pairs(headers) do
    table.insert(lines, k .. ": " .. v)
  end
  table.insert(lines, "Content-Length: " .. #body)
  table.insert(lines, "")
  table.insert(lines, body)

  local payload = table.concat(lines, "\r\n")
  local ok, bytesWritten = try(function()
    client.lock()
    local bw = client.writeString(payload)
    client.unlock()
    return bw
  end)
  return ok and bytesWritten and bytesWritten > 0
end

local function handleHttpRequest(client, method, uri, headerText, body)
  local path, query = uri:match("^([^%?]+)%??(.*)")
  path = path or uri
  query = query or ""

  local connHeader = headerText:match("[Cc]onnection:%s*([%w%-_]+)")
  local shouldCloseReq = (connHeader and connHeader:lower() == "close") or false
  local isHttp10 = headerText:match("^%u+%s+[^%s]+%s+HTTP/1%.0")
  if isHttp10 and not (connHeader and connHeader:lower() == "keep-alive") then
    shouldCloseReq = true
  end

  local corsHeaders = {
    ["Access-Control-Allow-Origin"] = "*",
    ["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS",
    ["Access-Control-Allow-Headers"] = "Content-Type, Authorization, Accept, X-Session-Id, X-Session-Token",
    ["Access-Control-Expose-Headers"] = "*"
  }

  -- 1. OPTIONS (CORS preflight)
  if method == "OPTIONS" then
    corsHeaders["Access-Control-Max-Age"] = "86400"
    corsHeaders["Connection"] = "close"
    sendHttpResponse(client, 204, "No Content", corsHeaders, "", true)
    return { shouldClose = true }
  end

  -- 2. GET /sse (Server-Sent Events)
  if method == "GET" and (path == "/sse" or path == "/events") then
    local sessionId = generateSessionId()
    MCPServer.lockCS.enter()
    MCPServer.sseSessions[sessionId] = { client = client, createdAt = os.time() }
    MCPServer.lockCS.leave()

    local sseHeaders = {
      ["Content-Type"] = "text/event-stream",
      ["Cache-Control"] = "no-cache, no-transform",
      ["Connection"] = "keep-alive",
      ["Access-Control-Allow-Origin"] = "*",
      ["Access-Control-Expose-Headers"] = "*"
    }

    local lines = { "HTTP/1.1 200 OK" }
    for k, v in pairs(sseHeaders) do
      table.insert(lines, k .. ": " .. v)
    end
    table.insert(lines, "")
    table.insert(lines, "event: endpoint\r\ndata: /messages?sessionId=" .. sessionId .. "\r\n\r\n")

    try(function()
      client.lock()
      client.writeString(table.concat(lines, "\r\n"))
      client.unlock()
    end)
    return { isSse = true }
  end

  -- 3. POST /messages?sessionId=..., /message, or /sse (MCP messages via SSE session or direct)
  if method == "POST" and (path == "/messages" or path == "/message" or path == "/sse") then
    local sessionId = query:match("sessionId=([^&]+)")
    if not sessionId then
      sessionId = headerText:match("[Xx]%-[Ss]ession%-[Ii]d:%s*([%w%-_]+)")
    end
    if not sessionId then
      sessionId = headerText:match("[Xx]%-[Ss]ession%-[Tt]oken:%s*([%w%-_]+)")
    end

    MCPServer.lockCS.enter()
    local targetSession = sessionId and MCPServer.sseSessions[sessionId] or nil
    local targetSessionId = sessionId

    -- If specified session not found, check if there's an active SSE session to fall back to
    if not targetSession then
      local latestTime = 0
      for sid, s in pairs(MCPServer.sseSessions) do
        if s.client and (s.createdAt or 0) >= latestTime then
          latestTime = s.createdAt or 0
          targetSession = s
          targetSessionId = sid
        end
      end
    end
    MCPServer.lockCS.leave()

    if targetSession and targetSession.client then
      -- Acknowledge POST with 202 Accepted
      corsHeaders["Content-Type"] = "text/plain"
      sendHttpResponse(client, 202, "Accepted", corsHeaders, "Accepted", shouldCloseReq)

      -- Process JSON-RPC and push to active SSE connection
      local respJson = MCPServer.processMessageString(body)
      if respJson then
        local sseClient = targetSession.client
        local ok, bytesWritten = try(function()
          sseClient.lock()
          local payload = respJson:gsub("\r?\n", "\ndata: ")
          local bw = sseClient.writeString("event: message\r\ndata: " .. payload .. "\r\n\r\n")
          sseClient.unlock()
          return bw
        end)
        if not ok or not bytesWritten or bytesWritten <= 0 then
          MCPServer.lockCS.enter()
          if targetSessionId and MCPServer.sseSessions[targetSessionId] == targetSession then
            MCPServer.sseSessions[targetSessionId] = nil
          end
          MCPServer.lockCS.leave()
        end
      end
      return { shouldClose = shouldCloseReq }
    else
      -- Direct POST (e.g. POST /sse or /messages with direct JSON-RPC body): return JSON-RPC response directly in HTTP 200
      local respJson = MCPServer.processMessageString(body) or "{}"
      corsHeaders["Content-Type"] = "application/json"
      sendHttpResponse(client, 200, "OK", corsHeaders, respJson, shouldCloseReq)
      return { shouldClose = shouldCloseReq }
    end
  end

  -- 4. POST / or /rpc (Direct JSON-RPC over HTTP)
  if method == "POST" and (path == "/" or path == "/rpc" or path == "/api") then
    local respJson = MCPServer.processMessageString(body) or "{}"
    corsHeaders["Content-Type"] = "application/json"
    sendHttpResponse(client, 200, "OK", corsHeaders, respJson, shouldCloseReq)
    return { shouldClose = shouldCloseReq }
  end

  -- 5. GET / or /status (Status JSON)
  if method == "GET" then
    local statusInfo = {
      server = "Cheat Engine MCP Server",
      version = MCPServer.version,
      protocolVersion = MCPServer.protocolVersion,
      status = "running",
      openedProcess = (getOpenedProcessID() ~= 0) and (process or ("PID " .. getOpenedProcessID())) or "None",
      endpoints = {
        sse = "/sse",
        messages = "/messages?sessionId=<sessionId>",
        direct_post = "/"
      }
    }
    corsHeaders["Content-Type"] = "application/json"
    sendHttpResponse(client, 200, "OK", corsHeaders, jsonparser.encode(statusInfo), shouldCloseReq)
    return { shouldClose = shouldCloseReq }
  end

  -- Fallback 404
  corsHeaders["Content-Type"] = "text/plain"
  sendHttpResponse(client, 404, "Not Found", corsHeaders, "Not Found", shouldCloseReq)
  return { shouldClose = shouldCloseReq }
end

local function handleClientConnection(client, clientThread)
  local buffer = ""
  local isHttp = nil
  local isSse = false

  while not (MCPServer.serverTerminated or clientThread.Terminated) do
    local b = client.readBytesMin(1)
    if b == nil or #b == 0 then
      break
    end

    local chunk = byteTableToString(b)
    buffer = buffer .. chunk

    -- Determine protocol if not yet known
    if isHttp == nil then
      if #buffer >= 4 then
        if buffer:match("^[A-Z]+%s+") then
          isHttp = true
        else
          isHttp = false
        end
      end
    end

    if isHttp == true then
      local shouldClose = false
      while true do
        local headerEnd = buffer:find("\r?\n\r?\n")
        if not headerEnd then
          break
        end

        local headerText = buffer:sub(1, headerEnd - 1)
        local _, matchEnd = buffer:find("\r?\n\r?\n")
        local bodyStart = matchEnd + 1

        local method, uri = headerText:match("^(%u+)%s+([^%s]+)")
        if not (method and uri) then
          -- Malformed HTTP request header
          buffer = ""
          shouldClose = true
          break
        end

        local clHeader = headerText:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")
        local contentLength = clHeader and tonumber(clHeader) or 0

        local bodyLength = #buffer - bodyStart + 1
        if bodyLength < contentLength then
          -- Incomplete body, wait for more data
          break
        end

        local body = buffer:sub(bodyStart, bodyStart + contentLength - 1)
        buffer = buffer:sub(bodyStart + contentLength)

        local reqResult = handleHttpRequest(client, method, uri, headerText, body)
        if reqResult and reqResult.isSse then
          isSse = true
          break
        end
        if reqResult and reqResult.shouldClose then
          shouldClose = true
          break
        end
      end

      if isSse then
        -- Connection is now in Server-Sent Events mode.
        -- Wait until client disconnects (readBytesMin returns nil or empty).
        while not (MCPServer.serverTerminated or clientThread.Terminated) do
          local sseb = client.readBytesMin(1)
          if sseb == nil or #sseb == 0 then
            break
          end
        end
        break
      end

      if shouldClose then
        break
      end

    elseif isHttp == false then
      -- Raw TCP JSON-RPC Stream
      -- 1. Check for Content-Length framing (LSP-style)
      if buffer:match("^[Cc]ontent%-[Ll]ength:") then
        while true do
          if not buffer:match("^[Cc]ontent%-[Ll]ength:") then break end
          local headerEnd = buffer:find("\r?\n\r?\n")
          if not headerEnd then break end
          local cl = tonumber(buffer:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
          local _, matchEnd = buffer:find("\r?\n\r?\n")
          local bodyStart = matchEnd + 1
          if #buffer < bodyStart + cl - 1 then break end
          local msg = buffer:sub(bodyStart, bodyStart + cl - 1)
          buffer = buffer:sub(bodyStart + cl)
          local resp = MCPServer.processMessageString(msg)
          if resp then
            local framed = "Content-Length: " .. #resp .. "\r\n\r\n" .. resp
            try(function()
              client.lock()
              client.writeString(framed)
              client.unlock()
            end)
          end
        end
      else
        -- 2. Line-delimited JSON-RPC (standard MCP stdio/socket)
        while buffer:find("\n") do
          local lineEnd = buffer:find("\n")
          local line = buffer:sub(1, lineEnd - 1):gsub("\r", ""):trim()
          buffer = buffer:sub(lineEnd + 1)
          if line ~= "" then
            local resp = MCPServer.processMessageString(line)
            if resp then
              try(function()
                client.lock()
                client.writeString(resp .. "\n")
                client.unlock()
              end)
            end
          end
        end
      end
    end
  end

  -- Clean up disconnected client and SSE sessions
  MCPServer.lockCS.enter()
  for sid, s in pairs(MCPServer.sseSessions) do
    if s.client == client then
      MCPServer.sseSessions[sid] = nil
    end
  end
  for idx, c in pairs(MCPServer.clients) do
    if c == client then
      MCPServer.clients[idx] = nil
      break
    end
  end
  MCPServer.lockCS.leave()

  if client then
    client.destroy()
  end
end

-------------------------------------------------------------------------------
-- Server Lifecycle Management
-------------------------------------------------------------------------------

function MCPServer.start(port, localhostOnly)
  if MCPServer.running then
    print("MCP Server is already running on port " .. tostring(MCPServer.port))
    return true
  end

  port = port or MCPServer.port or 11211
  localhostOnly = (localhostOnly ~= nil) and localhostOnly or MCPServer.localhostOnly

  MCPServer.port = port
  MCPServer.localhostOnly = localhostOnly
  MCPServer.serverTerminated = false

  local ss = createSocketServer(port, localhostOnly)
  if not ss then
    print(string.format("MCP Server: Failed to bind socket server on port %d", port))
    return false
  end

  MCPServer.serverSocket = ss
  MCPServer.running = true

  MCPServer.serverThread = createThread(function(thread)
    print(string.format("MCP Server: Listening on port %d (localhostOnly: %s)", port, tostring(localhostOnly)))
    while not (MCPServer.serverTerminated or thread.Terminated) do
      local client = ss.acceptConnection(true)
      if client then
        MCPServer.lockCS.enter()
        table.insert(MCPServer.clients, client)
        MCPServer.lockCS.leave()

        createThread(function(clientThread)
          handleClientConnection(client, clientThread)
        end)
      end
    end
    if ss then
      ss.destroy()
    end
  end)

  MCPServer.heartbeatThread = createThread(function(thread)
    local elapsed = 0
    while not (MCPServer.serverTerminated or thread.Terminated) do
      sleep(500)
      elapsed = elapsed + 500
      if elapsed >= 15000 then
        elapsed = 0
        MCPServer.lockCS.enter()
        local deadSessions = {}
        for sid, session in pairs(MCPServer.sseSessions) do
          if session.client then
            local ok, bw = try(function()
              session.client.lock()
              local written = session.client.writeString(": keepalive\r\n\r\n")
              session.client.unlock()
              return written
            end)
            if not ok or not bw or bw <= 0 then
              table.insert(deadSessions, sid)
            end
          else
            table.insert(deadSessions, sid)
          end
        end
        for _, sid in ipairs(deadSessions) do
          MCPServer.sseSessions[sid] = nil
        end
        MCPServer.lockCS.leave()
      end
    end
  end)

  MCPServer.updateMenu()
  return true
end

function MCPServer.stop()
  if not MCPServer.running then return end
  MCPServer.serverTerminated = true
  MCPServer.running = false

  -- Stop heartbeat thread
  if MCPServer.heartbeatThread then
    MCPServer.heartbeatThread.terminate()
    MCPServer.heartbeatThread = nil
  end

  -- Close active clients
  MCPServer.lockCS.enter()
  for _, c in pairs(MCPServer.clients) do
    try(function() c.destroy() end)
  end
  MCPServer.clients = {}
  MCPServer.sseSessions = {}
  MCPServer.lockCS.leave()

  -- Unblock acceptConnection if waiting
  if MCPServer.serverSocket then
    try(function()
      local unblocker = connectToTCPServer("127.0.0.1", MCPServer.port)
      if unblocker then unblocker.destroy() end
    end)
    MCPServer.serverSocket.destroy() 
    MCPServer.serverSocket = nil
  end

  print("MCP Server stopped.")
  MCPServer.updateMenu()
end

function MCPServer.restart(port, localhostOnly)
  MCPServer.stop()
  sleep(200)
  return MCPServer.start(port, localhostOnly)
end

-------------------------------------------------------------------------------
-- UI & Menu Integration
-------------------------------------------------------------------------------

function MCPServer.copyAntigravityConfig()
  local sseUrl = string.format("http://127.0.0.1:%d/sse", MCPServer.port)
  local config = {
    mcpServers = {
      cheatengine = {
        serverUrl = sseUrl
      }
    }
  }
  local jsonStr = jsonparser.encode(config)
  if writeToClipboard then
    writeToClipboard(jsonStr)
    if showMessage then
      showMessage("Antigravity MCP config copied to clipboard!\n\nPaste this into ~/.gemini/config/mcp_config.json:\n\n" .. jsonStr)
    end
  else
    print("Antigravity MCP Config:\n" .. jsonStr)
  end
end

function MCPServer.copyClaudeConfig()
  local sseUrl = string.format("http://127.0.0.1:%d/sse", MCPServer.port)
  local config = {
    mcpServers = {
      cheatengine = {
        url = sseUrl
      }
    }
  }
  local jsonStr = jsonparser.encode(config)
  if writeToClipboard then
    writeToClipboard(jsonStr)
    if showMessage then
      showMessage("Claude Desktop / Cursor config copied to clipboard!\n\nPaste this into claude_desktop_config.json:\n\n" .. jsonStr)
    end
  else
    print("Claude/Cursor MCP Config:\n" .. jsonStr)
  end
end

function MCPServer.copyClientConfig()
  local sseUrl = string.format("http://127.0.0.1:%d/sse", MCPServer.port)
  local config = {
    mcpServers = {
      cheatengine = {
        url = sseUrl,
        serverUrl = sseUrl
      }
    }
  }
  local jsonStr = jsonparser.encode(config)
  if writeToClipboard then
    writeToClipboard(jsonStr)
    if showMessage then
      showMessage("Universal MCP client configuration copied to clipboard!\n\nCompatible with Antigravity, Claude Desktop, and Cursor:\n\n" .. jsonStr)
    end
  else
    print("Universal MCP Client Config:\n" .. jsonStr)
  end
end

function MCPServer.updateMenu()
  if not MCPServer.menuItemStatus then return end
  runOnMainThread(function()
    if MCPServer.running then
      MCPServer.menuItemStatus.Caption = string.format("Status: Running on port %d", MCPServer.port)
      if MCPServer.menuItemToggle then
        MCPServer.menuItemToggle.Caption = "Stop Server"
      end
    else
      MCPServer.menuItemStatus.Caption = "Status: Stopped"
      if MCPServer.menuItemToggle then
        MCPServer.menuItemToggle.Caption = "Start Server"
      end
    end
  end)
end

function MCPServer.initMenu()
  if not MainForm or not MainForm.Menu then return end

  runOnMainThread(function()
    if MCPServer.mainMenu then return end

    local topMenu = createMenuItem(MainForm)
    topMenu.Caption = "MCP"
    MCPServer.mainMenu = topMenu

    -- Status Item
    local miStatus = createMenuItem(MainForm)
    miStatus.Caption = "Status: Initializing..."
    miStatus.Enabled = false
    topMenu.add(miStatus)
    MCPServer.menuItemStatus = miStatus

    -- Start/Stop Toggle Item
    local miToggle = createMenuItem(MainForm)
    miToggle.Caption = "Start Server"
    miToggle.OnClick = function()
      if MCPServer.running then
        MCPServer.stop()
      else
        MCPServer.start()
      end
    end
    topMenu.add(miToggle)
    MCPServer.menuItemToggle = miToggle

    -- Separator
    local miSep1 = createMenuItem(MainForm)
    miSep1.Caption = "-"
    topMenu.add(miSep1)

    -- Configure Port
    local miPort = createMenuItem(MainForm)
    miPort.Caption = "Configure Port..."
    miPort.OnClick = function()
      if inputQuery then
        local newPort = inputQuery("MCP Server Port", "Enter port number:", tostring(MCPServer.port))
        if newPort and tonumber(newPort) then
          local p = tonumber(newPort)
          local s = getSettings("MCPServer", true)
          s.Value["Port"] = tostring(p)
          if setSettingsOption then
            setSettingsOption('MCPServerPort', MCPServer.settingsTabName or 'AI Tools', tostring(p))
          end
          updateAntigravityConfig(p)
          if MCPServer.running then
            MCPServer.restart(p)
          else
            MCPServer.port = p
            MCPServer.updateMenu()
          end
        end
      end
    end
    topMenu.add(miPort)

    -- Copy Config for Antigravity
    local miCopyAgy = createMenuItem(MainForm)
    miCopyAgy.Caption = "Copy Config for Antigravity"
    miCopyAgy.OnClick = function()
      MCPServer.copyAntigravityConfig()
    end
    topMenu.add(miCopyAgy)

    -- Copy Config for Claude / Cursor
    local miCopyClaude = createMenuItem(MainForm)
    miCopyClaude.Caption = "Copy Config for Claude / Cursor"
    miCopyClaude.OnClick = function()
      MCPServer.copyClaudeConfig()
    end
    topMenu.add(miCopyClaude)

    -- Copy Universal Config
    local miCopyUniv = createMenuItem(MainForm)
    miCopyUniv.Caption = "Copy Universal Config (Both)"
    miCopyUniv.OnClick = function()
      MCPServer.copyClientConfig()
    end
    topMenu.add(miCopyUniv)

    -- Initial visibility based on autoStart setting
    topMenu.Visible = (MCPServer.autoStart == true)

    -- Add topMenu to MainForm.Menu.Items    
    MainForm.Menu.Items.insert(MainForm.Menu.Items.Count-1, topMenu) --add it before help


    MCPServer.updateMenu()
  end)
end

function MCPServer.setMenuVisible(visible)
  if not MCPServer.mainMenu then return end
  runOnMainThread(function()
    if MCPServer.mainMenu then
      MCPServer.mainMenu.Visible = (visible == true)
    end
  end)
end

-------------------------------------------------------------------------------
-- Initialization & Settings
-------------------------------------------------------------------------------

MCPServer.settingsTabName = 'AI Tools'

local function onSettingsChange(settingName, subName)
  if settingName == 'Launch MCP Server' or settingName == 'LaunchMCPServer' then
    local shouldLaunch = getSettingsOption(settingName, subName)
    if shouldLaunch ~= nil then
      MCPServer.autoStart = (shouldLaunch == true)
      MCPServer.setMenuVisible(MCPServer.autoStart)
      if MCPServer.autoStart then
        if not MCPServer.running then
          MCPServer.start(MCPServer.port, MCPServer.localhostOnly)
        end
      else
        if MCPServer.running then
          MCPServer.stop()
        end
      end
    end
  elseif settingName == 'MCPServerPort' or settingName == 'MCP Server Port' then
    local portStr = getSettingsOption(settingName, subName)
    if portStr and tonumber(portStr) then
      local p = tonumber(portStr)
      if p > 0 and p < 65536 and p ~= MCPServer.port then
        MCPServer.port = p
        local s = getSettings("MCPServer", true)
        s.Value["Port"] = tostring(p)
        updateAntigravityConfig(p)
        if MCPServer.running then
          MCPServer.restart(p)
        else
          MCPServer.updateMenu()
        end
      end
    end
  end
end

local function initMCPServer()
  local tabName = MCPServer.settingsTabName or 'AI Tools'

  -- Check for port configured in ~/.gemini/config/mcp_config.json
  local detectedPort = detectConfiguredPort()
  if detectedPort then
    MCPServer.port = detectedPort
  end

  -- Load settings from CE registry (overrides detected port if set)
  local s = getSettings("MCPServer", true)
  if s.Value["Port"] and tonumber(s.Value["Port"]) then
    MCPServer.port = tonumber(s.Value["Port"])
  end
  if s.Value["LocalhostOnly"] ~= nil and s.Value["LocalhostOnly"] ~= "" then
    MCPServer.localhostOnly = (s.Value["LocalhostOnly"] == "1" or s.Value["LocalhostOnly"] == "true")
  end

  -- Register Settings in CE Settings window under 'AI Tools' tab
  if createSettingsOption then
    local settingTypeBoolean = ctBoolean or 0
    local settingTypeString = ctString or 1

    createSettingsOption('Launch MCP Server', 'Launch MCP Server', settingTypeBoolean, tabName, nil, false, onSettingsChange)
    createSettingsOption('MCPServerPort', 'MCP Server Port', settingTypeString, tabName, nil, tostring(MCPServer.port or 20000), onSettingsChange)

    local shouldLaunch = getSettingsOption('Launch MCP Server', tabName)
    if shouldLaunch == nil then
      shouldLaunch = getSettingsOption('LaunchMCPServer', tabName)
    end
    if shouldLaunch ~= nil then
      MCPServer.autoStart = (shouldLaunch == true)
    else
      MCPServer.autoStart = false
    end

    local configuredPort = getSettingsOption('MCPServerPort', tabName)
    if configuredPort == nil or configuredPort == '' then
      configuredPort = getSettingsOption('MCP Server Port', tabName)
    end
    if configuredPort and tonumber(configuredPort) then
      MCPServer.port = tonumber(configuredPort)
    end
  else
    if s.Value["AutoStart"] ~= nil and s.Value["AutoStart"] ~= "" then
      MCPServer.autoStart = (s.Value["AutoStart"] == "1" or s.Value["AutoStart"] == "true")
    else
      MCPServer.autoStart = false
    end
  end

  -- Setup menu
  MCPServer.initMenu()

  -- Auto-start server if enabled
  if MCPServer.autoStart then
    MCPServer.start(MCPServer.port, MCPServer.localhostOnly)
  end
end

initMCPServer()

return MCPServer

