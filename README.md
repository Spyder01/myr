# Myr

A lightweight, embeddable, strongly-typed language with FP ergonomics.

Memory-efficient and performant by design — algebraic types, no hidden costs, no magic. Implemented in [Odin](https://odin-lang.org).

---

## Quick start

```sh
odin build . -out:myr    # build the myr binary
./myr run main.myr
```

Or run directly via the Odin toolchain:

```sh
odin run . -- run main.myr
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

## Documentation

See [DOC.md](DOC.md) for the full language reference — types, operators, control flow, generics, structs, enums, pointers, arrays, slices, strings, and more.

## Examples

See the [`examples/`](examples/) directory:

| File | What it shows |
|------|---------------|
| `fibonacci.myr` | Recursive and iterative fib |
| `fizzbuzz.myr` | Classic FizzBuzz |
| `structs.myr` | Value semantics, nested structs, pointers |
| `linked_list.myr` | Recursive structs, pointer traversal |
| `enums.myr` | Enum construction and field access |
| `match_demo.myr` | Match dispatch and destructuring |
| `generics.myr` | Generic functions, generic structs |
| `slices.myr` | Dynamic slices, auto-grow, `.len` |
| `sorting.myr` | Bubble sort on a fixed array |
| `strings.myr` | String traversal, character counting |
| `first_class_fn.myr` | Higher-order functions |
| `primes.myr` | Sieve-style prime search |

## Building from source

Requires the [Odin compiler](https://odin-lang.org/docs/install/).

```sh
odin build .                      # build interpreter binary
odin test ./backend/bytecode/vm/  # run VM tests
```

## Status

Phase 1 — bytecode compiler + VM. Pipeline:

```
source → lex → parse → type-check → compile → VM
```

**Working:** integers, floats, booleans, strings (`.len`, `s[i]`), arithmetic, comparisons, logical/bitwise operators, compound assignment, if/else, all loop forms, break/continue, functions, recursion, first-class functions, constants, structs (value semantics, nested, pointer), enums with named-field variants, match expressions (variant dispatch, field destructuring, wildcard, match-as-expression), generic functions (monomorphisation, nested generics, generic struct params/returns), fixed-size arrays (`Array[T, N]`), dynamic slices (`Slice[T]`), pointers (`^T`, `new`, `nil`, `&x`, `p^`), recursive structs, type checker.

**Not yet:** closures, maps, for-in iteration.
