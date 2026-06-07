package bytecode

import "../../parser"
import "../../lexer"
import "core:strconv"
import "core:fmt"
import "core:strings"

CompilerError :: struct {
	message: string,
	span:    lexer.Span,
}

LoopCtx :: struct {
	start:       u16,                  // bytecode offset of the condition (for continue)
	local_base:  int,                  // len(locals) at loop entry (for emit POPs on break/continue)
	breaks:      [MAX_BREAK_COUNT]u16, // JUMP offsets waiting to be patched to after the loop
	break_count: u8,
}

StructLayout :: struct {
	field_names:        []string,
	field_offsets:      []int,
	field_struct_types: []string, // "" for scalars/pointers, struct name for flat struct fields
	field_ptr_inners:   []string, // "" for non-pointers, "T" for ^T pointer fields
	total_slots:        int,
}

Compiler :: struct {
	bc:             ByteCodeCompiler,
	ast:            ^parser.AST,
	errors:         [MAX_ERROR_COUNT]CompilerError,
	error_count:    u8,
	loop_ctx:       ^LoopCtx,
	const_table:    map[string]Value,
	struct_layouts: map[string]StructLayout,
}

new_compiler :: proc(ast: ^parser.AST) -> Compiler {
	return Compiler{
		bc             = new_bytecode_compiler("__main__", 0),
		ast            = ast,
		const_table    = make(map[string]Value),
		struct_layouts = make(map[string]StructLayout),
	}
}

compiler_destroy :: proc(c: ^Compiler) {
	compiler_free(&c.bc)
	delete(c.const_table)
}

compile :: proc(ast: ^parser.AST) -> (^Function, []CompilerError) {
	c := new_compiler(ast)

	// Two-pass struct layout building: the first pass registers all struct names
	// so the second pass can correctly resolve forward references (e.g. Monkey
	// referencing Person which is declared after it).
	for _ in 0 ..= 1 {
		for node in ast.nodes {
			if decl, ok := node.(parser.Declaration); ok {
				if sd, ok2 := decl.(parser.StructDecl); ok2 {
					c.struct_layouts[sd.name.data] = build_struct_layout(&c, sd)
				}
			}
		}
	}

	for node, i in ast.nodes {
		if _, is_decl := node.(parser.Declaration); is_decl {
			compile_decl(&c, parser.DeclarationIdx(i))
		}
	}

	// call main — leave its return value on the stack so __main__ returns it
	main_idx, main_err := chunk_add_constant(current_chunk(&c.bc), "main")
	if main_err == nil {
		emit(&c.bc, .GET_GLOBAL, {})
		emit_byte(&c.bc, u8(main_idx), {})
		emit(&c.bc, .CALL, {})
		emit_byte(&c.bc, 0, {})
		// no POP — __main__'s RETURN will pop and store it at stack[0]
	} else {
		emit(&c.bc, .NIL, {})
	}

	emit(&c.bc, .RETURN, {})
	emit_byte(&c.bc, 1, {})

	errors := c.errors[:c.error_count]
	if c.error_count > 0 {
		fn := compiler_end(&c.bc)
		function_free(fn)
		return nil, errors
	}

	return compiler_end(&c.bc), errors
}

// ---- declarations ----

compile_decl :: proc(c: ^Compiler, idx: parser.DeclarationIdx) {
	node := c.ast.nodes[idx]
	span := c.ast.spans[idx]

	switch d in node.(parser.Declaration) {
	case parser.FunctionDecl:
		compile_function(c, d, span)
	case parser.ConstDecl:
		if val, ok := eval_const_expr(c, d.value, span); ok {
			c.const_table[d.name.data] = val
		}
	case parser.ImportDecl:
		// skip for now
	case parser.StructDecl:
		layout := build_struct_layout(c, d)
		c.struct_layouts[d.name.data] = layout
	case parser.EnumDecl:
	}
}

compile_function :: proc(c: ^Compiler, d: parser.FunctionDecl, span: lexer.Span) {
	// Compute total slot count for arity: a struct param occupies N slots.
	total_param_slots := 0
	for param in d.params {
		struct_name := type_ann_struct_name(c, param.type)
		slots := 1
		if struct_name != "" {
			if layout, ok := c.struct_layouts[struct_name]; ok {
				slots = layout.total_slots
			}
		}
		total_param_slots += slots
	}

	// create a child compiler for this function
	fn_compiler := new_bytecode_compiler(d.name.data, u8(total_param_slots), &c.bc)

	// slot 0 is the function itself (allows recursion, matches VM frame layout)
	add_local(&fn_compiler, d.name.data)
	// parameters start at slot 1; register each with its actual slot count
	for param in d.params {
		struct_name := type_ann_struct_name(c, param.type)
		ptr_inner   := type_ann_ptr_inner(c, param.type)
		slots := 1
		if struct_name != "" {
			if layout, ok := c.struct_layouts[struct_name]; ok {
				slots = layout.total_slots
			}
		}
		add_local(&fn_compiler, param.name.data, slots, struct_name, ptr_inner)
	}

	// compile body
	child := Compiler{bc = fn_compiler, ast = c.ast, errors = c.errors, error_count = c.error_count, const_table = c.const_table, struct_layouts = c.struct_layouts}
	compile_block(&child, d.body)
	emit(&child.bc, .RETURN, span)
	emit_byte(&child.bc, 1, span)
	c.errors      = child.errors
	c.error_count = child.error_count

	// get compiled function
	fn := compiler_end(&child.bc)

	// emit function as a constant in parent, bind to name
	emit_constant(&c.bc, fn, span)
	name_idx, _ := chunk_add_constant(current_chunk(&c.bc), d.name.data)
	emit(&c.bc, .DEFINE_GLOBAL, span)
	emit_byte(&c.bc, u8(name_idx), span)
}

// ---- blocks ----

compile_block :: proc(c: ^Compiler, block: parser.BlockExpression) {
	c.bc.scope_depth += 1
	for stmt in block.stmts {
		compile_stmt(c, stmt)
	}
	if result, ok := block.result.?; ok {
		compile_expr(c, result)
	}
	end_scope(c)
}

end_scope :: proc(c: ^Compiler) {
	c.bc.scope_depth -= 1
	for len(c.bc.locals) > 0 &&
	    c.bc.locals[len(c.bc.locals)-1].depth > c.bc.scope_depth {
		local := c.bc.locals[len(c.bc.locals)-1]
		for _ in 0..<local.slots {
			emit(&c.bc, .POP, {})
		}
		pop(&c.bc.locals)
	}
}

// ---- statements ----

compile_stmt :: proc(c: ^Compiler, idx: parser.StatementIdx) {
	node := c.ast.nodes[idx]
	span := c.ast.spans[idx]

	switch s in node.(parser.Statement) {
	case parser.ConstStatement:
		if val, ok := eval_const_expr(c, s.value, span); ok {
			c.const_table[s.name.data] = val
		}

	case parser.LetStatement:
		compile_expr(c, s.value)
		if c.bc.scope_depth == 0 {
			name_idx, _ := chunk_add_constant(current_chunk(&c.bc), s.name.data)
			emit(&c.bc, .DEFINE_GLOBAL, span)
			emit_byte(&c.bc, u8(name_idx), span)
		} else {
			struct_type := expr_struct_type(c, s.value)
			ptr_inner   := expr_ptr_inner(c, s.value)
			if struct_type == "" && ptr_inner == "" {
				if ann_idx, has_ann := s.type.?; has_ann {
					struct_type = type_ann_struct_name(c, ann_idx)
					ptr_inner   = type_ann_ptr_inner(c, ann_idx)
				}
			}
			slots := 1
			if struct_type != "" {
				if layout, ok := c.struct_layouts[struct_type]; ok {
					slots = layout.total_slots
				}
			}
			add_local(&c.bc, s.name.data, slots, struct_type, ptr_inner)
		}

	case parser.ReturnStatement:
		if val, ok := s.value.?; ok {
			compile_expr(c, val)
			emit(&c.bc, .RETURN, span)
			emit_byte(&c.bc, u8(expr_slot_count(c, val)), span)
		} else {
			emit(&c.bc, .NIL, span)
			emit(&c.bc, .RETURN, span)
			emit_byte(&c.bc, 1, span)
		}

	case parser.ExpressionStatement:
		compile_expr(c, s.expr)
		n := expr_slot_count(c, s.expr)
		for _ in 0..<n {
			emit(&c.bc, .POP, span)
		}

	case parser.ForStatement:
		compile_for(c, s, span)

	case parser.BreakStatement:
		if c.loop_ctx == nil {
			compiler_error(c, "break outside of loop", span)
			return
		}
		n := 0
		for i in c.loop_ctx.local_base..<len(c.bc.locals) {
			n += c.bc.locals[i].slots
		}
		for _ in 0..<n { emit(&c.bc, .POP, span) }
		if c.loop_ctx.break_count >= MAX_BREAK_COUNT {
			compiler_error(c, "too many break statements in one loop", span)
			return
		}
		jmp, _ := emit_jump(&c.bc, .JUMP, span)
		c.loop_ctx.breaks[c.loop_ctx.break_count] = jmp
		c.loop_ctx.break_count += 1

	case parser.ContinueStatement:
		if c.loop_ctx == nil {
			compiler_error(c, "continue outside of loop", span)
			return
		}
		n := 0
		for i in c.loop_ctx.local_base..<len(c.bc.locals) {
			n += c.bc.locals[i].slots
		}
		for _ in 0..<n { emit(&c.bc, .POP, span) }
		emit_loop(&c.bc, c.loop_ctx.start, span)

	case parser.WithContextStatement:
		// TODO
	}
}

compile_for :: proc(c: ^Compiler, s: parser.ForStatement, span: lexer.Span) {
	// compile init once before loop_start so the variable exists for the condition
	has_init := false
	if init, ok := s.init.?; ok {
		has_init = true
		c.bc.scope_depth += 1
		compile_stmt(c, init)
	}

	loop_start := u16(len(current_chunk(&c.bc).code))

	// local_base is after init — break/continue pop body locals only;
	// the init local is cleaned up separately after the loop
	ctx := LoopCtx{
		start      = loop_start,
		local_base = len(c.bc.locals),
	}
	outer_ctx  := c.loop_ctx
	c.loop_ctx  = &ctx

	exit_jump: u16 = 0
	has_condition := false

	if cond, ok := s.condition.?; ok {
		has_condition = true
		compile_expr(c, cond)
		exit_jump, _ = emit_jump(&c.bc, .JUMP_IF_FALSE, span)
		emit(&c.bc, .POP, span)
	}

	compile_block(c, s.body)

	if post, ok := s.post.?; ok {
		compile_stmt(c, post)
		// ExpressionStatement already emits POP — no extra POP needed
	}

	emit_loop(&c.bc, loop_start, span)

	if has_condition {
		patch_jump(&c.bc, exit_jump)
		emit(&c.bc, .POP, span)
	}

	// break jumps land here — after the condition POP, before init cleanup
	for i in 0..<int(ctx.break_count) {
		patch_jump(&c.bc, ctx.breaks[i])
	}
	c.loop_ctx = outer_ctx

	// close the init scope so the loop variable doesn't outlive the loop
	if has_init {
		c.bc.scope_depth -= 1
		for len(c.bc.locals) > 0 &&
		    c.bc.locals[len(c.bc.locals)-1].depth > c.bc.scope_depth {
			local := c.bc.locals[len(c.bc.locals)-1]
			for _ in 0..<local.slots {
				emit(&c.bc, .POP, span)
			}
			pop(&c.bc.locals)
		}
	}
}

// ---- expressions ----

compile_expr :: proc(c: ^Compiler, idx: parser.ExpressionIdx) {
	node := c.ast.nodes[idx]
	span := c.ast.spans[idx]

	switch e in node.(parser.Expression) {
	case parser.LiteralExpression:
		tok := lexer.Token(e)
		if tok.kind == .NIL {
			emit(&c.bc, .NIL, span)
			return
		}
		val := parse_literal(tok)
		emit_constant(&c.bc, val, span)

	case parser.IdentExpression:
		tok := lexer.Token(e)
		name := tok.data
		// const table is checked first — inlined as an immediate value
		if val, ok := c.const_table[name]; ok {
			emit_constant(&c.bc, val, span)
			return
		}
		// check locals first (inner → outer)
		slot, slots, found := resolve_local(&c.bc, name)
		if found {
			for s in 0..<slots {
				emit(&c.bc, .GET_LOCAL, span)
				emit_byte(&c.bc, u8(slot + s), span)
			}
		} else {
			name_idx, _ := chunk_add_constant(current_chunk(&c.bc), name)
			emit(&c.bc, .GET_GLOBAL, span)
			emit_byte(&c.bc, u8(name_idx), span)
		}

	case parser.UnaryExpression:
		compile_expr(c, e.operand)
		#partial switch e.op.kind {
		case .MINUS: emit(&c.bc, .NEGATE, span)
		case .BANG:  emit(&c.bc, .NOT, span)
		case .TILDE: emit(&c.bc, .BNOT, span)
		}

	case parser.BinaryExpression:
		// assignment is special
		if e.operation.kind == .EQ {
			compile_assignment(c, e, span)
			return
		}
		if e.operation.kind == .PLUS_EQ  || e.operation.kind == .MINUS_EQ ||
		   e.operation.kind == .STAR_EQ  || e.operation.kind == .SLASH_EQ ||
		   e.operation.kind == .PERCENT_EQ {
			compile_compound_assignment(c, e, span)
			return
		}
		// short-circuit logical operators
		if e.operation.kind == .AND {
			compile_expr(c, e.left)
			jump, _ := emit_jump(&c.bc, .JUMP_IF_FALSE, span)
			emit(&c.bc, .POP, span)
			compile_expr(c, e.right)
			patch_jump(&c.bc, jump)
			return
		}
		if e.operation.kind == .OR {
			compile_expr(c, e.left)
			jump, _ := emit_jump(&c.bc, .JUMP_IF_TRUE, span)
			emit(&c.bc, .POP, span)
			compile_expr(c, e.right)
			patch_jump(&c.bc, jump)
			return
		}
		compile_expr(c, e.left)
		compile_expr(c, e.right)
		emit(&c.bc, op_to_opcode(e.operation.kind), span)

	case parser.CallExpression:
		// check for print builtin
		callee_node := c.ast.nodes[e.callee]
		if expr, ok := callee_node.(parser.Expression); ok {
			if id, ok2 := expr.(parser.IdentExpression); ok2 {
				switch lexer.Token(id).data {
				case "print":
					for arg in e.args {
						compile_expr(c, arg)
						emit(&c.bc, .PRINT, span)
					}
					emit(&c.bc, .NIL, span)
					return
				case "input":
					// emit prompt (empty string if no argument given)
					if len(e.args) > 0 {
						compile_expr(c, e.args[0])
					} else {
						emit_constant(&c.bc, "", span)
					}
					emit(&c.bc, .INPUT, span)
					return
				}
			}
		}
		compile_expr(c, e.callee)
		total_arg_slots := 0
		for arg in e.args {
			compile_expr(c, arg)
			total_arg_slots += expr_slot_count(c, arg)
		}
		emit(&c.bc, .CALL, span)
		emit_byte(&c.bc, u8(total_arg_slots), span)

	case parser.IfExpression:
		compile_if(c, e, span)

	case parser.BlockExpression:
		compile_block(c, e)

	case parser.FieldAccessExpression:
		compile_field_access(c, e, span)

	case parser.StructLiteralExpression:
		compile_struct_literal(c, e, span)

	case parser.NewExpression:
		compile_new_expr(c, e, span)

	case parser.DerefExpression:
		compile_deref_expr(c, e, span)

	case parser.IndexExpression, parser.MatchExpression:
		compiler_error(c, "not yet implemented", span)
	}
}

compile_compound_assignment :: proc(c: ^Compiler, e: parser.BinaryExpression, span: lexer.Span) {
	op: Opcode
	#partial switch e.operation.kind {
	case .PLUS_EQ:    op = .ADD
	case .MINUS_EQ:   op = .SUB
	case .STAR_EQ:    op = .MUL
	case .SLASH_EQ:   op = .DIV
	case .PERCENT_EQ: op = .MOD
	}

	lhs_node := c.ast.nodes[e.left]
	lhs_expr, is_expr := lhs_node.(parser.Expression)
	if !is_expr { compiler_error(c, "invalid compound assignment target", span); return }

	#partial switch lhs in lhs_expr {
	case parser.IdentExpression:
		name := lexer.Token(lhs).data
		slot, _, found := resolve_local(&c.bc, name)
		if found {
			emit(&c.bc, .GET_LOCAL, span)
			emit_byte(&c.bc, u8(slot), span)
		} else {
			name_idx, _ := chunk_add_constant(current_chunk(&c.bc), name)
			emit(&c.bc, .GET_GLOBAL, span)
			emit_byte(&c.bc, u8(name_idx), span)
		}
		compile_expr(c, e.right)
		emit(&c.bc, op, span)
		if found {
			emit(&c.bc, .SET_LOCAL, span)
			emit_byte(&c.bc, u8(slot), span)
		} else {
			name_idx, _ := chunk_add_constant(current_chunk(&c.bc), name)
			emit(&c.bc, .SET_GLOBAL, span)
			emit_byte(&c.bc, u8(name_idx), span)
		}

	case parser.FieldAccessExpression:
		base_slot, heap_offset, parent_type, chain_ok := resolve_access_chain(c, lhs.object)
		if chain_ok && parent_type != "" {
			layout, has_layout := c.struct_layouts[parent_type]
			if !has_layout { compiler_error(c, "compound assignment on non-struct field", span); return }
			field_offset, _, _, _, field_found := find_field(layout, lhs.field.data)
			if !field_found { compiler_error(c, fmt.tprintf("unknown field '%s'", lhs.field.data), span); return }
			if heap_offset >= 0 {
				abs_heap := heap_offset + field_offset
				emit(&c.bc, .GET_LOCAL, span)
				emit_byte(&c.bc, u8(base_slot), span)
				emit(&c.bc, .HEAP_GET, span)
				emit_byte(&c.bc, u8(abs_heap), span)
				compile_expr(c, e.right)
				emit(&c.bc, op, span)
				emit(&c.bc, .GET_LOCAL, span)
				emit_byte(&c.bc, u8(base_slot), span)
				emit(&c.bc, .HEAP_SET, span)
				emit_byte(&c.bc, u8(abs_heap), span)
			} else {
				abs_slot := base_slot + field_offset
				emit(&c.bc, .GET_LOCAL, span)
				emit_byte(&c.bc, u8(abs_slot), span)
				compile_expr(c, e.right)
				emit(&c.bc, op, span)
				emit(&c.bc, .SET_LOCAL, span)
				emit_byte(&c.bc, u8(abs_slot), span)
			}
		} else {
			// Fallback: chain passes through a pointer-typed field.
			// GET: emit ptr, HEAP_GET field; apply op; SET: emit ptr again, HEAP_SET field.
			heap_base1, container_type, ok1 := compile_ptr_to_container(c, lhs.object, span)
			if !ok1 { compiler_error(c, "invalid compound assignment target", span); return }
			layout, has := c.struct_layouts[container_type]
			if !has { compiler_error(c, "compound assignment on non-struct field", span); return }
			field_offset, _, _, _, field_found := find_field(layout, lhs.field.data)
			if !field_found { compiler_error(c, fmt.tprintf("unknown field '%s'", lhs.field.data), span); return }
			abs_heap := heap_base1 + field_offset
			emit(&c.bc, .HEAP_GET, span)
			emit_byte(&c.bc, u8(abs_heap), span)
			compile_expr(c, e.right)
			emit(&c.bc, op, span)
			// Re-acquire the ptr for HEAP_SET.
			heap_base2, _, ok2 := compile_ptr_to_container(c, lhs.object, span)
			if !ok2 { compiler_error(c, "invalid compound assignment target", span); return }
			emit(&c.bc, .HEAP_SET, span)
			emit_byte(&c.bc, u8(heap_base2 + field_offset), span)
		}

	case:
		compiler_error(c, "invalid compound assignment target", span)
	}
}

compile_assignment :: proc(c: ^Compiler, e: parser.BinaryExpression, span: lexer.Span) {
	compile_expr(c, e.right)
	lhs := c.ast.nodes[e.left]
	if expr, ok := lhs.(parser.Expression); ok {
		if id, ok2 := expr.(parser.IdentExpression); ok2 {
			name := lexer.Token(id).data
			slot, slots, found := resolve_local(&c.bc, name)
			if found {
				if slots == 1 {
					emit(&c.bc, .SET_LOCAL, span)
					emit_byte(&c.bc, u8(slot), span)
				} else {
					// multi-slot struct: write each slot in reverse, leave nil as expression value
					for s := slots - 1; s >= 0; s -= 1 {
						emit(&c.bc, .SET_LOCAL, span)
						emit_byte(&c.bc, u8(slot + s), span)
						emit(&c.bc, .POP, span)
					}
					emit(&c.bc, .NIL, span)
				}
			} else {
				name_idx, _ := chunk_add_constant(current_chunk(&c.bc), name)
				emit(&c.bc, .SET_GLOBAL, span)
				emit_byte(&c.bc, u8(name_idx), span)
			}
			return
		}
		if fa, ok3 := expr.(parser.FieldAccessExpression); ok3 {
			compile_field_set(c, fa, span)
			return
		}
	}
	compiler_error(c, "invalid assignment target", span)
}

compile_if :: proc(c: ^Compiler, e: parser.IfExpression, span: lexer.Span) {
	compile_expr(c, e.condition)
	then_jump, _ := emit_jump(&c.bc, .JUMP_IF_FALSE, span)
	emit(&c.bc, .POP, span)   // pop condition (true path)

	compile_block(c, e.then_block)
	emit(&c.bc, .NIL, span)   // if always produces a value

	if else_block, ok := e.else_block.?; ok {
		else_jump, _ := emit_jump(&c.bc, .JUMP, span)
		patch_jump(&c.bc, then_jump)
		emit(&c.bc, .POP, span)   // pop condition (false path)
		compile_block(c, else_block)
		emit(&c.bc, .NIL, span)   // else always produces a value
		patch_jump(&c.bc, else_jump)
	} else {
		patch_jump(&c.bc, then_jump)
		emit(&c.bc, .POP, span)   // pop condition (no-else path)
		emit(&c.bc, .NIL, span)
	}
}

// ---- helpers ----

resolve_local :: proc(bc: ^ByteCodeCompiler, name: string) -> (stack_slot: int, slots: int, found: bool) {
	target := -1
	for i := len(bc.locals) - 1; i >= 0; i -= 1 {
		if bc.locals[i].name == name {
			target = i
			break
		}
	}
	if target < 0 do return 0, 0, false
	offset := 0
	for i in 0..<target {
		offset += bc.locals[i].slots
	}
	return offset, bc.locals[target].slots, true
}

op_to_opcode :: proc(kind: lexer.TokenType) -> Opcode {
	#partial switch kind {
	case .PLUS:    return .ADD
	case .MINUS:   return .SUB
	case .STAR:    return .MUL
	case .SLASH:   return .DIV
	case .PERCENT: return .MOD
	case .LT_LT:      return .SHL
	case .GT_GT:      return .SHR
	case .AMPERSAND:  return .BAND
	case .PIPE:       return .BOR
	case .CARET:      return .BXOR
	case .EQ_EQ:   return .EQ
	case .BANG_EQ: return .NEQ
	case .LT:      return .LT
	case .LT_EQ:   return .LTE
	case .GT:      return .GT
	case .GT_EQ:   return .GTE
	}
	return .ADD // unreachable
}

parse_literal :: proc(tok: lexer.Token) -> Value {
	#partial switch tok.kind {
	case .INT:
		if len(tok.data) > 2 && tok.data[0] == '0' && (tok.data[1] == 'x' || tok.data[1] == 'X') {
			n, _ := strconv.parse_i64(tok.data[2:], 16)
			return i64(n)
		}
		n, _ := strconv.parse_i64(tok.data)
		return i64(n)
	case .FLOAT:
		f, _ := strconv.parse_f64(tok.data)
		return f64(f)
	case .STRING:
		if len(tok.data) < 2 { return "" }
		raw := tok.data[1:len(tok.data)-1]
		return decode_string_escapes(raw)

	case .TRUE:  return true
	case .FALSE: return false
	}
	return Nil{}
}

eval_const_expr :: proc(c: ^Compiler, idx: parser.ExpressionIdx, span: lexer.Span) -> (Value, bool) {
	node := c.ast.nodes[idx]

	#partial switch e in node.(parser.Expression) {
	case parser.LiteralExpression:
		return parse_literal(lexer.Token(e)), true

	case parser.IdentExpression:
		name := lexer.Token(e).data
		if val, ok := c.const_table[name]; ok {
			return val, true
		}
		compiler_error(c, "undefined constant", span)
		return Nil{}, false

	case parser.UnaryExpression:
		val, ok := eval_const_expr(c, e.operand, span)
		if !ok { return Nil{}, false }
		#partial switch e.op.kind {
		case .MINUS:
			if n, ok2 := val.(i64); ok2 { return -n, true }
			if f, ok2 := val.(f64); ok2 { return -f, true }
		case .BANG:
			if b, ok2 := val.(bool); ok2 { return !b, true }
		}
		compiler_error(c, "invalid unary operator in const expression", span)
		return Nil{}, false

	case parser.BinaryExpression:
		lv, lok := eval_const_expr(c, e.left,  span)
		rv, rok := eval_const_expr(c, e.right, span)
		if !lok || !rok { return Nil{}, false }
		if ln, ok := lv.(i64); ok {
			if rn, ok2 := rv.(i64); ok2 {
				#partial switch e.operation.kind {
				case .PLUS:    return ln + rn, true
				case .MINUS:   return ln - rn, true
				case .STAR:    return ln * rn, true
				case .SLASH:
					if rn == 0 { compiler_error(c, "division by zero in const expression", span); return Nil{}, false }
					return ln / rn, true
				case .PERCENT:
					if rn == 0 { compiler_error(c, "modulo by zero in const expression", span); return Nil{}, false }
					return ln % rn, true
				case .LT_LT:     return ln << uint(rn), true
				case .GT_GT:     return ln >> uint(rn), true
				case .AMPERSAND: return ln & rn, true
				case .PIPE:      return ln | rn, true
				case .CARET:     return ln ~ rn, true
				}
			}
		}
		if lf, ok := lv.(f64); ok {
			if rf, ok2 := rv.(f64); ok2 {
				#partial switch e.operation.kind {
				case .PLUS:  return lf + rf, true
				case .MINUS: return lf - rf, true
				case .STAR:  return lf * rf, true
				case .SLASH: return lf / rf, true
				}
			}
		}
		compiler_error(c, "invalid operands in const expression", span)
		return Nil{}, false
	}

	compiler_error(c, "not a compile-time constant expression", span)
	return Nil{}, false
}

decode_string_escapes :: proc(s: string) -> string {
	if !strings.contains(s, "\\") { return s }
	b := strings.builder_make()
	i := 0
	for i < len(s) {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 'n':  strings.write_byte(&b, '\n')
			case 't':  strings.write_byte(&b, '\t')
			case 'r':  strings.write_byte(&b, '\r')
			case '\\': strings.write_byte(&b, '\\')
			case '"':  strings.write_byte(&b, '"')
			case '0':  strings.write_byte(&b, 0)
			case:
				strings.write_byte(&b, '\\')
				strings.write_byte(&b, s[i])
			}
		} else {
			strings.write_byte(&b, s[i])
		}
		i += 1
	}
	return strings.to_string(b)
}

compiler_error :: proc(c: ^Compiler, msg: string, span: lexer.Span) {
	if c.error_count < MAX_ERROR_COUNT {
		c.errors[c.error_count] = CompilerError{message = msg, span = span}
		c.error_count += 1
	}
}

// ---- struct helpers ----

local_struct_type :: proc(bc: ^ByteCodeCompiler, name: string) -> string {
	for i := len(bc.locals) - 1; i >= 0; i -= 1 {
		if bc.locals[i].name == name {
			return bc.locals[i].struct_type
		}
	}
	return ""
}

local_ptr_inner :: proc(bc: ^ByteCodeCompiler, name: string) -> string {
	for i := len(bc.locals) - 1; i >= 0; i -= 1 {
		if bc.locals[i].name == name {
			return bc.locals[i].ptr_inner
		}
	}
	return ""
}

type_slot_count :: proc(c: ^Compiler, type_idx: parser.TypeIdx) -> int {
	if int(type_idx) >= len(c.ast.nodes) do return 1
	node := c.ast.nodes[int(type_idx)]
	ty, ok := node.(parser.Type)
	if !ok do return 1
	// Pointer types always occupy exactly 1 slot.
	if _, is_ptr := ty.(parser.PointerType); is_ptr do return 1
	named, ok2 := ty.(parser.NamedType)
	if !ok2 do return 1
	name := lexer.Token(named).data
	if layout, ok3 := c.struct_layouts[name]; ok3 {
		return layout.total_slots
	}
	return 1
}

type_ann_struct_name :: proc(c: ^Compiler, type_idx: parser.TypeIdx) -> string {
	if int(type_idx) >= len(c.ast.nodes) do return ""
	node := c.ast.nodes[int(type_idx)]
	ty, ok := node.(parser.Type)
	if !ok do return ""
	// Pointer types are not flat structs — the local holds 1 pointer slot.
	if _, is_ptr := ty.(parser.PointerType); is_ptr do return ""
	named, ok2 := ty.(parser.NamedType)
	if !ok2 do return ""
	name := lexer.Token(named).data
	if _, ok3 := c.struct_layouts[name]; ok3 {
		return name
	}
	return ""
}

// type_ann_ptr_inner returns the name of T when the annotation is ^T, or "".
type_ann_ptr_inner :: proc(c: ^Compiler, type_idx: parser.TypeIdx) -> string {
	if int(type_idx) >= len(c.ast.nodes) do return ""
	node := c.ast.nodes[int(type_idx)]
	ty, ok := node.(parser.Type)
	if !ok do return ""
	ptr, is_ptr := ty.(parser.PointerType)
	if !is_ptr do return ""
	inner_node := c.ast.nodes[int(ptr.inner)]
	inner_ty, ok2 := inner_node.(parser.Type)
	if !ok2 do return ""
	named, ok3 := inner_ty.(parser.NamedType)
	if !ok3 do return ""
	return lexer.Token(named).data
}

expr_slot_count :: proc(c: ^Compiler, idx: parser.ExpressionIdx) -> int {
	st := expr_struct_type(c, idx)
	if st == "" do return 1
	if layout, ok := c.struct_layouts[st]; ok do return layout.total_slots
	return 1
}

build_struct_layout :: proc(c: ^Compiler, d: parser.StructDecl) -> StructLayout {
	field_names        := make([]string, len(d.fields))
	field_offsets      := make([]int,    len(d.fields))
	field_struct_types := make([]string, len(d.fields))
	field_ptr_inners   := make([]string, len(d.fields))
	offset := 0
	for field, i in d.fields {
		field_names[i]        = field.name.data
		field_offsets[i]      = offset
		field_struct_types[i] = type_ann_struct_name(c, field.type)
		field_ptr_inners[i]   = type_ann_ptr_inner(c, field.type)
		offset += type_slot_count(c, field.type)
	}
	return StructLayout{
		field_names        = field_names,
		field_offsets      = field_offsets,
		field_struct_types = field_struct_types,
		field_ptr_inners   = field_ptr_inners,
		total_slots        = offset,
	}
}

find_field :: proc(layout: StructLayout, field_name: string) -> (offset: int, slots: int, struct_type: string, ptr_inner: string, found: bool) {
	for i in 0..<len(layout.field_names) {
		if layout.field_names[i] == field_name {
			next := layout.total_slots
			if i + 1 < len(layout.field_offsets) {
				next = layout.field_offsets[i + 1]
			}
			pi := ""
			if len(layout.field_ptr_inners) > i {
				pi = layout.field_ptr_inners[i]
			}
			return layout.field_offsets[i], next - layout.field_offsets[i], layout.field_struct_types[i], pi, true
		}
	}
	return 0, 0, "", "", false
}

call_return_struct_type :: proc(c: ^Compiler, e: parser.CallExpression) -> string {
	callee_node := c.ast.nodes[e.callee]
	expr, ok := callee_node.(parser.Expression)
	if !ok do return ""
	id, ok2 := expr.(parser.IdentExpression)
	if !ok2 do return ""
	fn_name := lexer.Token(id).data
	for node in c.ast.nodes {
		decl, ok3 := node.(parser.Declaration)
		if !ok3 do continue
		fn, ok4 := decl.(parser.FunctionDecl)
		if !ok4 do continue
		if fn.name.data != fn_name do continue
		ret_idx, has_ret := fn.return_type.?
		if !has_ret do return ""
		return type_ann_struct_name(c, ret_idx)
	}
	return ""
}

// call_return_ptr_inner returns "T" if the callee's return type is ^T, or "".
call_return_ptr_inner :: proc(c: ^Compiler, e: parser.CallExpression) -> string {
	callee_node := c.ast.nodes[e.callee]
	expr, ok := callee_node.(parser.Expression)
	if !ok do return ""
	id, ok2 := expr.(parser.IdentExpression)
	if !ok2 do return ""
	fn_name := lexer.Token(id).data
	for node in c.ast.nodes {
		decl, ok3 := node.(parser.Declaration)
		if !ok3 do continue
		fn, ok4 := decl.(parser.FunctionDecl)
		if !ok4 do continue
		if fn.name.data != fn_name do continue
		ret_idx, has_ret := fn.return_type.?
		if !has_ret do return ""
		return type_ann_ptr_inner(c, ret_idx)
	}
	return ""
}

expr_struct_type :: proc(c: ^Compiler, idx: parser.ExpressionIdx) -> string {
	node := c.ast.nodes[int(idx)]
	expr, ok := node.(parser.Expression)
	if !ok do return ""
	#partial switch e in expr {
	case parser.StructLiteralExpression:
		return e.type_name.data
	case parser.IdentExpression:
		return local_struct_type(&c.bc, lexer.Token(e).data)
	case parser.FieldAccessExpression:
		_, _, parent_type, ok2 := resolve_access_chain(c, e.object)
		if !ok2 do return ""
		layout, has := c.struct_layouts[parent_type]
		if !has do return ""
		_, _, field_st, _, found := find_field(layout, e.field.data)
		if !found do return ""
		return field_st
	case parser.CallExpression:
		return call_return_struct_type(c, e)
	case parser.NewExpression:
		return ""  // new T{} returns a pointer, not a flat struct
	case parser.DerefExpression:
		return expr_ptr_inner(c, e.operand)  // p^ produces a flat struct copy
	}
	return ""
}

// expr_ptr_inner returns the inner struct name when the expression produces a ^T pointer.
expr_ptr_inner :: proc(c: ^Compiler, idx: parser.ExpressionIdx) -> string {
	node := c.ast.nodes[int(idx)]
	expr, ok := node.(parser.Expression)
	if !ok do return ""
	if ne, ok2 := expr.(parser.NewExpression); ok2 {
		return ne.type_name.data
	}
	if id, ok2 := expr.(parser.IdentExpression); ok2 {
		return local_ptr_inner(&c.bc, lexer.Token(id).data)
	}
	if ce, ok2 := expr.(parser.CallExpression); ok2 {
		return call_return_ptr_inner(c, ce)
	}
	return ""
}

compile_struct_literal :: proc(c: ^Compiler, e: parser.StructLiteralExpression, span: lexer.Span) {
	layout, ok := c.struct_layouts[e.type_name.data]
	if !ok {
		compiler_error(c, fmt.tprintf("undefined struct '%s'", e.type_name.data), span)
		return
	}
	field_map := make(map[string]parser.ExpressionIdx)
	defer delete(field_map)
	for field in e.fields {
		field_map[field.name.data] = field.value
	}
	for name in layout.field_names {
		val_idx, has_val := field_map[name]
		if !has_val {
			compiler_error(c, fmt.tprintf("missing field '%s' in struct literal", name), span)
			emit(&c.bc, .NIL, span)
			continue
		}
		compile_expr(c, val_idx)
	}
}

// resolve_access_chain walks a chain of field accesses (e.g. r.origin.x) and
// returns the base stack slot, an accumulated heap_offset (-1 for flat struct
// locals, >=0 for pointer locals), and the struct type at that point, so the
// caller can apply one more field lookup on top of it.
resolve_access_chain :: proc(c: ^Compiler, idx: parser.ExpressionIdx) -> (slot: int, heap_offset: int, struct_type: string, ok: bool) {
	node := c.ast.nodes[int(idx)]
	expr, is_expr := node.(parser.Expression)
	if !is_expr do return 0, -1, "", false
	#partial switch e in expr {
	case parser.IdentExpression:
		name := lexer.Token(e).data
		s, _, found := resolve_local(&c.bc, name)
		if !found do return 0, -1, "", false
		st := local_struct_type(&c.bc, name)
		pi := local_ptr_inner(&c.bc, name)
		if pi != "" {
			return s, 0, pi, true  // pointer local: heap_offset=0
		}
		return s, -1, st, true    // flat struct local: heap_offset=-1
	case parser.FieldAccessExpression:
		base, h_off, parent_type, chain_ok := resolve_access_chain(c, e.object)
		if !chain_ok do return 0, -1, "", false
		layout, has := c.struct_layouts[parent_type]
		if !has do return 0, -1, "", false
		offset, _, field_st, _, found := find_field(layout, e.field.data)
		if !found do return 0, -1, "", false
		if h_off >= 0 {
			// Through pointer: accumulate heap offset (stops at pointer-typed fields — handled by compile_ptr_to_container)
			return base, h_off + offset, field_st, true
		}
		return base + offset, -1, field_st, true
	}
	return 0, -1, "", false
}

// compile_ptr_to_container emits bytecode that leaves the owning [^]Value pointer
// on the stack for the access chain in `idx`. Returns (heap_base, struct_type, ok).
// heap_base is the cumulative flat-struct offset within the heap object (used by
// the caller to address individual fields via HEAP_GET/HEAP_SET).
// For pointer-typed fields it emits HEAP_GET to hop through to the next pointer.
compile_ptr_to_container :: proc(c: ^Compiler, idx: parser.ExpressionIdx, span: lexer.Span) -> (heap_base: int, struct_type: string, ok: bool) {
	node := c.ast.nodes[int(idx)]
	expr, is_expr := node.(parser.Expression)
	if !is_expr do return 0, "", false
	#partial switch e in expr {
	case parser.IdentExpression:
		name := lexer.Token(e).data
		slot, _, found := resolve_local(&c.bc, name)
		if !found do return 0, "", false
		pi := local_ptr_inner(&c.bc, name)
		if pi == "" do return 0, "", false
		emit(&c.bc, .GET_LOCAL, span)
		emit_byte(&c.bc, u8(slot), span)
		return 0, pi, true

	case parser.FieldAccessExpression:
		base, parent_type, chain_ok := compile_ptr_to_container(c, e.object, span)
		if !chain_ok do return 0, "", false
		layout, has := c.struct_layouts[parent_type]
		if !has do return 0, "", false
		field_offset, _, field_st, field_pi, found := find_field(layout, e.field.data)
		if !found do return 0, "", false
		if field_st != "" {
			// Flat struct field within the current heap object: accumulate offset.
			return base + field_offset, field_st, true
		}
		if field_pi != "" {
			// Pointer-typed field: emit HEAP_GET to load it, start a fresh chain.
			emit(&c.bc, .HEAP_GET, span)
			emit_byte(&c.bc, u8(base + field_offset), span)
			return 0, field_pi, true
		}
		return 0, "", false
	}
	return 0, "", false
}

compile_field_access :: proc(c: ^Compiler, e: parser.FieldAccessExpression, span: lexer.Span) {
	base_slot, heap_offset, parent_type, ok := resolve_access_chain(c, e.object)

	if ok && parent_type != "" {
		layout, has_layout := c.struct_layouts[parent_type]
		if !has_layout {
			compiler_error(c, "field access on non-struct value", span)
			return
		}
		field_offset, field_slots, _, _, field_found := find_field(layout, e.field.data)
		if !field_found {
			compiler_error(c, fmt.tprintf("unknown field '%s'", e.field.data), span)
			return
		}
		if heap_offset >= 0 {
			for s in 0..<field_slots {
				emit(&c.bc, .GET_LOCAL, span)
				emit_byte(&c.bc, u8(base_slot), span)
				emit(&c.bc, .HEAP_GET, span)
				emit_byte(&c.bc, u8(heap_offset + field_offset + s), span)
			}
		} else {
			for s in 0..<field_slots {
				emit(&c.bc, .GET_LOCAL, span)
				emit_byte(&c.bc, u8(base_slot + field_offset + s), span)
			}
		}
		return
	}

	// Fallback: chain passes through a pointer-typed field (e.g. a.next.val).
	heap_base, container_type, chain_ok := compile_ptr_to_container(c, e.object, span)
	if !chain_ok { compiler_error(c, "invalid field access", span); return }
	layout, has := c.struct_layouts[container_type]
	if !has { compiler_error(c, "field access on non-struct value", span); return }
	field_offset, field_slots, _, _, field_found := find_field(layout, e.field.data)
	if !field_found { compiler_error(c, fmt.tprintf("unknown field '%s'", e.field.data), span); return }
	// ptr is on stack; emit HEAP_GET for each slot (re-push ptr for multi-slot reads).
	for s in 0..<field_slots {
		if s > 0 {
			// For multi-slot reads through a pointer hop we'd need the ptr again.
			// Single-slot (scalars, pointers) is the common case; this handles it.
			compiler_error(c, "multi-slot field read through pointer hop not yet supported", span)
			return
		}
		emit(&c.bc, .HEAP_GET, span)
		emit_byte(&c.bc, u8(heap_base + field_offset + s), span)
	}
}

compile_field_set :: proc(c: ^Compiler, e: parser.FieldAccessExpression, span: lexer.Span) {
	base_slot, heap_offset, parent_type, ok := resolve_access_chain(c, e.object)

	if ok && parent_type != "" {
		layout, has_layout := c.struct_layouts[parent_type]
		if !has_layout {
			compiler_error(c, "field assignment on non-struct value", span)
			return
		}
		field_offset, _, _, _, field_found := find_field(layout, e.field.data)
		if !field_found {
			compiler_error(c, fmt.tprintf("unknown field '%s'", e.field.data), span)
			return
		}
		if heap_offset >= 0 {
			emit(&c.bc, .GET_LOCAL, span)
			emit_byte(&c.bc, u8(base_slot), span)
			emit(&c.bc, .HEAP_SET, span)
			emit_byte(&c.bc, u8(heap_offset + field_offset), span)
		} else {
			emit(&c.bc, .SET_LOCAL, span)
			emit_byte(&c.bc, u8(base_slot + field_offset), span)
		}
		return
	}

	// Fallback: value is already on stack; emit ptr to container, then HEAP_SET.
	heap_base, container_type, chain_ok := compile_ptr_to_container(c, e.object, span)
	if !chain_ok { compiler_error(c, "invalid field assignment target", span); return }
	layout, has := c.struct_layouts[container_type]
	if !has { compiler_error(c, "field assignment on non-struct value", span); return }
	field_offset, _, _, _, field_found := find_field(layout, e.field.data)
	if !field_found { compiler_error(c, fmt.tprintf("unknown field '%s'", e.field.data), span); return }
	emit(&c.bc, .HEAP_SET, span)
	emit_byte(&c.bc, u8(heap_base + field_offset), span)
}

// compile_new_expr pushes all struct fields in layout order, then emits NEW N.
// The VM allocates a heap slice of N Value slots, pops them, and pushes a ^Value pointer.
compile_new_expr :: proc(c: ^Compiler, e: parser.NewExpression, span: lexer.Span) {
	layout, ok := c.struct_layouts[e.type_name.data]
	if !ok {
		compiler_error(c, fmt.tprintf("undefined struct '%s'", e.type_name.data), span)
		emit(&c.bc, .NIL, span)
		return
	}
	field_map := make(map[string]parser.ExpressionIdx)
	defer delete(field_map)
	for field in e.fields {
		field_map[field.name.data] = field.value
	}
	for name in layout.field_names {
		val_idx, has_val := field_map[name]
		if !has_val {
			compiler_error(c, fmt.tprintf("missing field '%s' in new expression", name), span)
			emit(&c.bc, .NIL, span)
			continue
		}
		compile_expr(c, val_idx)
	}
	emit(&c.bc, .NEW, span)
	emit_byte(&c.bc, u8(layout.total_slots), span)
}

// compile_deref_expr loads the pointer and emits HEAP_LOAD N to copy all slots.
compile_deref_expr :: proc(c: ^Compiler, e: parser.DerefExpression, span: lexer.Span) {
	// Determine how many heap slots to load from the pointer's inner type.
	pi := expr_ptr_inner(c, e.operand)
	n := 1
	if pi != "" {
		if layout, ok := c.struct_layouts[pi]; ok {
			n = layout.total_slots
		}
	}
	compile_expr(c, e.operand)  // pushes the ^Value pointer
	emit(&c.bc, .HEAP_LOAD, span)
	emit_byte(&c.bc, u8(n), span)
}
