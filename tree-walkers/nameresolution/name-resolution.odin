package nameresolution

import "core:fmt"
import "../../parser"
import "../../lexer"

// Index of the AST node that defines a name.
// May be a Declaration (FunctionDecl, StructDecl, ConstDecl),
// a Statement (LetStatement, ConstStatement),
// or for function parameters, the owning FunctionDecl's index.
DefIdx :: distinct u32

INVALID_DEF :: DefIdx(parser.INVALID_IDX)

NRError :: struct {
	span:    lexer.Span,
	message: string,
}

NRResult :: struct {
	resolutions: map[parser.ExpressionIdx]DefIdx,
	errors:      [MAX_NR_ERRORS]NRError,
	error_count: u16,
}

nr_result_destroy :: proc(r: ^NRResult) {
	delete(r.resolutions)
}

Scope :: map[string]DefIdx

NameResolver :: struct {
	ast:            ^parser.AST,
	scopes:         [dynamic]Scope, // scopes[0] = builtins; scopes[1..] = locals
	module_tops:    [dynamic]Scope, // module_tops[k] = top-level symbols of module k
	table:          ^parser.ModuleTable,
	current_module: parser.ModuleId,
	result:         NRResult,
}

@private
nr_enter_scope :: proc(nr: ^NameResolver) {
	append(&nr.scopes, make(Scope))
}

@private
nr_exit_scope :: proc(nr: ^NameResolver) {
	scope := pop(&nr.scopes)
	delete(scope)
}

@private
nr_define :: proc(nr: ^NameResolver, name: string, idx: DefIdx) {
	nr.scopes[len(nr.scopes) - 1][name] = idx
}

// nr_lookup resolves a bare (unqualified) name. Lookup order enforces module
// isolation: locals (inner→outer) → the current module's own top-level symbols →
// builtins. Other modules' symbols are deliberately NOT consulted, so a bare
// cross-module reference is "undefined" — access must be qualified (math.add).
@private
nr_lookup :: proc(nr: ^NameResolver, name: string) -> (DefIdx, bool) {
	// locals
	for i := len(nr.scopes) - 1; i >= 1; i -= 1 {
		if idx, ok := nr.scopes[i][name]; ok {
			return idx, true
		}
	}
	// current module's top-level symbols
	if int(nr.current_module) < len(nr.module_tops) {
		if idx, ok := nr.module_tops[nr.current_module][name]; ok {
			return idx, true
		}
	}
	// builtins (scopes[0])
	if len(nr.scopes) > 0 {
		if idx, ok := nr.scopes[0][name]; ok {
			return idx, true
		}
	}
	return INVALID_DEF, false
}

@private
nr_error :: proc(nr: ^NameResolver, span: lexer.Span, msg: string) {
	if nr.result.error_count >= MAX_NR_ERRORS do return
	nr.result.errors[nr.result.error_count] = NRError{span = span, message = msg}
	nr.result.error_count += 1
}

resolve_program :: proc(ast: ^parser.AST, table: ^parser.ModuleTable = nil) -> NRResult {
	// When no module table is supplied (single-file programs, unit tests), behave as
	// one main module with no imports.
	local_table: parser.ModuleTable
	use_table := table
	if use_table == nil {
		local_table = parser.module_table_init()
		use_table = &local_table
	}
	defer if table == nil { parser.module_table_destroy(&local_table) }

	module_count := len(use_table.names)
	nr := NameResolver{
		ast         = ast,
		scopes      = make([dynamic]Scope),
		module_tops = make([dynamic]Scope, module_count),
		table       = use_table,
		result = NRResult{
			resolutions = make(map[parser.ExpressionIdx]DefIdx),
		},
	}
	for i in 0..<module_count { nr.module_tops[i] = make(Scope) }
	defer {
		for scope in nr.scopes { delete(scope) }
		delete(nr.scopes)
		for scope in nr.module_tops { delete(scope) }
		delete(nr.module_tops)
	}

	// scopes[0] is the universal builtins scope, visible from every module.
	// INVALID_DEF tells the type checker there is no backing AST node for these names.
	nr_enter_scope(&nr)
	nr_define(&nr, "print", INVALID_DEF)
	nr_define(&nr, "input", INVALID_DEF)

	// Pass 1: register every top-level name into its OWNING module's scope so bodies
	// can reference module-mates in any order while staying isolated from other modules.
	// A name defined twice in the same module is an error — a directory is one module,
	// so this usually means two independent programs were merged into one.
	for node, i in ast.nodes {
		decl, ok := node.(parser.Declaration)
		if !ok do continue
		mod := parser.module_of(use_table, i)
		name: string
		name_tok: lexer.Token
		switch d in decl {
		case parser.FunctionDecl: name = d.name.data; name_tok = d.name
		case parser.StructDecl:   name = d.name.data; name_tok = d.name
		case parser.EnumDecl:     name = d.name.data; name_tok = d.name
		case parser.ConstDecl:    name = d.name.data; name_tok = d.name
		case parser.ImportDecl:   continue
		}
		if _, exists := nr.module_tops[mod][name]; exists {
			if use_table.names[mod] == "" {
				nr_error(&nr, name_tok.span, fmt.tprintf(
					"duplicate definition of '%s' — a directory is one module; give each program its own directory", name))
			} else {
				nr_error(&nr, name_tok.span, fmt.tprintf(
					"duplicate definition of '%s' in module '%s'", name, use_table.names[mod]))
			}
			continue // keep the first definition
		}
		nr.module_tops[mod][name] = DefIdx(i)
	}

	// Pass 2: resolve identifier references inside every declaration body, with
	// current_module set so unqualified lookups stay within the owning module.
	for node, i in ast.nodes {
		decl, ok := node.(parser.Declaration)
		if !ok do continue
		nr.current_module = parser.module_of(use_table, i)
		nr_resolve_decl(&nr, DefIdx(i), decl)
	}

	return nr.result
}

@private
nr_resolve_decl :: proc(nr: ^NameResolver, idx: DefIdx, decl: parser.Declaration) {
	switch d in decl {
	case parser.FunctionDecl:
		nr_enter_scope(nr)
		// params store the owning fn's DefIdx; type checker finds the param type by name
		for param in d.params {
			nr_define(nr, param.name.data, idx)
		}
		nr_resolve_block(nr, d.body)
		nr_exit_scope(nr)

	case parser.ConstDecl:
		nr_resolve_expr(nr, d.value)

	case parser.StructDecl, parser.EnumDecl, parser.ImportDecl:
		// no value-level identifiers to resolve
	}
}

@private
nr_resolve_block :: proc(nr: ^NameResolver, block: parser.BlockExpression) {
	nr_enter_scope(nr)
	for stmt_idx in block.stmts {
		nr_resolve_stmt(nr, stmt_idx)
	}
	if result, ok := block.result.?; ok {
		nr_resolve_expr(nr, result)
	}
	nr_exit_scope(nr)
}

@private
nr_resolve_stmt :: proc(nr: ^NameResolver, idx: parser.StatementIdx) {
	node := nr.ast.nodes[idx]
	stmt, ok := node.(parser.Statement)
	if !ok do return

	switch s in stmt {
	case parser.LetStatement:
		nr_resolve_expr(nr, s.value)          // resolve RHS before name is visible
		nr_define(nr, s.name.data, DefIdx(idx))

	case parser.ConstStatement:
		nr_resolve_expr(nr, s.value)
		nr_define(nr, s.name.data, DefIdx(idx))

	case parser.ReturnStatement:
		if val, ok := s.value.?; ok {
			nr_resolve_expr(nr, val)
		}

	case parser.ExpressionStatement:
		nr_resolve_expr(nr, s.expr)

	case parser.ForStatement:
		nr_enter_scope(nr)                     // scope for init variable
		if init, ok := s.init.?; ok {
			nr_resolve_stmt(nr, init)
		}
		if cond, ok := s.condition.?; ok {
			nr_resolve_expr(nr, cond)
		}
		if post, ok := s.post.?; ok {
			nr_resolve_stmt(nr, post)
		}
		nr_resolve_block(nr, s.body)
		nr_exit_scope(nr)

	case parser.WithContextStatement:
		for override in s.overrides {
			nr_resolve_expr(nr, override.value)
		}
		nr_resolve_block(nr, s.body)

	case parser.BreakStatement, parser.ContinueStatement:
	}
}

@private
nr_resolve_expr :: proc(nr: ^NameResolver, idx: parser.ExpressionIdx) {
	if u32(idx) == parser.INVALID_IDX do return
	node := nr.ast.nodes[idx]
	expr, ok := node.(parser.Expression)
	if !ok do return

	switch e in expr {
	case parser.IdentExpression:
		tok := lexer.Token(e)
		def, found := nr_lookup(nr, tok.data)
		if !found {
			nr_error(nr, tok.span, fmt.tprintf("undefined: '%s'", tok.data))
		} else {
			nr.result.resolutions[idx] = def
		}

	case parser.LiteralExpression:

	case parser.UnaryExpression:
		nr_resolve_expr(nr, e.operand)

	case parser.BinaryExpression:
		nr_resolve_expr(nr, e.left)
		nr_resolve_expr(nr, e.right)

	case parser.CallExpression:
		nr_resolve_expr(nr, e.callee)
		for arg in e.args {
			nr_resolve_expr(nr, arg)
		}

	case parser.FieldAccessExpression:
		// Qualified module access: `alias.member` where `alias` is in scope as an
		// import of the current module. Resolve the member in the target module's
		// top-level scope and record it so the type checker can type the access.
		obj_node := nr.ast.nodes[int(e.object)]
		if obj_expr, ok := obj_node.(parser.Expression); ok {
			if obj_id, is_id := obj_expr.(parser.IdentExpression); is_id {
				alias := lexer.Token(obj_id).data
				if mod, is_alias := nr.table.aliases[nr.current_module][alias]; is_alias {
					if def, found := nr.module_tops[mod][e.field.data]; found {
						nr.result.resolutions[idx] = def
					} else {
						nr_error(nr, e.field.span, fmt.tprintf("module '%s' has no member '%s'", alias, e.field.data))
					}
					return
				}
			}
		}
		nr_resolve_expr(nr, e.object)
		// field name resolved by the type checker once struct type is known

	case parser.IndexExpression:
		nr_resolve_expr(nr, e.object)
		nr_resolve_expr(nr, e.index)

	case parser.IfExpression:
		nr_resolve_expr(nr, e.condition)
		nr_resolve_block(nr, e.then_block)
		if eb, ok := e.else_block.?; ok {
			nr_resolve_block(nr, eb)
		}

	case parser.MatchExpression:
		nr_resolve_expr(nr, e.subject)
		for arm in e.arms {
			nr_enter_scope(nr)
			pattern_node := nr.ast.nodes[int(arm.pattern)]
			if pexpr, ok := pattern_node.(parser.Expression); ok {
				if enum_pat, is_enum := pexpr.(parser.EnumLiteralExpression); is_enum {
					for field in enum_pat.fields {
						fval_node := nr.ast.nodes[int(field.value)]
						if fexpr, fok := fval_node.(parser.Expression); fok {
							if ident, is_ident := fexpr.(parser.IdentExpression); is_ident {
								nr_define(nr, lexer.Token(ident).data, DefIdx(field.value))
							}
						}
					}
				}
			}
			nr_resolve_expr(nr, arm.body)
			nr_exit_scope(nr)
		}

	case parser.BlockExpression:
		nr_resolve_block(nr, e)

	case parser.StructLiteralExpression:
		// type_name is a type reference — resolved by type checker
		for field in e.fields {
			nr_resolve_expr(nr, field.value)
		}

	case parser.NewExpression:
		// type_name is a type reference — resolved by type checker
		for field in e.fields {
			nr_resolve_expr(nr, field.value)
		}

	case parser.EnumLiteralExpression:
		// enum_name and variant_name are type references — resolved by type checker
		for field in e.fields {
			nr_resolve_expr(nr, field.value)
		}

	case parser.DerefExpression:
		nr_resolve_expr(nr, e.operand)

	case parser.AddrOfExpression:
		nr_resolve_expr(nr, e.operand)

	case parser.ArrayLiteralExpression:
		for val in e.values { nr_resolve_expr(nr, val) }
	}
}
