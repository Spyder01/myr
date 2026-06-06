package vm

import bc "../../bytecode"

STACK_MAX  :: 256
FRAMES_MAX :: 64
MAX_INTERN_LEN :: 64

// type aliases so vm.odin can use these without bc. prefix
Value    :: bc.Value
Nil      :: bc.Nil
Function :: bc.Function
Opcode   :: bc.Opcode
