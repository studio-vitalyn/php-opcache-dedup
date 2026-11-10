#!/usr/bin/env perl
# Inserts the opcache dedup hooks into a pristine php-src tree (8.2 .. master).
# Used only to (re)generate patches/*.patch; every edit must apply exactly once.
#
# usage: scripts/hooks.pl <php-src-dir>
use strict;
use warnings;

my $root = shift or die "usage: $0 <php-src-dir>\n";
my $oc = "$root/ext/opcache";

sub slurp { local $/; open my $fh, '<', $_[0] or die "$_[0]: $!"; <$fh> }
sub spew  { open my $fh, '>', $_[0] or die "$_[0]: $!"; print $fh $_[1]; }

sub edit {
	my ($file, @subs) = @_;
	my $src = slurp($file);
	while (my ($re, $code) = splice(@subs, 0, 2)) {
		my $n = 0; $n++ while $src =~ /$re/g;
		die "$file: expected 1 match for $re, got $n\n" if $n != 1;
		$src =~ s/$re/$code->()/e;
	}
	spew($file, $src);
}

# Build system: keep source lists sorted
edit("$oc/config.m4",
	qr/^([ \t]*)zend_accelerator_debug\.c( \\)?\n/m, sub { my $c = $2 // ""; "$1zend_accelerator_debug.c$c\n$1zend_accelerator_dedup.c$c\n" });
edit("$oc/config.w32",
	qr/^([ \t]*)zend_accelerator_debug\.c( \\)\n/m, sub { "$1zend_accelerator_debug.c$2\n$1zend_accelerator_dedup.c$2\n" });

# Directive + shared table pointer
edit("$oc/ZendAccelerator.h",
	qr/^#include "zend_accelerator_debug.h"\n/m, sub { qq{#include "zend_accelerator_debug.h"\n#include "zend_accelerator_dedup.h"\n} },
	qr/^(\t(?:zend_bool|bool)\s+)enable_cli;\n/m, sub { "$1enable_cli;\n$1enable_dedup;\n" },
	qr/^(\tzend_accel_hash hash;\s+\/\* hash table for cached scripts \*\/\n)/m,
		sub { "$1\tzend_accel_dedup_table *dedup;    /* shared opcode blocks, see zend_accelerator_dedup.h */\n" });

# Table allocation (kept across restarts, like ZCSG(hash)) and reset on restart
edit("$oc/ZendAccelerator.c",
	qr/^(\tzend_accel_hash_init\(&ZCSG\(hash\), ZCG\(accel_directives\)\.max_accelerated_files\);\n)/m,
		sub { "$1\tzend_accel_dedup_init_shm();\n" },
	qr/^(\t+)(zend_accel_hash_clean\(&ZCSG\(hash\)\);\n)/m, sub { "$1$2$1zend_accel_dedup_reset();\n" });

# INI, opcache_get_configuration(), opcache_get_status()
edit("$oc/zend_accelerator_module.c",
	qr/^(\tSTD_PHP_INI_BOOLEAN\("opcache\.enable_cli"\s*, "0"\s*, PHP_INI_SYSTEM, OnUpdateBool,\s+accel_directives\.enable_cli,\s+zend_accel_globals, accel_globals\)\n)/m,
		sub { qq{$1\tSTD_PHP_INI_BOOLEAN("opcache.enable_dedup"           , "0"   , PHP_INI_SYSTEM, OnUpdateBool,              accel_directives.enable_dedup,              zend_accel_globals, accel_globals)\n} },
	qr/^(\tadd_assoc_bool\(&directives, "opcache\.enable_cli",\s+ZCG\(accel_directives\)\.enable_cli\);\n)/m,
		sub { qq{$1\tadd_assoc_bool(&directives, "opcache.enable_dedup",        ZCG(accel_directives).enable_dedup);\n} },
	qr/^(\t\/\* Accelerator statistics \*\/\n)/m, sub { "\tzend_accel_dedup_add_status(return_value);\n\n$1" });

# Size calculation pass
edit("$oc/zend_persist_calc.c",
	qr/^(\tZCG\(current_persistent_script\) = new_persistent_script;\n)/m,
		sub { "$1\tzend_accel_dedup_calc_begin(for_shm);\n" },
	qr/^(\treturn new_persistent_script->size;\n\}\n)/m, sub { "\tzend_accel_dedup_calc_end();\n\n$1" },
	qr/^(\tif \(op_array->literals\) \{\n\t\tzval \*p = op_array->literals;\n[^\n]*\n)\t\tADD_SIZE\(sizeof\(zval\) \* op_array->last_literal\);\n/m,
		sub { "\tbool dedup_shared = zend_accel_dedup_calc_op_array(op_array);\n\n$1"
			. "\t\t/* Literal values are persisted even when the zvals are shared */\n"
			. "\t\tif (!dedup_shared) {\n\t\t\tADD_SIZE(sizeof(zval) * op_array->last_literal);\n\t\t}\n" },
	qr/^(\tzend_shared_alloc_register_xlat_entry\(op_array->opcodes, op_array->opcodes\);\n)\tADD_SIZE\(sizeof\(zend_op\) \* op_array->last\);\n/m,
		sub { "$1\tif (!dedup_shared) {\n\t\tADD_SIZE(sizeof(zend_op) * op_array->last);\n\t}\n" });

# Persist pass
edit("$oc/zend_persist.c",
	qr/^(\tscript->mem = ZCG\(mem\);\n)/m, sub { "$1\tzend_accel_dedup_persist_begin(for_shm);\n" },
	qr/^(\treturn script;\n\}\n)/m, sub { "\tzend_accel_dedup_persist_end();\n\n$1" },
	qr/^\tif \(op_array->literals\) \{\n(\t\tzval \*p, \*end;\n)/m,
		sub { "\tzend_accel_dedup_entry *dedup_entry = zend_accel_dedup_persist_find(op_array);\n\n"
			. "\tif (dedup_entry) {\n"
			. "\t\tzval *p = op_array->literals;\n"
			. "\t\tzval *end = p + op_array->last_literal;\n\n"
			. "\t\t/* Only the literal zvals and the opcodes are shared. The values are\n"
			. "\t\t * persisted as usual, so that they are released, or shared with other\n"
			. "\t\t * op_arrays of the script through the xlat table. */\n"
			. "\t\twhile (p < end) {\n"
			. "\t\t\tzend_persist_zval(p);\n"
			. "\t\t\tp++;\n"
			. "\t\t}\n"
			. "\t\tzend_accel_dedup_share(op_array, dedup_entry);\n"
			. "\t}\n\n"
			. "\tif (op_array->literals && !dedup_entry) {\n$1" },
	qr/^\t\{\n(\t\tzend_op \*new_opcodes = zend_shared_memdup_put\(op_array->opcodes)/m,
		sub { "\tif (!dedup_entry) {\n$1" },
	qr/^(\t\tefree\(op_array->opcodes\);\n\t\top_array->opcodes = new_opcodes;\n)/m,
		sub { "$1\n\t\tzend_accel_dedup_register_op_array(op_array);\n" });

# Documented defaults
for my $ini ("$root/php.ini-development", "$root/php.ini-production") {
	edit($ini, qr/^(;opcache\.enable_cli=0\n)/m, sub {
		"$1\n; Shares the opcodes of identical functions between cached scripts instead of\n"
		. "; storing one copy per file path. Useful when many copies of the same code are\n"
		. "; served by one PHP-FPM master. Ignored when the file cache is set or the JIT\n"
		. "; is available (opcache.jit=off still allows enabling it at run time; use\n"
		. "; opcache.jit=disable or opcache.jit_buffer_size=0).\n"
		. ";opcache.enable_dedup=0\n" });
}

# Release notes, master only
if (-f "$root/UPGRADING" && slurp("$root/main/php_version.h") =~ /PHP_VERSION "\d+\.\d+\.\d+-dev"/) {
	edit("$root/UPGRADING",
		qr/^(========================================\n11\. Changes to INI File Handling\n========================================\n\n)/m,
		sub { "$1- Opcache:\n"
			. "  . Added opcache.enable_dedup (default 0, INI_SYSTEM). When enabled, the\n"
			. "    opcodes and literals of identical functions are stored once in shared\n"
			. "    memory, regardless of the file they belong to. This reduces memory\n"
			. "    usage when many copies of the same code are served by one SAPI\n"
			. "    instance (e.g. shared hosting). opcache_get_status() reports it in\n"
			. "    the new \"dedup\" key. Not available with the JIT or the file cache.\n\n" });
}
