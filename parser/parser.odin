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

decode_parser_error_message :: proc(err: ^ParserError, source: string) -> string {
	slice := source[err.span.start:err.span.end]
	switch err.kind {
	case .UNEXPECTED_TOKEN:
		return fmt.tprintf("unexpected token '%s' at %d:%d", slice, err.span.start, err.span.end)
	case .SYNTAX:
		return fmt.tprintf("syntax error near '%s' at %d:%d", slice, err.span.start, err.span.end)
	}
	return "unknown error"
} 

Parser :: struct {
	lex: 				 	 lexer.Lexer,
	current_token: lexer.Token,
	ast: 					 AST,
	errors: 			 [dynamic]ParserError,
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

	expect(p, .LEFT_BRACE)
	struct_fields := parse_struct_fields(p)
	expect(p, .RIGHT_BRACE)

	decl := StructDecl{
		name=name,
		fields=struct_fields,
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
	tok := expect(p, .IDENT)
	named := NamedType(tok)
	append_elem(&p.ast.nodes, Node(Type(named)))
	append_elem(&p.ast.spans, tok.span)
	return TypeIdx(len(p.ast.nodes) - 1)
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
	return BlockExpression{stmts = stmts[:]}
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
		init      := parse_let_stmt(p)
		expect(p, .SEMICOLON)
		condition := parse_expr(p)
		expect(p, .SEMICOLON)
		post      := parse_expr_stmt(p)
		body      := parse_block(p)
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
	condition := parse_expr(p)
	body      := parse_block(p)
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
	case .EQ_EQ, .BANG_EQ,
	     .LT, .GT, .LT_EQ, .GT_EQ:              return 7,  8
	case .PLUS, .MINUS:                          return 9,  10
	case .STAR, .SLASH, .PERCENT:                return 11, 12
	case .DOT, .LEFT_BRACKET, .LEFT_PAREN:       return 15, 16
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
	case .INT, .FLOAT, .STRING, .TRUE, .FALSE:
		advance(p)
		expr := LiteralExpression(tok)
		append_elem(&p.ast.nodes, Node(Expression(expr)))
		append_elem(&p.ast.spans, tok.span)
		return ExpressionIdx(len(p.ast.nodes) - 1)

	case .IDENT:
		advance(p)
		expr := IdentExpression(tok)
		append_elem(&p.ast.nodes, Node(Expression(expr)))
		append_elem(&p.ast.spans, tok.span)
		return ExpressionIdx(len(p.ast.nodes) - 1)

	case .MINUS, .BANG:
		advance(p)
		operand := parse_expr(p, 13)
		expr    := UnaryExpression{op = tok, operand = operand}
		append_elem(&p.ast.nodes, Node(Expression(expr)))
		append_elem(&p.ast.spans, tok.span)
		return ExpressionIdx(len(p.ast.nodes) - 1)

	case .LEFT_PAREN:
		advance(p)
		inner := parse_expr(p, 0)
		expect(p, .RIGHT_PAREN)
		return inner

	case .IF:
		return parse_if(p)
	}

	append_elem(&p.errors, ParserError{kind = .UNEXPECTED_TOKEN, span = tok.span})
	advance(p)
	return ExpressionIdx(INVALID_IDX)
}

@private
parse_if :: proc(p: ^Parser) -> ExpressionIdx {
	tok := expect(p, .IF)
	condition  := parse_expr(p, 0)
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
	expr  := FieldAccessExpression{object = object, field = field}
	append_elem(&p.ast.nodes, Node(Expression(expr)))
	append_elem(&p.ast.spans, op.span)
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

	decl := ImportDecl(path)

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


