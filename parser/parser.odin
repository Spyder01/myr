package parser

import "../lexer"
import "core:fmt"



ParserErrorType :: enum(u8) {
	SYNTAX,
	UNEXPECTED_TOKEN,
}

ParserError :: struct {
	span: lexer.Span,
	kind: ParserErrorType,
}

offset_to_line_col :: proc(source: string, offset: u32) -> (line, col: int) {
	line = 1
	col  = 1
	for i := u32(0); i < offset && int(i) < len(source); i += 1 {
		if source[i] == '\n' {
			line += 1
			col   = 1
		} else {
			col  += 1
		}
	}
	return
}

decode_parser_error_message :: proc(err: ^ParserError, source: string) -> string {
	slice      := source[err.span.start:err.span.end]
	line, col  := offset_to_line_col(source, err.span.start)
	switch err.kind {
	case .UNEXPECTED_TOKEN:
		return fmt.tprintf("unexpected token '%s' at %d:%d", slice, line, col)
	case .SYNTAX:
		return fmt.tprintf("syntax error near '%s' at %d:%d", slice, line, col)
	}
	return "unknown error"
} 

Parser :: struct {
	lex:           lexer.Lexer,
	current_token: lexer.Token,
	ast:           AST,
	errors:        [dynamic]ParserError,
	no_struct_lit: bool,
}

parser_destroy :: proc(p: ^Parser) {
	delete(p.errors)
	ast_destroy(&p.ast)
}

new_parser :: proc(source: string) -> Parser {
	p := Parser{
		lex = lexer.Lexer{source = source, start = 0, current = 0},
	}
	p.current_token = lexer.next_token(&p.lex)
	return p
}

@private
peek_token :: proc(p: ^Parser) -> lexer.Token {
	return p.current_token
}

@private
peek :: proc(p: ^Parser) -> lexer.TokenType {
	return peek_token(p).kind
}

@private
peek_span :: proc(p: ^Parser) -> lexer.Span {
	return peek_token(p).span
}

@private
advance :: proc(p: ^Parser) -> lexer.Token {
	if peek(p) == .EOF {
		return p.current_token
	}

	curr_token := p.current_token
	p.current_token = lexer.next_token(&p.lex)
	
	return curr_token
}

@private
expect :: proc(p: ^Parser, expected_token_type: lexer.TokenType) -> lexer.Token {
	next_token_type := peek(p)
	if next_token_type == .EOF || next_token_type == expected_token_type {
		return advance(p)
	}
	
	span := peek_span(p)

	append_elem(&p.errors, ParserError{
		kind=.UNEXPECTED_TOKEN,
		span=span
	})

	return lexer.Token{kind = .ERROR, span = span}
} 

parse_program :: proc(p: ^Parser) -> AST {
	for peek(p) != .EOF {
		parse_declarations(p)
	}

	return p.ast
}

@private
parse_declarations :: proc(p: ^Parser) {
	#partial switch peek(p) {
	case .FN:     parse_function_declarations(p)
	case .STRUCT: parse_struct_declarations(p)
	case .ENUM:   parse_enum_declarations(p)
	case .IMPORT: parse_import_declarations(p)
	case .CONST:  parse_const_declarations(p)
	case:
			append_elem(&p.errors, ParserError{kind = .UNEXPECTED_TOKEN, span = peek_span(p)})
			advance(p)
	}
}

@private
parse_function_declarations :: proc(p: ^Parser) {
	expect(p, .FN)
	name := expect(p, .IDENT)

	type_params := make([dynamic]lexer.Token)
	if peek(p) == .LEFT_BRACKET {
		advance(p)
		for peek(p) != .RIGHT_BRACKET && peek(p) != .EOF {
			tp := expect(p, .IDENT)
			append_elem(&type_params, tp)
			if peek(p) != .RIGHT_BRACKET {
				expect(p, .COMMA)
			}
		}
		expect(p, .RIGHT_BRACKET)
	}

	expect(p, .LEFT_PAREN)
	params := parse_params(p)
	expect(p, .RIGHT_PAREN)

	return_type: Maybe(TypeIdx) = nil
	if peek(p) == .ARROW {
		advance(p)
		return_type = parse_type(p)
	}

	body := parse_block(p)

	decl := FunctionDecl{
		name        = name,
		type_params = type_params[:],
		params      = params,
		return_type = return_type,
		body        = body,
	}

	append_elem(&p.ast.nodes, Node(Declaration(decl)))
	append_elem(&p.ast.spans, name.span)
}

@private
parse_struct_declarations :: proc(p: ^Parser) {
	expect(p, .STRUCT)
	name := expect(p, .IDENT)

	type_params := make([dynamic]lexer.Token)
	if peek(p) == .LEFT_BRACKET {
		advance(p)
		for peek(p) != .RIGHT_BRACKET && peek(p) != .EOF {
			tp := expect(p, .IDENT)
			append_elem(&type_params, tp)
			if peek(p) != .RIGHT_BRACKET { expect(p, .COMMA) }
		}
		expect(p, .RIGHT_BRACKET)
	}

	expect(p, .LEFT_BRACE)
	struct_fields := parse_struct_fields(p)
	expect(p, .RIGHT_BRACE)

	decl := StructDecl{
		name        = name,
		type_params = type_params[:],
		fields      = struct_fields,
	}

	append_elem(&p.ast.nodes, Node(Declaration(decl)))
	append_elem(&p.ast.spans, name.span)
}

@private
parse_params :: proc(p: ^Parser) -> []Param {
	params := make([dynamic]Param)
	for peek(p) != .RIGHT_PAREN && peek(p) != .EOF {
		name := expect(p, .IDENT)
		expect(p, .COLON)
		type := parse_type(p)
		append_elem(&params, Param{name = name, type = type})
		if peek(p) != .RIGHT_PAREN {
			expect(p, .COMMA)
		}
	}
	return params[:]
}

@private
parse_type :: proc(p: ^Parser) -> TypeIdx {
	if peek(p) == .LEFT_PAREN {
		return parse_fn_type(p)
	}
	if peek(p) == .CARET {
		caret := advance(p)
		inner := parse_type(p)
		ptr := PointerType{inner = inner}
		append_elem(&p.ast.nodes, Node(Type(ptr)))
		append_elem(&p.ast.spans, caret.span)
		return TypeIdx(len(p.ast.nodes) - 1)
	}
	tok := expect(p, .IDENT)
	if peek(p) == .DOT {
		// module-qualified type: math.Vec or math.Vec[T]
		advance(p)
		name := expect(p, .IDENT)
		type_args: []TypeIdx = nil
		if peek(p) == .LEFT_BRACKET {
			advance(p)
			args := make([dynamic]TypeIdx)
			for peek(p) != .RIGHT_BRACKET && peek(p) != .EOF {
				append_elem(&args, parse_type(p))
				if peek(p) != .RIGHT_BRACKET { expect(p, .COMMA) }
			}
			expect(p, .RIGHT_BRACKET)
			type_args = args[:]
		}
		qt := QualifiedType{module = tok, name = name, type_args = type_args}
		append_elem(&p.ast.nodes, Node(Type(qt)))
		append_elem(&p.ast.spans, tok.span)
		return TypeIdx(len(p.ast.nodes) - 1)
	}
	if peek(p) == .LEFT_BRACKET {
		if tok.data == "Array" {
			return parse_array_type(p, tok)
		}
		advance(p)
		args := make([dynamic]TypeIdx)
		for peek(p) != .RIGHT_BRACKET && peek(p) != .EOF {
			append_elem(&args, parse_type(p))
			if peek(p) != .RIGHT_BRACKET { expect(p, .COMMA) }
		}
		expect(p, .RIGHT_BRACKET)
		gt := GenericType{name = tok, args = args[:]}
		append_elem(&p.ast.nodes, Node(Type(gt)))
		append_elem(&p.ast.spans, tok.span)
		return TypeIdx(len(p.ast.nodes) - 1)
	}
	named := NamedType(tok)
	append_elem(&p.ast.nodes, Node(Type(named)))
	append_elem(&p.ast.spans, tok.span)
	return TypeIdx(len(p.ast.nodes) - 1)
}

@private
parse_array_type :: proc(p: ^Parser, tok: lexer.Token) -> TypeIdx {
	expect(p, .LEFT_BRACKET)
	elem_type := parse_type(p)
	expect(p, .COMMA)
	size_tok := expect(p, .INT)
	n := 0
	for c in size_tok.data { n = n * 10 + int(c - '0') }
	expect(p, .RIGHT_BRACKET)
	at := ArrayType{elem = elem_type, size = n}
	append_elem(&p.ast.nodes, Node(Type(at)))
	append_elem(&p.ast.spans, tok.span)
	return TypeIdx(len(p.ast.nodes) - 1)
}

@private
parse_array_literal :: proc(p: ^Parser, tok: lexer.Token) -> ExpressionIdx {
	expect(p, .LEFT_BRACKET)
	elem_type := parse_type(p)
	expect(p, .COMMA)
	size_tok := expect(p, .INT)
	n := 0
	for c in size_tok.data { n = n * 10 + int(c - '0') }
	expect(p, .RIGHT_BRACKET)
	expect(p, .LEFT_BRACE)
	values := make([dynamic]ExpressionIdx)
	for peek(p) != .RIGHT_BRACE && peek(p) != .EOF {
		append_elem(&values, parse_expr(p, 0))
		if peek(p) != .RIGHT_BRACE { expect(p, .COMMA) }
	}
	expect(p, .RIGHT_BRACE)
	expr := ArrayLiteralExpression{elem_type = elem_type, size = n, values = values[:]}
	append_elem(&p.ast.nodes, Node(Expression(expr)))
	append_elem(&p.ast.spans, tok.span)
	return ExpressionIdx(len(p.ast.nodes) - 1)
}

@private
parse_fn_type :: proc(p: ^Parser) -> TypeIdx {
	span := peek_span(p)
	expect(p, .LEFT_PAREN)
	params := make([dynamic]TypeIdx)
	for peek(p) != .RIGHT_PAREN && peek(p) != .EOF {
		append_elem(&params, parse_type(p))
		if peek(p) != .RIGHT_PAREN {
			expect(p, .COMMA)
		}
	}
	expect(p, .RIGHT_PAREN)

	return_type: Maybe(TypeIdx) = nil
	if peek(p) == .ARROW {
		advance(p)
		return_type = parse_type(p)
	}

	fn_type := FnType{params = params[:], return_type = return_type}
	append_elem(&p.ast.nodes, Node(Type(fn_type)))
	append_elem(&p.ast.spans, span)
	return TypeIdx(len(p.ast.nodes) - 1)
}

@private
parse_block :: proc(p: ^Parser) -> BlockExpression {
	expect(p, .LEFT_BRACE)
	stmts := make([dynamic]StatementIdx)
	for peek(p) != .RIGHT_BRACE && peek(p) != .EOF {
		idx := parse_stmt(p)
		append_elem(&stmts, idx)
	}
	expect(p, .RIGHT_BRACE)

	// Tail expression: if the last statement is a bare expression (no semicolon
	// terminator in the language, so we check statement kind), promote it to the
	// block result so the block produces a value without an explicit return.
	result: Maybe(ExpressionIdx) = nil
	if len(stmts) > 0 {
		last := stmts[len(stmts)-1]
		if last_node, ok := p.ast.nodes[int(last)].(Statement); ok {
			if es, ok2 := last_node.(ExpressionStatement); ok2 {
				result = es.expr
				pop(&stmts)
			}
		}
	}

	return BlockExpression{stmts = stmts[:], result = result}
}

@private
parse_struct_fields :: proc(p: ^Parser) -> []StructField {
	struct_fields := make([dynamic]StructField)
	for peek(p) != .RIGHT_BRACE && peek(p) != .EOF {
		name := expect(p, .IDENT)
		expect(p, .COLON)
		type := parse_type(p)
		append_elem(&struct_fields, StructField{name = name, type = type})
		if peek(p) != .RIGHT_BRACE {
			expect(p, .COMMA)
		}
	}

	return struct_fields[:]
}

@private
parse_stmt :: proc(p: ^Parser) -> StatementIdx {
	#partial switch peek(p) {
	case .LET:      return parse_let_stmt(p)
	case .CONST:    return parse_const_stmt(p)
	case .RETURN:   return parse_return_stmt(p)
	case .LOOP:     return parse_for(p)
	case .BREAK:
		tok := advance(p)
		append_elem(&p.ast.nodes, Node(Statement(BreakStatement{})))
		append_elem(&p.ast.spans, tok.span)
		return StatementIdx(len(p.ast.nodes) - 1)
	case .CONTINUE:
		tok := advance(p)
		append_elem(&p.ast.nodes, Node(Statement(ContinueStatement{})))
		append_elem(&p.ast.spans, tok.span)
		return StatementIdx(len(p.ast.nodes) - 1)
	case:           return parse_expr_stmt(p)
	}
}

@private
parse_for :: proc(p: ^Parser) -> StatementIdx {
	tok := expect(p, .LOOP)

	// infinite loop: for { }
	if peek(p) == .LEFT_BRACE {
		body := parse_block(p)
		stmt := ForStatement{body = body}
		append_elem(&p.ast.nodes, Node(Statement(stmt)))
		append_elem(&p.ast.spans, tok.span)
		return StatementIdx(len(p.ast.nodes) - 1)
	}

	// traditional: for let i = 0; cond; post { }
	if peek(p) == .LET {
		init := parse_let_stmt(p)
		expect(p, .SEMICOLON)
		p.no_struct_lit = true
		condition := parse_expr(p)
		p.no_struct_lit = false
		expect(p, .SEMICOLON)
		p.no_struct_lit = true
		post := parse_expr_stmt(p)
		p.no_struct_lit = false
		body := parse_block(p)
		stmt := ForStatement{
			init      = init,
			condition = condition,
			post      = post,
			body      = body,
		}
		append_elem(&p.ast.nodes, Node(Statement(stmt)))
		append_elem(&p.ast.spans, tok.span)
		return StatementIdx(len(p.ast.nodes) - 1)
	}

	// condition loop: for cond { }
	p.no_struct_lit = true
	condition := parse_expr(p)
	p.no_struct_lit = false
	body := parse_block(p)
	stmt := ForStatement{condition = condition, body = body}
	append_elem(&p.ast.nodes, Node(Statement(stmt)))
	append_elem(&p.ast.spans, tok.span)
	return StatementIdx(len(p.ast.nodes) - 1)
}

@private
parse_const_stmt :: proc(p: ^Parser) -> StatementIdx {
	expect(p, .CONST)
	name  := expect(p, .IDENT)
	expect(p, .EQ)
	value := parse_expr(p)
	stmt  := ConstStatement{name = name, value = value}
	append_elem(&p.ast.nodes, Node(Statement(stmt)))
	append_elem(&p.ast.spans, name.span)
	return StatementIdx(len(p.ast.nodes) - 1)
}

parse_let_stmt :: proc(p: ^Parser) -> StatementIdx {
	expect(p, .LET)
	name := expect(p, .IDENT)

	type: Maybe(TypeIdx) = nil
	if peek(p) == .COLON {
		advance(p)
		type = parse_type(p)
	}

	expect(p, .EQ)
	value := parse_expr(p)

	stmt := LetStatement{name = name, type = type, value = value}
	append_elem(&p.ast.nodes, Node(Statement(stmt)))
	append_elem(&p.ast.spans, name.span)
	return StatementIdx(len(p.ast.nodes) - 1)
}

@private
parse_return_stmt :: proc(p: ^Parser) -> StatementIdx {
	tok := expect(p, .RETURN)

	value: Maybe(ExpressionIdx) = nil
	if peek(p) != .RIGHT_BRACE && peek(p) != .EOF {
		value = parse_expr(p)
	}

	stmt := ReturnStatement{value = value}
	append_elem(&p.ast.nodes, Node(Statement(stmt)))
	append_elem(&p.ast.spans, tok.span)
	return StatementIdx(len(p.ast.nodes) - 1)
}

@private
parse_expr_stmt :: proc(p: ^Parser) -> StatementIdx {
	tok  := peek_token(p)
	expr := parse_expr(p)

	stmt := ExpressionStatement{expr = expr}
	append_elem(&p.ast.nodes, Node(Statement(stmt)))
	append_elem(&p.ast.spans, tok.span)
	return StatementIdx(len(p.ast.nodes) - 1)
}

@private
binding_power :: proc(kind: lexer.TokenType) -> (left: int, right: int) {
	#partial switch kind {
	case .EQ, .PLUS_EQ, .MINUS_EQ,
	     .STAR_EQ, .SLASH_EQ, .PERCENT_EQ:      return 1,  2
	case .OR:                                    return 3,  4
	case .AND:                                   return 5,  6
	case .PIPE:                                  return 7,  8
	case .CARET:                                 return 9,  10
	case .AMPERSAND:                             return 11, 12
	case .EQ_EQ, .BANG_EQ,
	     .LT, .GT, .LT_EQ, .GT_EQ:              return 13, 14
	case .LT_LT, .GT_GT:                        return 15, 16
	case .PLUS, .MINUS:                          return 17, 18
	case .STAR, .SLASH, .PERCENT:                return 19, 20
	case .DOT, .LEFT_BRACKET, .LEFT_PAREN:       return 23, 24
	}
	return 0, 0
}

@private
parse_expr :: proc(p: ^Parser, min_bp: int = 0) -> ExpressionIdx {
	left := parse_prefix(p)

	for {
		op := peek_token(p)
		left_bp, right_bp := binding_power(op.kind)
		if left_bp == 0 || left_bp < min_bp do break

		advance(p)

		#partial switch op.kind {
		case .LEFT_PAREN:
			left = parse_call(p, left, op)
		case .LEFT_BRACKET:
			left = parse_index(p, left, op)
		case .DOT:
			left = parse_field_access(p, left, op)
		case .CARET:
			// Postfix dereference (p^) when next token cannot start an expression.
			// Otherwise falls through to XOR binary expression.
			if !can_start_expr(peek(p)) {
				expr := DerefExpression{operand = left}
				append_elem(&p.ast.nodes, Node(Expression(expr)))
				append_elem(&p.ast.spans, op.span)
				left = ExpressionIdx(len(p.ast.nodes) - 1)
			} else {
				right := parse_expr(p, right_bp)
				expr  := BinaryExpression{left = left, right = right, operation = op}
				append_elem(&p.ast.nodes, Node(Expression(expr)))
				append_elem(&p.ast.spans, op.span)
				left = ExpressionIdx(len(p.ast.nodes) - 1)
			}
		case:
			right := parse_expr(p, right_bp)
			expr  := BinaryExpression{left = left, right = right, operation = op}
			append_elem(&p.ast.nodes, Node(Expression(expr)))
			append_elem(&p.ast.spans, op.span)
			left = ExpressionIdx(len(p.ast.nodes) - 1)
		}
	}

	return left
}

@private
parse_prefix :: proc(p: ^Parser) -> ExpressionIdx {
	tok := peek_token(p)

	#partial switch tok.kind {
	case .INT, .FLOAT, .STRING, .TRUE, .FALSE, .NIL:
		advance(p)
		expr := LiteralExpression(tok)
		append_elem(&p.ast.nodes, Node(Expression(expr)))
		append_elem(&p.ast.spans, tok.span)
		return ExpressionIdx(len(p.ast.nodes) - 1)

	case .IDENT:
		advance(p)
		if !p.no_struct_lit {
			if peek(p) == .LEFT_BRACE {
				return parse_struct_literal(p, tok)
			}
			if peek(p) == .LEFT_BRACKET && token_after_brackets(p) == .LEFT_BRACE {
				if tok.data == "Array" {
					return parse_array_literal(p, tok)
				}
				return parse_generic_struct_literal(p, tok)
			}
		}
		expr := IdentExpression(tok)
		append_elem(&p.ast.nodes, Node(Expression(expr)))
		append_elem(&p.ast.spans, tok.span)
		return ExpressionIdx(len(p.ast.nodes) - 1)

	case .AMPERSAND:
		advance(p)
		operand := parse_expr(p, 21)
		expr    := AddrOfExpression{operand = operand}
		append_elem(&p.ast.nodes, Node(Expression(expr)))
		append_elem(&p.ast.spans, tok.span)
		return ExpressionIdx(len(p.ast.nodes) - 1)

	case .MINUS, .BANG, .TILDE:
		advance(p)
		operand := parse_expr(p, 21)
		expr    := UnaryExpression{op = tok, operand = operand}
		append_elem(&p.ast.nodes, Node(Expression(expr)))
		append_elem(&p.ast.spans, tok.span)
		return ExpressionIdx(len(p.ast.nodes) - 1)

	case .LEFT_PAREN:
		advance(p)
		inner := parse_expr(p, 0)
		expect(p, .RIGHT_PAREN)
		return inner

	case .LEFT_BRACE:
		tok := peek_token(p)
		block := parse_block(p)
		append_elem(&p.ast.nodes, Node(Expression(block)))
		append_elem(&p.ast.spans, tok.span)
		return ExpressionIdx(len(p.ast.nodes) - 1)

	case .IF:
		return parse_if(p)

	case .NEW:
		advance(p)
		type_name := expect(p, .IDENT)
		return parse_new_expr(p, type_name)

	case .MATCH:
		return parse_match(p)
	}

	append_elem(&p.errors, ParserError{kind = .UNEXPECTED_TOKEN, span = tok.span})
	advance(p)
	return ExpressionIdx(INVALID_IDX)
}

@private
parse_struct_literal :: proc(p: ^Parser, type_name: lexer.Token) -> ExpressionIdx {
	expect(p, .LEFT_BRACE)
	fields := make([dynamic]StructLiteralField)
	for peek(p) != .RIGHT_BRACE && peek(p) != .EOF {
		name  := expect(p, .IDENT)
		expect(p, .EQ)
		value := parse_expr(p, 0)
		append_elem(&fields, StructLiteralField{name = name, value = value})
		if peek(p) != .RIGHT_BRACE {
			expect(p, .COMMA)
		}
	}
	expect(p, .RIGHT_BRACE)
	expr := StructLiteralExpression{type_name = type_name, fields = fields[:]}
	append_elem(&p.ast.nodes, Node(Expression(expr)))
	append_elem(&p.ast.spans, type_name.span)
	return ExpressionIdx(len(p.ast.nodes) - 1)
}

// token_after_brackets peeks past a balanced [...] without consuming any tokens.
// Returns the kind of the first token that follows the closing ].
@private
token_after_brackets :: proc(p: ^Parser) -> lexer.TokenType {
	saved_lex := p.lex
	saved_tok := p.current_token
	depth := 0
	result := lexer.TokenType.EOF
	loop: for p.current_token.kind != .EOF {
		kind := p.current_token.kind
		_ = advance(p)
		if kind == .LEFT_BRACKET {
			depth += 1
		} else if kind == .RIGHT_BRACKET {
			depth -= 1
			if depth == 0 {
				result = p.current_token.kind
				break loop
			}
		}
	}
	p.lex = saved_lex
	p.current_token = saved_tok
	return result
}

@private
parse_generic_struct_literal :: proc(p: ^Parser, type_name: lexer.Token) -> ExpressionIdx {
	expect(p, .LEFT_BRACKET)
	type_args := make([dynamic]TypeIdx)
	for peek(p) != .RIGHT_BRACKET && peek(p) != .EOF {
		append_elem(&type_args, parse_type(p))
		if peek(p) != .RIGHT_BRACKET { expect(p, .COMMA) }
	}
	expect(p, .RIGHT_BRACKET)
	expect(p, .LEFT_BRACE)
	fields := make([dynamic]StructLiteralField)
	for peek(p) != .RIGHT_BRACE && peek(p) != .EOF {
		name  := expect(p, .IDENT)
		expect(p, .EQ)
		value := parse_expr(p, 0)
		append_elem(&fields, StructLiteralField{name = name, value = value})
		if peek(p) != .RIGHT_BRACE { expect(p, .COMMA) }
	}
	expect(p, .RIGHT_BRACE)
	expr := StructLiteralExpression{type_name = type_name, type_args = type_args[:], fields = fields[:]}
	append_elem(&p.ast.nodes, Node(Expression(expr)))
	append_elem(&p.ast.spans, type_name.span)
	return ExpressionIdx(len(p.ast.nodes) - 1)
}

@private
parse_new_expr :: proc(p: ^Parser, type_name: lexer.Token) -> ExpressionIdx {
	expect(p, .LEFT_BRACE)
	fields := make([dynamic]StructLiteralField)
	for peek(p) != .RIGHT_BRACE && peek(p) != .EOF {
		name  := expect(p, .IDENT)
		expect(p, .EQ)
		value := parse_expr(p, 0)
		append_elem(&fields, StructLiteralField{name = name, value = value})
		if peek(p) != .RIGHT_BRACE {
			expect(p, .COMMA)
		}
	}
	expect(p, .RIGHT_BRACE)
	expr := NewExpression{type_name = type_name, fields = fields[:]}
	append_elem(&p.ast.nodes, Node(Expression(expr)))
	append_elem(&p.ast.spans, type_name.span)
	return ExpressionIdx(len(p.ast.nodes) - 1)
}

@private
can_start_expr :: proc(kind: lexer.TokenType) -> bool {
	#partial switch kind {
	case .INT, .FLOAT, .STRING, .TRUE, .FALSE, .NIL,
	     .IDENT, .LEFT_PAREN, .MINUS, .BANG, .TILDE, .IF, .NEW, .MATCH, .LEFT_BRACE:
		return true
	}
	return false
}

@private
parse_match :: proc(p: ^Parser) -> ExpressionIdx {
	tok := expect(p, .MATCH)
	p.no_struct_lit = true
	subject := parse_expr(p, 0)
	p.no_struct_lit = false
	expect(p, .LEFT_BRACE)
	arms := make([dynamic]MatchArm)
	for peek(p) != .RIGHT_BRACE && peek(p) != .EOF {
		pattern := parse_match_pattern(p)
		expect(p, .FAT_ARROW)
		body := parse_expr(p, 0)
		append_elem(&arms, MatchArm{pattern = pattern, body = body})
	}
	expect(p, .RIGHT_BRACE)
	expr := MatchExpression{subject = subject, arms = arms[:]}
	append_elem(&p.ast.nodes, Node(Expression(expr)))
	append_elem(&p.ast.spans, tok.span)
	return ExpressionIdx(len(p.ast.nodes) - 1)
}

@private
parse_match_pattern :: proc(p: ^Parser) -> ExpressionIdx {
	tok := peek_token(p)

	// Wildcard: _
	if tok.kind == .UNDERSCORE {
		advance(p)
		expr := IdentExpression(tok)
		append_elem(&p.ast.nodes, Node(Expression(expr)))
		append_elem(&p.ast.spans, tok.span)
		return ExpressionIdx(len(p.ast.nodes) - 1)
	}

	// Literal pattern: 0, 1, true, false, etc.
	#partial switch tok.kind {
	case .INT, .FLOAT, .STRING, .TRUE, .FALSE:
		advance(p)
		expr := LiteralExpression(tok)
		append_elem(&p.ast.nodes, Node(Expression(expr)))
		append_elem(&p.ast.spans, tok.span)
		return ExpressionIdx(len(p.ast.nodes) - 1)
	}

	// Enum pattern: EnumName.VariantName { ... } or module.EnumName.VariantName { ... }
	enum_name    := expect(p, .IDENT)
	expect(p, .DOT)
	variant_name := expect(p, .IDENT)
	module_tok:  lexer.Token
	has_module := false
	if peek(p) == .DOT {
		// module-qualified: the first two idents were module.Enum; the variant follows.
		advance(p)
		module_tok   = enum_name
		enum_name    = variant_name
		variant_name = expect(p, .IDENT)
		has_module   = true
	}
	expect(p, .LEFT_BRACE)
	fields := make([dynamic]StructLiteralField)
	for peek(p) != .RIGHT_BRACE && peek(p) != .EOF {
		field_tok := expect(p, .IDENT)
		ident_expr := IdentExpression(field_tok)
		append_elem(&p.ast.nodes, Node(Expression(ident_expr)))
		append_elem(&p.ast.spans, field_tok.span)
		ident_idx := ExpressionIdx(len(p.ast.nodes) - 1)
		append_elem(&fields, StructLiteralField{name = field_tok, value = ident_idx})
		if peek(p) != .RIGHT_BRACE {
			expect(p, .COMMA)
		}
	}
	expect(p, .RIGHT_BRACE)
	pattern := EnumLiteralExpression{
		enum_name    = enum_name,
		variant_name = variant_name,
		fields       = fields[:],
		module       = module_tok,
		has_module   = has_module,
	}
	append_elem(&p.ast.nodes, Node(Expression(pattern)))
	append_elem(&p.ast.spans, enum_name.span)
	return ExpressionIdx(len(p.ast.nodes) - 1)
}

@private
parse_if :: proc(p: ^Parser) -> ExpressionIdx {
	tok := expect(p, .IF)
	p.no_struct_lit = true
	condition := parse_expr(p, 0)
	p.no_struct_lit = false
	then_block := parse_block(p)

	else_block: Maybe(BlockExpression) = nil
	if peek(p) == .ELSE {
		advance(p)
		if peek(p) == .IF {
			// else-if: wrap the nested if in a block
			else_if_idx := parse_if(p)
			else_block = BlockExpression{
				stmts  = nil,
				result = else_if_idx,
			}
		} else {
			else_block = parse_block(p)
		}
	}

	expr := IfExpression{
		condition  = condition,
		then_block = then_block,
		else_block = else_block,
	}
	append_elem(&p.ast.nodes, Node(Expression(expr)))
	append_elem(&p.ast.spans, tok.span)
	return ExpressionIdx(len(p.ast.nodes) - 1)
}

@private
parse_call :: proc(p: ^Parser, callee: ExpressionIdx, op: lexer.Token) -> ExpressionIdx {
	args := make([dynamic]ExpressionIdx)
	for peek(p) != .RIGHT_PAREN && peek(p) != .EOF {
		append_elem(&args, parse_expr(p, 0))
		if peek(p) != .RIGHT_PAREN {
			expect(p, .COMMA)
		}
	}
	expect(p, .RIGHT_PAREN)
	expr := CallExpression{callee = callee, args = args[:]}
	append_elem(&p.ast.nodes, Node(Expression(expr)))
	append_elem(&p.ast.spans, op.span)
	return ExpressionIdx(len(p.ast.nodes) - 1)
}

@private
parse_index :: proc(p: ^Parser, object: ExpressionIdx, op: lexer.Token) -> ExpressionIdx {
	index := parse_expr(p, 0)
	expect(p, .RIGHT_BRACKET)
	expr := IndexExpression{object = object, index = index}
	append_elem(&p.ast.nodes, Node(Expression(expr)))
	append_elem(&p.ast.spans, op.span)
	return ExpressionIdx(len(p.ast.nodes) - 1)
}

@private
parse_field_access :: proc(p: ^Parser, object: ExpressionIdx, op: lexer.Token) -> ExpressionIdx {
	field := expect(p, .IDENT)
	// A brace after a dotted name introduces a literal (struct or enum).
	// One dot  `A.B {`   → EnumName.Variant or module.Struct (disambiguated downstream).
	// Two dots `A.B.C {` → module.EnumName.Variant (always a qualified enum literal).
	if peek(p) == .LEFT_BRACE && !p.no_struct_lit {
		obj_node := p.ast.nodes[int(object)]
		if obj_expr, ok := obj_node.(Expression); ok {
			#partial switch obj in obj_expr {
			case IdentExpression:
				return parse_enum_literal(p, lexer.Token(obj), field)
			case FieldAccessExpression:
				// object is `A.B`; require A to be a plain identifier → module.B.field
				inner := p.ast.nodes[int(obj.object)]
				if inner_expr, ok2 := inner.(Expression); ok2 {
					if mod, ok3 := inner_expr.(IdentExpression); ok3 {
						return parse_enum_literal(p, obj.field, field, lexer.Token(mod), true)
					}
				}
			}
		}
	}
	expr  := FieldAccessExpression{object = object, field = field}
	append_elem(&p.ast.nodes, Node(Expression(expr)))
	append_elem(&p.ast.spans, op.span)
	return ExpressionIdx(len(p.ast.nodes) - 1)
}

@private
parse_enum_literal :: proc(p: ^Parser, enum_name: lexer.Token, variant_name: lexer.Token, module: lexer.Token = {}, has_module := false) -> ExpressionIdx {
	expect(p, .LEFT_BRACE)
	fields := make([dynamic]StructLiteralField)
	for peek(p) != .RIGHT_BRACE && peek(p) != .EOF {
		name  := expect(p, .IDENT)
		expect(p, .EQ)
		value := parse_expr(p, 0)
		append_elem(&fields, StructLiteralField{name = name, value = value})
		if peek(p) != .RIGHT_BRACE {
			expect(p, .COMMA)
		}
	}
	expect(p, .RIGHT_BRACE)
	expr := EnumLiteralExpression{enum_name = enum_name, variant_name = variant_name, fields = fields[:], module = module, has_module = has_module}
	append_elem(&p.ast.nodes, Node(Expression(expr)))
	append_elem(&p.ast.spans, enum_name.span)
	return ExpressionIdx(len(p.ast.nodes) - 1)
}

@private
parse_enum_declarations :: proc(p: ^Parser) {
	expect(p, .ENUM)
	name := expect(p, .IDENT)

	expect(p, .LEFT_BRACE)
	variants, fields := parse_enum_variants(p)
	expect(p, .RIGHT_BRACE)

	decl := EnumDecl{
		name     = name,
		variants = variants,
		fields   = fields,
	}

	append_elem(&p.ast.nodes, Node(Declaration(decl)))
	append_elem(&p.ast.spans, name.span)
}

@private
parse_enum_variants :: proc(p: ^Parser) -> ([]EnumVariant, []StructField) {
	variants := make([dynamic]EnumVariant)
	fields   := make([dynamic]StructField)

	for peek(p) != .RIGHT_BRACE && peek(p) != .EOF {
		name        := expect(p, .IDENT)
		field_start := u16(len(fields))

		if peek(p) == .LEFT_BRACE {
			advance(p)
			for peek(p) != .RIGHT_BRACE && peek(p) != .EOF {
				field_name := expect(p, .IDENT)
				expect(p, .COLON)
				field_type := parse_type(p)
				append_elem(&fields, StructField{name = field_name, type = field_type})
				if peek(p) != .RIGHT_BRACE {
					expect(p, .COMMA)
				}
			}
			expect(p, .RIGHT_BRACE)
		}

		append_elem(&variants, EnumVariant{name = name, field_start = field_start})

		if peek(p) != .RIGHT_BRACE {
			expect(p, .COMMA)
		}
	}

	return variants[:], fields[:]
}

@private
parse_import_declarations :: proc(p: ^Parser) {
	expect(p, .IMPORT)
	path := expect(p, .STRING)

	decl := ImportDecl{path = path}
	// `as` is a contextual keyword: it lexes as an identifier.
	if peek(p) == .IDENT && peek_token(p).data == "as" {
		advance(p)
		decl.alias     = expect(p, .IDENT)
		decl.has_alias = true
	}

	append_elem(&p.ast.nodes, Node(Declaration(decl)))
	append_elem(&p.ast.spans, path.span)
}

@private
parse_const_declarations :: proc(p: ^Parser) {
	expect(p, .CONST)
	name  := expect(p, .IDENT)
	expect(p, .EQ)
	value := parse_expr(p)

	decl := ConstDecl{name = name, value = value}
	append_elem(&p.ast.nodes, Node(Declaration(decl)))
	append_elem(&p.ast.spans, name.span)
}


