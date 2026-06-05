package myr

import "core:fmt"
import "core:os"
import bc "backend/bytecode"
import "backend/bytecode/vm"
import "parser"

main :: proc() {
	args := os.args[1:]

	if len(args) == 0 {
		fmt.eprintln("usage: myr [--dump] <file.myr>")
		os.exit(1)
	}

	dump := false
	file := ""
	for arg in args {
		if arg == "--dump" {
			dump = true
		} else {
			file = arg
		}
	}

	if file == "" {
		fmt.eprintln("usage: myr [--dump] <file.myr>")
		os.exit(1)
	}

	source, err := os.read_entire_file_from_path(file, context.allocator)
	if err != os.ERROR_NONE {
		fmt.eprintfln("error: could not read '%s'", file)
		os.exit(1)
	}
	defer delete(source)

	// parse
	p   := parser.new_parser(string(source))
	ast := parser.parse_program(&p)
	defer parser.ast_destroy(&ast)

	if len(p.errors) > 0 {
		for &e in p.errors {
			fmt.eprintln(parser.decode_parser_error_message(&e, string(source)))
		}
		delete(p.errors)
		os.exit(1)
	}
	delete(p.errors)

	// compile
	fn, comp_errors := bc.compile(&ast)
	if len(comp_errors) > 0 {
		for e in comp_errors {
			fmt.eprintfln("compile error at %d:%d — %s", e.span.start, e.span.end, e.message)
		}
		os.exit(1)
	}
	defer bc.function_free(fn)

	// disassemble (optional)
	if dump {
		bc.disassemble_chunk(&fn.chunk, fn.name)
		fmt.println()
	}

	// run
	machine := vm.new_vm()
	defer vm.destroy_vm(&machine)
	if vm_err := vm.vm_interpret(&machine, fn); vm_err != nil {
		fmt.eprintfln("runtime error: %v", vm_err)
		os.exit(1)
	}
}
