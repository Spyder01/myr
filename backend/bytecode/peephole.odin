package bytecode

import "../../lexer"

// peephole_optimize fuses common instruction sequences into superinstructions,
// recurses into nested functions, then compacts all NOP padding bytes.
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

	// Pre-scan: mark every byte that is a jump target so we never eliminate
	// an instruction that some jump lands on.
	jump_targets := make([]bool, n)
	defer delete(jump_targets)
	{
		j := 0
		for j < n {
			op := Opcode(code[j])
			#partial switch op {
			case .JUMP, .JUMP_IF_FALSE, .JUMP_IF_TRUE, .JUMP_IF_FALSE_POP, .JUMP_IF_TRUE_POP:
				hi     := u16(code[j+1]); lo := u16(code[j+2])
				target := j + 3 + int((hi<<8)|lo)
				if target < n { jump_targets[target] = true }
			case .LOOP:
				hi     := u16(code[j+1]); lo := u16(code[j+2])
				target := j + 3 - int((hi<<8)|lo)
				if target >= 0 { jump_targets[target] = true }
			}
			j += instr_size(code[:], j)
		}
	}

	i    := 0
	for i < n {
		op := Opcode(code[i])

		// ── INC_LOCAL / DEC_LOCAL (CONST variant) ────────────────────────────
		// GET_LOCAL s; CONST c; (ADD|ADD_I64|SUB|SUB_I64); SET_LOCAL s; POP
		// where constants[c].(i64) == 1 and same slot — 8 bytes total
		if op == .GET_LOCAL && i+8 <= n && Opcode(code[i+2]) == .CONST {
			op4 := Opcode(code[i+4])
			if (op4 == .ADD || op4 == .ADD_I64 || op4 == .SUB || op4 == .SUB_I64) &&
			   Opcode(code[i+5]) == .SET_LOCAL &&
			   code[i+1] == code[i+6] &&
			   Opcode(code[i+7]) == .POP {
				c_idx := code[i+3]
				if int(c_idx) < len(chunk.constants) {
					if v, ok2 := chunk.constants[c_idx].(i64); ok2 && v == 1 {
						is_inc := op4 == .ADD || op4 == .ADD_I64
						slot   := code[i+1]
						code[i]   = u8(Opcode.INC_LOCAL if is_inc else Opcode.DEC_LOCAL)
						code[i+1] = slot
						for j in 2..<8 { code[i+j] = u8(Opcode.NOP) }
						i += 8
						continue
					}
				}
			}
		}

		// ── INC_LOCAL / DEC_LOCAL (CONST_LONG variant) ───────────────────────
		// GET_LOCAL s; CONST_LONG hi lo; (ADD|SUB)_I64?; SET_LOCAL s; POP — 9 bytes
		if op == .GET_LOCAL && i+9 <= n && Opcode(code[i+2]) == .CONST_LONG {
			op5 := Opcode(code[i+5])
			if (op5 == .ADD || op5 == .ADD_I64 || op5 == .SUB || op5 == .SUB_I64) &&
			   Opcode(code[i+6]) == .SET_LOCAL &&
			   code[i+1] == code[i+7] &&
			   Opcode(code[i+8]) == .POP {
				hi    := u16(code[i+3]); lo := u16(code[i+4])
				c_idx := (hi << 8) | lo
				if int(c_idx) < len(chunk.constants) {
					if v, ok2 := chunk.constants[c_idx].(i64); ok2 && v == 1 {
						is_inc := op5 == .ADD || op5 == .ADD_I64
						slot   := code[i+1]
						code[i]   = u8(Opcode.INC_LOCAL if is_inc else Opcode.DEC_LOCAL)
						code[i+1] = slot
						for j in 2..<9 { code[i+j] = u8(Opcode.NOP) }
						i += 9
						continue
					}
				}
			}
		}

		// ── GET_LOCAL a; GET_LOCAL b; OP → op_LOCALS a b; NOP; NOP ──────────
		if op == .GET_LOCAL && i+5 <= n && Opcode(code[i+2]) == .GET_LOCAL {
			a   := code[i+1]
			b   := code[i+3]
			op3 := Opcode(code[i+4])
			fused: Maybe(Opcode)
			switch {
			case op3 == .ADD  || op3 == .ADD_I64: fused = .ADD_LOCALS
			case op3 == .MUL  || op3 == .MUL_I64: fused = .MUL_LOCALS
			case op3 == .SUB  || op3 == .SUB_I64: fused = .SUB_LOCALS
			case op3 == .DIV  || op3 == .DIV_I64: fused = .DIV_LOCALS
			case op3 == .MOD  || op3 == .MOD_I64: fused = .MOD_LOCALS
			case op3 == .LT   || op3 == .LT_I64:  fused = .LT_LOCALS
			case op3 == .LTE  || op3 == .LTE_I64: fused = .LTE_LOCALS
			case op3 == .GT   || op3 == .GT_I64:  fused = .GT_LOCALS
			case op3 == .GTE  || op3 == .GTE_I64: fused = .GTE_LOCALS
			}
			if s, ok2 := fused.?; ok2 {
				code[i]   = u8(s)
				code[i+1] = a
				code[i+2] = b
				code[i+3] = u8(Opcode.NOP)
				code[i+4] = u8(Opcode.NOP)
				i += 5
				continue
			}
		}

		// ── GET_LOCAL s; CONST c; OP → op_LOCAL_CONST s 0 c; NOP ─────────────
		if op == .GET_LOCAL && i+5 <= n && Opcode(code[i+2]) == .CONST {
			slot := code[i+1]
			c    := code[i+3]
			op3  := Opcode(code[i+4])
			fused: Maybe(Opcode)
			switch {
			case op3 == .LT  || op3 == .LT_I64:  fused = .LT_LOCAL_CONST
			case op3 == .LTE || op3 == .LTE_I64: fused = .LTE_LOCAL_CONST
			case op3 == .GT  || op3 == .GT_I64:  fused = .GT_LOCAL_CONST
			case op3 == .GTE || op3 == .GTE_I64: fused = .GTE_LOCAL_CONST
			case op3 == .SUB || op3 == .SUB_I64: fused = .SUB_LOCAL_CONST
			case op3 == .EQ:                      fused = .EQ_LOCAL_CONST
			}
			if s, ok2 := fused.?; ok2 {
				code[i]   = u8(s)
				code[i+1] = slot
				code[i+2] = 0
				code[i+3] = c
				code[i+4] = u8(Opcode.NOP)
				i += 5
				continue
			}
		}

		// ── GET_LOCAL s; CONST_LONG hi lo; OP → op_LOCAL_CONST s hi lo; NOP; NOP ─
		if op == .GET_LOCAL && i+6 <= n && Opcode(code[i+2]) == .CONST_LONG {
			slot := code[i+1]
			hi   := code[i+3]
			lo   := code[i+4]
			op3  := Opcode(code[i+5])
			fused: Maybe(Opcode)
			switch {
			case op3 == .LT  || op3 == .LT_I64:  fused = .LT_LOCAL_CONST
			case op3 == .LTE || op3 == .LTE_I64: fused = .LTE_LOCAL_CONST
			case op3 == .GT  || op3 == .GT_I64:  fused = .GT_LOCAL_CONST
			case op3 == .GTE || op3 == .GTE_I64: fused = .GTE_LOCAL_CONST
			case op3 == .SUB || op3 == .SUB_I64: fused = .SUB_LOCAL_CONST
			case op3 == .EQ:                      fused = .EQ_LOCAL_CONST
			}
			if s, ok2 := fused.?; ok2 {
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

		// ── SET_LOCAL s; POP → SET_LOCAL_POP s; NOP ───────────────────────────
		if op == .SET_LOCAL && i+3 <= n && Opcode(code[i+2]) == .POP {
			code[i]   = u8(Opcode.SET_LOCAL_POP)
			code[i+2] = u8(Opcode.NOP)
			i += 3
			continue
		}

		// ── NIL; POP → NOP NOP ─────────────────────────────────────────────────
		// Only when neither byte is a jump target — the NIL may be the else-path
		// result that JUMP_IF_FALSE_POP lands on, which must not be removed.
		if op == .NIL && i+1 < n && Opcode(code[i+1]) == .POP &&
		   !jump_targets[i] && !jump_targets[i+1] {
			code[i]   = u8(Opcode.NOP)
			code[i+1] = u8(Opcode.NOP)
			i += 2
			continue
		}

		// ── Constant folding: CONST a; CONST b; ARITH_OP → CONST result ────────
		// 5 bytes (2+2+1) → 2 bytes + 3 NOPs
		if op == .CONST && i+5 <= n && Opcode(code[i+2]) == .CONST {
			a_idx := int(code[i+1])
			b_idx := int(code[i+3])
			arith := Opcode(code[i+4])
			if a_idx < len(chunk.constants) && b_idx < len(chunk.constants) {
				a, a_ok := chunk.constants[a_idx].(i64)
				b, b_ok := chunk.constants[b_idx].(i64)
				if a_ok && b_ok {
					result: i64; valid := true
					#partial switch arith {
					case .ADD, .ADD_I64: result = a + b
					case .SUB, .SUB_I64: result = a - b
					case .MUL, .MUL_I64: result = a * b
					case .DIV, .DIV_I64: if b == 0 { valid = false } else { result = a / b }
					case .MOD, .MOD_I64: if b == 0 { valid = false } else { result = a % b }
					case: valid = false
					}
					if valid {
						new_idx, err := chunk_add_constant(chunk, result)
						if err == nil {
							if new_idx <= 0xFF {
								code[i]   = u8(Opcode.CONST)
								code[i+1] = u8(new_idx)
								code[i+2] = u8(Opcode.NOP)
								code[i+3] = u8(Opcode.NOP)
								code[i+4] = u8(Opcode.NOP)
							} else {
								code[i]   = u8(Opcode.CONST_LONG)
								code[i+1] = u8(new_idx >> 8)
								code[i+2] = u8(new_idx & 0xFF)
								code[i+3] = u8(Opcode.NOP)
								code[i+4] = u8(Opcode.NOP)
							}
							i += 5
							continue
						}
					}
				}
			}
		}

		// ── GET_LOCAL s; RETURN n → RETURN_LOCAL s n; NOP ──────────────────────
		if op == .GET_LOCAL && i+4 <= n && Opcode(code[i+2]) == .RETURN {
			slot := code[i+1]
			ret_n := code[i+3]
			code[i]   = u8(Opcode.RETURN_LOCAL)
			code[i+1] = slot
			code[i+2] = ret_n
			code[i+3] = u8(Opcode.NOP)
			i += 4
			continue
		}

		// ── CONST c; RETURN n → RETURN_CONST c n; NOP ──────────────────────────
		if op == .CONST && i+4 <= n && Opcode(code[i+2]) == .RETURN {
			c_idx := code[i+1]
			ret_n := code[i+3]
			code[i]   = u8(Opcode.RETURN_CONST)
			code[i+1] = c_idx
			code[i+2] = ret_n
			code[i+3] = u8(Opcode.NOP)
			i += 4
			continue
		}

		i += instr_size(code[:], i)
	}

	compact_nops(chunk)
}

// compact_nops removes all NOP padding bytes produced by the peephole and
// fixes all jump offsets so they remain correct in the compacted code.
@private
compact_nops :: proc(chunk: ^Chunk) {
	code  := &chunk.code
	spans := &chunk.spans
	n     := len(code)

	// bail early if there is nothing to remove
	has_nop := false
	for b in code { if Opcode(b) == .NOP { has_nop = true; break } }
	if !has_nop { return }

	// Pass 1: build old→new and new→old position maps
	old_to_new := make([]int, n + 1)
	defer delete(old_to_new)
	new_to_old := make([]int, n)      // max possible size; actual used = total_new
	defer delete(new_to_old)

	new_pos := 0
	for old in 0..<n {
		if Opcode(code[old]) == .NOP {
			old_to_new[old] = -1      // filled in below
		} else {
			old_to_new[old] = new_pos
			new_to_old[new_pos] = old
			new_pos += 1
		}
	}
	old_to_new[n] = new_pos          // end-of-code sentinel

	// Resolve NOP entries to the next live instruction so that jumps targeting
	// a NOP land correctly after compaction.
	for old := n - 1; old >= 0; old -= 1 {
		if old_to_new[old] == -1 {
			old_to_new[old] = old_to_new[old + 1]
		}
	}

	total_new := new_pos

	// Pass 2: copy non-NOP bytes into fresh arrays
	new_code  := make([dynamic]u8,         0, total_new)
	new_spans := make([dynamic]lexer.Span, 0, total_new)
	for old in 0..<n {
		if Opcode(code[old]) != .NOP {
			append(&new_code,  code[old])
			append(&new_spans, spans[old])
		}
	}

	// Pass 3: fix jump offsets inside new_code using the old code for reading
	// original offset values (new_code still holds old offsets from the copy).
	ni := 0
	for ni < total_new {
		op := Opcode(new_code[ni])
		#partial switch op {
		case .JUMP, .JUMP_IF_FALSE, .JUMP_IF_TRUE, .JUMP_IF_FALSE_POP, .JUMP_IF_TRUE_POP:
			old_pos    := new_to_old[ni]
			old_hi     := u16(code[old_pos + 1])
			old_lo     := u16(code[old_pos + 2])
			old_offset := (old_hi << 8) | old_lo
			// forward jump: ip advances to old_pos+3 then adds offset
			old_target   := old_pos + 3 + int(old_offset)
			new_ip_after := ni + 3
			new_target   := old_to_new[old_target]
			new_offset   := u16(new_target - new_ip_after)
			new_code[ni + 1] = u8(new_offset >> 8)
			new_code[ni + 2] = u8(new_offset & 0xFF)

		case .LOOP:
			old_pos    := new_to_old[ni]
			old_hi     := u16(code[old_pos + 1])
			old_lo     := u16(code[old_pos + 2])
			old_offset := (old_hi << 8) | old_lo
			// backward jump: ip advances to old_pos+3 then subtracts offset
			old_target   := old_pos + 3 - int(old_offset)
			new_ip_after := ni + 3
			new_target   := old_to_new[old_target]
			new_offset   := u16(new_ip_after - new_target)
			new_code[ni + 1] = u8(new_offset >> 8)
			new_code[ni + 2] = u8(new_offset & 0xFF)
		}
		ni += instr_size(new_code[:], ni)
	}

	// Swap chunk's arrays with the compacted versions
	delete(chunk.code)
	delete(chunk.spans)
	chunk.code  = new_code
	chunk.spans = new_spans
}

// instr_size returns the byte width of the instruction at code[pos].
@private
instr_size :: proc(code: []u8, pos: int) -> int {
	if pos >= len(code) do return 1
	#partial switch Opcode(code[pos]) {
	case .CONST, .GET_LOCAL, .SET_LOCAL, .GET_GLOBAL, .SET_GLOBAL, .DEFINE_GLOBAL,
	     .CALL, .RETURN, .NEW, .HEAP_GET, .HEAP_SET, .HEAP_LOAD,
	     .ADDR_LOCAL, .MAKE_SLICE, .SLICE_GET,
	     .INC_LOCAL, .DEC_LOCAL, .SET_LOCAL_POP:
		return 2
	case .CONST_LONG, .JUMP, .JUMP_IF_FALSE, .JUMP_IF_TRUE, .LOOP,
	     .JUMP_IF_FALSE_POP, .JUMP_IF_TRUE_POP,
	     .ADD_LOCALS, .MUL_LOCALS, .SUB_LOCALS, .DIV_LOCALS, .MOD_LOCALS,
	     .LT_LOCALS, .LTE_LOCALS, .GT_LOCALS, .GTE_LOCALS,
	     .ARRAY_GET, .ARRAY_SET, .SLICE_SET,
	     .RETURN_LOCAL, .RETURN_CONST:
		return 3
	case .LT_LOCAL_CONST, .LTE_LOCAL_CONST, .SUB_LOCAL_CONST,
	     .GT_LOCAL_CONST, .GTE_LOCAL_CONST, .EQ_LOCAL_CONST:
		return 4
	}
	return 1
}
