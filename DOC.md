# Myr Language Reference

Myr is a strongly-typed, embedded language with FP ergonomics. The runtime is a bytecode VM written in Odin. This document is the complete language reference for Myr version 0.1.0.

---

## Table of Contents

1. [Primitives](#primitives)
2. [Variables and Constants](#variables-and-constants)
3. [Operators](#operators)
4. [Control Flow](#control-flow)
5. [Functions](#functions)
6. [Structs](#structs)
7. [Enums](#enums)
8. [Match](#match)
9. [Pointers](#pointers)
10. [Arrays](#arrays)
11. [Slices](#slices)
12. [Strings](#strings)
13. [Generic Functions and Structs](#generic-functions-and-structs)
14. [Built-ins](#built-ins)
15. [CLI](#cli)

---

## Primitives

| Type    | Description                          |
|---------|--------------------------------------|
| `int`   | 64-bit signed integer                |
| `i64`   | Alias for `int`                      |
| `float` | 64-bit IEEE 754 floating-point       |
| `f64`   | Alias for `float`                    |
| `bool`  | `true` or `false`                    |
| `str`   | Immutable UTF-8 string slice         |

Integer literals are decimal. Float literals require a decimal point (`3.14`, not `3.`). Boolean literals are `true` and `false`. The nil pointer value is `nil`.

```
function main() {
    let a: int   = 42
    let b: float = 3.14
    let c: bool  = true
    let d: str   = "hello"
    print(a)
    print(b)
    print(c)
    print(d)
}
```

---

## Variables and Constants

### `let` — mutable binding

```
let x = 10            // type inferred as int
let y: float = 2.5    // explicit type annotation
let s: str = "world"
```

`let` bindings are mutable. The type annotation after `:` is optional when it can be inferred from the initializer.

### `const` — compile-time constant

```
const MAX = 100
const PI  = 3.14159
const MSG = "ready"
```

Constants are evaluated at compile time. Arithmetic expressions over other constants are folded:

```
const A = 10
const B = 20
const C = A + B    // C == 30, resolved at compile time
```

Constants may appear at the top level (file scope) or inside a function body. A local `const` shadows a top-level one with the same name.

```
const X = 1

function main() -> int {
    const X = 2    // shadows the global X in this scope
    return X       // returns 2
}
```

---

## Operators

### Arithmetic

| Operator | Description         |
|----------|---------------------|
| `+`      | Addition            |
| `-`      | Subtraction         |
| `*`      | Multiplication      |
| `/`      | Division            |
| `%`      | Remainder (modulo)  |
| `-x`     | Unary negation      |

Integer division truncates toward zero. Dividing an integer by zero is a runtime error (`DIVISION_BY_ZERO`).

The `+` operator also concatenates strings:

```
let greeting = "Hello, " + "world"
```

### Comparison

| Operator | Description              |
|----------|--------------------------|
| `==`     | Equal                    |
| `!=`     | Not equal                |
| `<`      | Less than                |
| `<=`     | Less than or equal       |
| `>`      | Greater than             |
| `>=`     | Greater than or equal    |

Comparison operators return `bool`. Pointers may be compared with `==` and `!=`; `nil` compares equal only to `nil`.

### Logical

| Operator | Description  |
|----------|--------------|
| `&&`     | Logical AND  |
| `\|\|`   | Logical OR   |
| `!`      | Logical NOT  |

### Bitwise (integers only)

| Operator | Description              |
|----------|--------------------------|
| `&`      | Bitwise AND              |
| `\|`     | Bitwise OR               |
| `^`      | Bitwise XOR (infix)      |
| `~x`     | Bitwise NOT (unary)      |
| `<<`     | Left shift               |
| `>>`     | Right shift              |

Note: `^` in infix position is XOR. In prefix position (`^T`) it denotes a pointer type.

### Compound Assignment

| Operator | Equivalent to    |
|----------|------------------|
| `+=`     | `x = x + rhs`   |
| `-=`     | `x = x - rhs`   |
| `*=`     | `x = x * rhs`   |
| `/=`     | `x = x / rhs`   |
| `%=`     | `x = x % rhs`   |

Compound assignment works on local variables, struct fields (including through pointers), and array/slice elements.

### Operator Precedence

From highest to lowest:

1. Unary: `-x`, `!x`, `~x`
2. `*`, `/`, `%`
3. `+`, `-`
4. `<<`, `>>`
5. `<`, `<=`, `>`, `>=`
6. `==`, `!=`
7. `&`
8. `^`
9. `|`
10. `&&`
11. `||`

---

## Control Flow

### `if` / `else if` / `else`

```
if cond {
    // ...
} else if other_cond {
    // ...
} else {
    // ...
}
```

`if` is an expression. When every branch produces a value, the whole `if` expression evaluates to that value:

```
function main() -> int {
    let x = 7
    let label = if x > 5 { 1 } else { 0 }
    return label    // 1
}
```

### `for` loops

**While-style** — loops while condition is true:

```
for cond {
    // body
}
```

**Infinite loop** — loops forever (use `break` to exit):

```
for {
    // body
}
```

**C-style** — init, condition, post:

```
for let i = 0; i < n; i += 1 {
    // body
}
```

The loop variable declared in the `init` clause is scoped to the loop body and is not accessible after the loop ends.

### `break` and `continue`

```
for let i = 0; i < 10; i += 1 {
    if i == 5 { break }       // exit the loop
    if i % 2 == 0 { continue } // skip to the next iteration
    print(i)
}
```

### Complete example

```
function fizzbuzz(n: int) {
    let i = 1
    for i <= n {
        if i % 15 == 0 {
            print("FizzBuzz")
        } else if i % 3 == 0 {
            print("Fizz")
        } else if i % 5 == 0 {
            print("Buzz")
        } else {
            print(i)
        }
        i = i + 1
    }
}

function main() {
    fizzbuzz(20)
}
```

---

## Functions

### Declaration

```
function name(param: Type, ...) -> ReturnType {
    return value
}
```

A function without a `-> ReturnType` annotation returns nothing (void). A bare `return` is valid in void functions.

```
function greet(name: str) {
    print(name)
}

function add(a: int, b: int) -> int {
    return a + b
}
```

### Recursion

```
function fib(n: int) -> int {
    if n <= 1 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}

function main() {
    for let i = 0; i <= 10; i += 1 {
        print(fib(i))
    }
}
```

### First-class functions

Functions are values. A function can be stored in a variable, passed as an argument, or returned from another function. The type of a function is written `(ParamTypes...) -> ReturnType`.

```
function double(x: int) -> int { return x * 2 }

function apply(f: (int) -> int, x: int) -> int {
    return f(x)
}

function get_fn() -> (int) -> int {
    return double
}

function main() {
    let f = double          // store in a let
    print(apply(f, 5))      // 10
    let g = get_fn()
    print(g(7))             // 14
}
```

Multi-parameter function type:

```
function combine(f: (int, int) -> int, a: int, b: int) -> int {
    return f(a, b)
}
```

---

## Structs

Structs are value types. All fields are named. Declaration appears at the top level.

```
struct Point { x: float, y: float }
```

### Construction

```
let p = Point{x = 3.0, y = 4.0}
```

### Field access and mutation

```
let p = Point{x = 1.0, y = 2.0}
p.x = 99.0
print(p.x)    // 99.0
```

### Value semantics

Assignment copies all fields. Mutating the copy does not affect the original.

```
struct Point { x: float, y: float }

function main() {
    let p = Point{x = 3.0, y = 4.0}
    let q = p        // full copy
    q.x = 99.0
    print(p.x)       // 3.0 — unaffected
}
```

### Nested structs

```
struct Vec2 { x: float, y: float }
struct Rect { origin: Vec2, size: Vec2 }

function area(r: Rect) -> float {
    return r.size.x * r.size.y
}

function main() {
    let r = Rect{
        origin = Vec2{x = 0.0, y = 0.0},
        size   = Vec2{x = 10.0, y = 5.0},
    }
    print(area(r))    // 50.0
}
```

### Passing structs to functions

Structs are passed by value (copied). To allow a function to mutate a struct, pass a pointer to it (see [Pointers](#pointers)).

### Generic structs

```
struct Stack[T] { top: T, size: int }

function main() -> int {
    let s = Stack[int]{top = 42, size = 1}
    return s.top    // 42
}
```

Type parameters are listed in `[]` after the struct name. When constructing a generic struct, supply the concrete type in `[]`:

```
struct Pair[A, B] { first: A, second: B }

function main() -> int {
    let p = Pair[int, float]{first = 7, second = 3.14}
    return p.first    // 7
}
```

---

## Enums

Enums are tagged unions. Every variant has named fields only — no positional payloads.

### Declaration

```
enum Shape {
    Circle { radius: float },
    Rect   { w: float, h: float },
}
```

Unit variants (no fields) use empty braces:

```
enum Direction { North {}, South {}, East {}, West {} }
```

### Construction

```
let circle = Shape.Circle { radius = 5.0 }
let rect   = Shape.Rect   { w = 10.0, h = 4.0 }
let dir    = Direction.North {}
```

### Enums as function parameters and return types

```
enum Shape {
    Circle { radius: float },
    Rect   { w: float, h: float },
}

function make_unit_square() -> Shape {
    return Shape.Rect { w = 1.0, h = 1.0 }
}
```

Matching on enum values is documented in the [Match](#match) section.

---

## Match

`match` tests a subject against a list of arms and runs the first arm that matches. It is an expression.

### Enum variant match

Each arm names the enum variant and lists the fields to bind:

```
enum Shape {
    Circle { radius: i64 },
    Rect   { w: i64, h: i64 },
}

function area(s: Shape) -> i64 {
    match s {
        Shape.Circle { radius } => { return radius * radius }
        Shape.Rect   { w, h }  => { return w * h }
    }
    return 0
}
```

Bound field names (`radius`, `w`, `h`) are live as read-only locals inside the arm body.

### Wildcard arm

`_` matches anything. It must come after all specific arms.

```
function main() -> i64 {
    let s = Shape.Rect { w = 3, h = 7 }
    match s {
        Shape.Circle { radius } => { return radius }
        _ => { return 99 }
    }
    return 0
}
```

### Scalar match

`match` also works on `int`, `float`, `bool`, and `str` — compare against literal values:

```
function main() -> i64 {
    let x: i64 = 1
    match x {
        0 => { return 100 }
        1 => { return 200 }
        _ => { return 0 }
    }
    return -1
}
```

### Match as an expression

When every arm ends with a bare expression (not a `return` statement), `match` produces a value:

```
function main() -> i64 {
    let x: i64 = 7
    let y = match x {
        7 => 42
        _ => 0
    }
    return y    // 42
}
```

### Exhaustiveness

The type checker enforces that every variant of an enum is covered. A wildcard arm (`_`) satisfies the requirement for any uncovered variants.

```
// This is a compile error — Rect is not covered:
match s {
    Shape.Circle { radius } => { }
}

// This is valid — wildcard covers Rect:
match s {
    Shape.Circle { radius } => { }
    _ => { }
}
```

---

## Pointers

Pointer types are written `^T`. Myr provides two ways to obtain a pointer: heap allocation with `new` and address-of a stack local with `&`.

### Heap allocation — `new`

```
struct Point { x: i64, y: i64 }

function main() {
    let p: ^Point = new Point{x = 10, y = 20}
    print(p.x)    // 10
}
```

`new Struct{...}` allocates on the heap and returns a `^Struct`.

### Address-of a local — `&`

```
struct Counter { n: int }

function inc(c: ^Counter) {
    c.n += 1
}

function main() -> int {
    let c = Counter{n = 0}
    inc(&c)    // pass a pointer to the stack local
    inc(&c)
    return c.n    // 2
}
```

`&x` produces a pointer to the local variable `x`. Mutations through the pointer are visible on the original variable.

### Auto-deref field access

Field access through a pointer auto-dereferences:

```
let p: ^Point = new Point{x = 3, y = 4}
p.x = 99      // writes through the pointer
print(p.x)    // reads through the pointer; prints 99
```

### Explicit deref — `p^`

`p^` copies the pointed-at struct value onto the stack:

```
struct Point { x: i64, y: i64 }

function deref_copy(p: ^Point) -> Point { return p^ }

function main() -> i64 {
    let p: ^Point = new Point{x = 42, y = 0}
    let copy = deref_copy(p)
    copy.x = 999        // does not affect p
    return p.x          // 42
}
```

### nil

A pointer can be `nil`. Dereferencing `nil` is a runtime error (`NULL_DEREF`).

```
struct Node { val: i64, next: ^Node }

function main() {
    let n: ^Node = new Node{val = 1, next = nil}
    print(n.next == nil)    // true
}
```

### Linked list example

```
struct Node { val: int, next: ^Node }

function push(head: ^Node, val: int) -> ^Node {
    return new Node{val = val, next = head}
}

function sum(n: ^Node) -> int {
    let total = 0
    for n != nil {
        total += n.val
        n = n.next
    }
    return total
}

function main() {
    let head: ^Node = new Node{val = 5, next = nil}
    for let i = 4; i >= 1; i -= 1 {
        head = push(head, i)
    }
    print(sum(head))    // 15
}
```

---

## Arrays

`Array[T, N]` is a fixed-size, stack-allocated array of `N` elements of type `T`. The size `N` must be a compile-time constant.

### Declaration and initialization

```
let a = Array[int, 5]{1, 2, 3, 4, 5}
```

Elements are listed positionally in `{}`.

### Read and write

```
function main() -> int {
    let a = Array[int, 5]{10, 20, 30, 40, 50}
    a[0] = 99
    return a[0] + a[1]    // 99 + 20 = 119
}
```

Index with `a[i]`. Writing past the fixed size is undefined behavior (no bounds check at runtime for arrays — use `Slice[T]` if you need dynamic sizing).

### Iterating an array

```
function main() -> int {
    let a = Array[int, 5]{1, 2, 3, 4, 5}
    let sum = 0
    for let i = 0; i < 5; i += 1 {
        sum += a[i]
    }
    return sum    // 15
}
```

---

## Slices

`Slice[T]` is a heap-backed dynamic array. Its fields are `.len`, `.cap`, and `.grow_factor`.

### Declaration

```
let s: Slice[i64] = Slice[i64]{cap = 8}
```

When `cap` is omitted the default capacity is **64**:

```
let s: Slice[i64] = Slice[i64]{}    // cap = 64
```

`grow_factor` defaults to **1** (the capacity doubles: `new_cap = old_cap + grow_factor * old_cap`). Set it explicitly to control growth rate:

```
let s: Slice[i64] = Slice[i64]{cap = 4, grow_factor = 2}
```

Setting `grow_factor = 0` disables growth: writing past `cap` is a runtime error (`INDEX_OUT_OF_BOUNDS`).

### Read and write

```
s[0] = 42
let v = s[0]    // 42
```

### Auto-grow

Writing at index `i >= cap` triggers a grow. The backing buffer is reallocated and old data is copied. After the write, `cap` is updated to the new capacity.

```
function main() -> i64 {
    let s: Slice[i64] = Slice[i64]{cap = 2}
    s[0] = 10
    s[1] = 20
    s[2] = 30    // triggers grow: cap 2 → 4
    return s[0] + s[1] + s[2]    // 60
}
```

### `.len` tracking

`.len` is automatically updated to `max(len, i + 1)` after each write at index `i`:

```
function main() -> i64 {
    let s = Slice[i64]{cap = 8}
    s[0] = 1
    s[1] = 2
    s[3] = 9    // skips index 2; len = 4
    return s.len
}
```

### Fields summary

| Field          | Type  | Meaning                                             |
|----------------|-------|-----------------------------------------------------|
| `.len`         | `int` | Highest index written + 1                           |
| `.cap`         | `int` | Current backing capacity                            |
| `.grow_factor` | `int` | Growth multiplier; 0 disables growth                |

### Full example

```
function main() -> i64 {
    let s: Slice[i64] = Slice[i64]{cap = 5}
    for let i = 0; i < 5; i += 1 {
        s[i] = i + 1
    }
    let sum = 0
    for let i = 0; i < s.len; i += 1 {
        sum += s[i]
    }
    return sum    // 15
}
```

---

## Strings

`str` is an immutable slice over UTF-8 bytes. String literals use double quotes.

### Literals and escape sequences

| Escape | Meaning           |
|--------|-------------------|
| `\n`   | Newline           |
| `\t`   | Tab               |
| `\\`   | Literal backslash |
| `\"`   | Literal quote     |

```
let s = "hello\nworld"
let t = "say \"hi\""
```

### `.len`

Returns the byte count (not character count):

```
function main() -> int {
    let s = "hello"
    return s.len    // 5
}
```

### Indexing — `s[i]`

Returns a single-character `str` (not an integer):

```
function main() -> bool {
    let s = "hello"
    return s[0] == "h"    // true
}
```

Indexing out of bounds is a runtime error (`INDEX_OUT_OF_BOUNDS`).

### Comparison

```
let s = "abc"
print(s == "abc")    // true
print(s != "xyz")    // true
```

### Traversal example

```
function main() -> bool {
    let s = "hello"
    let found = false
    for let i = 0; i < s.len; i += 1 {
        if s[i] == "l" {
            found = true
        }
    }
    return found    // true
}
```

---

## Generic Functions and Structs

### Generic functions

Type parameters are listed in `[]` after the function name. Each call site is monomorphised — the compiler generates a separate concrete instantiation per distinct type.

```
function max[T](a: T, b: T) -> T {
    if a > b { return a }
    return b
}

function main() {
    print(max(3, 7))        // int instantiation → 7
    print(max(3.14, 2.71))  // float instantiation → 3.14
}
```

### Multiple type parameters

```
function zip[A, B](a: A, b: B) -> A {
    return a
}
```

### Generic structs

```
struct Box[T] { value: T }

function main() -> int {
    let b = Box[int]{value = 99}
    return b.value    // 99
}
```

Nested generic structs work:

```
struct Box[T] { value: T }

function main() -> int {
    let inner = Box[int]{value = 42}
    let outer = Box[Box[int]]{value = inner}
    return outer.value.value    // 42
}
```

### Generic functions with generic struct params/returns

```
struct Stack[T] { top: T, size: int }

function make_stack[T](val: T) -> Stack[T] {
    return Stack[T]{top = val, size = 1}
}

function peek[T](s: Stack[T]) -> T {
    return s.top
}

function main() -> int {
    let s = make_stack(55)
    return peek(s)    // 55
}
```

### Nested generic calls

```
function max[T](a: T, b: T) -> T {
    if a > b { return a }
    return b
}
function min[T](a: T, b: T) -> T {
    if a < b { return a }
    return b
}
function clamp[T](val: T, lo: T, hi: T) -> T {
    return max(min(val, hi), lo)
}

function main() {
    print(clamp(15, 0, 10))     // 10
    print(clamp(-5, 0, 10))     // 0
    print(clamp(5, 0, 10))      // 5
}
```

---

## Built-ins

### `print(val)`

Prints any value followed by a newline. Works with all types: `int`, `float`, `bool`, `str`, struct values, enum values, and pointers.

```
print(42)
print(3.14)
print(true)
print("hello")
```

### `input()`

Reads a line from stdin and returns it as a `str`. The trailing newline is stripped.

```
function main() {
    let name = input()
    print(name)
}
```

An optional prompt string can be passed; it is printed to stdout before reading:

```
function main() {
    let name = input("Enter your name: ")
    print(name)
}
```

---

## CLI

```
myr run <file>          compile and execute a .myr file
myr run --dump <file>   compile, print bytecode disassembly, then execute
myr check <file>        parse and type-check without executing
myr dump <file>         print bytecode disassembly without executing
myr version             print the Myr version
myr help                print usage
myr help <command>      print help for a specific command
myr <file>              shorthand for myr run <file>
```

`myr check` exits with code 0 on success, 1 if there are any errors. It performs the full pipeline (parse → name resolution → type check → compile) but skips execution.

`myr dump` is useful for inspecting compiler output and debugging code generation.

---

## Complete Programs

### Fibonacci

```
function fib(n: int) -> int {
    if n <= 1 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}

function main() {
    for let i = 0; i <= 10; i += 1 {
        print(fib(i))
    }
}
```

### Primes

```
function is_prime(n: int) -> int {
    if n < 2 { return 0 }
    let i = 2
    for i * i <= n {
        if n % i == 0 { return 0 }
        i = i + 1
    }
    return 1
}

function main() {
    let n = 2
    let count = 0
    for count < 10 {
        if is_prime(n) == 1 {
            print(n)
            count = count + 1
        }
        n = n + 1
    }
}
```

### Struct mutation via pointer

```
struct Vec2 { x: float, y: float }
struct Rect { origin: Vec2, size: Vec2 }

function area(r: Rect) -> float {
    return r.size.x * r.size.y
}

function scale(r: ^Rect, factor: float) {
    r.size.x *= factor
    r.size.y *= factor
}

function main() {
    let rp: ^Rect = new Rect{
        origin = Vec2{x = 1.0, y = 2.0},
        size   = Vec2{x = 8.0, y = 4.0},
    }
    scale(rp, 2.0)
    print(rp.size.x)    // 16.0
    print(area(rp^))    // 128.0
}
```

### Enum and match

```
enum Shape {
    Circle { radius: i64 },
    Rect   { w: i64, h: i64 },
}

function describe(s: Shape) -> i64 {
    match s {
        Shape.Circle { radius } => { return radius }
        Shape.Rect   { w, h }  => { return w + h }
    }
    return 0
}

function main() {
    let circle = Shape.Circle { radius = 7 }
    let rect   = Shape.Rect   { w = 10, h = 4 }
    print(describe(circle))    // 7
    print(describe(rect))      // 14
}
```

### Generic max and clamp

```
function max[T](a: T, b: T) -> T {
    if a > b { return a }
    return b
}
function min[T](a: T, b: T) -> T {
    if a < b { return a }
    return b
}
function clamp[T](val: T, lo: T, hi: T) -> T {
    return max(min(val, hi), lo)
}

function main() {
    print(max(3, 7))
    print(max(3.14, 2.71))
    print(clamp(15, 0, 10))
    print(clamp(-5, 0, 10))
}
```
