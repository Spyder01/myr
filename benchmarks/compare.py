#!/usr/bin/env python3
"""
Myr vs Python vs Node benchmark comparison.
Usage: python3 benchmarks/compare.py  (run from project root)
"""
import subprocess, os, sys, tempfile

ODIN  = os.environ.get("ODIN",  "/Users/suhanj/.lang/Odin/odin")
NODE  = os.environ.get("NODE",  "node")
PY    = os.environ.get("PYTHON", sys.executable)
RUNS  = 3

# ---- runtime programs ----

PYTHON = {
    "fib": """\
def fib(n):
    if n <= 1: return n
    return fib(n-1) + fib(n-2)
print(fib(30))
""",
    "loop": """\
s = 0
for i in range(1000000): s += i
print(s)
""",
    "calls": """\
def add(a, b): return a + b
s = 0
for i in range(100000): s = add(s, i)
print(s)
""",
    "primes": """\
def is_prime(n):
    if n < 2: return False
    i = 2
    while i * i <= n:
        if n % i == 0: return False
        i += 1
    return True
print(sum(1 for n in range(2, 10001) if is_prime(n)))
""",
    "str_compare": """\
a, b = "hello world", "hello world"
count = 0
for i in range(1000000):
    if a == b: count += 1
print(count)
""",
    "str_concat": """\
count = 0
for i in range(100000):
    s = "hello" + " " + "world"
    if s == "hello world": count += 1
print(count)
""",
}

NODE_JS = {
    "fib": """\
function fib(n){if(n<=1)return n;return fib(n-1)+fib(n-2);}
console.log(fib(30));
""",
    "loop": """\
let s=BigInt(0);
for(let i=BigInt(0);i<BigInt(1000000);i++) s+=i;
console.log(s.toString());
""",
    "calls": """\
function add(a,b){return a+b;}
let s=0;for(let i=0;i<100000;i++) s=add(s,i);
console.log(s);
""",
    "primes": """\
function isPrime(n){if(n<2)return false;for(let i=2;i*i<=n;i++)if(n%i===0)return false;return true;}
let c=0;for(let n=2;n<=10000;n++)if(isPrime(n))c++;
console.log(c);
""",
    "str_compare": """\
const a="hello world",b="hello world";
let count=0;for(let i=0;i<1000000;i++)if(a===b)count++;
console.log(count);
""",
    "str_concat": """\
let count=0;
for(let i=0;i<100000;i++){const s="hello"+" "+"world";if(s==="hello world")count++;}
console.log(count);
""",
}

# ---- measurement ----

def measure(cmd, runs=RUNS):
    """Returns (avg_ms, avg_kib, last_output)"""
    times, mems = [], []
    out = ""
    for _ in range(runs):
        r = subprocess.run(
            ["/usr/bin/time", "-l"] + cmd,
            capture_output=True, text=True,
        )
        out = r.stdout.strip()
        for line in r.stderr.splitlines():
            if "real" in line:
                try: times.append(float(line.split()[0]) * 1000)
                except: pass
            if "maximum resident set size" in line:
                try: mems.append(int(line.split()[0]) // 1024)
                except: pass
    return (
        sum(times) / len(times) if times else 0,
        sum(mems)  / len(mems)  if mems  else 0,
        out,
    )

def run_script(runtime_cmd, source, suffix):
    with tempfile.NamedTemporaryFile("w", suffix=suffix, delete=False) as f:
        f.write(source)
        f.flush()
        return measure(runtime_cmd + [f.name])

# ---- benchmarks ----

MYR_ONLY = [
    ("for_while",   "benchmarks/for_while.myr",    "499999500000"),
    ("for_inf",     "benchmarks/for_infinite.myr",  "499999500000"),
    ("for_c",       "benchmarks/for_c_style.myr",   "499999500000"),
]

CROSS = [
    ("fib",         "benchmarks/fib.myr",           "832040"),
    ("loop",        "benchmarks/loop.myr",           "499999500000"),
    ("calls",       "benchmarks/calls.myr",          "4999950000"),
    ("primes",      "benchmarks/primes.myr",         "1229"),
    ("str_compare", "benchmarks/str_compare.myr",    "1000000"),
    ("str_concat",  "benchmarks/str_concat.myr",     "100000"),
]

# ---- formatting ----

def fmt_ms(ms):
    if ms < 1: return "  <1ms"
    return f"{ms:5.0f}ms"

def fmt_mem(kib):
    if kib >= 1024: return f"{kib/1024:4.1f}MiB"
    return f"{kib:4.0f}KiB"

def cmp_label(myr, other):
    if other <= 0 or myr <= 0: return "     —"
    r = other / myr
    if   r > 1.05: return f"myr {r:.1f}x faster"
    elif r < 0.95: return f"myr {1/r:.1f}x slower"
    else:          return "     equal"

def print_table(rows, headers):
    col_w = [max(len(h), max(len(str(r[i])) for r in rows)) for i, h in enumerate(headers)]
    sep   = "+-" + "-+-".join("-" * w for w in col_w) + "-+"
    def fmt_row(cells):
        return "| " + " | ".join(str(c).ljust(w) for c, w in zip(cells, col_w)) + " |"
    print(sep)
    print(fmt_row(headers))
    print(sep)
    for r in rows: print(fmt_row(r))
    print(sep)

# ---- main ----

def main():
    print("building myr with -o:speed ...")
    subprocess.run([ODIN, "build", ".", "-o:speed", "-out:myr-bench"], check=True, capture_output=True)
    print("done\n")

    # --- for-loop comparison (Myr only) ---
    print("=== for loop variants (Myr only) ===\n")
    rows = []
    for name, myr_file, expected in MYR_ONLY + [("loop/while", "benchmarks/loop.myr", "499999500000")]:
        ms, kib, out = measure(["./myr-bench", myr_file])
        ok = "✓" if out == expected else "✗"
        rows.append([name, fmt_ms(ms), fmt_mem(kib), ok])
    print_table(rows, ["variant", "time", "mem", ""])
    print()

    # --- cross-runtime comparison ---
    print("=== cross-runtime comparison ===\n")
    print("  collecting results (3 runs each × 3 runtimes × 6 benchmarks) ...")

    results = {}
    for name, myr_file, _ in CROSS:
        myr_ms,  myr_kib,  _ = measure(["./myr-bench", myr_file])
        py_ms,   py_kib,   _ = run_script([PY],   PYTHON[name],  ".py")
        node_ms, node_kib, _ = run_script([NODE], NODE_JS[name], ".js")
        results[name] = (myr_ms, myr_kib, py_ms, py_kib, node_ms, node_kib)

    print()
    print("  performance — time in ms, lower is better\n")
    rows = []
    for name, (myr_ms, _, py_ms, _, nd_ms, _) in results.items():
        rows.append([name,
            fmt_ms(myr_ms), fmt_ms(py_ms),  fmt_ms(nd_ms),
            cmp_label(myr_ms, py_ms), cmp_label(myr_ms, nd_ms)])
    print_table(rows, ["benchmark", "myr", "python", "node", "vs python", "vs node"])

    print()
    print("  memory — peak RSS, lower is better\n")
    rows = []
    for name, (_, myr_kib, _, py_kib, _, nd_kib) in results.items():
        rows.append([name,
            fmt_mem(myr_kib), fmt_mem(py_kib),  fmt_mem(nd_kib),
            cmp_label(myr_kib, py_kib), cmp_label(myr_kib, nd_kib)])
    print_table(rows, ["benchmark", "myr", "python", "node", "vs python", "vs node"])

    print()
    print("note: myr numbers include parse+compile time; python/node are pure execution.")
    print("      'calls' benchmark resolution is <1ms — ratio is noise, not signal.")

    subprocess.run(["rm", "-f", "myr-bench"])

if __name__ == "__main__":
    main()
