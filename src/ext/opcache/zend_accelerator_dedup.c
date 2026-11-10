/*
   +----------------------------------------------------------------------+
   | Zend OPcache                                                         |
   +----------------------------------------------------------------------+
   | Copyright © The PHP Group and Contributors.                          |
   +----------------------------------------------------------------------+
   | This source file is subject to the Modified BSD License that is      |
   | bundled with this package in the file LICENSE, and is available      |
   | through the World Wide Web at <https://www.php.net/license/>.        |
   |                                                                      |
   | SPDX-License-Identifier: BSD-3-Clause                                |
   +----------------------------------------------------------------------+
*/

/*
 * Security notes (multi-tenant hosting: one FPM master, one pool and one
 * Unix user per site). Each decision below answers a reviewed attack
 * surface; the full review, with the tests that verify each point, is kept
 * in docs/SECURITY.md of the patch's repository.
 *
 * 1. Sharing never relies on the key alone. zend_hash_func() is not
 *    collision resistant, so a key match is always followed by a full
 *    comparison of the two serialized blocks (zend_accel_dedup_entry_equals).
 *    Two blocks share memory only if they are byte-for-byte the same
 *    opcodes and literals, in which case they are interchangeable by
 *    construction. A collision can therefore prevent a sharing, never
 *    cause one.
 * 2. The key is salted (table->salt, random bytes drawn when the SHM is
 *    initialized). Without it, a tenant could prepare blocks that fill the
 *    probe sequence of a key and keep other tenants' identical code from
 *    being shared (a denial of the optimization, not of service).
 * 3. The table is only consulted while a script is persisted, i.e. right
 *    after the tenant compiled it from a file it could open. Lookups by
 *    path, opcache.validate_permission and opcache.validate_root are
 *    untouched, and nothing lets a request ask for a block by key.
 * 4. Blocks are immutable and are never freed before a restart, which
 *    clears the table together with the SHM (zend_accel_dedup_reset). A
 *    tenant editing or invalidating its own file gets a new block; the
 *    others keep executing the old one. No refcount is needed.
 * 5. Everything that identifies a tenant stays per op_array: filename,
 *    scope, variable names, arg_info, static variables, try/catch and
 *    live ranges, runtime definition keys (which embed the path). Only
 *    opcodes and literal zvals are shared, and every reference they make
 *    outside the block is either compared (operands, jump offsets,
 *    handlers) or resolved per op_array or per request (CVs, cache slots,
 *    static variable offsets, closure indexes, self/parent).
 * 6. Compiled code is tenant-controlled, so the serializer is bounded:
 *    array literals nested deeper than ZEND_ACCEL_DEDUP_MAX_DEPTH make the
 *    op_array ineligible instead of recursing, lookups and insertions
 *    probe at most ZEND_ACCEL_DEDUP_MAX_PROBES slots, a full table only
 *    stops registrations, and the persist pass never reads a compiled
 *    block again (the calc pass records its decisions).
 * 7. What this does not change: the SHM is mapped read-write in every
 *    worker. A worker that runs native code can already rewrite any cached
 *    script, with or without this feature; sharing only makes one block
 *    serve several tenants. opcache.restrict_api is required in shared
 *    hosting with or without it (opcache_get_status(true),
 *    opcache_invalidate() and opcache_reset() are otherwise available to
 *    every tenant), and the "dedup" counters it exposes are a side channel
 *    it closes. Memory growth observable from outside (e.g. /proc/meminfo)
 *    can still reveal that another tenant runs the same code, as with any
 *    memory deduplication.
 */

#include "ZendAccelerator.h"
#include "zend_API.h"
#include "zend_accelerator_dedup.h"
#include "zend_shared_alloc.h"
#include "zend_smart_str.h"
#include "zend_vm.h"

#ifdef HAVE_JIT
# include "jit/zend_jit.h"
#endif
#include "php_version.h"
#if PHP_VERSION_ID >= 80200
# include "ext/random/php_random.h"
#else
# include "ext/standard/php_random.h"
#endif

/* Bound on the number of slots inspected per lookup or insertion. Keeps the
 * work done under the SHM lock constant even if many blocks share a hash. */
#define ZEND_ACCEL_DEDUP_MAX_PROBES 16

/* Nesting of array literals beyond which an op_array is not shared: the
 * serialization recurses, and compiled code is tenant-controlled. */
#define ZEND_ACCEL_DEDUP_MAX_DEPTH  32

#define ZEND_ACCEL_DEDUP_MIN_SLOTS  1024
#define ZEND_ACCEL_DEDUP_MAX_SLOTS  (1 << 20)

struct _zend_accel_dedup_entry {
	zend_ulong  hash;         /* 0 marks a free slot; a real key is mapped away from 0 */
	zend_op    *opcodes;
	zval       *literals;
	uint32_t    last;
	uint32_t    last_literal;
};

struct _zend_accel_dedup_table {
	zend_ulong             salt;        /* random, so that key collisions cannot be prepared */
	uint32_t               mask;
	uint32_t               num_entries;
	uint32_t               max_entries;
	zend_ulong             hits;
	zend_ulong             misses;
	zend_ulong             saved_memory;
	zend_accel_dedup_entry slots[1];
};

/* Normalized, position independent representation of an opline. */
typedef struct _zend_accel_dedup_op {
	const void *handler;
	uint32_t    op1;
	uint32_t    op2;
	uint32_t    result;
	uint32_t    extended_value;
	uint32_t    lineno;
	uint8_t     opcode;
	uint8_t     op1_type;
	uint8_t     op2_type;
	uint8_t     result_type;
} zend_accel_dedup_op;

/* Per-process state of the script being persisted. The persist size computed
 * by zend_accel_script_persist_calc() must match exactly what
 * zend_accel_script_persist() writes, so the persist pass applies the
 * decisions taken by the calc pass instead of looking blocks up again. Both
 * passes run under the SHM write lock, and entries are never removed before a
 * restart, so a block found by the calc pass is still there.
 *
 * decisions maps the compiled opcodes of each op_array considered by the calc
 * pass to the shared entry to use (IS_PTR) or, when there is none, to the
 * hash of the block (IS_LONG), so that it can be registered without being
 * serialized again. */
static struct {
	bool       calc;
	bool       calc_done;
	bool       persist;
	bool       has_decisions;
	HashTable  decisions;
	zval      *pending;     /* decision of the op_array being persisted */
} dedup_ctx;

#if ZEND_ACCEL_DEDUP_SUPPORTED

static void zend_accel_dedup_append_string(smart_str *buf, zend_string *str)
{
	size_t len = ZSTR_LEN(str);

	smart_str_appendl(buf, (const char *) &len, sizeof(len));
	smart_str_appendl(buf, ZSTR_VAL(str), len);
}

static bool zend_accel_dedup_append_zval(smart_str *buf, zval *zv, uint32_t depth)
{
	smart_str_appendc(buf, (char) Z_TYPE_P(zv));

	switch (Z_TYPE_P(zv)) {
		case IS_UNDEF:
		case IS_NULL:
		case IS_FALSE:
		case IS_TRUE:
			return true;
		case IS_LONG:
			smart_str_appendl(buf, (const char *) &Z_LVAL_P(zv), sizeof(zend_long));
			return true;
		case IS_DOUBLE:
			/* Bitwise, so that 0.0 and -0.0 are kept apart. */
			smart_str_appendl(buf, (const char *) &Z_DVAL_P(zv), sizeof(double));
			return true;
		case IS_STRING:
			zend_accel_dedup_append_string(buf, Z_STR_P(zv));
			return true;
		case IS_ARRAY: {
			HashTable *ht = Z_ARRVAL_P(zv);
			uint32_t num_elements = zend_hash_num_elements(ht);
			zend_ulong index;
			zend_string *key;
			zval *val;

			if (depth >= ZEND_ACCEL_DEDUP_MAX_DEPTH) {
				return false;
			}
			smart_str_appendl(buf, (const char *) &num_elements, sizeof(num_elements));
			ZEND_HASH_FOREACH_KEY_VAL(ht, index, key, val) {
				if (key) {
					smart_str_appendc(buf, 's');
					zend_accel_dedup_append_string(buf, key);
				} else {
					smart_str_appendc(buf, 'i');
					smart_str_appendl(buf, (const char *) &index, sizeof(index));
				}
				if (!zend_accel_dedup_append_zval(buf, val, depth + 1)) {
					return false;
				}
			} ZEND_HASH_FOREACH_END();
			return true;
		}
		default:
			/* Constant expressions, attribute pointers, etc. are not
			 * compared; the op_array is simply not shared. */
			return false;
	}
}

static zend_always_inline uint32_t zend_accel_dedup_operand(const zend_op *opline, znode_op node, uint8_t type, uint32_t flags, const zval *literals)
{
	if (type == IS_CONST) {
		/* Opline-relative offset to literal index */
		return (uint32_t) (RT_CONSTANT(opline, node) - literals);
	}
	if (type == IS_UNUSED) {
		switch (flags & ZEND_VM_OP_MASK) {
			case 0:
			case ZEND_VM_OP_THIS:
			case ZEND_VM_OP_NEXT:
				/* Not read by the VM, and possibly left uninitialized by
				 * the compiler. */
				return 0;
		}
	}
	/* Everything else (CV/TMP/VAR offsets, jump offsets, numbers) is
	 * already independent of the block's address. */
	return node.num;
}

/* Serializes opcodes and literals into a representation that is identical
 * for the compiled block and for its persisted copy, and that determines
 * execution completely: two blocks with the same representation are
 * interchangeable.
 *
 * Compiled blocks are only serialized by the calc pass, which frees nothing.
 * The persist pass releases compiled values as it copies them (possibly
 * values shared by several op_arrays), so it must never read a compiled
 * block: it only serializes blocks that are already in SHM. */
static bool zend_accel_dedup_normalize(smart_str *buf, const zend_op *opcodes, uint32_t last, zval *literals, uint32_t last_literal)
{
	const zend_op *opline = opcodes;
	const zend_op *end = opcodes + last;
	uint32_t i;

	smart_str_appendl(buf, (const char *) &ZCSG(dedup)->salt, sizeof(zend_ulong));
	smart_str_appendl(buf, (const char *) &last, sizeof(last));
	smart_str_appendl(buf, (const char *) &last_literal, sizeof(last_literal));

	for (; opline < end; opline++) {
		uint32_t flags = zend_get_opcode_flags(opline->opcode);
		zend_accel_dedup_op op;

		memset(&op, 0, sizeof(op));
		op.handler = opline->handler;
		op.op1 = zend_accel_dedup_operand(opline, opline->op1, opline->op1_type, ZEND_VM_OP1_FLAGS(flags), literals);
		op.op2 = zend_accel_dedup_operand(opline, opline->op2, opline->op2_type, ZEND_VM_OP2_FLAGS(flags), literals);
		op.result = opline->result.num;
		op.extended_value = opline->extended_value;
		op.lineno = opline->lineno;
		op.opcode = opline->opcode;
		op.op1_type = opline->op1_type;
		op.op2_type = opline->op2_type;
		op.result_type = opline->result_type;

		if (opline->op1_type == IS_CONST
		 && (opline->opcode == ZEND_SEND_VAL
		  || opline->opcode == ZEND_SEND_VAL_EX
		  || opline->opcode == ZEND_QM_ASSIGN)) {
			/* zend_persist_op_array_ex() re-selects these handlers, purely
			 * from the fields compared above. */
			op.handler = NULL;
		}

		smart_str_appendl(buf, (const char *) &op, sizeof(op));
	}

	for (i = 0; i < last_literal; i++) {
		uint32_t extra = Z_EXTRA(literals[i]);

		smart_str_appendl(buf, (const char *) &extra, sizeof(extra));
		if (!zend_accel_dedup_append_zval(buf, &literals[i], 0)) {
			return false;
		}
	}

	smart_str_0(buf);
	return true;
}

static bool zend_accel_dedup_entry_equals(const zend_accel_dedup_entry *entry, const smart_str *buf)
{
	smart_str other = {0};
	bool equals;

	equals = zend_accel_dedup_normalize(&other, entry->opcodes, entry->last, entry->literals, entry->last_literal)
		&& ZSTR_LEN(other.s) == ZSTR_LEN(buf->s)
		&& memcmp(ZSTR_VAL(other.s), ZSTR_VAL(buf->s), ZSTR_LEN(buf->s)) == 0;
	smart_str_free(&other);

	return equals;
}

/* Returns the entry equal to buf, or NULL */
static zend_accel_dedup_entry *zend_accel_dedup_find(const smart_str *buf, zend_ulong hash)
{
	zend_accel_dedup_table *table = ZCSG(dedup);
	uint32_t slot = (uint32_t) hash & table->mask;
	uint32_t probes;

	for (probes = 0; probes < ZEND_ACCEL_DEDUP_MAX_PROBES; probes++) {
		zend_accel_dedup_entry *entry = &table->slots[slot];

		if (!entry->hash) {
			break;
		}
		if (entry->hash == hash && zend_accel_dedup_entry_equals(entry, buf)) {
			return entry;
		}
		slot = (slot + 1) & table->mask;
	}

	return NULL;
}

static zend_always_inline bool zend_accel_dedup_eligible(const zend_op_array *op_array)
{
	return op_array->last > 0 && !zend_accel_in_shm(op_array->opcodes);
}

static zend_always_inline size_t zend_accel_dedup_block_size(const zend_op_array *op_array)
{
	/* Must match ADD_SIZE() in zend_persist_op_array_calc_ex() */
	return ZEND_ALIGNED_SIZE(sizeof(zval) * op_array->last_literal)
		+ ZEND_ALIGNED_SIZE(sizeof(zend_op) * op_array->last);
}

static zend_always_inline zend_ulong zend_accel_dedup_key(const zend_op_array *op_array)
{
	return (zend_ulong) (uintptr_t) op_array->opcodes;
}

static void zend_accel_dedup_forget_decisions(void)
{
	if (dedup_ctx.has_decisions) {
		zend_hash_destroy(&dedup_ctx.decisions);
		dedup_ctx.has_decisions = false;
	}
	dedup_ctx.pending = NULL;
}

#endif /* ZEND_ACCEL_DEDUP_SUPPORTED */

void zend_accel_dedup_init_shm(void)
{
	ZCSG(dedup) = NULL;

	if (!ZCG(accel_directives).enable_dedup) {
		return;
	}

#if !ZEND_ACCEL_DEDUP_SUPPORTED
	zend_accel_error(ACCEL_LOG_WARNING, "opcache.enable_dedup is not supported on this platform");
#else
	zend_accel_dedup_table *table;
	zend_ulong num_slots;

	if (ZCG(accel_directives).file_cache) {
		/* The file cache serializes scripts relative to their own memory
		 * block and cannot represent pointers into other scripts. */
		zend_accel_error(ACCEL_LOG_WARNING, "opcache.enable_dedup is ignored because opcache.file_cache is set, unset it to use deduplication");
		return;
	}
# ifdef HAVE_JIT
	if (JIT_G(enabled) && JIT_G(buffer_size)) {
		/* The JIT patches opline handlers of the op_array it compiles. With
		 * opcache.jit=off and a JIT buffer, it can still be turned on at run
		 * time (opcache.jit is INI_ALL), so that is not enough. */
		zend_accel_error(ACCEL_LOG_WARNING, "opcache.enable_dedup is ignored because the JIT is enabled, set opcache.jit=disable or opcache.jit_buffer_size=0");
		return;
	}
# endif

	/* Four slots per cacheable script; duplicates do not take a slot */
	num_slots = ZEND_ACCEL_DEDUP_MIN_SLOTS;
	while (num_slots < (zend_ulong) ZCG(accel_directives).max_accelerated_files * 4
	 && num_slots < ZEND_ACCEL_DEDUP_MAX_SLOTS) {
		num_slots <<= 1;
	}

	table = zend_shared_alloc(sizeof(zend_accel_dedup_table) + (num_slots - 1) * sizeof(zend_accel_dedup_entry));
	if (!table) {
		zend_accel_error(ACCEL_LOG_WARNING, "Insufficient shared memory for opcache.enable_dedup, deduplication disabled");
		return;
	}
	table->mask = (uint32_t) num_slots - 1;
	table->max_entries = (uint32_t) (num_slots / 4 * 3);
	/* zend_hash_func() is not collision resistant: without a secret salt, a
	 * tenant could prepare blocks that fill the probe sequence of a key and
	 * keep other tenants' blocks with that key from being shared. */
	if (php_random_bytes(&table->salt, sizeof(table->salt), false) != SUCCESS) {
		table->salt = (zend_ulong) (uintptr_t) table ^ (zend_ulong) time(NULL) ^ ((zend_ulong) getpid() << 32);
	}
	ZCSG(dedup) = table;
	zend_accel_dedup_reset();
#endif
}

void zend_accel_dedup_reset(void)
{
	zend_accel_dedup_table *table = ZCSG(dedup);

	if (!table) {
		return;
	}

	table->num_entries = 0;
	table->hits = 0;
	table->misses = 0;
	table->saved_memory = 0;
	memset(table->slots, 0, ((size_t) table->mask + 1) * sizeof(zend_accel_dedup_entry));
}

void zend_accel_dedup_calc_begin(bool for_shm)
{
#if ZEND_ACCEL_DEDUP_SUPPORTED
	/* Left over if the previous script could not be persisted */
	zend_accel_dedup_forget_decisions();

	dedup_ctx.calc = for_shm && ZCSG(dedup) != NULL;
	dedup_ctx.calc_done = false;
	dedup_ctx.persist = false;
	if (dedup_ctx.calc) {
		/* Persistent, so that a script that is never persisted (out of
		 * memory) does not show up as a request leak */
		zend_hash_init(&dedup_ctx.decisions, 64, NULL, NULL, 1);
		dedup_ctx.has_decisions = true;
	}
#endif
}

void zend_accel_dedup_calc_end(void)
{
	dedup_ctx.calc_done = dedup_ctx.calc;
	dedup_ctx.calc = false;
}

/* Returns true when the opcodes and literals of op_array will be shared, in
 * which case the caller must not account for the opcodes and the literal
 * zvals. The literal values are still persisted, see zend_accel_dedup_share(). */
bool zend_accel_dedup_calc_op_array(const zend_op_array *op_array)
{
#if ZEND_ACCEL_DEDUP_SUPPORTED
	zend_accel_dedup_entry *entry = NULL;
	smart_str buf = {0};
	zval decision;

	if (!dedup_ctx.calc || !zend_accel_dedup_eligible(op_array)) {
		return false;
	}

	/* Sized for the opcodes; literals are usually smaller */
	smart_str_alloc(&buf, op_array->last * sizeof(zend_accel_dedup_op) + 64, 0);
	if (zend_accel_dedup_normalize(&buf, op_array->opcodes, op_array->last, op_array->literals, op_array->last_literal)) {
		zend_ulong hash = zend_hash_func(ZSTR_VAL(buf.s), ZSTR_LEN(buf.s));

		/* hash == 0 marks a free slot; map it away so a real block is never
		 * mistaken for one (would only lose a sharing, never cause one) */
		if (UNEXPECTED(hash == 0)) {
			hash = 1;
		}

		entry = zend_accel_dedup_find(&buf, hash);
		if (entry) {
			ZVAL_PTR(&decision, entry);
		} else {
			ZVAL_LONG(&decision, (zend_long) hash);
		}
		zend_hash_index_update(&dedup_ctx.decisions, zend_accel_dedup_key(op_array), &decision);
	}
	smart_str_free(&buf);

	return entry != NULL;
#else
	return false;
#endif
}

void zend_accel_dedup_persist_begin(bool for_shm)
{
	/* Only valid right after the matching calc pass */
	dedup_ctx.persist = for_shm && dedup_ctx.calc_done;
	dedup_ctx.calc_done = false;
}

void zend_accel_dedup_persist_end(void)
{
#if ZEND_ACCEL_DEDUP_SUPPORTED
	zend_accel_dedup_forget_decisions();
#endif
	dedup_ctx.persist = false;
}

/* Called by zend_persist_op_array_ex() before the literals and opcodes are
 * copied. Returns the shared block to use instead, if any. */
zend_accel_dedup_entry *zend_accel_dedup_persist_find(const zend_op_array *op_array)
{
#if ZEND_ACCEL_DEDUP_SUPPORTED
	dedup_ctx.pending = NULL;
	if (dedup_ctx.persist) {
		dedup_ctx.pending = zend_hash_index_find(&dedup_ctx.decisions, zend_accel_dedup_key(op_array));
		if (dedup_ctx.pending && Z_TYPE_P(dedup_ctx.pending) == IS_PTR) {
			return Z_PTR_P(dedup_ctx.pending);
		}
	}
#endif
	return NULL;
}

/* Points op_array to the shared block and releases its compiled opcodes.
 * The values of its literals must have been persisted in place beforehand
 * (zend_persist_zval()), so that the compiled ones are released, or shared
 * with other op_arrays of the script, exactly as usual. */
void zend_accel_dedup_share(zend_op_array *op_array, const zend_accel_dedup_entry *entry)
{
#if ZEND_ACCEL_DEDUP_SUPPORTED
	/* Methods sharing this op_array (e.g. inherited within the script) are
	 * resolved through the xlat table, see zend_persist_op_array_ex(). */
	if (op_array->literals) {
		zend_shared_alloc_register_xlat_entry(op_array->literals, entry->literals);
	}
	zend_shared_alloc_register_xlat_entry(op_array->opcodes, entry->opcodes);

	/* Literals are allocated together with the opcodes by pass_two() */
	efree(op_array->opcodes);
	op_array->opcodes = entry->opcodes;
	op_array->literals = entry->literals;

	ZCSG(dedup)->hits++;
	ZCSG(dedup)->saved_memory += zend_accel_dedup_block_size(op_array);
#endif
}

/* Called by zend_persist_op_array_ex() once the literals and opcodes of
 * op_array have been copied to SHM, to make them available for sharing. */
void zend_accel_dedup_register_op_array(const zend_op_array *op_array)
{
#if ZEND_ACCEL_DEDUP_SUPPORTED
	zend_accel_dedup_table *table = ZCSG(dedup);
	zval *decision = dedup_ctx.pending;
	smart_str buf = {0};
	zend_ulong hash;
	uint32_t slot, probes;

	dedup_ctx.pending = NULL;
	if (!decision || Z_TYPE_P(decision) != IS_LONG) {
		return;
	}

	table->misses++;
	if (table->num_entries >= table->max_entries) {
		return;
	}

	/* The calc pass hashed the compiled block, which serializes exactly
	 * like this persisted copy */
	hash = (zend_ulong) Z_LVAL_P(decision);
	slot = (uint32_t) hash & table->mask;

	for (probes = 0; probes < ZEND_ACCEL_DEDUP_MAX_PROBES; probes++) {
		zend_accel_dedup_entry *entry = &table->slots[slot];

		if (!entry->hash) {
			entry->hash = hash;
			entry->opcodes = op_array->opcodes;
			entry->literals = op_array->literals;
			entry->last = op_array->last;
			entry->last_literal = op_array->last_literal;
			table->num_entries++;
			break;
		}
		if (entry->hash == hash) {
			/* Possibly the same block twice in one script: only then is
			 * this copy serialized again */
			if (!buf.s) {
				zend_accel_dedup_normalize(&buf, op_array->opcodes, op_array->last, op_array->literals, op_array->last_literal);
			}
			if (buf.s && zend_accel_dedup_entry_equals(entry, &buf)) {
				break;
			}
		}
		slot = (slot + 1) & table->mask;
	}

	smart_str_free(&buf);
#endif
}

void zend_accel_dedup_add_status(zval *status)
{
	zend_accel_dedup_table *table = ZCSG(dedup);
	zval dedup;

	array_init(&dedup);
	add_assoc_bool(&dedup, "enabled", table != NULL);
	if (table) {
		add_assoc_long(&dedup, "max_entries", table->max_entries);
		add_assoc_long(&dedup, "num_entries", table->num_entries);
		add_assoc_long(&dedup, "hits", table->hits);
		add_assoc_long(&dedup, "misses", table->misses);
		add_assoc_long(&dedup, "saved_memory", table->saved_memory);
	}
	add_assoc_zval(status, "dedup", &dedup);
}
