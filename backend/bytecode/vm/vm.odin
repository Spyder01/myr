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

vm_push :: proc(vm: ^VM, val: Value) -> Maybe(VMError) {
	if vm.stack_top >= STACK_MAX do return .STACK_OVERFLOW
	vm.stack[vm.stack_top] = val
	vm.stack_top += 1
	return nil
}

vm_pop :: proc(vm: ^VM) -> (Value, Maybe(VMError)) {
	if vm.stack_top == 0 do return Nil{}, .STACK_UNDERFLOW
	vm.stack_top -= 1
	return vm.stack[vm.stack_top], nil
}

vm_peek :: proc(vm: ^VM, dist: u16 = 0) -> (Value, Maybe(VMError)) {
	if vm.stack_top == 0 || dist >= vm.stack_top do return Nil{}, .STACK_UNDERFLOW
	return vm.stack[vm.stack_top - 1 - dist], nil
}

current_frame :: proc(vm: ^VM) -> ^CallFrame {
	return &vm.frames[vm.frame_count - 1]
}

read_byte :: proc(frame: ^CallFrame) -> u8 {
	b := frame.function.chunk.code[frame.ip]
	frame.ip += 1
	return b
}

read_short :: proc(frame: ^CallFrame) -> u16 {
	hi := u16(read_byte(frame)) << 8
	lo := u16(read_byte(frame))
	return hi | lo
}

read_constant :: proc(frame: ^CallFrame) -> Value {
	idx := read_byte(frame)
	return frame.function.chunk.constants[idx]
}

read_constant_long :: proc(frame: ^CallFrame) -> Value {
	idx := read_short(frame)
	return frame.function.chunk.constants[idx]
}

vm_run :: proc(vm: ^VM) -> Maybe(VMError) {
	frame := current_frame(vm)
	for {
		op := Opcode(read_byte(frame))
		#partial switch op {

		case .CONST:
			val := read_constant(frame)
			if s, ok := val.(string); ok { val = string_pool_intern(&vm.strings, s) }
			if err := vm_push(vm, val); err != nil do return err

		case .CONST_LONG:
			val := read_constant_long(frame)
			if s, ok := val.(string); ok { val = string_pool_intern(&vm.strings, s) }
			if err := vm_push(vm, val); err != nil do return err

		case .NIL:
			if err := vm_push(vm, Nil{}); err != nil do return err

		case .TRUE:
			if err := vm_push(vm, true); err != nil do return err

		case .FALSE:
			if err := vm_push(vm, false); err != nil do return err

		case .ADD:
			b, err1 := vm_pop(vm); if err1 != nil do return err1
			a, err2 := vm_pop(vm); if err2 != nil do return err2
			#partial switch av in a {
			case i64:
				bv, ok := b.(i64); if !ok do return .TYPE_ERROR
				if err := vm_push(vm, av + bv); err != nil do return err
			case f64:
				bv, ok := b.(f64); if !ok do return .TYPE_ERROR
				if err := vm_push(vm, av + bv); err != nil do return err
			case string:
				bv, ok := b.(string); if !ok do return .TYPE_ERROR
				tmp := strings.concatenate({av, bv})
				interned := string_pool_intern(&vm.strings, tmp)
				if raw_data(tmp) != raw_data(interned) { delete(tmp) }
				if err := vm_push(vm, interned); err != nil do return err
			case: return .TYPE_ERROR
			}

		case .SUB:  if err := vm_binary_op(vm, .SUB);  err != nil do return err
		case .MUL:  if err := vm_binary_op(vm, .MUL);  err != nil do return err
		case .DIV:  if err := vm_binary_op(vm, .DIV);  err != nil do return err
		case .MOD:  if err := vm_binary_op(vm, .MOD);  err != nil do return err
		case .SHL:  if err := vm_binary_op(vm, .SHL);  err != nil do return err
		case .SHR:  if err := vm_binary_op(vm, .SHR);  err != nil do return err
		case .BAND: if err := vm_binary_op(vm, .BAND); err != nil do return err
		case .BOR:  if err := vm_binary_op(vm, .BOR);  err != nil do return err
		case .BXOR: if err := vm_binary_op(vm, .BXOR); err != nil do return err

		case .BNOT:
			a, err := vm_pop(vm); if err != nil do return err
			av, ok := a.(i64); if !ok do return .TYPE_ERROR
			if err2 := vm_push(vm, ~av); err2 != nil do return err2

		case .NEGATE:
			a, err := vm_pop(vm); if err != nil do return err
			#partial switch av in a {
			case i64: if err2 := vm_push(vm, -av); err2 != nil do return err2
			case f64: if err2 := vm_push(vm, -av); err2 != nil do return err2
			case:     return .TYPE_ERROR
			}

		case .EQ:
			b, _ := vm_pop(vm); a, _ := vm_pop(vm)
			if err := vm_push(vm, vm_values_equal(a, b)); err != nil do return err

		case .NEQ:
			b, _ := vm_pop(vm); a, _ := vm_pop(vm)
			if err := vm_push(vm, !vm_values_equal(a, b)); err != nil do return err

		case .LT:  if err := vm_compare(vm, .LT);  err != nil do return err
		case .LTE: if err := vm_compare(vm, .LTE); err != nil do return err
		case .GT:  if err := vm_compare(vm, .GT);  err != nil do return err
		case .GTE: if err := vm_compare(vm, .GTE); err != nil do return err

		case .NOT:
			a, err := vm_pop(vm); if err != nil do return err
			if err2 := vm_push(vm, is_falsy(a)); err2 != nil do return err2

		case .POP:
			_, err := vm_pop(vm); if err != nil do return err

		case .PRINT:
			a, err := vm_pop(vm); if err != nil do return err
			print_value(a); fmt.println()

		case .INPUT:
			prompt, err := vm_pop(vm); if err != nil do return err
			if s, ok := prompt.(string); ok && len(s) > 0 { fmt.printf("%s", s) }
			tmp := read_line(vm.stdin)
			interned := string_pool_intern(&vm.strings, tmp)
			if raw_data(tmp) != raw_data(interned) { delete(tmp) }
			vm_push(vm, interned)

		case .DEFINE_GLOBAL:
			slot := read_byte(frame)
			top, _ := vm_peek(vm)
			vm.globals[slot] = top
			vm_pop(vm)

		case .GET_GLOBAL:
			slot := read_byte(frame)
			if err := vm_push(vm, vm.globals[slot]); err != nil do return err

		case .SET_GLOBAL:
			slot := read_byte(frame)
			top, _ := vm_peek(vm)
			vm.globals[slot] = top

		case .GET_LOCAL:
			slot := u16(read_byte(frame))
			if err := vm_push(vm, vm.stack[frame.slots + slot]); err != nil do return err

		case .SET_LOCAL:
			slot := u16(read_byte(frame))
			top, _ := vm_peek(vm)
			vm.stack[frame.slots + slot] = top

		case .JUMP:
			offset := read_short(frame)
			frame.ip += int(offset)

		case .JUMP_IF_FALSE:
			offset := read_short(frame)
			top, _ := vm_peek(vm)
			if is_falsy(top) { frame.ip += int(offset) }

		case .JUMP_IF_TRUE:
			offset := read_short(frame)
			top, _ := vm_peek(vm)
			if !is_falsy(top) { frame.ip += int(offset) }

		case .LOOP:
			offset := read_short(frame)
			frame.ip -= int(offset)

		case .CALL:
			arg_count := u16(read_byte(frame))
			if err := vm_call(vm, arg_count); err != nil do return err
			frame = current_frame(vm)

		case .ADDR_LOCAL:
			slot := int(read_byte(frame))
			ptr: [^]Value = raw_data(vm.stack[frame.slots + u16(slot):])
			if err := vm_push(vm, ptr); err != nil do return err

		case .ARRAY_GET:
			base_slot  := u16(read_byte(frame))
			elem_slots := int(read_byte(frame))
			idx_val, err := vm_pop(vm); if err != nil do return err
			i, ok := idx_val.(i64); if !ok do return .TYPE_ERROR
			for s in 0..<elem_slots {
				if push_err := vm_push(vm, vm.stack[frame.slots + base_slot + u16(int(i)*elem_slots + s)]); push_err != nil do return push_err
			}

		case .ARRAY_SET:
			base_slot  := u16(read_byte(frame))
			elem_slots := int(read_byte(frame))
			idx_val, err := vm_pop(vm); if err != nil do return err
			i, ok := idx_val.(i64); if !ok do return .TYPE_ERROR
			top := int(vm.stack_top)
			for s in 0..<elem_slots {
				vm.stack[frame.slots + base_slot + u16(int(i)*elem_slots + s)] = vm.stack[top - elem_slots + s]
			}
			// Leave elem_slots values on the stack — mirrors SET_LOCAL's peek-not-pop contract.
			// The expression statement caller emits POPs via expr_slot_count.

		case .MAKE_SLICE:
			elem_slots      := int(read_byte(frame))
			gf_val, err1    := vm_pop(vm); if err1 != nil do return err1
			cap_val, err2   := vm_pop(vm); if err2 != nil do return err2
			cap, ok1        := cap_val.(i64); if !ok1 do return .TYPE_ERROR
			gf_raw, ok2     := gf_val.(i64);  if !ok2 do return .TYPE_ERROR
			if gf_raw < 0 || gf_raw > 255 do return .TYPE_ERROR
			if cap <= 0 { cap = 1 }
			if cap > i64(max(u32)) do return .TYPE_ERROR
			cap = i64(u32(cap))
			gf := u8(gf_raw)
			slots           := make([]Value, int(cap) * elem_slots)
			append(&vm.heap_objects, slots)
			ptr: [^]Value = raw_data(slots)
			if err3 := vm_push(vm, ptr);        err3 != nil do return err3  // ptr
			if err3 := vm_push(vm, i64(0));     err3 != nil do return err3  // len = 0
			if err3 := vm_push(vm, cap);        err3 != nil do return err3  // cap
			if err3 := vm_push(vm, i64(gf));    err3 != nil do return err3  // grow_factor (stored as i64, semantically u8)

		case .SLICE_GET:
			elem_slots := int(read_byte(frame))
			idx_val, err1 := vm_pop(vm); if err1 != nil do return err1
			ptr_val, err2 := vm_pop(vm); if err2 != nil do return err2
			i, ok1 := idx_val.(i64); if !ok1 do return .TYPE_ERROR
			ptr, ok2 := ptr_val.([^]Value); if !ok2 do return .TYPE_ERROR
			if ptr == nil do return .NULL_DEREF
			for s in 0..<elem_slots {
				if push_err := vm_push(vm, ptr[int(i)*elem_slots + s]); push_err != nil do return push_err
			}

		case .SLICE_SET:
			base_slot  := u16(read_byte(frame))
			elem_slots := int(read_byte(frame))
			idx_val, err1 := vm_pop(vm); if err1 != nil do return err1
			i, ok1 := idx_val.(i64); if !ok1 do return .TYPE_ERROR
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
			top := int(vm.stack_top)
			for s in 0..<elem_slots {
				ptr[int(i)*elem_slots + s] = vm.stack[top - elem_slots + s]
			}
			cur_len := vm.stack[frame.slots + base_slot + 1].(i64)
			if i + 1 > cur_len {
				vm.stack[frame.slots + base_slot + 1] = i + 1
			}
			// Leave val on stack (peek contract — caller pops via expr_slot_count).

		case .STR_LEN:
			str_val, err1 := vm_pop(vm); if err1 != nil do return err1
			s, ok := str_val.(string); if !ok do return .TYPE_ERROR
			if push_err := vm_push(vm, i64(len(s))); push_err != nil do return push_err

		case .STR_GET:
			idx_val, err1 := vm_pop(vm); if err1 != nil do return err1
			str_val, err2 := vm_pop(vm); if err2 != nil do return err2
			i, ok1 := idx_val.(i64); if !ok1 do return .TYPE_ERROR
			s, ok2 := str_val.(string); if !ok2 do return .TYPE_ERROR
			if i < 0 || i >= i64(len(s)) do return .INDEX_OUT_OF_BOUNDS
			if push_err := vm_push(vm, vm.char_cache[s[i]]); push_err != nil do return push_err

		case .NEW:
			n := int(read_byte(frame))
			slots := make([]Value, n)
			for i := n - 1; i >= 0; i -= 1 {
				v, err := vm_pop(vm)
				if err != nil { delete(slots); return err }
				slots[i] = v
			}
			append(&vm.heap_objects, slots)
			ptr: [^]Value = raw_data(slots)
			if err := vm_push(vm, ptr); err != nil do return err

		case .HEAP_GET:
			offset := int(read_byte(frame))
			pv, err := vm_pop(vm); if err != nil do return err
			ptr, ok := pv.([^]Value); if !ok do return .TYPE_ERROR
			if ptr == nil do return .NULL_DEREF
			if err2 := vm_push(vm, ptr[offset]); err2 != nil do return err2

		case .HEAP_SET:
			offset := int(read_byte(frame))
			pv, err1 := vm_pop(vm); if err1 != nil do return err1
			ptr, ok := pv.([^]Value); if !ok do return .TYPE_ERROR
			if ptr == nil do return .NULL_DEREF
			val, err2 := vm_peek(vm); if err2 != nil do return err2
			ptr[offset] = val

		case .HEAP_LOAD:
			n := int(read_byte(frame))
			pv, err := vm_pop(vm); if err != nil do return err
			ptr, ok := pv.([^]Value); if !ok do return .TYPE_ERROR
			if ptr == nil do return .NULL_DEREF
			for i in 0..<n {
				if err2 := vm_push(vm, ptr[i]); err2 != nil do return err2
			}

		case .NOP:
			// nothing

		case .ADD_LOCALS:
			a := u16(read_byte(frame))
			b := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + a].(i64)
			bv, ok2 := vm.stack[frame.slots + b].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			if err := vm_push(vm, av + bv); err != nil do return err

		case .MUL_LOCALS:
			a := u16(read_byte(frame))
			b := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + a].(i64)
			bv, ok2 := vm.stack[frame.slots + b].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			if err := vm_push(vm, av * bv); err != nil do return err

		case .LT_LOCAL_CONST:
			slot := u16(read_byte(frame))
			hi   := u16(read_byte(frame))
			lo   := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + slot].(i64)
			bv, ok2 := frame.function.chunk.constants[(hi<<8)|lo].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			if err := vm_push(vm, av < bv); err != nil do return err

		case .LTE_LOCAL_CONST:
			slot := u16(read_byte(frame))
			hi   := u16(read_byte(frame))
			lo   := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + slot].(i64)
			bv, ok2 := frame.function.chunk.constants[(hi<<8)|lo].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			if err := vm_push(vm, av <= bv); err != nil do return err

		case .SUB_LOCAL_CONST:
			slot := u16(read_byte(frame))
			hi   := u16(read_byte(frame))
			lo   := u16(read_byte(frame))
			av, ok1 := vm.stack[frame.slots + slot].(i64)
			bv, ok2 := frame.function.chunk.constants[(hi<<8)|lo].(i64)
			if !ok1 || !ok2 do return .TYPE_ERROR
			if err := vm_push(vm, av - bv); err != nil do return err

		case .RETURN:
			n := int(read_byte(frame))
			if n == 0 {
				vm.frame_count -= 1
				if vm.frame_count == 0 { vm.stack_top = 0; return nil }
				vm.stack_top = vm.frames[vm.frame_count].slots
				frame = current_frame(vm)
			} else if n == 1 {
				ret := vm.stack[vm.stack_top - 1]
				vm.frame_count -= 1
				if vm.frame_count == 0 {
					vm.stack[0] = ret
					vm.stack_top = 1
					return nil
				}
				vm.stack_top = vm.frames[vm.frame_count].slots
				vm.stack[vm.stack_top] = ret
				vm.stack_top += 1
				frame = current_frame(vm)
			} else {
				tmp: [256]Value
				for i := n - 1; i >= 0; i -= 1 {
					v, pop_err := vm_pop(vm)
					if pop_err != nil do return pop_err
					tmp[i] = v
				}
				vm.frame_count -= 1
				if vm.frame_count == 0 {
					for i in 0..<n { vm.stack[i] = tmp[i] }
					vm.stack_top = u16(n)
					return nil
				}
				vm.stack_top = vm.frames[vm.frame_count].slots
				for i in 0..<n {
					if push_err := vm_push(vm, tmp[i]); push_err != nil do return push_err
				}
				frame = current_frame(vm)
			}

		// ---- type-specific arithmetic ----

		case .ADD_I64:
			bv := vm.stack[vm.stack_top-1].(i64); av := vm.stack[vm.stack_top-2].(i64)
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av + bv
		case .SUB_I64:
			bv := vm.stack[vm.stack_top-1].(i64); av := vm.stack[vm.stack_top-2].(i64)
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av - bv
		case .MUL_I64:
			bv := vm.stack[vm.stack_top-1].(i64); av := vm.stack[vm.stack_top-2].(i64)
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av * bv
		case .DIV_I64:
			bv := vm.stack[vm.stack_top-1].(i64); av := vm.stack[vm.stack_top-2].(i64)
			if bv == 0 do return .DIVISION_BY_ZERO
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av / bv
		case .MOD_I64:
			bv := vm.stack[vm.stack_top-1].(i64); av := vm.stack[vm.stack_top-2].(i64)
			if bv == 0 do return .DIVISION_BY_ZERO
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av % bv

		case .ADD_F64:
			bv := vm.stack[vm.stack_top-1].(f64); av := vm.stack[vm.stack_top-2].(f64)
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av + bv
		case .SUB_F64:
			bv := vm.stack[vm.stack_top-1].(f64); av := vm.stack[vm.stack_top-2].(f64)
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av - bv
		case .MUL_F64:
			bv := vm.stack[vm.stack_top-1].(f64); av := vm.stack[vm.stack_top-2].(f64)
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av * bv
		case .DIV_F64:
			bv := vm.stack[vm.stack_top-1].(f64); av := vm.stack[vm.stack_top-2].(f64)
			if bv == 0 do return .DIVISION_BY_ZERO
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av / bv

		case .ADD_STR:
			bv, _ := vm_pop(vm); av, _ := vm_pop(vm)
			a, _ := av.(string); b, _ := bv.(string)
			tmp := strings.concatenate({a, b})
			interned := string_pool_intern(&vm.strings, tmp)
			if raw_data(tmp) != raw_data(interned) { delete(tmp) }
			if err := vm_push(vm, interned); err != nil do return err

		case .LT_I64:
			bv := vm.stack[vm.stack_top-1].(i64); av := vm.stack[vm.stack_top-2].(i64)
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av < bv
		case .LTE_I64:
			bv := vm.stack[vm.stack_top-1].(i64); av := vm.stack[vm.stack_top-2].(i64)
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av <= bv
		case .GT_I64:
			bv := vm.stack[vm.stack_top-1].(i64); av := vm.stack[vm.stack_top-2].(i64)
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av > bv
		case .GTE_I64:
			bv := vm.stack[vm.stack_top-1].(i64); av := vm.stack[vm.stack_top-2].(i64)
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av >= bv

		case .LT_F64:
			bv := vm.stack[vm.stack_top-1].(f64); av := vm.stack[vm.stack_top-2].(f64)
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av < bv
		case .LTE_F64:
			bv := vm.stack[vm.stack_top-1].(f64); av := vm.stack[vm.stack_top-2].(f64)
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av <= bv
		case .GT_F64:
			bv := vm.stack[vm.stack_top-1].(f64); av := vm.stack[vm.stack_top-2].(f64)
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av > bv
		case .GTE_F64:
			bv := vm.stack[vm.stack_top-1].(f64); av := vm.stack[vm.stack_top-2].(f64)
			vm.stack_top -= 1; vm.stack[vm.stack_top-1] = av >= bv

		case .NEGATE_I64:
			vm.stack[vm.stack_top-1] = -vm.stack[vm.stack_top-1].(i64)
		case .NEGATE_F64:
			vm.stack[vm.stack_top-1] = -vm.stack[vm.stack_top-1].(f64)
		}
	}
}

vm_interpret :: proc(vm: ^VM, fn: ^Function) -> Maybe(VMError) {
	vm_push(vm, Value(fn))

	frame := &vm.frames[0]
	vm.frame_count = 1
	frame.function = fn
	frame.ip       = 0
	frame.slots    = 0

	return vm_run(vm)
}

is_falsy :: proc(val: Value) -> bool {
	switch v in val {
	case bool:      return !v
	case Nil:       return true
	case i64:       return false
	case f64:       return false
	case string:    return false
	case ^Function: return false
	case [^]Value:  return v == nil
	}
	return true
}

read_line :: proc(src: io.Reader) -> string {
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
	case ^Function: fmt.printf("<fn %s>", v.name)
	case [^]Value:
		if v == nil { fmt.printf("nil") } else { fmt.printf("<ptr>") }
	}
}

vm_values_equal :: proc(a, b: Value) -> bool {
	if as, ok := a.(string); ok {
		if bs, ok2 := b.(string); ok2 {
			return as == bs
		}
		return false
	}
	return bc.values_equal(a, b)
}

vm_binary_op :: proc(vm: ^VM, op: Opcode) -> Maybe(VMError) {
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

vm_compare :: proc(vm: ^VM, op: Opcode) -> Maybe(VMError) {
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

vm_call :: proc(vm: ^VM, arg_count: u16) -> Maybe(VMError) {
	callee := vm.stack[vm.stack_top - 1 - arg_count]
	fn, ok := callee.(^Function)
	if !ok do return .CALL_NON_FUNCTION
	if arg_count != u16(fn.arity) do return .WRONG_ARG_COUNT
	if vm.frame_count >= FRAMES_MAX do return .STACK_OVERFLOW

	frame := &vm.frames[vm.frame_count]
	vm.frame_count += 1
	frame.function = fn
	frame.ip       = 0
	frame.slots    = vm.stack_top - arg_count - 1
	return nil
}
