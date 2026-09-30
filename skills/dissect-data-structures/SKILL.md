---
name: dissect-data-structures
description: Reverse engineering unknown memory blocks and structs using Cheat Engine Structure Dissect, identifying vtables, pointer chains, strings, and comparing multiple entities side-by-side. Use this skill when analyzing object layouts, class fields, entity structures, and unknown buffers.
---

# Cheat Engine Structure Dissect Skill

The `dissect-data-structures` skill provides AI agents and reverse engineers with systematic methodologies for mapping, labeling, and comparing complex game structures and C++ classes using Cheat Engine's **Structure Dissect** tool.

---

## When to Use This Skill

Activate this skill when:
- You have found one address in an entity (e.g., Health at `0x7FFF12345678`) and need to map the entire entity structure (MaxHealth, Speed, Armor, Inventory, Position, Team).
- Reverse engineering unknown C++ object hierarchies and finding virtual method tables (VMT / VTable).
- Comparing multiple game entities side-by-side (e.g., Player vs Enemy 1 vs Enemy 2) to quickly isolate discriminating fields (Team ID, Coordinates).
- Generating C struct headers or Cheat Engine table entries for complex game classes.

---

## Automatic Structure Population (Extensions & Symbols)

Before manually guessing or typing fields, leverage Cheat Engine's automatic structure resolvers:
- **Mono / IL2CPP & UETools**: Extensions like `monoscript` and `uetools` can automatically populate structure layouts based on runtime type detection of the given address (e.g. dissecting a Mono object pointer or `[GEngine]`).
- **Debug Symbols (PDB / DWARF)**: If the target application has debug symbols loaded in Cheat Engine, Structure Dissect can automatically populate structure layouts, exact field names, data types, and offsets using that debug information.

---

## How to Open Structure Dissect

1. **Via Memory View**:
   - Open Cheat Engine **Memory View** (`Ctrl+M`).
   - Click **Tools** -> **Dissect Data/Structures** (`Ctrl+D`).
2. **From the Address List**:
   - Right-click any memory address record in the Address List -> **Browse this memory region** -> press `Ctrl+D`.
3. **Via Lua**:
   ```lua
   createStructureForm(address)
   ```

---

## The Heuristic Field Identification Guide


Cheat Engine can automatically guess variable types (File -> New Structure -> Guess structure size and types). Here is how to verify and classify fields manually:

### 1. Virtual Method Table (`VTable` / `vptr`)
- **Location**: Almost always at offset `0x00` in non-POD C++ classes with virtual methods.
- **Characteristics**: An 8-byte pointer (in x64) pointing into the `.rdata` section of a loaded module (`game.exe+0x...`).
- **Verification**: In Memory View, jump to the pointer address. You should see a list of function pointers.

### 2. Pointer Fields vs Integers
- An 8-byte value is likely a **pointer** if:
  - It falls within the target process's heap or module address range (e.g. `0x00007FFF...` in 64-bit Windows).
  - Following the address leads to readable memory with valid headers or data.
- It is an **integer** if:
  - It is small (e.g. `0`, `1`, `100`, `999`), negative, or represents a bitmask (`0x0000000F`).

### 3. Floats vs Integers
- **Float (`vtSingle`)**:
  - If interpreted as an integer, floats look like large numbers (`0x3F800000` = `1.0f`, `0x42C80000` = `100.0f`).
  - Values between `0.001` and `10000.0` or coordinates (e.g. `1245.32`, `-452.1`) are floats.
  - Groups of 3 consecutive floats (`X`, `Y`, `Z`) at an offset indicate position or velocity vectors (`FVector` or `Vector3`).

### 4. Text and Strings
- **Inline ASCII/UTF-8**: 1-byte characters visible as readable text directly in the hex dump.
- **WideString (UTF-16)**: Alternating character bytes with null bytes (e.g. `P \0 l \0 a \0 y \0 e \0 r \0`).
- **String Pointers**: A pointer to an external buffer accompanied by an integer length and capacity field (like `std::string` or `FString`).

---

## The Multi-Instance Comparison Technique (The "Secret Weapon")

Comparing multiple instances side-by-side in Structure Dissect is the fastest way to isolate entity fields without reading assembly:

### Step 1: Collect Candidate Addresses
1. Locate your Player entity address (e.g., `0x7FFF00100`).
2. Locate an Enemy entity address (e.g., `0x7FFF00800`).
3. Locate a second Enemy or Neutral entity address (e.g., `0x7FFF00F00`).

### Step 2: Add Columns in Structure Dissect
1. In Structure Dissect, enter the Player address for **Group 1**.
2. Click **Structures** -> **Add new group / column**.
3. Add Enemy 1 as **Group 2**, and Enemy 2 as **Group 3**.

### Step 3: Differentiate Fields
- **Lock Rows**: Click **View** -> **Lock selected rows** to keep matching headers in sync.
- Observe:
  - **Shared identical values**: Global configurations, class descriptors, max health settings, vtable pointers.
  - **Differentiating values**:
    - **Team ID**: Player has `0` or `1`, enemies have `2` or `3`.
    - **Health**: Decreases in real-time only in the attacked enemy's column.
    - **Coordinates**: Slightly varying floats across all 3 columns that change when moving.

---

## Exporting Structures to Code

Once you define and label fields in Structure Dissect:
- **Export to C Header File**: Select **File** -> **Export** -> **C header file**.
- **Generate Auto Assembler Template**: Create defines for offsets:
  ```asm
  define(OFFSET_VTABLE,       0x00)
  define(OFFSET_TEAM_ID,      0x18)
  define(OFFSET_HEALTH,       0x30)
  define(OFFSET_MAX_HEALTH,   0x34)
  define(OFFSET_COORDINATES,  0x50)
  ```
- **Sync with Address List**: Create parent memory records representing base entities and add child records with these relative offsets.
