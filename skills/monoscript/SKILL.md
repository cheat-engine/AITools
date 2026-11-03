---
name: monoscript
description: Cheat Engine Mono and Unity IL2CPP runtime scripting, reverse engineering, and Auto Assembler integration. Use this skill when inspecting, hooking, scanning, or calling Mono/.NET/IL2CPP code, classes, methods, fields, and objects in target processes via monoscript.lua and MonoDataCollector.
---

# Cheat Engine MonoScript Skill (`monoscript.lua`)

The `monoscript` skill enables AI agents to reverse engineer, inspect, hook, and manipulate applications and games built with the **Mono runtime** (e.g., Unity Mono, standalone .NET Mono) or **Unity IL2CPP** via Cheat Engine's `autorun/monoscript.lua` and injected **MonoDataCollector**.
Even IL2CPP targets get injected with the monodatacollector library and they will adjust accordingly to their environment
When the monodatacollector is attached to an IL2CPP target, it will spawn a thread that will enumerate all methods and their entry points and stores them in a symbollist used by Cheat Engine's symbol handler
The symbolhandler will parse .net formatted strings to find the method or field.  If it is a field, it will return the static field, or the field offset if it is not a static address 
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

For the exhaustive catalog of all 200+ functions and constants, see [references/api_reference.md](references/api_reference.md).

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

-- Synchronous lookup: uses fast native GC walk/Unity Liveness first, falls back to memory scan
local instances = mono_class_findInstancesOfClassListOnly(klass)

-- Or call fast native GC heap search directly (supports includeSubclasses flag):
-- local instances = mono_class_findInstancesFast(klass, false)

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

### 6. Inflating Generic Classes & Methods

Dynamically specialize open generic types and generic methods at runtime using runtime reflection:

```lua
-- Inflate generic class: List<int>
local listGeneric = mono_findClass("mscorlib", "System.Collections.Generic.List`1")
local intClass = mono_findClass("mscorlib", "System.Int32")
local listOfIntClass = mono_class_inflate(listGeneric, intClass)
-- Multiple type arguments: mono_class_inflate(dictGeneric, {keyClass, valClass})

-- Inflate generic method: GetComponent<T>()
local goClass = mono_findClass("UnityEngine", "GameObject")
local getCompMethod = mono_class_findMethod(goClass, "GetComponent")
local playerClass = mono_findClass("Assembly-CSharp", "PlayerController")
local inflatedMethod = mono_method_inflate(getCompMethod, playerClass)
```

---

### 7. Working with ValueTypes, Struct Buffers & Table Literals

Manipulate unboxed structs, pass table literals directly to methods, or allocate zero-GC buffers for high-frequency loops:

```lua
local v3Class = mono_findClass("UnityEngine", "Vector3")
local playerClass = mono_findClass("PlayerController")
local setPosMethod = mono_class_findMethod(playerClass, "SetPosition")
local instances = mono_class_findInstancesOfClassListOnly(playerClass)

if instances and #instances > 0 then
  -- Option A: Pass table literal directly (named or positional array)
  -- Automatically instantiates, marshals, and populates the struct in target memory:
  mono_invoke_method(nil, setPosMethod, instances[1], { {x = 100.0, y = 50.0, z = -20.0} })
  
  -- Option B: Zero-allocation StructBuffer for high-frequency loops (bypasses managed GC heap)
  local v3Buf = mono_struct_createBuffer(v3Class, {x = 0, y = 10, z = 0})
  v3Buf.x = 250.5              -- Direct property setter via metatable
  print("Current Y:", v3Buf.y) -- Direct property getter
  
  -- Pass buffer directly into method invocation (marshalled as unboxed pointer, 0 allocations):
  mono_invoke_method(nil, setPosMethod, instances[1], { v3Buf })
  
  -- Convert to snapshot Lua table or deallocate buffer
  local tbl = v3Buf:toTable()
  v3Buf:free()
end

-- In-place struct manipulation on existing memory addresses:
-- mono_struct_setField(address, v3Class, "x", 999.0)
-- local currentX = mono_struct_getField(address, v3Class, "x")
```

---

### 8. Auto Assembler Commands


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

### 9. Symbol Resolution in Disassembler & Hex View

Once `LaunchMonoDataCollector()` is active, Cheat Engine registers:
1. **Symbol Lookups**: Address fields and scripts accept:
   - `Assembly-CSharp:Player:Update` -> Resolves to JIT address.
   - `Player:health` -> Resolves to field offset or static memory address.
2. **Address Lookups**: Disassembly displays names automatically:
   - `Assembly-CSharp:Player:TakeDamage+14` appears in memory view instead of bare addresses.

---

### 10. Inspecting & Navigating `.NET Info` (`dotnetinfo.lua`)

Cheat Engine provides the `.NET Info` window (`frmDotNetInfo`) for exploring domains, images, classes, methods, and fields.

#### Delay-Loaded Class Lists
- `Image.Classes` is fetched asynchronously in a background worker thread (`ClassFetchThread`).
- While fetching, `Image.Classes.Busy` is `true`. Do not attempt to read or index `Image.Classes` until `Image.Classes` is non-nil and `not Image.Classes.Busy`.
- In virtual ListViews (`lvClasses.OwnerData = true`), item count is driven by `lvClasses.Items.Count = #Image.Classes` and captions are fetched on demand via `OnData`.

#### Single-Domain UI Behavior
- If the target process has only 1 domain, `frmDotNetInfo.lbDomains` is hidden (`Visible = false`) and `lbImages` is already populated with the images for that domain.

#### Scrolling Items into View
- On Cheat Engine `TListItem` objects, call `item.makeVisible(false)` to scroll the selected class or member into view.

#### Handling `libmono.abort`
- If an unhandled error occurs during data collector attachment, `libmono.abort` is set to `true`.
- When `libmono.abort == true`, all Mono functions (`mono_image_enumClassesEx`, `mono_enumDomains`, etc.) return `nil` immediately.
- To recover, reset `libmono.abort = false` before retrying Mono queries.

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

## Runtime Invocation & JIT Invariants

### Never Invoke Open Generic Method Definitions
> [!CAUTION]
> Invoking an open (uninflated) generic method definition via `mono_invoke_method()` or `mono_runtime_invoke()` causes the Mono JIT compiler inside the target process to abort immediately:
> `* Assertion at method-to-ir.c:7384, condition '!sig->has_type_parameters' not met` (`SIGABRT`, exit code 134).

When resolving methods by name and parameter count (e.g., via `mono_class_enumMethods`):
1. **Detect Open Generics**: Inspect the method signature using `mono_method_getSignature(method)`. Check whether the return type is `'T'`, `'T[]'`, or contains generic indicators (`` ` ``, `!`).
2. **Handle Overloads**: In classes with both generic and non-generic overloads (such as `UnityEngine.Object.FindObjectsOfType`), generic methods like `FindObjectsOfType<T>(bool)` can match a 1-parameter count filter and precede `FindObjectsOfType(Type)` in metadata order. Always verify the parameter types or return type before invoking.
3. **Inflate Concrete Generics**: If you need to invoke a generic method, inflate it with concrete type arguments first using `mono_method_inflate(method, typeArgs)`.

---

## Unity Engine Discovery & Scene Architecture

### 2D vs 3D Game Object Parity
Unity games use the **exact same** internal data structures (`GameObject`, `Transform`, `Component`, `Scene`) regardless of whether the gameplay is 2D or 3D. 2D games simply employ 2D physics colliders (`BoxCollider2D`), `SpriteRenderer`, and orthographic camera projections attached to standard `GameObject` nodes.

### Scene Struct Properties & Internal Calls
In `UnityEngine.SceneManagement.Scene`, property getters (`name`, `isLoaded`, `rootCount`) are wrappers around static C++ engine calls:
- `Scene.GetNameInternal(int sceneHandle)`
- `Scene.GetIsLoadedInternal(int sceneHandle)`
- `Scene.GetRootCountInternal(int sceneHandle)`

Passing an unboxed `Scene` struct buffer (`mono_struct_createBuffer`) to instance getters will fail or return invalid data. Always pass the raw integer scene handle (`m_Handle`) directly to the static internal methods.

### Resilient Native GameObject Query Pipeline
In production Unity builds, root GameObjects are frequently not rooted in Mono GC statics, causing managed GC walks or `mono_class_findInstancesFast` to return 0 roots. To reliably discover all GameObjects:
1. **Native Engine Queries**:
   - `UnityEngine.Object.FindObjectsOfType(Type, bool)` (Unity 5.6+ 2-parameter overload: `type`, `includeInactive`).
   - `UnityEngine.Resources.FindObjectsOfTypeAll(Type)`: Interrogates the native C++ engine registry directly, discovering both active and inactive objects across scenes and asset domains in a single call (<50ms).
2. **Root Hierarchy Identification**:
   - Query all `Transform` instances and filter for `transform.parent == nil`.
   - Resolve the owning scene handle via `unity.getGameObjectSceneHandle(go)` (`gameObject.scene.handle`).
   - Group objects with persistent scene handles (e.g. negative handles like `-12`) under `DontDestroyOnLoad`.

---

## Essential Function Quick Reference

| Task | Primary Function | Secondary / Alternative |
| :--- | :--- | :--- |
| **Connect** | `LaunchMonoDataCollector()` | `getMonoPipe()`, `mono_isValid()` |
| **Enum Images** | `mono_enumImagesEx()` | Returns a table of each image. Each entry contains the imagehandle and name of the image |
| **Enum Classes** | `mono_image_enumClassesEx(imagehandle)` | Returns a list of all the classnames and classhandles and some other basic information |
| **Class Query** | `mono_findClass("Namespace.Class")` | `mono_findClass2(fullName, assembly)` |
| **Enum Methods** | `mono_class_enumMethods(classhandle, includeParents:BOOLEAN)` | Returns a list of all the methods and their methodhandles, and other information |
| **Method Query** | `mono_class_findMethod(class, name)` | `mono_findMethod(namespace, class, method, params)` |
| **JIT Compile** | `mono_compile_method(method)` | Native entry point address returned |
| **Field Info** | `mono_class_enumFields(class, true)` | Returns table of `{name, offset, isStatic, ...}` |
| **Static Value**| `mono_class_getStaticFieldValue(class, field)` | `mono_class_setStaticFieldValue(class, field, val)` |
| **Find Objects**| `mono_class_findInstancesOfClassListOnly(class)` | `mono_class_findInstancesOfClass(domain, class, cb)` |
| **Find Fast**   | `mono_class_findInstancesFast(class, includeSubclasses)` | Native GC walk / Unity Liveness without memory scan |
| **Inflate Generic** | `mono_class_inflate(genericClass, typeArgs)` | `mono_method_inflate(genericMethod, typeArgs)` |
| **Struct Buffer** | `mono_struct_createBuffer(class, values)` | Zero-GC native buffer with interactive properties |
| **Struct Fields** | `mono_struct_getField(addr, class, key)` | `mono_struct_setField(addr, class, key, val)` |
| **Invoke Code** | `mono_invoke_method(nil, method, obj, args)` | `mono_invoke(name, obj, args)` |
| **Read String** | `mono_string_readString(address)` | `mono_new_string(domain, "text")` |
| **Dissect GUI** | `mono_dissect()` | Opens interactive Mono Dissector window |
| **Unity Scene GUI** | `ShowUnitySceneExplorer()` | Opens visual Unity Scene & GameObject hierarchy explorer (in `unityscript.lua`) |
| **Unity Roots** | `unity.getRootGameObjects([scene], [includeInactive])` | Resilient multi-tier native C++ engine query pipeline (`unityscript.lua`) |
| **Unity Find**  | `unity.findObjectsOfType(className, [includeInactive])` | Direct native engine search bypassing Mono GC limits (`unityscript.lua`) |

See [references/api_reference.md](references/api_reference.md) for full parameter and return schemas (loadable on demand via `getSkill(skillName='monoscript', reference='references/api_reference.md')`).
