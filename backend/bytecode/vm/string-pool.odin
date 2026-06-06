package vm

import "core:strings"


StringPool :: struct {
	entries: map[string]string,
}

string_pool_new :: proc() -> StringPool {
	return StringPool{entries = make(map[string]string)}
}

string_pool_destroy :: proc(pool: ^StringPool) {
	for _, s in pool.entries {
		delete(s)
	}
	delete(pool.entries)
}

// Returns a canonical interned copy of s.
// Long strings (> MAX_INTERN_LEN) are cloned but not interned.
// Caller must not free the returned string — the pool owns it.
string_pool_intern :: proc(pool: ^StringPool, s: string) -> string {
	if len(s) > MAX_INTERN_LEN {
		return strings.clone(s)
	}
	if existing, ok := pool.entries[s]; ok {
		return existing
	}
	owned := strings.clone(s)
	pool.entries[owned] = owned
	return owned
}
