---
name: auto-assembler
description: Writing Cheat Engine Auto Assembler (AA) scripts, embedded C blocks ({$c} and {$ccode}), AOB scanning (aobscanmodule), memory allocation (alloc), register preservation, code caves, assembly hooks, and enable/disable templates. Use this skill when generating, debugging, or analyzing Cheat Engine Auto Assembler injection scripts, cheat tables, and memory patches.
---

# Cheat Engine Auto Assembler Skill

The `auto-assembler` skill guides AI agents and reverse engineers in writing robust, patch-resistant, and crash-proof Cheat Engine Auto Assembler (AA) scripts.

---

## When to Use This Skill

Activate this skill when:
- Creating Auto Assembler scripts with `[ENABLE]` and `[DISABLE]` sections.
- Embedding native C code (`{$c}` and `{$ccode}`) for complex game logic, algorithms, state tracking, and string formatting without writing low-level assembly.
- Writing Array of Byte (AOB) injection scripts that survive game updates (`aobscanmodule`,`aobscanfunction`,`aobscanregion`).
- Implementing code caves, mid-function hooks, or function detours.
- Preserving CPU registers and flags (`pushfq`/`popfq`, `pushaq`/`popaq`, 32-bit `pushad`/`popad`).
- Ensuring 16-byte stack alignment and 32-byte shadow space in x64 Windows ABI during calls.
- Verifying syntax and testing AA scripts programmatically (`check_auto_assemble_syntax`, `auto_assemble`).

---

## Script Architecture & Template

Every reliable Auto Assembler script should follow the standard `[ENABLE]` / `[DISABLE]` template:

```asm
{ Game   : GameName.exe
  Version: 1.0.0
  Date   : YYYY-MM-DD
  Author : Cheat Engine Assistant
}

[ENABLE]
aobscanmodule(INJECT, GameName.exe, 89 83 48 02 00 00 48 8B) // Match unique bytes with wildcards
alloc(newmem, $1000, INJECT)

label(code)
label(return)

newmem:
  // 1. Optional: Filter target entities (e.g., check if entity == player)
  // cmp [rbx+0x10], 1
  // jne code

  // 2. Custom cheat logic
  // mov [rbx+0x00000248], #999  // Lock ammo or health to 999
  // or bypass subtraction by skipping the write entirely

code:
  // 3. Stolen original instructions exactly as in target process
  mov [rbx+0x00000248], eax
  jmp return

INJECT:
  jmp newmem
  nop             // Pad extra bytes if stolen instructions exceed 5 bytes
return:
registersymbol(INJECT)

[DISABLE]
INJECT:
  // Restore original unmodified opcode bytes
  db 89 83 48 02 00 00

unregistersymbol(INJECT)
dealloc(newmem)
```

---

## Critical Rules for Crash-Free Scripts

### 1. Near Allocation in 64-Bit Processes
- Always pass the injection address as the 3rd argument to `alloc`:
  ```asm
  alloc(newmem, $1000, INJECT)
  ```
- **Why**: In 64-bit processes, an unconditional relative jump `jmp newmem` takes 5 bytes (`E9 xx xx xx xx`) but is limited to a 32-bit offset (+/- 2GB). Passing `INJECT` forces Cheat Engine to allocate `newmem` within 2GB of `INJECT`, avoiding crashes from 14-byte absolute jumps (`FF 25 ...`).

### 2. Instruction Boundary & Byte Padding
- A `jmp` hook requires **at least 5 bytes**.
- You **must never** cut an x86/x64 instruction in half!
  - If the target instruction is 3 bytes (e.g. `sub [rax], ecx`), and the next is 4 bytes (e.g. `mov edx, [rax+4]`), your hook covers 7 bytes.
  - Stolen bytes must include **both** instructions in full.
  - Pad the remaining 2 bytes at `INJECT` with `nop` (`90 90`).

### 3. Preserving Registers & CPU Flags
If your custom code modifies registers or performs comparisons, always preserve flags:

**64-Bit Register Preservation:**
```asm
newmem:
  pushfq                 // Save RFLAGS (zero flag, sign flag, carry flag)
  push rax
  push rbx
  push rcx
  push rdx
  push rsi
  push rdi
  push r8
  push r9
  push r10
  push r11

  // -- Custom logic / Function calls --

  pop r11
  pop r10
  pop r9
  pop r8
  pop rdi
  pop rsi
  pop rdx
  pop rcx
  pop rbx
  pop rax
  popfq                  // Restore RFLAGS
```

**32-Bit Register Preservation:**
```asm
newmem:
  pushfd                 // Save EFLAGS
  pushad                 // Save all 32-bit GPRs
  
  // -- Custom logic --

  popad
  popfd
```

### 4. Calling Functions from AA Hooks (x64 Windows ABI)
If you invoke a function using `call` inside `newmem`:
1. **16-Byte Stack Alignment**: The RSP register must be aligned to a 16-byte boundary prior to the `call` instruction.
2. **Shadow Space**: Windows x64 requires allocating at least 32 bytes (`sub rsp, 28h` or `sub rsp, 20h`) of scratch space before the call:
```asm
  sub rsp, 28h          // 32-byte shadow space + 8-byte alignment
  call SomeFunctionAddress
  add rsp, 28h          // Clean up shadow space
```

### 5. Handling RIP-Relative Stolen Bytes
If the original stolen instruction uses RIP-relative addressing (e.g., `mov rax, [rip+0x1234]`), moving that instruction into `newmem` changes RIP, causing it to access invalid memory!
- **Fix**: Re-encode the instruction using absolute addressing in `newmem`, or pick a hook site before/after the RIP-relative instruction.

---

## Embedded C Code: `{$c}` and `{$ccode}`

Cheat Engine allows embedding C code directly into Auto Assembler scripts. The C source is compiled at assembly time by an internal TinyCC (TCC) compiler and executed natively by the target process.

### Architecture & Compilation Mechanics

1. **Unified Translation Unit**: During assembly Pass 1, Cheat Engine extracts **all** `{$c}` and `{$ccode}` blocks across the entire script and combines them into a single C source file.
2. **Automated Memory Allocation**: Cheat Engine automatically inserts `alloc(ceinternal_autofree_ccode, <size>)` at the top of the AA script to allocate executable memory for the compiled C code.
3. **Symbol Resolution via `extern`**: Any symbol declared with `extern` in C that is not defined in the C code itself is resolved dynamically through Cheat Engine's symbol handler (`symhandler`). This includes:
   - AA-allocated buffers (`alloc`) and labels (`label`).
   - Registered symbols (`registersymbol`).
   - Exported functions from target process modules (e.g., `ntdll.sprintf`, `kernel32.GetTickCount`).
4. **Source-Level Debugging**: Unless the `NODEBUG` parameter is specified, Cheat Engine generates debug line information mapping machine instructions back to C source lines. When stepping through the hook in Cheat Engine's debugger, you can see and step through the original C code.

---

### Core Differences: `{$c}` vs `{$ccode}`

| Feature | `{$c} ... {$asm}` | `{$ccode [parameters]} ... {$asm}` |
| :--- | :--- | :--- |
| **Placement** | **Anywhere** in the script (top-level, headers, outside code caves) | **Only inside executable code** (e.g., within `newmem:`) |
| **Purpose** | Declaring structs, typedefs, global variables, external signatures, and standalone helper functions | Inline code cave hooks, register manipulation, and event handling |
| **Register Mapping** | None (standard C functions) | Automatic via `varname=REG` parameters |
| **Assembly Emitted** | None directly inline | Emits an inline `call` to an auto-generated safecall stub |
| **Stack & Calling Setup** | Caller must handle ABI/calling convention if called manually | Managed automatically by the generated safecall stub |
| **Symbol Registration** | Exported functions/variables are automatically registered in CE's symbol table | Functions are internal wrapper stubs unless using `PREFIX=` |

> [!IMPORTANT]
> `{$ccode}` emits an inline `call` opcode. You **must only** place `{$ccode}` inside executable sections (like `newmem:`). Placing it in global scope, above memory allocations, or inside pure data sections will corrupt memory layout and crash the process.
> In contrast, `{$c}` can be placed anywhere (top of script, between allocations, or at the bottom).

---

### Parameters & Register Mapping (`{$ccode}`)

Parameters passed to `{$ccode ...}` map CPU registers to local C variables using `variablename=registername` syntax separated by spaces.

```c
{$ccode playerbase=RCX newhealth=RBX decvalue=EAX}
```

#### 1. General Purpose Registers (GPR)
- **64-bit**: `RAX`, `RBX`, `RCX`, `RDX`, `RSI`, `RDI`, `RBP`, `RSP`, `R8` through `R15`. (Treated as `unsigned long long`).
- **32-bit**: `EAX`, `EBX`, `ECX`, `EDX`, `ESI`, `EDI`, `EBP`, `ESP`. (Treated as `unsigned long`).
- **ARM64**: `X0`..`X30` (64-bit), `W0`..`W30` (32-bit).

> [!NOTE]
> `RSP` / `ESP` is read-only. Modified values assigned to `RSP` in `{$ccode}` are not written back.

#### 2. Registers as Floats
Appending `F` to a GPR register name interprets the register's raw bit pattern directly as a single-precision `float`:
- `RAXF`, `RBXF`, `RCXF`, `RDXF`, `RSIF`, `RDIF`, `RBPF`, `R8F`..`R15F`
- `EAXF`, `EBXF`, `ECXF`, `EDXF`, `ESIF`, `EDIF`, `EBPF`

#### 3. Vector & SIMD Registers (XMM)
Cheat Engine provides built-in mappings for XMM registers:

- **Full 128-bit Register (`XMM0` through `XMM15`)**:
  When mapped as `var=XMM0`, Cheat Engine automatically introduces the `xmmreg` type:
  ```c
  typedef struct {
    union {
      struct {
        float f0;
        float f1;
        float f2;
        float f3;
      };
      struct {
        double d0;
        double d1;
      };
      float fa[4];
      double da[2];
    };
  } xmmreg, *pxmmreg;
  ```
  Access specific lanes using `var.f0`, `var.d0`, `var.fa[2]`, or `var.da[1]`.

- **Lane-Specific Float (`XMMn.lane` or `XMMn.laneF`)**:
  - `XMM0.0` through `XMM0.3` (or `XMM0.0F` .. `XMM0.3F`): Maps a single 32-bit float lane directly.
- **Lane-Specific Double (`XMMn.laneD`)**:
  - `XMM0.0D` and `XMM0.1D`: Maps a 64-bit double precision lane.
- **ARM64 SIMD**: `S0`..`S31` (float), `D0`..`D31` (double), `Q0`..`Q31` (128-bit vector).

#### 4. Block Modifiers & Options
Modifiers can be included in the header of `{$c}` or `{$ccode}`:
- `PREFIX=prefixName`: Prefixes exported symbols in the symbol table with `prefixName.` (e.g. `PREFIX=MyMod` creates `MyMod.myHelper`). Prevents name collisions across multiple scripts.
- `NODEBUG`: Disables generating debug line mappings (stepping through C code in CE debugger).
- `KERNELMODE` / `KALLOC`: Allocates the compiled C code in kernel space (Windows DBVM/kernel driver mode).
- `WINDOWS` / `WIN` vs `UNIX` / `LINUX` / `MACOS`: Overrides the target ABI calling convention (Windows x64 vs System V ABI).

---

### Symbol Resolution & `extern` Linking

Any global variable, AA label, or external function used inside C must be declared using `extern`. Cheat Engine's symbol handler will resolve it at assembly time:

```c
{$c}
// 1. External functions from target modules
extern __cdecl int sprintf(char *buffer, const char *format, ...);
extern void *malloc(unsigned long long size);
extern void free(void *ptr);

// 2. Variables or memory allocated in the AA script
extern int playerHealth;
extern char logBuffer[1024];
{$asm}
```

- When calling target APIs, ensure the calling convention is specified (`__cdecl`, `__stdcall`, etc.).
- Functions defined inside a `{$c}` block (that are not internal stubs) are added to Cheat Engine's global symbol list. You can call them directly from regular assembly code (`call MyHelperFunction`).

---

### Critical Rules & Pitfalls for `{$c}` and `{$ccode}`

> [!CAUTION]
> **DO NOT use early `return;` in `{$ccode}`!**
> Cheat Engine wraps `{$ccode}` inside an auto-generated function:
> 1. Unpack registers from parameter struct into local variables.
> 2. Execute user C code.
> 3. **Epilogue**: Copy local variables back to the parameter struct.
>
> If you execute `return;` in your C code, control returns **immediately**, skipping the epilogue! Any register changes you made will be lost. Use structured `if-else` blocks or `goto` to a label at the very end of the block instead of `return;`.

> [!IMPORTANT]
> - **Memory Dereferencing**: Always cast pointers before dereferencing raw memory addresses:
>   ```c
>   int health = *(int*)(playerBase + 0xB8);
>   *(float*)(playerBase + 0x140) = 100.0f;
>   ```
> - **No Header Includes Needed**: TCC does not have access to standard disk headers (`#include <stdio.h>` will fail). Declare needed functions and structs directly in `{$c}` or `{$ccode}` using `extern` and typedefs.
> - **Stack Alignment**: Cheat Engine's auto-generated safecall stub automatically handles 16-byte stack alignment and register saving before calling your `{$ccode}` function.

---

### Practical Examples

#### Example 1: Pure Inline `{$ccode}` Logic (Entity Filtering & God Mode)

```asm
[ENABLE]
aobscanmodule(HealthHook, Game.exe, 89 83 B8 00 00 00 48 8B)
alloc(newmem, $1000, HealthHook)
label(return)

newmem:
{$ccode entityPtr=RBX newHealth=EAX}
// Check if entity is player (flag at offset 0x10 == 1)
int isPlayer = *(int*)(entityPtr + 0x10);

if (isPlayer == 1) {
    newHealth = 9999; // Set health to 9999 for player
}
// Note: Do NOT use 'return;' here!
{$asm}

  mov [rbx+000000B8], eax
  jmp return

HealthHook:
  jmp newmem
  nop
return:
registersymbol(HealthHook)

[DISABLE]
HealthHook:
  db 89 83 B8 00 00 00
unregistersymbol(HealthHook)
dealloc(newmem)
```

#### Example 2: Struct Definition & Helper Function in `{$c}` with Inline `{$ccode}` Hook

```asm
[ENABLE]
aobscanmodule(DamageHook, Game.exe, F3 0F 11 83 40 01 00 00)
alloc(newmem, $1000, DamageHook)
label(return)

// Top-level {$c} block defines types and helper logic (can be anywhere in script)
{$c}
typedef struct {
    char pad[0x10];
    int teamId;
    char pad2[0x28];
    float maxHealth;
} Entity;

int IsFriendly(Entity *ent) {
    if (!ent) return 0;
    return ent->teamId == 1;
}
{$asm}

newmem:
// Inline {$ccode} hook executes inside the code cave
{$ccode ent=RBX newDamage=XMM0.0F}
Entity *target = (Entity*)ent;

if (IsFriendly(target)) {
    newDamage = 0.0f; // Friendly fire immunity
}
{$asm}

  movss [rbx+00000140], xmm0
  jmp return

DamageHook:
  jmp newmem
  nop 3
return:
registersymbol(DamageHook)

[DISABLE]
DamageHook:
  db F3 0F 11 83 40 01 00 00
unregistersymbol(DamageHook)
dealloc(newmem)
```

#### Example 3: Calling a `{$c}` Function Directly from Assembly

```asm
[ENABLE]
alloc(newmem, $1000)
label(code)
label(return)

// Global helper defined in {$c}
{$c PREFIX=CheatEngine}
int CalculateBonus(int baseVal, int multiplier) {
    return (baseVal * multiplier) + 500;
}
{$asm}

newmem:
  // Non-internal functions defined in {$c} are added to symbol table
  // Under x64 Windows ABI: RCX = 1st arg, RDX = 2nd arg
  sub rsp, 28h
  mov ecx, eax
  mov edx, 2
  call CheatEngine.CalculateBonus
  add rsp, 28h
  // EAX now contains the return value

code:
  mov [rsi+0x20], eax
  jmp return
```

#### Example 4: In-Game Logging with `sprintf` and AA-Allocated Buffers

```asm
[ENABLE]
aobscanmodule(ItemHook, Game.exe, 8B 48 08 89 4B 10)
alloc(newmem, $1000, ItemHook)
alloc(logBuffer, 2048)
alloc(logOffset, 4)
registersymbol(logBuffer)
registersymbol(logOffset)
label(return)

newmem:
{$ccode itemId=ECX entity=RAX}
extern char logBuffer[2048];
extern int logOffset;
extern __cdecl int sprintf(char *buf, const char *fmt, ...);

if (logOffset < 1900) {
    int written = sprintf(&logBuffer[logOffset], "Entity 0x%llX received item ID: %d\n", entity, itemId);
    if (written > 0) {
        logOffset += written;
    }
}
{$asm}

  mov ecx, [rax+08]
  mov [rbx+10], ecx
  jmp return

ItemHook:
  jmp newmem
  nop
return:
registersymbol(ItemHook)

[DISABLE]
ItemHook:
  db 8B 48 08 89 4B 10
unregistersymbol(ItemHook)
unregistersymbol(logBuffer)
unregistersymbol(logOffset)
dealloc(newmem)
dealloc(logBuffer)
dealloc(logOffset)
```

#### Example 5: SIMD / Vector Manipulation via `xmmreg`

```asm
[ENABLE]
aobscanmodule(PosHook, Game.exe, 0F 10 83 80 00 00 00)
alloc(newmem, $1000, PosHook)
label(return)

newmem:
{$ccode vec=XMM0}
// Modify vector components directly via built-in xmmreg union
vec.f0 += 10.0f; // Boost X coordinate
vec.f1 += 50.0f; // Boost Y coordinate
{$asm}

  movups [rbx+00000080], xmm0
  jmp return

PosHook:
  jmp newmem
  nop 2
return:
registersymbol(PosHook)

[DISABLE]
PosHook:
  db 0F 10 83 80 00 00 00
unregistersymbol(PosHook)
dealloc(newmem)
```

---

## Cheat Engine Auto Assembler Directives

| Directive | Purpose | Example |
| :--- | :--- | :--- |
| `aobscanmodule(sym, mod, hex)` | Scans specified module for byte pattern | `aobscanmodule(HealthHook, game.exe, F3 0F 11 83 ?? ?? 00 00)` |
| `aobscanfunction(sym, functionaddress, hex)` | Scans specified function for byte pattern | `aobscanfunction(HealthHook, player:setHealth, F3 0F 11 83 ?? ?? 00 00)` |
| `aobscanregion(sym, startaddress, stopaddress, hex)` | Scans specified region for byte pattern | `aobscanregion(HealthHook, player:setHealth, player:setHealth+100, F3 0F 11 83 ?? ?? 00 00)` |
| `alloc(sym, size, [preferAddr])` | Allocates virtual memory in target | `alloc(newmem, $1000, HealthHook)` |
| `dealloc(sym)` | Frees allocated memory on disable | `dealloc(newmem)` |
| `registersymbol(sym)` | Registers global symbol for CE address list and Lua references | `registersymbol(HealthHook)` |
| `unregistersymbol(sym)` | Removes global symbol | `unregistersymbol(HealthHook)` |
| `label(sym)` | Declares local code label | `label(code) label(return)` |
| `define(sym, val)` | Text replacement macro | `define(PLAYER_OFFSET, 0x1F8)` |
| `{$c [options]} ... {$asm}` | Embeds top-level C declarations, structs, helper functions, and globals anywhere in script | `{$c} int add(int a, int b) { return a+b; } {$asm}` |
| `{$ccode [params]} ... {$asm}` | Injects inline C hook into executable code with auto register binding | `{$ccode player=RCX hp=RBX} hp = 999; {$asm}` |
| `{$lua} ... {$asm}` | Executes embedded Lua script in CE | `{$lua} print("Script activated") {$asm}` |

---

## Testing Scripts via AITools
Before applying an Auto Assembler script to memory:
1. Validate syntax:
   `check_auto_assemble_syntax({ script = aaScript })`
2. If syntax check returns `{ result = "Success" }`, assemble or attach to memory record:
   `createMemoryRecord({ description = "God Mode", vartype = "vtAutoAssembler", script = aaScript })`
