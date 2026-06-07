# Notes

## TODO
- VM library API (after NativeFn is added and Phase 1 is complete)
- Superinstructions (instruction fusion for common patterns like GET_LOCAL+GET_LOCAL+ADD)

## Optimisation
- Optimise type-checker and name resolution: adopt techniques from existing langs like Rust and Odin

## Constraints
- No global state in VM — all state lives in the VM struct; multiple instances must be thread-safe without locks
