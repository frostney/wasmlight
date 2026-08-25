# Connector language

## Executive Summary

- `.wlc` is a declaration-only DSL for Wasmlight connectors. It is not a
  programming language: it is not Turing complete and it admits no
  general-purpose computation. Bindings are declared; they are not
  programmed.
- `ParseConnector` in `Wasm.Connector` is the shipped parse entry point. It
  builds a declaration model for later ABI planning. It is not a compile
  command and does not load a library.
- The language is not C# and invokes no C# compiler.

## Parser-accepted grammar

This section describes the grammar the parser accepts today.
`wasmlight compile --connector` selects and parses `.wlc` files through
`ParseConnector`. Import matching and unused-declaration stripping are
`ResolveConnectorPlan` in `Wasm.Connector.Resolve`
([connector-resolve.md](connector-resolve.md)); embedding remains later
work.

A file is a sequence of static classes. Each class may contain structs,
enums, delegates, and `static extern` methods. Braces and semicolons
follow ordinary C# placement. `//` and non-nested `/* */` comments are
trivia.

```csharp
public static class Libc
{
    public enum Whence : int
    {
        Set = 0,
        Cur,
        End = 2,
    }

    public struct Iovec
    {
        [Scoped]
        public byte[] Base;
        public int Length;
    }

    public delegate int ReadCallback(int fd, [Out] byte[] buf, int count);

    [Queued]
    public delegate void Notify(int code);

    [DllImport("libc")]
    public static extern int getpid();

    [DllImport("libc", EntryPoint = "write")]
    [return: MarshalAs(UnmanagedType.Int32)]
    public static extern int Write(
        int fd,
        [In, MarshalAs(UnmanagedType.LPArray)] byte[] buf,
        int count);
}
```

Fixed attributes:

- `DllImport("library")` on each extern method, with optional
  `EntryPoint = "symbol"` (also accepted as a standalone `[EntryPoint("symbol")]`)
- `MarshalAs(UnmanagedType.Kind)` on parameters, fields, and
  `[return: MarshalAs(...)]`, with optional `SizeConst`
- `In` and `Out` on parameters (combinable as copy-in, copy-out, or inout)
- `Scoped` on a delegate (same-call callback) or on a parameter/field
  (scoped borrow)
- `Queued` on a delegate (foreign-thread void notification)

Accepted `UnmanagedType` members are the C ABI set `Int8`, `UInt8`,
`Int16`, `UInt16`, `Int32`, `UInt32`, `Int64`, `UInt64`, `Float32`,
`Float64`, `Bool`, `LPStr`, `LPWStr`, `LPUTF8Str`, `LPArray`,
`ByValArray`, `SysInt`, and `SysUInt`.

Visibility keywords are accepted and ignored. Parameter modifiers
`ref`, `out`, and `in` are recorded. Enum members may use an integer
literal; omitted values increment from the previous member.

The model keeps every parsed declaration, including unused classes and
methods. Matching guest imports and stripping unused bindings is not
part of this parser.

## Rejected constructs

The parser raises `EWasmConnectorError` with a 1-based line and column.
These prefixes mark constructs outside the language:

- `method bodies are outside the connector language`
- `properties are outside the connector language`
- `inheritance is outside the connector language`
- `generics are outside the connector language`
- `expressions are outside the connector language`
- `control flow is outside the connector language`
- `allocation is outside the connector language`

Unknown attributes, a non-static class, and an `extern` method without
`[DllImport]` are also rejected with a precise prefix. The error class
is a sibling of `EWasmTextError`, never a decode or validation error.
