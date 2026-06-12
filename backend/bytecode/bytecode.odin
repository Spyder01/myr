package bytecode

import "../../lexer"

Nil :: struct{}

// FnRef is a function-table index. It replaces raw ^Function pointers in
// runtime values so bytecode is position-independent and serialisable.
FnRef :: distinct u16

Value :: union {
	i64,
	f64,
	bool,
	string,
	Nil,
	FnRef,
	[^]Value, // heap pointer: base of a contiguous heap-allocated Value slice
}

Opcode :: enum u8 {
	CONST,
	CONST_LONG,
	NIL,
	TRUE,
	FALSE,

	ADD,
	SUB,
	MUL,
	DIV,
	MOD,
	NEGATE,
	SHL,
	SHR,
	BAND,
	BOR,
	BXOR,
	BNOT,

	EQ,
	NEQ,
	LT,
	LTE,
	GT,
	GTE,
	NOT,

	DEFINE_GLOBAL,
	SET_GLOBAL,
	GET_GLOBAL,
	GET_LOCAL,
	SET_LOCAL,

	JUMP,
	JUMP_IF_FALSE,
	JUMP_IF_TRUE,
	LOOP,

	CALL,
	RETURN,

	NEW,        // 1-byte: N  — pop N values, heap-alloc slice, push ^Value base
	HEAP_GET,   // 1-byte: offset — pop ^Value, push ptr[offset]
	HEAP_SET,   // 1-byte: offset — pop ^Value (top), ptr[offset] = stack_top below it
	HEAP_LOAD,  // 1-byte: N  — pop ^Value, push ptr[0..N-1] (full deref)
	ADDR_LOCAL, // 1-byte: slot — push a raw pointer to frame[slot] (stack reference)
	ARRAY_GET,            // 2-bytes: base_slot, elem_slots — pop index i, push frame[base_slot + i*elem_slots .. +elem_slots]
	ARRAY_SET,            // 2-bytes: base_slot, elem_slots — pop index i and elem_slots values, write frame[base_slot + i*elem_slots]
	ARRAY_GET_STACK,      // 2-bytes: total_slots, elem_slots — pop index and total_slots array from stack, push elem_slots element
	ARRAY_SET_CHAINED,    // 3-bytes: base_slot, outer_elem_slots, inner_elem_slots — stack: [val(inner_elem_slots), i, j] write frame[base_slot + i*outer + j*inner]
	MAKE_SLICE,      // 1-byte: elem_slots — pop grow_factor, pop cap, alloc heap, push [ptr, len=0, cap, grow_factor]
	SLICE_GET,       // 1-byte: elem_slots — pop index, pop ptr, push ptr[i*elem_slots .. +elem_slots]
	SLICE_SET,       // 2-bytes: base_slot, elem_slots — pop index, grow if needed (doubling), write frame[base_slot]..+elem_slots (peek, leave val)
	SLICE_GET_STACK, // 1-byte: elem_slots — pop index, pop Slice (ptr len cap gf) from stack, push ptr[i*elem_slots .. +elem_slots]
	STR_LEN,    // no operands — pop string, push i64 byte-length
	STR_GET,    // no operands — pop index (i64), pop string, push byte at index as i64

	POP,
	PRINT,
	INPUT,

	// Superinstructions — peephole-fused
	NOP,

	// binary op with two locals (3 bytes: a b)
	ADD_LOCALS, MUL_LOCALS, SUB_LOCALS, DIV_LOCALS, MOD_LOCALS,
	LT_LOCALS, LTE_LOCALS, GT_LOCALS, GTE_LOCALS,

	// binary op with local and constant (4 bytes: slot hi lo)
	LT_LOCAL_CONST, LTE_LOCAL_CONST, SUB_LOCAL_CONST,
	GT_LOCAL_CONST, GTE_LOCAL_CONST, EQ_LOCAL_CONST,

	// in-place increment/decrement of a local (2 bytes: slot) — no stack traffic
	INC_LOCAL,
	DEC_LOCAL,

	// combined conditional jump + unconditional pop (3 bytes: hi lo)
	JUMP_IF_FALSE_POP,
	JUMP_IF_TRUE_POP,

	// store and discard: SET_LOCAL + POP fused (2 bytes: slot)
	SET_LOCAL_POP,

	// push a function ref by table index: LOAD_FN hi lo (3 bytes)
	LOAD_FN,

	// return without a push: GET_LOCAL s; RETURN n → RETURN_LOCAL s n (3 bytes: slot n)
	RETURN_LOCAL,
	// return a constant: CONST c; RETURN n → RETURN_CONST c n (3 bytes: const_idx n)
	RETURN_CONST,

	// GET_LOCAL a; GET_LOCAL b; MOD_I64; CONST 0; EQ → MOD_LOCAL_LOCAL_EQ_ZERO a b (3 bytes)
	MOD_LOCAL_LOCAL_EQ_ZERO,

	// GET_LOCAL s; GET_LOCAL s; MUL_I64 → SQUARE_I64 s (2 bytes)
	SQUARE_I64,
	// GET_LOCAL s; GET_LOCAL s; MUL_F64 → SQUARE_F64 s (2 bytes)
	SQUARE_F64,

	// NIL; EQ → NIL_EQ (1 byte): in-place nil check on top of stack
	NIL_EQ,
	// NIL; NEQ → NIL_NEQ (1 byte): in-place non-nil check on top of stack
	NIL_NEQ,

	// Type-specific arithmetic — emitted when both operands have a known type.
	// Skips the union switch in the VM handler.
	ADD_I64, SUB_I64, MUL_I64, DIV_I64, MOD_I64,
	ADD_F64, SUB_F64, MUL_F64, DIV_F64,
	ADD_STR,
	LT_I64, LTE_I64, GT_I64, GTE_I64,
	LT_F64, LTE_F64, GT_F64, GTE_F64,
	NEGATE_I64, NEGATE_F64,
}


Chunk :: struct {
    code:      [dynamic]u8,
    constants: [dynamic]Value,
    spans:     [dynamic]lexer.Span,
}

new_chunk :: proc() -> Chunk {
    return Chunk{
        code      = make([dynamic]u8),
        constants = make([dynamic]Value),
        spans     = make([dynamic]lexer.Span),
    }
}

chunk_write :: proc(chunk: ^Chunk, byte: u8, span: lexer.Span) -> Maybe(ByteCodeCompilerError) {
    if len(chunk.code) >= MAX_CODE_COUNT do return .TOO_MANY_OP_CODE
    append(&chunk.code, byte)
    append(&chunk.spans, span)
    return nil
}

values_equal :: proc(a, b: Value) -> bool {
    switch av in a {
    case i64:    if bv, ok := b.(i64);    ok do return av == bv
    case f64:    if bv, ok := b.(f64);    ok do return av == bv
    case bool:   if bv, ok := b.(bool);   ok do return av == bv
    case string: if bv, ok := b.(string); ok do return av == bv
    case Nil:    _, ok := b.(Nil);            return ok
    case FnRef:  if bv, ok := b.(FnRef);  ok do return av == bv
    case [^]Value: if bv, ok := b.([^]Value); ok do return av == bv
    }
    return false
}

chunk_add_constant :: proc(chunk: ^Chunk, val: Value) -> (u16, Maybe(ByteCodeCompilerError)) {
    for constant, i in chunk.constants {
        if values_equal(constant, val) do return u16(i), nil
    }
    if len(chunk.constants) >= MAX_CONSTANT_COUNT do return 0, .TOO_MANY_CONSTANTS
    append(&chunk.constants, val)
    return u16(len(chunk.constants) - 1), nil
}

chunk_free :: proc(c: ^Chunk) {
    delete(c.code)
    delete(c.constants)
    delete(c.spans)
}

Function :: struct {
	chunk: Chunk,
	name:  string,
	arity: u8,
}

new_function :: proc(name: string, arity: u8) -> ^Function {
	fn := new(Function)
	fn.name  = name
	fn.arity = arity
	fn.chunk = new_chunk()
	return fn
}

function_free :: proc(fn: ^Function) {
	chunk_free(&fn.chunk)
	free(fn)
}

// Module is the compilation unit: a flat table of all functions.
// Index 0 is always the top-level __main__ entry point.
Module :: struct {
	functions: [dynamic]^Function,
}

new_module :: proc() -> ^Module {
	m := new(Module)
	m.functions = make([dynamic]^Function)
	return m
}

module_free :: proc(m: ^Module) {
	for fn in m.functions {
		if fn != nil { function_free(fn) }
	}
	delete(m.functions)
	free(m)
}

