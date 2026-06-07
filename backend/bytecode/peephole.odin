package bytecode

// peephole_optimize fuses common instruction sequences into superinstructions,
// recursing into nested functions stored as constants first.
peephole_optimize :: proc(fn: ^Function) {
	for val in fn.chunk.constants {
		if nested, ok := val.(^Function); ok {
			peephole_optimize(nested)
		}
	}
	peephole_optimize_chunk(&fn.chunk)
}

@private
peephole_optimize_chunk :: proc(chunk: ^Chunk) {
	code := &chunk.code
	n    := len(code)
	i    := 0
	for i < n {
		op := Opcode(code[i])

		// GET_LOCAL a; GET_LOCAL b; (ADD|MUL) → superinstr a b; NOP; NOP
		if op == .GET_LOCAL && i+5 <= n && Opcode(code[i+2]) == .GET_LOCAL {
			a   := code[i+1]
			b   := code[i+3]
			op3 := Opcode(code[i+4])
			fused: Maybe(Opcode)
			#partial switch op3 {
			case .ADD: fused = .ADD_LOCALS
			case .MUL: fused = .MUL_LOCALS
			}
			if s, ok := fused.?; ok {
				code[i]   = u8(s)
				code[i+1] = a
				code[i+2] = b
				code[i+3] = u8(Opcode.NOP)
				code[i+4] = u8(Opcode.NOP)
				i += 5
				continue
			}
		}

		// GET_LOCAL s; CONST c; (LT|LTE|SUB) → superinstr s 0 c; NOP
		if op == .GET_LOCAL && i+5 <= n && Opcode(code[i+2]) == .CONST {
			slot := code[i+1]
			c    := code[i+3]
			op3  := Opcode(code[i+4])
			fused: Maybe(Opcode)
			#partial switch op3 {
			case .LT:  fused = .LT_LOCAL_CONST
			case .LTE: fused = .LTE_LOCAL_CONST
			case .SUB: fused = .SUB_LOCAL_CONST
			}
			if s, ok := fused.?; ok {
				code[i]   = u8(s)
				code[i+1] = slot
				code[i+2] = 0
				code[i+3] = c
				code[i+4] = u8(Opcode.NOP)
				i += 5
				continue
			}
		}

		// GET_LOCAL s; CONST_LONG hi lo; (LT|LTE|SUB) → superinstr s hi lo; NOP; NOP
		if op == .GET_LOCAL && i+6 <= n && Opcode(code[i+2]) == .CONST_LONG {
			slot := code[i+1]
			hi   := code[i+3]
			lo   := code[i+4]
			op3  := Opcode(code[i+5])
			fused: Maybe(Opcode)
			#partial switch op3 {
			case .LT:  fused = .LT_LOCAL_CONST
			case .LTE: fused = .LTE_LOCAL_CONST
			case .SUB: fused = .SUB_LOCAL_CONST
			}
			if s, ok := fused.?; ok {
				code[i]   = u8(s)
				code[i+1] = slot
				code[i+2] = hi
				code[i+3] = lo
				code[i+4] = u8(Opcode.NOP)
				code[i+5] = u8(Opcode.NOP)
				i += 6
				continue
			}
		}

		i += instr_size(code[:], i)
	}
}

// instr_size returns the byte width of the instruction at code[pos].
@private
instr_size :: proc(code: []u8, pos: int) -> int {
	if pos >= len(code) do return 1
	#partial switch Opcode(code[pos]) {
	case .CONST, .GET_LOCAL, .SET_LOCAL, .GET_GLOBAL, .SET_GLOBAL, .DEFINE_GLOBAL,
	     .CALL, .RETURN, .NEW, .HEAP_GET, .HEAP_SET, .HEAP_LOAD:
		return 2
	case .CONST_LONG, .JUMP, .JUMP_IF_FALSE, .JUMP_IF_TRUE, .LOOP:
		return 3
	case .ADD_LOCALS, .MUL_LOCALS:
		return 3
	case .LT_LOCAL_CONST, .LTE_LOCAL_CONST, .SUB_LOCAL_CONST:
		return 4
	}
	return 1
}
