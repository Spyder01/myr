# Myr

A language designed around simplicity and control.

Algebraic types and FP ergonomics without a borrow checker. No hidden costs, no magic — you see what the program does and you decide how it does it. Implemented in [Odin](https://odin-lang.org).

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
myr dump  <file>          show bytecode disassembly
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

### Variables and loops

```myr
function main() {
    let i = 0
    for i < 10 {
        print(i)
        i = i + 1
    }
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
        i = i + 1
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
for let i = 0; i < n; i = i + 1 { }
```

### Recursion

```myr
function fib(n: int) -> int {
    if n <= 1 { return n }
    return fib(n - 1) + fib(n - 2)
}
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
source → lex → parse → compile → VM
```

Working: integers, floats, booleans, strings, arithmetic, comparisons, if/else, all loop forms (while / infinite / C-style), break, continue, functions, recursion, lexical scoping, closures.

Not yet: structs, enums, algebraic types, pattern matching, type checker, generics.

## Examples

See the [`examples/`](examples/) directory.
