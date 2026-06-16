package bytecode

import "../../lexer"

// peephole_optimize fuses common instruction sequences into superinstructions,
// recurses into nested functions, then compacts all NOP padding bytes.
peephole_optimize :: proc(module: ^Module) {
	for fn in module.functions {
		if fn != nil { peephole_optimize_chunk(&fn.chunk) }
	}
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
			if (op4 == .ADD_I64 || op4 == .SUB_I64) &&   // typed only; bare op may be float in a generic body
			   Opcode(code[i+5]) == .SET_LOCAL &&
			   code[i+1] == code[i+6] &&
			   Opcode(code[i+7]) == .POP {
				c_idx := code[i+3]
				if int(c_idx) < len(chunk.constants) {
					if v, ok2 := chunk.constants[c_idx].(i64); ok2 && v == 1 {
						is_inc := op4 == .ADD_I64
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
			if (op5 == .ADD_I64 || op5 == .SUB_I64) &&   // typed only; bare op may be float in a generic body
			   Opcode(code[i+6]) == .SET_LOCAL &&
			   code[i+1] == code[i+7] &&
			   Opcode(code[i+8]) == .POP {
				hi    := u16(code[i+3]); lo := u16(code[i+4])
				c_idx := (hi << 8) | lo
				if int(c_idx) < len(chunk.constants) {
					if v, ok2 := chunk.constants[c_idx].(i64); ok2 && v == 1 {
						is_inc := op5 == .ADD_I64
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

		// ── GET_LOCAL a; GET_LOCAL b; MOD_I64; CONST 0; EQ → MOD_LOCAL_LOCAL_EQ_ZERO a b ─
		if op == .GET_LOCAL && i+8 <= n && Opcode(code[i+2]) == .GET_LOCAL &&
		   Opcode(code[i+4]) == .MOD_I64 &&   // typed only; bare .MOD may be float in a generic body
		   Opcode(code[i+5]) == .CONST && Opcode(code[i+7]) == .EQ {
			c_idx := code[i+6]
			if int(c_idx) < len(chunk.constants) {
				if v, ok2 := chunk.constants[c_idx].(i64); ok2 && v == 0 {
					a := code[i+1]
					b := code[i+3]
					// Compare-and-branch: the divisibility test followed by
					// JUMP_IF_FALSE_POP becomes BRANCH_MOD_LL_NZ (branch when a%b != 0).
					// Source spans 11 bytes (the 8-byte test + 3-byte jump).
					if i+11 <= n && Opcode(code[i+8]) == .JUMP_IF_FALSE_POP &&
					   !jump_targets[i+8] && !jump_targets[i+9] && !jump_targets[i+10] {
						orig   := (u16(code[i+9]) << 8) | u16(code[i+10])
						stored := orig + 6   // rebase offset from 11-byte source to 5-byte op end
						code[i]   = u8(Opcode.BRANCH_MOD_LL_NZ)
						code[i+1] = a
						code[i+2] = b
						code[i+3] = u8(stored >> 8)
						code[i+4] = u8(stored & 0xFF)
						for j in 5..<11 { code[i+j] = u8(Opcode.NOP) }
						i += 11
						continue
					}
					code[i]   = u8(Opcode.MOD_LOCAL_LOCAL_EQ_ZERO)
					code[i+1] = a
					code[i+2] = b
					for j in 3..<8 { code[i+j] = u8(Opcode.NOP) }
					i += 8
					continue
				}
			}
		}

		// ── GET_LOCAL a; GET_LOCAL b; OP → op_LOCALS a b; NOP; NOP ──────────
		if op == .GET_LOCAL && i+5 <= n && Opcode(code[i+2]) == .GET_LOCAL {
			a   := code[i+1]
			b   := code[i+3]
			op3 := Opcode(code[i+4])
			// Same-slot squaring: GET_LOCAL s; GET_LOCAL s; MUL → SQUARE s (2 bytes)
			if a == b {
				sq: Maybe(Opcode)
				switch {
				case op3 == .MUL_I64: sq = .SQUARE_I64   // typed only; bare .MUL may be float in a generic body
				case op3 == .MUL_F64: sq = .SQUARE_F64
				}
				if sq_op, ok2 := sq.?; ok2 {
					code[i]   = u8(sq_op)
					code[i+1] = a
					for j in 2..<5 { code[i+j] = u8(Opcode.NOP) }
					i += 5
					continue
				}
			}
			// Only fuse the TYPED i64 ops: the _LOCALS superinstructions assume i64
			// operands, but a bare untyped op (e.g. inside an un-typechecked generic
			// body, which may run on floats) must fall through to the polymorphic
			// dynamic opcode instead.
			fused: Maybe(Opcode)
			#partial switch op3 {
			case .ADD_I64: fused = .ADD_LOCALS
			case .MUL_I64: fused = .MUL_LOCALS
			case .SUB_I64: fused = .SUB_LOCALS
			case .DIV_I64: fused = .DIV_LOCALS
			case .MOD_I64: fused = .MOD_LOCALS
			case .LT_I64:  fused = .LT_LOCALS
			case .LTE_I64: fused = .LTE_LOCALS
			case .GT_I64:  fused = .GT_LOCALS
			case .GTE_I64: fused = .GTE_LOCALS
			}
			// Compare-and-branch: a relational <CMP>_LOCALS immediately followed by
			// JUMP_IF_FALSE_POP collapses into a single BRANCH_<CMP>_LOCALS dispatch.
			// Source spans 8 bytes (GET_LOCAL a; GET_LOCAL b; CMP; JUMP_IF_FALSE_POP).
			if s, ok2 := fused.?; ok2 {
				if br, is_rel := branch_of_locals(s); is_rel && i+8 <= n &&
				   Opcode(code[i+5]) == .JUMP_IF_FALSE_POP &&
				   !jump_targets[i+5] && !jump_targets[i+6] && !jump_targets[i+7] {
					orig   := (u16(code[i+6]) << 8) | u16(code[i+7])
					stored := orig + 3   // rebase offset from 8-byte source to 5-byte op end
					code[i]   = u8(br)
					code[i+1] = a
					code[i+2] = b
					code[i+3] = u8(stored >> 8)
					code[i+4] = u8(stored & 0xFF)
					for j in 5..<8 { code[i+j] = u8(Opcode.NOP) }
					i += 8
					continue
				}
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
			// Typed i64 ops only (these superinstructions assume i64); EQ_LOCAL_CONST
			// is polymorphic so bare .EQ is safe.
			fused: Maybe(Opcode)
			#partial switch op3 {
			case .LT_I64:  fused = .LT_LOCAL_CONST
			case .LTE_I64: fused = .LTE_LOCAL_CONST
			case .GT_I64:  fused = .GT_LOCAL_CONST
			case .GTE_I64: fused = .GTE_LOCAL_CONST
			case .SUB_I64: fused = .SUB_LOCAL_CONST
			case .EQ:      fused = .EQ_LOCAL_CONST
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
			#partial switch op3 {
			case .LT_I64:  fused = .LT_LOCAL_CONST
			case .LTE_I64: fused = .LTE_LOCAL_CONST
			case .GT_I64:  fused = .GT_LOCAL_CONST
			case .GTE_I64: fused = .GTE_LOCAL_CONST
			case .SUB_I64: fused = .SUB_LOCAL_CONST
			case .EQ:      fused = .EQ_LOCAL_CONST
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

		// ── NIL; EQ → NIL_EQ / NIL; NEQ → NIL_NEQ ─────────────────────────────
		// EQ/NEQ must not be a jump target (NIL may be one — NIL_EQ is equivalent).
		if op == .NIL && i+2 <= n && !jump_targets[i+1] {
			next := Opcode(code[i+1])
			fused: Maybe(Opcode)
			#partial switch next {
			case .EQ:  fused = .NIL_EQ
			case .NEQ: fused = .NIL_NEQ
			}
			if f, ok2 := fused.?; ok2 {
				code[i]   = u8(f)
				code[i+1] = u8(Opcode.NOP)
				i += 2
				continue
			}
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
		// Only safe when n == 1 (single-slot scalar return). Multi-slot returns
		// (structs, enums) push several GET_LOCALs before RETURN n; fusing the
		// last GET_LOCAL would discard all but the last slot.
		if op == .GET_LOCAL && i+4 <= n && Opcode(code[i+2]) == .RETURN {
			ret_n := code[i+3]
			if ret_n == 1 {
				slot := code[i+1]
				code[i]   = u8(Opcode.RETURN_LOCAL)
				code[i+1] = slot
				code[i+2] = ret_n
				code[i+3] = u8(Opcode.NOP)
				i += 4
				continue
			}
		}

		// ── CONST c; RETURN n → RETURN_CONST c n; NOP ──────────────────────────
		// Same guard: only fuse for single-slot returns.
		if op == .CONST && i+4 <= n && Opcode(code[i+2]) == .RETURN {
			ret_n := code[i+3]
			if ret_n == 1 {
				c_idx := code[i+1]
				code[i]   = u8(Opcode.RETURN_CONST)
				code[i+1] = c_idx
				code[i+2] = ret_n
				code[i+3] = u8(Opcode.NOP)
				i += 4
				continue
			}
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

	// bail early if there is nothing to remove.
	// Scan instruction-by-instruction: an operand byte that happens to equal
	// NOP's opcode value must NOT be mistaken for a real NOP instruction.
	has_nop := false
	{
		j := 0
		for j < n {
			if Opcode(code[j]) == .NOP { has_nop = true; break }
			j += instr_size(code[:], j)
		}
	}
	if !has_nop { return }

	// Pass 1: build old→new and new→old position maps.
	// Instruction-level scan: all bytes of a multi-byte instruction are mapped
	// as a unit, preventing operand bytes from being misidentified as NOPs.
	old_to_new := make([]int, n + 1)
	defer delete(old_to_new)
	new_to_old := make([]int, n)      // max possible size; actual used = total_new
	defer delete(new_to_old)

	new_pos := 0
	{
		old := 0
		for old < n {
			sz := instr_size(code[:], old)
			if Opcode(code[old]) == .NOP {
				old_to_new[old] = -1  // filled in by backward resolve below
			} else {
				for k in 0..<sz {
					old_to_new[old + k] = new_pos + k
					new_to_old[new_pos + k] = old + k
				}
				new_pos += sz
			}
			old += sz
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

	// Pass 2: copy non-NOP instructions into fresh arrays (instruction-level).
	new_code  := make([dynamic]u8,         0, total_new)
	new_spans := make([dynamic]lexer.Span, 0, total_new)
	{
		old := 0
		for old < n {
			sz := instr_size(code[:], old)
			if Opcode(code[old]) != .NOP {
				for k in 0..<sz {
					append(&new_code,  code[old + k])
					append(&new_spans, spans[old + k])
				}
			}
			old += sz
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

		case .BRANCH_LT_LOCALS, .BRANCH_LTE_LOCALS, .BRANCH_GT_LOCALS,
		     .BRANCH_GTE_LOCALS, .BRANCH_MOD_LL_NZ:
			// 5-byte op (a b hi lo); forward offset stored relative to the op's end,
			// so the target is uniformly old_pos + 5 + offset.
			old_pos    := new_to_old[ni]
			old_hi     := u16(code[old_pos + 3])
			old_lo     := u16(code[old_pos + 4])
			old_offset := (old_hi << 8) | old_lo
			old_target   := old_pos + 5 + int(old_offset)
			new_ip_after := ni + 5
			new_target   := old_to_new[old_target]
			new_offset   := u16(new_target - new_ip_after)
			new_code[ni + 3] = u8(new_offset >> 8)
			new_code[ni + 4] = u8(new_offset & 0xFF)
		}
		ni += instr_size(new_code[:], ni)
	}

	// Swap chunk's arrays with the compacted versions
	delete(chunk.code)
	delete(chunk.spans)
	chunk.code  = new_code
	chunk.spans = new_spans
}

// branch_of_locals maps a relational <CMP>_LOCALS opcode to its fused
// compare-and-branch form, or returns ok=false for non-relational ops.
@private
branch_of_locals :: proc(op: Opcode) -> (Opcode, bool) {
	#partial switch op {
	case .LT_LOCALS:  return .BRANCH_LT_LOCALS,  true
	case .LTE_LOCALS: return .BRANCH_LTE_LOCALS, true
	case .GT_LOCALS:  return .BRANCH_GT_LOCALS,  true
	case .GTE_LOCALS: return .BRANCH_GTE_LOCALS, true
	}
	return .NOP, false
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
	     .ARRAY_GET, .ARRAY_SET, .ARRAY_GET_STACK, .SLICE_SET,
	     .RETURN_LOCAL, .RETURN_CONST,
	     .MOD_LOCAL_LOCAL_EQ_ZERO,
	     .LOAD_FN,
	     .CALL_NATIVE:
		return 3
	case .SLICE_GET_STACK:
		return 2
	case .SQUARE_I64, .SQUARE_F64:
		return 2
	case .LT_LOCAL_CONST, .LTE_LOCAL_CONST, .SUB_LOCAL_CONST,
	     .GT_LOCAL_CONST, .GTE_LOCAL_CONST, .EQ_LOCAL_CONST,
	     .ARRAY_SET_CHAINED:
		return 4
	case .BRANCH_LT_LOCALS, .BRANCH_LTE_LOCALS, .BRANCH_GT_LOCALS,
	     .BRANCH_GTE_LOCALS, .BRANCH_MOD_LL_NZ:
		return 5  // op a b hi lo
	}
	return 1
}
