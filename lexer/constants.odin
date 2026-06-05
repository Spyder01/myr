package lexer


Spaces :: enum byte {
	WHITESPACE = ' ',
	NEW_LINE   = '\n',
	CARRIAGE 	 = '\r',
	TAB 			 = '\t',
}

Symbols :: enum byte {
	COMMA     = ',',
	SEMICOLON = ';',
	PERCENT   = '%',
	CARET     = '^',
	TILDE     = '~',
	AT        = '@',
	PLUS      = '+',
	STAR      = '*',
	SLASH     = '/',
	MINUS     = '-',
	GT        = '>',
	EQ        = '=',
	BANG      = '!',
	COLON     = ':',
	AMPERSAND = '&',
	PIPE      = '|',
	LT        = '<',
	DOT       = '.',
	QUOTE     = '"',
	ARROW_R   = '>',
}

Braces :: enum byte {
	LEFT_PAREN    = '(',
	RIGHT_PAREN   = ')',
	LEFT_BRACE    = '{',
	RIGHT_BRACE   = '}',
	LEFT_BRACKET  = '[',
	RIGHT_BRACKET = ']',
}

Digits :: enum byte {
	ZERO = '0',
	NINE = '9',
}

Alpha :: enum byte {
	LOWER_A    = 'a',
	LOWER_Z    = 'z',
	UPPER_A    = 'A',
	UPPER_Z    = 'Z',
	UNDERSCORE = '_',
}

KW_LET     :: "let"
KW_FN      :: "function"
KW_IF      :: "if"
KW_ELSE    :: "else"
KW_MATCH   :: "match"
KW_RETURN  :: "return"
KW_STRUCT  :: "struct"
KW_ENUM    :: "enum"
KW_WITH    :: "with"
KW_CONTEXT :: "context"
KW_SOA     :: "soa"
KW_AOS     :: "aos"
KW_IMPORT  :: "import"
KW_TRUE    :: "true"
KW_FALSE   :: "false"
KW_FOR      :: "for"
KW_BREAK    :: "break"
KW_CONTINUE :: "continue"
KW_PRINT    :: "print"

