package typechecker

MAX_TYPE_ERRORS :: 1 << 8

// TypeId sentinels and primitive constants.
// Indices 0..NUM_PRIMITIVES-1 are pre-registered by new_type_checker; order must not change.
UNKNOWN_TYPE   :: TypeId(max(u16))
VOID_TYPE      :: TypeId(0)
BOOL_TYPE      :: TypeId(1)
INT_TYPE       :: TypeId(2)
FLOAT_TYPE     :: TypeId(3)
STRING_TYPE    :: TypeId(4)
NIL_TYPE       :: TypeId(5)
NUM_PRIMITIVES :: 6

