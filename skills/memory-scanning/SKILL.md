---
name: memory-scanning
description: Advanced memory scanning strategies, selecting correct data types, unknown initial value workflows, changed/unchanged filtering, memory page protection filters, and Lua automation. Use this skill when searching for values in game memory or refining scans.
---

# Cheat Engine Memory Scanning Skill

The `memory-scanning` skill guides AI agents and reverse engineers in selecting optimal data types, scan configurations, and filtering strategies to isolate values in target memory quickly and accurately.

---

## When to Use This Skill

Activate this skill when:
- Searching for game values (health, ammunition, currency, timers, coordinates, cooldowns).
- Isolating unknown or obfuscated values using relative scan types (`soUnknownValue`, `soDecreasedValue`, `soIncreasedValue`, `soUnchangedValue`).
- Setting up memory protection filters (writable, executable, copy-on-write).
- Automating memory scans using Cheat Engine's Lua API (`createMemScan`, `refineScan`, `createFoundList`).
- Choosing between integer, floating-point, double-precision, or array-of-byte (AOB) representations.

---

## Data Type Selection Matrix

Selecting the incorrect data type is the most common cause of failed scans:

| Value Type in Game | Recommended CE Type (`VarType`) | Reason & Identification |
| :--- | :--- | :--- |
| **Visible Integers** (Ammo, Coins, Level, Inventory Count) | `vtDword` (4-byte integer) | Default for almost all 32-bit and 64-bit game engines. |
| **Counters / Small values** (< 255 or < 65535) | `vtByte` (1-byte) or `vtWord` (2-byte) | Rarely used for primary stats, but common in retro/indie games and flags. |
| **Smooth / Animated HUD** (Health bars, Mana, Energy, Stamina) | `vtSingle` (4-byte Float) | Smooth progress bars almost always interpolate floats between `0.0f` and `100.0f` or `1.0f`. |
| **Physics & Coordinates** (Position X/Y/Z, Velocity, Speed, Angles) | `vtSingle` (Float) or `vtDouble` (Double) | World space coordinates in 3D games are IEEE 754 floats. UE5 games with Large World Coordinates use Doubles. |
| **Massive RPG Currency** (> 2 billion) | `vtQword` (8-byte integer) or `vtDouble` | Used to prevent 32-bit integer overflow. |
| **Text / Names** (Character names, dialogue) | `vtString` or `vtWideString` | ASCII/UTF-8 vs UTF-16 (Windows native). |
| **Code / Instructions** (Functions, Jumps, Calls) | `vtByteArray` (Array of Byte / AOB) | Matching machine instructions using wildcards (`??`). |

---

## The Unknown Initial Value Workflow

When a value is not displayed on-screen as a direct number (e.g., an unlabeled health bar, durability bar, or hidden cooldown), use relative differential scanning:

### Step 1: Initial Scan
- Open process in Cheat Engine.
- Set **Scan Option** to `Unknown initial value` (`soUnknownValue`).
- Set **Value Type** to `Float` (for smooth bars) or `4 Bytes` (for stepped bars/ammo).
- Click **First Scan**. CE will index millions of memory addresses.

### Step 2: Value Decreased Filter
- Return to game and perform an action that lowers the value (take damage, fire a shot).
- In CE, change **Scan Option** to `Decreased value` (`soDecreasedValue`).
- Click **Next Scan**. The results list drops significantly.

### Step 3: Unchanged Value Filter (The "Noise Eliminator")
- Return to game and do **nothing** (stand still, pause action).
- Change **Scan Option** to `Unchanged value` (`soUnchangedValue`).
- Click **Next Scan**. This eliminates thousands of transient background variables, clocks, and frame counters.

### Step 4: Value Increased Filter
- Return to game and heal or collect ammo.
- Change **Scan Option** to `Increased value` (`soIncreasedValue`).
- Click **Next Scan**.

### Step 5: Repeat until Isolated
- Alternate between `Decreased value`, `Unchanged value`, and `Increased value` until fewer than 10 addresses remain.
- Freeze or modify candidates one-by-one to confirm the true address.

---

## Performance & Filter Settings

### Memory Protection & Active Memory
- **Writable (`fsm_Writable` / `fsm_CopyOnWrite`)**: Check this box for all variable scans. Memory containing values that change must be writable.
- **Executable (`fsm_Executable`)**: Leave unchecked for data scans to skip scanning code segments (`.text`). Check only when scanning for opcodes / AOBs.
- **Active memory only**: The "Active memory only" option scans only paged-in memory. This is especially handy to skip huge swaths of memory like static lookup tables or uncommitted memory pages which are not useful for target values.

### FastScan & Alignment
- **FastScan (Alignment)**:
  - Default: `4-byte aligned` (`alignment = 4`). Standard variables in C/C++ are aligned to their type size (`sizeof(int)` = 4).
  - Unaligned scanning is only needed if scanning for packed structs or arbitrary strings.

---

## Automating Scans via Cheat Engine Lua

In modern Cheat Engine releases (7.7 and later), you do not explicitly need a `foundlist` to retrieve addresses. You can use the `memscan` object's **`Results`** property:
- `ms.Results` returns an indexed table containing all found addresses.
- Accessing `ms.Results` automatically calls `ms.waitTillDone()` for you!
- **When to use `foundlist` instead**: `ms.Results` provides address pointers only. It does not automatically read or cache their current values. If you need both the addresses and their current values, a `foundlist` (`createFoundList(ms)`) remains the more optimized approach.

```lua
-- Modern CE 7.7+ scanning using ms.Results:
function performAutoScan(val, vartype)
  local ms = createMemScan()
  ms.ScanValue = tostring(val)
  ms.VarType = vartype or 'vtDword'
  ms.ScanOption = 'soExactValue'
  
  -- FastScan 4-byte alignment
  ms.scan()
  
  -- In CE 7.7+, accessing ms.Results automatically waits for scan completion
  -- and returns an indexed table of addresses:
  local results = ms.Results
  print(string.format("Found %d results.", #results))
  
  for i = 1, math.min(#results, 10) do
    print(string.format("[%d] Address: 0x%X", i, results[i]))
  end
  
  ms.destroy()
end
```


---

## Handling Obfuscated / Encrypted Values
If exact scans fail repeatedly:
1. **Multiplied Floats**: Some games store float values as integers multiplied by 100 or 1000 (e.g. 75.5% health stored as `7550`).
2. **XOR Encryption**: Many anti-cheat protected or mobile games store a random key alongside the value: `StoredValue = RealValue ^ Key`. Use "Find out what writes to this address" or scan for `Unknown initial value` with relative changes.
3. **Double Buffering**: Two copies of the stat exist: a display copy and a logical copy. Changing the display copy gets overwritten immediately. Always find the instruction that writes to the address to locate the master structure.
