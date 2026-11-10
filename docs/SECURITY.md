# Security review: isolation between tenants

Review of 2026-10-20, written before the upstream proposal and revised the
same day after an external critical reading (section 8). It covers the patch
(`zend_accelerator_dedup.c` and its hooks) and the native OPcache
protections the use case relies on. Each property is checked by a test that
runs in both modes, `opcache.enable_dedup=0` (native baseline) and `=1`. The
design decisions are also documented in a comment at the top of
`zend_accelerator_dedup.c`, so that they stay attached to the code.

## 1. Threat model

Shared hosting: one PHP-FPM master, one pool and one Linux user per site. A
**tenant** controls the files in its docroot and the PHP code that runs
under its user. The starting point is a **compromised tenant** (hacked site,
malicious customer), not a hash collision. Two capability levels:

| Level | Capabilities | Goal examined |
|---|---|---|
| **PHP** | write files in its docroot, run arbitrary PHP under its user, call the `opcache_*` API, read `/proc` if `open_basedir` allows it | get code executed by a worker of another pool, read another tenant's code, configuration or data, deny service to others |
| **Native** | native code execution in a worker: memory bug in PHP or an extension, misconfigured FFI | same |

What the patch adds to the attack surface:

- a table in shared memory (key → block of opcodes and literals);
- `op_array`s of different tenants pointing to the **same** block;
- counters in `opcache_get_status()`.

Design invariants:

1. the table is consulted only **at persist time** of a script that the
   tenant has just compiled from a file it was able to open;
2. a block is shared only if its serialization is **strictly equal**
   (salted key, then full comparison);
3. blocks are **immutable** and never freed before a restart, which empties
   the table together with the SHM;
4. everything that depends on the tenant (`filename`, scope, variables,
   `arg_info`, static variables, try/catch, declaration keys) stays per
   `op_array`;
5. serialization is **bounded**: the compiled code is controlled by the
   tenant.

## 2. What holds both before and after: the native state

These points do not come from the patch. They apply to any multi-tenant
OPcache deployment under a single master, and the patch does not improve
them.

- The OPcache SHM is mapped **read-write in every worker**.
  `opcache.protect_memory` makes it read-only outside persistence, but that
  is a barrier against accidental writes or a limited write primitive, not
  against native code execution (which can call `mprotect` again). Its cost
  is measured in section 6.
- The **compiled literals** of every site live in this SHM: database
  passwords, `AUTH_*`/`*_SALT` keys from `wp-config.php`. A worker running
  native code reads all of them, with or without dedup.
- Without `opcache.restrict_api`, **any tenant** can call
  `opcache_get_status(true)` (paths of every script of every tenant),
  `opcache_invalidate()` on any path, and `opcache_reset()`. Tested (§5, V5).
- *Interned strings* are already shared between tenants.
- A tenant can exhaust `memory_consumption` and trigger restarts.

**Consequence**: the "one master, several users" model relies on the
absence of native execution in a worker. If that assumption is not
acceptable for a population of tenants, the answer is architectural
(section 7), not in this patch nor in native OPcache.

## 3. What the patch changes in this model

### 3.1 Target concentration (native attacker)

A shared block serves several tenants. A native attacker who corrupts the
`esc_html()` block changes the behaviour of every site sharing it, under
each site's identity, instead of a single one. Natively, the same attacker
has to corrupt one script per site; it has the capability to do so (it can
read the script table), but dedup saves it the work.

- **Verdict**: real, specific to dedup, but conditional on a capability
  (native code in a worker) that already grants everything. The blast
  radius is the variable to control: section 7.

### 3.2 Common failure mode (bug in the patch)

A bug in the persist pass writes into an area that every tenant executes.
The use-after-free found during the load test (workers dying with SIGSEGV,
pre-fix version) illustrates the class. In the final version, the persist
pass never reads back a compiled block, serialization is bounded (depth,
probes), SHM writes are limited to the fields of one table entry at a masked
index, and everything is covered by the tests in section 5.

- **Verdict**: real, specific to dedup, reduced by the final design and by
  the tests; the blast radius (section 7) also bounds it.
- Tools: ASan (ASLR disabled) on the dedup tests, the OPcache test suite and
  the compilation of two WordPress sites with dedup: 0 errors, and no leak
  attributable to the patch (see `RESULTS.md`). Limitation: neither Valgrind
  nor ASan instruments the inside of the SHM (OPcache's own allocator). They
  cover the heap and the stack, where serialization, decisions and buffers
  live. An overflow inside the SHM would only be caught by the behavioural
  tests.

### 3.3 Side channels

Sharing memory between trust domains is a known attack class (KSM between
VMs, page deduplication). What dedup reveals: **another tenant runs exactly
this code**. Oracles:

| Oracle | Reachable at PHP level? | Assessment |
|---|---|---|
| `dedup` counters in `opcache_get_status()` | yes without `restrict_api`, no with it | closed by `restrict_api` |
| shared memory growth (`/proc/meminfo` `Shmem`, cgroup) after compiling an exact copy of a file | yes if `/proc` is readable (`open_basedir` does not block it by default) | **real**. A shared file grows the SHM by about 40 % less than a new file (opcodes and literals are ~58 % of a script). Inside a container, `/proc/meminfo` shows the host or the container depending on lxcfs. What it reveals, the version of a plugin at a neighbour, is usually public already (versions in the HTML, `readme.txt`). Not closed. |
| persist time (avoided copy vs. comparison) | yes, noisy (microseconds within a compilation of milliseconds) | marginal |
| Flush+Reload on the shared code | **no**: requires `clflush`/`rdtsc`, hence native code; a native attacker already reads everything | not applicable at PHP level |

- **Verdict**: one real oracle at PHP level (memory growth), of low value,
  documented and accepted. It is the same trade-off as any memory
  deduplication; it has no native equivalent.

## 4. Vectors examined (PHP attacker)

### V1. Key collision

`zend_hash_func` is not collision-resistant. Key equality is never enough:
the candidate block is re-serialized and compared byte by byte. Two blocks
with the same key and different content occupy two entries.

- **Verdict**: impossible to get a different block shared. At worst, a
  collision prevents sharing.
- **Hardening**: the key is salted with 8 random bytes drawn at SHM
  initialization (`php_random_bytes`), so that a tenant cannot precompute
  blocks that fill the probe sequence of a key.
- **Test**: `dedup_hash_collision.phpt`.

### V2. Poisoning after sharing

A and B have identical code, B persists it, A shares it; A then modifies its
file, invalidates it, or clears the cache.

- The shared block is never modified in place: A's new version is a **new**
  block, used only by A. `opcache_invalidate()` and an mtime change mark A's
  **script** as stale, nothing else. `opcache_reset()` clears everything,
  table included, for everyone (native behaviour).
- **Verdict**: no edit or invalidation by one tenant changes another
  tenant's behaviour.
- **Test**: `isolation.sh` §1, cross edits in both directions, output
  identical to native; `dedup_hostile.phpt` (restart).

### V3. Context-dependent semantics in a shared block

| Reference in the opcodes | Where it points | Per `op_array`? |
|---|---|---|
| CV (`vars`), TMP/VAR | name array / frame | yes / per request |
| cache slots (`INIT_FCALL`, `FETCH_CLASS_CONSTANT`…) | `run_time_cache` | per request |
| static variable offset (`BIND_STATIC`) | `static_variables` | yes, same layout since same opcodes |
| closure index (`DECLARE_LAMBDA_FUNCTION`) | `dynamic_func_defs` | yes |
| `self` / `parent` / `static` | `scope`, frame | yes / per call |
| declaration keys (`DECLARE_CLASS_DELAYED`, functions, anonymous classes) | literals | contain the path: never shared |
| jumps, `switch`/`match` | relative, tables in the literals | compared |
| parameter and return types | `arg_info` | yes |
| try/catch, live ranges | tables derived from the opcodes | yes |
| VM handlers | compared (JIT excluded) | — |

- **Verdict**: every reference outside the block is either compared or
  resolved per `op_array` or per request. Two blocks with equal
  serialization are interchangeable.
- **Tests**: `dedup_variants.phpt`, `dedup_paths.phpt`,
  `dedup_vendored.phpt`, `probe.sh` (480 FPM requests: `__FILE__`, traces,
  error logs, worker user).

### V4. New read path

The table is never queried by path nor from a request: a tenant cannot
"ask for" a block at PHP level. Lookup by path and `validate_permission`
are unchanged.

- **Test**: `isolation.sh` §3, reading the other site's `secret.php` (640)
  through a symlink and through an absolute path, before and after its owner
  caches it: denied in both modes.

### V5. OPcache API across tenants

- **Test**: `isolation.sh` §2: `opcache_get_status()`,
  `opcache_invalidate()` on the other tenant's file, `opcache_reset()`, from
  A: accepted without `restrict_api` (native and dedup alike), denied with
  it.
- **Verdict**: `restrict_api` is mandatory, pointing to a path that no
  tenant controls.

### V6. Hostile PHP code against the patch itself

The tenant writes the PHP that the patch serializes and compares.

| Case | Behaviour | Test |
|---|---|---|
| deeply nested constant array | beyond 32 levels, the `op_array` is not shared, no recursion | `dedup_hostile.phpt` (200 levels) |
| huge function (60,000 opcodes, 60,000 literals) | serialized once, shared; buffer memory under `memory_limit`, like compilation | `dedup_hostile.phpt` |
| full table | no further registration, everything else unchanged | `dedup_hostile.phpt` (900 functions, table of 768) |
| collision flooding | at most 16 probes, salted key | `dedup_hash_collision.phpt` |
| restart (`opcache_reset()`, exhaustion, `max_wasted_percentage`) | table emptied together with the SHM in the common restart path (`zend_accel_dedup_reset`) | `dedup_hostile.phpt`, `isolation.sh` |
| overflows | `last`, `last_literal` as `uint32_t` × `sizeof` on 64 bits, masked indexes, reads bounded by the entry | review |

- What hostile code can achieve: make sharing ineffective, at the cost of
  its own memory, just as it can already exhaust the native cache.

### V7. Native attacker

See sections 2 and 3.1. Dedup adds no capability; it concentrates the
target.

## 4bis. "List → target → inject" attack chain (audit of 2026-10-20)

Explicit audit of a PHP attacker who wants to inject code into a specific
function (e.g. `esc_html()`) of another site. Three steps; the chain breaks
at the second.

### Step 1 — list cached files, including other tenants' files?

**Yes at PHP level, but that is native OPcache, not dedup.**
`opcache_get_status(true)` walks the whole `ZCSG(hash)` table (every script
of every tenant of the master) and returns `full_path`, `hits`,
`memory_consumption` and timestamps for each. Verified
(`zend_accelerator_module.c`, `accelerator_get_scripts`). Closed by
`opcache.restrict_api`. Dedup adds **only** aggregate counters (`enabled`,
`num_entries`, `hits`, `misses`, `saved_memory`): no path, no per-block or
per-tenant data. Enumeration is therefore not made worse by the patch.

### Step 2 — map a file to the opcodes of a function, to target a neighbour's `esc_html()`?

**No at PHP level.** This is where the chain breaks.

- **No OPcache API returns opcodes.** Full surface:
  `opcache_get_status`, `opcache_get_configuration`, `opcache_reset`,
  `opcache_invalidate`, `opcache_jit_blacklist`, `opcache_compile_file`,
  `opcache_is_script_cached`. None returns opcode or literal bytes.
- **Reflection does not expose opcodes** (no bytecode/opcode method in
  `ext/reflection`). It gives the signature, parameters and file, not the
  compiled bytecode.
- **The dedup table is not exposed to PHP.** It can be neither enumerated
  nor queried: it is only read internally, at persist time.
- Merely bringing a neighbour's `op_array` into one's own process would
  require `include`-ing its file, hence permission to read it at the
  filesystem level: blocked by `validate_permission` and Unix permissions
  (tested, `isolation.sh` §3).

From PHP, a tenant can therefore neither read the opcodes of `esc_html()`,
nor know which sites share a block, nor link block → file → tenant. All of
this requires native memory access.

### Step 3 — patch the opcode and inject code into another site?

**At PHP level: no.** No PHP function writes opcodes. And even though dedup
makes A and B point to the **same** block when their code is identical, the
shared memory is **immutable**:

- opcodes: `zend_op` in SHM, no write path from PHP;
- literals: flagged `IS_ARRAY_IMMUTABLE` / `GC_IMMUTABLE` at persist time
  (verified, `zend_persist.c`). Copy-on-write: a tenant modifying a returned
  constant array modifies a private copy, never the shared one;
- `static_variables`, `run_time_cache`: per `op_array` or per request,
  **not shared**.

A co-tenant sharing a block with a victim therefore cannot alter a single
shared byte through any PHP path. Tested: `dedup_cotenant_write.phpt` (A
shares `config()`/`run()` with B, A hammers the returned constant array, B
and the shared memory stay intact).

**At native level: yes, but that is the pre-existing full capability.** The
SHM is mapped `PROT_READ|PROT_WRITE` in every worker (verified,
`shared_alloc_mmap.c`). A worker running native code can already rewrite any
cached script of any tenant, with or without dedup. What dedup changes:
patching **one** shared `esc_html()` block affects every site sharing it, in
one write, instead of one block per site (concentration, §3.1). It is an
**amplification** of an already total capability, not a new capability.

**Conclusion.** For a PHP attacker the chain breaks at step 2: it can
enumerate paths (native OPcache, closed by `restrict_api`), but can neither
read opcodes, nor link them to a function or a site, nor write them. Steps 2
and 3 require native execution, which already gives full read-write access
to the SHM, independently of dedup. Dedup's only contribution is the
concentration of the blast radius once that native access is obtained —
hence the recommendation of masters of 15 to 20 sites of equivalent trust
(§7) and mandatory `restrict_api`.

## 5. Tests

| Test | Mode | What it checks |
|---|---|---|
| `dedup_hash_collision.phpt` | phpt | V1 |
| `dedup_hostile.phpt` | phpt | V6: depth, size, full table, restart |
| `dedup_cotenant_write.phpt` | phpt | §4bis step 3: a co-tenant sharing a block cannot mutate it for the others |
| `dedup_variants.phpt`, `dedup_literals.phpt` | phpt | V3 |
| `dedup_paths.phpt`, `dedup_vendored.phpt`, `dedup_classes.phpt` | phpt | V3 |
| `docker/loadtest/probe.sh` | FPM, 80 sites | V3: error logs, magic constants, worker user |
| `docker/loadtest/isolation.sh` | FPM, 2 sites, 2 users, 4 runs | V2, V4, V5: identical to native |
| PHP test suite (6,437 tests) + Valgrind + ASan | debug / asan | 3.2 (heap and stack) |
| `docker/fuzz/` differential fuzzing | bench + asan | 3.2, V3: random PHP, dedup output == native, 3,000 ASan iterations + thousands in bench, 0 divergences |

Matrix: PHP 8.2, 8.3, 8.4, 8.5, 8.6 (RC3) and master (8.7-dev).
Commands: `make test-all`, then `make shell` and `docker/loadtest/probe.sh`,
`docker/loadtest/isolation.sh`.

## 6. Native protections: suitable for this case?

| Directive | Role | For this use case |
|---|---|---|
| `validate_permission=1` | re-checks `access()` on the file on every cache lookup by path | **mandatory**, unchanged, tested |
| `validate_root=1` | separates chroots | mandatory if chroot |
| `restrict_api=<admin path>` | restricts `opcache_*` to scripts under this path | **mandatory**, tested |
| `protect_memory=1` | SHM read-only outside persistence | against accidental writes and limited write primitives; not against native code. Measured cost: compilation CPU ×55 with 4 GB of SHM (`mprotect` of the whole SHM on every persist), unusable in production |
| `file_cache` | second-level cache on disk | must never be shared between tenants (bug #80864); dedup disables itself if it is set |
| `jit` | | `disable` required; `off` (sury default) is not enough |
| `open_basedir` | | does not hide `/proc/meminfo` (oracle 3.3) |

## 7. Blast radius and alternatives

The gain saturates quickly (-35.8 % at 10 sites, -45.1 % at 30, -46.5 % at
80): the shareable portion is reached with a few dozen sites. The risks
specific to dedup (3.1, 3.2) and the native ones (section 2) all scale with
the number of tenants behind one master.

**Recommendation**: masters of 15 to 20 sites, grouped by equivalent trust
level (a single customer, or comparable customers), rather than one master
for all sites. This keeps most of the saving and divides the blast radius of
a corruption, a crash or a cold restart. No dedup between tenants of unequal
trust: this is the same rule as for sharing a master.

**Alternative without a patch, rejected**: a single read-only WordPress
core, owned by root, symlinked into each site. OPcache keys on the real
path, so there is a single copy, and a compromised site can no longer modify
the core. **Rejected for shared hosting**: it forces the hosting provider to
manage the core files of customer sites (same version for everyone,
coordinated updates, plugins and themes handled the same way,
`ABSPATH`/`__FILE__` on a common path), which is not sustainable on shared
hosting, even between known projects. Dedup leaves each site intact and
managed by its owner: that is precisely what makes it applicable here.

## 8. External critical review of 2026-10-20: what was taken into account

| Point | Follow-up |
|---|---|
| The patch is evaluated against native, not against the shared-hosting threat model | section 1 rewritten from a compromised tenant; section 2 on the native state |
| Target concentration, common failure mode | sections 3.1 and 3.2, blast radius recommendation (7) |
| "Never addressable from outside" is meaningless against native code | wording removed; scope explicitly limited to PHP level (V4) |
| Side channels not addressed | section 3.3: real and accepted memory oracle, marginal timing, Flush+Reload out of reach at PHP level |
| Pathological literals, full table, restart | depth bound added to the code, `dedup_hostile.phpt` |
| Valgrind not conclusive for the SHM; real fuzzing missing | acknowledged (3.2); ASan run on the tests, the OPcache suite and two WordPress sites; differential fuzzing added (`docker/fuzz/`), 3,000 ASan iterations + thousands in bench, 0 divergences |
| The patch entrenches the weakest model | section 7: masters of 15 to 20 sites; symlink alternative rejected, with the reason |
| JIT and `file_cache` | `jit=off` is the sury default; required settings in section 6; cold-start cost re-measured |
| Single run, latencies dominated by queueing | CPU overhead measured as CPU time with 95 % CI (±2 ms, +2.5 %, 20 repetitions); real-time run under saturation attempted but inconclusive (host at load average 33), see `RESULTS.md` |
| Proxmox or Docker; 8.6 missing | Docker container **inside** a Proxmox LXC CT, stated; 8.6 (RC3) added to the matrix |
