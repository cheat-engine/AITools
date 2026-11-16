# Cheat Engine AITools

AI-powered assistance and reverse engineering extension for [Cheat Engine](https://github.com/cheat-engine/cheat-engine).

## Installation

Place this directory in the `Extensions` folder of Cheat Engine:
```text
<Cheat Engine Directory>/Extensions/AITools
```
Overwrite if it already exists.

---

## Core Tools (39 Built-in Tools)

Cheat Engine AITools exposes **39 high-level, composite tools** directly to the AI model. Instead of flooding the LLM context with hundreds of micro-RPC functions, AITools provides polymorphic and ergonomic tools covering the entire reverse engineering lifecycle:

### 1. Process & System
| Tool | Description | Key Parameters |
| :--- | :--- | :--- |
| `openProcess` | Opens target process by executable name | `processname` |
| `getOpenedProcessName` | Returns the executable name of the currently attached process | None |
| `getTargetedProcessInfo` | Retrieves target architecture details (calling convention, x86/x64, ARM, Android) | None |
| `getVersionStrings` | Extracts PE version resource strings (ProductVersion, FileDescription, etc.) | None |

### 2. Memory Scanning
| Tool | Description | Key Parameters |
| :--- | :--- | :--- |
| `scanMemory` | Initiates a new memory scan and spawns the interactive AI memscan session | `value`, `vartype`, `scanOption`, `roundingtype` |
| `refineScan` | Refines active scan results with new conditions (increased, decreased, changed, exact) | `scannerID`, `value`, `scanOption`, `roundingtype` |
| `getResultsAndValues` | Paginates through matching addresses and retrieves current live memory values | `scannerID`, `startindex`, `count` |

### 3. Memory Inspection & Modification
| Tool | Description | Key Parameters |
| :--- | :--- | :--- |
| `readMemoryBlock` | Reads raw memory blocks in specified sizes and formats | `address`, `size`, `type` |
| `readString` | Reads ASCII, UTF-8, or Wide strings from a memory address | `address`, `maxlength`, `isWide` |
| `writeAddress` | Polymorphic memory write supporting all standard CE types (`vtByte`..`vtDouble`, `vtString`) | `address`, `vartype`, `value` |
| `openMemoryView` | Opens CE Memory Viewer / Disassembly window focused at given address | `disassemblerAddress`, `hexviewAddress` |

### 4. Debugger & Watchpoints
| Tool | Description | Key Parameters |
| :--- | :--- | :--- |
| `startWatchpoint` | Attaches debugger and sets access/write watchpoint to capture triggering code | `address`, `breakpointMethod`, `breakType` |
| `queryWatchPointStatus` | Queries instructions that hit the watchpoint with hit counts and disassembly | `watchpointID` |
| `getDetailedWatchpointData` | Dumps registers (GPRs, SSE/AVX), stack view, and memory snapshots for a hit | `watchpointID`, `address` |
| `stopWatchpoint` | Pauses hit recording while preserving collected telemetry data | `watchpointID` |
| `deleteWatchpoint` | Stops watchpoint and frees allocated data structures | `watchpointID` |

### 5. Disassembly & Module Analysis
| Tool | Description | Key Parameters |
| :--- | :--- | :--- |
| `disassembleInstruction` | Disassembles a single instruction at specified address | `address` |
| `disassembleRange` | Disassembles an address range into instructions, bytes, and symbols | `startAddress`, `endAddress` |
| `getFunctionRange` | Detects start and end boundaries of the function enclosing given address | `address` |
| `enumModules` | Lists all loaded modules with base and end memory addresses | None |
| `getModuleFromAddress` | Resolves module name and bounds containing specified address | `address` |
| `getModuleSections` | Enumerates PE sections (`.text`, `.data`, `.rdata`, etc.) for specified module | `moduleName` |

### 6. Address List & Record Management
| Tool | Description | Key Parameters |
| :--- | :--- | :--- |
| `createMemoryRecord` | Adds new address list record (supports pointers, offsets, AA scripts, hierarchy) | `description`, `address`, `vartype`, `offsets`, `script` |
| `editMemoryRecord` | Edits existing memory record (address, description, vartype, offsets, script, active/freeze) | `memoryRecordID`, `description`, `active`, ... |
| `deleteMemoryRecord` | Removes a record from the address list by ID | `memoryRecordID` |
| `getAddressList` | Dumps current hierarchical address list layout and record IDs | None |
| `getMemoryRecordDetails` | Fetches comprehensive details and runtime state of a memory record | `memoryRecordID` |
| `getMemoryRecordByDescription` | Resolves unique memory record ID by its description text | `description` |

### 7. Script Windows & GUI Integration
| Tool | Description | Key Parameters |
| :--- | :--- | :--- |
| `showAutoAssemblerScript` | Opens Auto Assembler window and populates editor with script | `AutoAssemblerScript` |
| `getAutoAssemblerScript` | Fetches script content from an open Auto Assembler window | `autoAssemblerWindowID` |
| `setAutoAssemblerScript` | Updates script content in an open Auto Assembler window | `autoAssemblerWindowID`, `AutoAssemblerScript` |
| `syntaxCheckAutoAssemblerScript` | Checks Auto Assembler script syntax without assembling into memory | `script` |
| `showLuaScript` | Opens Lua engine window and inserts provided script | `LuaScript` |
| `getLuaEngineScript` | Retrieves script text from an open Lua engine window | `LuaEngineReference` |
| `setLuaEngineScript` | Sets script content in an open Lua engine window | `LuaEngineReference`, `LuaScript` |

### 8. Lua Execution & CE Documentation
| Tool | Description | Key Parameters |
| :--- | :--- | :--- |
| `executeLuaCode` | Executes arbitrary Lua code inside Cheat Engine (sync/async, captures prints and errors) | `script`, `async` |
| `getCELuaDocumentationByKeyword` | Searches official Cheat Engine Lua API documentation by keyword | `keyword`, `range` |
| `getCELuaDocumentationByLineNumber` | Retrieves documentation lines around specified line number | `linenr`, `linecount` |
| `wait` | Pauses execution outside UI thread for specified milliseconds | `timeToSleep` |

### 9. Progressive Disclosure Skill Loader
| Tool | Description | Key Parameters |
| :--- | :--- | :--- |
| `getSkill` | On-demand retrieval of full procedural instructions and workflows for specialized domains | `name` |

---

## Built-in Skills (6 Specialized Domains)

AITools adopts a **Progressive Disclosure** architecture. While basic operations are handled via the 39 core tools, complex domain expertise (Auto Assembler templates, Mono runtime reflection, Unreal Engine structure traversal) is packaged into dedicated skills. The model retrieves them on demand using `getSkill`.

### Available Skills Table

| Skill | Description | Key Capabilities & Target Scenarios | Reference |
| :--- | :--- | :--- | :--- |
| **`auto-assembler`** | Writing robust Auto Assembler (AA) scripts and memory patches | • `[ENABLE]` and `[DISABLE]` script architecture<br>• Embedded native C blocks (`{$c}` and `{$ccode}`)<br>• AOB signature scanning (`aobscanmodule`)<br>• Code caves, mid-function hooks & detours<br>• Register preservation & x64 ABI stack alignment | [SKILL.md](skills/auto-assembler/SKILL.md) |
| **`dissect-data-structures`** | Reverse engineering unknown memory blocks and C++ structures | • Structure Dissect tool workflows<br>• VMT / VTable identification<br>• Multi-entity side-by-side comparison<br>• C struct header generation<br>• Runtime type resolution integration | [SKILL.md](skills/dissect-data-structures/SKILL.md) |
| **`memory-scanning`** | Advanced memory scanning and filtering strategies | • Optimal data type selection (int, float, double, AOB)<br>• Unknown initial value workflows (decreased, increased, unchanged)<br>• Memory page protection masks (writable, executable)<br>• Lua scan automation (`createMemScan`, `refineScan`) | [SKILL.md](skills/memory-scanning/SKILL.md) |
| **`monoscript`** | Mono and Unity IL2CPP runtime reverse engineering | • Runtime class, method, and field offset resolution<br>• JIT compilation for native hook targets<br>• Finding active class instances in managed heap<br>• Dynamic method invocation<br>• Auto Assembler integration (`USEMONO`, `FINDMONOMETHOD`) | [SKILL.md](skills/monoscript/SKILL.md) |
| **`pointer-scanning`** | Multi-level pointer scanning and map generation | • Static base address resolution (`module+offset`)<br>• Pointermap (`.scandata`) generation and comparison<br>• Resolving multi-level pointer chains<br>• Persistent Cheat Engine address list records<br>• Lua pointer resolution (`readPointer`) | [SKILL.md](skills/pointer-scanning/SKILL.md) |
| **`unreal-engine`** | Reverse engineering Unreal Engine 4 and 5 games | • Locating global engine pointers (`GEngine`, `GWorld`, `GNames`, `GUObjectArray`)<br>• Direct hierarchy traversal (`GEngine -> GameInstance -> PlayerController`)<br>• Dynamic dissection of `UObject`, `UClass`, `UProperty`<br>• Actor & component analysis (`CharacterMovementComponent`, `RootComponent`)<br>• Runtime `UObject::ProcessEvent` hooking | [SKILL.md](skills/unreal-engine/SKILL.md) |

---

### Skill Details

#### `auto-assembler`
Guides the AI in crafting robust, patch-resistant Cheat Engine Auto Assembler scripts. It covers standard `[ENABLE]`/`[DISABLE]` templates, inline C code compilation via `{$c}`/`{$ccode}`, array-of-byte (`aobscanmodule`) signature scanning, function hooking/detours, CPU register preservation (`pushfq`/`pushaq`), and x64 calling convention alignment.

#### `dissect-data-structures`
Provides systematic methodologies for inspecting and mapping complex object hierarchies and data structures in target memory. Helps identify virtual method tables (VTables), classify structure fields (primitives, pointers, strings), and compare multiple game entities simultaneously to isolate critical offsets.

#### `memory-scanning`
Covers best practices for locating game variables and values in memory. Includes data type selection matrices (e.g. distinguishing between 4-byte integers, floats, doubles, and bitfields), workflows for unknown or encrypted values, memory protection filtering, and automated scanning via Cheat Engine's Lua scripting engine.

#### `monoscript`
Leverages Cheat Engine's `monoscript.lua` and injected `MonoDataCollector` to inspect and modify games built on Mono (.NET) or Unity IL2CPP. Allows dynamic resolution of managed classes, methods, and fields without static offsets, invoking managed methods at runtime, and integrating Mono helpers into Auto Assembler scripts.

#### `pointer-scanning`
Offers guidance on discovering reliable multi-level pointer paths from static module bases to dynamic heap memory. Covers capturing pointermaps, comparing `.scandata` dumps across process restarts to filter out dead or unstable pointers, and configuring address records with complex pointer offsets.

#### `unreal-engine`
Specialized for Unreal Engine 4 and 5 games using the bundled `UETools` extension. Focuses on resolving critical engine structures (`GEngine`, `GWorld`, `FNamePool`, `GUObjectArray`), traversing the object tree down to player pawns and components, inspecting dynamic UProperties, and intercepting engine events via `ProcessEvent`.

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
