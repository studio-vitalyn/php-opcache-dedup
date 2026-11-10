# Results

## Load test: 1,000,000 requests (2026-10-19 and 2026-10-20)

PHP 8.4.26 release build, container with 10 vCPUs and 18 GB.

**Setup**:

- 80 WordPress installs, with WooCommerce, Yoast SEO, Contact Form 7 and
  Elementor active, and one MariaDB database per site;
- one user and one `ondemand` pool per site, under **a single FPM master**;
- `validate_permission=1`, 8 GB of OPcache;
- nginx and `h2load`, 32 connections, 500,000 requests per mode, the same
  sequence replayed in both runs;
- page mix: home, posts, products, shop, REST, search.

| | dedup=0 | dedup=1 | Difference |
|---|---:|---:|---:|
| OPcache memory, end of run | 6,406 MB | 3,428 MB | **-46.5 %** |
| Copies avoided | — | 3,018 MB (2,447,101 functions) | |
| Cached scripts | 252,812 | 252,673 | |
| PHP-FPM RAM, peak PSS | 6,711 MB | 5,466 MB | **-18.6 %** |
| PHP-FPM CPU per request | 170.3 ms | 171.7 ms | +0.8 % |
| Throughput | 52.2 req/s | 51.7 req/s | -1.0 % |
| Latency p50 / p99 | 523 / 1,853 ms | 522 / 1,933 ms | |
| Non-200 responses | 0 | 0 | |
| Workers killed by SIGSEGV | 0 | 0 | |

**Steady state** (after 5 min): CPU per request is identical within ±1 % in
every time slice, between 167 and 173 ms for both runs, with the same slow
drift.

**Cold start** (first 5 minutes): 41 req/s with dedup versus 46 without. This
is the cost of computing fingerprints at compile time, since reduced by the
optimization described below.

These runs used the version preceding that optimization. Since the sharing
decisions are identical, the memory results also hold for the final version.

## Compilation CPU overhead: +2.5 % (confidence interval)

Measured as **CPU time** (`getrusage`, insensitive to host scheduling noise),
20 repetitions, synthetic corpus of 400 programs in two copies (5,065 shared
blocks). PHP 8.4 release build.

| | mean CPU time | std. dev. | 95 % CI |
|---|---:|---:|---:|
| dedup=0 | 242 ms | 5 ms | ±2 ms |
| dedup=1 | 248 ms | 4 ms | ±2 ms |

That is **+2.5 % compilation CPU**, with tight, disjoint intervals. This cost
applies only to compilation (the first minutes after a restart or a file
update); at runtime, workers read the same opcodes. `docker/bench/compile-ci.sh`.

### Note on the wall-clock run below saturation

An A/B run with 8 connections (below saturation) was attempted to measure
latencies without queueing. It is **inconclusive**: the Proxmox host was
heavily loaded during the measurement (load average 33 on 16 cores, CI jobs
and other tenants), and the dedup=1 run suffered periodic scheduling stalls
(rps dropping from 30 to 13 in some windows) that the dedup=0 run did not,
simply because it ran during a different host-load window. Since the
execution path is identical with dedup and natively (the same opcodes are
read), no per-request cost is expected at runtime, and the CPU-time
measurement above confirms it. A reliable latency measurement would require
a dedicated host.

## Optimization: a single serialization per function

The persist pass applies the decisions recorded by the calc pass instead of
repeating the lookup. Consequences:

- 1 serialization per function instead of 3 or 4;
- no compiled block is re-read during persistence any more;
- table entries of 32 bytes instead of 40.

**Measurement**: compilation CPU of three sites in one CLI process, seven
alternating repetitions.

| Version | CPU (mean) | vs native |
|---|---:|---:|
| PHP 8.4 native | 7,742 ms | — |
| dedup, load-test version | 8,439 ms | +9.0 % |
| dedup, final version | 7,912 ms | **+2.2 %** |

## Cost of `opcache.protect_memory` (2026-10-20)

Measured because the security review considered it as a barrier against
writes to SHM. Compilation bench, 10 sites, 4 GB of SHM, release build:

| | `protect_memory=0` | `protect_memory=1` |
|---|---:|---:|
| Compilation CPU, native | 33.9 s | **1,852 s** (×55) |
| Compilation CPU, dedup | 35.0 s | 2,727 s |
| Load duration, native | 8.7 s | 368 s |

On every persistence, OPcache switches the whole SHM (4 GB) to read-only and
back to writable with `mprotect`. The cost is proportional to the SHM size
and the number of scripts: **unusable in production** with a cache of this
size, with or without dedup. It is therefore not an available mitigation;
[SECURITY.md](SECURITY.md) §6 takes this into account.

## Compilation bench

Measurements from 2026-10-19, on a 16-vCPU host (container limited to 8 CPUs
and 14 GB), with PHP 8.4.26 release build and the JIT disabled.

## A/B bench

Setup, identical for each site:

- **Stack**: WordPress, WooCommerce, Yoast SEO, Contact Form 7 and Elementor,
  about 9,000 PHP files per site.
- **Isolation**: one Unix user and one FPM pool per site, **under a single
  master**, with `opcache.validate_permission=1`.
- **Heterogeneity**: 80 % of the sites run the current stack, 20 % an older
  stack (WordPress 6.5.5, WooCommerce 9.0…).
- **Loading**: every file is compiled via `opcache_compile_file()` through
  each site's pool, 8 sites in parallel.

| Sites | SHM dedup=0 | SHM dedup=1 | Gain | Compilation CPU | Shared blocks |
|---:|---:|---:|---:|---:|---:|
| 10 | 1,818 MB | 1,167 MB | **-35.8 %** | -5.6 % | 78.7 % |
| 30 | 4,857 MB | 2,667 MB | **-45.1 %** | -0.5 % | 84.4 % |

In both configurations:

- the same number of scripts is cached;
- no OPcache errors;
- no crashes;
- the output of the functional test (WordPress formatting API run on each
  site) is identical.

**Marginal cost of one more site**: about 152 MB without dedup, about 75 MB
with it.

**Projection for 80 sites** with the same distribution: about 12.5 GB versus
6.4 GB, i.e. **-49 %**.

**For the production setup that motivated this work** (80 sites, about 3 GB,
80 % identical files), about **1.5 to 1.7 GB** can therefore be expected. This
is an estimate derived from this bench, not a production measurement.

The gain grows with the number of sites and tends towards about 50 %, because
each identical site only costs its non-shareable part.

## What remains duplicated per site

Measured on one additional identical site, using temporary instrumentation of
`zend_persist_calc.c`:

| Part | Cost of one site | With dedup |
|---|---:|---|
| Opcodes and literal zvals | ~58 % | shared (except path-dependent blocks) |
| Class structures: `zend_class_entry`, method `zend_op_array`s, method, property and constant tables | ~31 % | duplicated |
| `arg_info`, `vars`, live ranges | ~2.5 % | duplicated |
| Rest (script, function tables, keys) | ~8 % | duplicated |

Class structures contain the path (`filename`) and script-specific scope
pointers: they cannot be shared without changing the engine's
representation. **About -50 % is therefore the ceiling of this approach.**
This is a design limit, not missing optimization.

## Tests

| Suite | Result |
|---|---|
| `ext/opcache/tests/dedup` (15 phpt), debug build | 15/15 on 8.2, 8.3, 8.4, 8.5, 8.6 (RC3) and master, final version (8.0 and 8.1 dropped as end-of-life). Includes `dedup_variants`: two docroots with the same layout, 20 varied functions (operator, comparison, literals, branches, call, argument order, default value, `match`, `switch`, `catch`, line shift, and metadata only: variable name, parameter type, return type, static variable initial value). Each function returns the result of its own version; only the 5 whose opcodes are identical are shared. |
| Zend/tests + tests/ + ext/opcache/tests (6,437 tests), dedup enabled and `protect_memory=1` | 0 regressions on 8.4, final version. |
| Valgrind memcheck, dedup phpt | 0 errors attributable to the patch. Only report: uninitialized padding written by native `zend_file_cache`, with dedup disabled in that test. |
| Valgrind, compiling 2 identical WordPress sites in one process | 0 errors, before and after the optimization. |
| Cross-tenant isolation (`docker/loadtest/isolation.sh`): 2 sites, 2 users, 1 master, 4 runs (dedup off/on × restrict_api off/on) | Cross edits have no effect, reading the other site's file is denied before and after caching, API denied with `restrict_api`; identical output native/dedup. Details: [SECURITY.md](SECURITY.md). |
| Error probe on the 80 sites through FPM (`docker/loadtest/probe.sh`): warning, notice, exception, fatal, division by zero, `__FILE__`, `__DIR__`, `__LINE__`, `__CLASS__`, `__METHOD__`, traces and Reflection | 480 requests per mode, 1,680 paths checked, 0 anomalies. Every log entry and every trace names the calling site. Output byte-for-byte identical to dedup=0. |
| Differential fuzzing (`docker/fuzz/`, 2026-10-20) | Deterministic random PHP (closures), two identical sites, `opcache_compile_file(a)+(b)` to share, then `include(b)` to execute; dedup=1 output must equal dedup=0 and must have shared. **3,000 iterations under ASan** and thousands on the bench build: 0 divergences, 0 crashes. |
| ASan (`--enable-address-sanitizer` build, ASLR disabled with `setarch -R`, 2026-10-20) | 15/15 dedup tests, 0 errors; `ext/opcache` suite (864 tests) with no regression with dedup; compiling two complete WordPress sites in one process with dedup: 0 memory errors. LeakSanitizer reports 48.5 MB in both modes, within 32 bytes (1,061,791 versus 1,061,792 allocations): these are PHP compiler `emalloc`s abandoned by the "Cannot redeclare" fatals of the test script; no stack goes through the patch's code. Limitation: neither ASan nor Valgrind instruments the inside of the SHM (OPcache's own allocator). |

## Bug found by the bench and fixed

**Symptom**: in release builds only, under concurrent FPM load, workers died
with SIGSEGV. Backtraces were obtained with `make bench GDB=1`.

**Cause**: when two `op_array`s of the same script share a constant array,
the first one persisted moves it to SHM and frees the original. Normalizing
the second one read the freed original. The first version of the patch also
freed the literals itself on a match, with the same flaw.

**Fix**:

- the persist pass never re-reads a compiled block: it applies the decisions
  of the calc pass, which frees nothing;
- on a match, literal *values* are persisted by `zend_persist_zval()` as
  usual; only the zval array and the opcodes are replaced.

**Regression test**: `dedup_shared_values.phpt`.
