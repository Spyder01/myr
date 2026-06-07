package bytecode

import "../../lexer"

Nil :: struct{}

Value :: union {
	i64,
	f64,
	bool,
	string,
	Nil,
	^Function,
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

	NEW,       // 1-byte: N  — pop N values, heap-alloc slice, push ^Value base
	HEAP_GET,  // 1-byte: offset — pop ^Value, push ptr[offset]
	HEAP_SET,  // 1-byte: offset — pop ^Value (top), ptr[offset] = stack_top below it
	HEAP_LOAD, // 1-byte: N  — pop ^Value, push ptr[0..N-1] (full deref)

	POP,
	PRINT,
	INPUT,

	// Superinstructions (peephole-fused, not yet wired in VM)
	NOP,
	ADD_LOCALS,
	MUL_LOCALS,
	LT_LOCAL_CONST,
	LTE_LOCAL_CONST,
	SUB_LOCAL_CONST,
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
    case i64:       if bv, ok := b.(i64);    ok do return av == bv
    case f64:       if bv, ok := b.(f64);    ok do return av == bv
    case bool:      if bv, ok := b.(bool);   ok do return av == bv
    case string:    if bv, ok := b.(string); ok do return av == bv
    case Nil:       _, ok := b.(Nil);            return ok
    case ^Function: return false
    case [^]Value:  if bv, ok := b.([^]Value); ok do return av == bv
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

