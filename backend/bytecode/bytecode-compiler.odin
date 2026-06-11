package bytecode

import "../../parser"
import "../../lexer"
import tc "../../tree-walkers/typechecker"
import "core:strconv"
import "core:fmt"
import "core:strings"

CompilerError :: struct {
	message: string,
	span:    lexer.Span,
}

LoopCtx :: struct {
	start:       u16,                  // bytecode offset of the condition (for continue)
	local_base:  int,                  // len(locals) at loop entry (for emit POPs on break/continue)
	breaks:      [MAX_BREAK_COUNT]u16, // JUMP offsets waiting to be patched to after the loop
	break_count: u8,
}

StructLayout :: struct {
	field_names:        []string,
	field_offsets:      []int,
	field_struct_types: []string, // "" for scalars/pointers, struct name for flat struct fields
	field_ptr_inners:   []string, // "" for non-pointers, "T" for ^T pointer fields
	total_slots:        int,
}

EnumVariantLayout :: struct {
	discriminant:  int,
	field_names:   []string,
	field_offsets: []int, // 0-based within the variant (does not include the discriminant slot)
	total_slots:   int,   // number of field slots for this variant only (not including discriminant)
}

EnumLayout :: struct {
	total_slots: int,              // 1 (discriminant) + max(variant.total_slots) across all variants
	variants:    map[string]EnumVariantLayout,
}

InlineFnInfo :: struct {
	decl: parser.FunctionDecl,
}

Compiler :: struct {
	bc:                ByteCodeCompiler,
	ast:               ^parser.AST,
	errors:            [MAX_ERROR_COUNT]CompilerError,
	error_count:       u8,
	loop_ctx:          ^LoopCtx,
	const_table:       map[string]Value,
	struct_layouts:    ^map[string]StructLayout,
	enum_layouts:      map[string]EnumLayout,
	tc_types:          []tc.TypeId,
	tc_type_table:     []tc.TypeInfo,
	generic_templates:        map[string]parser.FunctionDecl,
	generic_struct_templates: map[string]parser.StructDecl,
	generic_emitted:          map[string]bool,
	type_subst:               map[string]string,
	global_slots:             map[string]u16,
	global_count:             u16,
	root:                     ^Compiler,
	// inlining
	inline_fns:         map[string]InlineFnInfo, // shared via root
	inline_fn_name:     string,                  // non-empty when inlining (prevents recursion)
	inline_result_slot: int,                     // stack slot holding the return value
	inline_patches:     [dynamic]int,            // JUMP offsets to patch at inline exit
}

new_compiler :: proc(ast: ^parser.AST, tc_types: []tc.TypeId = nil, tc_type_table: []tc.TypeInfo = nil) -> Compiler {
	sl := new(map[string]StructLayout)
	sl^ = make(map[string]StructLayout)
	return Compiler{
		bc                = new_bytecode_compiler("__main__", 0),
		ast               = ast,
		const_table       = make(map[string]Value),
		struct_layouts    = sl,
		enum_layouts      = make(map[string]EnumLayout),
		tc_types          = tc_types,
		tc_type_table     = tc_type_table,
		generic_templates        = make(map[string]parser.FunctionDecl),
		generic_struct_templates = make(map[string]parser.StructDecl),
		generic_emitted          = make(map[string]bool),
		type_subst               = make(map[string]string),
		global_slots             = make(map[string]u16),
		inline_fns               = make(map[string]InlineFnInfo),
		inline_patches           = make([dynamic]int),
	}
}

compiler_destroy :: proc(c: ^Compiler) {
	compiler_free(&c.bc)
	delete(c.const_table)
	delete(c.generic_templates)
	delete(c.generic_struct_templates)
	delete(c.generic_emitted)
	delete(c.type_subst)
	delete(c.global_slots)
	delete(c.inline_fns)
	delete(c.inline_patches)
}

// assign_global_slot returns the runtime slot for a global name, allocating one if new.
// Always operates on the root compiler so all child compilers share the same table.
assign_global_slot :: proc(c: ^Compiler, name: string) -> u16 {
	root := c if c.root == nil else c.root
	if slot, ok := root.global_slots[name]; ok { return slot }
	slot := root.global_count
	root.global_slots[name] = slot
	root.global_count += 1
	return slot
}

compile :: proc(ast: ^parser.AST, tc_types: []tc.TypeId = nil, tc_type_table: []tc.TypeInfo = nil) -> (^Function, []CompilerError) {
	c := new_compiler(ast, tc_types, tc_type_table)

	for node in ast.nodes {
		if decl, ok := node.(parser.Declaration); ok {
			if sd, ok2 := decl.(parser.StructDecl); ok2 {
				if len(sd.type_params) > 0 {
					c.generic_struct_templates[sd.name.data] = sd
				} else {
					c.struct_layouts^[sd.name.data] = build_struct_layout(&c, sd)
				}
			} else if ed, ok2 := decl.(parser.EnumDecl); ok2 {
				c.enum_layouts[ed.name.data] = build_enum_layout(&c, ed)
			} else if fn, ok2 := decl.(parser.FunctionDecl); ok2 {
				if len(fn.type_params) > 0 {
					c.generic_templates[fn.name.data] = fn
				}
			}
		}
	}

	for node, i in ast.nodes {
		if _, is_decl := node.(parser.Declaration); is_decl {
			compile_decl(&c, parser.DeclarationIdx(i))
		}
	}

	// call main — leave its return value on the stack so __main__ returns it
	main_slot := assign_global_slot(&c, "main")
	emit(&c.bc, .GET_GLOBAL, {})
	emit_byte(&c.bc, u8(main_slot), {})
	emit(&c.bc, .CALL, {})
	emit_byte(&c.bc, 0, {})

	emit(&c.bc, .RETURN, {})
	emit_byte(&c.bc, 1, {})

	errors := c.errors[:c.error_count]
	if c.error_count > 0 {
		fn := compiler_end(&c.bc)
		function_free(fn)
		return nil, errors
	}

	return compiler_end(&c.bc), errors
}

// ---- declarations ----

compile_decl :: proc(c: ^Compiler, idx: parser.DeclarationIdx) {
	node := c.ast.nodes[idx]
	span := c.ast.spans[idx]

	switch d in node.(parser.Declaration) {
	case parser.FunctionDecl:
		if len(d.type_params) > 0 { return } // generic — already instantiated in pre-scan
		compile_function(c, d, d.name.data, span)
	case parser.ConstDecl:
		if val, ok := eval_const_expr(c, d.value, span); ok {
			c.const_table[d.name.data] = val
		}
	case parser.ImportDecl:
		// skip for now
	case parser.StructDecl:
		if len(d.type_params) > 0 { return }
		layout := build_struct_layout(c, d)
		c.struct_layouts^[d.name.data] = layout
	case parser.EnumDecl:
		layout := build_enum_layout(c, d)
		c.enum_layouts[d.name.data] = layout
	}
}

emit_inline_call :: proc(c: ^Compiler, fn_info: InlineFnInfo, args: []parser.ExpressionIdx, span: lexer.Span) {
	// Reserve result slot at the bottom of the inline area.
	result_slot := 0
	for local in c.bc.locals { result_slot += local.slots }
	emit(&c.bc, .NIL, span)
	add_local(&c.bc, "__inline_result__")

	// Evaluate each arg and register it as a named local (param binding).
	// Pass full type metadata so field access on pointer/struct params resolves correctly.
	for i in 0..<len(fn_info.decl.params) {
		compile_expr(c, args[i])
		param       := fn_info.decl.params[i]
		ptr_inner   := type_ann_ptr_inner(c, param.type)
		struct_name := type_ann_struct_name(c, param.type)
		enum_name   := type_ann_enum_name(c, param.type)
		add_local(&c.bc, param.name.data, 1, struct_name, ptr_inner, enum_name)
	}

	// Save inline context, set new context.
	saved_name    := c.inline_fn_name
	saved_slot    := c.inline_result_slot
	saved_patches := c.inline_patches
	c.inline_fn_name    = fn_info.decl.name.data
	c.inline_result_slot = result_slot
	c.inline_patches    = make([dynamic]int)

	// Compile the body. compile_fn_body removes body locals without emitting POPs;
	// our inline-return handler already did the cleanup at each return site.
	compile_fn_body(c, fn_info.decl.body)

	// Fallthrough handler: reached end of body without an explicit return.
	// Dead code for functions that always return explicitly, but harmless.
	{
		emit(&c.bc, .NIL, span)
		emit(&c.bc, .SET_LOCAL, span)
		emit_byte(&c.bc, u8(result_slot), span)
		emit(&c.bc, .POP, span)
		total := 0
		for local in c.bc.locals { total += local.slots }
		for _ in 0..<(total - (result_slot + 1)) { emit(&c.bc, .POP, span) }
		patch, _ := emit_jump(&c.bc, .JUMP, span)
		append(&c.inline_patches, int(patch))
	}

	// Patch all return-site JUMPs to the current position.
	for patch in c.inline_patches { patch_jump(&c.bc, u16(patch)) }

	// Restore inline context.
	delete(c.inline_patches)
	c.inline_fn_name    = saved_name
	c.inline_result_slot = saved_slot
	c.inline_patches    = saved_patches

	// Remove param locals and result local from bc.locals without emitting POPs.
	// (Stack cleanup was done at each return site.)
	for _ in 0..<(1 + len(fn_info.decl.params)) { pop(&c.bc.locals) }
	// Result value is now on the stack at result_slot; stack_top = result_slot + 1.
}

compile_function :: proc(c: ^Compiler, d: parser.FunctionDecl, emit_name: string, span: lexer.Span) {
	// Compute total slot count for arity: struct and enum params occupy N slots each.
	total_param_slots := 0
	for param in d.params {
		struct_name := type_ann_struct_name(c, param.type)
		enum_name   := type_ann_enum_name(c, param.type)
		slots := 1
		if struct_name != "" {
			if layout, ok := c.struct_layouts^[struct_name]; ok {
				slots = layout.total_slots
			}
		} else if enum_name != "" {
			if layout, ok := c.enum_layouts[enum_name]; ok {
				slots = layout.total_slots
			}
		}
		total_param_slots += slots
	}

	// create a child compiler for this function
	fn_compiler := new_bytecode_compiler(emit_name, u8(total_param_slots), &c.bc)

	// slot 0 is the function itself (allows recursion, matches VM frame layout)
	add_local(&fn_compiler, emit_name)
	// parameters start at slot 1; register each with its actual slot count
	for param in d.params {
		struct_name := type_ann_struct_name(c, param.type)
		enum_name   := type_ann_enum_name(c, param.type)
		ptr_inner   := type_ann_ptr_inner(c, param.type)
		slots := 1
		if struct_name != "" {
			if layout, ok := c.struct_layouts^[struct_name]; ok {
				slots = layout.total_slots
			}
		} else if enum_name != "" {
			if layout, ok := c.enum_layouts[enum_name]; ok {
				slots = layout.total_slots
			}
		}
		add_local(&fn_compiler, param.name.data, slots, struct_name, ptr_inner, enum_name)
	}

	// compile body — child shares all read-only tables and the generic registry.
	// Each child gets its OWN copy of type_subst so that clearing the root's
	// substitution during a nested instantiation does not affect this child's view.
	// root points to the __main__ compiler so nested generic instantiations can
	// emit DEFINE_GLOBAL into the top-level chunk from inside a function body.
	root_c := c.root
	if root_c == nil { root_c = c }
	child_subst := make(map[string]string)
	for k, v in c.type_subst { child_subst[k] = v }
	child := Compiler{
		bc                = fn_compiler,
		ast               = c.ast,
		errors            = c.errors,
		error_count       = c.error_count,
		const_table       = c.const_table,
		struct_layouts    = c.struct_layouts,
		enum_layouts      = c.enum_layouts,
		tc_types          = c.tc_types,
		tc_type_table     = c.tc_type_table,
		generic_templates        = c.generic_templates,
		generic_struct_templates = c.generic_struct_templates,
		generic_emitted          = c.generic_emitted,
		type_subst               = child_subst,
		global_slots             = c.global_slots,
		root                     = root_c,
		inline_fns               = c.inline_fns,
		inline_patches           = make([dynamic]int),
	}
	compile_fn_body(&child, d.body)
	emit(&child.bc, .RETURN, span)
	emit_byte(&child.bc, 1, span)
	c.errors      = child.errors
	c.error_count = child.error_count
	delete(child.inline_patches)

	// get compiled function
	fn := compiler_end(&child.bc)

	// emit function as a constant in parent, bind to emit_name
	emit_constant(&c.bc, fn, span)
	emit(&c.bc, .DEFINE_GLOBAL, span)
	emit_byte(&c.bc, u8(assign_global_slot(c, emit_name)), span)

	// Register in inline_fns if eligible:
	//   non-generic, all 1-slot params, 1-slot return, no tail expression, not recursive
	if len(d.type_params) == 0 && len(d.params) <= 8 {
		if _, has_tail := d.body.result.?; !has_tail {
			eligible := true
			for param in d.params {
				if type_ann_struct_name(c, param.type) != "" || type_ann_enum_name(c, param.type) != "" {
					eligible = false
					break
				}
			}
			// Exclude functions that return multi-slot types (struct/enum return values):
			// the inline return handler only stores the top stack slot.
			if eligible {
				if ret_idx, has_ret := d.return_type.?; has_ret {
					if type_ann_struct_name(c, ret_idx) != "" || type_ann_enum_name(c, ret_idx) != "" {
						eligible = false
					}
				}
			}
			if eligible && body_calls_self(c.ast, d.body, emit_name) {
				eligible = false
			}
			if eligible {
				root_c.inline_fns[emit_name] = InlineFnInfo{decl = d}
			}
		}
	}
}

// body_calls_self returns true if any CallExpression in the body directly calls `name`.
// Used to exclude recursive functions from inlining.
body_calls_self :: proc(ast: ^parser.AST, block: parser.BlockExpression, name: string) -> bool {
	for stmt_idx in block.stmts {
		if stmt_calls(ast, stmt_idx, name) { return true }
	}
	return false
}

stmt_calls :: proc(ast: ^parser.AST, idx: parser.StatementIdx, name: string) -> bool {
	node := ast.nodes[idx]
	#partial switch s in node.(parser.Statement) {
	case parser.ExpressionStatement: return expr_calls(ast, s.expr, name)
	case parser.ReturnStatement:
		if val, ok := s.value.?; ok { return expr_calls(ast, val, name) }
	case parser.LetStatement:        return expr_calls(ast, s.value, name)
	case parser.ForStatement:
		if cond, ok := s.condition.?; ok {
			if expr_calls(ast, cond, name) { return true }
		}
		return body_calls_self(ast, s.body, name)
	}
	return false
}

expr_calls :: proc(ast: ^parser.AST, idx: parser.ExpressionIdx, name: string) -> bool {
	node := ast.nodes[idx]
	#partial switch e in node.(parser.Expression) {
	case parser.CallExpression:
		callee_node := ast.nodes[e.callee]
		if expr, ok := callee_node.(parser.Expression); ok {
			if id, ok2 := expr.(parser.IdentExpression); ok2 {
				if lexer.Token(id).data == name { return true }
			}
		}
		for arg in e.args { if expr_calls(ast, arg, name) { return true } }
	case parser.BinaryExpression:
		return expr_calls(ast, e.left, name) || expr_calls(ast, e.right, name)
	case parser.UnaryExpression:
		return expr_calls(ast, e.operand, name)
	case parser.IfExpression:
		if expr_calls(ast, e.condition, name) { return true }
		if body_calls_self(ast, e.then_block, name) { return true }
		if else_block, ok := e.else_block.?; ok {
			return body_calls_self(ast, else_block, name)
		}
	}
	return false
}

// ---- blocks ----

// compile_block is for inner blocks (arm bodies, if-else branches, loop bodies).
//
// When the block has a tail expression, we pre-reserve a single stack slot at the
// OUTER scope depth (before the block's scope opens) to hold the result.  This
// keeps the slot below all block-local variables so end_scope can POP block locals
// without touching it.  The tail expression is compiled while block locals are still
// live (so it can reference them), then SET_LOCAL'd into the reserved slot.
// The caller is responsible for consuming the result value (e.g. compile_for pops it
// after each iteration; compile_if already handles it via its NIL-guard).
compile_block :: proc(c: ^Compiler, block: parser.BlockExpression) {
	// Pre-reserve result slot at outer depth if the block produces a value.
	result_slot := -1
	if _, has_result := block.result.?; has_result {
		result_slot = 0
		for local in c.bc.locals { result_slot += local.slots }
		emit(&c.bc, .NIL, {})
		append(&c.bc.locals, Local{
			name  = "__block_result__",
			depth = c.bc.scope_depth,  // outer depth — end_scope for THIS block skips it
			slots = 1,
		})
	}

	c.bc.scope_depth += 1
	for stmt in block.stmts {
		compile_stmt(c, stmt)
	}

	if result, ok := block.result.?; ok {
		compile_expr(c, result)                    // block locals still live here
		emit(&c.bc, .SET_LOCAL, {})
		emit_byte(&c.bc, u8(result_slot), {})
		emit(&c.bc, .POP, {})                      // remove extra copy from top
	}

	end_scope(c)                                   // pops block-local vars only

	if result_slot >= 0 {
		pop(&c.bc.locals)                          // remove __block_result__ sentinel
	}
}

// compile_fn_body is for function bodies only. RETURN resets the frame's stack_top,
// so end_scope's POPs are not needed — omitting them lets the result expression
// freely reference any variable defined in the function body's stmts.
compile_fn_body :: proc(c: ^Compiler, block: parser.BlockExpression) {
	c.bc.scope_depth += 1
	for stmt in block.stmts {
		compile_stmt(c, stmt)
	}
	if result, ok := block.result.?; ok {
		compile_expr(c, result)
	}
	// Update scope tracking without emitting POPs — RETURN handles frame cleanup.
	c.bc.scope_depth -= 1
	for len(c.bc.locals) > 0 && c.bc.locals[len(c.bc.locals)-1].depth > c.bc.scope_depth {
		pop(&c.bc.locals)
	}
}

end_scope :: proc(c: ^Compiler) {
	c.bc.scope_depth -= 1
	for len(c.bc.locals) > 0 &&
	    c.bc.locals[len(c.bc.locals)-1].depth > c.bc.scope_depth {
		local := c.bc.locals[len(c.bc.locals)-1]
		for _ in 0..<local.slots {
			emit(&c.bc, .POP, {})
		}
		pop(&c.bc.locals)
	}
}

// ---- statements ----

compile_stmt :: proc(c: ^Compiler, idx: parser.StatementIdx) {
	node := c.ast.nodes[idx]
	span := c.ast.spans[idx]

	switch s in node.(parser.Statement) {
	case parser.ConstStatement:
		if val, ok := eval_const_expr(c, s.value, span); ok {
			c.const_table[s.name.data] = val
		}

	case parser.LetStatement:
		compile_expr(c, s.value)
		if c.bc.scope_depth == 0 {
			emit(&c.bc, .DEFINE_GLOBAL, span)
			emit_byte(&c.bc, u8(assign_global_slot(c, s.name.data)), span)
		} else {
			slice_es := expr_slice_elem_slots(c, s.value)
			if slice_es > 0 {
				add_local(&c.bc, s.name.data, 4, "", "", "", 0, slice_es)
				break
			}
			struct_type      := expr_struct_type(c, s.value)
			ptr_inner        := expr_ptr_inner(c, s.value)
			enum_type        := expr_enum_type(c, s.value)
			array_elem_slots := expr_array_elem_slots(c, s.value)
			if struct_type == "" && ptr_inner == "" && enum_type == "" && array_elem_slots == 0 {
				if ann_idx, has_ann := s.type.?; has_ann {
					struct_type = type_ann_struct_name(c, ann_idx)
					ptr_inner   = type_ann_ptr_inner(c, ann_idx)
					enum_type   = type_ann_enum_name(c, ann_idx)
					if struct_type == "" && enum_type == "" {
						// Check if the annotation is Array[T, N]
						if int(ann_idx) < len(c.ast.nodes) {
							if ty, ok := c.ast.nodes[int(ann_idx)].(parser.Type); ok {
								if at, ok2 := ty.(parser.ArrayType); ok2 {
									array_elem_slots = type_slot_count(c, at.elem)
								}
							}
						}
					}
				}
			}
			slots := 1
			if array_elem_slots > 0 {
				slots = expr_slot_count(c, s.value)
				if slots == 1 {
					// fallback: compute from annotation
					if ann_idx, has_ann := s.type.?; has_ann {
						slots = type_slot_count(c, ann_idx)
					}
				}
			} else if struct_type != "" {
				if layout, ok := c.struct_layouts^[struct_type]; ok {
					slots = layout.total_slots
				}
			} else if enum_type != "" {
				if layout, ok := c.enum_layouts[enum_type]; ok {
					slots = layout.total_slots
				}
			}
			add_local(&c.bc, s.name.data, slots, struct_type, ptr_inner, enum_type, array_elem_slots)
		}

	case parser.ReturnStatement:
		if c.inline_fn_name != "" {
			// Inline return: stash result at result_slot, pop locals above it, jump to end.
			if val, ok := s.value.?; ok {
				compile_expr(c, val)
			} else {
				emit(&c.bc, .NIL, span)
			}
			emit(&c.bc, .SET_LOCAL, span)
			emit_byte(&c.bc, u8(c.inline_result_slot), span)
			emit(&c.bc, .POP, span)
			total := 0
			for local in c.bc.locals { total += local.slots }
			for _ in 0..<(total - (c.inline_result_slot + 1)) { emit(&c.bc, .POP, span) }
			patch, _ := emit_jump(&c.bc, .JUMP, span)
			append(&c.inline_patches, int(patch))
			return
		}
		if val, ok := s.value.?; ok {
			compile_expr(c, val)
			emit(&c.bc, .RETURN, span)
			emit_byte(&c.bc, u8(expr_slot_count(c, val)), span)
		} else {
			emit(&c.bc, .NIL, span)
			emit(&c.bc, .RETURN, span)
			emit_byte(&c.bc, 1, span)
		}

	case parser.ExpressionStatement:
		compile_expr(c, s.expr)
		n := expr_slot_count(c, s.expr)
		for _ in 0..<n {
			emit(&c.bc, .POP, span)
		}

	case parser.ForStatement:
		compile_for(c, s, span)

	case parser.BreakStatement:
		if c.loop_ctx == nil {
			compiler_error(c, "break outside of loop", span)
			return
		}
		n := 0
		for i in c.loop_ctx.local_base..<len(c.bc.locals) {
			n += c.bc.locals[i].slots
		}
		for _ in 0..<n { emit(&c.bc, .POP, span) }
		if c.loop_ctx.break_count >= MAX_BREAK_COUNT {
			compiler_error(c, "too many break statements in one loop", span)
			return
		}
		jmp, _ := emit_jump(&c.bc, .JUMP, span)
		c.loop_ctx.breaks[c.loop_ctx.break_count] = jmp
		c.loop_ctx.break_count += 1

	case parser.ContinueStatement:
		if c.loop_ctx == nil {
			compiler_error(c, "continue outside of loop", span)
			return
		}
		n := 0
		for i in c.loop_ctx.local_base..<len(c.bc.locals) {
			n += c.bc.locals[i].slots
		}
		for _ in 0..<n { emit(&c.bc, .POP, span) }
		emit_loop(&c.bc, c.loop_ctx.start, span)

	case parser.WithContextStatement:
		// TODO
	}
}

compile_for :: proc(c: ^Compiler, s: parser.ForStatement, span: lexer.Span) {
	// compile init once before loop_start so the variable exists for the condition
	has_init := false
	if init, ok := s.init.?; ok {
		has_init = true
		c.bc.scope_depth += 1
		compile_stmt(c, init)
	}

	loop_start := u16(len(current_chunk(&c.bc).code))

	// local_base is after init — break/continue pop body locals only;
	// the init local is cleaned up separately after the loop
	ctx := LoopCtx{
		start      = loop_start,
		local_base = len(c.bc.locals),
	}
	outer_ctx  := c.loop_ctx
	c.loop_ctx  = &ctx

	exit_jump: u16 = 0
	has_condition := false

	if cond, ok := s.condition.?; ok {
		has_condition = true
		compile_expr(c, cond)
		exit_jump, _ = emit_jump(&c.bc, .JUMP_IF_FALSE_POP, span)
	}

	compile_block(c, s.body)
	// Discard the loop body's result value (if any) before the back-edge.
	// parse_block promotes the last ExpressionStatement to block.result, but
	// loop bodies run for side effects only — their result is never used.
	if result_expr, has_result := s.body.result.?; has_result {
		n := expr_slot_count(c, result_expr)
		for _ in 0..<n { emit(&c.bc, .POP, span) }
	}

	if post, ok := s.post.?; ok {
		compile_stmt(c, post)
		// ExpressionStatement already emits POP — no extra POP needed
	}

	emit_loop(&c.bc, loop_start, span)

	if has_condition {
		patch_jump(&c.bc, exit_jump)
	}

	// break jumps land here — after the condition POP, before init cleanup
	for i in 0..<int(ctx.break_count) {
		patch_jump(&c.bc, ctx.breaks[i])
	}
	c.loop_ctx = outer_ctx

	// close the init scope so the loop variable doesn't outlive the loop
	if has_init {
		c.bc.scope_depth -= 1
		for len(c.bc.locals) > 0 &&
		    c.bc.locals[len(c.bc.locals)-1].depth > c.bc.scope_depth {
			local := c.bc.locals[len(c.bc.locals)-1]
			for _ in 0..<local.slots {
				emit(&c.bc, .POP, span)
			}
			pop(&c.bc.locals)
		}
	}
}

// ---- expressions ----

compile_expr :: proc(c: ^Compiler, idx: parser.ExpressionIdx) {
	node := c.ast.nodes[idx]
	span := c.ast.spans[idx]

	switch e in node.(parser.Expression) {
	case parser.LiteralExpression:
		tok := lexer.Token(e)
		if tok.kind == .NIL {
			emit(&c.bc, .NIL, span)
			return
		}
		val := parse_literal(tok)
		emit_constant(&c.bc, val, span)

	case parser.IdentExpression:
		tok := lexer.Token(e)
		name := tok.data
		// const table is checked first — inlined as an immediate value
		if val, ok := c.const_table[name]; ok {
			emit_constant(&c.bc, val, span)
			return
		}
		// check locals first (inner → outer)
		slot, slots, found := resolve_local(&c.bc, name)
		if found {
			for s in 0..<slots {
				emit(&c.bc, .GET_LOCAL, span)
				emit_byte(&c.bc, u8(slot + s), span)
			}
		} else {
			emit(&c.bc, .GET_GLOBAL, span)
			emit_byte(&c.bc, u8(assign_global_slot(c, name)), span)
		}

	case parser.UnaryExpression:
		if val, ok := try_fold_expr(c, idx); ok {
			emit_constant(&c.bc, val, span)
			return
		}
		compile_expr(c, e.operand)
		#partial switch e.op.kind {
		case .MINUS: emit(&c.bc, specialize_opcode(c, .NEGATE, e.operand), span)
		case .BANG:  emit(&c.bc, .NOT, span)
		case .TILDE: emit(&c.bc, .BNOT, span)
		}

	case parser.BinaryExpression:
		// assignment is special
		if e.operation.kind == .EQ {
			compile_assignment(c, e, span)
			return
		}
		if e.operation.kind == .PLUS_EQ  || e.operation.kind == .MINUS_EQ ||
		   e.operation.kind == .STAR_EQ  || e.operation.kind == .SLASH_EQ ||
		   e.operation.kind == .PERCENT_EQ {
			compile_compound_assignment(c, e, span)
			return
		}
		if val, ok := try_fold_expr(c, idx); ok {
			emit_constant(&c.bc, val, span)
			return
		}
		// short-circuit logical operators
		if e.operation.kind == .AND {
			compile_expr(c, e.left)
			jump, _ := emit_jump(&c.bc, .JUMP_IF_FALSE, span)
			emit(&c.bc, .POP, span)
			compile_expr(c, e.right)
			patch_jump(&c.bc, jump)
			return
		}
		if e.operation.kind == .OR {
			compile_expr(c, e.left)
			jump, _ := emit_jump(&c.bc, .JUMP_IF_TRUE, span)
			emit(&c.bc, .POP, span)
			compile_expr(c, e.right)
			patch_jump(&c.bc, jump)
			return
		}
		compile_expr(c, e.left)
		compile_expr(c, e.right)
		emit(&c.bc, specialize_opcode(c, op_to_opcode(e.operation.kind), e.left), span)

	case parser.CallExpression:
		// check for print builtin
		callee_node := c.ast.nodes[e.callee]
		if expr, ok := callee_node.(parser.Expression); ok {
			if id, ok2 := expr.(parser.IdentExpression); ok2 {
				fn_name := lexer.Token(id).data
				switch fn_name {
				case "print":
					for arg in e.args {
						compile_expr(c, arg)
						emit(&c.bc, .PRINT, span)
					}
					emit(&c.bc, .NIL, span)
					return
				case "input":
					if len(e.args) > 0 {
						compile_expr(c, e.args[0])
					} else {
						emit_constant(&c.bc, "", span)
					}
					emit(&c.bc, .INPUT, span)
					return
				}
				// Try inlining direct calls to eligible functions.
				if c.inline_fn_name == "" {
					root_c := c if c.root == nil else c.root
					if fn_info, ok := root_c.inline_fns[fn_name]; ok {
						if len(e.args) == len(fn_info.decl.params) {
							emit_inline_call(c, fn_info, e.args, span)
							return
						}
					}
				}
				// Generic function call: emit the instantiation into the root chunk
				// on first use, then call it by its mangled name.
				if tmpl, is_generic := c.generic_templates[fn_name]; is_generic {
					mangled := compute_generic_mangled_name(c, tmpl, e.args)
					if !strings.contains(mangled, "__unknown") {
						root_c := c.root
						if root_c == nil { root_c = c }
						if !root_c.generic_emitted[mangled] {
							root_c.generic_emitted[mangled] = true
							// Save root's substitution, build one for this instantiation.
							saved := make(map[string]string)
							for k, v in root_c.type_subst { saved[k] = v }
							clear(&root_c.type_subst)
							for tp in tmpl.type_params {
								concrete := infer_type_param(c, tmpl, tp.data, e.args)
								if concrete != "" { root_c.type_subst[tp.data] = concrete }
							}
							compile_function(root_c, tmpl, mangled, span)
							clear(&root_c.type_subst)
							for k, v in saved { root_c.type_subst[k] = v }
							delete(saved)
						}
					}
					emit(&c.bc, .GET_GLOBAL, span)
					emit_byte(&c.bc, u8(assign_global_slot(c, mangled)), span)
					total_arg_slots := 0
					for arg in e.args {
						compile_expr(c, arg)
						total_arg_slots += expr_slot_count(c, arg)
					}
					emit(&c.bc, .CALL, span)
					emit_byte(&c.bc, u8(total_arg_slots), span)
					return
				}
			}
		}
		compile_expr(c, e.callee)
		total_arg_slots := 0
		for arg in e.args {
			compile_expr(c, arg)
			total_arg_slots += expr_slot_count(c, arg)
		}
		emit(&c.bc, .CALL, span)
		emit_byte(&c.bc, u8(total_arg_slots), span)

	case parser.IfExpression:
		compile_if(c, e, span)

	case parser.BlockExpression:
		compile_block(c, e)

	case parser.FieldAccessExpression:
		compile_field_access(c, e, span)

	case parser.StructLiteralExpression:
		if e.type_name.data == "Slice" {
			compile_slice_literal(c, e, span)
			return
		}
		compile_struct_literal(c, e, span)

	case parser.NewExpression:
		compile_new_expr(c, e, span)

	case parser.DerefExpression:
		compile_deref_expr(c, e, span)

	case parser.AddrOfExpression:
		compile_addr_of(c, e, span)

	case parser.EnumLiteralExpression:
		compile_enum_literal(c, e, span)

	case parser.IndexExpression:
		compile_index_expression(c, e, span)

	case parser.ArrayLiteralExpression:
		compile_array_literal(c, e, span)

	case parser.MatchExpression:
		compile_match(c, e, span)
	}
}

compile_compound_assignment :: proc(c: ^Compiler, e: parser.BinaryExpression, span: lexer.Span) {
	op: Opcode
	#partial switch e.operation.kind {
	case .PLUS_EQ:    op = .ADD
	case .MINUS_EQ:   op = .SUB
	case .STAR_EQ:    op = .MUL
	case .SLASH_EQ:   op = .DIV
	case .PERCENT_EQ: op = .MOD
	}

	lhs_node := c.ast.nodes[e.left]
	lhs_expr, is_expr := lhs_node.(parser.Expression)
	if !is_expr { compiler_error(c, "invalid compound assignment target", span); return }

	#partial switch lhs in lhs_expr {
	case parser.IdentExpression:
		name := lexer.Token(lhs).data
		slot, _, found := resolve_local(&c.bc, name)
		if found {
			emit(&c.bc, .GET_LOCAL, span)
			emit_byte(&c.bc, u8(slot), span)
		} else {
			emit(&c.bc, .GET_GLOBAL, span)
			emit_byte(&c.bc, u8(assign_global_slot(c, name)), span)
		}
		compile_expr(c, e.right)
		emit(&c.bc, op, span)
		if found {
			emit(&c.bc, .SET_LOCAL, span)
			emit_byte(&c.bc, u8(slot), span)
		} else {
			emit(&c.bc, .SET_GLOBAL, span)
			emit_byte(&c.bc, u8(assign_global_slot(c, name)), span)
		}

	case parser.FieldAccessExpression:
		base_slot, heap_offset, parent_type, chain_ok := resolve_access_chain(c, lhs.object)
		if chain_ok && parent_type != "" {
			layout, has_layout := c.struct_layouts^[parent_type]
			if !has_layout { compiler_error(c, "compound assignment on non-struct field", span); return }
			field_offset, _, _, _, field_found := find_field(layout, lhs.field.data)
			if !field_found { compiler_error(c, fmt.tprintf("unknown field '%s'", lhs.field.data), span); return }
			if heap_offset >= 0 {
				abs_heap := heap_offset + field_offset
				emit(&c.bc, .GET_LOCAL, span)
				emit_byte(&c.bc, u8(base_slot), span)
				emit(&c.bc, .HEAP_GET, span)
				emit_byte(&c.bc, u8(abs_heap), span)
				compile_expr(c, e.right)
				emit(&c.bc, op, span)
				emit(&c.bc, .GET_LOCAL, span)
				emit_byte(&c.bc, u8(base_slot), span)
				emit(&c.bc, .HEAP_SET, span)
				emit_byte(&c.bc, u8(abs_heap), span)
			} else {
				abs_slot := base_slot + field_offset
				emit(&c.bc, .GET_LOCAL, span)
				emit_byte(&c.bc, u8(abs_slot), span)
				compile_expr(c, e.right)
				emit(&c.bc, op, span)
				emit(&c.bc, .SET_LOCAL, span)
				emit_byte(&c.bc, u8(abs_slot), span)
			}
		} else {
			// Fallback: chain passes through a pointer-typed field.
			// GET: emit ptr, HEAP_GET field; apply op; SET: emit ptr again, HEAP_SET field.
			heap_base1, container_type, ok1 := compile_ptr_to_container(c, lhs.object, span)
			if !ok1 { compiler_error(c, "invalid compound assignment target", span); return }
			layout, has := c.struct_layouts^[container_type]
			if !has { compiler_error(c, "compound assignment on non-struct field", span); return }
			field_offset, _, _, _, field_found := find_field(layout, lhs.field.data)
			if !field_found { compiler_error(c, fmt.tprintf("unknown field '%s'", lhs.field.data), span); return }
			abs_heap := heap_base1 + field_offset
			emit(&c.bc, .HEAP_GET, span)
			emit_byte(&c.bc, u8(abs_heap), span)
			compile_expr(c, e.right)
			emit(&c.bc, op, span)
			// Re-acquire the ptr for HEAP_SET.
			heap_base2, _, ok2 := compile_ptr_to_container(c, lhs.object, span)
			if !ok2 { compiler_error(c, "invalid compound assignment target", span); return }
			emit(&c.bc, .HEAP_SET, span)
			emit_byte(&c.bc, u8(heap_base2 + field_offset), span)
		}

	case:
		compiler_error(c, "invalid compound assignment target", span)
	}
}

compile_assignment :: proc(c: ^Compiler, e: parser.BinaryExpression, span: lexer.Span) {
	compile_expr(c, e.right)
	lhs := c.ast.nodes[e.left]
	if expr, ok := lhs.(parser.Expression); ok {
		if id, ok2 := expr.(parser.IdentExpression); ok2 {
			name := lexer.Token(id).data
			slot, slots, found := resolve_local(&c.bc, name)
			if found {
				if slots == 1 {
					emit(&c.bc, .SET_LOCAL, span)
					emit_byte(&c.bc, u8(slot), span)
				} else {
					// multi-slot struct: write each slot in reverse, leave nil as expression value
					for s := slots - 1; s >= 0; s -= 1 {
						emit(&c.bc, .SET_LOCAL, span)
						emit_byte(&c.bc, u8(slot + s), span)
						emit(&c.bc, .POP, span)
					}
					emit(&c.bc, .NIL, span)
				}
			} else {
				emit(&c.bc, .SET_GLOBAL, span)
				emit_byte(&c.bc, u8(assign_global_slot(c, name)), span)
			}
			return
		}
		if fa, ok3 := expr.(parser.FieldAccessExpression); ok3 {
			compile_field_set(c, fa, span)
			return
		}
		if ie, ok3 := expr.(parser.IndexExpression); ok3 {
			compile_index_set(c, ie, span)
			return
		}
	}
	compiler_error(c, "invalid assignment target", span)
}

compile_if :: proc(c: ^Compiler, e: parser.IfExpression, span: lexer.Span) {
	compile_expr(c, e.condition)
	then_jump, _ := emit_jump(&c.bc, .JUMP_IF_FALSE_POP, span)

	compile_block(c, e.then_block)
	if _, has_result := e.then_block.result.?; !has_result {
		emit(&c.bc, .NIL, span)
	}

	if else_block, ok := e.else_block.?; ok {
		else_jump, _ := emit_jump(&c.bc, .JUMP, span)
		patch_jump(&c.bc, then_jump)
		compile_block(c, else_block)
		if _, has_result := else_block.result.?; !has_result {
			emit(&c.bc, .NIL, span)
		}
		patch_jump(&c.bc, else_jump)
	} else {
		else_jump, _ := emit_jump(&c.bc, .JUMP, span)
		patch_jump(&c.bc, then_jump)
		emit(&c.bc, .NIL, span)
		patch_jump(&c.bc, else_jump)
	}
}

compile_match :: proc(c: ^Compiler, e: parser.MatchExpression, span: lexer.Span) {
	// Determine subject kind: enum or scalar
	enum_name := expr_enum_type(c, e.subject)
	is_enum   := enum_name != ""

	layout:        EnumLayout
	subject_slots := 1
	if is_enum {
		has: bool
		layout, has = c.enum_layouts[enum_name]
		if !has {
			compiler_error(c, fmt.tprintf("unknown enum '%s'", enum_name), span)
			emit(&c.bc, .NIL, span)
			return
		}
		subject_slots = layout.total_slots
	}

	// Push result placeholder — match is an expression; the matched arm writes
	// its result here via SET_LOCAL before popping its bindings and jumping out.
	emit(&c.bc, .NIL, span)
	add_local(&c.bc, "__match_result__", 1)

	// subj_slot = stack index of the first subject slot (right after result placeholder)
	subj_slot := 0
	for local in c.bc.locals {
		subj_slot += local.slots
	}
	result_slot := subj_slot - 1

	// push subject copy, register sentinel so resolve_local stays correct
	compile_expr(c, e.subject)
	add_local(&c.bc, "__match_subject__", subject_slots)

	arm_end_jumps := make([dynamic]u16)
	defer delete(arm_end_jumps)

	for arm in e.arms {
		pattern_node := c.ast.nodes[int(arm.pattern)]
		pexpr, ok := pattern_node.(parser.Expression)
		if !ok { compiler_error(c, "invalid match pattern", span); continue }

		#partial switch pat in pexpr {
		case parser.IdentExpression:
			// Wildcard: _ => always fires, no discriminant check
			if lexer.Token(pat).data != "_" {
				compiler_error(c, "match pattern ident must be '_' (wildcard)", span)
				continue
			}
			compile_expr(c, arm.body)
			// Block bodies with no tail expression leave no value on the stack; push NIL.
			if body_expr, bok := c.ast.nodes[int(arm.body)].(parser.Expression); bok {
				if block, bbok := body_expr.(parser.BlockExpression); bbok {
					if _, has_result := block.result.?; !has_result {
						emit(&c.bc, .NIL, span)
					}
				}
			}
			emit(&c.bc, .SET_LOCAL, span)
			emit_byte(&c.bc, u8(result_slot), span)
			emit(&c.bc, .POP, span)
			jmp, _ := emit_jump(&c.bc, .JUMP, span)
			append(&arm_end_jumps, jmp)

		case parser.LiteralExpression:
			// Scalar literal: compare subject to constant
			emit(&c.bc, .GET_LOCAL, span)
			emit_byte(&c.bc, u8(subj_slot), span)
			emit_constant(&c.bc, parse_literal(lexer.Token(pat)), span)
			emit(&c.bc, .EQ, span)
			next_arm_jump, _ := emit_jump(&c.bc, .JUMP_IF_FALSE_POP, span)

			compile_expr(c, arm.body)
			// Block bodies with no tail expression leave no value on the stack; push NIL.
			if body_expr, bok := c.ast.nodes[int(arm.body)].(parser.Expression); bok {
				if block, bbok := body_expr.(parser.BlockExpression); bbok {
					if _, has_result := block.result.?; !has_result {
						emit(&c.bc, .NIL, span)
					}
				}
			}
			emit(&c.bc, .SET_LOCAL, span)
			emit_byte(&c.bc, u8(result_slot), span)
			emit(&c.bc, .POP, span)
			jmp, _ := emit_jump(&c.bc, .JUMP, span)
			append(&arm_end_jumps, jmp)

			patch_jump(&c.bc, next_arm_jump)

		case parser.EnumLiteralExpression:
			// Enum variant: discriminant check + field bindings
			if !is_enum {
				compiler_error(c, "enum pattern on non-enum subject", span)
				continue
			}
			variant_layout, vok := layout.variants[pat.variant_name.data]
			if !vok {
				compiler_error(c, fmt.tprintf("unknown variant '%s'", pat.variant_name.data), span)
				continue
			}

			emit(&c.bc, .GET_LOCAL, span)
			emit_byte(&c.bc, u8(subj_slot), span)
			emit_constant(&c.bc, i64(variant_layout.discriminant), span)
			emit(&c.bc, .EQ, span)
			next_arm_jump, _ := emit_jump(&c.bc, .JUMP_IF_FALSE_POP, span)

			c.bc.scope_depth += 1
			for field in pat.fields {
				binding_name := field.name.data
				field_offset := -1
				for fi in 0..<len(variant_layout.field_names) {
					if variant_layout.field_names[fi] == binding_name {
						field_offset = variant_layout.field_offsets[fi]
						break
					}
				}
				if field_offset < 0 {
					compiler_error(c, fmt.tprintf("unknown field '%s' in variant '%s'", binding_name, pat.variant_name.data), span)
					continue
				}
				emit(&c.bc, .GET_LOCAL, span)
				emit_byte(&c.bc, u8(subj_slot + 1 + field_offset), span)
				add_local(&c.bc, binding_name)
			}

			compile_expr(c, arm.body)
			// Block bodies with no tail expression leave no value on the stack; push NIL.
			if body_expr, bok := c.ast.nodes[int(arm.body)].(parser.Expression); bok {
				if block, bbok := body_expr.(parser.BlockExpression); bbok {
					if _, has_result := block.result.?; !has_result {
						emit(&c.bc, .NIL, span)
					}
				}
			}
			emit(&c.bc, .SET_LOCAL, span)
			emit_byte(&c.bc, u8(result_slot), span)
			emit(&c.bc, .POP, span)

			c.bc.scope_depth -= 1
			for len(c.bc.locals) > 0 && c.bc.locals[len(c.bc.locals)-1].depth > c.bc.scope_depth {
				local := c.bc.locals[len(c.bc.locals)-1]
				for _ in 0..<local.slots {
					emit(&c.bc, .POP, span)
				}
				pop(&c.bc.locals)
			}

			jmp, _ := emit_jump(&c.bc, .JUMP, span)
			append(&arm_end_jumps, jmp)

			patch_jump(&c.bc, next_arm_jump)

		case:
			compiler_error(c, "unsupported match pattern kind", span)
		}
	}

	// all arm-end JUMPs land here
	for jmp in arm_end_jumps {
		patch_jump(&c.bc, jmp)
	}

	// remove subject sentinel, pop subject copy slots
	pop(&c.bc.locals)
	for _ in 0..<subject_slots {
		emit(&c.bc, .POP, span)
	}

	// remove result sentinel — result value is now the top of the stack
	pop(&c.bc.locals)
}

// ---- helpers ----

resolve_local :: proc(bc: ^ByteCodeCompiler, name: string) -> (stack_slot: int, slots: int, found: bool) {
	target := -1
	for i := len(bc.locals) - 1; i >= 0; i -= 1 {
		if bc.locals[i].name == name {
			target = i
			break
		}
	}
	if target < 0 do return 0, 0, false
	offset := 0
	for i in 0..<target {
		offset += bc.locals[i].slots
	}
	return offset, bc.locals[target].slots, true
}

// specialize_opcode upgrades a generic arithmetic/comparison opcode to a
// type-specific one when the type of the left operand is statically known.
specialize_opcode :: proc(c: ^Compiler, op: Opcode, left: parser.ExpressionIdx) -> Opcode {
	if c.tc_types == nil || int(left) >= len(c.tc_types) { return op }
	switch c.tc_types[int(left)] {
	case tc.INT_TYPE:
		#partial switch op {
		case .ADD:    return .ADD_I64
		case .SUB:    return .SUB_I64
		case .MUL:    return .MUL_I64
		case .DIV:    return .DIV_I64
		case .MOD:    return .MOD_I64
		case .LT:     return .LT_I64
		case .LTE:    return .LTE_I64
		case .GT:     return .GT_I64
		case .GTE:    return .GTE_I64
		case .NEGATE: return .NEGATE_I64
		}
	case tc.FLOAT_TYPE:
		#partial switch op {
		case .ADD:    return .ADD_F64
		case .SUB:    return .SUB_F64
		case .MUL:    return .MUL_F64
		case .DIV:    return .DIV_F64
		case .LT:     return .LT_F64
		case .LTE:    return .LTE_F64
		case .GT:     return .GT_F64
		case .GTE:    return .GTE_F64
		case .NEGATE: return .NEGATE_F64
		}
	case tc.STRING_TYPE:
		if op == .ADD { return .ADD_STR }
	}
	return op
}

op_to_opcode :: proc(kind: lexer.TokenType) -> Opcode {
	#partial switch kind {
	case .PLUS:    return .ADD
	case .MINUS:   return .SUB
	case .STAR:    return .MUL
	case .SLASH:   return .DIV
	case .PERCENT: return .MOD
	case .LT_LT:      return .SHL
	case .GT_GT:      return .SHR
	case .AMPERSAND:  return .BAND
	case .PIPE:       return .BOR
	case .CARET:      return .BXOR
	case .EQ_EQ:   return .EQ
	case .BANG_EQ: return .NEQ
	case .LT:      return .LT
	case .LT_EQ:   return .LTE
	case .GT:      return .GT
	case .GT_EQ:   return .GTE
	}
	return .ADD // unreachable
}

parse_literal :: proc(tok: lexer.Token) -> Value {
	#partial switch tok.kind {
	case .INT:
		if len(tok.data) > 2 && tok.data[0] == '0' && (tok.data[1] == 'x' || tok.data[1] == 'X') {
			n, _ := strconv.parse_i64(tok.data[2:], 16)
			return i64(n)
		}
		n, _ := strconv.parse_i64(tok.data)
		return i64(n)
	case .FLOAT:
		f, _ := strconv.parse_f64(tok.data)
		return f64(f)
	case .STRING:
		if len(tok.data) < 2 { return "" }
		raw := tok.data[1:len(tok.data)-1]
		return decode_string_escapes(raw)

	case .TRUE:  return true
	case .FALSE: return false
	}
	return Nil{}
}

eval_const_expr :: proc(c: ^Compiler, idx: parser.ExpressionIdx, span: lexer.Span) -> (Value, bool) {
	node := c.ast.nodes[idx]

	#partial switch e in node.(parser.Expression) {
	case parser.LiteralExpression:
		return parse_literal(lexer.Token(e)), true

	case parser.IdentExpression:
		name := lexer.Token(e).data
		if val, ok := c.const_table[name]; ok {
			return val, true
		}
		compiler_error(c, "undefined constant", span)
		return Nil{}, false

	case parser.UnaryExpression:
		val, ok := eval_const_expr(c, e.operand, span)
		if !ok { return Nil{}, false }
		#partial switch e.op.kind {
		case .MINUS:
			if n, ok2 := val.(i64); ok2 { return -n, true }
			if f, ok2 := val.(f64); ok2 { return -f, true }
		case .BANG:
			if b, ok2 := val.(bool); ok2 { return !b, true }
		}
		compiler_error(c, "invalid unary operator in const expression", span)
		return Nil{}, false

	case parser.BinaryExpression:
		lv, lok := eval_const_expr(c, e.left,  span)
		rv, rok := eval_const_expr(c, e.right, span)
		if !lok || !rok { return Nil{}, false }
		if ln, ok := lv.(i64); ok {
			if rn, ok2 := rv.(i64); ok2 {
				#partial switch e.operation.kind {
				case .PLUS:    return ln + rn, true
				case .MINUS:   return ln - rn, true
				case .STAR:    return ln * rn, true
				case .SLASH:
					if rn == 0 { compiler_error(c, "division by zero in const expression", span); return Nil{}, false }
					return ln / rn, true
				case .PERCENT:
					if rn == 0 { compiler_error(c, "modulo by zero in const expression", span); return Nil{}, false }
					return ln % rn, true
				case .LT_LT:     return ln << uint(rn), true
				case .GT_GT:     return ln >> uint(rn), true
				case .AMPERSAND: return ln & rn, true
				case .PIPE:      return ln | rn, true
				case .CARET:     return ln ~ rn, true
				}
			}
		}
		if lf, ok := lv.(f64); ok {
			if rf, ok2 := rv.(f64); ok2 {
				#partial switch e.operation.kind {
				case .PLUS:  return lf + rf, true
				case .MINUS: return lf - rf, true
				case .STAR:  return lf * rf, true
				case .SLASH: return lf / rf, true
				}
			}
		}
		compiler_error(c, "invalid operands in const expression", span)
		return Nil{}, false
	}

	compiler_error(c, "not a compile-time constant expression", span)
	return Nil{}, false
}

// try_fold_expr attempts to evaluate an expression as a compile-time constant.
// Returns (value, true) on success, (Nil{}, false) if any operand is not constant.
// Never emits errors — callers fall back to normal code generation on false.
try_fold_expr :: proc(c: ^Compiler, idx: parser.ExpressionIdx) -> (Value, bool) {
	node := c.ast.nodes[idx]
	#partial switch e in node.(parser.Expression) {
	case parser.LiteralExpression:
		tok := lexer.Token(e)
		if tok.kind == .NIL { return Nil{}, true }
		return parse_literal(tok), true

	case parser.IdentExpression:
		name := lexer.Token(e).data
		if val, ok := c.const_table[name]; ok { return val, true }
		return Nil{}, false

	case parser.UnaryExpression:
		val, ok := try_fold_expr(c, e.operand)
		if !ok { return Nil{}, false }
		#partial switch e.op.kind {
		case .MINUS:
			if n, ok2 := val.(i64);  ok2 { return -n,  true }
			if f, ok2 := val.(f64);  ok2 { return -f,  true }
		case .BANG:
			if b, ok2 := val.(bool); ok2 { return !b,  true }
		case .TILDE:
			if n, ok2 := val.(i64);  ok2 { return ~n,  true }
		}
		return Nil{}, false

	case parser.BinaryExpression:
		lv, lok := try_fold_expr(c, e.left)
		rv, rok := try_fold_expr(c, e.right)
		if !lok || !rok { return Nil{}, false }
		if ln, ok := lv.(i64); ok {
			if rn, ok2 := rv.(i64); ok2 {
				#partial switch e.operation.kind {
				case .PLUS:      return ln + rn,        true
				case .MINUS:     return ln - rn,        true
				case .STAR:      return ln * rn,        true
				case .SLASH:
					if rn == 0 { return Nil{}, false }
					return ln / rn, true
				case .PERCENT:
					if rn == 0 { return Nil{}, false }
					return ln % rn, true
				case .LT_LT:     return ln << uint(rn), true
				case .GT_GT:     return ln >> uint(rn), true
				case .AMPERSAND: return ln & rn,        true
				case .PIPE:      return ln | rn,        true
				case .CARET:     return ln ~ rn,        true
				case .EQ_EQ:     return ln == rn,       true
				case .BANG_EQ:   return ln != rn,       true
				case .LT:        return ln <  rn,       true
				case .LT_EQ:     return ln <= rn,       true
				case .GT:        return ln >  rn,       true
				case .GT_EQ:     return ln >= rn,       true
				}
			}
		}
		if lf, ok := lv.(f64); ok {
			if rf, ok2 := rv.(f64); ok2 {
				#partial switch e.operation.kind {
				case .PLUS:    return lf + rf,  true
				case .MINUS:   return lf - rf,  true
				case .STAR:    return lf * rf,  true
				case .SLASH:   return lf / rf,  true
				case .EQ_EQ:   return lf == rf, true
				case .BANG_EQ: return lf != rf, true
				case .LT:      return lf <  rf, true
				case .LT_EQ:   return lf <= rf, true
				case .GT:      return lf >  rf, true
				case .GT_EQ:   return lf >= rf, true
				}
			}
		}
		if lb, ok := lv.(bool); ok {
			if rb, ok2 := rv.(bool); ok2 {
				#partial switch e.operation.kind {
				case .EQ_EQ:   return lb == rb, true
				case .BANG_EQ: return lb != rb, true
				case .AND:     return lb && rb, true
				case .OR:      return lb || rb, true
				}
			}
		}
		if ls, ok := lv.(string); ok {
			if rs, ok2 := rv.(string); ok2 {
				#partial switch e.operation.kind {
				case .PLUS:    return strings.concatenate([]string{ls, rs}), true
				case .EQ_EQ:   return ls == rs, true
				case .BANG_EQ: return ls != rs, true
				}
			}
		}
		return Nil{}, false
	}
	return Nil{}, false
}

decode_string_escapes :: proc(s: string) -> string {
	if !strings.contains(s, "\\") { return s }
	b := strings.builder_make()
	i := 0
	for i < len(s) {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 'n':  strings.write_byte(&b, '\n')
			case 't':  strings.write_byte(&b, '\t')
			case 'r':  strings.write_byte(&b, '\r')
			case '\\': strings.write_byte(&b, '\\')
			case '"':  strings.write_byte(&b, '"')
			case '0':  strings.write_byte(&b, 0)
			case:
				strings.write_byte(&b, '\\')
				strings.write_byte(&b, s[i])
			}
		} else {
			strings.write_byte(&b, s[i])
		}
		i += 1
	}
	return strings.to_string(b)
}

compiler_error :: proc(c: ^Compiler, msg: string, span: lexer.Span) {
	if c.error_count < MAX_ERROR_COUNT {
		c.errors[c.error_count] = CompilerError{message = msg, span = span}
		c.error_count += 1
	}
}

// ---- struct helpers ----

local_enum_type :: proc(bc: ^ByteCodeCompiler, name: string) -> string {
	for i := len(bc.locals) - 1; i >= 0; i -= 1 {
		if bc.locals[i].name == name {
			return bc.locals[i].enum_type
		}
	}
	return ""
}

type_ann_enum_name :: proc(c: ^Compiler, type_idx: parser.TypeIdx) -> string {
	if int(type_idx) >= len(c.ast.nodes) do return ""
	node := c.ast.nodes[int(type_idx)]
	ty, ok := node.(parser.Type)
	if !ok do return ""
	if _, is_ptr := ty.(parser.PointerType); is_ptr do return ""
	named, ok2 := ty.(parser.NamedType)
	if !ok2 do return ""
	name := lexer.Token(named).data
	if subst, has := c.type_subst[name]; has { name = subst }
	if _, ok3 := c.enum_layouts[name]; ok3 {
		return name
	}
	return ""
}

expr_enum_type :: proc(c: ^Compiler, idx: parser.ExpressionIdx) -> string {
	node := c.ast.nodes[int(idx)]
	expr, ok := node.(parser.Expression)
	if !ok do return ""
	#partial switch e in expr {
	case parser.EnumLiteralExpression:
		return e.enum_name.data
	case parser.IdentExpression:
		if name := local_enum_type(&c.bc, lexer.Token(e).data); name != "" {
			return name
		}
		// Fall back to the type-checker's inference for cases where the compiler
		// didn't propagate enum_type into bc.locals (e.g. global variables,
		// function parameters whose annotation wasn't resolved at compile time).
		if c.tc_types != nil && int(idx) < len(c.tc_types) {
			type_id := c.tc_types[int(idx)]
			if int(type_id) < len(c.tc_type_table) {
				if et, ok := c.tc_type_table[int(type_id)].(tc.EnumType); ok {
					return et.name
				}
			}
		}
		return ""
	case parser.CallExpression:
		return call_return_enum_type(c, e)
	}
	return ""
}

call_return_enum_type :: proc(c: ^Compiler, e: parser.CallExpression) -> string {
	callee_node := c.ast.nodes[e.callee]
	expr, ok := callee_node.(parser.Expression)
	if !ok do return ""
	id, ok2 := expr.(parser.IdentExpression)
	if !ok2 do return ""
	fn_name := lexer.Token(id).data
	for node in c.ast.nodes {
		decl, ok3 := node.(parser.Declaration)
		if !ok3 do continue
		fn, ok4 := decl.(parser.FunctionDecl)
		if !ok4 do continue
		if fn.name.data != fn_name do continue
		ret_idx, has_ret := fn.return_type.?
		if !has_ret do return ""
		return type_ann_enum_name(c, ret_idx)
	}
	return ""
}

local_slice_elem_slots :: proc(bc: ^ByteCodeCompiler, name: string) -> int {
	for i := len(bc.locals) - 1; i >= 0; i -= 1 {
		if bc.locals[i].name == name { return bc.locals[i].slice_elem_slots }
	}
	return 0
}

// expr_slice_elem_slots returns the elem_slots for a slice expression (>0), or 0 if not a slice.
expr_slice_elem_slots :: proc(c: ^Compiler, idx: parser.ExpressionIdx) -> int {
	node := c.ast.nodes[int(idx)]
	expr, ok := node.(parser.Expression)
	if !ok { return 0 }
	if sle, ok2 := expr.(parser.StructLiteralExpression); ok2 {
		if sle.type_name.data != "Slice" || len(sle.type_args) == 0 { return 0 }
		return type_slot_count(c, sle.type_args[0])
	}
	if id, ok2 := expr.(parser.IdentExpression); ok2 {
		return local_slice_elem_slots(&c.bc, lexer.Token(id).data)
	}
	return 0
}

local_struct_type :: proc(bc: ^ByteCodeCompiler, name: string) -> string {
	for i := len(bc.locals) - 1; i >= 0; i -= 1 {
		if bc.locals[i].name == name {
			return bc.locals[i].struct_type
		}
	}
	return ""
}

local_ptr_inner :: proc(bc: ^ByteCodeCompiler, name: string) -> string {
	for i := len(bc.locals) - 1; i >= 0; i -= 1 {
		if bc.locals[i].name == name {
			return bc.locals[i].ptr_inner
		}
	}
	return ""
}

type_slot_count :: proc(c: ^Compiler, type_idx: parser.TypeIdx) -> int {
	if int(type_idx) >= len(c.ast.nodes) do return 1
	node := c.ast.nodes[int(type_idx)]
	ty, ok := node.(parser.Type)
	if !ok do return 1
	if _, is_ptr := ty.(parser.PointerType); is_ptr do return 1
	if gt, ok2 := ty.(parser.GenericType); ok2 {
		if gt.name.data == "Slice" { return 4 }
		mangled := generic_struct_mangled_name(c, gt.name.data, gt.args)
		if layout, found := c.struct_layouts^[mangled]; found { return layout.total_slots }
		return 1
	}
	if at, ok2 := ty.(parser.ArrayType); ok2 {
		return at.size * type_slot_count(c, at.elem)
	}
	named, ok2 := ty.(parser.NamedType)
	if !ok2 do return 1
	name := lexer.Token(named).data
	if subst, has := c.type_subst[name]; has { name = subst }
	if layout, ok3 := c.struct_layouts^[name]; ok3 {
		return layout.total_slots
	}
	if layout, ok3 := c.enum_layouts[name]; ok3 {
		return layout.total_slots
	}
	return 1
}

type_ann_struct_name :: proc(c: ^Compiler, type_idx: parser.TypeIdx) -> string {
	if int(type_idx) >= len(c.ast.nodes) do return ""
	node := c.ast.nodes[int(type_idx)]
	ty, ok := node.(parser.Type)
	if !ok do return ""
	if _, is_ptr := ty.(parser.PointerType); is_ptr do return ""
	if gt, ok2 := ty.(parser.GenericType); ok2 {
		mangled := generic_struct_mangled_name(c, gt.name.data, gt.args)
		if _, found := c.struct_layouts^[mangled]; found { return mangled }
		return ""
	}
	named, ok2 := ty.(parser.NamedType)
	if !ok2 do return ""
	name := lexer.Token(named).data
	if subst, has := c.type_subst[name]; has { name = subst }
	if _, ok3 := c.struct_layouts^[name]; ok3 {
		return name
	}
	return ""
}

// type_ann_ptr_inner returns the name of T when the annotation is ^T, or "".
// Handles both ^NamedType and ^GenericType (e.g. ^Stack[T] with active type_subst).
type_ann_ptr_inner :: proc(c: ^Compiler, type_idx: parser.TypeIdx) -> string {
	if int(type_idx) >= len(c.ast.nodes) do return ""
	node := c.ast.nodes[int(type_idx)]
	ty, ok := node.(parser.Type)
	if !ok do return ""
	ptr, is_ptr := ty.(parser.PointerType)
	if !is_ptr do return ""
	inner_node := c.ast.nodes[int(ptr.inner)]
	inner_ty, ok2 := inner_node.(parser.Type)
	if !ok2 do return ""
	if gt, ok3 := inner_ty.(parser.GenericType); ok3 {
		return generic_struct_mangled_name(c, gt.name.data, gt.args)
	}
	named, ok3 := inner_ty.(parser.NamedType)
	if !ok3 do return ""
	name := lexer.Token(named).data
	if subst, has := c.type_subst[name]; has { name = subst }
	return name
}

expr_slot_count :: proc(c: ^Compiler, idx: parser.ExpressionIdx) -> int {
	node := c.ast.nodes[int(idx)]
	if expr, ok := node.(parser.Expression); ok {
		if ale, ok2 := expr.(parser.ArrayLiteralExpression); ok2 {
			return ale.size * type_slot_count(c, ale.elem_type)
		}
		if ie, ok2 := expr.(parser.IndexExpression); ok2 {
			// Result is one element — could be from an array, slice, or string.
			arr_es := expr_array_elem_slots(c, ie.object)
			if arr_es > 0 { return arr_es }
			if ses := expr_slice_elem_slots(c, ie.object); ses > 0 { return ses }
			return 1  // string index or other scalar-valued index
		}
	}
	if es := expr_slice_elem_slots(c, idx); es > 0 { return 4 }
	st := expr_struct_type(c, idx)
	if st != "" {
		if layout, ok := c.struct_layouts^[st]; ok do return layout.total_slots
	}
	et := expr_enum_type(c, idx)
	if et != "" {
		if layout, ok := c.enum_layouts[et]; ok do return layout.total_slots
	}
	return 1
}

// expr_array_elem_slots returns the slots-per-element for an array expression,
// or 0 if the expression is not a known array local.
expr_array_elem_slots :: proc(c: ^Compiler, idx: parser.ExpressionIdx) -> int {
	node := c.ast.nodes[int(idx)]
	expr, ok := node.(parser.Expression)
	if !ok { return 0 }
	if ale, ok2 := expr.(parser.ArrayLiteralExpression); ok2 {
		return type_slot_count(c, ale.elem_type)
	}
	id, ok2 := expr.(parser.IdentExpression)
	if !ok2 { return 0 }
	name := lexer.Token(id).data
	for i := len(c.bc.locals) - 1; i >= 0; i -= 1 {
		if c.bc.locals[i].name == name {
			return c.bc.locals[i].array_elem_slots
		}
	}
	return 0
}

build_struct_layout :: proc(c: ^Compiler, d: parser.StructDecl) -> StructLayout {
	field_names        := make([]string, len(d.fields))
	field_offsets      := make([]int,    len(d.fields))
	field_struct_types := make([]string, len(d.fields))
	field_ptr_inners   := make([]string, len(d.fields))
	offset := 0
	for field, i in d.fields {
		field_names[i]        = field.name.data
		field_offsets[i]      = offset
		field_struct_types[i] = type_ann_struct_name(c, field.type)
		field_ptr_inners[i]   = type_ann_ptr_inner(c, field.type)
		offset += type_slot_count(c, field.type)
	}
	return StructLayout{
		field_names        = field_names,
		field_offsets      = field_offsets,
		field_struct_types = field_struct_types,
		field_ptr_inners   = field_ptr_inners,
		total_slots        = offset,
	}
}

build_enum_layout :: proc(c: ^Compiler, d: parser.EnumDecl) -> EnumLayout {
	variants := make(map[string]EnumVariantLayout)
	max_field_slots := 0
	for variant, vi in d.variants {
		start := int(variant.field_start)
		end := len(d.fields)
		if vi + 1 < len(d.variants) {
			end = int(d.variants[vi + 1].field_start)
		}
		variant_fields := d.fields[start:end]
		n := len(variant_fields)
		field_names   := make([]string, n)
		field_offsets := make([]int,    n)
		offset := 0
		for field, i in variant_fields {
			field_names[i]   = field.name.data
			field_offsets[i] = offset
			offset += type_slot_count(c, field.type)
		}
		if offset > max_field_slots do max_field_slots = offset
		variants[variant.name.data] = EnumVariantLayout{
			discriminant  = vi,
			field_names   = field_names,
			field_offsets = field_offsets,
			total_slots   = offset,
		}
	}
	return EnumLayout{total_slots = 1 + max_field_slots, variants = variants}
}

// compile_enum_literal emits a stack-allocated enum value:
//   slot 0: integer discriminant (variant index in declaration order)
//   slots 1..N: field values in variant declaration order
//   slots N+1..total-1: NIL padding so all variants occupy the same number of slots
compile_enum_literal :: proc(c: ^Compiler, e: parser.EnumLiteralExpression, span: lexer.Span) {
	layout, ok := c.enum_layouts[e.enum_name.data]
	if !ok {
		compiler_error(c, fmt.tprintf("undefined enum '%s'", e.enum_name.data), span)
		emit(&c.bc, .NIL, span)
		return
	}
	variant_layout, vok := layout.variants[e.variant_name.data]
	if !vok {
		compiler_error(c, fmt.tprintf("unknown variant '%s' on enum '%s'", e.variant_name.data, e.enum_name.data), span)
		emit(&c.bc, .NIL, span)
		return
	}
	// Slot 0: integer discriminant (index of this variant in declaration order)
	emit_constant(&c.bc, i64(variant_layout.discriminant), span)
	// Slots 1..N: fields in variant declaration order
	field_map := make(map[string]parser.ExpressionIdx)
	defer delete(field_map)
	for field in e.fields {
		field_map[field.name.data] = field.value
	}
	for name in variant_layout.field_names {
		val_idx, has_val := field_map[name]
		if !has_val {
			compiler_error(c, fmt.tprintf("missing field '%s' in enum literal", name), span)
			emit(&c.bc, .NIL, span)
			continue
		}
		compile_expr(c, val_idx)
	}
	// NIL-pad so every variant fills the same total_slots
	total_field_slots := layout.total_slots - 1 // excludes discriminant slot
	for _ in 0..<(total_field_slots - variant_layout.total_slots) {
		emit(&c.bc, .NIL, span)
	}
}

find_field :: proc(layout: StructLayout, field_name: string) -> (offset: int, slots: int, struct_type: string, ptr_inner: string, found: bool) {
	for i in 0..<len(layout.field_names) {
		if layout.field_names[i] == field_name {
			next := layout.total_slots
			if i + 1 < len(layout.field_offsets) {
				next = layout.field_offsets[i + 1]
			}
			pi := ""
			if len(layout.field_ptr_inners) > i {
				pi = layout.field_ptr_inners[i]
			}
			return layout.field_offsets[i], next - layout.field_offsets[i], layout.field_struct_types[i], pi, true
		}
	}
	return 0, 0, "", "", false
}

call_return_struct_type :: proc(c: ^Compiler, e: parser.CallExpression) -> string {
	callee_node := c.ast.nodes[e.callee]
	expr, ok := callee_node.(parser.Expression)
	if !ok do return ""
	id, ok2 := expr.(parser.IdentExpression)
	if !ok2 do return ""
	fn_name := lexer.Token(id).data
	for node in c.ast.nodes {
		decl, ok3 := node.(parser.Declaration)
		if !ok3 do continue
		fn, ok4 := decl.(parser.FunctionDecl)
		if !ok4 do continue
		if fn.name.data != fn_name do continue
		ret_idx, has_ret := fn.return_type.?
		if !has_ret do return ""
		if len(fn.type_params) == 0 {
			return type_ann_struct_name(c, ret_idx)
		}
		// Generic function: infer substitution from args, resolve return type with it.
		saved := make(map[string]string)
		for k, v in c.type_subst { saved[k] = v }
		for tp in fn.type_params {
			concrete := infer_type_param(c, fn, tp.data, e.args)
			if concrete != "" { c.type_subst[tp.data] = concrete }
		}
		result := type_ann_struct_name(c, ret_idx)
		clear(&c.type_subst)
		for k, v in saved { c.type_subst[k] = v }
		delete(saved)
		return result
	}
	return ""
}

// call_return_ptr_inner returns "T" if the callee's return type is ^T, or "".
call_return_ptr_inner :: proc(c: ^Compiler, e: parser.CallExpression) -> string {
	callee_node := c.ast.nodes[e.callee]
	expr, ok := callee_node.(parser.Expression)
	if !ok do return ""
	id, ok2 := expr.(parser.IdentExpression)
	if !ok2 do return ""
	fn_name := lexer.Token(id).data
	for node in c.ast.nodes {
		decl, ok3 := node.(parser.Declaration)
		if !ok3 do continue
		fn, ok4 := decl.(parser.FunctionDecl)
		if !ok4 do continue
		if fn.name.data != fn_name do continue
		ret_idx, has_ret := fn.return_type.?
		if !has_ret do return ""
		return type_ann_ptr_inner(c, ret_idx)
	}
	return ""
}

expr_struct_type :: proc(c: ^Compiler, idx: parser.ExpressionIdx) -> string {
	node := c.ast.nodes[int(idx)]
	expr, ok := node.(parser.Expression)
	if !ok do return ""
	#partial switch e in expr {
	case parser.StructLiteralExpression:
		if e.type_name.data == "Slice" { return "" }
		if len(e.type_args) > 0 {
			mangled := generic_struct_mangled_name(c, e.type_name.data, e.type_args)
			if _, ok := c.struct_layouts^[mangled]; ok { return mangled }
		}
		return e.type_name.data
	case parser.IdentExpression:
		return local_struct_type(&c.bc, lexer.Token(e).data)
	case parser.FieldAccessExpression:
		_, _, parent_type, ok2 := resolve_access_chain(c, e.object)
		if !ok2 do return ""
		layout, has := c.struct_layouts^[parent_type]
		if !has do return ""
		_, _, field_st, _, found := find_field(layout, e.field.data)
		if !found do return ""
		return field_st
	case parser.CallExpression:
		return call_return_struct_type(c, e)
	case parser.NewExpression:
		return ""  // new T{} returns a pointer, not a flat struct
	case parser.DerefExpression:
		return expr_ptr_inner(c, e.operand)  // p^ produces a flat struct copy
	}
	return ""
}

// expr_ptr_inner returns the inner struct name when the expression produces a ^T pointer.
expr_ptr_inner :: proc(c: ^Compiler, idx: parser.ExpressionIdx) -> string {
	node := c.ast.nodes[int(idx)]
	expr, ok := node.(parser.Expression)
	if !ok do return ""
	if ne, ok2 := expr.(parser.NewExpression); ok2 {
		return ne.type_name.data
	}
	if id, ok2 := expr.(parser.IdentExpression); ok2 {
		return local_ptr_inner(&c.bc, lexer.Token(id).data)
	}
	if ce, ok2 := expr.(parser.CallExpression); ok2 {
		return call_return_ptr_inner(c, ce)
	}
	if ao, ok2 := expr.(parser.AddrOfExpression); ok2 {
		return expr_struct_type(c, ao.operand)
	}
	return ""
}

compile_struct_literal :: proc(c: ^Compiler, e: parser.StructLiteralExpression, span: lexer.Span) {
	struct_name := e.type_name.data
	if len(e.type_args) > 0 {
		tmpl, is_generic := c.generic_struct_templates[struct_name]
		if !is_generic {
			compiler_error(c, fmt.tprintf("undefined generic struct '%s'", struct_name), span)
			return
		}
		struct_name = instantiate_generic_struct(c, tmpl, e.type_args)
	}
	layout, ok := c.struct_layouts^[struct_name]
	if !ok {
		compiler_error(c, fmt.tprintf("undefined struct '%s'", struct_name), span)
		return
	}
	field_map := make(map[string]parser.ExpressionIdx)
	defer delete(field_map)
	for field in e.fields {
		field_map[field.name.data] = field.value
	}
	for name in layout.field_names {
		val_idx, has_val := field_map[name]
		if !has_val {
			compiler_error(c, fmt.tprintf("missing field '%s' in struct literal", name), span)
			emit(&c.bc, .NIL, span)
			continue
		}
		compile_expr(c, val_idx)
	}
}

// resolve_access_chain walks a chain of field accesses (e.g. r.origin.x) and
// returns the base stack slot, an accumulated heap_offset (-1 for flat struct
// locals, >=0 for pointer locals), and the struct type at that point, so the
// caller can apply one more field lookup on top of it.
resolve_access_chain :: proc(c: ^Compiler, idx: parser.ExpressionIdx) -> (slot: int, heap_offset: int, struct_type: string, ok: bool) {
	node := c.ast.nodes[int(idx)]
	expr, is_expr := node.(parser.Expression)
	if !is_expr do return 0, -1, "", false
	#partial switch e in expr {
	case parser.IdentExpression:
		name := lexer.Token(e).data
		s, _, found := resolve_local(&c.bc, name)
		if !found do return 0, -1, "", false
		st := local_struct_type(&c.bc, name)
		pi := local_ptr_inner(&c.bc, name)
		if pi != "" {
			return s, 0, pi, true  // pointer local: heap_offset=0
		}
		return s, -1, st, true    // flat struct local: heap_offset=-1
	case parser.FieldAccessExpression:
		base, h_off, parent_type, chain_ok := resolve_access_chain(c, e.object)
		if !chain_ok do return 0, -1, "", false
		layout, has := c.struct_layouts^[parent_type]
		if !has do return 0, -1, "", false
		offset, _, field_st, _, found := find_field(layout, e.field.data)
		if !found do return 0, -1, "", false
		if h_off >= 0 {
			// Through pointer: accumulate heap offset (stops at pointer-typed fields — handled by compile_ptr_to_container)
			return base, h_off + offset, field_st, true
		}
		return base + offset, -1, field_st, true
	}
	return 0, -1, "", false
}

// compile_ptr_to_container emits bytecode that leaves the owning [^]Value pointer
// on the stack for the access chain in `idx`. Returns (heap_base, struct_type, ok).
// heap_base is the cumulative flat-struct offset within the heap object (used by
// the caller to address individual fields via HEAP_GET/HEAP_SET).
// For pointer-typed fields it emits HEAP_GET to hop through to the next pointer.
compile_ptr_to_container :: proc(c: ^Compiler, idx: parser.ExpressionIdx, span: lexer.Span) -> (heap_base: int, struct_type: string, ok: bool) {
	node := c.ast.nodes[int(idx)]
	expr, is_expr := node.(parser.Expression)
	if !is_expr do return 0, "", false
	#partial switch e in expr {
	case parser.IdentExpression:
		name := lexer.Token(e).data
		slot, _, found := resolve_local(&c.bc, name)
		if !found do return 0, "", false
		pi := local_ptr_inner(&c.bc, name)
		if pi == "" do return 0, "", false
		emit(&c.bc, .GET_LOCAL, span)
		emit_byte(&c.bc, u8(slot), span)
		return 0, pi, true

	case parser.FieldAccessExpression:
		base, parent_type, chain_ok := compile_ptr_to_container(c, e.object, span)
		if !chain_ok do return 0, "", false
		layout, has := c.struct_layouts^[parent_type]
		if !has do return 0, "", false
		field_offset, _, field_st, field_pi, found := find_field(layout, e.field.data)
		if !found do return 0, "", false
		if field_st != "" {
			// Flat struct field within the current heap object: accumulate offset.
			return base + field_offset, field_st, true
		}
		if field_pi != "" {
			// Pointer-typed field: emit HEAP_GET to load it, start a fresh chain.
			emit(&c.bc, .HEAP_GET, span)
			emit_byte(&c.bc, u8(base + field_offset), span)
			return 0, field_pi, true
		}
		return 0, "", false
	}
	return 0, "", false
}

compile_field_access :: proc(c: ^Compiler, e: parser.FieldAccessExpression, span: lexer.Span) {
	// String field access: s.len → STR_LEN
	if c.tc_types != nil && int(e.object) < len(c.tc_types) && c.tc_types[int(e.object)] == tc.STRING_TYPE {
		if e.field.data == "len" {
			compile_expr(c, e.object)
			emit(&c.bc, .STR_LEN, span)
			return
		}
		compiler_error(c, fmt.tprintf("no field '%s' on str", e.field.data), span)
		emit(&c.bc, .NIL, span)
		return
	}
	// Slice field access: s.len → slot+1, s.cap → slot+2, s.grow_factor → slot+3
	if obj_expr, obj_ok := c.ast.nodes[int(e.object)].(parser.Expression); obj_ok {
		if id, is_id := obj_expr.(parser.IdentExpression); is_id {
			name := lexer.Token(id).data
			if local_slice_elem_slots(&c.bc, name) > 0 {
				slot, _, _ := resolve_local(&c.bc, name)
				switch e.field.data {
				case "len":         emit(&c.bc, .GET_LOCAL, span); emit_byte(&c.bc, u8(slot + 1), span)
				case "cap":         emit(&c.bc, .GET_LOCAL, span); emit_byte(&c.bc, u8(slot + 2), span)
				case "grow_factor": emit(&c.bc, .GET_LOCAL, span); emit_byte(&c.bc, u8(slot + 3), span)
				case: compiler_error(c, fmt.tprintf("no field '%s' on Slice[T]", e.field.data), span); emit(&c.bc, .NIL, span)
				}
				return
			}
		}
	}
	base_slot, heap_offset, parent_type, ok := resolve_access_chain(c, e.object)

	if ok && parent_type != "" {
		layout, has_layout := c.struct_layouts^[parent_type]
		if !has_layout {
			compiler_error(c, "field access on non-struct value", span)
			return
		}
		field_offset, field_slots, _, _, field_found := find_field(layout, e.field.data)
		if !field_found {
			compiler_error(c, fmt.tprintf("unknown field '%s'", e.field.data), span)
			return
		}
		if heap_offset >= 0 {
			for s in 0..<field_slots {
				emit(&c.bc, .GET_LOCAL, span)
				emit_byte(&c.bc, u8(base_slot), span)
				emit(&c.bc, .HEAP_GET, span)
				emit_byte(&c.bc, u8(heap_offset + field_offset + s), span)
			}
		} else {
			for s in 0..<field_slots {
				emit(&c.bc, .GET_LOCAL, span)
				emit_byte(&c.bc, u8(base_slot + field_offset + s), span)
			}
		}
		return
	}

	// Fallback: chain passes through a pointer-typed field (e.g. a.next.val).
	heap_base, container_type, chain_ok := compile_ptr_to_container(c, e.object, span)
	if !chain_ok { compiler_error(c, "invalid field access", span); return }
	layout, has := c.struct_layouts^[container_type]
	if !has { compiler_error(c, "field access on non-struct value", span); return }
	field_offset, field_slots, _, _, field_found := find_field(layout, e.field.data)
	if !field_found { compiler_error(c, fmt.tprintf("unknown field '%s'", e.field.data), span); return }
	// ptr is on stack; emit HEAP_GET for each slot (re-push ptr for multi-slot reads).
	for s in 0..<field_slots {
		if s > 0 {
			// For multi-slot reads through a pointer hop we'd need the ptr again.
			// Single-slot (scalars, pointers) is the common case; this handles it.
			compiler_error(c, "multi-slot field read through pointer hop not yet supported", span)
			return
		}
		emit(&c.bc, .HEAP_GET, span)
		emit_byte(&c.bc, u8(heap_base + field_offset + s), span)
	}
}

compile_field_set :: proc(c: ^Compiler, e: parser.FieldAccessExpression, span: lexer.Span) {
	// Slice field set: s.len → slot+1, s.cap → slot+2, s.grow_factor → slot+3
	if obj_expr, obj_ok := c.ast.nodes[int(e.object)].(parser.Expression); obj_ok {
		if id, is_id := obj_expr.(parser.IdentExpression); is_id {
			name := lexer.Token(id).data
			if local_slice_elem_slots(&c.bc, name) > 0 {
				slot, _, _ := resolve_local(&c.bc, name)
				switch e.field.data {
				case "len":         emit(&c.bc, .SET_LOCAL, span); emit_byte(&c.bc, u8(slot + 1), span)
				case "cap":         emit(&c.bc, .SET_LOCAL, span); emit_byte(&c.bc, u8(slot + 2), span)
				case "grow_factor": emit(&c.bc, .SET_LOCAL, span); emit_byte(&c.bc, u8(slot + 3), span)
				case: compiler_error(c, fmt.tprintf("no field '%s' on Slice[T]", e.field.data), span)
				}
				return
			}
		}
	}
	base_slot, heap_offset, parent_type, ok := resolve_access_chain(c, e.object)

	if ok && parent_type != "" {
		layout, has_layout := c.struct_layouts^[parent_type]
		if !has_layout {
			compiler_error(c, "field assignment on non-struct value", span)
			return
		}
		field_offset, _, _, _, field_found := find_field(layout, e.field.data)
		if !field_found {
			compiler_error(c, fmt.tprintf("unknown field '%s'", e.field.data), span)
			return
		}
		if heap_offset >= 0 {
			emit(&c.bc, .GET_LOCAL, span)
			emit_byte(&c.bc, u8(base_slot), span)
			emit(&c.bc, .HEAP_SET, span)
			emit_byte(&c.bc, u8(heap_offset + field_offset), span)
		} else {
			emit(&c.bc, .SET_LOCAL, span)
			emit_byte(&c.bc, u8(base_slot + field_offset), span)
		}
		return
	}

	// Fallback: value is already on stack; emit ptr to container, then HEAP_SET.
	heap_base, container_type, chain_ok := compile_ptr_to_container(c, e.object, span)
	if !chain_ok { compiler_error(c, "invalid field assignment target", span); return }
	layout, has := c.struct_layouts^[container_type]
	if !has { compiler_error(c, "field assignment on non-struct value", span); return }
	field_offset, _, _, _, field_found := find_field(layout, e.field.data)
	if !field_found { compiler_error(c, fmt.tprintf("unknown field '%s'", e.field.data), span); return }
	emit(&c.bc, .HEAP_SET, span)
	emit_byte(&c.bc, u8(heap_base + field_offset), span)
}

// compile_new_expr pushes all struct fields in layout order, then emits NEW N.
// The VM allocates a heap slice of N Value slots, pops them, and pushes a ^Value pointer.
compile_new_expr :: proc(c: ^Compiler, e: parser.NewExpression, span: lexer.Span) {
	layout, ok := c.struct_layouts^[e.type_name.data]
	if !ok {
		compiler_error(c, fmt.tprintf("undefined struct '%s'", e.type_name.data), span)
		emit(&c.bc, .NIL, span)
		return
	}
	field_map := make(map[string]parser.ExpressionIdx)
	defer delete(field_map)
	for field in e.fields {
		field_map[field.name.data] = field.value
	}
	for name in layout.field_names {
		val_idx, has_val := field_map[name]
		if !has_val {
			compiler_error(c, fmt.tprintf("missing field '%s' in new expression", name), span)
			emit(&c.bc, .NIL, span)
			continue
		}
		compile_expr(c, val_idx)
	}
	emit(&c.bc, .NEW, span)
	emit_byte(&c.bc, u8(layout.total_slots), span)
}

// compile_deref_expr loads the pointer and emits HEAP_LOAD N to copy all slots.
compile_deref_expr :: proc(c: ^Compiler, e: parser.DerefExpression, span: lexer.Span) {
	// Determine how many heap slots to load from the pointer's inner type.
	pi := expr_ptr_inner(c, e.operand)
	n := 1
	if pi != "" {
		if layout, ok := c.struct_layouts^[pi]; ok {
			n = layout.total_slots
		}
	}
	compile_expr(c, e.operand)  // pushes the ^Value pointer
	emit(&c.bc, .HEAP_LOAD, span)
	emit_byte(&c.bc, u8(n), span)
}

// compile_addr_of emits ADDR_LOCAL for &x, pushing a raw pointer into the frame.
// Only struct or scalar locals are supported as the operand.
compile_addr_of :: proc(c: ^Compiler, e: parser.AddrOfExpression, span: lexer.Span) {
	ident, ok := c.ast.nodes[int(e.operand)].(parser.Expression)
	if !ok {
		compiler_error(c, "&: operand is not an expression", span)
		emit(&c.bc, .NIL, span)
		return
	}
	id, is_ident := ident.(parser.IdentExpression)
	if !is_ident {
		compiler_error(c, "&: operand must be a local variable", span)
		emit(&c.bc, .NIL, span)
		return
	}
	slot, _, found := resolve_local(&c.bc, lexer.Token(id).data)
	if !found {
		compiler_error(c, fmt.tprintf("&: undefined variable '%s'", lexer.Token(id).data), span)
		emit(&c.bc, .NIL, span)
		return
	}
	emit(&c.bc, .ADDR_LOCAL, span)
	emit_byte(&c.bc, u8(slot), span)
}

// compile_slice_literal handles Slice[T]{cap = n, grow_factor = k}.
// Emits cap then grow_factor onto the stack, then MAKE_SLICE elem_slots.
// Leaves 4 slots on the stack: [ptr, len=0, cap, grow_factor].
compile_slice_literal :: proc(c: ^Compiler, e: parser.StructLiteralExpression, span: lexer.Span) {
	if len(e.type_args) == 0 {
		compiler_error(c, "Slice[T]{} requires a type argument", span)
		emit(&c.bc, .NIL, span); emit(&c.bc, .NIL, span); emit(&c.bc, .NIL, span); emit(&c.bc, .NIL, span)
		return
	}
	cap_expr         := parser.ExpressionIdx(parser.INVALID_IDX)
	grow_factor_expr := parser.ExpressionIdx(parser.INVALID_IDX)
	for field in e.fields {
		if field.name.data == "cap"         { cap_expr         = field.value }
		if field.name.data == "grow_factor" { grow_factor_expr = field.value }
	}
	if u32(cap_expr) == parser.INVALID_IDX {
		emit_constant(&c.bc, i64(64), span)
	} else {
		compile_expr(c, cap_expr)
	}
	if u32(grow_factor_expr) == parser.INVALID_IDX {
		emit_constant(&c.bc, i64(1), span)
	} else {
		compile_expr(c, grow_factor_expr)
	}
	elem_slots := type_slot_count(c, e.type_args[0])
	emit(&c.bc, .MAKE_SLICE, span)
	emit_byte(&c.bc, u8(elem_slots), span)
}

// compile_array_literal pushes each element in order onto the stack.
// The resulting N*elem_slots contiguous values become the array local's slots.
compile_array_literal :: proc(c: ^Compiler, e: parser.ArrayLiteralExpression, span: lexer.Span) {
	for val in e.values {
		compile_expr(c, val)
	}
}

// compile_index_expression reads one element from a local array or slice.
compile_index_expression :: proc(c: ^Compiler, e: parser.IndexExpression, span: lexer.Span) {
	obj_node := c.ast.nodes[int(e.object)]
	obj_expr, ok := obj_node.(parser.Expression)
	if !ok { compiler_error(c, "index: object is not an expression", span); emit(&c.bc, .NIL, span); return }
	id, is_ident := obj_expr.(parser.IdentExpression)
	if !is_ident { compiler_error(c, "index: only local array/slice indexing is supported", span); emit(&c.bc, .NIL, span); return }
	name := lexer.Token(id).data
	slot, _, found := resolve_local(&c.bc, name)
	if !found { compiler_error(c, fmt.tprintf("undefined variable '%s'", name), span); emit(&c.bc, .NIL, span); return }
	// String path
	if c.tc_types != nil && int(e.object) < len(c.tc_types) && c.tc_types[int(e.object)] == tc.STRING_TYPE {
		emit(&c.bc, .GET_LOCAL, span)
		emit_byte(&c.bc, u8(slot), span)
		compile_expr(c, e.index)
		emit(&c.bc, .STR_GET, span)
		return
	}
	// Slice path
	if ses := local_slice_elem_slots(&c.bc, name); ses > 0 {
		emit(&c.bc, .GET_LOCAL, span)
		emit_byte(&c.bc, u8(slot), span)  // push ptr
		compile_expr(c, e.index)
		emit(&c.bc, .SLICE_GET, span)
		emit_byte(&c.bc, u8(ses), span)
		return
	}
	// Array path
	elem_slots := 0
	for i := len(c.bc.locals) - 1; i >= 0; i -= 1 {
		if c.bc.locals[i].name == name { elem_slots = c.bc.locals[i].array_elem_slots; break }
	}
	if elem_slots == 0 { compiler_error(c, fmt.tprintf("'%s' is not an array or slice", name), span); emit(&c.bc, .NIL, span); return }
	compile_expr(c, e.index)
	emit(&c.bc, .ARRAY_GET, span)
	emit_byte(&c.bc, u8(slot), span)
	emit_byte(&c.bc, u8(elem_slots), span)
}

// compile_index_set writes one element into a local array or slice.
// Precondition: the value is already on the stack (from compile_assignment).
compile_index_set :: proc(c: ^Compiler, e: parser.IndexExpression, span: lexer.Span) {
	obj_node := c.ast.nodes[int(e.object)]
	obj_expr, ok := obj_node.(parser.Expression)
	if !ok { compiler_error(c, "index assign: object is not an expression", span); return }
	id, is_ident := obj_expr.(parser.IdentExpression)
	if !is_ident { compiler_error(c, "index assign: only local array/slice indexing is supported", span); return }
	name := lexer.Token(id).data
	slot, _, found := resolve_local(&c.bc, name)
	if !found { compiler_error(c, fmt.tprintf("undefined variable '%s'", name), span); return }
	// Slice path: SLICE_SET reads ptr/cap from the frame directly (base_slot, elem_slots).
	if ses := local_slice_elem_slots(&c.bc, name); ses > 0 {
		compile_expr(c, e.index)
		emit(&c.bc, .SLICE_SET, span)
		emit_byte(&c.bc, u8(slot), span)
		emit_byte(&c.bc, u8(ses), span)
		return
	}
	// Array path
	elem_slots := 0
	for i := len(c.bc.locals) - 1; i >= 0; i -= 1 {
		if c.bc.locals[i].name == name { elem_slots = c.bc.locals[i].array_elem_slots; break }
	}
	if elem_slots == 0 { compiler_error(c, fmt.tprintf("'%s' is not an array or slice", name), span); return }
	compile_expr(c, e.index)
	emit(&c.bc, .ARRAY_SET, span)
	emit_byte(&c.bc, u8(slot), span)
	emit_byte(&c.bc, u8(elem_slots), span)
}

// ---- generics ----

// generic_struct_mangled_name computes the monomorphised name for a generic struct,
// e.g. Box[int] → "Box__int", Pair[int, float] → "Pair__int__float".
@private
generic_struct_mangled_name :: proc(c: ^Compiler, struct_name: string, type_args: []parser.TypeIdx) -> string {
	b := strings.builder_make()
	strings.write_string(&b, struct_name)
	for arg in type_args {
		strings.write_string(&b, "__")
		strings.write_string(&b, type_arg_mangled_name(c, arg))
	}
	return strings.to_string(b)
}

// instantiate_generic_struct builds and registers the concrete StructLayout for a
// generic struct if it has not been registered yet. Returns the mangled name.
@private
instantiate_generic_struct :: proc(c: ^Compiler, tmpl: parser.StructDecl, type_args: []parser.TypeIdx) -> string {
	mangled := generic_struct_mangled_name(c, tmpl.name.data, type_args)
	if _, exists := c.struct_layouts^[mangled]; exists { return mangled }
	// Pre-instantiate any GenericType args so their layouts exist when we build ours.
	for arg_idx in type_args {
		if int(arg_idx) >= len(c.ast.nodes) { continue }
		ty_node, ok := c.ast.nodes[int(arg_idx)].(parser.Type)
		if !ok { continue }
		if gt, ok2 := ty_node.(parser.GenericType); ok2 {
			if inner_tmpl, has := c.generic_struct_templates[gt.name.data]; has {
				instantiate_generic_struct(c, inner_tmpl, gt.args)
			}
		}
	}
	saved := make(map[string]string)
	for k, v in c.type_subst { saved[k] = v }
	for tp, i in tmpl.type_params {
		if i >= len(type_args) { break }
		c.type_subst[tp.data] = type_arg_mangled_name(c, type_args[i])
	}
	layout := build_struct_layout(c, tmpl)
	c.struct_layouts^[mangled] = layout
	clear(&c.type_subst)
	for k, v in saved { c.type_subst[k] = v }
	delete(saved)
	return mangled
}

// type_ann_raw_name returns the raw identifier string of a NamedType annotation,
// or "" for pointer/fn types. Used to detect which params are type parameters.
@private
type_ann_raw_name :: proc(c: ^Compiler, type_idx: parser.TypeIdx) -> string {
	if int(type_idx) >= len(c.ast.nodes) { return "" }
	node := c.ast.nodes[int(type_idx)]
	ty, ok := node.(parser.Type)
	if !ok { return "" }
	named, ok2 := ty.(parser.NamedType)
	if !ok2 { return "" }
	return lexer.Token(named).data
}

// type_arg_mangled_name returns the fully-resolved name for one type argument.
// For NamedType it applies type_subst ("T" → "int").
// For GenericType it recurses to produce a mangled name ("Box[int]" → "Box__int").
@private
type_arg_mangled_name :: proc(c: ^Compiler, type_idx: parser.TypeIdx) -> string {
	if int(type_idx) >= len(c.ast.nodes) { return "" }
	node := c.ast.nodes[int(type_idx)]
	ty, ok := node.(parser.Type)
	if !ok { return "" }
	if gt, ok2 := ty.(parser.GenericType); ok2 {
		return generic_struct_mangled_name(c, gt.name.data, gt.args)
	}
	named, ok2 := ty.(parser.NamedType)
	if !ok2 { return "" }
	name := lexer.Token(named).data
	if subst, has := c.type_subst[name]; has { name = subst }
	return name
}

// parse_one_mangled_arg reads one type-arg token from the front of s, returning
// the full mangled arg name and the rest of the string after consuming it.
// Respects nested generic arities: "Box__int" in "Box__int__float" → ("Box__int", "float").
@private
parse_one_mangled_arg :: proc(c: ^Compiler, s: string) -> (arg: string, rest: string) {
	sep := strings.index(s, "__")
	token, tail: string
	if sep < 0 {
		token = s; tail = ""
	} else {
		token = s[:sep]; tail = s[sep+2:]
	}
	tmpl, is_gen := c.generic_struct_templates[token]
	if !is_gen { return token, tail }
	b := strings.builder_make()
	strings.write_string(&b, token)
	remaining := tail
	for _ in tmpl.type_params {
		sub_arg, sub_rest := parse_one_mangled_arg(c, remaining)
		strings.write_string(&b, "__")
		strings.write_string(&b, sub_arg)
		remaining = sub_rest
	}
	return strings.to_string(b), remaining
}

// type_id_to_name converts a typechecker TypeId to a concrete type name string.
@private
type_id_to_name :: proc(c: ^Compiler, id: tc.TypeId) -> string {
	switch id {
	case tc.VOID_TYPE, tc.UNKNOWN_TYPE: return ""
	case tc.INT_TYPE:    return "int"
	case tc.FLOAT_TYPE:  return "float"
	case tc.BOOL_TYPE:   return "bool"
	case tc.STRING_TYPE: return "string"
	}
	if c.tc_type_table == nil || int(id) >= len(c.tc_type_table) { return "" }
	#partial switch t in c.tc_type_table[int(id)] {
	case tc.StructType: return t.name
	case tc.EnumType:   return t.name
	}
	return ""
}

// infer_arg_type_name returns the concrete type name for an argument expression.
// Prefers the runtime mangled struct/enum name so generic struct args (e.g. Box__int)
// are not collapsed back to their template name by the typechecker.
@private
infer_arg_type_name :: proc(c: ^Compiler, idx: parser.ExpressionIdx) -> string {
	if st := expr_struct_type(c, idx); st != "" { return st }
	if et := expr_enum_type(c, idx); et != "" { return et }
	if c.tc_types == nil || int(idx) >= len(c.tc_types) { return "" }
	return type_id_to_name(c, c.tc_types[int(idx)])
}

// infer_type_param finds the concrete type for one type parameter by scanning the
// call's argument list matching parameters annotated with that type param name,
// either directly (a: T) or structurally (b: Box[T]).
@private
infer_type_param :: proc(c: ^Compiler, tmpl: parser.FunctionDecl, type_param_name: string, args: []parser.ExpressionIdx) -> string {
	for param, i in tmpl.params {
		if i >= len(args) { break }
		ann := type_ann_raw_name(c, param.type)
		if ann == type_param_name {
			// Direct match: param type is T itself.
			concrete := infer_arg_type_name(c, args[i])
			if concrete != "" { return concrete }
			if subst, has := c.type_subst[type_param_name]; has { return subst }
		} else {
			// Structural match: param type might be a generic struct containing T, e.g. Box[T].
			extracted := infer_type_param_from_generic(c, param.type, type_param_name, args[i])
			if extracted != "" { return extracted }
		}
	}
	return ""
}

// infer_type_param_from_generic handles the case where a parameter is declared as
// a generic struct type such as Box[T]. It looks up which position T occupies in
// the type args of the generic struct, then reads that position out of the
// argument's concrete struct name (e.g. "Box__int" → "int").
@private
infer_type_param_from_generic :: proc(c: ^Compiler, param_type_idx: parser.TypeIdx, type_param_name: string, arg_idx: parser.ExpressionIdx) -> string {
	if int(param_type_idx) >= len(c.ast.nodes) { return "" }
	ty, ok := c.ast.nodes[int(param_type_idx)].(parser.Type)
	if !ok { return "" }

	// Handle ^GenericType: param is a pointer to a generic struct (e.g. ^Stack[T]).
	// Strip the pointer on both sides, then match inner GenericType against the
	// concrete inner struct name obtained from the arg's pointer target.
	if ptr, ok2 := ty.(parser.PointerType); ok2 {
		arg_inner := expr_ptr_inner(c, arg_idx)
		if arg_inner == "" { return "" }
		if int(ptr.inner) >= len(c.ast.nodes) { return "" }
		inner_ty, ok3 := c.ast.nodes[int(ptr.inner)].(parser.Type)
		if !ok3 { return "" }
		inner_gt, ok4 := inner_ty.(parser.GenericType)
		if !ok4 { return "" }
		tp_pos := -1
		for tp_arg, j in inner_gt.args {
			if type_ann_raw_name(c, tp_arg) == type_param_name { tp_pos = j; break }
		}
		if tp_pos < 0 { return "" }
		base := inner_gt.name.data
		if !strings.has_prefix(arg_inner, base) { return "" }
		after := arg_inner[len(base):]
		if !strings.has_prefix(after, "__") { return "" }
		remaining := after[2:]
		for i := 0; i <= tp_pos; i += 1 {
			tok, rest := parse_one_mangled_arg(c, remaining)
			if i == tp_pos { return tok }
			remaining = rest
		}
		return ""
	}

	gt, ok2 := ty.(parser.GenericType)
	if !ok2 { return "" }

	// Find which position type_param_name occupies in the generic type's args.
	tp_pos := -1
	for tp_arg, j in gt.args {
		if type_ann_raw_name(c, tp_arg) == type_param_name { tp_pos = j; break }
	}
	if tp_pos < 0 { return "" }

	// Case 1: arg is a struct literal with explicit type args, e.g. Box[int]{...}.
	// Read the type directly without needing a compiled layout.
	if arg_node, ok3 := c.ast.nodes[int(arg_idx)].(parser.Expression); ok3 {
		if sle, ok4 := arg_node.(parser.StructLiteralExpression); ok4 {
			if sle.type_name.data == gt.name.data && tp_pos < len(sle.type_args) {
				name := type_arg_mangled_name(c, sle.type_args[tp_pos])
				if name != "" { return name }
			}
		}
	}

	// Case 2: arg is a compiled local/expression — its struct type is a mangled
	// name like "Box__int". Use parse_one_mangled_arg to correctly handle nested
	// generic names such as "Box__Box__int" → tp_pos=0 yields "Box__int".
	arg_struct := expr_struct_type(c, arg_idx)
	if arg_struct == "" { return "" }
	base := gt.name.data
	if !strings.has_prefix(arg_struct, base) { return "" }
	after_base := arg_struct[len(base):]
	if !strings.has_prefix(after_base, "__") { return "" }
	suffix := after_base[2:]
	remaining := suffix
	for i := 0; i <= tp_pos; i += 1 {
		arg_tok, rest := parse_one_mangled_arg(c, remaining)
		if i == tp_pos { return arg_tok }
		remaining = rest
	}
	return ""
}

// compute_generic_mangled_name produces the unique name for one instantiation,
// e.g. "max__int" or "pair__int__float".
@private
compute_generic_mangled_name :: proc(c: ^Compiler, tmpl: parser.FunctionDecl, args: []parser.ExpressionIdx) -> string {
	b := strings.builder_make()
	strings.write_string(&b, tmpl.name.data)
	for tp in tmpl.type_params {
		concrete := infer_type_param(c, tmpl, tp.data, args)
		strings.write_string(&b, "__")
		if concrete != "" {
			strings.write_string(&b, concrete)
		} else {
			strings.write_string(&b, "unknown")
		}
	}
	return strings.to_string(b)
}

