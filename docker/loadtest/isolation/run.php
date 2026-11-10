<?php
require __DIR__ . '/lib.php';
echo iso_marker(), ' ', basename(dirname(__DIR__)), ' ', getenv('USER') ?: '?', "\n";
