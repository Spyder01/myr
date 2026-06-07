package bytecode

import "core:fmt"

disassemble_chunk :: proc(chunk: ^Chunk, name: string) {
    fmt.printf("=== %s ===\n", name)
    offset := 0
    for offset < int(len(chunk.code)) {
        offset = disassemble_instruction(chunk, offset)
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
    case .GET_GLOBAL:   return const_instruction("GET_GLOBAL", chunk, offset)
    case .SET_GLOBAL:   return const_instruction("SET_GLOBAL", chunk, offset)
    case .DEFINE_GLOBAL: return const_instruction("DEFINE_GLOBAL", chunk, offset)
    case .CALL:         return byte_instruction("CALL", chunk, offset)

    // instructions with two byte operand
    case .CONST_LONG:   return const_long_instruction("CONST_LONG", chunk, offset)
    case .JUMP:         return jump_instruction("JUMP", 1, chunk, offset)
    case .JUMP_IF_FALSE: return jump_instruction("JUMP_IF_FALSE", 1, chunk, offset)
    case .JUMP_IF_TRUE:  return jump_instruction("JUMP_IF_TRUE",  1, chunk, offset)
    case .LOOP:         return jump_instruction("LOOP", -1, chunk, offset)

    case:
        fmt.printf("UNKNOWN opcode %d\n", op)
        return offset + 1
    }
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
    case ^Function: fmt.printf("<fn %s>", v.name)
    }
}
