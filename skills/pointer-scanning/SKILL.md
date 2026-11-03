---
name: pointer-scanning
description: Multilevel pointer scanning, generating and comparing pointermaps, resolving static base addresses (module+offset), verifying pointer chains across restarts, and Cheat Engine pointer resolution APIs. Use this skill when finding reliable pointers for dynamically allocated memory addresses (health, ammo, player base, etc.).
---

# Cheat Engine Pointer Scanning Skill

The `pointer-scanning` skill enables AI agents and reverse engineers to systematically locate stable multi-level pointer paths from static module bases to dynamic heap or stack structures across game restarts and updates.

---

## When to Use This Skill

Activate this skill when:
- Finding a static pointer path for a dynamic memory address (e.g. ammo, gold, health, coordinates).
- Creating Cheat Engine address list records that persist across game restarts without manual re-scanning.
- Generating, sorting, and comparing `.scandata` pointermaps to eliminate false positives.
- Resolving multi-level pointer offsets (`[[[[module.exe+base]+offset1]+offset2]+offset3]`).
- Using Cheat Engine Lua APIs to dynamically resolve pointer paths (`readPointer`, `createMemoryRecord` with offsets).

---

## Core Principles

1. **Static vs Dynamic Addresses**:
   - Addresses in the heap or stack change every time the game runs, changes levels, or reallocates memory.
   - Static pointers reside in read-only or data sections of the game executable (`game.exe+0x...`) or loaded DLLs (`GameAssembly.dll+0x...`).
2. **Multi-level Chains**:
   - Modern game engines (C++, Unreal, Unity, etc.) use object hierarchies:
     `Global Engine -> GameInstance -> PlayerArray[0] -> PlayerCharacter -> Attributes -> Health`.
   - Each arrow represents a pointer dereference plus an offset.

---

## Step-by-Step Workflow: The 2-Pass Pointermap Method

The most reliable and time-efficient technique in Cheat Engine is generating two pointermaps from separate game sessions and comparing them.

### Step 1: Session 1 Setup and First Pointermap
1. Open the target process in Cheat Engine.
2. Find the target value address (e.g. Health address: `0x7FFF104B8C10`).
3. Add the address to the Address List.
4. In Cheat Engine main menu:
   - Click **Memory View** -> **Tools** -> **Generate Pointermap**.
   - Save as `pointermap_session1.scandata`.
   - Wait until generation completes (this maps all 4-byte/8-byte pointer relationships in memory).

### Step 2: Session 2 Setup and Second Pointermap
1. Completely close the game and restart it.
2. Re-attach Cheat Engine to the new process.
3. Find the same target value again (e.g. new Health address: `0x7FFF217D4190`).
4. Generate a second pointermap:
   - **Memory View** -> **Tools** -> **Generate Pointermap**.
   - Save as `pointermap_session2.scandata`.

### Step 3: Running the Compared Pointer Scan
1. In the Address List, right-click the Session 2 address (`0x7FFF217D4190`) and select **Pointer scan for this address**.
2. Configure Scan Settings:
   - **Check**: "Use saved pointermap" -> Select `pointermap_session2.scandata`.
   - **Check**: "Compare results with other saved pointermap(s)" -> Select `pointermap_session1.scandata`.
   - In the comparison row, enter the Session 1 address: `0x7FFF104B8C10`.
   - **Max Level**: Set to `4` or `5` (higher levels like 7+ exponentially increase scan time and false positives).
   - **Max Offset**: Set to `4096` (`0x1000`) or `8192` (`0x2000`).
   - **Check**: "Only filter on module addresses" (ensures the base is an export or static module address, e.g., `game.exe+0x1234`).
3. Click **OK** and save the pointer scan results file (`results.ptr`).

### Step 4: Evaluating and Filtering Results
1. Cheat Engine will display thousands or hundreds of thousands of candidate pointer paths.
2. Sort candidates:
   - **Offset Count (Level)**: Fewer levels (e.g. 2 or 3 offsets) are generally much more stable than deep chains (6+ offsets).
   - **Base Module**: Paths starting with `game.exe` or main game DLLs (e.g. `mono-2.0-bdwgc.dll`, `Engine.dll`) are significantly better than paths starting in Windows system libraries (`ntdll.dll`, `kernelbase.dll`).
3. Select the top 3-5 candidates and double-click them to add them to your Address List.
4. Test stability:
   - Restart the game a 3rd time.
   - Attach CE and check if the pointer records automatically resolve to the correct value.

---

## Lua Automation & Cheat Engine Tools

### Resolving Pointers in Lua
```lua
-- Resolving a multi-level pointer chain in CE Lua:
function resolvePointerChain(baseAddressStr, offsets)
  local addr = getAddressSafe(baseAddressStr)
  if addr == nil or addr == 0 then return nil end

  local is64 = targetIs64Bit()
  for i = 1, #offsets do
    local offset = offsets[i]
    if type(offset) == 'string' then
      offset = tonumber(offset, 16) or getAddressSafe(offset) or 0
    end
    
    local ptr = is64 and readQword(addr) or readInteger(addr)
    if ptr == nil or ptr == 0 then return nil end
    addr = ptr + offset
  end
  return addr
end
```

### Adding a Pointer Record to Address List via AITools
```lua
-- Example calling createMemoryRecord with pointer offsets:
createMemoryRecord({
  description = "Player Health (Pointer)",
  address = "game.exe+0x1A2B3C",
  offsets = {"0x18", "0x40", "0x2F0"},
  vartype = "vtSingle"
})
```

---

## Common Pitfalls & Troubleshooting
- **Pointer points to NULL (0x0)**: The entity may only be instantiated when a level is actively loaded. Pointers to player characters are invalid in main menus.
- **Multiple paths change on level change**: Some paths are tied to thread stacks or temporary scene allocators. Prefer paths whose first offset points to a global manager or singleton instance.
- **Anti-Cheat Pointer Protection**: Some engines XOR or bit-rotate heap pointers. If pointer scans yield 0 results, inspect assembly code accessing the address using "Find out what accesses this address".
