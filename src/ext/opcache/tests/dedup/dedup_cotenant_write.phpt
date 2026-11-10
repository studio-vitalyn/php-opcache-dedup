--TEST--
opcache.enable_dedup: a tenant sharing a block cannot mutate it for the others
--EXTENSIONS--
opcache
--INI--
opcache.enable=1
opcache.enable_cli=1
opcache.enable_dedup=1
opcache.file_update_protection=0
opcache.jit_buffer_size=0
--FILE--
<?php
require __DIR__ . '/dedup.inc';

/* A and B have byte-identical code, so their op_array points at the same
 * shared opcodes and the same shared literal (a constant array). A then does
 * everything a hostile co-tenant can do from PHP to that block: mutate what
 * the shared literal returns, feed it to functions, write to it by reference.
 * B, and the shared memory, must be unaffected. There is no PHP API that
 * writes opcodes or the persisted literal zvals; both are immutable in SHM. */
$code = <<<'PHP'
<?php
return new class {
    public function config(): array
    {
        return ['db' => ['user' => 'root', 'pass' => 'secret'], 'keys' => [1, 2, 3]];
    }
    public function run(string $s): string
    {
        return strtoupper($s);
    }
};
PHP;
$paths = dedup_make_sites('dedup_cotenant', $code);

$before = dedup_stats();
$a = include $paths['a'];
$b = include $paths['b'];
$shared = dedup_stats()['hits'] - $before['hits'];
var_dump($shared >= 2);               /* config() and run() shared */

/* A mutates every value it can reach from the shared literal */
$cfg = $a->config();
$cfg['db']['pass'] = 'OWNED';
$cfg['keys'][] = 99;
sort($cfg['keys']);
$ref = &$cfg['db'];
$ref['injected'] = true;
unset($ref);
$a->run('x');                          /* exercise the shared opcodes */

/* B must still see the pristine constant, proving the shared literal was
 * copied on write, never mutated in place */
$bc = $b->config();
var_dump($bc['db']['pass']);
var_dump(array_key_exists('injected', $bc['db']));
var_dump($bc['keys']);
var_dump($b->run('abc'));

/* A re-reads its own constant: also pristine (copy-on-write, not the mutated $cfg) */
var_dump($a->config()['db']['pass']);
?>
--CLEAN--
<?php
require __DIR__ . '/dedup.inc';
dedup_remove_sites('dedup_cotenant');
?>
--EXPECT--
bool(true)
string(6) "secret"
bool(false)
array(3) {
  [0]=>
  int(1)
  [1]=>
  int(2)
  [2]=>
  int(3)
}
string(3) "ABC"
string(6) "secret"
