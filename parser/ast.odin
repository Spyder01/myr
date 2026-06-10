package parser

import "../lexer"

ExpressionIdx  :: distinct u32
StatementIdx   :: distinct u32
DeclarationIdx :: distinct u32
TypeIdx        :: distinct u32

INVALID_IDX :: max(u32)


LiteralExpression    :: distinct lexer.Token
IdentExpression      :: distinct lexer.Token

BinaryExpression :: struct {
	left:      ExpressionIdx,
	right:     ExpressionIdx,
	operation: lexer.Token,
}

UnaryExpression :: struct {
	operand: ExpressionIdx,
	op:      lexer.Token,
}

CallExpression :: struct {
	callee: ExpressionIdx,
	args:   []ExpressionIdx,
}

FieldAccessExpression :: struct {
	object: ExpressionIdx,
	field:  lexer.Token,
}

IndexExpression :: struct {
	object: ExpressionIdx,
	index:  ExpressionIdx,
}

IfExpression :: struct {
	condition:  ExpressionIdx,
	then_block: BlockExpression,
	else_block: Maybe(BlockExpression),
}

MatchArm :: struct {
	pattern: ExpressionIdx,
	body:    ExpressionIdx,
}

MatchExpression :: struct {
	subject: ExpressionIdx,
	arms:    []MatchArm,
}

BlockExpression :: struct {
	stmts:  []StatementIdx,
	result: Maybe(ExpressionIdx),
}

StructLiteralField :: struct {
	name:  lexer.Token,
	value: ExpressionIdx,
}

StructLiteralExpression :: struct {
	type_name: lexer.Token,
	type_args: []TypeIdx,
	fields:    []StructLiteralField,
}

NewExpression :: struct {
	type_name: lexer.Token,
	fields:    []StructLiteralField,
}

DerefExpression :: struct {
	operand: ExpressionIdx,
}

AddrOfExpression :: struct {
	operand: ExpressionIdx,
}

// EnumLiteralExpression represents EnumName.VariantName { field = value, ... }
EnumLiteralExpression :: struct {
	enum_name:    lexer.Token,
	variant_name: lexer.Token,
	fields:       []StructLiteralField,
}

Expression :: union {
	LiteralExpression,
	IdentExpression,
	UnaryExpression,
	BinaryExpression,
	CallExpression,
	FieldAccessExpression,
	IndexExpression,
	IfExpression,
	MatchExpression,
	BlockExpression,
	StructLiteralExpression,
	NewExpression,
	DerefExpression,
	AddrOfExpression,
	EnumLiteralExpression,
}

LetStatement :: struct {
	name:  lexer.Token,
	type:  Maybe(TypeIdx),
	value: ExpressionIdx,
}

ReturnStatement :: struct {
	value: Maybe(ExpressionIdx),
}

ExpressionStatement :: struct {
	expr: ExpressionIdx,
}

ContextOverride :: struct {
	key:   lexer.Token,
	value: ExpressionIdx,
}

WithContextStatement :: struct {
	overrides: []ContextOverride,
	body:      BlockExpression,
}

ForStatement :: struct {
	init:      Maybe(StatementIdx),
	condition: Maybe(ExpressionIdx),
	post:      Maybe(StatementIdx),
	body:      BlockExpression,
}

BreakStatement    :: struct {}
ContinueStatement :: struct {}

ConstStatement :: struct {
	name:  lexer.Token,
	value: ExpressionIdx,
}

Statement :: union {
	LetStatement,
	ConstStatement,
	ReturnStatement,
	ExpressionStatement,
	WithContextStatement,
	ForStatement,
	BreakStatement,
	ContinueStatement,
}

Param :: struct {
	name: lexer.Token,
	type: TypeIdx,
}

FunctionDecl :: struct {
	name:        lexer.Token,
	type_params: []lexer.Token,
	params:      []Param,
	return_type: Maybe(TypeIdx),
	body:        BlockExpression,
}

StructField :: struct {
	name: lexer.Token,
	type: TypeIdx,
}

Layout_Qualifier :: enum { SOA, AOS }

StructDecl :: struct {
	name:        lexer.Token,
	type_params: []lexer.Token,
	qualifier:   Maybe(Layout_Qualifier),
	fields:      []StructField,
}

EnumVariant :: struct {
	name:        lexer.Token,
	field_start: u16,
}

EnumDecl :: struct {
	name:     lexer.Token,
	variants: []EnumVariant,
	fields:   []StructField,
}

ImportDecl :: distinct lexer.Token

ConstDecl :: struct {
	name:  lexer.Token,
	value: ExpressionIdx,
}

Declaration :: union {
	FunctionDecl,
	StructDecl,
	EnumDecl,
	ImportDecl,
	ConstDecl,
}

NamedType :: distinct lexer.Token

GenericType :: struct {
	name: lexer.Token,
	args: []TypeIdx,
}

FnType :: struct {
	params:      []TypeIdx,
	return_type: Maybe(TypeIdx),
}

PointerType :: struct {
	inner: TypeIdx,
}

Type :: union {
	NamedType,
	GenericType,
	FnType,
	PointerType,
}

Node :: union {
	Expression,
	Statement,
	Declaration,
	Type,
}

AST :: struct {
	nodes: [dynamic]Node,
	spans: [dynamic]lexer.Span,
}

ast_destroy :: proc(ast: ^AST) {
	for node in ast.nodes {
		switch n in node {
		case Declaration:
			switch d in n {
			case FunctionDecl:
				delete(d.type_params)
				delete(d.params)
				delete(d.body.stmts)
			case StructDecl:
				delete(d.type_params)
				delete(d.fields)
			case EnumDecl:
				delete(d.variants)
				delete(d.fields)
			case ImportDecl:
		case ConstDecl:
			}
		case Statement:
			switch s in n {
			case LetStatement:
			case ConstStatement:
			case ReturnStatement:
			case ExpressionStatement:
			case WithContextStatement:
				delete(s.overrides)
				delete(s.body.stmts)
			case ForStatement:
				delete(s.body.stmts)
			case BreakStatement, ContinueStatement:
			}
		case Expression:
			switch e in n {
			case CallExpression:
				delete(e.args)
			case MatchExpression:
				delete(e.arms)
			case BlockExpression:
				delete(e.stmts)
			case IfExpression:
				delete(e.then_block.stmts)
				if eb, ok := e.else_block.?; ok do delete(eb.stmts)
			case StructLiteralExpression:
				delete(e.type_args)
				delete(e.fields)
			case NewExpression:
				delete(e.fields)
			case EnumLiteralExpression:
				delete(e.fields)
			case BinaryExpression, UnaryExpression,
			     FieldAccessExpression, IndexExpression,
			     LiteralExpression, IdentExpression,
			     DerefExpression, AddrOfExpression:
			}
		case Type:
			switch ty in n {
			case GenericType:   delete(ty.args)
			case FnType:        delete(ty.params)
			case NamedType, PointerType:
			}
		}
	}
	delete(ast.nodes)
	delete(ast.spans)
}

