--TEST--
opcache.enable_dedup: classes, inheritance, traits and static variables
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

$paths = dedup_make_sites('dedup_classes', <<<'PHP'
<?php
namespace DedupClasses;

/* Declared at runtime, so that both copies can be compiled in one process */
if (!trait_exists(Counts::class, false)) {
    trait Counts
    {
        public function next(): int
        {
            static $calls = 0;
            return ++$calls;
        }
    }

    abstract class Shape
    {
        public const UNIT = 'cm';

        abstract public function area(): float;

        public function describe(): string
        {
            return sprintf('%s: %.2f %s2', static::class, $this->area(), self::UNIT);
        }
    }

    final class Square extends Shape
    {
        use Counts;

        public function __construct(private float $side) {}

        public function area(): float
        {
            return $this->side ** 2;
        }
    }

    final class Circle extends Shape
    {
        use Counts;

        public function __construct(private float $radius) {}

        public function area(): float
        {
            return M_PI * $this->radius ** 2;
        }
    }
}
PHP);

var_dump(opcache_compile_file($paths['a']));
$before = dedup_stats();
var_dump(opcache_compile_file($paths['b']));
$after = dedup_stats();
var_dump($after['hits'] - $before['hits'] >= 5);

include $paths['b'];
$square = new DedupClasses\Square(3);
$circle = new DedupClasses\Circle(1);
echo $square->describe(), "\n", $circle->describe(), "\n";
var_dump($square->next(), $square->next(), $circle->next());
var_dump((new ReflectionMethod($square, 'describe'))->getFileName() === $paths['b']);
?>
--CLEAN--
<?php
require __DIR__ . '/dedup.inc';
dedup_remove_sites('dedup_classes');
?>
--EXPECT--
bool(true)
bool(true)
bool(true)
DedupClasses\Square: 9.00 cm2
DedupClasses\Circle: 3.14 cm2
int(1)
int(2)
int(1)
bool(true)
