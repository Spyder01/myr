package lexer

TokenType :: enum(u8) {
	// Literals
	INT,
	FLOAT,
	STRING,
	TRUE,
	FALSE,

	// Identifiers
	IDENT,
	UNDERSCORE,

	// Keywords
	LET,
	CONST,
	FN,
	IF,
	ELSE,
	MATCH,
	RETURN,
	STRUCT,
	ENUM,
	WITH,
	CONTEXT,
	SOA,
	AOS,
	IMPORT,
	LOOP,
	BREAK,
	CONTINUE,

	// Delimiters
	LEFT_PAREN,
	RIGHT_PAREN,
	LEFT_BRACE,
	RIGHT_BRACE,
	LEFT_BRACKET,
	RIGHT_BRACKET,
	COMMA,
	DOT,
	COLON,
	COLON_COLON,
	SEMICOLON,
	ARROW,
	ELLIPSIS,

	// Arithmetic
	PLUS,
	MINUS,
	STAR,
	SLASH,
	PERCENT,

	// Comparison
	EQ,
	EQ_EQ,
	BANG_EQ,
	LT,
	LT_EQ,
	GT,
	GT_EQ,

	// Logic
	BANG,
	AND,
	OR,

	// Bitwise
	AMPERSAND,
	PIPE,
	CARET,
	TILDE,
	LT_LT,
	GT_GT,

	// Decorators
	AT,

	// Special
	ERROR,
	EOF,
}

Span :: struct {
	start: u32,
	end: u32
}

Token :: struct {
	data: string,
	span: Span,
	kind: TokenType,	
}

build_error_token :: proc(span: Span) -> Token {
	return {
		span=span,
		kind=.ERROR,
	}
}

