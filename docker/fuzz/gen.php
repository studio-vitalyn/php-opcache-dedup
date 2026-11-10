<?php
/* Deterministic PHP generator for differential fuzzing. Given a seed, emits
 * a self-contained program: a set of functions built from random operators,
 * control flow, literals and calls, plus a driver that calls each with fixed
 * inputs and prints a hash of every result. The SAME seed always gives the
 * same program, so two "sites" get byte-identical code (shared), while a
 * seed+"'" mutation gives a near-identical variant (must not be shared with
 * the wrong result). The generated program must be deterministic: no time,
 * no randomness, no I/O at runtime. */

mt_srand((int) $argv[1]);
$variant = ($argv[2] ?? '') === 'variant';

function r(array $a) { return $a[mt_rand(0, count($a) - 1)]; }
function rname(string $p) { return $p . mt_rand(1000, 9999); }

$INT = fn () => (string) mt_rand(-50, 50);
$STR = fn () => "'" . r(['a', 'bc', 'déf', 'x y', '0', '', 'Ab', 'BA']) . "'";
$FLOAT = fn () => r(['0.0', '-0.0', '1.5', '0.1', '3.14', 'INF', '-INF']);
$BOOL = fn () => r(['true', 'false']);

function expr($vars, $depth, $ctx) {
    global $INT, $STR, $FLOAT, $BOOL;
    if ($depth <= 0) {
        return r([$INT(), $INT(), $STR(), $FLOAT(), $BOOL(), $vars ? r($vars) : $INT()]);
    }
    switch (mt_rand(0, 9)) {
        case 0: case 1:
            return '(' . expr($vars, $depth - 1, $ctx) . ' ' . r(['+', '-', '*', '.', '%', '**', '??', '<=>']) . ' ' . expr($vars, $depth - 1, $ctx) . ')';
        case 2:
            return '(' . expr($vars, $depth - 1, $ctx) . ' ' . r(['==', '===', '<', '<=', '>', '!=', '&&', '||', 'xor']) . ' ' . expr($vars, $depth - 1, $ctx) . ')';
        case 3:
            return r(['strlen', 'strtoupper', 'strrev', 'trim', 'abs', 'intval', 'count', 'json_encode', 'gettype', 'intdiv']) === 'intdiv'
                ? 'intdiv(' . expr($vars, $depth - 1, $ctx) . ', ' . r(['1', '2', '3', '-1']) . ')'
                : r(['strlen', 'strtoupper', 'strrev', 'abs', 'intval', 'gettype', 'json_encode']) . '(' . expr($vars, $depth - 1, $ctx) . ')';
        case 4:
            return '[' . implode(', ', array_map(fn () => expr($vars, $depth - 1, $ctx), range(0, mt_rand(0, 3)))) . ']';
        case 5:
            return "['" . r(['k', 'x', 'y']) . "' => " . expr($vars, $depth - 1, $ctx) . ", '" . r(['k', 'z', 'w']) . "' => " . expr($vars, $depth - 1, $ctx) . ']';
        case 6:
            return '(' . expr($vars, $depth - 1, $ctx) . ' ? ' . expr($vars, $depth - 1, $ctx) . ' : ' . expr($vars, $depth - 1, $ctx) . ')';
        case 7:
            return 'match(' . expr($vars, $depth - 1, $ctx) . ') { ' . $INT() . ' => ' . expr($vars, $depth - 1, $ctx) . ', default => ' . expr($vars, $depth - 1, $ctx) . ' }';
        default:
            return $vars ? r($vars) : $INT();
    }
}

function body($params, $variant) {
    $vars = $params;
    $stmts = [];
    $n = mt_rand(2, 6);
    for ($i = 0; $i < $n; $i++) {
        switch (mt_rand(0, 6)) {
            case 0:
                $v = '$v' . $i; $vars[] = $v;
                $stmts[] = "$v = " . expr($vars, 3, 'e') . ';';
                break;
            case 1:
                $stmts[] = 'if (' . expr($vars, 2, 'c') . ') { $acc .= ' . expr($vars, 2, 'e') . '; } else { $acc .= ' . expr($vars, 2, 'e') . '; }';
                break;
            case 2:
                $stmts[] = 'foreach (' . expr($vars, 2, 'e') . ' as $k => $w) { $acc .= $k . gettype($w); }';
                break;
            case 3:
                $stmts[] = 'for ($j = 0; $j < ' . mt_rand(0, 4) . '; $j++) { $acc .= $j; }';
                break;
            case 4:
                $stmts[] = 'try { $acc .= intdiv(1, ' . r(['0', '1', '2']) . '); } catch (\\Throwable $e) { $acc .= get_class($e); }';
                break;
            case 5:
                $stmts[] = 'switch (' . expr($vars, 1, 'e') . ') { case ' . $GLOBALS['INT']() . ': $acc .= "a"; break; default: $acc .= "d"; }';
                break;
            default:
                $stmts[] = '$acc .= ' . expr($vars, 3, 'e') . ';';
        }
    }
    /* the variant flips one operator deep in the last expression */
    $stmts[] = 'return $acc;';
    return "\$acc = '';\n    " . implode("\n    ", $stmts);
}

$items = [];
$nf = mt_rand(3, 8);
for ($f = 0; $f < $nf; $f++) {
    $np = mt_rand(0, 3);
    $params = array_slice(['$p0', '$p1', '$p2'], 0, $np);
    $sig = implode(', ', array_map(fn ($p) => "$p = 0", $params));
    $closure = "(function ($sig) {\n    " . body($params, $variant) . "\n    })";
    $args = implode(', ', array_map(fn () => r(['1', '-2', "'x'", '[1,2]', 'true', '0']), $params));
    /* closures, not named functions: two identical files share their
     * op_arrays without a redeclare conflict. Every call is captured so a
     * thrown Error becomes a comparable value. */
    $items[] = "  'c$f' => (function() { try { return json_encode($closure($args)); } catch (\\Throwable \$e) { return get_class(\$e) . ':' . \$e->getMessage(); } })(),";
}

$out = "<?php\n\$seed_marker = __FILE__;\nreturn [\n" . implode("\n", $items) . "\n];\n";
if ($variant) {
    $out = preg_replace('/ \+ /', ' - ', $out, 1);
}
echo $out;
