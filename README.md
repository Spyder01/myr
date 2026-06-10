# Myr

A lightweight, embeddable, strongly-typed language with FP ergonomics.

Memory-efficient and performant by design — algebraic types, no hidden costs, no magic. You see what the program does and you decide how it does it. Implemented in [Odin](https://odin-lang.org).

---

## Quick start

```sh
./build.sh          # build the myr binary into bin/
./bin/myr run main.myr
```

Or via the Odin toolchain directly:

```sh
odin run . -- run main.myr
```

## CLI

```
myr run   <file>          parse, compile and execute
myr check <file>          compile only — report errors, don't run
myr dump  <file>          show bytecode disassembly (all functions)
myr version               print version
myr help  [command]       usage info
myr <file.myr>            shorthand for myr run <file.myr>
```

## Language

### Functions

```myr
function add(a: int, b: int) -> int {
    return a + b
}

function main() {
    print(add(1, 2))
}
```

### Variables and constants

```myr
const MAX = 100

function main() {
    let x = 10
    let y = MAX - x
    print(y)
}
```

### Compound assignment

```myr
function main() {
    let sum = 0
    let i = 1
    for i <= 10 {
        sum += i
        i += 1
    }
    print(sum)   // 55
}
```

### Conditionals

```myr
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
        i += 1
    }
}
```

### For loop forms

```myr
// while-style
for condition { }

// infinite with break
for {
    if done { break }
}

// C-style
for let i = 0; i < n; i += 1 { }
```

### Recursion

```myr
function fib(n: int) -> int {
    if n <= 1 { return n }
    return fib(n - 1) + fib(n - 2)
}
```

### Structs

Structs are value types — assignment copies all fields.

```myr
struct Point { x: float, y: float }

function main() {
    let p = Point{x = 3.0, y = 4.0}
    let q = p      // full copy
    q.x = 99.0
    print(p.x)     // 3.0 — unaffected
}
```

Structs can be nested:

```myr
struct Vec2 { x: float, y: float }
struct Rect { origin: Vec2, size: Vec2 }

function area(r: Rect) -> float {
    return r.size.x * r.size.y
}

function main() {
    let r = Rect{origin = Vec2{x = 0.0, y = 0.0}, size = Vec2{x = 10.0, y = 5.0}}
    print(area(r))   // 50.0
}
```

### Pointers

Myr has two ways to get a `^T` pointer:

- `new T{...}` — heap-allocates a struct and returns a `^T`
- `&x` — takes the address of an existing local variable, returning a `^T` that points directly into the stack frame

Field access through either kind of pointer auto-derefs — no `->` needed.

```myr
struct Point { x: int, y: int }

function move(p: ^Point, dx: int, dy: int) {
    p.x += dx
    p.y += dy
}

function main() {
    // heap allocation
    let p: ^Point = new Point{x = 0, y = 0}
    move(p, 3, 4)
    print(p.x)   // 3
    print(p.y)   // 4

    // stack reference — mutations are visible on the original
    let pt = Point{x = 10, y = 20}
    move(&pt, 5, 5)
    print(pt.x)  // 15
    print(pt.y)  // 25
}
```

`&x` gives a live reference — writes through the pointer mutate the original local:

```myr
struct Counter { n: int }

function inc(c: ^Counter) {
    c.n += 1
}

function main() {
    let c = Counter{n = 0}
    inc(&c)
    inc(&c)
    inc(&c)
    print(c.n)   // 3
}
```

Use `nil` to represent a null pointer, and compare with `== nil` / `!= nil`:

```myr
struct Node { val: int, next: ^Node }

function main() {
    let n: ^Node = new Node{val = 42, next = nil}
    if n.next == nil {
        print("no next")
    }
}
```

Use `p^` to explicitly copy the pointed-at value onto the stack:

```myr
struct Point { x: int, y: int }

function main() {
    let p: ^Point = new Point{x = 10, y = 20}
    let copy = p^        // copy of the struct; mutations don't affect *p
    copy.x = 999
    print(p.x)           // 10 — unchanged
    print(copy.x)        // 999
}
```

### Recursive structs

Struct fields can reference the struct's own type via a pointer:

```myr
struct Node { val: int, next: ^Node }

function sum_list(n: ^Node) -> int {
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
    print(sum_list(a))   // 6
}
```

### Enums

Enums group a fixed set of named variants. Each variant carries named fields (no positional payloads).

```myr
enum Shape {
    Circle { radius: float },
    Rect   { w: float, h: float },
}
```

Construct a variant with `EnumName.VariantName { field = value, ... }`. Unit variants (no fields) use empty braces.

```myr
enum Direction { North {}, South {}, East {}, West {} }

function main() {
    let s = Shape.Circle { radius = 5.0 }
    let r = Shape.Rect   { w = 10.0, h = 4.0 }
    let d = Direction.North {}
}
```

Enum values can be passed to and returned from functions:

```myr
function largest(a: Shape, b: Shape) -> Shape {
    return a
}
```

### Match

#### Enum variants

`match` dispatches on an enum variant and destructures its named fields into the arm body. Only list the fields you need — unused fields can be omitted.

```myr
enum Shape {
    Circle { radius: int },
    Rect   { w: int, h: int },
}

function area(s: Shape) -> int {
    match s {
        Shape.Circle { radius } => { return radius * radius }
        Shape.Rect   { w, h }  => { return w * h }
    }
    return 0
}
```

#### Scalar literals

`match` works on integers, floats, booleans, and strings:

```myr
function day_name(d: int) -> string {
    match d {
        1 => { return "Monday" }
        2 => { return "Tuesday" }
        3 => { return "Wednesday" }
        _ => { return "other" }
    }
    return ""
}
```

```myr
function is_yes(s: string) -> bool {
    match s {
        "yes" => { return true }
        "y"   => { return true }
        _     => { return false }
    }
    return false
}
```

```myr
function describe_bool(b: bool) -> string {
    match b {
        true  => { return "yes" }
        false => { return "no" }
    }
    return ""
}
```

#### Wildcard arm

`_` matches anything not caught by earlier arms:

```myr
function is_circle(s: Shape) -> bool {
    match s {
        Shape.Circle { radius } => { return true }
        _ => { return false }
    }
    return false
}
```

#### Match as expression

`match` is an expression — the last expression in each arm body is the result value. All arms must produce the same type.

```myr
function area(s: Shape) -> int {
    return match s {
        Shape.Circle { radius } => { radius * radius }
        Shape.Rect   { w, h }  => { w * h }
    }
}
```

Works for scalars too, and can be assigned to a variable:

```myr
function label(n: int) -> string {
    return match n {
        0 => { "zero" }
        1 => { "one" }
        _ => { "many" }
    }
}

function main() {
    let s = Shape.Circle { radius = 5 }
    let a = match s {
        Shape.Circle { radius } => { radius * radius }
        Shape.Rect   { w, h }  => { w * h }
    }
    print(a)
}

### Arrays

`Array[T, N]` is a fixed-size, stack-allocated array. `T` is the element type and `N` is a compile-time integer size.

```myr
function main() {
    let scores = Array[i64, 3]{10, 20, 30}

    print(scores[0])   // 10
    print(scores[1])   // 20

    scores[2] = 99
    print(scores[2])   // 99
}
```

Iterate with a C-style for loop:

```myr
function sum(a: Array[i64, 5]) -> i64 {
    let total = 0
    for let i = 0; i < 5; i += 1 {
        total += a[i]
    }
    return total
}

function main() {
    let nums = Array[i64, 5]{1, 2, 3, 4, 5}
    print(sum(nums))   // 15
}
```

Arrays are value types — they live entirely on the stack, just like structs. There is no heap allocation.

### Generic functions

Functions can be parameterised over one or more type variables using `[T]` syntax. Myr uses monomorphisation — a separate concrete copy is compiled for each distinct combination of argument types.

```myr
function max[T](a: T, b: T) -> T {
    if a > b { return a }
    return b
}

function main() {
    print(max(3, 7))        // 7   — max__int
    print(max(1.5, 2.5))    // 2.5 — max__float
}
```

Multiple type parameters and multiple instantiations in the same program are supported:

```myr
function min[T](a: T, b: T) -> T {
    if a < b { return a }
    return b
}

function clamp[T](val: T, lo: T, hi: T) -> T {
    return max(min(val, hi), lo)
}

function main() {
    print(clamp(15, 0, 10))   // 10
    print(clamp(-5, 0, 10))   // 0
    print(clamp(5, 0, 10))    // 5
}
```

Generic functions can receive and return generic struct types. A function can return `Stack[T]` and the caller gets a fully typed local with correct slot count and field access:

```myr
struct Stack[T] { top: T, size: int }

function make_stack[T](val: T) -> Stack[T] {
    return Stack[T]{top = val, size = 1}
}

function peek[T](s: Stack[T]) -> T {
    return s.top
}

function main() {
    let s = make_stack(42)
    print(s.top)      // 42
    print(s.size)     // 1
    print(peek(s))    // 42
}
```

Generic structs can be nested — `Box[Box[int]]` is fully supported, including field access through all levels, passing to generic functions, and returning from generic functions:

```myr
struct Box[T] { value: T }

function wrap[T](v: T) -> Box[T] {
    return Box[T]{value = v}
}

function unwrap[T](b: Box[T]) -> T {
    return b.value
}

function main() {
    let inner = Box[int]{value = 7}
    let outer = Box[Box[int]]{value = inner}
    print(outer.value.value)       // 7

    let rewrapped = wrap(inner)    // Box[Box[int]]
    print(rewrapped.value.value)   // 7

    let mid = unwrap(outer)        // Box[int]
    print(mid.value)               // 7
}
```

Enums and structs are valid type arguments to generic functions:

```myr
enum Shape { Circle { radius: int }, Rect { w: int, h: int } }

function area[T](s: T) -> int {
    match s {
        Shape.Circle { radius } => { return radius * radius }
        Shape.Rect   { w, h }  => { return w * h }
    }
    return 0
}
```

### First-class functions

Functions are values — store them in variables, pass them as arguments, return them from other functions.

```myr
function double(x: int) -> int { return x * 2 }
function square(x: int) -> int { return x * x }

function apply(f: (int) -> int, x: int) -> int {
    return f(x)
}

function main() {
    print(apply(double, 5))   // 10
    print(apply(square, 5))   // 25

    let f = double
    print(f(7))               // 14
}
```

### Operators

```myr
// Arithmetic
a + b   a - b   a * b   a / b   a % b

// Comparison
a == b   a != b   a < b   a <= b   a > b   a >= b

// Logical
a && b   a || b   !a

// Bitwise (integers)
a & b   a | b   a ^ b   ~a   a << n   a >> n

// Compound assignment
a += b   a -= b   a *= b   a /= b   a %= b
```

## Building from source

Requires the [Odin compiler](https://odin-lang.org/docs/install/).

```sh
./build.sh            # optimised binary → bin/myr
odin test .           # run all tests
odin test ./lexer     # run tests for one package
```

## Status

Phase 1 — bytecode compiler + VM. The pipeline is:

```
source → lex → parse → type-check → compile → VM
```

Working: integers, floats, booleans, strings, arithmetic, comparisons, logical and bitwise operators, compound assignment, if/else, all loop forms (while / infinite / C-style), break, continue, functions, recursion, first-class functions, constants, structs (value semantics, nested), pointers (`^T`, `new`, `nil`, auto-deref, explicit deref `p^`, address-of `&x`), recursive structs, enums with named-field variants, `match` expressions (variant dispatch, field destructuring, wildcard arm, match-as-expression), generic functions (monomorphisation, nested generics, struct/enum params, generic struct return types, nested generic struct types like `Box[Box[int]]`), fixed-size stack arrays (`Array[T, N]`), type checker.

Not yet: closures.

## Examples

See the [`examples/`](examples/) directory.
