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

Compiler :: struct {
	bc:          ByteCodeCompiler,
	ast:         ^parser.AST,
	errors:      [MAX_ERROR_COUNT]CompilerError,
	error_count: u8,
	loop_ctx:    ^LoopCtx,
	const_table: map[string]Value,
}

new_compiler :: proc(ast: ^parser.AST) -> Compiler {
	return Compiler{
		bc          = new_bytecode_compiler("__main__", 0),
		ast         = ast,
		const_table = make(map[string]Value),
	}
}

compiler_destroy :: proc(c: ^Compiler) {
	compiler_free(&c.bc)
	delete(c.const_table)
}

compile :: proc(ast: ^parser.AST) -> (^Function, []CompilerError) {
	c := new_compiler(ast)

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
	case parser.StructDecl, parser.EnumDecl:
		// type declarations — no bytecode in Phase 1
	}
}

compile_function :: proc(c: ^Compiler, d: parser.FunctionDecl, span: lexer.Span) {
	// create a child compiler for this function
	fn_compiler := new_bytecode_compiler(d.name.data, u8(len(d.params)), &c.bc)

	// slot 0 is the function itself (allows recursion, matches VM frame layout)
	add_local(&fn_compiler, d.name.data)
	// parameters start at slot 1
	for param in d.params {
		add_local(&fn_compiler, param.name.data)
	}

	// compile body
	child := Compiler{bc = fn_compiler, ast = c.ast, errors = c.errors, error_count = c.error_count, const_table = c.const_table}
	compile_block(&child, d.body)
	emit(&child.bc, .RETURN, span)
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
		emit(&c.bc, .POP, {})
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
			add_local(&c.bc, s.name.data)
			// value stays on stack as the local's slot
		}

	case parser.ReturnStatement:
		if val, ok := s.value.?; ok {
			compile_expr(c, val)
		} else {
			emit(&c.bc, .NIL, span)
		}
		emit(&c.bc, .RETURN, span)

	case parser.ExpressionStatement:
		compile_expr(c, s.expr)
		emit(&c.bc, .POP, span)

	case parser.ForStatement:
		compile_for(c, s, span)

	case parser.BreakStatement:
		if c.loop_ctx == nil {
			compiler_error(c, "break outside of loop", span)
			return
		}
		n := len(c.bc.locals) - c.loop_ctx.local_base
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
		n := len(c.bc.locals) - c.loop_ctx.local_base
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
			emit(&c.bc, .POP, span)
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
		slot, found := resolve_local(&c.bc, name)
		if found {
			emit(&c.bc, .GET_LOCAL, span)
			emit_byte(&c.bc, u8(slot), span)
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
		}

	case parser.BinaryExpression:
		// assignment is special
		if e.operation.kind == .EQ {
			compile_assignment(c, e, span)
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
		for arg in e.args {
			compile_expr(c, arg)
		}
		emit(&c.bc, .CALL, span)
		emit_byte(&c.bc, u8(len(e.args)), span)

	case parser.IfExpression:
		compile_if(c, e, span)

	case parser.BlockExpression:
		compile_block(c, e)

	case parser.FieldAccessExpression, parser.IndexExpression,
	     parser.MatchExpression:
		compiler_error(c, "not yet implemented", span)
	}
}

compile_assignment :: proc(c: ^Compiler, e: parser.BinaryExpression, span: lexer.Span) {
	compile_expr(c, e.right)
	// figure out what the left side is
	lhs := c.ast.nodes[e.left]
	if ident, ok := lhs.(parser.Expression); ok {
		if id, ok2 := ident.(parser.IdentExpression); ok2 {
			name := lexer.Token(id).data
			slot, found := resolve_local(&c.bc, name)
			if found {
				emit(&c.bc, .SET_LOCAL, span)
				emit_byte(&c.bc, u8(slot), span)
			} else {
				name_idx, _ := chunk_add_constant(current_chunk(&c.bc), name)
				emit(&c.bc, .SET_GLOBAL, span)
				emit_byte(&c.bc, u8(name_idx), span)
			}
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

resolve_local :: proc(bc: ^ByteCodeCompiler, name: string) -> (slot: int, found: bool) {
	for i := len(bc.locals) - 1; i >= 0; i -= 1 {
		if bc.locals[i].name == name {
			return i, true
		}
	}
	return 0, false
}

op_to_opcode :: proc(kind: lexer.TokenType) -> Opcode {
	#partial switch kind {
	case .PLUS:    return .ADD
	case .MINUS:   return .SUB
	case .STAR:    return .MUL
	case .SLASH:   return .DIV
	case .PERCENT: return .MOD
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
