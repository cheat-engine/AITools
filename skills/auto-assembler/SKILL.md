---
name: auto-assembler
description: Writing Cheat Engine Auto Assembler (AA) scripts, high-level detours (hook and unhook), embedded C blocks ({$c} and {$ccode}), AOB scanning (aobscanmodule), memory allocation (alloc), register preservation, code caves, and enable/disable templates. Use this skill when generating, debugging, or analyzing Cheat Engine Auto Assembler injection scripts, cheat tables, and memory patches.
---

# Cheat Engine Auto Assembler Skill

The `auto-assembler` skill guides AI agents and reverse engineers in writing robust, patch-resistant, and crash-proof Cheat Engine Auto Assembler (AA) scripts.

---

## When to Use This Skill

Activate this skill when:
- Creating Auto Assembler scripts with `[ENABLE]` and `[DISABLE]` sections.
- Writing high-level detours and trampolines using `hook(address, destination, originalcodelabel)` and `unhook(address)`.
- Embedding native C code (`{$c}` and `{$ccode}`) for complex game logic, algorithms, state tracking, and string formatting without writing low-level assembly.
- Writing Array of Byte (AOB) injection scripts that survive game updates (`aobscan`, `aobscanmodule`, `aobscanfunction`, `aobscanregion`).
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
- **Fix**: Re-encode the instruction using absolute addressing in `newmem`, or pick a hook site before/after the RIP-relative instruction. (Alternatively, use the high-level `hook` command which reassembles instructions automatically).

---

## AOB Scanning & Advanced Pattern Syntax

Auto Assembler provides multiple AOB scanning directives to locate dynamic code and data addresses across game updates without hardcoded offsets:
- `aobscan(symbolName, pattern)`: Scans all readable and executable memory in the target process.
- `aobscanmodule(symbolName, moduleName, pattern)`: Restricts the scan to the memory range of a specific module (e.g. `Game.exe`).
- `aobscanfunction(symbolName, functionAddress, pattern)`: Restricts the scan to the memory boundaries of a specific function.
- `aobscanregion(symbolName, startAddress, stopAddress, pattern)`: Restricts the scan to an explicit start and stop address range.

### Formatting Conventions & Best Practices
- **Space-Separated Bytes (Preferred)**: Always format AOB patterns with spaces separating each byte token (e.g. `89 83 ** ** ** ** 48 8B`).
- **Asterisk Wildcards (`*` Preferred)**: Use `*` (or `**` for an entire byte) for wildcards. While `?` is supported by Cheat Engine, `*` is the preferred convention across Cheat Engine scripts and tools.

### Advanced Pattern Matching Features

Cheat Engine's AOB scanner supports powerful byte-level, nibble-level, bit-level, and relational pattern operators:

#### 1. Binary Bitmasks (`|1001***0|`)
Enclose an 8-bit binary pattern in pipe characters (`|...|`) to scan at the individual bit level:
- Must be exactly 8 characters long between the pipes (representing 1 byte).
- Bits can be `0`, `1`, or `*` (wildcard bit).
- **Example**:
  ```asm
  aobscanmodule(BitmaskHook, Game.exe, 48 8B |1001***0| 20)
  ```
  This matches any byte whose bits 7, 6, 3, and 0 are `1`, `0`, `1`, and `0` respectively, while bits 5, 4, 2, and 1 can be any value. This is especially useful for matching opcodes where instruction fields (such as ModR/M register encodings, SIB flags, or conditional branch codes) vary between builds.

#### 2. Nibble Wildcards (`*A` / `A*`)
Cheat Engine has native nibble support, allowing half-byte wildcards by combining an asterisk `*` with a hexadecimal digit:
- **`*A`**: Matches any byte where the second (low) nibble is `A` (e.g. `0A`, `1A`, `2A`, `3A`, ... `FA`).
- **`A*`**: Matches any byte where the first (high) nibble is `A` (e.g. `A0`, `A1`, `A2`, ... `AF`).
- **Example**:
  ```asm
  // Match an instruction where only one nibble of an opcode or register specifier is fixed:
  aobscanmodule(NibbleHook, Game.exe, 48 *8 89 5C 24 *0)
  ```

#### 3. Exclusion / NOT Operator (`!xx`)
Placing an exclamation mark `!` in front of a 2-digit hex byte tells the scanner to match any value that is **NOT** that byte:
- **`!00`**: Excludes `00` from the results (matches any byte value from `01` through `FF`).
- **`!90`**: Matches any opcode byte that is not a `NOP` (`90`).
- **Example**:
  ```asm
  // Find an instruction offset while ensuring the displacement byte is non-zero:
  aobscanmodule(OffsetHook, Game.exe, 89 83 !00 00 00 00 48 8B)
  ```

#### 4. Relational / Comparison Operators (`<xx` and `>xx`)
Placing `<` or `>` in front of a 2-digit hex byte specifies that the byte in memory must be strictly lower than or higher than that value:
- **`<0A`**: Matches any byte value strictly lower than `0A` (i.e. `00` through `09`).
- **`>0A`**: Matches any byte value strictly higher than `0A` (i.e. `0B` through `FF`).
- **Example**:
  ```asm
  // Match a stack allocation greater than 0x20 and a displacement less than 0x10:
  aobscanmodule(StackHook, Game.exe, 48 83 EC >20 48 89 5C 24 <10)
  ```

#### 5. Combined Advanced Patterns
All of these advanced operators can be mixed within a single space-separated AOB scan pattern:
```asm
aobscanmodule(PlayerHook, Game.exe, 48 89 5C 24 *8 48 8B 05 ** ** ** ** |1000****| !00 >0A)
```

---

## High-Level Detours: The `hook` and `unhook` Commands

Cheat Engine provides the high-level `hook` and `unhook` Auto Assembler directives. Instead of manually disassembling instructions, calculating byte lengths, padding `nop` opcodes, finding near allocation caves within 2GB, and copying stolen bytes, `hook` automates the entire detour and trampoline generation process.

### Syntax & Parameters

```asm
hook(address, destination, [originalcodelabel])
```

- **`address`**: The memory address, module offset, or label to hook (e.g., `INJECT` resolved from an `aobscanmodule`).
- **`destination`**: The address or label where the hook will jump/call (e.g., your `newmem` code cave or custom C function).
- **`originalcodelabel`** *(optional)*: The name of a label that Cheat Engine will automatically generate to hold the trampoline containing the original code.

To disable the hook cleanly in the `[DISABLE]` section:

```asm
unhook(address)
```

- **`unhook(address)`**: Automatically restores the exact original unmodified bytes that were overwritten at `address` and deallocates the trampoline memory allocated for `originalcodelabel`. You do not need to write manual `db` restoration bytes or `dealloc(originalcodelabel)`.

---

### Core Mechanics & Capabilities

#### 1. Automatic 2GB Jump Code Generation
In 64-bit processes, manual hooks often crash when `newmem` cannot be allocated within 2GB of `address`, requiring either a 5-byte relative jump (`E9 ...`) or a 14-byte absolute jump (`FF 25 ...`).
- `hook` writes the jump code for you **regardless of whether there is enough space within 2GB or not**.
- Cheat Engine inspects memory space around `address`:
  - If near memory (within +/- 2GB) is available, it writes a 5-byte jump (`HOOK5`) and automatically registers `destination` to prefer near allocation.
  - If near memory is not available, it automatically falls back to a 14-byte far jump (`HOOK14` / `jmp far`).
- **Instruction Boundary Preservation**: `hook` inspects the original instructions using Cheat Engine's disassembler and steals enough *whole* instructions to fit the jump. You never have to count instruction bytes or manually pad extra space with `nop`.

#### 2. Automatic Trampoline Generation (`originalcodelabel`)
When `originalcodelabel` is provided, Cheat Engine:
1. Automatically allocates executable memory for the trampoline stub.
2. Reassembles the stolen original instructions at `originalcodelabel` (using `reassemble` to automatically adjust RIP-relative offsets).
3. Emits an unconditional jump back to the instruction immediately following the hooked bytes.
4. Makes `originalcodelabel` callable or jumpable from anywhere in your AA script or embedded C code (`jmp originalcodelabel` or `call originalcodelabel`).

#### 3. Skipping Hooked Instructions via Sub-Labels (`originalcodelabel_lineN`)
Cheat Engine also registers automatic line-specific sub-labels for each stolen instruction:
- **`originalcodelabel_line2`**: Points to the instruction immediately following the first stolen instruction.
- **`originalcodelabel_line3`**: Points to the instruction immediately following the second stolen instruction, etc.

> [!TIP]
> **Skipping Unwanted Game Operations:**
> If the first instruction at the hook site is a health or ammo decrement (e.g., `sub [rbx+0x10], eax`) and subsequent stolen instructions handle essential entity bookkeeping (e.g., updating timestamps or flags), you do not need to replicate the bookkeeping instructions manually.
> Simply execute your custom logic, and then jump to `originalcodelabel_line2`:
> ```asm
> // Bypass the first instruction (e.g. sub [rbx+0x10], eax)
> jmp originalcodelabel_line2
> ```

---

### Synergy with `{$c}` and `{$ccode}` Blocks

The `hook` command pairs exceptionally well with embedded `{$c}` and `{$ccode}` blocks. Because `hook` handles all detour jumps, instruction boundaries, and trampoline returns, your script avoids all manual assembly boilerplate (`jmp return`, manual stolen bytes, `nop` padding), giving your code an exceptionally clean and readable look.

#### Comparison: Traditional Manual Cave vs. `hook` + `{$ccode}`

**Traditional Boilerplate Cave (manual calculations & stolen byte management):**
```asm
[ENABLE]
aobscanmodule(INJECT, Game.exe, 89 83 B8 00 00 00 48 8B)
alloc(newmem, $1000, INJECT)
label(code)
label(return)

newmem:
{$ccode player=RBX newhp=EAX}
if (player) newhp = 9999;
{$asm}

code:
  mov [rbx+000000B8], eax // Manual stolen bytes
  jmp return              // Manual return jump

INJECT:
  jmp newmem              // Manual 5-byte hook
  nop                     // Manual padding
return:
registersymbol(INJECT)

[DISABLE]
INJECT:
  db 89 83 B8 00 00 00   // Manual raw byte restoration
unregistersymbol(INJECT)
dealloc(newmem)
```

**Clean Modern Hook (`hook` + `{$ccode}` + `unhook`):**
```asm
[ENABLE]
aobscanmodule(INJECT, Game.exe, 89 83 B8 00 00 00 48 8B)
alloc(newmem, $1000)

newmem:
{$ccode player=RBX newhp=EAX}
if (player) newhp = 9999;
{$asm}
  jmp origcode            // Jump to auto-generated trampoline

hook(INJECT, newmem, origcode)
registersymbol(INJECT)

[DISABLE]
unhook(INJECT)
unregistersymbol(INJECT)
dealloc(newmem)
```

---

### Practical Examples with `hook`

#### Example 1: Pure Assembly Hook Skipping Damage via `originalcodelabel_line2`

```asm
[ENABLE]
aobscanmodule(DamageHook, Game.exe, 29 73 18 48 8B 4B 20) // sub [rbx+18], esi ; mov rcx, [rbx+20]
alloc(newmem, $1000)

newmem:
  // Check if target entity is the player (flag at offset 0x10 == 1)
  cmp byte ptr [rbx+10], 1
  jne origcode                     // If not player, execute all original instructions including sub

  // Player godmode: skip line 1 (sub [rbx+18], esi) and jump directly to line 2 (mov rcx, [rbx+20])
  jmp origcode_line2

hook(DamageHook, newmem, origcode)
registersymbol(DamageHook)

[DISABLE]
unhook(DamageHook)
unregistersymbol(DamageHook)
dealloc(newmem)
```

#### Example 2: Clean `{$ccode}` Hook with Custom Logic and Trampoline Call

```asm
[ENABLE]
aobscanmodule(AmmoHook, Game.exe, 48 89 5C 24 08 57 48 83 EC 20)
alloc(newmem, $1000)

newmem:
{$ccode weapon=RCX clip=RDX}
// If weapon is valid, ensure clip never drops below 30
if (weapon != 0 && clip < 30) {
    clip = 30;
}
{$asm}
  jmp origammo                    // Execute original function prelude via trampoline

hook(AmmoHook, newmem, origammo)
registersymbol(AmmoHook)

[DISABLE]
unhook(AmmoHook)
unregistersymbol(AmmoHook)
dealloc(newmem)
```

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
| `hook(address, destination, [origlabel])` | Generates near/far jump detour, reads original code, and builds trampoline with line labels (`origlabel_line2`) | `hook(HealthHook, newmem, origcode)` |
| `unhook(address)` | Restores original bytes at hook site and frees trampoline memory in `[DISABLE]` section | `unhook(HealthHook)` |
| `aobscan(sym, hex)` | Scans target memory for byte pattern | `aobscan(HealthHook, F3 0F 11 83 ** ** 00 00)` |
| `aobscanmodule(sym, mod, hex)` | Scans specified module for byte pattern | `aobscanmodule(HealthHook, game.exe, F3 0F 11 83 ** ** 00 00)` |
| `aobscanfunction(sym, functionaddress, hex)` | Scans specified function for byte pattern | `aobscanfunction(HealthHook, player:setHealth, F3 0F 11 83 ** ** 00 00)` |
| `aobscanregion(sym, startaddress, stopaddress, hex)` | Scans specified region for byte pattern | `aobscanregion(HealthHook, player:setHealth, player:setHealth+100, F3 0F 11 83 ** ** 00 00)` |
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
