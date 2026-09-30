---
name: auto-assembler
description: Writing Cheat Engine Auto Assembler (AA) scripts, AOB scanning (aobscanmodule), memory allocation (alloc), register preservation, code caves, assembly hooks, and enable/disable templates. Use this skill when generating, debugging, or analyzing Cheat Engine Auto Assembler injection scripts, cheat tables, and memory patches.
---

# Cheat Engine Auto Assembler Skill

The `auto-assembler` skill guides AI agents and reverse engineers in writing robust, patch-resistant, and crash-proof Cheat Engine Auto Assembler (AA) scripts.

---

## When to Use This Skill

Activate this skill when:
- Creating Auto Assembler scripts with `[ENABLE]` and `[DISABLE]` sections.
- Writing Array of Byte (AOB) injection scripts that survive game updates (`aobscanmodule`).
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

## Cheat Engine Auto Assembler Directives

| Directive | Purpose | Example |
| :--- | :--- | :--- |
| `aobscanmodule(sym, mod, hex)` | Scans specified module for byte pattern | `aobscanmodule(HealthHook, game.exe, F3 0F 11 83 ?? ?? 00 00)` |
| `alloc(sym, size, [preferAddr])` | Allocates virtual memory in target | `alloc(newmem, $1000, HealthHook)` |
| `dealloc(sym)` | Frees allocated memory on disable | `dealloc(newmem)` |
| `registersymbol(sym)` | Registers global symbol for CE address list | `registersymbol(HealthHook)` |
| `unregistersymbol(sym)` | Removes global symbol | `unregistersymbol(HealthHook)` |
| `label(sym)` | Declares local code label | `label(code) label(return)` |
| `define(sym, val)` | Text replacement macro | `define(PLAYER_OFFSET, 0x1F8)` |
| `{$lua} ... {$asm}` | Executes embedded Lua script in CE | `{$lua} print("Script activated") {$asm}` |

---

## Testing Scripts via AITools
Before applying an Auto Assembler script to memory:
1. Validate syntax:
   `check_auto_assemble_syntax({ script = aaScript })`
2. If syntax check returns `{ result = "Success" }`, assemble or attach to memory record:
   `createMemoryRecord({ description = "God Mode", vartype = "vtAutoAssembler", script = aaScript })`
