# Cheat Engine MonoScript API Reference

Exhaustive API reference for `autorun/monoscript.lua` and its interaction with `MonoDataCollector`.

---

## Table of Contents
1. [Core Constants & Enumerations](#1-core-constants--enumerations)
2. [Connection & Lifecycle Control](#2-connection--lifecycle-control)
3. [Domains, Assemblies & Images](#3-domains-assemblies--images)
4. [Classes & Type Introspection](#4-classes--type-introspection)
5. [Fields & Static Variables](#5-fields--static-variables)
6. [Methods, JIT Compilation & Invocation](#6-methods-jit-compilation--invocation)
7. [Objects, Instances, Strings & Arrays](#7-objects-instances-strings--arrays)
8. [CE Structure Dissector & GUI Integration](#8-ce-structure-dissector--gui-integration)
9. [Auto Assembler Commands](#9-auto-assembler-commands)

---

## 1. Core Constants & Enumerations

> [!CAUTION]
> **Do not send IPC commands manually.**
> The underlying IPC command values (`MONOCMD_*`) and pipe protocol are strictly internal implementation details of Cheat Engine and `MonoDataCollector`. API users and AI agents must **never** send commands or raw bytes to the pipe manually (`monopipe.writeByte(...)`, etc.). Only the exposed Lua API functions (`mono_*`) should be used to interact with the target process. Manual pipe commands will desynchronize the communication stream, cause race conditions, and create severe state conflicts with Cheat Engine's internal handlers.

### Type Identifiers (`MONO_TYPE_*`)
Represent the internal runtime type of fields, variables, and return values:
```lua
MONO_TYPE_END         = 0x00
MONO_TYPE_VOID        = 0x01
MONO_TYPE_BOOLEAN     = 0x02
MONO_TYPE_CHAR        = 0x03
MONO_TYPE_I1          = 0x04  -- sbyte
MONO_TYPE_U1          = 0x05  -- byte
MONO_TYPE_I2          = 0x06  -- short
MONO_TYPE_U2          = 0x07  -- ushort
MONO_TYPE_I4          = 0x08  -- int
MONO_TYPE_U4          = 0x09  -- uint
MONO_TYPE_I8          = 0x0a  -- long
MONO_TYPE_U8          = 0x0b  -- ulong
MONO_TYPE_R4          = 0x0c  -- float
MONO_TYPE_R8          = 0x0d  -- double
MONO_TYPE_STRING      = 0x0e
MONO_TYPE_PTR         = 0x0f  -- pointer
MONO_TYPE_BYREF       = 0x10  -- ref / out
MONO_TYPE_VALUETYPE   = 0x11  -- struct
MONO_TYPE_CLASS       = 0x12  -- class reference
MONO_TYPE_VAR         = 0x13  -- generic parameter
MONO_TYPE_ARRAY       = 0x14  -- multi-dim array
MONO_TYPE_GENERICINST = 0x15  -- generic type instance (e.g. List<T>)
MONO_TYPE_TYPEDBYREF  = 0x16
MONO_TYPE_I           = 0x18  -- IntPtr / native int
MONO_TYPE_U           = 0x19  -- UIntPtr / native uint
MONO_TYPE_FNPTR       = 0x1b  -- function pointer
MONO_TYPE_OBJECT      = 0x1c  -- System.Object
MONO_TYPE_SZARRAY     = 0x1d  -- single-dim 0-based array (T[])
```

---

## 2. Connection & Lifecycle Control

### `LaunchMonoDataCollector()`
Injects the appropriate `MonoDataCollector` library into the currently opened process and establishes communication.
- **Returns**: `boolean` (`true` on success, `false` or `nil` on failure).
- **Notes**: Must be called on the main thread (or via `synchronize()`). Sets up symbol lookup callbacks and address lookup callbacks in Cheat Engine.

### `getMonoPipe()`
Returns the `Pipe` connection object dedicated to the calling thread (`libmono.monopipes[getCurrentThreadID()]`).
- **Returns**: `Pipe` object or `nil`.
- **Notes**: Auto-connects if the thread does not yet have an active pipe.

### `createMonoThread(f)`
Creates and executes a new worker thread running function `f(t)` that automatically destroys its thread-specific pipe upon termination.
```lua
createMonoThread(function(thread)
  local klass = mono_findClass("Player")
  print("Found player class in thread: " .. string.format("%x", klass))
end)
```

### `libmono.terminate()`
Closes all open pipes, stops the heartbeat thread, unregisters Cheat Engine lookup callbacks, and resets internal state.
- **Must be called from main thread.**

### `mono_isValid()`
- **Returns**: `boolean` (`true` if Mono/IL2CPP collector is responding).

### `mono_isil2cpp()`
- **Returns**: `boolean` (`true` if target process is Unity IL2CPP).

### `mono_getMonoDatacollectorDLLVersion()`
- **Returns**: `integer` (DLL version code, e.g. `20062026`).

### `mono_clearcache()`
Clears all internal lookup caches (`monocache.foundclasses`, `monocache.vtables`, `monocache.fields`, etc.). Call if assemblies or scripts were reloaded.

### `mono_collectGarbage()`
Forces the Mono runtime garbage collector to execute a full collection pass.

### `mono_free(object)`
- **Parameters**: `object` (`qword`) - Pointer to free using `g_free`.

---

## 3. Domains, Assemblies & Images

### `mono_enumDomains()`
- **Returns**: `qword[]` - Table of active `MonoDomain*` pointers.

### `mono_setCurrentDomain(domain)`
- **Parameters**: `domain` (`qword`) - Domain to switch to.
- **Returns**: `integer` - Status code.

### `mono_enumAssemblies()`
- **Returns**: `qword[]` - Table of loaded `MonoAssembly*` pointers.

### `mono_getImageFromAssembly(assembly)`
- **Parameters**: `assembly` (`qword`) - Assembly pointer.
- **Returns**: `qword` - Corresponding `MonoImage*` pointer.

### `mono_image_get_name(image)`
- **Parameters**: `image` (`qword`) - Image pointer.
- **Returns**: `string` - Short assembly name without extension (e.g., `"Assembly-CSharp"`).

### `mono_image_get_filename(image)`
- **Parameters**: `image` (`qword`) - Image pointer.
- **Returns**: `string` - Absolute filesystem path to the DLL/assembly.

### `mono_enumImages(onImage)`
- **Parameters**: `onImage` (`function(image)`) - Callback invoked for each loaded image.

### `mono_enumImagesEx(domain)`
- **Parameters**: `domain` (`qword`, optional) - Domain to inspect.
- **Returns**: `table[]` - List of `{Image = qword, Path = string}`.

### `mono_loadAssemblyFromFile(fname)`
Loads an assembly from the target filesystem into the target Mono runtime.
- **Parameters**: `fname` (`string`) - File path on target system.
- **Returns**: `qword` - Loaded `MonoAssembly*` handle.

---

## 4. Classes & Type Introspection

### `mono_findClass(namespace, classname)`
Finds a class across all loaded assemblies.
- **Parameters**:
  - `namespace` (`string`): Namespace (or fully-qualified name `"Namespace.ClassName"` if second parameter is omitted).
  - `classname` (`string`, optional): Unqualified class name. Supports nested types (`"Outer+Inner"`) and generic syntax (``"List`1"``).
- **Returns**: `qword` - `MonoClass*` pointer, or `nil` if not found.

### `mono_findClass2(fullname, assemblyname)`
Uses .NET `Type.GetType()` internally to resolve classes. Essential for finding generic type instantiations or nested types.
- **Parameters**:
  - `fullname` (`string`): e.g. `"System.Collections.Generic.List`1[System.Int32]"`.
  - `assemblyname` (`string`, optional): Assembly name e.g. `"mscorlib"`.
- **Returns**: `qword` - `MonoClass*` pointer.

### `mono_image_findClass(image, namespace, classname)`
- **Parameters**: `image` (`qword`), `namespace` (`string`), `classname` (`string`).
- **Returns**: `qword` - `MonoClass*` pointer within that specific image.

### `mono_image_enumClasses(image)`
- **Parameters**: `image` (`qword`).
- **Returns**: `table[]` - Array of `{class = qword, classname = string, namespace = string}`.

### `mono_image_enumClassesEx(image)`
Batch enumeration returning full class metadata:
- **Returns**: `table[]` - Array of `{Handle, ParentHandle, NestingTypeHandle, Name, NameSpace, FullName}`.

### `mono_class_getName(class)`
- **Returns**: `string` - Unqualified class name.

### `mono_class_getNamespace(class)`
- **Returns**: `string` - Namespace string.

### `mono_class_getFullName(typeptr, isclass, nameformat)`
- **Parameters**:
  - `typeptr` (`qword`): Pointer to `MonoClass*` or `MonoType*`.
  - `isclass` (`integer`, optional, default `1`): `1` if class, `0` if type.
  - `nameformat` (`integer`, optional): Formatting mode:
    - `MONO_TYPE_NAME_FORMAT_IL = 0`
    - `MONO_TYPE_NAME_FORMAT_REFLECTION = 1` (default)
    - `MONO_TYPE_NAME_FORMAT_FULL_NAME = 2`
    - `MONO_TYPE_NAME_FORMAT_ASSEMBLY_QUALIFIED = 3`
- **Returns**: `string` - Formatted name.

### `mono_class_getParent(class)`
- **Returns**: `qword` - `MonoClass*` of parent base class (`0` if root `System.Object`).

### `mono_class_getImage(class)`
- **Returns**: `qword` - `MonoImage*` declaring this class.

### `mono_class_get_type(class)`
- **Returns**: `qword` - `MonoType*` representing this class.

### `mono_type_get_class(monotype)`
- **Returns**: `qword` - `MonoClass*` corresponding to this type.

### `mono_type_get_type(monotype)`
- **Returns**: `integer` - Numeric type ID (`MONO_TYPE_*`).

### `mono_class_isgeneric(class)`
- **Returns**: `boolean` - `true` if class is a generic template.

### `mono_class_isEnum(class)`
- **Returns**: `boolean` - `true` if class is an `Enum`.

### `mono_class_getEnumValues(enumclass)`
- **Returns**: `table[]` - Array of `{name = string, value = integer}` entries.

### `mono_class_isValueType(class)`
- **Returns**: `boolean` - `true` if class is a value type (`struct` or `enum`).

### `mono_class_isStruct(class)`
- **Returns**: `boolean` - `true` if class is a struct (value type, not primitive, not enum).

### `mono_class_IsPrimitive(class)`
- **Returns**: `boolean` - `true` if primitive type (int, float, bool, pointer).

### `mono_class_isSubClassOf(class, parentclass, checkInterfaces)`
- **Returns**: `boolean` - `true` if class derives from parent or implements interface.

### `mono_class_getNestedTypes(class)`
- **Returns**: `qword[]` - List of nested `MonoClass*` handles.

### `mono_class_getNestingType(class)`
- **Returns**: `qword` - Enclosing parent `MonoClass*` handle if nested, or `0`.

### `mono_class_enumInterfaces(class)`
- **Returns**: `qword[]` - List of interface `MonoClass*` handles implemented.

### `mono_class_getVTable(domain, class)`
- **Parameters**: `domain` (`qword`, optional), `class` (`qword`).
- **Returns**: `qword` - Pointer to `MonoVTable` in target memory. (On IL2CPP, returns the class pointer).

---

## 5. Fields & Static Variables

### `mono_class_enumFields(class, includeParents, expandedStructs)`
Enumerates all fields of a class.
- **Parameters**:
  - `class` (`qword`): Target `MonoClass*`.
  - `includeParents` (`boolean`, optional): Include fields inherited from base classes.
  - `expandedStructs` (`boolean`, optional): Flatten nested struct fields with dot notation.
- **Returns**: `table[]` - Array of field tables:
  ```lua
  {
    field = qword,          -- MonoClassField* handle
    name = string,          -- Field name
    altname = string,       -- Unwrapped property name for backing fields (e.g. <Health>k__BackingField -> Health)
    typename = string,      -- Declared type name string
    type = qword,           -- MonoType* handle
    monotype = integer,     -- MONO_TYPE_* numeric constant
    parent = qword,         -- MonoClass* of declaring class
    offset = integer,       -- Byte offset from object base (or static block)
    flags = integer,        -- Field attribute flags
    isStatic = boolean,     -- true if static or has RVA
    isConst = boolean,      -- true if const/literal
    staticAddress = qword   -- Absolute memory address if static
  }
  ```

### `mono_field_getClass(field)`
- **Returns**: `qword` - `MonoClass*` declaring the field.

### `mono_field_get_type(field)`
- **Returns**: `qword` - `MonoType*` of the field.

### `mono_field_get_value_object(field, object)`
- **Returns**: `qword` - Boxed `MonoObject*` representing the current field value in `object`.

### `mono_class_getStaticFieldAddress(domain, class)`
- **Returns**: `qword` - Base memory address of the static field buffer for this class.

### `mono_getStaticFieldValue(vtable, field)`
- **Parameters**: `vtable` (`qword`), `field` (`qword`).
- **Returns**: `qword` - Raw static field value.

### `mono_setStaticFieldValue(vtable, field, value)`
- **Parameters**: `vtable` (`qword`), `field` (`qword`), `value` (`qword`).

### `mono_class_getStaticFieldValue(class, field)`
Convenience wrapper that resolves vtable automatically.
- **Returns**: `qword` - Static field value.

### `mono_class_setStaticFieldValue(class, field, value)`
Convenience wrapper that resolves vtable automatically and updates static field value.

---

## 6. Methods, JIT Compilation & Invocation

### `mono_class_findMethod(class, methodname)`
- **Parameters**: `class` (`qword`), `methodname` (`string`).
- **Returns**: `qword` - `MonoMethod*` handle (first match).

### `mono_findMethod(namespace, classname, methodname, parameters)`
Finds method across loaded images.
- **Parameters**:
  - `namespace` (`string`): Namespace (or combined `"Namespace:Class:Method(args)"`).
  - `classname` (`string`, optional).
  - `methodname` (`string`, optional).
  - `parameters` (`string`, optional): Argument types string e.g. `"int,string"`.
- **Returns**: `method, class` - `MonoMethod*` handle and `MonoClass*` handle.

### `mono_findMethodWithParameters(namespace, classname, methodname, parameters)`
Finds a specific method overload by scoring parameter names and types.
- **Returns**: `method, class`.

### `mono_findMethodByDesc(assemblyname, methoddesc)`
- **Parameters**:
  - `assemblyname` (`string`): Assembly name (e.g. `"Assembly-CSharp"`).
  - `methoddesc` (`string`): Description pattern e.g. `":TakeDamage(int,float)"`.
- **Returns**: `qword` - `MonoMethod*` handle.

### `mono_class_enumMethods(class, includeParents)`
- **Returns**: `table[]` - Alphabetically sorted array of:
  ```lua
  {
    method = qword,  -- MonoMethod* handle
    name = string,   -- Method name
    flags = integer, -- Method attributes
    parent = qword   -- Declaring MonoClass* handle
  }
  ```

### `mono_method_getName(method)`
- **Returns**: `string` - Method name.

### `mono_method_getFullName(method)`
- **Returns**: `string` - Full method signature name.

### `mono_method_getClass(method)`
- **Returns**: `qword` - Declaring `MonoClass*`.

### `mono_method_get_parameters(method)`
Returns structured parameter definitions:
- **Returns**: `table`:
  ```lua
  {
    parameters = {
      { name = string, type = integer, monotype = qword },
      ...
    },
    returntype = integer,
    returnmonotype = qword
  }
  ```

### `mono_method_getSignature(method)`
- **Returns**:
  - `signature`: Formatted parameter string.
  - `parameternames`: Array of parameter name strings.
  - `returntype`: Return type name string.

### `mono_compile_method(method)`
**Compiles a method into native machine code.**
- **Parameters**: `method` (`qword`): `MonoMethod*` handle.
- **Returns**: `qword` - Memory address of native executable machine code!
- **Notes**: In Mono, this JIT compiles the method if not already compiled. In IL2CPP, this returns the pre-compiled AOT native code address.

### `mono_method_disassemble(method)`
- **Returns**: `string` - CIL bytecode disassembly text. (Returns empty string on IL2CPP).

### `mono_getILCodeFromMethod(method)`
- **Returns**: `address, size` - Base address and byte count of CIL bytecode in memory. (Returns `nil` on IL2CPP).

### `mono_getJitInfo(address)`
Maps a native instruction address back to its JIT metadata.
- **Returns**: `table` containing:
  - `jitinfo`: `MonoJitInfo*` handle.
  - `method`: `MonoMethod*` handle.
  - `code_start`: Beginning address of compiled code.
  - `code_size`: Byte size of compiled code block.

### `mono_invoke_method(domain, method, object, args)`
**Executes a method dynamically in the target process.**
- **Parameters**:
  - `domain` (`qword`, optional): Runtime domain (`nil` uses default).
  - `method` (`qword` or `string`): `MonoMethod*` handle or method name.
  - `object` (`qword`): Instance object pointer (`0` or `nil` for static methods).
  - `args` (`table`): Array of arguments. Each argument can be a raw value or `{type = vtType, value = val}`:
    ```lua
    local args = {
      { type = vtDword, value = 100 },
      { type = vtSingle, value = 50.5 }
    }
    ```
- **Returns**: `result, exception, vtype`:
  - `result`: Returned value or object address. If return type is a struct/enum, fields are automatically read into a table.
  - `exception`: Exception message string if an unhandled exception occurred, else `nil`.
  - `vtype`: `MONO_TYPE_*` integer of returned value.

### `mono_invoke(methodname, instance, arguments)`
Convenience wrapper calling `mono_invoke_method(nil, methodname, instance, arguments)`.

---

## 7. Objects, Instances, Strings & Arrays

### `mono_object_getClass(address)`
Determines the class of an object instance at a memory address.
- **Parameters**: `address` (`qword`) - Object memory address.
- **Returns**: `classHandle, className` - `MonoClass*` handle and class name string.

### `mono_object_new(class)`
Allocates a new object of the specified class on the managed heap.
- **Parameters**: `class` (`qword`) - `MonoClass*` handle.
- **Returns**: `qword` - Allocated `MonoObject*` memory address.

### `mono_object_init(object)`
Runs default object initialization on an allocated `MonoObject*`.
- **Returns**: `boolean`.

### `mono_object_unbox(object)`
Unboxes a boxed value type object.
- **Returns**: `qword` - Direct pointer to the raw value type data in memory.

### `mono_object_enumValues(object)`
Reads all instance fields of an object from memory.
- **Parameters**: `object` (`qword`) - Object instance pointer.
- **Returns**: `table` - Key-value map `{fieldName = value}` with current field values.

### `mono_object_findRealStartOfObject(address, maxsize)`
Scans backwards from an interior address (such as a field pointer) to find the object's base header.
- **Parameters**: `address` (`qword`), `maxsize` (`integer`, default `4096`).
- **Returns**: `baseAddress, classAddress, className`.

### `mono_class_findInstancesOfClass(domain, class, callback, progressBar)`
Performs a memory scan to locate all live instances of a class matching its VTable pointer.
- **Parameters**: `domain` (`qword`), `class` (`qword`), `callback` (`function(addresses)`), `progressBar` (optional).

### `mono_class_findInstancesOfClassListOnly(domain, class, progressBar)`
Finds all live instances of a class synchronously.
- **Returns**: `qword[]` - Array of instance memory addresses.
- **Notes**: In Unity games, leverages `UnityEngine.Resources.FindObjectsOfTypeAll` or `UnityEngine.Object.FindObjectsOfType` for instant, authoritative results.

### `mono_new_string(domain, utf8str)`
Allocates a new managed `System.String` object in the target process.
- **Parameters**: `domain` (`qword`, optional), `utf8str` (`string`).
- **Returns**: `qword` - Memory address of new managed string object.

### `mono_string_readString(stringobject)`
Reads a managed `System.String` instance from target memory.
- **Parameters**: `stringobject` (`qword`) - Address of managed string object.
- **Returns**: `string` - Decoded text.

### `mono_array_new(class, count)`
Allocates a new single-dimensional managed array.
- **Parameters**: `class` (`qword`) - Element `MonoClass*`, `count` (`integer`).
- **Returns**: `qword` - Memory address of managed array object.

### `mono_array_element_size(arrayClass)`
- **Returns**: `integer` - Size in bytes of a single array element.

### `mono_class_getArrayElementClass(arrayClass)`
- **Returns**: `qword` - Element `MonoClass*` handle.

### `mono_arrayinstance_getCount(instance)`
- **Returns**: `integer` - Element count read directly from target array header.

### `mono_arrayinstance_getItemAddress(instance, index)`
- **Returns**: `qword` - Memory address of element at 0-based `index`.

---

## 8. CE Structure Dissector & GUI Integration

### `mono_dissect()`
Opens the Mono Data Dissector window showing the assembly/class/field hierarchy treeview.

### `mono_createStructureFromName(name)`
Generates a Cheat Engine data structure from a Mono class name.

### `mono_reloadGlobalStructures(imagename)`
Reloads all global CE structure definitions for the specified image.

### `mono_purgeDuplicateGlobalStructures()`
Cleans up duplicate global structure definitions in Cheat Engine.

---

## 9. Auto Assembler Commands

### `USEMONO`
Directs Cheat Engine to initialize and connect `MonoDataCollector` before executing the assembly script.
```asm
[ENABLE]
USEMONO
// Your AA script...
```

### `FINDMONOMETHOD(DefineName, Namespace:ClassName:MethodName)`
Resolves the method, compiles it with `mono_compile_method`, and defines an AA symbol equal to the native entry address.
```asm
[ENABLE]
USEMONO
FINDMONOMETHOD(TakeDamageEntry, Assembly-CSharp:PlayerHealth:TakeDamage)

TakeDamageEntry:
  jmp my_hook
```

### `GETMONOSTRUCT(StructName, Namespace:ClassName)`
Generates an Auto Assembler structure definition matching the exact field layout and vtable offset of the class.
```asm
[ENABLE]
USEMONO
GETMONOSTRUCT(EnemyStruct, Assembly-CSharp:EnemyController)

// In assembly:
mov eax, [rcx+EnemyStruct.currentHP]
```
