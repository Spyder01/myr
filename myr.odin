package myr

import "core:fmt"
import "core:os"
import "core:strings"
import bc "backend/bytecode"
import "backend/bytecode/vm"
import "parser"

VERSION :: "0.1.0"

main :: proc() {
	args := os.args[1:]

	if len(args) == 0 {
		print_usage()
		os.exit(0)
	}

	cmd  := args[0]
	rest := args[1:]

	switch cmd {
	case "run":
		cmd_run(rest)
	case "check":
		cmd_check(rest)
	case "dump":
		cmd_dump(rest)
	case "version", "--version", "-V":
		fmt.printfln("myr %s", VERSION)
	case "help", "--help", "-h":
		if len(rest) > 0 {
			print_command_help(rest[0])
		} else {
			print_help()
		}
	case:
		if strings.has_suffix(cmd, ".myr") {
			// shorthand: myr <file>  →  myr run <file>
			run_file(cmd, dump = false, execute = true)
		} else {
			fmt.eprintfln("error: unknown command '%s'", cmd)
			fmt.eprintln("       run 'myr help' for usage")
			os.exit(1)
		}
	}
}

// ---- commands ----

cmd_run :: proc(args: []string) {
	file := ""
	dump := false
	for arg in args {
		switch arg {
		case "--dump": dump = true
		case "--help", "-h": print_command_help("run"); return
		case: file = arg
		}
	}
	if file == "" {
		fmt.eprintln("error: 'myr run' requires a file")
		fmt.eprintln("       usage: myr run [--dump] <file.myr>")
		os.exit(1)
	}
	run_file(file, dump = dump, execute = true)
}

cmd_check :: proc(args: []string) {
	file := ""
	for arg in args {
		switch arg {
		case "--help", "-h": print_command_help("check"); return
		case: file = arg
		}
	}
	if file == "" {
		fmt.eprintln("error: 'myr check' requires a file")
		fmt.eprintln("       usage: myr check <file.myr>")
		os.exit(1)
	}
	run_file(file, dump = false, execute = false)
}

cmd_dump :: proc(args: []string) {
	file := ""
	for arg in args {
		switch arg {
		case "--help", "-h": print_command_help("dump"); return
		case: file = arg
		}
	}
	if file == "" {
		fmt.eprintln("error: 'myr dump' requires a file")
		fmt.eprintln("       usage: myr dump <file.myr>")
		os.exit(1)
	}
	run_file(file, dump = true, execute = false)
}

// ---- core pipeline ----

run_file :: proc(file: string, dump: bool, execute: bool) {
	source_bytes, err := os.read_entire_file_from_path(file, context.allocator)
	if err != os.ERROR_NONE {
		fmt.eprintfln("error: could not read '%s'", file)
		os.exit(1)
	}
	defer delete(source_bytes)
	source := string(source_bytes)

	p   := parser.new_parser(source)
	ast := parser.parse_program(&p)
	defer parser.ast_destroy(&ast)

	if len(p.errors) > 0 {
		for &e in p.errors {
			fmt.eprintln(parser.decode_parser_error_message(&e, source))
		}
		delete(p.errors)
		os.exit(1)
	}
	delete(p.errors)

	fn, comp_errors := bc.compile(&ast)
	if len(comp_errors) > 0 {
		for e in comp_errors {
			line, col := offset_to_line_col(source, e.span.start)
			fmt.eprintfln("%s:%d:%d: error: %s", file, line, col, e.message)
		}
		os.exit(1)
	}
	defer bc.function_free(fn)

	if dump {
		bc.disassemble_chunk(&fn.chunk, fn.name)
		fmt.println()
	}

	if !execute do return

	machine := vm.new_vm()
	defer vm.destroy_vm(&machine)
	if vm_err := vm.vm_interpret(&machine, fn); vm_err != nil {
		fmt.eprintfln("%s: runtime error: %v", file, vm_err)
		os.exit(1)
	}
}

// ---- helpers ----

offset_to_line_col :: proc(source: string, offset: u32) -> (line, col: int) {
	line = 1
	col  = 1
	for i := u32(0); i < offset && int(i) < len(source); i += 1 {
		if source[i] == '\n' {
			line += 1
			col   = 1
		} else {
			col  += 1
		}
	}
	return
}

// ---- help ----

print_usage :: proc() {
	fmt.println("myr — a language designed around simplicity and control")
	fmt.println()
	fmt.printfln("version: %s", VERSION)
	fmt.println()
	fmt.println("usage:")
	fmt.println("  myr <command> [options]")
	fmt.println("  myr <file.myr>            shorthand for 'myr run <file.myr>'")
	fmt.println()
	fmt.println("commands:")
	fmt.println("  run    <file>   parse, compile and execute a .myr file")
	fmt.println("  check  <file>   parse and compile without executing (error check)")
	fmt.println("  dump   <file>   show compiled bytecode disassembly")
	fmt.println("  version         print version")
	fmt.println("  help [command]  print this message or help for a specific command")
	fmt.println()
	fmt.println("run 'myr help <command>' for details on a specific command")
}

print_help :: proc() {
	print_usage()
}

print_command_help :: proc(cmd: string) {
	switch cmd {
	case "run":
		fmt.println("myr run — parse, compile and execute a .myr source file")
		fmt.println()
		fmt.println("usage:")
		fmt.println("  myr run [--dump] <file.myr>")
		fmt.println()
		fmt.println("options:")
		fmt.println("  --dump    print bytecode disassembly before executing")
		fmt.println("  --help    print this message")
		fmt.println()
		fmt.println("examples:")
		fmt.println("  myr run main.myr")
		fmt.println("  myr run --dump main.myr")

	case "check":
		fmt.println("myr check — parse and compile a .myr file without executing it")
		fmt.println()
		fmt.println("usage:")
		fmt.println("  myr check <file.myr>")
		fmt.println()
		fmt.println("exits with code 0 if the file is valid, 1 if there are errors.")
		fmt.println()
		fmt.println("examples:")
		fmt.println("  myr check main.myr")

	case "dump":
		fmt.println("myr dump — show the bytecode disassembly of a .myr file")
		fmt.println()
		fmt.println("usage:")
		fmt.println("  myr dump <file.myr>")
		fmt.println()
		fmt.println("compiles the file and prints all bytecode chunks.")
		fmt.println("useful for understanding compiler output and debugging codegen.")
		fmt.println()
		fmt.println("examples:")
		fmt.println("  myr dump main.myr")

	case "version":
		fmt.println("myr version — print the Myr version")
		fmt.println()
		fmt.println("usage:")
		fmt.println("  myr version")

	case:
		fmt.eprintfln("error: no help for unknown command '%s'", cmd)
		fmt.eprintln("       run 'myr help' for the list of commands")
		os.exit(1)
	}
}
