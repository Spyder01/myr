package myr

import "core:fmt"
import "core:mem/virtual"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import bc "backend/bytecode"
import "embed"
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
	file      := ""
	dump      := false
	show_time := false
	for arg in args {
		switch arg {
		case "--dump":        dump = true
		case "--time":        show_time = true
		case "--help", "-h":  print_command_help("run"); return
		case:                 file = arg
		}
	}
	if file == "" {
		fmt.eprintln("error: 'myr run' requires a file")
		fmt.eprintln("       usage: myr run [--dump] [--time] <file.myr>")
		os.exit(1)
	}
	run_file(file, dump = dump, execute = true, show_time = show_time)
}

cmd_check :: proc(args: []string) {
	file      := ""
	show_time := false
	for arg in args {
		switch arg {
		case "--time":        show_time = true
		case "--help", "-h":  print_command_help("check"); return
		case:                 file = arg
		}
	}
	if file == "" {
		fmt.eprintln("error: 'myr check' requires a file")
		fmt.eprintln("       usage: myr check [--time] <file.myr>")
		os.exit(1)
	}
	run_file(file, dump = false, execute = false, show_time = show_time)
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

run_file :: proc(file: string, dump: bool, execute: bool, show_time: bool = false) {
	source_bytes, read_err := os.read_entire_file_from_path(file, context.allocator)
	if read_err != os.ERROR_NONE {
		fmt.eprintfln("error: could not read '%s'", file)
		os.exit(1)
	}
	defer delete(source_bytes)
	source := string(source_bytes)

	state := embed.myr_new()
	defer embed.myr_free(&state)
	embed.myr_register(&state, "print", cli_print_native)

	source_dir := filepath.dir(file)
	if source_dir == "" { source_dir = "." }
	source_file := filepath.base(file)

	compile_start := time.tick_now()
	compile_errors := embed.myr_compile(&state, source, source_dir, source_file)
	t_compile := time.tick_since(compile_start)

	if compile_errors != nil {
		for e in compile_errors {
			line, col := parser.offset_to_line_col(source, e.offset)
			fmt.eprintfln("%s:%d:%d: error: %s", file, line, col, e.message)
		}
		delete(compile_errors)
		os.exit(1)
	}

	if dump {
		bc.disassemble_all(state.module)
		fmt.println()
	}

	if show_time { fmt.eprintfln("  compile:  %v", t_compile) }

	if !execute do return

	t0 := time.tick_now()
	if vm_err := embed.myr_run(&state); vm_err != nil {
		fmt.eprintfln("%s: runtime error: %v", file, vm_err)
		os.exit(1)
	}
	t_run := time.tick_since(t0)

	if show_time { fmt.eprintfln("  run:      %v", t_run) }
}

// cli_print_native is the default print implementation for the CLI.
// Each argument is printed on its own line, matching the original PRINT opcode behaviour.
cli_print_native :: proc(args: []bc.Value) -> bc.Value {
	for arg in args {
		switch v in arg {
		case i64:       fmt.printf("%d", v)
		case f64:       fmt.printf("%g", v)
		case bool:      fmt.printf("%t", v)
		case string:    fmt.printf("%s", v)
		case bc.Nil:    fmt.printf("nil")
		case bc.FnRef:  fmt.printf("<fn#%d>", int(v))
		case [^]bc.Value:
			if v == nil { fmt.printf("nil") } else { fmt.printf("<ptr>") }
		}
		fmt.println()
	}
	return bc.Nil{}
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
