---
name: monoscript
description: Cheat Engine Mono and Unity IL2CPP runtime scripting, reverse engineering, and Auto Assembler integration. Use this skill when inspecting, hooking, scanning, or calling Mono/.NET/IL2CPP code, classes, methods, fields, and objects in target processes via monoscript.lua and MonoDataCollector.
---

# Cheat Engine MonoScript Skill (`monoscript.lua`)

The `monoscript` skill enables AI agents to reverse engineer, inspect, hook, and manipulate applications and games built with the **Mono runtime** (e.g., Unity Mono, standalone .NET Mono) or **Unity IL2CPP** via Cheat Engine's `autorun/monoscript.lua` and injected **MonoDataCollector**.

---

## When to Use This Skill

Activate this skill when:
- Investigating, reverse engineering, or writing cheats for Unity or Mono-based games.
- Resolving managed classes, methods, and field offsets at runtime without hardcoding static offsets.
- JIT-compiling methods to obtain native execution entry points for mid-function or detour hooking.
- Finding all active instances of a class in the managed heap.
- Reading or writing static variables and instance fields across game updates.
- Dynamically invoking managed methods (e.g., calling game methods, spawning items, unlocking achievements).
- Writing Cheat Engine Auto Assembler (AA) scripts using `USEMONO`, `FINDMONOMETHOD`, or `GETMONOSTRUCT`.

For the exhaustive catalog of all 180+ functions and constants, see [`references/api_reference.md`](./Extensions/AITools/skills/monoscript/references/api_reference.md).

---

## Core Architecture & Connection

Cheat Engine interacts with target runtimes through a dual-process architecture:
1. **Host (Cheat Engine)**: [`monoscript.lua`](./autorun/monoscript.lua) runs in CE's Lua engine, providing high-level APIs, symbol lookups, and AA directives.
2. **Target (Game Process)**: Injected `MonoDataCollector` library (`MonoDataCollector64.dll`, `libMonoDataCollector-linux-x86_64.so`, etc.) attaches to the runtime (`mono_thread_attach` / `il2cpp_thread_attach`) and executes `MONOCMD_*` commands.
3. **IPC Transport**: Named pipe `cemonodc_pid<PID>` (or local TCP socket `127.0.0.1:52737` under Wine).

```
Cheat Engine (monoscript.lua)  <--- Named Pipe / TCP --->  MonoDataCollector DLL in Target
```

---

## Workflows & Practical Examples

### 1. Attaching to the Mono / IL2CPP Runtime

Always ensure the data collector is initialized before invoking Mono functions:

```lua
-- Attach data collector if not already active
if not mono_isValid() then
  LaunchMonoDataCollector()
end

if mono_isil2cpp() then
  print("Target is Unity IL2CPP")
else
  print("Target is standard Mono")
end
```

> [!TIP]
> If a Cheat Engine table has `UsesMono` enabled, Cheat Engine will auto-launch the collector on process attach.

---

### 2. Finding Classes, Methods & Compiling Native Addresses

To hook or disassemble a method, first locate its class and compile it:

```lua
-- Find class across all loaded assemblies
local klass = mono_findClass("PlayerController")
-- Or with namespace:
-- local klass = mono_findClass("Assembly-CSharp", "Game.PlayerController")

if klass and klass ~= 0 then
  -- Find method by name
  local method = mono_class_findMethod(klass, "TakeDamage")
  
  if method and method ~= 0 then
    -- JIT compile the method into native machine code
    local entryPoint = mono_compile_method(method)
    printf("TakeDamage native address: 0x%X", entryPoint)
    
    -- In standard Mono, you can also inspect CIL bytecode:
    if not mono_isil2cpp() then
      local ilText = mono_method_disassemble(method)
      print(ilText)
    end
  end
end
```

---

### 3. Enumerating Fields & Reading/Writing Values

Inspect field layouts and offsets dynamically without guessing struct padding:

```lua
local klass = mono_findClass("PlayerController")
local fields = mono_class_enumFields(klass, true, true)

for i, f in ipairs(fields) do
  printf("Field: %s | Offset: 0x%X | Type: %s | Static: %s", 
    f.name, f.offset, f.typename, tostring(f.isStatic))
  
  -- If field is static, read its value directly
  if f.isStatic and not f.isConst then
    local val = mono_class_getStaticFieldValue(klass, f.field)
    printf("  Static value: %s", tostring(val))
  end
end
```

To modify a static field:
```lua
mono_class_setStaticFieldValue(klass, fieldHandle, 9999)
```

---

### 4. Finding Live Object Instances in Memory

Locate active instances of a class on the heap:

```lua
local klass = mono_findClass("Player")

-- Synchronous lookup (in Unity, leverages Resources.FindObjectsOfTypeAll)
local instances = mono_class_findInstancesOfClassListOnly(klass)

if instances then
  for i, addr in ipairs(instances) do
    printf("Instance %d at 0x%X", i, addr)
    
    -- Read all instance fields into a Lua table
    local values = mono_object_enumValues(addr)
    for fieldName, val in pairs(values) do
      printf("  %s = %s", fieldName, tostring(val))
    end
  end
end
```

---

### 5. Invoking Managed Methods Dynamically

Call arbitrary managed methods inside the target process with marshalled arguments:

```lua
local klass = mono_findClass("InventoryManager")
local method = mono_class_findMethod(klass, "AddItem")

-- Find instance of InventoryManager
local instances = mono_class_findInstancesOfClassListOnly(klass)
if instances and #instances > 0 then
  local instance = instances[1]
  
  -- Method signature: AddItem(int itemId, int quantity)
  local args = {
    { type = vtDword, value = 401 }, -- Item ID
    { type = vtDword, value = 10 }   -- Quantity
  }
  
  local result, exception = mono_invoke_method(nil, method, instance, args)
  if exception then
    print("Invocation error: " .. exception)
  else
    print("Method invoked successfully. Result: " .. tostring(result))
  end
end
```

---

### 6. Auto Assembler Commands

`monoscript.lua` introduces 3 commands directly into Cheat Engine's Auto Assembler:

#### `USEMONO`
Initializes MonoDataCollector before executing the script. Always include this at the top of the `[ENABLE]` section:
```asm
[ENABLE]
USEMONO()
```

#### `FINDMONOMETHOD(DefineName, Namespace:ClassName:MethodName)`
Compiles the target method and assigns its native address to `DefineName`:
```asm
[ENABLE]
USEMONO()
FINDMONOMETHOD(TakeDamageEntry, Assembly-CSharp:Player:TakeDamage)

TakeDamageEntry:
  jmp newmem
  nop
```

Note though that FINDMONOMETHOD is obsolete and just referencing a symbol with the same name will cause cheat engine to compile it for you as well

#### `GETMONOSTRUCT(StructName, Namespace:ClassName)`
Generates an Auto Assembler structure representing the class layout:
```asm
[ENABLE]
USEMONO()
GETMONOSTRUCT(PlayerStruct, Assembly-CSharp:Player)

// Fields can now be referenced symbolically:
mov [rax+PlayerStruct.currentHealth], #9999
```

---

### 7. Symbol Resolution in Disassembler & Hex View

Once `LaunchMonoDataCollector()` is active, Cheat Engine registers:
1. **Symbol Lookups**: Address fields and scripts accept:
   - `Assembly-CSharp:Player:Update` -> Resolves to JIT address.
   - `Player:health` -> Resolves to field offset or static memory address.
2. **Address Lookups**: Disassembly displays names automatically:
   - `Assembly-CSharp:Player:TakeDamage+14` appears in memory view instead of bare addresses.

---

## Mono vs Unity IL2CPP: Key Nuances

| Feature | Standard Mono | Unity IL2CPP |
| :--- | :--- | :--- |
| **Method Compilation** | JIT compiles on-demand via `mono_compile_method()`. | Pre-compiled AOT native code. `mono_compile_method()` returns existing address. |
| **CIL Bytecode** | `mono_getILCodeFromMethod()` & `mono_method_disassemble()` return IL bytecode. | IL bytecode is not in memory; returns `nil` / empty. Inspect native disassembly instead. |
| **VTable Resolution** | Full dynamic vtables (`mono_class_getVTable()`). | Static class pointers; `mono_class_getVTable()` returns class pointer itself. |
| **Class Fallbacks** | Fast metadata table inspection. | May fall back to pattern scanning (`mono_image_enumClasses_il2cppfallback`). |
| **Symbol Enum** | Loaded per assembly on demand. | Emits background symbol list (`monoIL2CPPSymbolEnum`). |

---

## Concurrency & Thread-Safety Rules

> [!WARNING]
> Do not create pipes yourself. Just use the API provided by Cheat Engine's monoscript.lua

1. **Worker Threads**:
   If executing Mono calls inside a Lua worker thread (`createThread`), accessing lua functions will autocreate pipe connections for you which will be destroyed upon thread termination   

2. **Main Thread GUI Operations**:
   `LaunchMonoDataCollector()` and `libmono.terminate()` must be executed on the main UI thread. If calling from an external thread, wrap in `synchronize()`:
   ```lua
   synchronize(function()
     LaunchMonoDataCollector()
   end)
   ```

---

## Essential Function Quick Reference

| Task | Primary Function | Secondary / Alternative |
| :--- | :--- | :--- |
| **Connect** | `LaunchMonoDataCollector()` | `getMonoPipe()`, `mono_isValid()` |
| **Class Query** | `mono_findClass("Namespace.Class")` | `mono_findClass2(fullName, assembly)` |
| **Method Query** | `mono_class_findMethod(class, name)` | `mono_findMethod(namespace, class, method, params)` |
| **JIT Compile** | `mono_compile_method(method)` | Native entry point address returned |
| **Field Info** | `mono_class_enumFields(class, true)` | Returns table of `{name, offset, isStatic, ...}` |
| **Static Value**| `mono_class_getStaticFieldValue(class, field)` | `mono_class_setStaticFieldValue(class, field, val)` |
| **Find Objects**| `mono_class_findInstancesOfClassListOnly(class)` | `mono_class_findInstancesOfClass(domain, class, cb)` |
| **Invoke Code** | `mono_invoke_method(nil, method, obj, args)` | `mono_invoke(name, obj, args)` |
| **Read String** | `mono_string_readString(address)` | `mono_new_string(domain, "text")` |
| **Dissect GUI** | `mono_dissect()` | Opens interactive Mono Dissector window |

See [references/api_reference.md](references/api_reference.md) for full parameter and return schemas (loadable on demand via `getSkill(skillName='monoscript', reference='references/api_reference.md')`).
