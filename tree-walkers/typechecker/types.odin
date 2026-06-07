package typechecker

import "../../parser"
import "../../lexer"
import nr "../nameresolution"

TypeId :: distinct u16

// Primitive type categories. Order must match the VOID_TYPE..STRING_TYPE constants.
PrimitiveType :: enum u8 {
	VOID,
	BOOL,
	INT,
	FLOAT,
	STRING,
}

// Function type stored in the type table.
// params is owned by this struct; caller must delete when destroying.
FnType :: struct {
	params:      []TypeId,
	return_type: TypeId,
}

// Struct type stored in the type table.
// field_names and field_types are owned; caller must delete when destroying.
StructType :: struct {
	name:        string,
	field_names: []string,
	field_types: []TypeId,
}

// TypeInfo is the entry stored in the type table.
TypeInfo :: union {
	PrimitiveType,
	FnType,
	StructType,
}

TypeCheckerError :: struct {
	message:  string,   // non-empty for non-mismatch errors
	expected: TypeId,
	found:    TypeId,
	span:     lexer.Span,
}

TypecheckResult :: struct {
	types:       []TypeId,
	type_table:  [dynamic]TypeInfo,
	errors:      [MAX_TYPE_ERRORS]TypeCheckerError,
	error_count: u16,
}

Typechecker :: struct {
	ast:            ^parser.AST,
	nr:             ^nr.NRResult,
	types:          []TypeId,          // one entry per ast.nodes element; UNKNOWN_TYPE = not checked
	type_table:     [dynamic]TypeInfo,
	current_fn_ret: TypeId,            // return type of function being checked
	err_count:      u16,
	errors:         [MAX_TYPE_ERRORS]TypeCheckerError,
}

new_type_checker :: proc(ast: ^parser.AST, nrr: ^nr.NRResult) -> Typechecker {
	assert(nrr.error_count == 0, "type checking requires clean name resolution")

	tc := Typechecker{
		ast            = ast,
		nr             = nrr,
		types          = make([]TypeId, len(ast.nodes)),
		type_table     = make([dynamic]TypeInfo),
		current_fn_ret = VOID_TYPE,
	}

	for &t in tc.types { t = UNKNOWN_TYPE }

	// Pre-register primitives — indices must match VOID_TYPE..STRING_TYPE constants.
	append(&tc.type_table, TypeInfo(PrimitiveType.VOID))
	append(&tc.type_table, TypeInfo(PrimitiveType.BOOL))
	append(&tc.type_table, TypeInfo(PrimitiveType.INT))
	append(&tc.type_table, TypeInfo(PrimitiveType.FLOAT))
	append(&tc.type_table, TypeInfo(PrimitiveType.STRING))

	return tc
}

// type_id_name returns a source-level spelling for a TypeId.
// Used for error messages; the returned string is a string literal (no allocation).
type_id_name :: proc(id: TypeId, table: []TypeInfo) -> string {
	if id == UNKNOWN_TYPE || int(id) >= len(table) { return "unknown" }
	#partial switch t in table[id] {
	case PrimitiveType:
		switch t {
		case .VOID:   return "void"
		case .BOOL:   return "bool"
		case .INT:    return "i64"
		case .FLOAT:  return "f64"
		case .STRING: return "str"
		}
	case FnType:
		return "function"
	case StructType:
		return t.name
	}
	return "unknown"
}

tc_result_destroy :: proc(r: ^TypecheckResult) {
	for info in r.type_table {
		#partial switch t in info {
		case FnType:     delete(t.params)
		case StructType: delete(t.field_names); delete(t.field_types)
		}
	}
	delete(r.type_table)
	delete(r.types)
}
