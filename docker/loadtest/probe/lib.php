<?php
/* Identical on every site, so its functions are deduplicated. Everything it
 * reports must still name the calling site. */
function probe_where(): array
{
    return ['file' => __FILE__, 'dir' => __DIR__, 'line' => __LINE__, 'function' => __FUNCTION__];
}

class ProbeThing
{
    public function where(): array
    {
        return [
            'class' => __CLASS__,
            'method' => __METHOD__,
            'line' => __LINE__,
            'file' => __FILE__,
            'trace' => array_map(fn ($f) => ($f['file'] ?? '?') . ':' . ($f['line'] ?? '?'), debug_backtrace()),
        ];
    }

    public function fail(string $kind): void
    {
        switch ($kind) {
            case 'warning':
                trigger_error('probe warning', E_USER_WARNING);
                return;
            case 'notice':
                echo $undefined_probe_variable;
                return;
            case 'exception':
                throw new RuntimeException('probe exception');
            case 'error':
                undefined_probe_function();
                return;
            case 'division':
                echo intdiv(1, 0);
                return;
        }
    }
}
