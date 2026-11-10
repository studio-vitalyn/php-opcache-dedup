# OPcache dedup

This OPcache patch shares the opcodes of identical functions in shared memory
(SHM), regardless of which file contains them. It targets shared hosting,
where a single PHP-FPM master serves dozens of copies of the same code
(WordPress, plugins, `vendor/`).

The description intended for the php-src pull request is in
[docs/PR.md](docs/PR.md).

> Motivation: in production, 80 PHP 8.4 sites use about 3 GB of OPcache
> although about 80 % of their files are identical. OPcache indexes by path
> and therefore stores 80 copies of the same bytecode.

The patch is written as a php-src PR targeting `master` (8.7-dev). Backports
are provided for 8.2, 8.3, 8.4, 8.5 and 8.6 (RC3), the branches still
maintained. 8.0 and 8.1, which are end-of-life, were dropped on 2026-10-20
(the patch applied to them and passed the tests).

## Usage

```ini
[opcache]
; Off by default. INI_SYSTEM: an FPM restart is enough to toggle it.
; When 0, no structure is allocated and behaviour is strictly native.
opcache.enable_dedup = 1
```

`opcache_get_status()` exposes the counters:

```php
['dedup' => ['enabled' => true, 'max_entries' => 49152, 'num_entries' => 812,
             'hits' => 15873, 'misses' => 2210, 'saved_memory' => 412316160]]
```

**What stays per-site.** A function that contains the file path is not
shared. This is the case for `__FILE__`/`__DIR__`, including as a parameter
default value, and for `self::CONST` when the class constant is built from
`__DIR__`. User constants are not a problem: with `const ROOT = __DIR__ . '/www';`
or `define()`, only the body of the declaring file carries the path, and code
that uses `ROOT` remains shareable. The rule for in-house code: declare the
path once in a constant, then use it by name. On WordPress, code blocked by
the path accounts for 6.5 % of the bytecode (details in
[docs/ANALYSIS.md](docs/ANALYSIS.md)).

Deduplication is skipped, with a warning in the OPcache log, if
`opcache.file_cache` is set or if the JIT is available. `opcache.jit=off` is
not enough, because the JIT can still be enabled at runtime, and that is the
default of the sury packages: `opcache.jit=disable` or
`opcache.jit_buffer_size=0` is required. It is also skipped on 32-bit builds.
It only has an effect if the sites share the **same FPM master** (one SHM per
master).

## Principle

Sharing is based on a hash of the **compiled block** (the opcodes and
literals of each function), not on a hash of the file or its path. Because
`__FILE__` and `__DIR__` are compile-time literals, a whole file is never
identical to its copy. Most of its functions, however, are.

- Every hash match is confirmed by a full comparison: a collision can never
  lead to sharing.
- Each `op_array` keeps its own path, scope, variables and exception tables.
  `__FILE__`, stack traces and Reflection therefore remain specific to each
  site.
- Scripts are still looked up by path, with the native checks
  (`validate_permission`, `validate_root`).
- Everything happens under the existing SHM write lock. Nothing is freed
  before a restart, so shared blocks need no reference count.

Details, sources and the comparison with the initial proposal are in
[docs/ANALYSIS.md](docs/ANALYSIS.md). The security review (cross-tenant
isolation, vectors examined, required native protections) is in
[docs/SECURITY.md](docs/SECURITY.md).

## Contents

```
src/ext/opcache/zend_accelerator_dedup.{c,h}   implementation (shared by all versions)
src/ext/opcache/tests/dedup/*.phpt             phpt tests
scripts/hooks.pl                               inserts the hooks into a php-src tree (~40 lines)
scripts/gen-patches.sh                         generates patches/php-<series>.patch (git am format)
scripts/versions                               supported series and reference php-src tag
patches/php-{8.2..8.6,master}.patch            full patch per series
docker/                                        dev, test and bench container
```

Applying a patch to a php-src checkout:

```sh
cd php-src && git am /path/to/patches/php-8.4.patch   # or: git apply
```

## Build, tests and bench (Docker host)

Nothing runs locally. The Makefile syncs the repository over SSH to a Docker
host (`DOCKER_HOST_SSH`, directory `REMOTE_DIR`, both set in an unversioned
`local.mk`), then runs everything in the compose container
`opcache-dedup-dev` (limited to 8 CPUs and 14 GB).

```sh
make up                          # build and start the container
make patches                     # regenerate patches/ from src/ and hooks.pl
make test SERIES=8.4             # dedup phpt (debug build)
make test-all                    # dedup phpt on 8.2 … master
make test-opcache SERIES=8.4     # ext/opcache/tests without, then with dedup
make test-full SERIES=8.4        # Zend/tests + tests + ext/opcache, without, then with dedup
make bench SERIES=8.4 SITES=80 IDENTICAL=80
make shell
```

The A/B bench sets up N sites running WordPress, WooCommerce, Yoast, Contact
Form 7 and Elementor. Each site has its own Unix user and FPM pool under a
single master, with `validate_permission=1`. A percentage of the sites runs
the current stack, the others an older stack. The bench compiles every PHP
file in parallel through each pool, with `opcache.enable_dedup` set to 0 and
then to 1, and compares:

- SHM consumption;
- compilation CPU;
- the output of a functional test (WordPress formatting API) on each site.

## Results

**Load test**, PHP 8.4: 80 active WordPress sites (WooCommerce, Elementor,
Yoast), a single FPM master, 1,000,000 requests in total.

| | without dedup | with dedup |
|---|---:|---:|
| OPcache memory | 6,406 MB | **3,428 MB (-46.5 %)** |
| PHP-FPM RAM, peak PSS | 6,711 MB | **5,466 MB (-18.6 %)** |
| CPU per request, throughput, latency | baseline | identical, within ±1 % at steady state |
| Errors, crashes | 0 | 0 |

- **Tests**: 15/15 phpt on 8.2 → master; 6,437 PHP tests with no regression
  (8.4); Valgrind clean.
- **Details**: [docs/RESULTS.md](docs/RESULTS.md).
- **Replaying the load test**: `make shell`, then
  `docker/loadtest/setup.sh 8.4 80 80 && docker/loadtest/night.sh 500000`.
