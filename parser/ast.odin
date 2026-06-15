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
	type_name:  lexer.Token,
	type_args:  []TypeIdx,
	fields:     []StructLiteralField,
	module:     lexer.Token, // module qualifier, e.g. the `math` in math.Vec{...}
	has_module: bool,
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

ArrayLiteralExpression :: struct {
	elem_type: TypeIdx,
	size:      int,
	values:    []ExpressionIdx,
}

// EnumLiteralExpression represents EnumName.VariantName { field = value, ... }
// or, when has_module is set, module.EnumName.VariantName { ... }.
EnumLiteralExpression :: struct {
	enum_name:    lexer.Token,
	variant_name: lexer.Token,
	fields:       []StructLiteralField,
	module:       lexer.Token, // module qualifier, e.g. the `math` in math.Color.Red{...}
	has_module:   bool,
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
	ArrayLiteralExpression,
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

// ImportDecl is `import "path"` or `import "path" as alias`.
ImportDecl :: struct {
	path:      lexer.Token, // STRING token, still quoted
	alias:     lexer.Token, // IDENT; valid only when has_alias
	has_alias: bool,
}

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

// QualifiedType is a module-qualified type name, e.g. math.Vec or math.Vec[T].
QualifiedType :: struct {
	module:    lexer.Token,
	name:      lexer.Token,
	type_args: []TypeIdx,
}

FnType :: struct {
	params:      []TypeIdx,
	return_type: Maybe(TypeIdx),
}

PointerType :: struct {
	inner: TypeIdx,
}

ArrayType :: struct {
	elem: TypeIdx,
	size: int,
}

Type :: union {
	NamedType,
	GenericType,
	FnType,
	PointerType,
	ArrayType,
	QualifiedType,
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

// import_path strips the surrounding quotes from an ImportDecl token and returns
// the bare path string (e.g. "math" → math) and the byte offset for error reporting.
import_path :: proc(imp: ImportDecl) -> (path: string, span_start: u32) {
	tok := imp.path
	raw := tok.data
	if len(raw) >= 2 { raw = raw[1 : len(raw)-1] }
	return raw, tok.span.start
}

// import_namespace returns the name used to refer to the import in code: the
// alias if present, otherwise the bare directory path.
import_namespace :: proc(imp: ImportDecl) -> string {
	if imp.has_alias { return imp.alias.data }
	path, _ := import_path(imp)
	return path
}

// ast_merge appends all nodes from src into dst, offsetting every index reference
// within src nodes by the current length of dst. Creates deep copies of all slice
// fields so that ast_destroy can be called on both dst (later) and src (immediately
// after this call) independently without aliasing.
// Returns the base offset applied (= original len(dst.nodes)).
ast_merge :: proc(dst: ^AST, src: ^AST) -> u32 {
	base := u32(len(dst.nodes))
	for node, i in src.nodes {
		append(&dst.nodes, _off_node(node, base))
		append(&dst.spans, src.spans[i])
	}
	return base
}

@private
_off_u :: proc(idx: u32, base: u32) -> u32 {
	if idx == INVALID_IDX { return INVALID_IDX }
	return idx + base
}

@private _off_e :: proc(i: ExpressionIdx, b: u32) -> ExpressionIdx { return ExpressionIdx(_off_u(u32(i), b)) }
@private _off_s :: proc(i: StatementIdx,  b: u32) -> StatementIdx  { return StatementIdx(_off_u(u32(i),  b)) }
@private _off_t :: proc(i: TypeIdx,       b: u32) -> TypeIdx       { return TypeIdx(_off_u(u32(i),       b)) }

@private
_off_maybe_e :: proc(m: Maybe(ExpressionIdx), b: u32) -> Maybe(ExpressionIdx) {
	if v, ok := m.?; ok { return _off_e(v, b) }
	return nil
}
@private
_off_maybe_t :: proc(m: Maybe(TypeIdx), b: u32) -> Maybe(TypeIdx) {
	if v, ok := m.?; ok { return _off_t(v, b) }
	return nil
}
@private
_off_maybe_s :: proc(m: Maybe(StatementIdx), b: u32) -> Maybe(StatementIdx) {
	if v, ok := m.?; ok { return _off_s(v, b) }
	return nil
}

@private
_off_block :: proc(bl: BlockExpression, b: u32) -> BlockExpression {
	new_stmts := make([]StatementIdx, len(bl.stmts))
	for s, i in bl.stmts { new_stmts[i] = _off_s(s, b) }
	return BlockExpression{stmts = new_stmts, result = _off_maybe_e(bl.result, b)}
}

@private
_off_slit_fields :: proc(fields: []StructLiteralField, b: u32) -> []StructLiteralField {
	nf := make([]StructLiteralField, len(fields))
	for f, i in fields { nf[i] = StructLiteralField{name = f.name, value = _off_e(f.value, b)} }
	return nf
}

@private
_off_node :: proc(node: Node, b: u32) -> Node {
	switch n in node {
	case Expression:
		switch e in n {
		case LiteralExpression: return Node(Expression(e))
		case IdentExpression:   return Node(Expression(e))
		case UnaryExpression:
			return Node(Expression(UnaryExpression{op = e.op, operand = _off_e(e.operand, b)}))
		case BinaryExpression:
			return Node(Expression(BinaryExpression{left = _off_e(e.left, b), right = _off_e(e.right, b), operation = e.operation}))
		case CallExpression:
			na := make([]ExpressionIdx, len(e.args))
			for a, i in e.args { na[i] = _off_e(a, b) }
			return Node(Expression(CallExpression{callee = _off_e(e.callee, b), args = na}))
		case FieldAccessExpression:
			return Node(Expression(FieldAccessExpression{object = _off_e(e.object, b), field = e.field}))
		case IndexExpression:
			return Node(Expression(IndexExpression{object = _off_e(e.object, b), index = _off_e(e.index, b)}))
		case IfExpression:
			var_else: Maybe(BlockExpression) = nil
			if eb, ok := e.else_block.?; ok { var_else = _off_block(eb, b) }
			return Node(Expression(IfExpression{condition = _off_e(e.condition, b), then_block = _off_block(e.then_block, b), else_block = var_else}))
		case MatchExpression:
			na := make([]MatchArm, len(e.arms))
			for a, i in e.arms { na[i] = MatchArm{pattern = _off_e(a.pattern, b), body = _off_e(a.body, b)} }
			return Node(Expression(MatchExpression{subject = _off_e(e.subject, b), arms = na}))
		case BlockExpression:
			return Node(Expression(_off_block(e, b)))
		case StructLiteralExpression:
			nta := make([]TypeIdx, len(e.type_args))
			for a, i in e.type_args { nta[i] = _off_t(a, b) }
			return Node(Expression(StructLiteralExpression{type_name = e.type_name, type_args = nta, fields = _off_slit_fields(e.fields, b), module = e.module, has_module = e.has_module}))
		case NewExpression:
			return Node(Expression(NewExpression{type_name = e.type_name, fields = _off_slit_fields(e.fields, b)}))
		case DerefExpression:
			return Node(Expression(DerefExpression{operand = _off_e(e.operand, b)}))
		case AddrOfExpression:
			return Node(Expression(AddrOfExpression{operand = _off_e(e.operand, b)}))
		case EnumLiteralExpression:
			return Node(Expression(EnumLiteralExpression{enum_name = e.enum_name, variant_name = e.variant_name, fields = _off_slit_fields(e.fields, b), module = e.module, has_module = e.has_module}))
		case ArrayLiteralExpression:
			nv := make([]ExpressionIdx, len(e.values))
			for v, i in e.values { nv[i] = _off_e(v, b) }
			return Node(Expression(ArrayLiteralExpression{elem_type = _off_t(e.elem_type, b), size = e.size, values = nv}))
		}
	case Statement:
		switch s in n {
		case LetStatement:
			return Node(Statement(LetStatement{name = s.name, type = _off_maybe_t(s.type, b), value = _off_e(s.value, b)}))
		case ConstStatement:
			return Node(Statement(ConstStatement{name = s.name, value = _off_e(s.value, b)}))
		case ReturnStatement:
			return Node(Statement(ReturnStatement{value = _off_maybe_e(s.value, b)}))
		case ExpressionStatement:
			return Node(Statement(ExpressionStatement{expr = _off_e(s.expr, b)}))
		case WithContextStatement:
			no := make([]ContextOverride, len(s.overrides))
			for o, i in s.overrides { no[i] = ContextOverride{key = o.key, value = _off_e(o.value, b)} }
			return Node(Statement(WithContextStatement{overrides = no, body = _off_block(s.body, b)}))
		case ForStatement:
			return Node(Statement(ForStatement{
				init      = _off_maybe_s(s.init, b),
				condition = _off_maybe_e(s.condition, b),
				post      = _off_maybe_s(s.post, b),
				body      = _off_block(s.body, b),
			}))
		case BreakStatement:    return Node(Statement(BreakStatement{}))
		case ContinueStatement: return Node(Statement(ContinueStatement{}))
		}
	case Declaration:
		switch d in n {
		case FunctionDecl:
			ntp := make([]lexer.Token, len(d.type_params)); copy(ntp, d.type_params)
			np  := make([]Param, len(d.params))
			for p, i in d.params { np[i] = Param{name = p.name, type = _off_t(p.type, b)} }
			return Node(Declaration(FunctionDecl{name = d.name, type_params = ntp, params = np, return_type = _off_maybe_t(d.return_type, b), body = _off_block(d.body, b)}))
		case StructDecl:
			ntp := make([]lexer.Token, len(d.type_params)); copy(ntp, d.type_params)
			nf  := make([]StructField, len(d.fields))
			for f, i in d.fields { nf[i] = StructField{name = f.name, type = _off_t(f.type, b)} }
			return Node(Declaration(StructDecl{name = d.name, type_params = ntp, qualifier = d.qualifier, fields = nf}))
		case EnumDecl:
			nv := make([]EnumVariant, len(d.variants)); copy(nv, d.variants)
			nf := make([]StructField, len(d.fields))
			for f, i in d.fields { nf[i] = StructField{name = f.name, type = _off_t(f.type, b)} }
			return Node(Declaration(EnumDecl{name = d.name, variants = nv, fields = nf}))
		case ImportDecl: return Node(Declaration(d))
		case ConstDecl:  return Node(Declaration(ConstDecl{name = d.name, value = _off_e(d.value, b)}))
		}
	case Type:
		switch t in n {
		case NamedType:  return Node(Type(t))
		case PointerType:
			return Node(Type(PointerType{inner = _off_t(t.inner, b)}))
		case ArrayType:
			return Node(Type(ArrayType{elem = _off_t(t.elem, b), size = t.size}))
		case GenericType:
			na := make([]TypeIdx, len(t.args))
			for a, i in t.args { na[i] = _off_t(a, b) }
			return Node(Type(GenericType{name = t.name, args = na}))
		case QualifiedType:
			na := make([]TypeIdx, len(t.type_args))
			for a, i in t.type_args { na[i] = _off_t(a, b) }
			return Node(Type(QualifiedType{module = t.module, name = t.name, type_args = na}))
		case FnType:
			np := make([]TypeIdx, len(t.params))
			for p, i in t.params { np[i] = _off_t(p, b) }
			return Node(Type(FnType{params = np, return_type = _off_maybe_t(t.return_type, b)}))
		}
	}
	return node
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
			case ArrayLiteralExpression:
				delete(e.values)
			case BinaryExpression, UnaryExpression,
			     FieldAccessExpression, IndexExpression,
			     LiteralExpression, IdentExpression,
			     DerefExpression, AddrOfExpression:
			}
		case Type:
			switch ty in n {
			case GenericType:   delete(ty.args)
			case QualifiedType: delete(ty.type_args)
			case FnType:        delete(ty.params)
			case NamedType, PointerType, ArrayType:
			}
		}
	}
	delete(ast.nodes)
	delete(ast.spans)
}

