package bytecode

import "core:fmt"

disassemble_chunk :: proc(chunk: ^Chunk, name: string) {
    fmt.printf("=== %s ===\n", name)
    offset := 0
    for offset < int(len(chunk.code)) {
        offset = disassemble_instruction(chunk, offset)
    }
}

// disassemble_all disassembles every function in the module's flat table.
disassemble_all :: proc(module: ^Module) {
    for fn, i in module.functions {
        if fn == nil { continue }
        disassemble_chunk(&fn.chunk, fn.name)
        if i < len(module.functions) - 1 { fmt.println() }
    }
}

disassemble_instruction :: proc(chunk: ^Chunk, offset: int) -> int {
    // print byte offset (address)
    fmt.printf("%04d ", offset)

    // print source line info
    if offset > 0 && chunk.spans[offset].start == chunk.spans[offset - 1].start {
        fmt.printf("   | ")  // same line as previous instruction
    } else {
        fmt.printf("%4d ", chunk.spans[offset].start)
    }

    op := Opcode(chunk.code[offset])
    switch op {
    // simple instructions (no operands)
    case .ADD:          return simple_instruction("ADD", offset)
    case .SUB:          return simple_instruction("SUB", offset)
    case .MUL:          return simple_instruction("MUL", offset)
    case .DIV:          return simple_instruction("DIV", offset)
    case .NEGATE:       return simple_instruction("NEGATE", offset)
    case .NOT:          return simple_instruction("NOT", offset)
    case .NIL:          return simple_instruction("NIL", offset)
    case .TRUE:         return simple_instruction("TRUE", offset)
    case .FALSE:        return simple_instruction("FALSE", offset)
    case .POP:          return simple_instruction("POP", offset)
    case .RETURN:       return byte_instruction("RETURN", chunk, offset)
    case .PRINT:        return simple_instruction("PRINT", offset)
    case .INPUT:        return simple_instruction("INPUT", offset)
    case .EQ:           return simple_instruction("EQ", offset)
    case .NEQ:          return simple_instruction("NEQ", offset)
    case .LT:           return simple_instruction("LT", offset)
    case .LTE:          return simple_instruction("LTE", offset)
    case .GT:           return simple_instruction("GT", offset)
    case .GTE:          return simple_instruction("GTE", offset)
    case .MOD:          return simple_instruction("MOD", offset)
    case .SHL:          return simple_instruction("SHL",  offset)
    case .SHR:          return simple_instruction("SHR",  offset)
    case .BAND:         return simple_instruction("BAND", offset)
    case .BOR:          return simple_instruction("BOR",  offset)
    case .BXOR:         return simple_instruction("BXOR", offset)
    case .BNOT:         return simple_instruction("BNOT", offset)

    // instructions with one byte operand
    case .CONST:        return const_instruction("CONST", chunk, offset)
    case .GET_LOCAL:    return byte_instruction("GET_LOCAL", chunk, offset)
    case .SET_LOCAL:    return byte_instruction("SET_LOCAL", chunk, offset)
    case .GET_GLOBAL:    return byte_instruction("GET_GLOBAL",    chunk, offset)
    case .SET_GLOBAL:    return byte_instruction("SET_GLOBAL",    chunk, offset)
    case .DEFINE_GLOBAL: return byte_instruction("DEFINE_GLOBAL", chunk, offset)
    case .CALL:         return byte_instruction("CALL", chunk, offset)
    case .NEW:          return byte_instruction("NEW",       chunk, offset)
    case .HEAP_GET:     return byte_instruction("HEAP_GET",  chunk, offset)
    case .HEAP_SET:     return byte_instruction("HEAP_SET",  chunk, offset)
    case .HEAP_LOAD:    return byte_instruction("HEAP_LOAD", chunk, offset)

    // instructions with two byte operand
    case .CONST_LONG:   return const_long_instruction("CONST_LONG", chunk, offset)
    case .JUMP:         return jump_instruction("JUMP", 1, chunk, offset)
    case .JUMP_IF_FALSE: return jump_instruction("JUMP_IF_FALSE", 1, chunk, offset)
    case .JUMP_IF_TRUE:  return jump_instruction("JUMP_IF_TRUE",  1, chunk, offset)
    case .LOOP:         return jump_instruction("LOOP", -1, chunk, offset)

    case .NOP:          return simple_instruction("NOP",          offset)
    case .STR_LEN:      return simple_instruction("STR_LEN",      offset)
    case .STR_GET:      return simple_instruction("STR_GET",      offset)
    case .ADDR_LOCAL:   return byte_instruction("ADDR_LOCAL",     chunk, offset)
    case .MAKE_SLICE:   return byte_instruction("MAKE_SLICE",     chunk, offset)
    case .SLICE_GET:    return byte_instruction("SLICE_GET",      chunk, offset)
    case .ARRAY_GET:       return two_byte_instruction("ARRAY_GET",       chunk, offset)
    case .ARRAY_SET:       return two_byte_instruction("ARRAY_SET",       chunk, offset)
    case .ARRAY_GET_STACK:   return two_byte_instruction("ARRAY_GET_STACK",   chunk, offset)
    case .ARRAY_SET_CHAINED: return three_byte_instruction("ARRAY_SET_CHAINED", chunk, offset)
    case .SLICE_SET:         return two_byte_instruction("SLICE_SET",           chunk, offset)
    case .SLICE_GET_STACK: return byte_instruction("SLICE_GET_STACK",     chunk, offset)

    // Superinstructions — _LOCALS (3 bytes: opcode a b)
    case .ADD_LOCALS:   return two_byte_instruction("ADD_LOCALS",   chunk, offset)
    case .MUL_LOCALS:   return two_byte_instruction("MUL_LOCALS",   chunk, offset)
    case .SUB_LOCALS:   return two_byte_instruction("SUB_LOCALS",   chunk, offset)
    case .DIV_LOCALS:   return two_byte_instruction("DIV_LOCALS",   chunk, offset)
    case .MOD_LOCALS:   return two_byte_instruction("MOD_LOCALS",   chunk, offset)
    case .LT_LOCALS:    return two_byte_instruction("LT_LOCALS",    chunk, offset)
    case .LTE_LOCALS:   return two_byte_instruction("LTE_LOCALS",   chunk, offset)
    case .GT_LOCALS:    return two_byte_instruction("GT_LOCALS",    chunk, offset)
    case .GTE_LOCALS:   return two_byte_instruction("GTE_LOCALS",   chunk, offset)
    // _LOCAL_CONST (4 bytes: opcode slot hi lo)
    case .LT_LOCAL_CONST:   return three_byte_instruction("LT_LOCAL_CONST",   chunk, offset)
    case .LTE_LOCAL_CONST:  return three_byte_instruction("LTE_LOCAL_CONST",  chunk, offset)
    case .GT_LOCAL_CONST:   return three_byte_instruction("GT_LOCAL_CONST",   chunk, offset)
    case .GTE_LOCAL_CONST:  return three_byte_instruction("GTE_LOCAL_CONST",  chunk, offset)
    case .SUB_LOCAL_CONST:  return three_byte_instruction("SUB_LOCAL_CONST",  chunk, offset)
    case .EQ_LOCAL_CONST:   return three_byte_instruction("EQ_LOCAL_CONST",   chunk, offset)
    // INC/DEC (2 bytes: opcode slot)
    case .INC_LOCAL:    return byte_instruction("INC_LOCAL",   chunk, offset)
    case .DEC_LOCAL:    return byte_instruction("DEC_LOCAL",   chunk, offset)
    // Conditional-jump-and-pop (3 bytes: opcode hi lo)
    case .JUMP_IF_FALSE_POP: return jump_instruction("JUMP_IF_FALSE_POP", 1, chunk, offset)
    case .JUMP_IF_TRUE_POP:  return jump_instruction("JUMP_IF_TRUE_POP",  1, chunk, offset)
    // SET_LOCAL_POP (2 bytes: opcode slot)
    case .SET_LOCAL_POP: return byte_instruction("SET_LOCAL_POP", chunk, offset)
    // LOAD_FN (3 bytes: opcode hi lo) — push FnRef(idx) onto the stack
    case .LOAD_FN:
        hi  := u16(chunk.code[offset+1]) << 8
        lo  := u16(chunk.code[offset+2])
        idx := hi | lo
        fmt.printf("%-16s %4d\n", "LOAD_FN", idx)
        return offset + 3
    // RETURN_LOCAL (3 bytes: opcode slot n), RETURN_CONST (3 bytes: opcode const_idx n)
    case .RETURN_LOCAL:  return two_byte_instruction("RETURN_LOCAL",  chunk, offset)
    case .RETURN_CONST:  return const_return_instruction("RETURN_CONST", chunk, offset)
    // MOD_LOCAL_LOCAL_EQ_ZERO (3 bytes: opcode slot_a slot_b)
    case .MOD_LOCAL_LOCAL_EQ_ZERO: return two_byte_instruction("MOD_LL_EQ_ZERO", chunk, offset)
    // SQUARE_I64 / SQUARE_F64 (2 bytes: opcode slot)
    case .SQUARE_I64: return byte_instruction("SQUARE_I64", chunk, offset)
    case .SQUARE_F64: return byte_instruction("SQUARE_F64", chunk, offset)
    // NIL_EQ / NIL_NEQ (1 byte: opcode only)
    case .NIL_EQ:  return simple_instruction("NIL_EQ",  offset)
    case .NIL_NEQ: return simple_instruction("NIL_NEQ", offset)

    // Type-specific arithmetic
    case .ADD_I64:      return simple_instruction("ADD_I64",    offset)
    case .SUB_I64:      return simple_instruction("SUB_I64",    offset)
    case .MUL_I64:      return simple_instruction("MUL_I64",    offset)
    case .DIV_I64:      return simple_instruction("DIV_I64",    offset)
    case .MOD_I64:      return simple_instruction("MOD_I64",    offset)
    case .ADD_F64:      return simple_instruction("ADD_F64",    offset)
    case .SUB_F64:      return simple_instruction("SUB_F64",    offset)
    case .MUL_F64:      return simple_instruction("MUL_F64",    offset)
    case .DIV_F64:      return simple_instruction("DIV_F64",    offset)
    case .ADD_STR:      return simple_instruction("ADD_STR",    offset)
    case .LT_I64:       return simple_instruction("LT_I64",     offset)
    case .LTE_I64:      return simple_instruction("LTE_I64",    offset)
    case .GT_I64:       return simple_instruction("GT_I64",     offset)
    case .GTE_I64:      return simple_instruction("GTE_I64",    offset)
    case .LT_F64:       return simple_instruction("LT_F64",     offset)
    case .LTE_F64:      return simple_instruction("LTE_F64",    offset)
    case .GT_F64:       return simple_instruction("GT_F64",     offset)
    case .GTE_F64:      return simple_instruction("GTE_F64",    offset)
    case .NEGATE_I64:   return simple_instruction("NEGATE_I64", offset)
    case .NEGATE_F64:   return simple_instruction("NEGATE_F64", offset)
    }
    return offset + 1
}

// no operands — just print name, advance by 1
simple_instruction :: proc(name: string, offset: int) -> int {
    fmt.printf("%s\n", name)
    return offset + 1
}

// one byte operand — print name + raw byte value
byte_instruction :: proc(name: string, chunk: ^Chunk, offset: int) -> int {
    slot := chunk.code[offset + 1]
    fmt.printf("%-16s %4d\n", name, slot)
    return offset + 2
}

// one byte operand — print name + constant index + constant value
const_instruction :: proc(name: string, chunk: ^Chunk, offset: int) -> int {
    idx := chunk.code[offset + 1]
    fmt.printf("%-16s %4d '", name, idx)
    print_value(chunk.constants[idx])
    fmt.printf("'\n")
    return offset + 2
}

// two byte operand — print name + constant index + constant value
const_long_instruction :: proc(name: string, chunk: ^Chunk, offset: int) -> int {
    hi  := u16(chunk.code[offset + 1]) << 8
    lo  := u16(chunk.code[offset + 2])
    idx := hi | lo
    fmt.printf("%-16s %4d '", name, idx)
    print_value(chunk.constants[idx])
    fmt.printf("'\n")
    return offset + 3
}

// two byte operands — print name + both raw bytes
two_byte_instruction :: proc(name: string, chunk: ^Chunk, offset: int) -> int {
    a := chunk.code[offset + 1]
    b := chunk.code[offset + 2]
    fmt.printf("%-16s %4d %4d\n", name, a, b)
    return offset + 3
}

// three byte operands — print name + slot + constant index (hi<<8|lo)
three_byte_instruction :: proc(name: string, chunk: ^Chunk, offset: int) -> int {
    slot := chunk.code[offset + 1]
    hi   := u16(chunk.code[offset + 2])
    lo   := u16(chunk.code[offset + 3])
    idx  := (hi << 8) | lo
    fmt.printf("%-16s %4d %4d '", name, slot, idx)
    print_value(chunk.constants[idx])
    fmt.printf("'\n")
    return offset + 4
}

// RETURN_CONST: opcode + const_idx + n
const_return_instruction :: proc(name: string, chunk: ^Chunk, offset: int) -> int {
    idx := chunk.code[offset + 1]
    n   := chunk.code[offset + 2]
    fmt.printf("%-16s %4d '", name, n)
    print_value(chunk.constants[idx])
    fmt.printf("'\n")
    return offset + 3
}

// jump instructions — print name + offset + resolved target address
jump_instruction :: proc(name: string, sign: int, chunk: ^Chunk, offset: int) -> int {
    hi     := u16(chunk.code[offset + 1]) << 8
    lo     := u16(chunk.code[offset + 2])
    jump   := u16(hi | lo)
    target := offset + 3 + sign * int(jump)  // sign=1 forward, sign=-1 backward
    fmt.printf("%-16s %4d -> %d\n", name, jump, target)
    return offset + 3
}

print_value :: proc(val: Value) {
    switch v in val {
    case i64:       fmt.printf("%d", v)
    case f64:       fmt.printf("%g", v)
    case bool:      fmt.printf("%t", v)
    case string:    fmt.printf("\"%s\"", v)
    case Nil:       fmt.printf("nil")
    case FnRef:     fmt.printf("<fn#%d>", int(v))
    case [^]Value:
        if v == nil { fmt.printf("nil") } else { fmt.printf("<ptr>") }
    }
}
