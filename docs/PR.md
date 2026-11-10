# Opcache: share identical opcode arrays between cached scripts

## Problem

Shared hosts commonly run many copies of the same application from a single
PHP-FPM master: CMS cores, plugins and `vendor/` directories. OPcache keys
scripts by path, so every copy is persisted separately, even though most
functions compile to exactly the same opcodes.

On one production host, 80 WordPress sites on PHP 8.4 use about **3 GB** of
OPcache memory. About 80% of their files are identical.

Sharing at the file level, either by keying on a hash of the source file or by
pointing duplicates at one entry, cannot work. A compiled script contains its
path in several places:

- `op_array->filename`;
- `__FILE__` and `__DIR__`, which are compile-time literals;
- runtime definition keys;
- class entries.

This was already discussed for APC in [bug #63689] and on internals in
[2016][externals].

[bug #63689]: https://bugs.php.net/bug.php?id=63689
[externals]: https://externals.io/message/93024

## Proposal

Add `opcache.enable_dedup` (`INI_SYSTEM`, default `0`). When it is enabled, the
**opcodes and literals of each op_array** are looked up by content before being
copied to SHM. If an equivalent block was persisted before, the new op_array
points to it and no copy is made. Everything else stays per op_array:

- filename, line ranges, scope and prototype;
- vars, arg_info, live ranges, try/catch table and static variables.

`__FILE__`, `__DIR__`, stack traces, error messages and Reflection are
therefore unchanged. Blocks that depend on the path simply differ, so they are
not shared.

Because the unit of sharing is the function and not the file, this also covers
identical code in otherwise different files. Examples are the same library
vendored by several plugins, or unchanged functions after a file is updated.

### Correctness

- **Key.** The key is a position-independent serialization of the block:
  - opline-relative constant operands are converted to literal indexes;
  - `UNUSED` operands the VM does not read (per `zend_get_opcode_flags()`)
    are zeroed, because PHP 8.0 leaves stale data in some of them;
  - literals are serialized by value, recursively for arrays;
  - op_arrays with other literal types (constant ASTs, `IS_PTR`) are never
    shared.
- **Full comparison.** A hash match is always confirmed by comparing the full
  serializations. A hash collision, accidental or crafted, can never cause two
  blocks to be shared.
- **Exact sizes.** `zend_accel_script_persist_calc()` and
  `zend_accel_script_persist()` must agree on the size. The calc pass records
  its decision for each op_array: the shared block, or the hash of the block
  to register. The persist pass applies these decisions instead of looking
  blocks up again. Both passes run under the same SHM lock and entries are
  never removed before a restart, so a block found by the calc pass is still
  there. Each block is therefore serialized once, in the calc pass.
- **Literal values.** When a block is shared, the literal zvals and the
  opcodes are replaced by the shared ones, but the literal values are still
  persisted with `zend_persist_zval()`. Values used by several op_arrays of
  the script (for example constant arrays inlined by the optimizer) are
  therefore released or translated through the xlat table exactly as today.
  Compiled blocks are only read by the calc pass, which frees nothing. The
  persist pass, which releases compiled values as it copies them, only reads
  blocks already in SHM.
- **Inherited methods.** xlat entries are registered for the replaced
  opcodes and literals, so methods sharing the op_array within the script
  resolve to the shared block as they do today.
- **No refcount.** Nothing in OPcache SHM is freed before a restart, so shared
  blocks need no refcount. The table is cleared on restart.
- **Handlers.** `SEND_VAL`, `SEND_VAL_EX` and `QM_ASSIGN` handlers on
  constant operands are re-selected by `zend_persist_op_array_ex()`. They are
  compared through the fields they are derived from. All other handlers are
  compared as they are.

### What is not shared

A function is path-dependent, and therefore not shared, when its opcodes
contain the file path:

- `__FILE__` and `__DIR__`, which are folded at compile time, including in
  default parameter values;
- `self::CONST` when the class constant is built from `__DIR__`, because the
  optimizer inlines the value into the method;
- runtime definition keys of delayed class declarations, which contain the
  path (file bodies only).

User constants are not a problem. OPcache compiles with
`ZEND_COMPILE_NO_CONSTANT_SUBSTITUTION`, so with `const ROOT = __DIR__ . '/x';`
or `define()` only the file body that declares the constant holds the path.
Every function that uses `ROOT` fetches it by name at run time and stays
shareable.

Measured on a second, identical WordPress site with WooCommerce, Yoast SEO,
Contact Form 7 and Elementor, path-dependent code is 6.5% of opcodes and
literals. It is made of 7,505 file bodies and 367 functions. 92.3% is shared.

### Security

- **No new lookup path.** Scripts are still looked up by path.
  `opcache.validate_permission` and `opcache.validate_root` are unaffected.
  The table is only consulted while persisting, so a shared block cannot be
  reached through its hash.
- **No hash-only matching** (see above). The key is also salted with
  random bytes drawn when the SHM is initialized, so a tenant cannot
  prepare blocks that fill the probe sequence of a key and keep other
  tenants' blocks from being shared.
- **Bounded work.** Lookups and insertions inspect at most 16 slots, so many
  colliding blocks cannot make compilation slow under the SHM lock.
- **Immutable blocks.** A block is never modified or freed before a
  restart. A tenant editing or invalidating its own file gets a new block;
  the others keep executing the old one.
- **Native attacker.** The SHM is mapped read-write in every worker (unless
  `opcache.protect_memory`), so a worker running native code can already
  rewrite any cached script. The table adds no capability.
- **Multi-tenant checks.** Two sites under two Unix users and one FPM
  master, with dedup off and on: cross edits never leak, reading the other
  site's file through a symlink or its path is refused before and after it
  is cached (`validate_permission`), and `opcache_get_status()`,
  `opcache_invalidate()` and `opcache_reset()` from a site are refused with
  `opcache.restrict_api` (without it they are allowed, as they are today).
  The dedup runs are identical to the native ones.
- **Side channel.** As with the existing OPcache statistics, a tenant could
  infer that another tenant runs the same code by watching `saved_memory` or
  free memory. `opcache.restrict_api` closes this.

### Disabled when

- **The JIT is enabled.** The JIT patches the opline handlers of the
  op_arrays it compiles.
- **`opcache.file_cache` is set.** The file cache serializes pointers
  relative to the script's own memory block.
- **On 32-bit builds.** `ZEND_USE_ABS_CONST_ADDR` / `ZEND_USE_ABS_JMP_ADDR`.

In these cases a warning is logged and the behavior is unchanged. With the
directive off, no memory is allocated and no code path changes.

## Changes

- New `ext/opcache/zend_accelerator_dedup.{c,h}`.
- Hooks, about 40 lines in total:
  - `zend_persist_calc.c`, `zend_persist.c`: size accounting, sharing and
    registration;
  - `ZendAccelerator.c`: table allocation next to `ZCSG(hash)`, reset on
    restart;
  - `zend_accelerator_module.c`: INI entry, `opcache_get_configuration()`,
    and the new `"dedup"` key of `opcache_get_status()`.
- `php.ini-development`, `php.ini-production`, `UPGRADING`.
- 15 tests in `ext/opcache/tests/dedup/`: two docroots with 20 one-detail variants, key collisions that must not be shared, hostile code (deep literals, huge functions, full table), and a co-tenant that cannot mutate a shared block.

## Results

Load test on PHP 8.4 (release build, JIT off):

- **Setup.** 80 fully installed WordPress sites, with WooCommerce, Yoast SEO,
  Contact Form 7 and Elementor active and one MariaDB database each. One Unix
  user and one `ondemand` pool per site, all under one FPM master, with
  `opcache.validate_permission=1`.
- **Load.** nginx and h2load, 32 connections, 500,000 requests per run,
  replaying the same sequence (home, posts, products, shop, REST, search).

| | dedup=0 | dedup=1 | |
|---|---:|---:|---:|
| OPcache memory at the end | 6,406 MB | 3,428 MB | -46.5% |
| PHP-FPM memory, peak PSS | 6,711 MB | 5,466 MB | -18.6% |
| PHP-FPM CPU per request | 170.3 ms | 171.7 ms | +0.8% |
| Throughput | 52.2 req/s | 51.7 req/s | |
| Non-200 responses, crashed workers | 0 | 0 | |

- **CPU.** In steady state the CPU per request is the same within the run's
  own variation (167 to 173 ms in 30-minute slices for both runs).
- **Cold start.** The serialization cost shows during the first minutes,
  while everything is compiled. In this PR each block is serialized once (the
  calc pass decision is reused), which brings compilation from +9.0% to
  +2.2% CPU compared with no dedup.

Compile-only A/B benchmark on PHP 8.4 (release build, JIT off):

- **Setup.** N WordPress sites (core, WooCommerce, Yoast SEO, Contact Form
  7, Elementor; about 9,000 PHP files each). Each site has its own Unix user
  and its own pool, all under one FPM master, with
  `opcache.validate_permission=1`.
- **Mix.** 80% of the sites run the current stack, 20% an older one.
- **Load.** Every file is compiled through its own pool, 8 pools in
  parallel.

| Sites | dedup=0 | dedup=1 | Memory | Compile CPU |
|---:|---:|---:|---:|---:|
| 10 | 1,818 MB | 1,167 MB | -35.8% | -5.6% |
| 30 | 4,857 MB | 2,667 MB | -45.1% | -0.5% |

- **Marginal cost.** An additional site costs about 75 MB instead of
  152 MB.
- **Ceiling.** The remaining duplicated memory is mostly class structures
  (class entries, method op_arrays, method and property tables), which embed
  the filename and per-script scope pointers.
- **Correctness.** Same number of cached scripts in both runs, no OPcache
  error, and identical output of a functional check run on every site.

Production (PHP 8.4, enabled on 2026-10-29):

- **Setup.** A shared host with 74 FPM pools over several PHP versions, one
  master per version. The 8.4 master serves 52 pools, one Unix user each,
  with `opcache.validate_permission=1` and `opcache.memory_consumption=5G`.
- **Memory.** The resident part of the 8.4 SHM segment went from 4.3-4.5 GB
  to 2.5 GB with the same configuration and sites (-43%). From
  `opcache_get_status()`, 3.1 GB are used and 2.3 GB were saved: the same
  content would need 5.4 GB without dedup, more than the configured size.
- **Sharing.** 82.5% of the persisted op_arrays (1.9 million out of 2.3
  million) point to an existing block. The table holds 404,109 entries for
  224,514 cached scripts (1.8 unique blocks per script).
- **Stability.** No worker died on SIGSEGV, SIGBUS or SIGABRT in 11 days,
  on any version. Two out-of-memory episodes of the host were caused by the
  private memory of the workers (pool sizing); the OPcache segment stayed
  between 2.6 and 2.9 GB during both.
- **Operations.** With memory freed, `opcache.max_accelerated_files` and
  `opcache.interned_strings_buffer` became the limits first (key table full
  at 262,237 entries with the memory half empty). They have to be sized
  together with the memory.

Tests (8.4):

- the new tests pass;
- Zend/tests, tests/ and ext/opcache/tests show no difference with and
  without `opcache.enable_dedup=1` (`opcache.protect_memory=1`);
- valgrind reports no error in the new tests.

## Open questions

- Should the table size be configurable? It is currently 4 slots per
  `opcache.max_accelerated_files`, at 32 bytes per slot, capped at 2^20 slots
  (786,432 usable entries, 32 MB). In production it is 51% full; on a
  smaller development host (`max_accelerated_files=65536`) it reached 93%.
  A full table is harmless (new blocks are no longer shared), but sizing it
  from the memory rather than from the number of scripts may fit better.
- Possible follow-ups: share `arg_info` and `vars`, and eventually immutable
  class data, which are the next largest duplicated structures.
