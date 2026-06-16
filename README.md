<p align="center">
  <img src="assets/logo.png" alt="Myr logo" width="140">
</p>

<h1 align="center">Myr</h1>

<p align="center">
  A lightweight, embeddable, strongly-typed language with FP ergonomics.
</p>

<p align="center">
  Memory-efficient and performant by design — algebraic types, no hidden costs, no magic.<br>
  Implemented in <a href="https://odin-lang.org">Odin</a>.
</p>

---

## Quick start

```sh
./build.sh                                   # builds the optimized binary to bin/myr
bin/myr run examples/fibonacci/fibonacci.myr
```

Or run directly via the Odin toolchain (no separate build step):

```sh
odin run . -- run examples/fibonacci/fibonacci.myr
```

## CLI

```
myr run   <file>     parse, compile, and execute
myr check <file>     type-check only — report errors, don't run
myr dump  <file>     print bytecode disassembly
myr version          print version
myr help             usage info
```

## A taste of the language

```myr
function fib(n: int) -> int {
    if n <= 1 { return n }
    return fib(n - 1) + fib(n - 2)
}

function main() {
    for let i = 0; i <= 10; i += 1 {
        print(fib(i))
    }
}
```

```myr
enum Shape {
    Circle { radius: float },
    Rect   { w: float, h: float },
}

function area(s: Shape) -> float {
    return match s {
        Shape.Circle { radius } => { radius * radius * 3.14 }
        Shape.Rect   { w, h }  => { w * h }
    }
}

function main() {
    print(area(Shape.Circle { radius = 5.0 }))
    print(area(Shape.Rect   { w = 10.0, h = 4.0 }))
}
```

```myr
struct Node { val: int, next: ^Node }

function sum(n: ^Node) -> int {
    let total = 0
    for n != nil {
        total += n.val
        n = n.next
    }
    return total
}

function main() {
    let c: ^Node = new Node{val = 3, next = nil}
    let b: ^Node = new Node{val = 2, next = c}
    let a: ^Node = new Node{val = 1, next = b}
    print(sum(a))   // 6
}
```

```myr
function double(x: int) -> int { return x * 2 }
function square(x: int) -> int { return x * x }

function apply(f: (int) -> int, x: int) -> int {
    return f(x)
}

function main() {
    print(apply(double, 5))    // 10
    print(apply(square, 5))    // 25
    let f = double
    print(f(7))                // 14
}
```

## Modules

A **directory is a module**. Every `.myr` file in a directory belongs to the same module and shares scope, so you can split a program across files freely. A **subdirectory is a separate, importable module**, accessed through its namespace:

```
project/
  main.myr
  math/
    ops.myr      ← function add(a: int, b: int) -> int { return a + b }
```

```myr
// main.myr
import "math"            // or:  import "math" as m

function main() {
    print(math.add(2, 3))   // 5 — module members are accessed qualified
}
```

Imports resolve relative to the entry file, load transitively, and **circular imports are reported** (`circular import: a -> b -> a`). Module-qualified types work too: `let v: math.Vec = math.Vec{ x = 1, y = 2 }`.

## Performance

Myr compiles to bytecode and runs on a stack VM with a real optimizer:

- **Type-specialized opcodes** — `ADD_I64`, `LTE_F64`, … emitted when a type is known, skipping runtime type dispatch.
- **Superinstruction fusion** — common sequences collapse into a single op; e.g. a loop guard `GET_LOCAL a; GET_LOCAL b; LT_I64; JUMP_IF_FALSE_POP` becomes one compare-and-branch instruction.
- **Function inlining** of small functions, plus constant folding and a peephole pass.

The result: the 30th Fibonacci number — ~2.7M recursive calls — runs in ~0.2s.

Benchmark it yourself:

```sh
./benchmarks/run.sh              # times each benchmark, checks for regressions
python3 benchmarks/compare.py    # head-to-head vs Python / Node / Lua
```

## How it works

The pipeline is strictly linear — source becomes bytecode in five passes, then runs on the VM:

```
source ─▶ lex ─▶ parse ─▶ name-resolve ─▶ type-check ─▶ compile ─▶ bytecode VM
```

- **Lexer** — hand-written; source text → tokens (with source spans for errors).
- **Parser** — recursive descent with Pratt expression parsing → an index-based AST.
- **Name resolution** — binds every identifier to its definition; enforces module scoping.
- **Type checker** — bidirectional inference over a typed AST; monomorphizes generics.
- **Compiler** — lowers the AST to bytecode, then a peephole pass fuses superinstructions.
- **VM** — a stack machine with type-specialized opcodes executes the bytecode.

The whole interpreter is written in [Odin](https://odin-lang.org), organized one package per stage:

| Package | Role |
|---------|------|
| `lexer/` | tokenizer |
| `parser/` | AST + recursive-descent/Pratt parser, module merging |
| `tree-walkers/nameresolution/` | scope + name binding |
| `tree-walkers/typechecker/` | type inference, generics |
| `backend/bytecode/` | bytecode compiler, peephole optimizer, disassembler |
| `backend/bytecode/vm/` | the stack VM |
| `embed/` | embedding API — drive the VM from a host program |

## Documentation

See [DOC.md](DOC.md) for the full language reference — types, operators, control flow, generics, structs, enums, pointers, arrays, slices, strings, and more.

## Examples

Each example is its own directory (a directory is a module). Run with
`bin/myr run examples/<name>/<name>.myr`:

| Example | What it shows |
|---------|---------------|
| `fibonacci/` | Recursive and iterative fib |
| `fizzbuzz/` | Classic FizzBuzz |
| `structs/` | Value semantics, nested structs, pointers |
| `linked_list/` | Recursive structs, pointer traversal |
| `enums/` | Enum construction and field access |
| `match_demo/` | Match dispatch and destructuring |
| `generics/` | Generic functions and structs over int, float, str |
| `slices/` | Dynamic slices, auto-grow, `.len` |
| `sorting/` | Bubble sort on a fixed array |
| `strings/` | String traversal, character counting |
| `first_class_fn/` | Higher-order functions |
| `primes/` | Trial-division prime search |

## Building from source

Requires the [Odin compiler](https://odin-lang.org/docs/install/).

```sh
odin build .                      # build interpreter binary
odin test ./backend/bytecode/vm/  # run VM tests
```

## Status

Phase 1 — bytecode compiler + VM (see [How it works](#how-it-works)).

**Working:** integers, floats, booleans, strings (`.len`, `s[i]`), arithmetic, comparisons, logical/bitwise operators, compound assignment, if/else, all loop forms, break/continue, functions, recursion, first-class functions, constants, structs (value semantics, nested, pointer), enums with named-field variants, match expressions (variant dispatch, field destructuring, wildcard, match-as-expression), generic functions and structs over any type (monomorphisation, nested generics, params/returns), fixed-size arrays (`Array[T, N]`), dynamic slices (`Slice[T]`), pointers (`^T`, `new`, `nil`, `&x`, `p^`), recursive structs, a bidirectional type checker, and a **module system** (directory = module, qualified imports, aliasing, transitive loading, circular-import detection, module-qualified types).

**Not yet (Phase 2):** closures, maps, for-in iteration, manual memory management + optional GC, C FFI, and compile-time decorators.
