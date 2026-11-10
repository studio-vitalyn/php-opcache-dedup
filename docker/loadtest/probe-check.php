<?php
/* Checks the probe transcripts written by probe.sh. */
[, $dir] = $argv;
$runs = [];
foreach ([0, 1] as $dedup) {
    $blocks = preg_split('/^### /m', file_get_contents("$dir/dedup$dedup.txt"), -1, PREG_SPLIT_NO_EMPTY);
    foreach ($blocks as $block) {
        [$head, $body] = explode("\n", $block, 2);
        $runs[$dedup][$head] = $body;
    }
}

$problems = 0;
$checks = 0;
foreach ($runs[1] as $head => $body) {
    [$site] = explode(' ', $head);
    /* Every path in the output or in the log must be the calling site's */
    preg_match_all('#/sites/(site\d{3})/#', $body, $m);
    foreach ($m[1] as $seen) {
        $checks++;
        if ($seen !== $site) {
            $problems++;
            echo "WRONG SITE: $head mentions $seen\n";
        }
    }
    if (!$m[1]) {
        $problems++;
        echo "NO PATH: $head\n$body\n";
    }
    /* The worker runs as the site user */
    if (preg_match('/"user":"([^"]*)"/', $body, $u) && $u[1] !== $site) {
        $problems++;
        echo "WRONG USER: $head runs as {$u[1]}\n";
    }
    /* Byte for byte the same as without dedup */
    if (($runs[0][$head] ?? null) !== $body) {
        $problems++;
        echo "DIFFERS FROM dedup=0: $head\n--- dedup=0\n{$runs[0][$head]}\n--- dedup=1\n$body\n";
    }
}

$status = json_decode(file_get_contents("$dir/opcache1.json"), true);
printf("requests: %d per run, path checks: %d, problems: %d\n", count($runs[1]), $checks, $problems);
printf("dedup=1: %d shared blocks (%.1f MB), segfaults: %s / %s\n",
    $status['dedup_hits'], $status['dedup_saved'] / 1048576,
    trim(file_get_contents("$dir/segfaults0.txt")), trim(file_get_contents("$dir/segfaults1.txt")));

/* One sample, as a reader would see it */
$sample = array_keys($runs[1]);
foreach ([$sample[1], $sample[3], $sample[4], $sample[count($sample) - 3]] as $head) {
    echo "\n### $head\n", $runs[1][$head];
}
exit($problems ? 1 : 0);
