# Notes

## TODO
- VM library API (after NativeFn is added and Phase 1 is complete)
- Superinstructions (instruction fusion for common patterns like GET_LOCAL+GET_LOCAL+ADD)

## Optimisation
- Optimise type-checker and name resolution: adopt techniques from existing langs like Rust and Odin
- PRIORITY: Superinstructions (instruction fusion) — fuse GET_LOCAL+GET_LOCAL+ADD/MUL and GET_LOCAL+CONST+LT/LTE/SUB into single opcodes. Implementation exists but caused a perf regression (NOP-padding strategy likely hurts instruction cache). Needs proper benchmarking and alternative approach (e.g. shrink bytecode + fix up jump offsets) before landing.
- PRIORITY: Typed fast-path opcodes — ADD_i64/f64, SUB_i64/f64, MUL_i64/f64, DIV_i64/f64, MOD_i64, LT/LTE/GT/GTE/EQ/NEQ per type (i64, f64, bool, str), NEGATE_i64/f64. Compiler emits these when TC confirms types; VM handlers skip union-tag dispatch. Wire: compile(ast, tcr) threads TypecheckResult into Compiler.types, select_binop picks tightest opcode. Defer until type system is stable.

## Constraints
- No global state in VM — all state lives in the VM struct; multiple instances must be thread-safe without locks
