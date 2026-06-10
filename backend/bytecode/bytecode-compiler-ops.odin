package bytecode

import "../../lexer"

ByteCodeCompilerError :: enum u8 {
    TOO_MANY_CONSTANTS,
    TOO_MANY_LOCAL_VARIABLES,
    TOO_MANY_OP_CODE,
    SCOPE_DEPTH_BREACHED,
}

Local :: struct {
    name:             string,
    depth:            u8,
    slots:            int,    // 1 for scalars/pointers, N for flat structs/enums, N*elem_slots for arrays, 3 for slices
    struct_type:      string, // "" for scalars/pointers/enums, struct name for flat struct locals
    ptr_inner:        string, // "" unless this is a ^T pointer local; stores "T"
    enum_type:        string, // "" unless this is a flat enum local; stores enum name
    array_elem_slots: int,    // 0 = not an array; >0 = slots per element
    slice_elem_slots: int,    // 0 = not a slice; >0 = slots per element (local occupies 3 slots: ptr, len, cap)
}

ByteCodeCompiler :: struct {
    function:    ^Function,          
    parent:      ^ByteCodeCompiler,  
    locals:      [dynamic]Local,
    scope_depth: u8,
}

new_bytecode_compiler :: proc(name: string, arity: u8, parent: ^ByteCodeCompiler = nil) -> ByteCodeCompiler {
    return ByteCodeCompiler{
        function = new_function(name, arity),
        parent   = parent,
        locals   = make([dynamic]Local),
    }
}

// success path — caller takes ownership of the function, compiler is invalidated
compiler_end :: proc(bc: ^ByteCodeCompiler) -> ^Function {
    fn := bc.function
    bc.function = nil
    delete(bc.locals)
    return fn
}

// error path — frees everything, safe to call even after compiler_end (function is nil)
compiler_free :: proc(bc: ^ByteCodeCompiler) {
    if bc.function != nil {
        function_free(bc.function)
        bc.function = nil
    }
    delete(bc.locals)
}

current_chunk :: proc(bc: ^ByteCodeCompiler) -> ^Chunk {
    return &bc.function.chunk
}

add_local :: proc(compiler: ^ByteCodeCompiler, name: string, slots: int = 1, struct_type: string = "", ptr_inner: string = "", enum_type: string = "", array_elem_slots: int = 0, slice_elem_slots: int = 0) -> Maybe(ByteCodeCompilerError) {
    if len(compiler.locals) >= MAX_LOCAL_VARIABLE_COUNT do return .TOO_MANY_LOCAL_VARIABLES
    append(&compiler.locals, Local{name = name, depth = compiler.scope_depth, slots = slots, struct_type = struct_type, ptr_inner = ptr_inner, enum_type = enum_type, array_elem_slots = array_elem_slots, slice_elem_slots = slice_elem_slots})
    return nil
}

emit_byte :: proc(compiler: ^ByteCodeCompiler, byte: u8, span: lexer.Span) -> Maybe(ByteCodeCompilerError) {
    return chunk_write(current_chunk(compiler), byte, span)
}

emit :: proc(compiler: ^ByteCodeCompiler, op_code: Opcode, span: lexer.Span) -> Maybe(ByteCodeCompilerError) {
    return emit_byte(compiler, u8(op_code), span)
}

emit_constant :: proc(compiler: ^ByteCodeCompiler, constant: Value, span: lexer.Span) -> Maybe(ByteCodeCompilerError) {
    idx, err := chunk_add_constant(current_chunk(compiler), constant)
    if err != nil do return err
    if idx <= 0xFF {
        if err = emit(compiler, .CONST, span); err != nil do return err
        if err = emit_byte(compiler, u8(idx), span); err != nil do return err
    } else {
        if err = emit(compiler, .CONST_LONG, span); err != nil do return err
        if err = emit_byte(compiler, u8(idx >> 8), span); err != nil do return err
        if err = emit_byte(compiler, u8(idx & 0xFF), span); err != nil do return err
    }
    return nil
}

emit_jump :: proc(compiler: ^ByteCodeCompiler, op: Opcode, span: lexer.Span) -> (u16, Maybe(ByteCodeCompilerError)) {
    if err, has_err := emit(compiler, op, span).?; has_err do return 0, err
    if err, has_err := emit_byte(compiler, PLACEHOLDER_BYTE_HI, span).?; has_err do return 0, err
    if err, has_err := emit_byte(compiler, PLACEHOLDER_BYTE_LO, span).?; has_err do return 0, err
    return u16(len(current_chunk(compiler).code)) - 2, nil
}

patch_jump :: proc(compiler: ^ByteCodeCompiler, offset: u16) -> Maybe(ByteCodeCompilerError) {
    jump := int(len(current_chunk(compiler).code)) - int(offset) - 2
    if jump < 0 || jump > MAX_CODE_COUNT do return .TOO_MANY_OP_CODE
    current_chunk(compiler).code[offset]     = u8(u16(jump) >> 8)
    current_chunk(compiler).code[offset + 1] = u8(u16(jump) & 0xFF)
    return nil
}

emit_loop :: proc(compiler: ^ByteCodeCompiler, loop_start: u16, span: lexer.Span) -> Maybe(ByteCodeCompilerError) {
    if err, has_err := emit(compiler, .LOOP, span).?; has_err do return err
    offset := int(len(current_chunk(compiler).code)) - int(loop_start) + 2
    if offset > MAX_CODE_COUNT do return .TOO_MANY_OP_CODE
    if err, has_err := emit_byte(compiler, u8(u16(offset) >> 8), span).?; has_err do return err
    if err, has_err := emit_byte(compiler, u8(u16(offset) & 0xFF), span).?; has_err do return err
    return nil
}
