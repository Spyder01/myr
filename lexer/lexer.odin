package lexer


Lexer :: struct {
	source: string,
	start: u32,
	current: u32,
}

make_token :: proc(l: ^Lexer, kind: TokenType) -> Token {
		return Token{
				kind = kind,
				data = l.source[l.start:l.current],
				span = Span{start = l.start, end = l.current},
		}
}

is_eof :: proc(l: ^Lexer) -> bool {
	return l.current >= u32(len(l.source))
}

peek :: proc(l: ^Lexer) -> byte {
	if is_eof(l) do return 0;

	return l.source[l.current]
}

peek_next :: proc(l: ^Lexer) -> byte {
	if l.current + 1 >= u32(len(l.source)) do return 0;

	return l.source[l.current + 1]
}

advance :: proc(l: ^Lexer) -> byte {
	ch := peek(l)
	if ch == 0 do return ch

	l.current += 1

	return ch
}

match :: proc(l: ^Lexer, expected: byte) -> bool {
	ch := peek(l)
	if ch == expected && ch != 0 {
		l.current += 1
		return true
	}

	return false
}


skip_whitespace :: proc(l: ^Lexer) {
		for !is_eof(l) {
				switch peek(l) {
				case byte(Spaces.WHITESPACE), byte(Spaces.TAB), byte(Spaces.NEW_LINE), byte(Spaces.CARRIAGE):
						advance(l)
				case byte(Symbols.SLASH):
						if peek_next(l) == byte(Symbols.SLASH) {
								for !is_eof(l) && peek(l) != byte(Spaces.NEW_LINE) {
										advance(l)
								}
						} else {
								return
						}
				case:
						return
				}
		}
}

error_token :: proc(l: ^Lexer, msg: string) -> Token {
	return Token{
		kind = .ERROR,
		data = msg,
		span = Span{start = l.start, end = l.current},
	}
}

is_digit :: proc(ch: byte) -> bool {
	return ch >= byte(Digits.ZERO) && ch <= byte(Digits.NINE)
}

is_alpha :: proc(ch: byte) -> bool {
	return (ch >= byte(Alpha.LOWER_A) && ch <= byte(Alpha.LOWER_Z)) ||
	       (ch >= byte(Alpha.UPPER_A) && ch <= byte(Alpha.UPPER_Z)) ||
	        ch == byte(Alpha.UNDERSCORE)
}

check_keyword :: proc(s: string) -> TokenType {
	switch s {
	case KW_LET:     return .LET
	case KW_FN:      return .FN
	case KW_IF:      return .IF
	case KW_ELSE:    return .ELSE
	case KW_MATCH:   return .MATCH
	case KW_RETURN:  return .RETURN
	case KW_STRUCT:  return .STRUCT
	case KW_ENUM:    return .ENUM
	case KW_WITH:    return .WITH
	case KW_CONTEXT: return .CONTEXT
	case KW_SOA:     return .SOA
	case KW_AOS:     return .AOS
	case KW_IMPORT:  return .IMPORT
	case KW_TRUE:    return .TRUE
	case KW_FALSE:   return .FALSE
	case KW_FOR:      return .LOOP
	case KW_BREAK:    return .BREAK
	case KW_CONTINUE: return .CONTINUE
	}
	return .IDENT
}

scan_ident :: proc(l: ^Lexer) -> Token {
	for is_alpha(peek(l)) || is_digit(peek(l)) {
		advance(l)
	}
	slice := l.source[l.start:l.current]
	kind  := check_keyword(slice)
	if kind == .IDENT && slice == "_" do kind = .UNDERSCORE
	return make_token(l, kind)
}

scan_number :: proc(l: ^Lexer) -> Token {
	for is_digit(peek(l)) {
		advance(l)
	}
	if peek(l) == '.' && is_digit(peek_next(l)) {
		advance(l)
		for is_digit(peek(l)) {
			advance(l)
		}
		return make_token(l, .FLOAT)
	}
	return make_token(l, .INT)
}

scan_string :: proc(l: ^Lexer) -> Token {
	for peek(l) != byte(Symbols.QUOTE) && !is_eof(l) {
		advance(l)
	}
	if is_eof(l) do return error_token(l, "unterminated string")
	advance(l) 
	return make_token(l, .STRING)
}

next_token :: proc(l: ^Lexer) -> Token {
	skip_whitespace(l)
	l.start = l.current

	if is_eof(l) do return make_token(l, .EOF)

	ch := advance(l)

	if is_alpha(ch) do return scan_ident(l)
	if is_digit(ch) do return scan_number(l)

	switch ch {
	case byte(Braces.LEFT_PAREN):   return make_token(l, .LEFT_PAREN)
	case byte(Braces.RIGHT_PAREN):  return make_token(l, .RIGHT_PAREN)
	case byte(Braces.LEFT_BRACE):   return make_token(l, .LEFT_BRACE)
	case byte(Braces.RIGHT_BRACE):  return make_token(l, .RIGHT_BRACE)
	case byte(Braces.LEFT_BRACKET): return make_token(l, .LEFT_BRACKET)
	case byte(Braces.RIGHT_BRACKET):return make_token(l, .RIGHT_BRACKET)
	case byte(Symbols.COMMA):       return make_token(l, .COMMA)
	case byte(Symbols.SEMICOLON):   return make_token(l, .SEMICOLON)
	case byte(Symbols.PERCENT):     return make_token(l, .PERCENT)
	case byte(Symbols.CARET):       return make_token(l, .CARET)
	case byte(Symbols.TILDE):       return make_token(l, .TILDE)
	case byte(Symbols.AT):          return make_token(l, .AT)
	case byte(Symbols.PLUS):        return make_token(l, .PLUS)
	case byte(Symbols.STAR):        return make_token(l, .STAR)
	case byte(Symbols.SLASH):       return make_token(l, .SLASH)
	case byte(Symbols.MINUS):       return make_token(l, match(l, byte(Symbols.GT))       ? .ARROW       : .MINUS)
	case byte(Symbols.EQ):          return make_token(l, match(l, byte(Symbols.EQ))       ? .EQ_EQ       : .EQ)
	case byte(Symbols.BANG):        return make_token(l, match(l, byte(Symbols.EQ))       ? .BANG_EQ     : .BANG)
	case byte(Symbols.COLON):       return make_token(l, match(l, byte(Symbols.COLON))    ? .COLON_COLON : .COLON)
	case byte(Symbols.AMPERSAND):   return make_token(l, match(l, byte(Symbols.AMPERSAND))? .AND         : .AMPERSAND)
	case byte(Symbols.PIPE):        return make_token(l, match(l, byte(Symbols.PIPE))     ? .OR          : .PIPE)
	case byte(Symbols.LT):
		if match(l, byte(Symbols.LT)) do return make_token(l, .LT_LT)
		if match(l, byte(Symbols.EQ)) do return make_token(l, .LT_EQ)
		return make_token(l, .LT)
	case byte(Symbols.GT):
		if match(l, byte(Symbols.GT)) do return make_token(l, .GT_GT)
		if match(l, byte(Symbols.EQ)) do return make_token(l, .GT_EQ)
		return make_token(l, .GT)
	case byte(Symbols.DOT):
		if peek(l) == byte(Symbols.DOT) && peek_next(l) == byte(Symbols.DOT) {
			advance(l)
			advance(l)
			return make_token(l, .ELLIPSIS)
		}
		return make_token(l, .DOT)
	case byte(Symbols.QUOTE): return scan_string(l)
	}

	return error_token(l, "unexpected character")
}

traverse_tokens :: proc(l: ^Lexer, traverse: proc(Token)) {
	for {
		token := next_token(l)

		traverse(token)	
		if token.kind == .EOF {
			return
		}
	}
}

