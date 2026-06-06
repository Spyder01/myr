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
	frames:      [FRAMES_MAX]CallFrame,
	frame_count: u8,
	stack:       [STACK_MAX]Value,
	stack_top:   u16,
	globals:     map[string]Value,
	stdin:       io.Reader, // nil → use os.stdin
}

VMError :: enum {
	STACK_OVERFLOW,
	STACK_UNDERFLOW,
	TYPE_ERROR,
	UNDEFINED_VARIABLE,
	WRONG_ARG_COUNT,
	CALL_NON_FUNCTION,
	DIVISION_BY_ZERO,
}

new_vm :: proc(max_globals: Maybe(int) = nil) -> VM {
	vm: VM
	if cap, ok := max_globals.?; ok {
		vm.globals = make(map[string]Value, cap)
	} else {
		vm.globals = make(map[string]Value)
	}
	return vm
}

destroy_vm :: proc(vm: ^VM) {
	delete(vm.globals)
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

read_byte :: proc(vm: ^VM) -> u8 {
    frame := current_frame(vm)
    b := frame.function.chunk.code[frame.ip]
    frame.ip += 1
    return b
}

read_short :: proc(vm: ^VM) -> u16 {
    hi := u16(read_byte(vm)) << 8
    lo := u16(read_byte(vm))
    return hi | lo
}

read_constant :: proc(vm: ^VM) -> Value {
    idx := read_byte(vm)
    return current_frame(vm).function.chunk.constants[idx]
}

read_constant_long :: proc(vm: ^VM) -> Value {
    idx := read_short(vm)
    return current_frame(vm).function.chunk.constants[idx]
}

vm_run :: proc(vm: ^VM) -> Maybe(VMError) {
    for {
        op := Opcode(read_byte(vm))
        switch op {

        case .CONST:
            val := read_constant(vm)
            if err := vm_push(vm, val); err != nil do return err

        case .CONST_LONG:
            val := read_constant_long(vm)
            if err := vm_push(vm, val); err != nil do return err

        case .NIL:
            if err := vm_push(vm, Nil{}); err != nil do return err

        case .TRUE:
            if err := vm_push(vm, true); err != nil do return err

        case .FALSE:
            if err := vm_push(vm, false); err != nil do return err

        case .ADD:
            b, err1 := vm_pop(vm)
            if err1 != nil do return err1
            a, err2 := vm_pop(vm)
            if err2 != nil do return err2
            #partial switch av in a {
            case i64:
                bv, ok := b.(i64)
                if !ok do return .TYPE_ERROR
                if err := vm_push(vm, av + bv); err != nil do return err
            case f64:
                bv, ok := b.(f64)
                if !ok do return .TYPE_ERROR
                if err := vm_push(vm, av + bv); err != nil do return err
            case string:
                bv, ok := b.(string)
                if !ok do return .TYPE_ERROR
                if err := vm_push(vm, strings.concatenate({av, bv})); err != nil do return err
            case: return .TYPE_ERROR
            }

        case .SUB:
            if err := vm_binary_op(vm, .SUB); err != nil do return err

        case .MUL:
            if err := vm_binary_op(vm, .MUL); err != nil do return err

        case .DIV:
            if err := vm_binary_op(vm, .DIV); err != nil do return err

        case .MOD:
            if err := vm_binary_op(vm, .MOD); err != nil do return err

        case .NEGATE:
            a, err := vm_pop(vm)
            if err != nil do return err
            #partial switch av in a {
            case i64: if err := vm_push(vm, -av); err != nil do return err
            case f64: if err := vm_push(vm, -av); err != nil do return err
            case:     return .TYPE_ERROR
            }

        case .EQ:
            b, _ := vm_pop(vm)
            a, _ := vm_pop(vm)
            if err := vm_push(vm, bc.values_equal(a, b)); err != nil do return err

        case .NEQ:
            b, _ := vm_pop(vm)
            a, _ := vm_pop(vm)
            if err := vm_push(vm, !bc.values_equal(a, b)); err != nil do return err

        case .LT:
            if err := vm_compare(vm, .LT); err != nil do return err

        case .LTE:
            if err := vm_compare(vm, .LTE); err != nil do return err

        case .GT:
            if err := vm_compare(vm, .GT); err != nil do return err

        case .GTE:
            if err := vm_compare(vm, .GTE); err != nil do return err

        case .NOT:
            a, err := vm_pop(vm)
            if err != nil do return err
            if err := vm_push(vm, is_falsy(a)); err != nil do return err

        case .POP:
            _, err := vm_pop(vm)
            if err != nil do return err

        case .PRINT:
            a, err := vm_pop(vm)
            if err != nil do return err
            print_value(a)
            fmt.println()

        case .INPUT:
            prompt, err := vm_pop(vm)
            if err != nil do return err
            if s, ok := prompt.(string); ok && len(s) > 0 {
                fmt.printf("%s", s)
            }
            line := read_line(vm.stdin)
            vm_push(vm, line)

        case .DEFINE_GLOBAL:
            name := read_constant(vm).(string)
            top, _ := vm_peek(vm)
            vm.globals[name] = top
            vm_pop(vm)

        case .GET_GLOBAL:
            name := read_constant(vm).(string)
            val, ok := vm.globals[name]
            if !ok do return .UNDEFINED_VARIABLE
            if err := vm_push(vm, val); err != nil do return err

        case .SET_GLOBAL:
            name := read_constant(vm).(string)
            if !(name in vm.globals) do return .UNDEFINED_VARIABLE
            top, _ := vm_peek(vm)
            vm.globals[name] = top

        case .GET_LOCAL:
            slot := u16(read_byte(vm))
            frame := current_frame(vm)
            if err := vm_push(vm, vm.stack[frame.slots + slot]); err != nil do return err

        case .SET_LOCAL:
            slot := u16(read_byte(vm))
            frame := current_frame(vm)
            top, _ := vm_peek(vm)
            vm.stack[frame.slots + slot] = top

        // --- control flow ---
        case .JUMP:
            offset := read_short(vm)
            current_frame(vm).ip += int(offset)

        case .JUMP_IF_FALSE:
            offset := read_short(vm)
            top, _ := vm_peek(vm)
            if is_falsy(top) {
                current_frame(vm).ip += int(offset)
            }

        case .JUMP_IF_TRUE:
            offset := read_short(vm)
            top, _ := vm_peek(vm)
            if !is_falsy(top) {
                current_frame(vm).ip += int(offset)
            }

        case .LOOP:
            offset := read_short(vm)
            current_frame(vm).ip -= int(offset)

        case .CALL:
            arg_count := u16(read_byte(vm))
            if err := vm_call(vm, arg_count); err != nil do return err

        case .RETURN:
            result, err := vm_pop(vm)
            if err != nil do return err

            vm.frame_count -= 1
            if vm.frame_count == 0 {
                vm.stack[0] = result
                vm.stack_top = 1
                return nil
            }

            frame := &vm.frames[vm.frame_count]
            vm.stack_top = frame.slots

            if err := vm_push(vm, result); err != nil do return err
        }
    }
}

is_falsy :: proc(val: Value) -> bool {
    switch v in val {
    case bool:   return !v
    case Nil:    return true
    case i64:    return false
    case f64:    return false
    case string: return false
    case ^Function: return false
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
    case i64:       fmt.printf("%d", v)
    case f64:       fmt.printf("%g", v)
    case bool:      fmt.printf("%t", v)
    case string:    fmt.printf("%s", v)
    case Nil:       fmt.printf("nil")
    case ^Function: fmt.printf("<fn %s>", v.name)
    }
}

vm_binary_op :: proc(vm: ^VM, op: Opcode) -> Maybe(VMError) {
    b, err1 := vm_pop(vm)
    if err1 != nil do return err1
    a, err2 := vm_pop(vm)
    if err2 != nil do return err2
    #partial switch av in a {
    case i64:
        bv, ok := b.(i64)
        if !ok do return .TYPE_ERROR
        #partial switch op {
        case .SUB: return vm_push(vm, av - bv)
        case .MUL: return vm_push(vm, av * bv)
        case .DIV:
            if bv == 0 do return .DIVISION_BY_ZERO
            return vm_push(vm, av / bv)
        case .MOD:
            if bv == 0 do return .DIVISION_BY_ZERO
            return vm_push(vm, av % bv)
        }
    case f64:
        bv, ok := b.(f64)
        if !ok do return .TYPE_ERROR
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
        bv, ok := b.(i64)
        if !ok do return .TYPE_ERROR
        #partial switch op {
        case .LT:  return vm_push(vm, av < bv)
        case .LTE: return vm_push(vm, av <= bv)
        case .GT:  return vm_push(vm, av > bv)
        case .GTE: return vm_push(vm, av >= bv)
        }
    case f64:
        bv, ok := b.(f64)
        if !ok do return .TYPE_ERROR
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

vm_interpret :: proc(vm: ^VM, fn: ^Function) -> Maybe(VMError) {
    vm_push(vm, Value(fn))

    frame := &vm.frames[0]
    vm.frame_count = 1
    frame.function = fn
    frame.ip       = 0
    frame.slots    = 0

    return vm_run(vm)
}
