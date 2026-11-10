# Analysis: initial proposal vs implementation

Starting point: in production, 80 PHP 8.4 sites use about 3 GB of OPcache
although about 80 % of their files are identical. The idea is to deduplicate
by content hash rather than by path.

This document compares the initial proposal (a separate `ext/opcache-dedup`
extension) with prior art and with the OPcache code. It explains the choices
made in this repository.

## 1. Prior art

| Topic | Finding | Source |
|---|---|---|
| Requested before? | APC, bug #63689 "Caching by hash not path" (2012), same use case (identical WordPress installs), closed as *Won't fix*. Rasmus Lerdorf replied that pointing duplicates to a first entry amounts to "implementing symlinks in APC". | https://bugs.php.net/bug.php?id=63689 |
| Proposed before? | 2016 internals thread, "Shared Opcode Cache": storage keyed by the file's SHA-512, abandoned. The objection was about sharing SHM between unrelated processes, which is not the case for the pools of a single FPM master. | https://externals.io/message/93024 |
| Existing RFC or PR | None found (wiki.php.net, php-src, externals). | — |
| SHM scope under FPM | One SHM per FPM master, shared by all its pools. Deduplication only has an effect if the sites share a master. With one master per user, there is nothing to share. | https://bugs.php.net/bug.php?id=69090 |
| Isolation | `opcache.validate_permission` and `opcache.validate_root` exist since 7.0.14 (cross-pool leaks, CVE-2015-8994). | https://www.php.net/manual/en/opcache.configuration.php |
| `__FILE__` / `__DIR__` | Resolved **at compile time** into literals (`zend_try_ct_eval_magic_const()`). Two identical files at different paths therefore do not produce identical opcodes. | `Zend/zend_compile.c` |
| Strings | Strings are already deduplicated across scripts by the *interned strings* buffer. Still duplicated: opcode arrays, literals, `zend_op_array` structures and classes. | `ext/opcache/ZendAccelerator.c` |
| xxHash | Non-cryptographic. Collisions faster than brute force are known for XXH3 (xxHash #1127, 2026). Matching on the hash alone is not safe across tenants. | https://github.com/Cyan4973/xxHash/issues/1127 |
| PHP 8.5 | OPcache becomes mandatory and statically compiled (RFC *make_opcache_required*). The code must therefore live in `ext/opcache`, not in a separate extension. | https://wiki.php.net/rfc/make_opcache_required |
| Current workarounds | Symlinks or bind mounts of a common core (OPcache indexes the realpath), hardlinks, shared `opcache.file_cache` (dangerous: bug #80864, binary webshell), preloading (a single application per master). | see the links above |

Lifecycle as of 2026-10-19: 8.0 and 8.1 are end-of-life, 8.2 and 8.3 only
receive security fixes, 8.4 and 8.5 are actively maintained. Upstream, a
feature can only target `master` (8.7-dev). The 8.2 to 8.6 patches are
backports to be applied by users or by a distribution; 8.0 and 8.1, which are
end-of-life, were dropped on 2026-10-20.

## 2. Differences from the initial proposal

| Initial proposal | Problem | Choice made |
|---|---|---|
| Separate extension `ext/opcache-dedup` | OPcache provides no extension point on persistence. In 8.5 and later, it is also compiled in statically. | A patch to `ext/opcache`: one file, `zend_accelerator_dedup.c`, and about 40 lines of hooks. |
| Hash of the source **file**, path table plus opcode pool | A file's bytecode contains its path: `op_array->filename`, the `__FILE__`/`__DIR__` literals, runtime declaration keys, classes. A whole file is therefore never shareable as is. | Hash of each **compiled block** (opcodes and literals of a `zend_op_array`). Whatever depends on the path naturally differs and is not shared. The rest is shared, including between *different* files that contain identical functions (vendored libraries). |
| `__FILE__` injected from the path table at runtime | Impossible without modifying the compiler, since these are compile-time constants. | Unnecessary: each `op_array` keeps its `filename`, scope, `vars`, `arg_info`, live ranges and try/catch. Only opcodes and literals are shared. The `dedup_paths` and `dedup_vendored` tests check this. |
| `opcache.dedup_hash_algorithm = xxhash` | With the hash alone, an XXH3 collision forged by one tenant could make its code run in place of another tenant's. If the full block is compared, the choice of algorithm no longer matters for security, and an extra directive would add nothing. | No directive. The hash (`zend_hash_func`) only selects the slot. Every match is confirmed by a **full comparison** of the normalized form, so a collision can never cause sharing. The number of probes is bounded (16), which prevents a collision flood from degrading compilation. |
| UID/permission check before loading a block "by its hash" | Such loading does not exist: the pool is never addressed from outside. | Scripts are always looked up by path, with the native checks (`validate_permission`, `validate_root`). The pool is only used at persistence time. |
| "Strict atomic locks" | Unnecessary. | Lookup and insertion happen during persistence, which is already serialized by OPcache's SHM write lock. Readers only follow pointers, without any additional lock. |
| Kill switch `opcache.enable_dedup` | — | Kept (`PHP_INI_SYSTEM`, default 0). When it is 0, no table is allocated and behaviour is strictly native. It cannot vary per pool, since the SHM is shared by the master. |
| `make test TESTS=ext/opcache/tests/dedup/` | — | Kept. There are 15 phpt, plus the full Zend and opcache suites re-run with and without dedup (`make test-full`). |

## 3. How it works

1. **Calc pass** (`zend_persist_calc.c`): each `op_array` is serialized into
   an address-independent form.
   - Opline-relative constant operands become literal indexes.
   - `UNUSED` operands not read by the VM are zeroed: PHP 8.0 leaves
     leftovers in them.
   - Literals are serialized by value, arrays included.
   - This form is hashed and looked up in the SHM table. If it is found, its
     size is not reserved.
2. **Persist pass** (`zend_persist.c`): it applies as is the decisions
   recorded by the calc pass (block to share, or fingerprint of the block to
   register). The computed size is therefore exact, and each block is
   serialized only once.
   - On a match, the `op_array` points to the existing opcodes and literal
     zvals. Literal *values* are still persisted by `zend_persist_zval()`, as
     usual: a constant array shared with another `op_array` of the script is
     thus freed or translated through the xlat table exactly as today. The
     xlat entries of the opcodes are registered for methods inherited within
     the same script.
   - The persist pass never re-reads a compiled block, since it frees values
     as it copies them. Re-reading a compiled block at this stage caused a
     use-after-free in the first version (see [RESULTS.md](RESULTS.md)).
   - Otherwise, the block is copied normally and then registered in the
     table.
3. **Restart** (OOM, `opcache_reset()`, hash table full): the table is
   cleared together with the SHM. OPcache frees nothing before a restart, so
   a shared block needs no reference count.

Automatically disabled, with a warning in the OPcache log:

- **with the JIT**, which rewrites the oplines' handlers;
- **with `opcache.file_cache`**, whose serializer cannot represent a pointer
  into another script;
- **on 32-bit builds**, where operand addresses are absolute.

## 4. Limitations and possible follow-ups

- Only opcodes and literals are shared, i.e. most of the per-function volume.
  Still duplicated: `zend_op_array` and `zend_class_entry` structures,
  property and constant tables, `arg_info`, `vars`, and method tables. Going
  further would require sharing those too (step 2).
- Side channel: a tenant can infer whether another tenant runs the same code
  by observing `opcache_get_status()['dedup']` or free memory. The risk is
  the same as with the existing OPcache statistics, and `opcache.restrict_api`
  neutralizes it.
- The JIT is excluded. Making it compatible would require the JIT to work on
  a private copy of the oplines.
- Saved memory is accounted to the first owner's entry. If that script is
  invalidated, its size is counted as *wasted* although the block is still in
  use. This is harmless, since nothing is freed before a restart.

## 5. Code blocked by the path: measurement (2026-10-20)

**Method**:

- temporary instrumentation of the calc pass, not part of this repository;
- two identical sites (WordPress, WooCommerce, Yoast, CF7, Elementor)
  compiled one after the other through their FPM pools;
- everything not shared on the second site is classified by cause.

| Second site (69,277 op_arrays, 83.7 MB of opcodes and literals) | op_arrays | Bytes |
|---|---:|---:|
| Shared | 87.2 % | **92.3 %** (77.3 MB) |
| Blocked by a literal containing the path | 11.4 % | **6.5 %** (5.5 MB) |
| Actually different | 1.1 % | 0.7 % |
| Constant expressions (`IS_CONSTANT_AST`), ineligible | 0.3 % | 0.5 % |

Breakdown of the 5.5 MB blocked by the path:

| Cause | Bytes | Where |
|---|---:|---|
| `include`/`require __DIR__ . '/…'` (constant folded by the compiler) | 2.1 MB | 295 file bodies: `wp-settings.php`, `wp-admin` pages, plugin bootstraps |
| `__FILE__`/`__DIR__` in an expression or argument (`plugin_basename(__FILE__)`, `$dir = __DIR__ …`) | 1.7 MB | a few hundred file bodies, 367 functions or methods |
| Runtime declaration keys (`DECLARE_CLASS_DELAYED`, anonymous classes, `const`): `"\0name" . path . ":line$n"` | 1.6 MB | 7,212 class file bodies, 128 bytes median |

**Orders of magnitude**:

- 7,505 of the 7,872 blocked op_arrays are file bodies, not functions;
- opcodes and literals are about 58 % of a site's cost, so code blocked by
  the path accounts for about **3.8 % of per-site memory**;
- lifting it entirely would move the load-test gain from about -46.5 % to
  about -49 %;
- class structures (about 31 % of per-site cost) are a much bigger lever.

**Possible directions**, by increasing effort:

1. **Declaration keys without the path** (opcache only, about 1.8 % of
   opcodes)
   - At persistence time, replace the path with a fingerprint of the file's
     content.
   - Two identical files loaded in the same request declare the same class,
     which is a fatal error today anyway, so the uniqueness that matters is
     preserved.
2. **`__FILE__`/`__DIR__` resolved at runtime** (about 4.6 % of opcodes)
   - This requires a Zend change: a compiler option, set by OPcache when
     dedup is active, compiles these constants into a read of
     `EX(func)->op_array.filename`.
   - It needs a new opcode, or an AST node evaluated at runtime for constant
     expressions.
   - The cost is one runtime concatenation per `include __DIR__ . …`,
     negligible.
   - This belongs in an RFC and a discussion with the engine maintainers, not
     in this patch.
