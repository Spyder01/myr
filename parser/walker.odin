package parser

import "../lexer"

// ---- Recursive visitor ----

Visitor :: proc(node: Node, span: lexer.Span)

visit_decl :: proc(ast: ^AST, idx: DeclarationIdx, visit: Visitor) {
	if idx == DeclarationIdx(INVALID_IDX) do return
	visit(ast.nodes[idx], ast.spans[idx])
	switch d in ast.nodes[idx].(Declaration) {
	case FunctionDecl:
		visit_block(ast, d.body, visit)
	case StructDecl, EnumDecl, ImportDecl, ConstDecl:
		// leaves
	}
}

visit_block :: proc(ast: ^AST, block: BlockExpression, visit: Visitor) {
	for stmt in block.stmts do visit_stmt(ast, stmt, visit)
	if result, ok := block.result.?; ok do visit_expr(ast, result, visit)
}

visit_stmt :: proc(ast: ^AST, idx: StatementIdx, visit: Visitor) {
	if idx == StatementIdx(INVALID_IDX) do return
	visit(ast.nodes[idx], ast.spans[idx])
	switch s in ast.nodes[idx].(Statement) {
	case ConstStatement:
		visit_expr(ast, s.value, visit)
	case LetStatement:
		visit_expr(ast, s.value, visit)
	case ReturnStatement:
		if value, ok := s.value.?; ok do visit_expr(ast, value, visit)
	case ExpressionStatement:
		visit_expr(ast, s.expr, visit)
	case WithContextStatement:
		for override in s.overrides do visit_expr(ast, override.value, visit)
		visit_block(ast, s.body, visit)
	case ForStatement:
		if init, ok := s.init.?; ok      do visit_stmt(ast, init, visit)
		if cond, ok := s.condition.?; ok do visit_expr(ast, cond, visit)
		if post, ok := s.post.?; ok      do visit_stmt(ast, post, visit)
		visit_block(ast, s.body, visit)
	case BreakStatement, ContinueStatement:
		// leaves
	}
}

visit_expr :: proc(ast: ^AST, idx: ExpressionIdx, visit: Visitor) {
	if idx == ExpressionIdx(INVALID_IDX) do return
	visit(ast.nodes[idx], ast.spans[idx])
	switch e in ast.nodes[idx].(Expression) {
	case BinaryExpression:
		visit_expr(ast, e.left, visit)
		visit_expr(ast, e.right, visit)
	case UnaryExpression:
		visit_expr(ast, e.operand, visit)
	case CallExpression:
		visit_expr(ast, e.callee, visit)
		for arg in e.args do visit_expr(ast, arg, visit)
	case FieldAccessExpression:
		visit_expr(ast, e.object, visit)
	case IndexExpression:
		visit_expr(ast, e.object, visit)
		visit_expr(ast, e.index, visit)
	case IfExpression:
		visit_expr(ast, e.condition, visit)
		visit_block(ast, e.then_block, visit)
		if else_block, ok := e.else_block.?; ok do visit_block(ast, else_block, visit)
	case MatchExpression:
		visit_expr(ast, e.subject, visit)
		for arm in e.arms {
			visit_expr(ast, arm.pattern, visit)
			visit_expr(ast, arm.body, visit)
		}
	case BlockExpression:
		visit_block(ast, e, visit)
	case LiteralExpression, IdentExpression:
		// leaves
	}
}

// ---- Cursor walker ----


WalkerCursor :: struct {
	ast:   ^AST,
	stack: [dynamic]u32,
}

walker_init :: proc(ast: ^AST, root: DeclarationIdx) -> WalkerCursor {
	w := WalkerCursor{ast = ast, stack = make([dynamic]u32)}
	append(&w.stack, u32(root))
	return w
}

walker_done :: proc(w: ^WalkerCursor) -> bool {
	return len(w.stack) == 0
}

walker_destroy :: proc(w: ^WalkerCursor) {
	delete(w.stack)
}

walker_next :: proc(w: ^WalkerCursor) -> (Node, lexer.Span) {
	idx  := pop(&w.stack)
	node := w.ast.nodes[idx]
	span := w.ast.spans[idx]
	walker_push_children(w, node)
	return node, span
}

@private
walker_push_children :: proc(w: ^WalkerCursor, node: Node) {
	switch n in node {
	case Expression: walker_push_expr(w, n)
	case Statement:  walker_push_stmt(w, n)
	case Declaration:
		if d, ok := n.(FunctionDecl); ok {
			walker_push_block(w, d.body)
		}
	case Type:
		// types have no child nodes in the pool
	}
}

@private
walker_push_expr :: proc(w: ^WalkerCursor, e: Expression) {
	switch v in e {
	case BinaryExpression:
		append(&w.stack, u32(v.right))
		append(&w.stack, u32(v.left))
	case UnaryExpression:
		append(&w.stack, u32(v.operand))
	case CallExpression:
		for i := len(v.args) - 1; i >= 0; i -= 1 {
			append(&w.stack, u32(v.args[i]))
		}
		append(&w.stack, u32(v.callee))
	case FieldAccessExpression:
		append(&w.stack, u32(v.object))
	case IndexExpression:
		append(&w.stack, u32(v.index))
		append(&w.stack, u32(v.object))
	case IfExpression:
		if else_block, ok := v.else_block.?; ok {
			walker_push_block(w, else_block)
		}
		walker_push_block(w, v.then_block)
		append(&w.stack, u32(v.condition))
	case MatchExpression:
		for i := len(v.arms) - 1; i >= 0; i -= 1 {
			append(&w.stack, u32(v.arms[i].body))
			append(&w.stack, u32(v.arms[i].pattern))
		}
		append(&w.stack, u32(v.subject))
	case BlockExpression:
		walker_push_block(w, v)
	case LiteralExpression, IdentExpression:
		// leaves
	}
}

@private
walker_push_stmt :: proc(w: ^WalkerCursor, s: Statement) {
	switch v in s {
	case ConstStatement:
		append(&w.stack, u32(v.value))
	case LetStatement:
		append(&w.stack, u32(v.value))
	case ReturnStatement:
		if value, ok := v.value.?; ok {
			append(&w.stack, u32(value))
		}
	case ExpressionStatement:
		append(&w.stack, u32(v.expr))
	case WithContextStatement:
		walker_push_block(w, v.body)
		for i := len(v.overrides) - 1; i >= 0; i -= 1 {
			append(&w.stack, u32(v.overrides[i].value))
		}
	case ForStatement:
		walker_push_block(w, v.body)
		if post, ok := v.post.?; ok      do append(&w.stack, u32(post))
		if cond, ok := v.condition.?; ok do append(&w.stack, u32(cond))
		if init, ok := v.init.?; ok      do append(&w.stack, u32(init))
	case BreakStatement, ContinueStatement:
		// leaves
	}
}

@private
walker_push_block :: proc(w: ^WalkerCursor, block: BlockExpression) {
	if result, ok := block.result.?; ok {
		append(&w.stack, u32(result))
	}
	for i := len(block.stmts) - 1; i >= 0; i -= 1 {
		append(&w.stack, u32(block.stmts[i]))
	}
}
