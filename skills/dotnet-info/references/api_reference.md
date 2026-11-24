# .NET Info & DataSource API Reference

This document provides a reference catalog of all functions, classes, data structures, constants, and control identifiers exposed by Cheat Engine's **.NET Info** system, `DataSource` caching object, `DotNetDataCollector`, and `DotNetInterface`.

---

## Table of Contents
1. [TDotNetPipe (getDotNetDataCollector())](#1-tdotnetpipe-getdotnetdatacollector)
2. [The DataSource Object Structure & APIs](#2-the-datasource-object-structure--apis)
3. [DotNetInterface.lua Active APIs](#3-dotnetinterfacelua-active-apis)
4. [frmDotNetInfo Controls and Dialog APIs](#4-frmdotnetinfo-controls-and-dialog-apis)
5. [Element Types, TypeCodes, and Attribute Bitmasks](#5-element-types-typecodes-and-attribute-bitmasks)

---

## 1. TDotNetPipe (getDotNetDataCollector())

The native Pascal / C++ CLR debugging pipe wrapper registered in Lua via `getDotNetDataCollector()`.

### `enumDomains()`
- **Signature**: `dc.enumDomains() -> table`
- **Description**: Enumerates all loaded Application Domains in the target process.
- **Returns**: Array of domain tables:
  ```lua
  {
    {
      DomainHandle = 0x7FFA12340000, -- uint64
      Name = "DefaultDomain"          -- string
    },
    ...
  }
  ```

### `enumModuleList(domainHandle)`
- **Signature**: `dc.enumModuleList(domainHandle: uint64) -> table`
- **Description**: Enumerates all PE modules / assemblies loaded inside the specified AppDomain.
- **Returns**: Array of module tables:
  ```lua
  {
    {
      ModuleHandle = 0x7FFA80001000, -- uint64
      BaseAddress  = 0x7FF710000000, -- uint64
      Name         = "C:\\Game\\Assembly-CSharp.dll" -- string (full path)
    },
    ...
  }
  ```

### `enumTypeDefs(moduleHandle)`
- **Signature**: `dc.enumTypeDefs(moduleHandle: uint64) -> table`
- **Description**: Enumerates all class TypeDefs defined within the target module.
- **Returns**: Array of TypeDef records:
  ```lua
  {
    {
      TypeDefToken = 0x02000002, -- uint64 / dword
      Name         = "Game.PlayerController", -- string
      Flags        = 0x100001,   -- integer
      Extends      = 0x01000014    -- uint64 (TypeDefToken of parent, or 0)
    },
    ...
  }
  ```

### `getTypeDefMethods(moduleHandle, typeDefToken)`
- **Signature**: `dc.getTypeDefMethods(moduleHandle: uint64, typeDefToken: uint64) -> table`
- **Description**: Enumerates all methods declared on the specified class.
- **Returns**: Array of method records:
  ```lua
  {
    {
      MethodToken         = 0x0600001A, -- uint64 / dword
      Name                = "TakeDamage", -- string
      Attributes          = 0x0006,     -- integer (bitmask)
      ImplementationFlags = 0x0000,     -- integer
      ILCode              = 0x7FFA89B0, -- uint64 (address of CIL code)
      NativeCode          = 0x7FF76B00, -- uint64 (compiled machine code, or 0)
      SecondaryNativeCode = {           -- array of uint64 addresses
        0x7FF76B80, ...
      }
    },
    ...
  }
  ```

### `getMethodParameters(moduleHandle, methodToken)`
- **Signature**: `dc.getMethodParameters(moduleHandle: uint64, methodToken: uint64) -> (parameters: table, sig: string)`
- **Description**: Returns parameter types, parameter names, and signature string for a method.
- **Returns**:
  1. `parameters`: Array of `{ Name = "amount", CType = 0x0c }`
  2. `sig`: Method signature string formatted by metadata reader.

### `getTypeDefData(moduleHandle, typeDefToken)`
- **Signature**: `dc.getTypeDefData(moduleHandle: uint64, typeDefToken: uint64) -> table`
- **Description**: Queries comprehensive layout and field details for a class.
- **Returns**:
  ```lua
  {
    ClassName          = "PlayerController", -- string
    ObjectType         = 0,                  -- integer
    ElementType        = 0,                  -- integer (if array)
    CountOffset        = 0,                  -- integer
    ElementSize        = 0,                  -- integer
    FirstElementOffset = 0,                  -- integer
    Fields = {
      {
        Token              = 0x04000005,      -- uint64 / dword
        Offset             = 0x018,           -- integer (byte offset)
        FieldType          = 0x0c,            -- integer (CorElementType)
        Name               = "m_Health",      -- string
        FieldTypeClassName = "System.Single", -- string
        IsStatic           = false,           -- boolean
        Attribs            = 0x0006,          -- integer
        Address            = 0                -- uint64 (static address if static)
      },
      ...
    }
  }
  ```

### `getTypeDefParent(moduleHandle, typeDefToken)`
- **Signature**: `dc.getTypeDefParent(moduleHandle: uint64, typeDefToken: uint64) -> table`
- **Description**: Resolves parent class token and module handle across module boundaries.
- **Returns**: `{ ModuleHandle = 0x..., TypedefToken = 0x... }` (or `nil` if root class).

### `getAddressData(address)`
- **Signature**: `dc.getAddressData(address: uint64) -> table`
- **Description**: Reads runtime object header at `address` and inspects its dynamic type layout.
- **Returns**: Table matching `getTypeDefData` layout prefixed with `StartAddress = address`.

### `enumAllObjects()`
- **Signature**: `dc.enumAllObjects() -> table`
- **Description**: Walks the entire garbage-collected heap and enumerates every active object.
- **Returns**: Array of heap object records:
  ```lua
  {
    {
      StartAddress = 0x1D8A2000,
      Size         = 48,
      TypeID       = { token1 = 0x..., token2 = 0x... },
      ClassName    = "Game.PlayerController"
    },
    ...
  }
  ```

### `enumAllObjectsOfType(moduleHandle, typeDefToken)`
- **Signature**: `dc.enumAllObjectsOfType(moduleHandle: uint64, typeDefToken: uint64) -> table`
- **Description**: Scans the GC heap and returns an array of instance memory addresses for a specific class.
- **Returns**: Array of `uint64` memory addresses: `{ 0x1D8A2000, 0x1D8A5400, ... }`.

---

## 2. The DataSource Object Structure & APIs

The global `DataSource` table defined in `bin/autorun/dotnetinfo.lua`.

### Core Fields on `DataSource`

| Field | Type | Description |
|---|---|---|
| `DataSource.Domains` | `table` | Array of Domain objects. Includes `ClassHandleLookup` dictionary. |
| `DataSource.DotNetDataCollector` | `TDotNetPipe` | Active native CLR pipe instance from `getDotNetDataCollector()`. |
| `DataSource.ClassNameLookup` | `table` | Hash map `[classname] -> Class` for fast resolution. |
| `DataSource.BackgroundParser` | `thread` | Thread handle running `launchBackgroundParser()`. |
| `DataSource.BackgroundParserHeartbeat` | `integer` | Counter incrementing during background AST crawling. |
| `DataSource.FullyParsed` | `boolean` | Set to `true` when all domains, images, and classes are cached. |
| `DataSource.ParsedStatics` | `table` | Cached list of `{ name = "...", address = 0x... }` records. |
| `DataSource.ParsingStatics` | `thread` | Worker thread running static variable enumeration. |

### Domain Object Schema
```lua
{
  Handle            = 0x7FFA..., -- uint64
  Name              = "DefaultDomain", -- string
  Control           = 1,         -- CONTROL_MONO (0) or CONTROL_DOTNET (1)
  ClassHandleLookup = {},        -- table [Handle] -> Class
  Images            = { ... }    -- array of Image objects (populated by DataSource.getImages)
}
```

### Image Object Schema
```lua
{
  Handle      = 0x7FFA...,              -- uint64 (module handle)
  Name        = "C:\\Path\\Game.dll",   -- string (full path)
  FileName    = "Game.dll",             -- string (extracted basename)
  BaseAddress = 0x7FF7...,              -- uint64
  Domain      = Domain,                 -- back-reference to parent Domain
  Classes     = { ... }                 -- array of Class objects (populated by DataSource.getClasses)
}
```

### Class Object Schema
```lua
{
  Handle       = 0x02000010, -- TypeDefToken (or MonoClass handle)
  Name         = "PlayerController",
  NameSpace    = "Game",
  FullName     = "Game.PlayerController",
  ParentHandle = 0x02000004,
  Parent       = Class,      -- parent Class object
  Image        = Image,      -- back-reference to parent Image
  Fields       = { ... },    -- array of Field objects (populated by DataSource.getClassFields)
  Methods      = { ... }     -- array of Method objects (populated by DataSource.getClassMethods)
}
```

### Field Object Schema
```lua
{
  Handle      = 0x04000018,          -- Field token
  Name        = "m_Health",
  AltName     = "Health",            -- Demangled name if auto-property
  VarType     = 0x0c,                -- CorElementType / MonoType
  VarTypeName = "System.Single",
  Offset      = 0x018,               -- Byte offset from object base pointer
  Static      = false,               -- boolean
  Const       = false,               -- boolean (Mono)
  Attribs     = 0x0006,              -- Field attributes mask
  Address     = 0x7FFDA004,          -- Live memory address (if Static == true)
  Class       = Class                -- back-reference to parent Class
}
```

### Method Object Schema
```lua
{
  Handle              = 0x06000042,     -- MethodDef token
  Name                = "TakeDamage",
  Class               = Class,          -- back-reference to parent Class
  Attribs             = 0x0006,         -- Method attributes mask
  Static              = false,          -- boolean
  ILCode              = 0x7FFA1000,     -- Address of CIL byte buffer
  NativeCode          = 0x7FF72000,     -- Compiled machine code address (or 0)
  SecondaryNativeCode = { ... },
  ReturnType          = "System.Void",
  Parameters          = "(Single amount, Boolean instant)"
}
```

---

## 3. DotNetInterface.lua Active APIs

Functions exported by `bin/autorun/DotNetInterface.lua` using the active injected library `DotNetInterface.dll`.

| Function | Parameters | Return | Description |
|---|---|---|---|
| `LaunchDotNetInterface` | None | `boolean` | Injects `DotNetInterface.dll` into target and connects to named pipe `cedotnetpipe_pid<PID>`. |
| `dotnet_disconnect` | None | None | Closes active named pipe connection and terminates remote thread. |
| `dotnet_getModuleID` | `modulename: string` | `integer` | Resolves module zero-based index by assembly name or scope name. |
| `dotnet_findDotNetMethodAddress` | `namespace, classname, methodname, [modulename]` | `uint64` | Searches for method and compiles/fetches native code entry point. |
| `dotnet_getMethodEntryPoint` | `moduleid: integer, methoddef: integer` | `uint64` | Fetches native JIT execution entry point. |
| `dotnet_getMethodParameters` | `moduleid: integer, methoddef: integer` | `(returntype, parameters, TypeCodes)` | Fetches return type string, parameter signature string, and parameter TypeCode list. |
| `dotnet_invoke_method` | `moduleid, methoddef, wrappedObjectHandle, parameters` | `any` | Executes the managed method inside the target process with arguments. |
| `dotnet_getFieldValue` | `moduleid, fielddef, instanceaddress` | `string` | Reads string-formatted field value from remote instance. |
| `dotnet_setFieldValue` | `moduleid, fielddef, instanceaddress, value: string` | None | Sets field value in target instance from string. |
| `dotnet_getFieldTypeName` | `moduleid, fielddef` | `string` | Queries fully qualified type name of a field. |
| `dotnet_wrapobject` | `objectaddress: uint64` | `uint64` | Creates a GC handle anchor (`GCHandle`) preventing target object from being garbage-collected. |
| `dotnet_unwrapobject` | `wrappedobjecthandle: uint64` | `uint64` | Releases GC handle anchor. |
| `dotnet_loadModule` | `path: string` | `boolean` | Dynamically loads an external managed assembly into the target process. |

---

## 4. frmDotNetInfo Controls and Dialog APIs

### Key Form Controls on `frmDotNetInfo`

| Control Name | Class Type | Description |
|---|---|---|
| `lbDomains` | `TListBox` | Displays AppDomains. |
| `lbImages` | `TListBox` | Displays loaded assemblies / modules. |
| `lvClasses` | `TListView` | Displays TypeDefs (virtual owner-data mode). |
| `edtClassFilter` | `TEdit` | Real-time search filter for class names. |
| `gbInheritance` | `TGroupBox` | Class inheritance hierarchy view. |
| `lvFields` | `TListView` | Flat instance fields list. |
| `lvFields2` | `TVirtualStringTree` | Hierarchical recursive tree for nested structs/classes. |
| `lvStaticFields` | `TListView` | Static fields list with resolved memory addresses. |
| `comboFieldBaseAddress` | `TComboBox` | Instance pointer address selector for live field reading. |
| `btnLookupInstances` | `TButton` | Scans heap for all live instances of selected class. |
| `lvMethods` | `TListView` | Methods list with accessibility colors and parameters. |

### Key Menu Items & Dialog Functions

| Menu / Function | Description |
|---|---|
| `miInvokeMethod` | Invokes selected method via `dotNetInfo.SpawnInvokeMethodDialog`. |
| `miJitMethod` | JIT-compiles method and disassembles in Memory View. |
| `miGeneratePatchTemplateForMethod` | Generates Auto Assembler hook template for method. |
| `miBrowseField` | Navigates to field memory address in Memory View. |
| `miEnumAllStatics` | Scans all assemblies for static fields via `spawnEnumStaticsWindow`. |
| `miFindClass` / `miFindField` / `miFindMethod` | Opens `DotNetSearch.frm` via `spawnDotNetSearchDialog(DataSource, frmDotNetInfo, type)` (0=Class, 1=Field, 2=Method). |
| `miChangeColors` | Configures syntax highlighting colors via `DotNetInfoConfig.FRM`. |

---

## 5. Element Types, TypeCodes, and Attribute Bitmasks

### CorElementType Constants (`ELEMENT_TYPE_*`)

```lua
ELEMENT_TYPE_END         = 0x00 -- End of List
ELEMENT_TYPE_VOID        = 0x01
ELEMENT_TYPE_BOOLEAN     = 0x02
ELEMENT_TYPE_CHAR        = 0x03
ELEMENT_TYPE_I1          = 0x04 -- sbyte
ELEMENT_TYPE_U1          = 0x05 -- byte
ELEMENT_TYPE_I2          = 0x06 -- short
ELEMENT_TYPE_U2          = 0x07 -- ushort
ELEMENT_TYPE_I4          = 0x08 -- int
ELEMENT_TYPE_U4          = 0x09 -- uint
ELEMENT_TYPE_I8          = 0x0a -- long
ELEMENT_TYPE_U8          = 0x0b -- ulong
ELEMENT_TYPE_R4          = 0x0c -- float / Single
ELEMENT_TYPE_R8          = 0x0d -- double
ELEMENT_TYPE_STRING      = 0x0e
ELEMENT_TYPE_PTR         = 0x0f
ELEMENT_TYPE_CLASS       = 0x12 -- Class instance (expandable in lvFields2)
ELEMENT_TYPE_GENERICINST = 0x15 -- Generic instance (expandable in lvFields2)
ELEMENT_TYPE_I           = 0x18 -- IntPtr
ELEMENT_TYPE_U           = 0x19 -- UIntPtr
```

### TypeCode Constants (`TypeCode.*`)

```lua
TypeCode.Empty    = 0
TypeCode.Object   = 1
TypeCode.DBNull   = 2
TypeCode.Boolean  = 3
TypeCode.Char     = 4
TypeCode.SByte    = 5
TypeCode.Byte     = 6
TypeCode.Int16    = 7
TypeCode.UInt16   = 8
TypeCode.Int32    = 9
TypeCode.UInt32   = 10
TypeCode.Int64    = 11
TypeCode.UInt64   = 12
TypeCode.Single   = 13
TypeCode.Double   = 14
TypeCode.Decimal  = 15
TypeCode.DateTime = 16
TypeCode.String   = 18
```

### Method and Field Attribute Bitmasks

```lua
-- Method Access Masks
METHOD_ATTRIBUTE_MEMBER_ACCESS_MASK = 0x0007
METHOD_ATTRIBUTE_COMPILER_CONTROLLED= 0x0000
METHOD_ATTRIBUTE_PRIVATE            = 0x0001
METHOD_ATTRIBUTE_FAM_AND_ASSEM      = 0x0002
METHOD_ATTRIBUTE_ASSEM              = 0x0003
METHOD_ATTRIBUTE_FAMILY             = 0x0004
METHOD_ATTRIBUTE_FAM_OR_ASSEM       = 0x0005
METHOD_ATTRIBUTE_PUBLIC             = 0x0006
METHOD_ATTRIBUTE_STATIC             = 0x0010

-- Field Access Masks
FIELD_ATTRIBUTE_FIELD_ACCESS_MASK   = 0x0007
FIELD_ATTRIBUTE_COMPILER_CONTROLLED = 0x0000
FIELD_ATTRIBUTE_PRIVATE             = 0x0001
FIELD_ATTRIBUTE_FAM_AND_ASSEM       = 0x0002
FIELD_ATTRIBUTE_ASSEMBLY            = 0x0003
FIELD_ATTRIBUTE_FAMILY              = 0x0004
FIELD_ATTRIBUTE_FAM_OR_ASSEM        = 0x0005
FIELD_ATTRIBUTE_PUBLIC              = 0x0006
FIELD_ATTRIBUTE_STATIC              = 0x0010
FIELD_ATTRIBUTE_INIT_ONLY           = 0x0020 -- readonly
FIELD_ATTRIBUTE_LITERAL             = 0x0040 -- const
```
