--TEST--
opcache.enable_dedup: identical methods of differently named classes are shared
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

/* Same library vendored under two prefixes, declared at compile time */
$template = <<<'PHP'
<?php
namespace PREFIX\Lib;

class Base
{
    protected array $items = [];

    public function add(string $item): static
    {
        $this->items[] = \trim($item);
        return $this;
    }

    public function count(): int
    {
        return \count($this->items);
    }
}

class Collection extends Base
{
    public function join(string $glue = ', '): string
    {
        return \implode($glue, $this->items);
    }
}
PHP;

$paths = [];
foreach (['Acme', 'Other'] as $prefix) {
    $paths[$prefix] = dedup_make_sites('dedup_vendored', str_replace('PREFIX', $prefix, $template), [$prefix])[$prefix];
}

$before = dedup_stats();
include $paths['Acme'];
$middle = dedup_stats();
include $paths['Other'];
$after = dedup_stats();

var_dump($middle['hits'] === $before['hits']);
/* add(), count() and join() */
var_dump($after['hits'] - $middle['hits'] >= 3);

foreach (['Acme\Lib\Collection', 'Other\Lib\Collection'] as $class) {
    $c = (new $class)->add(' x ')->add('y');
    echo $class, ': ', $c->join(), ' (', $c->count(), ")\n";
    var_dump((new ReflectionMethod($class, 'count'))->getDeclaringClass()->getName());
}
?>
--CLEAN--
<?php
require __DIR__ . '/dedup.inc';
dedup_remove_sites('dedup_vendored');
?>
--EXPECT--
bool(true)
bool(true)
Acme\Lib\Collection: x, y (2)
string(13) "Acme\Lib\Base"
Other\Lib\Collection: x, y (2)
string(14) "Other\Lib\Base"
