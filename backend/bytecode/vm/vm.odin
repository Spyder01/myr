package vm

import bc "../../bytecode"
import "core:fmt"
import "core:strings"
import "core:os"
import "core:io"

CallFrame :: struct {
	ip:       int,
	function: ^Function,
	slots:    u16,
}

VM :: struct {
	frames:       [FRAMES_MAX]CallFrame,
	stack:        [STACK_MAX]Value,
	globals:      [256]Value,
	strings:      StringPool,
	heap_objects: [dynamic][]Value,
	char_cache:   [256]string,
	functions:    []^Function,  // function table set by vm_interpret; indexed by FnRef
	stack_top:    u16,
	frame_count:  u8,
	stdin:        io.Reader,
}

VMError :: enum {
	STACK_OVERFLOW,
	STACK_UNDERFLOW,
	TYPE_ERROR,
	UNDEFINED_VARIABLE,
	WRONG_ARG_COUNT,
	CALL_NON_FUNCTION,
	DIVISION_BY_ZERO,
	NULL_DEREF,
	INDEX_OUT_OF_BOUNDS,
}

new_vm :: proc(max_globals: Maybe(int) = nil) -> VM {
	vm: VM
	vm.strings      = string_pool_new()
	vm.heap_objects = make([dynamic][]Value)
	for i in 0..<256 {
		buf    := make([]byte, 1)
		buf[0]  = byte(i)
		vm.char_cache[i] = string(buf)
	}
	return vm
}

destroy_vm :: proc(vm: ^VM) {
	string_pool_destroy(&vm.strings)
	for obj in vm.heap_objects { delete(obj) }
	delete(vm.heap_objects)
	for s in vm.char_cache { delete(s) }
}

vm_push :: #force_inline proc "contextless" (vm: ^VM, val: Value) -> Maybe(VMError) {
	if vm.stack_top >= STACK_MAX do return .STACK_OVERFLOW
	vm.stack[vm.stack_top] = val
	vm.stack_top += 1
	return nil
}

vm_pop :: #force_inline proc "contextless" (vm: ^VM) -> (Value, Maybe(VMError)) {
	if vm.stack_top == 0 do return Nil{}, .STACK_UNDERFLOW
	vm.stack_top -= 1
	return vm.stack[vm.stack_top], nil
}

vm_peek :: #force_inline proc "contextless" (vm: ^VM, dist: u16 = 0) -> (Value, Maybe(VMError)) {
	if vm.stack_top == 0 || dist >= vm.stack_top do return Nil{}, .STACK_UNDERFLOW
	return vm.stack[vm.stack_top - 1 - dist], nil
}

current_frame :: #force_inline proc "contextless" (vm: ^VM) -> ^CallFrame {
	return &vm.frames[vm.frame_count - 1]
}

read_byte :: #force_inline proc "contextless" (frame: ^CallFrame) -> u8 {
	b := frame.function.chunk.code[frame.ip]
	frame.ip += 1
	return b
}

read_short :: #force_inline proc "contextless" (frame: ^CallFrame) -> u16 {
	hi := u16(read_byte(frame)) << 8
	lo := u16(read_byte(frame))
	return hi | lo
}

read_constant :: #force_inline proc "contextless" (frame: ^CallFrame) -> Value {
	idx := read_byte(frame)
	return frame.function.chunk.constants[idx]
}

read_constant_long :: #force_inline proc "contextless" (frame: ^CallFrame) -> Value {
	idx := read_short(frame)
	return frame.function.chunk.constants[idx]
}

vm_run :: proc(vm: ^VM) -> Maybe(VMError) {
	frame := current_frame(vm)
	sp    := vm.stack_top        // cached stack pointer — only written back at CALL / final RETURN
	for {
		op := Opcode(read_byte(frame))
		#partial switch op {

		case .CONST:
			val := read_constant(frame)
			if s, ok := val.(string); ok { val = string_pool_intern(&vm.strings, s) }
			vm.stack[sp] = val; sp += 1

		case .CONST_LONG:
			val := read_constant_long(frame)
			if s, ok := val.(string); ok { val = string_pool_intern(&vm.strings, s) }
			vm.stack[sp] = val; sp += 1

		case .LOAD_FN:
			hi  := u16(read_byte(frame)); lo := u16(read_byte(frame))
			vm.stack[sp] = FnRef((hi << 8) | lo); sp += 1

		case .NIL:   vm.stack[sp] = Nil{}; sp += 1
		case .TRUE:  vm.stack[sp] = true;  sp += 1
		case .FALSE: vm.stack[sp] = false; sp += 1

		case .ADD:
			b := vm.stack[sp-1]; sp -= 1
			#partial switch av in vm.stack[sp-1] {
			case i64:
				bv, ok := b.(i64); if !ok do return .TYPE_ERROR
				vm.stack[sp-1] = av + bv
			case f64:
				bv, ok := b.(f64); if !ok do return .TYPE_ERROR
				vm.stack[sp-1] = av + bv
			case string:
				bv, ok := b.(string); if !ok do return .TYPE_ERROR
				tmp := strings.concatenate({av, bv})
				interned := string_pool_intern(&vm.strings, tmp)
				if raw_data(tmp) != raw_data(interned) { delete(tmp) }
				vm.stack[sp-1] = interned
			case: return .TYPE_ERROR
			}

		case .SUB:  vm.stack_top = sp; if err := vm_binary_op(vm, .SUB);  err != nil do return err; sp = vm.stack_top
		case .MUL:  vm.stack_top = sp; if err := vm_binary_op(vm, .MUL);  err != nil do return err; sp = vm.stack_top
		case .DIV:  vm.stack_top = sp; if err := vm_binary_op(vm, .DIV);  err != nil do return err; sp = vm.stack_top
		case .MOD:  vm.stack_top = sp; if err := vm_binary_op(vm, .MOD);  err != nil do return err; sp = vm.stack_top
		case .SHL:  vm.stack_top = sp; if err := vm_binary_op(vm, .SHL);  err != nil do return err; sp = vm.stack_top
		case .SHR:  vm.stack_top = sp; if err := vm_binary_op(vm, .SHR);  err != nil do return err; sp = vm.stack_top
		case .BAND: vm.stack_top = sp; if err := vm_binary_op(vm, .BAND); err != nil do return err; sp = vm.stack_top
		case .BOR:  vm.stack_top = sp; if err := vm_binary_op(vm, .BOR);  err != nil do return err; sp = vm.stack_top
		case .BXOR: vm.stack_top = sp; if err := vm_binary_op(vm, .BXOR); err != nil do return err; sp = vm.stack_top

		case .BNOT:
			av, ok := vm.stack[sp-1].(i64); if !ok do return .TYPE_ERROR
			vm.stack[sp-1] = ~av

		case .NEGATE:
			#partial switch av in vm.stack[sp-1] {
			case i64: vm.stack[sp-1] = -av
			case f64: vm.stack[sp-1] = -av
			case:     return .TYPE_ERROR
			}

		case .EQ:
			b := vm.stack[sp-1]; sp -= 1
			vm.stack[sp-1] = vm_values_equal(vm.stack[sp-1], b)

		case .NEQ:
			b := vm.stack[sp-1]; sp -= 1
			vm.stack[sp-1] = !vm_values_equal(vm.stack[sp-1], b)

		case .LT:  vm.stack_top = sp; if err := vm_compare(vm, .LT);  err != nil do return err; sp = vm.stack_top
		case .LTE: vm.stack_top = sp; if err := vm_compare(vm, .LTE); err != nil do return err; sp = vm.stack_top
		case .GT:  vm.stack_top = sp; if err := vm_compare(vm, .GT);  err != nil do return err; sp = vm.stack_top
		case .GTE: vm.stack_top = sp; if err := vm_compare(vm, .GTE); err != nil do return err; sp = vm.stack_top

		case .NOT:
			vm.stack[sp-1] = is_falsy(vm.stack[sp-1])

		case .POP:
			sp -= 1

		case .PRINT:
			sp -= 1; print_value(vm.stack[sp]); fmt.println()

		case .INPUT:
			prompt := vm.stack[sp-1]; sp -= 1
			if s, ok := prompt.(string); ok && len(s) > 0 { fmt.printf("%s", s) }
			tmp := read_line(vm.stdin)
			interned := string_pool_intern(&vm.strings, tmp)
			if raw_data(tmp) != raw_data(interned) { delete(tmp) }
			vm.stack[sp] = interned; sp += 1

		case .DEFINE_GLOBAL:
			slot := read_byte(frame)
			vm.globals[slot] = vm.stack[sp-1]; sp -= 1

		case .GET_GLOBAL:
			slot := read_byte(frame)
			vm.stack[sp] = vm.globals[slot]; sp += 1

		case .SET_GLOBAL:
			slot := read_byte(frame)
			vm.globals[slot] = vm.stack[sp-1]

		case .GET_LOCAL:
			slot := u16(read_byte(frame))
			vm.stack[sp] = vm.stack[frame.slots + slot]; sp += 1

		case .SET_LOCAL:
			slot := u16(read_byte(frame))
			vm.stack[frame.slots + slot] = vm.stack[sp-1]

		case .JUMP:
			frame.ip += int(read_short(frame))

		case .JUMP_IF_FALSE:
			offset := read_short(frame)
			if is_falsy(vm.stack[sp-1]) { frame.ip += int(offset) }

		case .JUMP_IF_TRUE:
			offset := read_short(frame)
			if !is_falsy(vm.stack[sp-1]) { frame.ip += int(offset) }

		case .LOOP:
			frame.ip -= int(read_short(frame))

		case .CALL:
			arg_count := u16(read_byte(frame))
			vm.stack_top = sp
			if err := vm_call(vm, arg_count); err != nil do return err
			frame = current_frame(vm)
			sp = vm.stack_top

		case .ADDR_LOCAL:
			slot := int(read_byte(frame))
			ptr: [^]Value = raw_data(vm.stack[frame.slots + u16(slot):])
			vm.stack[sp] = ptr; sp += 1

		case .ARRAY_GET:
			base_slot  := u16(read_byte(frame))
			elem_slots := int(read_byte(frame))
			i, ok := vm.stack[sp-1].(i64); if !ok do return .TYPE_ERROR
			sp -= 1
			for s in 0..<elem_slots {
				vm.stack[sp] = vm.stack[frame.slots + base_slot + u16(int(i)*elem_slots + s)]; sp += 1
			}

		case .ARRAY_SET:
			base_slot  := u16(read_byte(frame))
			elem_slots := int(read_byte(frame))
			i, ok := vm.stack[sp-1].(i64); if !ok do return .TYPE_ERROR
			sp -= 1
			top := int(sp)
			for s in 0..<elem_slots {
				vm.stack[frame.slots + base_slot + u16(int(i)*elem_slots + s)] = vm.stack[top - elem_slots + s]
			}
			// Leave elem_slots values on the stack — mirrors SET_LOCAL's peek-not-pop contract.
			// The expression statement caller emits POPs via expr_slot_count.

		case .MAKE_SLICE:
			elem_slots  := int(read_byte(frame))
			gf_val      := vm.stack[sp-1]; sp -= 1
			cap_val     := vm.stack[sp-1]; sp -= 1
			cap, ok1    := cap_val.(i64); if !ok1 do return .TYPE_ERROR
			gf_raw, ok2 := gf_val.(i64);  if !ok2 do return .TYPE_ERROR
			if gf_raw < 0 || gf_raw > 255 do return .TYPE_ERROR
			if cap <= 0 { cap = 1 }
			if cap > i64(max(u32)) do return .TYPE_ERROR
			cap = i64(u32(cap))
			gf    := u8(gf_raw)
			slots := make([]Value, int(cap) * elem_slots)
			append(&vm.heap_objects, slots)
			ptr: [^]Value = raw_data(slots)
			vm.stack[sp] = ptr;     sp += 1  // ptr
			vm.stack[sp] = i64(0);  sp += 1  // len = 0
			vm.stack[sp] = cap;     sp += 1  // cap
			vm.stack[sp] = i64(gf); sp += 1  // grow_factor

		case .SLICE_GET:
			elem_slots  := int(read_byte(frame))
			idx_val     := vm.stack[sp-1]; sp -= 1
			ptr_val     := vm.stack[sp-1]; sp -= 1
			i, ok1      := idx_val.(i64);     if !ok1 do return .TYPE_ERROR
			ptr, ok2    := ptr_val.([^]Value); if !ok2 do return .TYPE_ERROR
			if ptr == nil do return .NULL_DEREF
			for s in 0..<elem_slots {
				vm.stack[sp] = ptr[int(i)*elem_slots + s]; sp += 1
			}

		case .SLICE_SET:
			base_slot   := u16(read_byte(frame))
			elem_slots  := int(read_byte(frame))
			i, ok1      := vm.stack[sp-1].(i64); if !ok1 do return .TYPE_ERROR
			sp -= 1
			ptr         := vm.stack[frame.slots + base_slot].([^]Value)
			cap         := u32(vm.stack[frame.slots + base_slot + 2].(i64))
			grow_factor := u8(vm.stack[frame.slots + base_slot + 3].(i64))
			if i >= i64(cap) {
				if grow_factor == 0 do return .INDEX_OUT_OF_BOUNDS
				new_cap := cap
				for i64(new_cap) <= i { new_cap += u32(grow_factor) * new_cap }
				new_slots := make([]Value, int(new_cap) * elem_slots)
				old_len := int(cap) * elem_slots
				for j in 0..<old_len { new_slots[j] = ptr[j] }
				for obj, oi in vm.heap_objects {
					if raw_data(obj) == ptr {
						delete(obj)
						vm.heap_objects[oi] = new_slots
						break
					}
				}
				ptr = raw_data(new_slots)
				vm.stack[frame.slots + base_slot]     = ptr
				vm.stack[frame.slots + base_slot + 2] = i64(new_cap)
			}
			top := int(sp)
			for s in 0..<elem_slots {
				ptr[int(i)*elem_slots + s] = vm.stack[top - elem_slots + s]
			}
			cur_len := vm.stack[frame.slots + base_slot + 1].(i64)
			if i + 1 > cur_len {
				vm.stack[frame.slots + base_slot + 1] = i + 1
			}
			// Leave val on stack (peek contract — caller pops via expr_slot_count).

		case .ARRAY_GET_STACK:
			total_slots := int(read_byte(frame))
			elem_slots  := int(read_byte(frame))
			i, ok := vm.stack[sp-1].(i64); if !ok do return .TYPE_ERROR
			sp -= 1
			base := int(sp) - total_slots
			for s in 0..<elem_slots {
				vm.stack[base + s] = vm.stack[base + int(i)*elem_slots + s]
			}
			sp = u16(base + elem_slots)

		case .ARRAY_SET_CHAINED:
			base_slot        := u16(read_byte(frame))
			outer_elem_slots := int(read_byte(frame))
			inner_elem_slots := int(read_byte(frame))
			j, ok1 := vm.stack[sp-1].(i64); if !ok1 do return .TYPE_ERROR
			sp -= 1
			i, ok2 := vm.stack[sp-1].(i64); if !ok2 do return .TYPE_ERROR
			sp -= 1
			dest := int(base_slot) + int(i)*outer_elem_slots + int(j)*inner_elem_slots
			top  := int(sp)
			for s in 0..<inner_elem_slots {
				vm.stack[frame.slots + u16(dest + s)] = vm.stack[top - inner_elem_slots + s]
			}
			// Leave inner_elem_slots values on stack (peek contract — caller emits POP)

		case .SLICE_GET_STACK:
			elem_slots := int(read_byte(frame))
			j, ok1     := vm.stack[sp-1].(i64); if !ok1 do return .TYPE_ERROR
			sp -= 1          // pop index
			sp -= 1          // pop grow_factor
			sp -= 1          // pop cap
			sp -= 1          // pop len
			ptr, ok2   := vm.stack[sp-1].([^]Value); if !ok2 do return .TYPE_ERROR
			sp -= 1          // pop ptr
			if ptr == nil do return .NULL_DEREF
			for s in 0..<elem_slots {
				vm.stack[sp] = ptr[int(j)*elem_slots + s]; sp += 1
			}

		case .STR_LEN:
			s, ok := vm.stack[sp-1].(string); if !ok do return .TYPE_ERROR
			vm.stack[sp-1] = i64(len(s))

		case .STR_GET:
			i, ok1 := vm.stack[sp-1].(i64);    if !ok1 do return .TYPE_ERROR
			s, ok2 := vm.stack[sp-2].(string);  if !ok2 do return .TYPE_ERROR
			if i < 0 || i >= i64(len(s)) do return .INDEX_OUT_OF_BOUNDS
			sp -= 2
			vm.stack[sp] = vm.char_cache[s[i]]; sp += 1

		case .NEW:
			n := int(read_byte(frame))
			slots := make([]Value, n)
			for i := n - 1; i >= 0; i -= 1 { sp -= 1; slots[i] = vm.stack[sp] }
			append(&vm.heap_objects, slots)
			ptr: [^]Value = raw_data(slots)
			vm.stack[sp] = ptr; sp += 1

		case .HEAP_GET:
			offset   := int(read_byte(frame))
			ptr, ok  := vm.stack[sp-1].([^]Value); if !ok do return .TYPE_ERROR
			if ptr == nil do return .NULL_DEREF
			sp -= 1
			vm.stack[sp] = ptr[offset]; sp += 1

		case .HEAP_SET:
			offset  := int(read_byte(frame))
			ptr, ok := vm.stack[sp-1].([^]Value); if !ok do return .TYPE_ERROR
			if ptr == nil do return .NULL_DEREF
			sp -= 1
			ptr[offset] = vm.stack[sp-1]

		case .HEAP_LOAD:
			n       := int(read_byte(frame))
			ptr, ok := vm.stack[sp-1].([^]Value); if !ok do return .TYPE_ERROR
			if ptr == nil do return .NULL_DEREF
			sp -= 1
			for i in 0..<n { vm.stack[sp] = ptr[i]; sp += 1 }

		case .NOP:
			// nothing

		case .ADD_LOCALS:
			a := u16(read_byte(frame)); b := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + a].(i64)
			bv, ok2 := vm.stack[frame.slots + b].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			vm.stack[sp] = av + bv; sp += 1

		case .MUL_LOCALS:
			a := u16(read_byte(frame)); b := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + a].(i64)
			bv, ok2 := vm.stack[frame.slots + b].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			vm.stack[sp] = av * bv; sp += 1

		case .LT_LOCAL_CONST:
			slot := u16(read_byte(frame)); hi := u16(read_byte(frame)); lo := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + slot].(i64)
			bv, ok2 := frame.function.chunk.constants[(hi<<8)|lo].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			vm.stack[sp] = av < bv; sp += 1

		case .LTE_LOCAL_CONST:
			slot := u16(read_byte(frame)); hi := u16(read_byte(frame)); lo := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + slot].(i64)
			bv, ok2 := frame.function.chunk.constants[(hi<<8)|lo].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			vm.stack[sp] = av <= bv; sp += 1

		case .SUB_LOCAL_CONST:
			slot := u16(read_byte(frame)); hi := u16(read_byte(frame)); lo := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + slot].(i64)
			bv, ok2 := frame.function.chunk.constants[(hi<<8)|lo].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			vm.stack[sp] = av - bv; sp += 1

		case .GT_LOCAL_CONST:
			slot := u16(read_byte(frame)); hi := u16(read_byte(frame)); lo := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + slot].(i64)
			bv, ok2 := frame.function.chunk.constants[(hi<<8)|lo].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			vm.stack[sp] = av > bv; sp += 1

		case .GTE_LOCAL_CONST:
			slot := u16(read_byte(frame)); hi := u16(read_byte(frame)); lo := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + slot].(i64)
			bv, ok2 := frame.function.chunk.constants[(hi<<8)|lo].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			vm.stack[sp] = av >= bv; sp += 1

		case .EQ_LOCAL_CONST:
			slot := u16(read_byte(frame)); hi := u16(read_byte(frame)); lo := u16(read_byte(frame))
			lv := vm.stack[frame.slots + slot]
			cv := frame.function.chunk.constants[(hi<<8)|lo]
			vm.stack[sp] = vm_values_equal(lv, cv); sp += 1

		case .SUB_LOCALS:
			a := u16(read_byte(frame)); b := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + a].(i64)
			bv, ok2 := vm.stack[frame.slots + b].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			vm.stack[sp] = av - bv; sp += 1

		case .DIV_LOCALS:
			a := u16(read_byte(frame)); b := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + a].(i64)
			bv, ok2 := vm.stack[frame.slots + b].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			if bv == 0 do return .DIVISION_BY_ZERO
			vm.stack[sp] = av / bv; sp += 1

		case .MOD_LOCALS:
			a := u16(read_byte(frame)); b := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + a].(i64)
			bv, ok2 := vm.stack[frame.slots + b].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			if bv == 0 do return .DIVISION_BY_ZERO
			vm.stack[sp] = av % bv; sp += 1

		case .LT_LOCALS:
			a := u16(read_byte(frame)); b := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + a].(i64)
			bv, ok2 := vm.stack[frame.slots + b].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			vm.stack[sp] = av < bv; sp += 1

		case .LTE_LOCALS:
			a := u16(read_byte(frame)); b := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + a].(i64)
			bv, ok2 := vm.stack[frame.slots + b].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			vm.stack[sp] = av <= bv; sp += 1

		case .GT_LOCALS:
			a := u16(read_byte(frame)); b := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + a].(i64)
			bv, ok2 := vm.stack[frame.slots + b].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			vm.stack[sp] = av > bv; sp += 1

		case .GTE_LOCALS:
			a := u16(read_byte(frame)); b := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + a].(i64)
			bv, ok2 := vm.stack[frame.slots + b].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			vm.stack[sp] = av >= bv; sp += 1

		case .INC_LOCAL:
			slot := u16(read_byte(frame))
			v, ok := vm.stack[frame.slots + slot].(i64)
			if !ok do return .TYPE_ERROR
			vm.stack[frame.slots + slot] = v + 1

		case .DEC_LOCAL:
			slot := u16(read_byte(frame))
			v, ok := vm.stack[frame.slots + slot].(i64)
			if !ok do return .TYPE_ERROR
			vm.stack[frame.slots + slot] = v - 1

		case .JUMP_IF_FALSE_POP:
			hi := u16(read_byte(frame)); lo := u16(read_byte(frame))
			offset := (hi << 8) | lo
			cond := vm.stack[sp-1]; sp -= 1
			if is_falsy(cond) {
				frame.ip += int(offset)
			}

		case .JUMP_IF_TRUE_POP:
			hi := u16(read_byte(frame)); lo := u16(read_byte(frame))
			offset := (hi << 8) | lo
			cond := vm.stack[sp-1]; sp -= 1
			if !is_falsy(cond) {
				frame.ip += int(offset)
			}

		case .SET_LOCAL_POP:
			slot := u16(read_byte(frame))
			vm.stack[frame.slots + slot] = vm.stack[sp-1]; sp -= 1

		case .RETURN:
			n := int(read_byte(frame))
			if n == 0 {
				vm.frame_count -= 1
				if vm.frame_count == 0 { vm.stack_top = 0; return nil }
				sp = vm.frames[vm.frame_count].slots
				frame = current_frame(vm)
			} else if n == 1 {
				ret := vm.stack[sp - 1]
				vm.frame_count -= 1
				if vm.frame_count == 0 {
					vm.stack[0] = ret; vm.stack_top = 1; return nil
				}
				sp = vm.frames[vm.frame_count].slots
				vm.stack[sp] = ret; sp += 1
				frame = current_frame(vm)
			} else {
				tmp: [256]Value
				for i := n - 1; i >= 0; i -= 1 { sp -= 1; tmp[i] = vm.stack[sp] }
				vm.frame_count -= 1
				if vm.frame_count == 0 {
					for i in 0..<n { vm.stack[i] = tmp[i] }
					sp = u16(n); vm.stack_top = sp; return nil
				}
				sp = vm.frames[vm.frame_count].slots
				for i in 0..<n { vm.stack[sp] = tmp[i]; sp += 1 }
				frame = current_frame(vm)
			}

		case .RETURN_LOCAL:
			slot  := u16(read_byte(frame))
			ret_n := int(read_byte(frame))
			ret   := vm.stack[frame.slots + slot]
			vm.frame_count -= 1
			if vm.frame_count == 0 {
				vm.stack[0] = ret; vm.stack_top = 1; return nil
			}
			sp = vm.frames[vm.frame_count].slots
			if ret_n == 1 { vm.stack[sp] = ret; sp += 1 }
			frame = current_frame(vm)

		case .RETURN_CONST:
			c_idx := u16(read_byte(frame))
			ret_n := int(read_byte(frame))
			ret   := frame.function.chunk.constants[c_idx]
			vm.frame_count -= 1
			if vm.frame_count == 0 {
				vm.stack[0] = ret; vm.stack_top = 1; return nil
			}
			sp = vm.frames[vm.frame_count].slots
			if ret_n == 1 { vm.stack[sp] = ret; sp += 1 }
			frame = current_frame(vm)

		case .MOD_LOCAL_LOCAL_EQ_ZERO:
			a  := u16(read_byte(frame)); b := u16(read_byte(frame))
			av := vm.stack[frame.slots + a].(i64)
			bv := vm.stack[frame.slots + b].(i64)
			if bv == 0 do return .DIVISION_BY_ZERO
			vm.stack[sp] = av % bv == 0
			sp += 1

		case .SQUARE_I64:
			s := u16(read_byte(frame))
			v := vm.stack[frame.slots + s].(i64)
			vm.stack[sp] = v * v
			sp += 1

		case .SQUARE_F64:
			s := u16(read_byte(frame))
			v := vm.stack[frame.slots + s].(f64)
			vm.stack[sp] = v * v
			sp += 1

		case .NIL_EQ:
			_, is_nil := vm.stack[sp-1].(Nil)
			vm.stack[sp-1] = is_nil

		case .NIL_NEQ:
			_, is_nil := vm.stack[sp-1].(Nil)
			vm.stack[sp-1] = !is_nil

		// ---- type-specific arithmetic (pop b, overwrite a in-place) ----

		case .ADD_I64:
			bv := vm.stack[sp-1].(i64); sp -= 1
			vm.stack[sp-1] = vm.stack[sp-1].(i64) + bv
		case .SUB_I64:
			bv := vm.stack[sp-1].(i64); sp -= 1
			vm.stack[sp-1] = vm.stack[sp-1].(i64) - bv
		case .MUL_I64:
			bv := vm.stack[sp-1].(i64); sp -= 1
			vm.stack[sp-1] = vm.stack[sp-1].(i64) * bv
		case .DIV_I64:
			bv := vm.stack[sp-1].(i64); if bv == 0 do return .DIVISION_BY_ZERO
			sp -= 1; vm.stack[sp-1] = vm.stack[sp-1].(i64) / bv
		case .MOD_I64:
			bv := vm.stack[sp-1].(i64); if bv == 0 do return .DIVISION_BY_ZERO
			sp -= 1; vm.stack[sp-1] = vm.stack[sp-1].(i64) % bv

		case .ADD_F64:
			bv := vm.stack[sp-1].(f64); sp -= 1
			vm.stack[sp-1] = vm.stack[sp-1].(f64) + bv
		case .SUB_F64:
			bv := vm.stack[sp-1].(f64); sp -= 1
			vm.stack[sp-1] = vm.stack[sp-1].(f64) - bv
		case .MUL_F64:
			bv := vm.stack[sp-1].(f64); sp -= 1
			vm.stack[sp-1] = vm.stack[sp-1].(f64) * bv
		case .DIV_F64:
			bv := vm.stack[sp-1].(f64); if bv == 0 do return .DIVISION_BY_ZERO
			sp -= 1; vm.stack[sp-1] = vm.stack[sp-1].(f64) / bv

		case .ADD_STR:
			b, _ := vm.stack[sp-1].(string); sp -= 1
			a, _ := vm.stack[sp-1].(string); sp -= 1
			tmp := strings.concatenate({a, b})
			interned := string_pool_intern(&vm.strings, tmp)
			if raw_data(tmp) != raw_data(interned) { delete(tmp) }
			vm.stack[sp] = interned; sp += 1

		case .LT_I64:
			bv := vm.stack[sp-1].(i64); sp -= 1; vm.stack[sp-1] = vm.stack[sp-1].(i64) < bv
		case .LTE_I64:
			bv := vm.stack[sp-1].(i64); sp -= 1; vm.stack[sp-1] = vm.stack[sp-1].(i64) <= bv
		case .GT_I64:
			bv := vm.stack[sp-1].(i64); sp -= 1; vm.stack[sp-1] = vm.stack[sp-1].(i64) > bv
		case .GTE_I64:
			bv := vm.stack[sp-1].(i64); sp -= 1; vm.stack[sp-1] = vm.stack[sp-1].(i64) >= bv

		case .LT_F64:
			bv := vm.stack[sp-1].(f64); sp -= 1; vm.stack[sp-1] = vm.stack[sp-1].(f64) < bv
		case .LTE_F64:
			bv := vm.stack[sp-1].(f64); sp -= 1; vm.stack[sp-1] = vm.stack[sp-1].(f64) <= bv
		case .GT_F64:
			bv := vm.stack[sp-1].(f64); sp -= 1; vm.stack[sp-1] = vm.stack[sp-1].(f64) > bv
		case .GTE_F64:
			bv := vm.stack[sp-1].(f64); sp -= 1; vm.stack[sp-1] = vm.stack[sp-1].(f64) >= bv

		case .NEGATE_I64:
			vm.stack[sp-1] = -vm.stack[sp-1].(i64)
		case .NEGATE_F64:
			vm.stack[sp-1] = -vm.stack[sp-1].(f64)
		}
	}
}

vm_interpret :: proc(vm: ^VM, module: ^Module) -> Maybe(VMError) {
	vm.functions = module.functions[:]
	fn := vm.functions[0]
	vm_push(vm, Value(FnRef(0)))

	frame := &vm.frames[0]
	vm.frame_count = 1
	frame.function = fn
	frame.ip       = 0
	frame.slots    = 0

	return vm_run(vm)
}

is_falsy :: #force_inline proc "contextless" (val: Value) -> bool {
	switch v in val {
	case bool:      return !v
	case Nil:       return true
	case i64:       return false
	case f64:       return false
	case string:    return false
	case FnRef: return false
	case [^]Value:  return v == nil
	}
	return true
}

read_line :: #force_inline proc(src: io.Reader) -> string {
	r := src if src.data != nil else io.Reader(os.to_reader(os.stdin))
	b := strings.builder_make()
	buf := [1]byte{}
	for {
		n, err := io.read(r, buf[:])
		if n > 0 {
			if buf[0] == '\n' { break }
			if buf[0] != '\r' { strings.write_byte(&b, buf[0]) }
		}
		if err != nil { break }
	}
	return strings.to_string(b)
}

print_value :: proc(val: Value) {
	switch v in val {
	case i64:      fmt.printf("%d", v)
	case f64:      fmt.printf("%g", v)
	case bool:     fmt.printf("%t", v)
	case string:   fmt.printf("%s", v)
	case Nil:      fmt.printf("nil")
	case FnRef: fmt.printf("<fn#%d>", int(v))
	case [^]Value:
		if v == nil { fmt.printf("nil") } else { fmt.printf("<ptr>") }
	}
}

vm_values_equal :: #force_inline proc(a, b: Value) -> bool {
	if as, ok := a.(string); ok {
		if bs, ok2 := b.(string); ok2 {
			return as == bs
		}
		return false
	}
	return bc.values_equal(a, b)
}

vm_binary_op :: #force_inline proc "contextless" (vm: ^VM, op: Opcode) -> Maybe(VMError) {
	b, err1 := vm_pop(vm); if err1 != nil do return err1
	a, err2 := vm_pop(vm); if err2 != nil do return err2
	#partial switch av in a {
	case i64:
		bv, ok := b.(i64); if !ok do return .TYPE_ERROR
		#partial switch op {
		case .SUB: return vm_push(vm, av - bv)
		case .MUL: return vm_push(vm, av * bv)
		case .DIV:
			if bv == 0 do return .DIVISION_BY_ZERO
			return vm_push(vm, av / bv)
		case .MOD:
			if bv == 0 do return .DIVISION_BY_ZERO
			return vm_push(vm, av % bv)
		case .SHL:  return vm_push(vm, av << uint(bv))
		case .SHR:  return vm_push(vm, av >> uint(bv))
		case .BAND: return vm_push(vm, av & bv)
		case .BOR:  return vm_push(vm, av | bv)
		case .BXOR: return vm_push(vm, av ~ bv)
		}
	case f64:
		bv, ok := b.(f64); if !ok do return .TYPE_ERROR
		#partial switch op {
		case .SUB: return vm_push(vm, av - bv)
		case .MUL: return vm_push(vm, av * bv)
		case .DIV:
			if bv == 0 do return .DIVISION_BY_ZERO
			return vm_push(vm, av / bv)
		case .MOD: return .TYPE_ERROR
		}
	case: return .TYPE_ERROR
	}
	return nil
}

vm_compare :: #force_inline proc "contextless" (vm: ^VM, op: Opcode) -> Maybe(VMError) {
	b, _ := vm_pop(vm)
	a, _ := vm_pop(vm)
	#partial switch av in a {
	case i64:
		bv, ok := b.(i64); if !ok do return .TYPE_ERROR
		#partial switch op {
		case .LT:  return vm_push(vm, av < bv)
		case .LTE: return vm_push(vm, av <= bv)
		case .GT:  return vm_push(vm, av > bv)
		case .GTE: return vm_push(vm, av >= bv)
		}
	case f64:
		bv, ok := b.(f64); if !ok do return .TYPE_ERROR
		#partial switch op {
		case .LT:  return vm_push(vm, av < bv)
		case .LTE: return vm_push(vm, av <= bv)
		case .GT:  return vm_push(vm, av > bv)
		case .GTE: return vm_push(vm, av >= bv)
		}
	case: return .TYPE_ERROR
	}
	return nil
}

vm_call :: #force_inline proc "contextless" (vm: ^VM, arg_count: u16) -> Maybe(VMError) {
	callee := vm.stack[vm.stack_top - 1 - arg_count]
	ref, ok := callee.(FnRef)
	if !ok do return .CALL_NON_FUNCTION
	fn := vm.functions[ref]
	if arg_count != u16(fn.arity) do return .WRONG_ARG_COUNT
	if vm.frame_count >= FRAMES_MAX do return .STACK_OVERFLOW

	frame := &vm.frames[vm.frame_count]
	vm.frame_count += 1
	frame.function = fn
	frame.ip       = 0
	frame.slots    = vm.stack_top - arg_count - 1
	return nil
}
