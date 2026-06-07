package typechecker

import "core:fmt"
import "../../parser"
import "../../lexer"
import nr "../nameresolution"

// ---- entry point ----

typecheck :: proc(ast: ^parser.AST, nrr: ^nr.NRResult) -> TypecheckResult {
	tc := new_type_checker(ast, nrr)

	// Pass 1: register all top-level declaration signatures.
	for node, i in ast.nodes {
		decl, ok := node.(parser.Declaration)
		if !ok do continue

		register_decl(&tc, nr.DefIdx(i), decl)
	}

	// Pass 2: check all declaration bodies.
	for node, i in ast.nodes {
		decl, ok := node.(parser.Declaration)
		if !ok do continue

		check_decl(&tc, nr.DefIdx(i), decl)
	}

	return TypecheckResult{
		types       = tc.types,
		type_table  = tc.type_table,
		errors      = tc.errors,
		error_count = tc.err_count,
	}
}

// ---- pass 1: register signatures ----

@private
register_decl :: proc(tc: ^Typechecker, def: nr.DefIdx, decl: parser.Declaration) {
	switch d in decl {
	case parser.FunctionDecl:
		params := make([]TypeId, len(d.params))
		for param, i in d.params {
			params[i] = resolve_named_type(tc, param.type)
		}

		ret := VOID_TYPE
		if rt, ok := d.return_type.?; ok {
			ret = resolve_named_type(tc, rt)
		}
		tc.types[int(def)] = register_fn_type(tc, params, ret)

	case parser.ConstDecl:
		tc.types[int(def)] = infer(tc, d.value)

	case parser.StructDecl:
		field_names := make([]string, len(d.fields))
		field_types := make([]TypeId, len(d.fields))
		for field, i in d.fields {
			field_names[i] = field.name.data
			field_types[i] = resolve_named_type(tc, field.type)
		}
		st_id := TypeId(len(tc.type_table))
		append(&tc.type_table, TypeInfo(StructType{
			name        = d.name.data,
			field_names = field_names,
			field_types = field_types,
		}))
		tc.types[int(def)] = st_id

	case parser.EnumDecl, parser.ImportDecl:
	}
}

// ---- pass 2: check bodies ----

@private
check_decl :: proc(tc: ^Typechecker, def: nr.DefIdx, decl: parser.Declaration) {
	switch d in decl {
	case parser.FunctionDecl:
		info, ok := get_type_info(tc, tc.types[int(def)])
		if !ok do return

		fn, is_fn := info.(FnType)
		if !is_fn do return

		tc.current_fn_ret = fn.return_type
		check_block(tc, d.body, fn.return_type)
		tc.current_fn_ret = VOID_TYPE

	case parser.ConstDecl, parser.StructDecl, parser.EnumDecl, parser.ImportDecl:
	}
}

// check_block checks every statement and optionally checks the tail expression.
// Returns the type of the tail expression, or VOID_TYPE if there is none.
@private
check_block :: proc(tc: ^Typechecker, block: parser.BlockExpression, result_type: TypeId = VOID_TYPE) -> TypeId {
	for stmt_idx in block.stmts {
		check_stmt(tc, stmt_idx)
	}
	if result, ok := block.result.?; ok {
		if result_type != VOID_TYPE {
			check(tc, result, result_type)
		}
		return infer(tc, result)
	}
	return VOID_TYPE
}

@private
check_stmt :: proc(tc: ^Typechecker, idx: parser.StatementIdx) {
	node := tc.ast.nodes[int(idx)]
	stmt, ok := node.(parser.Statement)
	if !ok do return

	#partial switch s in stmt {
	case parser.LetStatement:
		if ann_idx, has_ann := s.type.?; has_ann {
			ann_type := resolve_named_type(tc, ann_idx)
			check(tc, s.value, ann_type)
			tc.types[int(idx)] = ann_type
		} else {
			tc.types[int(idx)] = infer(tc, s.value)
		}

	case parser.ConstStatement:
		tc.types[int(idx)] = infer(tc, s.value)

	case parser.ReturnStatement:
		if val, has_val := s.value.?; has_val {
			check(tc, val, tc.current_fn_ret)
		}

	case parser.ExpressionStatement:
		infer(tc, s.expr)

	case parser.ForStatement:
		if init, has_init := s.init.?; has_init {
			check_stmt(tc, init)
		}
		if cond, has_cond := s.condition.?; has_cond {
			check(tc, cond, BOOL_TYPE)
		}
		if post, has_post := s.post.?; has_post {
			check_stmt(tc, post)
		}
		check_block(tc, s.body)

	case parser.WithContextStatement:
		check_block(tc, s.body)

	case parser.BreakStatement, parser.ContinueStatement:
	}
}

// ---- bidirectional core ----

// infer returns the TypeId for expression idx, memoising the result.
@private
infer :: proc(tc: ^Typechecker, idx: parser.ExpressionIdx) -> TypeId {
	if u32(idx) == parser.INVALID_IDX do return UNKNOWN_TYPE

	cached := tc.types[int(idx)]
	if cached != UNKNOWN_TYPE do return cached

	t := infer_inner(tc, idx)
	if t != UNKNOWN_TYPE {
		tc.types[int(idx)] = t
	}
	return t
}

@private
infer_inner :: proc(tc: ^Typechecker, idx: parser.ExpressionIdx) -> TypeId {
	node := tc.ast.nodes[int(idx)]
	expr, ok := node.(parser.Expression)
	if !ok do return UNKNOWN_TYPE

	switch e in expr {
	case parser.LiteralExpression:
		#partial switch lexer.Token(e).kind {
		case .INT:          return INT_TYPE
		case .FLOAT:        return FLOAT_TYPE
		case .TRUE, .FALSE: return BOOL_TYPE
		case .STRING:       return STRING_TYPE
		}

	case parser.IdentExpression:
		tok := lexer.Token(e)
		def, found := tc.nr.resolutions[idx]
		if !found do return UNKNOWN_TYPE
		if def == nr.INVALID_DEF do return UNKNOWN_TYPE  // VM built-in, no AST node
		// When the def points to a FunctionDecl, the ident might be a param name.
		def_node := tc.ast.nodes[int(def)]
		if decl, is_decl := def_node.(parser.Declaration); is_decl {
			if fn_decl, is_fn := decl.(parser.FunctionDecl); is_fn {
				for param in fn_decl.params {
					if param.name.data == tok.data {
						return resolve_named_type(tc, param.type)
					}
				}
			}
		}
		return type_of_def(tc, def)

	case parser.UnaryExpression:
		return infer_unary(tc, e)

	case parser.BinaryExpression:
		return infer_binary(tc, e)

	case parser.CallExpression:
		return infer_call(tc, idx, e)

	case parser.BlockExpression:
		return check_block(tc, e)

	case parser.IfExpression:
		check(tc, e.condition, BOOL_TYPE)
		then_type := check_block(tc, e.then_block)
		if eb, has_else := e.else_block.?; has_else {
			else_type := check_block(tc, eb)
			if then_type != UNKNOWN_TYPE && else_type != UNKNOWN_TYPE && then_type != else_type {
				tc_error(tc, tc.ast.spans[int(idx)], then_type, else_type)
			}
		}
		return then_type

	case parser.FieldAccessExpression:
		return infer_field_access(tc, idx, e)

	case parser.IndexExpression:
		return UNKNOWN_TYPE

	case parser.MatchExpression:
		return UNKNOWN_TYPE

	case parser.StructLiteralExpression:
		return infer_struct_literal(tc, idx, e)
	}
	return UNKNOWN_TYPE
}

// check verifies expression idx has type expected, reporting a mismatch if not.
@private
check :: proc(tc: ^Typechecker, idx: parser.ExpressionIdx, expected: TypeId) {
	if u32(idx) == parser.INVALID_IDX do return
	if expected == UNKNOWN_TYPE do return

	// Integer literal is coercible to float.
	if expected == FLOAT_TYPE {
		node := tc.ast.nodes[int(idx)]
		if expr, ok := node.(parser.Expression); ok {
			if lit, ok := expr.(parser.LiteralExpression); ok {
				if lexer.Token(lit).kind == .INT {
					tc.types[int(idx)] = FLOAT_TYPE
					return
				}
			}
		}
	}

	got := infer(tc, idx)
	if got == UNKNOWN_TYPE do return
	if got != expected {
		tc_error(tc, tc.ast.spans[int(idx)], expected, got)
	}
}

// ---- expression inference helpers ----

@private
infer_unary :: proc(tc: ^Typechecker, e: parser.UnaryExpression) -> TypeId {
	#partial switch e.op.kind {
	case .MINUS:
		t := infer(tc, e.operand)
		if t != INT_TYPE && t != FLOAT_TYPE && t != UNKNOWN_TYPE {
			tc_error(tc, e.op.span, INT_TYPE, t)
		}
		return t
	case .BANG:
		check(tc, e.operand, BOOL_TYPE)
		return BOOL_TYPE
	case .TILDE:
		check(tc, e.operand, INT_TYPE)
		return INT_TYPE
	}
	return UNKNOWN_TYPE
}

@private
infer_binary :: proc(tc: ^Typechecker, e: parser.BinaryExpression) -> TypeId {
	#partial switch e.operation.kind {
	// Arithmetic: both sides same type, result same type.
	case .PLUS, .MINUS, .STAR, .SLASH, .PERCENT:
		left := infer(tc, e.left)
		check(tc, e.right, left)
		return left

	// Comparison: both sides same type, result bool.
	case .EQ_EQ, .BANG_EQ, .LT, .LT_EQ, .GT, .GT_EQ:
		left := infer(tc, e.left)
		check(tc, e.right, left)
		return BOOL_TYPE

	// Logical: both sides bool, result bool.
	case .AND, .OR:
		check(tc, e.left, BOOL_TYPE)
		check(tc, e.right, BOOL_TYPE)
		return BOOL_TYPE

	// Bitwise: both sides int, result int.
	case .AMPERSAND, .PIPE, .CARET, .LT_LT, .GT_GT:
		check(tc, e.left, INT_TYPE)
		check(tc, e.right, INT_TYPE)
		return INT_TYPE

	// Assignment: check RHS against LHS type.
	case .EQ, .PLUS_EQ, .MINUS_EQ, .STAR_EQ, .SLASH_EQ, .PERCENT_EQ:
		left := infer(tc, e.left)
		check(tc, e.right, left)
		return VOID_TYPE
	}
	return UNKNOWN_TYPE
}

@private
infer_call :: proc(tc: ^Typechecker, call_idx: parser.ExpressionIdx, e: parser.CallExpression) -> TypeId {
	callee_type := infer(tc, e.callee)
	if callee_type == UNKNOWN_TYPE do return UNKNOWN_TYPE

	info, ok := get_type_info(tc, callee_type)
	if !ok {
		tc_error_msg(tc, tc.ast.spans[int(call_idx)], "not callable")
		return UNKNOWN_TYPE
	}
	fn, is_fn := info.(FnType)
	if !is_fn {
		tc_error_msg(tc, tc.ast.spans[int(call_idx)], "not callable")
		return UNKNOWN_TYPE
	}

	if len(e.args) != len(fn.params) {
		tc_error_msg(tc, tc.ast.spans[int(call_idx)],
			fmt.tprintf("expected %d argument(s), got %d", len(fn.params), len(e.args)))
		return fn.return_type
	}

	for arg, i in e.args {
		check(tc, arg, fn.params[i])
	}
	return fn.return_type
}

// ---- type table helpers ----

@private
type_of_def :: proc(tc: ^Typechecker, def: nr.DefIdx) -> TypeId {
	cached := tc.types[int(def)]
	if cached != UNKNOWN_TYPE do return cached

	// Fallback for const statements inside function bodies.
	node := tc.ast.nodes[int(def)]
	if stmt, ok := node.(parser.Statement); ok {
		if cs, ok := stmt.(parser.ConstStatement); ok {
			t := infer(tc, cs.value)
			tc.types[int(def)] = t
			return t
		}
	}
	return UNKNOWN_TYPE
}

// resolve_named_type converts a TypeIdx (a type annotation in the AST) to a TypeId.
@private
resolve_named_type :: proc(tc: ^Typechecker, type_idx: parser.TypeIdx) -> TypeId {
	if int(type_idx) >= len(tc.ast.nodes) do return UNKNOWN_TYPE
	node := tc.ast.nodes[int(type_idx)]
	ty, ok := node.(parser.Type)
	if !ok do return UNKNOWN_TYPE

	switch t in ty {
	case parser.NamedType:
		name := lexer.Token(t).data
		switch name {
		case "void":            return VOID_TYPE
		case "bool":            return BOOL_TYPE
		case "i64",  "int":    return INT_TYPE
		case "f64",  "float":  return FLOAT_TYPE
		case "str",  "string": return STRING_TYPE
		}
		for info, i in tc.type_table {
			if st, ok2 := info.(StructType); ok2 && st.name == name {
				return TypeId(i)
			}
		}
		return UNKNOWN_TYPE

	case parser.FnType:
		params := make([]TypeId, len(t.params))
		for param_idx, i in t.params {
			params[i] = resolve_named_type(tc, param_idx)
		}
		ret := VOID_TYPE
		if rt, has_rt := t.return_type.?; has_rt {
			ret = resolve_named_type(tc, rt)
		}
		return register_fn_type(tc, params, ret)

	case parser.GenericType:
		return UNKNOWN_TYPE
	}
	return UNKNOWN_TYPE
}

// register_fn_type interns a function type, deduplicating by structural equality.
@private
register_fn_type :: proc(tc: ^Typechecker, params: []TypeId, ret: TypeId) -> TypeId {
	outer: for info, i in tc.type_table {
		fn, ok := info.(FnType)
		if !ok do continue
		if fn.return_type != ret || len(fn.params) != len(params) do continue
		for j in 0..<len(params) {
			if fn.params[j] != params[j] do continue outer
		}
		delete(params)
		return TypeId(i)
	}
	id := TypeId(len(tc.type_table))
	append(&tc.type_table, TypeInfo(FnType{params = params, return_type = ret}))
	return id
}

@private
get_type_info :: proc(tc: ^Typechecker, id: TypeId) -> (TypeInfo, bool) {
	if id == UNKNOWN_TYPE || int(id) >= len(tc.type_table) {
		return nil, false
	}
	return tc.type_table[id], true
}

// ---- error reporting ----

@private
infer_struct_literal :: proc(tc: ^Typechecker, idx: parser.ExpressionIdx, e: parser.StructLiteralExpression) -> TypeId {
	struct_type_id := UNKNOWN_TYPE
	found_st: StructType
	for info, i in tc.type_table {
		if st, ok := info.(StructType); ok && st.name == e.type_name.data {
			struct_type_id = TypeId(i)
			found_st = st
			break
		}
	}
	if struct_type_id == UNKNOWN_TYPE {
		tc_error_msg(tc, tc.ast.spans[int(idx)], fmt.tprintf("undefined struct '%s'", e.type_name.data))
		return UNKNOWN_TYPE
	}
	for lit_field in e.fields {
		field_found := false
		for j in 0..<len(found_st.field_names) {
			if found_st.field_names[j] == lit_field.name.data {
				check(tc, lit_field.value, found_st.field_types[j])
				field_found = true
				break
			}
		}
		if !field_found {
			tc_error_msg(tc, tc.ast.spans[int(idx)],
				fmt.tprintf("unknown field '%s' on struct '%s'", lit_field.name.data, e.type_name.data))
		}
	}
	return struct_type_id
}

@private
infer_field_access :: proc(tc: ^Typechecker, idx: parser.ExpressionIdx, e: parser.FieldAccessExpression) -> TypeId {
	obj_type := infer(tc, e.object)
	if obj_type == UNKNOWN_TYPE do return UNKNOWN_TYPE
	info, ok := get_type_info(tc, obj_type)
	if !ok do return UNKNOWN_TYPE
	st, is_struct := info.(StructType)
	if !is_struct {
		tc_error_msg(tc, e.field.span, "field access on non-struct value")
		return UNKNOWN_TYPE
	}
	for j in 0..<len(st.field_names) {
		if st.field_names[j] == e.field.data {
			return st.field_types[j]
		}
	}
	tc_error_msg(tc, e.field.span,
		fmt.tprintf("no field '%s' on struct '%s'", e.field.data, st.name))
	return UNKNOWN_TYPE
}

@private
tc_error :: proc(tc: ^Typechecker, span: lexer.Span, expected, found: TypeId) {
	if tc.err_count >= MAX_TYPE_ERRORS do return
	tc.errors[tc.err_count] = TypeCheckerError{expected = expected, found = found, span = span}
	tc.err_count += 1
}

@private
tc_error_msg :: proc(tc: ^Typechecker, span: lexer.Span, message: string) {
	if tc.err_count >= MAX_TYPE_ERRORS do return
	tc.errors[tc.err_count] = TypeCheckerError{message = message, span = span}
	tc.err_count += 1
}
