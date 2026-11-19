---
name: unreal-engine
description: Reverse engineering Unreal Engine 4 and 5 games using Cheat Engine and UETools. Locating GNames, GWorld, GUObjectArray, resolving player controllers, acknowledged pawns, and dissecting UE structures dynamically. Use this skill when inspecting, scanning, or creating cheats for Unreal Engine titles.
---

# Cheat Engine Unreal Engine Skill (`UETools`)

The `unreal-engine` skill equips AI agents and reverse engineers with standardized workflows for analyzing, dissecting, and hooking games built on **Unreal Engine 4 and Unreal Engine 5** using Cheat Engine and the bundled `UETools` extension.

---

## When to Use This Skill

Activate this skill when:
- Reverse engineering or creating tables for games built with Unreal Engine 4 or 5.
- Finding the global engine pointers: `GEngine`, `GWorld`, `GNames` (`FNamePool`), and `GUObjectArray`.
- Traversing the runtime game object hierarchy directly from `GEngine` (`GEngine` links directly to `GameInstance`, skipping the `World` step: `GEngine -> GameInstance -> LocalPlayers[0] -> PlayerController -> AcknowledgedPawn`).
- Dissecting `UObject`, `UClass`, `UProperty`, and `UFunction` layouts dynamically.
- Inspecting and querying class definitions, field types, and offsets dynamically using published UETools functions (`UObject_enumProperties`, `UClass_enumProperties`, `UEngine_findObjectStart`).
- Locating Actor components: `RootComponent` (positions/coordinates), `CharacterMovementComponent` (speed, gravity, fly mode), and player attributes.
- Hooking `UObject::ProcessEvent` for engine-wide event interception and method invocation.

---

## Core Unreal Engine Architecture

Every Unreal Engine game shares a standardized runtime reflection system:

1. **`FNamePool` / `GNames`**:
   The global name cache mapping integer indices to engine strings ("None", "Actor", "PlayerController", "Health", etc.). When scanned by `UETools`, these entries are cached in `UEngine.NameToIndex` and `UEngine.IndexToName`. Because these tables contain hundreds of thousands of entries, **never dump them**—always query individual strings or indices.
2. **`GUObjectArray`**:
   A global chunked or flat array indexing every instantiated `UObject` in the engine. Each object has:
   - `VTable` pointer at offset `0x00`.
   - `ObjectFlags` at offset `0x08`.
   - `InternalIndex` at offset `0x0C`.
   - `ClassPrivate` (`UClass*`) at offset `0x10`.
   - `NamePrivate` (`FName`) at offset `0x18`.
   - `OuterPrivate` (`UObject*`) at offset `0x20`.
3. **`GEngine` (`UEngine*` / `UGameEngine*`) & `GWorld` (`UWorld*`)**:
   Cheat Engine's `UETools` extension specifically targets and resolves **`GEngine`** over `GWorld`.
   - **Direct `GameInstance` access**: `GEngine` has a direct pointer field to **`GameInstance`**, meaning the `World` traversal can be skipped entirely when accessing the player!
   - **`GWorld` via Viewport**: If level, actor, or world physics context is needed, `GWorld` can be obtained from the **`GameViewport`** field inside `GEngine` (`GEngine->GameViewport->World`).

---

## Standard Hierarchy Traversal

Because `GEngine` links directly to `GameInstance`, you can resolve player controllers and pawns without going through `World`:

```
GEngine (UEngine* / UGameEngine*)
├── GameInstance (UGameInstance*)                    [Direct link - skips World!]
│   └── LocalPlayers (TArray<ULocalPlayer*>)         [Offset: ~0x38]
│       └── LocalPlayers[0] (ULocalPlayer*)
│           └── PlayerController (APlayerController*) [Offset: ~0x30]
│               ├── AcknowledgedPawn (APawn*)       [Offset: ~0x2A0 - 0x338]
│               │   ├── RootComponent (USceneComponent*) [Offset: ~0x130 - 0x170]
│               │   │   └── RelativeLocation (FVector: X, Y, Z float)
│               │   │   └── ComponentVelocity (FVector)
│               │   ├── CharacterMovement (UCharacterMovementComponent*)
│               │   │   ├── MaxWalkSpeed (float) [Default: 600.0]
│               │   │   ├── JumpZVelocity (float)
│               │   │   └── GravityScale (float)
│               │   └── PlayerState (APlayerState*)
│               └── PlayerCameraManager (APlayerCameraManager*)
└── GameViewport (UGameViewportClient*)             [Optional: when World context is needed]
    └── World (UWorld* / GWorld)
```


---

## Workflows & Tools

### 1. Using Cheat Engine's Built-in UETools
Cheat Engine bundles the `UETools` extension (`UEInfoScanner.LUA` and `UEInfoStructureDissect.LUA`):
1. Attach Cheat Engine to the Unreal game process.
2. In Cheat Engine main menu, select **UETools** -> **Scan for UE Info**.
3. The scanner locates:
   - **`GEngine`** static address (registered as the `[GEngine]` symbol).
   - `GNames` table base and version (UE 4.0 - 4.22 chunked array vs UE 4.23+ `FNamePool`).
   - `GUObjectArray` base address.
4. Once scanned, `GWorld` is resolved through `GEngine->GameViewport->World`, and you can open **UETools Structure Dissect** (or menu **Dissect GEngine**) to view classes, methods, and fields by their engine-defined names rather than raw offsets!

> [!CAUTION]
> ### CRITICAL: NEVER Dump the `UEngine` Lua Table
> Scanning for UE info populates the global `UEngine` table in Cheat Engine's Lua environment.
> - **NEVER dump or serialize `UEngine`**: Do NOT call `print(tableToString(UEngine))`, `inspect(UEngine)`, `json.encode(UEngine)`, or run any recursive/loop-based table enumerations on `UEngine`.
> - **Stay away from `UEngine.NameToIndex` and `UEngine.IndexToName`**: These tables cache the game's entire `FNamePool` / `GNames` list (often hundreds of thousands of entries). Attempting to enumerate, dump, or serialize them will freeze or crash Cheat Engine, exhaust memory, overflow MCP/LLM communication buffers, and hang background worker threads.
> - **Query individual strings or FName indexes instead**: Always perform targeted lookups directly by key rather than enumerating:
>   ```lua
>   -- Safe: Query FName index for a specific string
>   local engineIndex = UEngine.NameToIndex['GameEngine']
>   local pawnIndex = UEngine.NameToIndex['AcknowledgedPawn']
>
>   -- Safe: Query string for a specific FName index
>   local name = UEngine.IndexToName[nameIndex]
>   ```

### 2. Manual AOB Scanning for `GWorld`
If `UETools` auto-scan cannot locate `GWorld`, pattern scan for the instruction referencing `GWorld`:

Common x64 patterns:
```asm
// Pattern 1 (Direct RIP-relative mov):
48 8B 05 ?? ?? ?? ?? 48 8B 88 ?? ?? 00 00

// Pattern 2:
48 8B 1D ?? ?? ?? ?? 48 85 DB 74 ?? 48 8B 83
```
- The `?? ?? ?? ??` is a signed 32-bit offset relative to `RIP` of the next instruction:
  `GWorld = instructionAddress + 7 + offset`.

### 3. Modifying Common Unreal Gameplay Attributes

#### Player Speed & Movement
Locate `CharacterMovementComponent` via `AcknowledgedPawn`:
- `MaxWalkSpeed` (`float`): Multiply by `2.0` or `3.0` for speedhack.
- `GravityScale` (`float`): Set to `0.0` or `0.1` for low-gravity float.
- `MovementMode` (`byte`): Setting to `5` (`MOVE_Flying`) enables noclip/flight in many UE titles.

#### Teleportation & Position
Locate `RootComponent` -> `RelativeLocation`:
- Stored as three consecutive 32-bit floats (`X`, `Y`, `Z`) or 64-bit doubles (`Large World Coordinates` in UE 5.0+).
- Reading `RelativeLocation` yields current coordinates. Writing modifies pawn position directly.

### 4. Intercepting `ProcessEvent`
All Blueprint and dynamic Unreal methods are routed through:
`void UObject::ProcessEvent(UFunction* Function, void* Parms)`
- Hooking `ProcessEvent` enables:
  - Logging every event invoked by the engine (god-view of game logic).
  - Intercepting damage events (e.g. `ReceivePointDamage`, `ApplyDamage`) and zeroing incoming damage.
  - Calling in-game functions with custom parameters.

### 5. Inspecting Class Definitions & Offsets via Published UETools APIs
Cheat Engine's `UETools` publishes several global Lua helper functions for introspecting runtime objects, querying class layouts, and locating object base addresses from interior pointers:

| Function | Purpose | Return Value |
| :--- | :--- | :--- |
| `UObject_enumProperties(address)` | Enumerate all properties (including inherited ones) of an instantiated `UObject`. | Table of `[propName] = { offset, size, propertyType, propertyAddress }` |
| `UClass_enumProperties(class, [usealt], [r])` | Enumerate all properties directly from a `UClass` or `UStruct` pointer. | Table of `[propName] = { offset, size, propertyType, propertyAddress }` |
| `UEngine_findObjectStart(startAddress)` | Scan backwards from an arbitrary interior memory address to find the enclosing `UObject` base. | Base address of the enclosing `UObject`, or `nil` |
| `UObject_getName(UObjectAddress)` | Resolves the runtime engine name of an object instance. | String (e.g. `"BP_HeroCharacter_C_1"`), or `nil` |

- **Why use these functions**: Instead of hardcoding fragile offsets across game updates, you can dynamically resolve exact property offsets at runtime (e.g. `props['Health'].offset` or `props['CharacterMovement'].offset`).
- **Enclosing Object Discovery (`UEngine_findObjectStart`)**: When a memory scan or breakpoint identifies a specific attribute address (e.g. health float at `0x7FF...B8`), calling `UEngine_findObjectStart(0x7FF...B8)` walks backward to locate the base `APawn` or `ACharacter` pointer and verifies that the field offset falls within the object.

---

## Example Lua Integration in Cheat Engine

### 1. Safe `UEngine` Lookups (Never Dump `UEngine`)

```lua
-- NEVER do this! Enumerating NameToIndex/IndexToName freezes or crashes Cheat Engine:
-- print(tableToString(UEngine))

-- DO: Query individual strings or FName indexes directly:
if UEngine and UEngine.NameToIndex then
  local engineClassIndex = UEngine.NameToIndex['GameEngine']
  local actorClassIndex  = UEngine.NameToIndex['Actor']
  print(string.format("GameEngine FName index: %s", tostring(engineClassIndex)))
end

-- DO: Resolve an FName index read from an object into its string:
function resolveFName(index)
  if UEngine and UEngine.IndexToName then
    return UEngine.IndexToName[index & 0xFFFFFFFF] or "Unknown"
  end
  return nil
end

-- DO: Access known scalar offsets directly:
if UEngine and UEngine.UObject then
  print(string.format("UObject.Class offset: 0x%X", UEngine.UObject.Class))
  print(string.format("UObject.Name offset: 0x%X", UEngine.UObject.Name))
end
```

### 2. Resolving Local Pawn from `GEngine` (skipping World)

```lua
-- Resolving local pawn directly from GEngine (skipping World):
function getLocalPawnFromGEngine(gengineAddr, offsets)
  local is64 = targetIs64Bit()
  local engine = is64 and readQword(gengineAddr) or readInteger(gengineAddr)
  if engine == nil or engine == 0 then return nil end
  
  -- GEngine has a direct link to GameInstance (no need to go through World):
  local gameInstance = readQword(engine + offsets.gameInstance)
  if gameInstance == nil or gameInstance == 0 then return nil end
  
  local localPlayers = readQword(gameInstance + offsets.localPlayers)
  local localPlayer0 = readQword(localPlayers) -- First element of TArray
  if localPlayer0 == nil or localPlayer0 == 0 then return nil end
  
  local playerController = readQword(localPlayer0 + offsets.playerController)
  local pawn = readQword(playerController + offsets.pawn)
  
  return pawn
end
```

### 3. Enumerating Properties and Finding Object Bases Dynamically

```lua
-- 1. Locate the base UObject pointer from an interior address (e.g. from a float scan for health):
local foundHealthAddress = 0x12345678 -- Example address from a memory scan
local objectBase = UEngine_findObjectStart(foundHealthAddress)

if objectBase then
  local objectName = UObject_getName(objectBase)
  print(string.format("Found enclosing object: %s at 0x%X", objectName or "Unknown", objectBase))

  -- 2. Enumerate all properties for this object (automatically includes parent/super classes):
  local props = UObject_enumProperties(objectBase)
  if props then
    -- Inspect specific property offsets and types without dumping the whole table:
    if props['Health'] then
      print(string.format("Health offset: 0x%X (Type: %s, Size: %d)", 
        props['Health'].offset, props['Health'].propertyType, props['Health'].size or 0))
    end
    if props['MaxHealth'] then
      print(string.format("MaxHealth offset: 0x%X", props['MaxHealth'].offset))
    end
    if props['CharacterMovement'] then
      print(string.format("CharacterMovement offset: 0x%X", props['CharacterMovement'].offset))
    end
  end
end

-- 3. Enumerate properties directly from a UClass pointer (without needing an object instance):
-- Example: Reading class definition of GameEngineClass
if UEngine and UEngine.GameEngineClass then
  local engineProps = UClass_enumProperties(UEngine.GameEngineClass)
  if engineProps and engineProps['GameInstance'] then
    print(string.format("GameInstance offset in GameEngine: 0x%X", engineProps['GameInstance'].offset))
  end
end
```
