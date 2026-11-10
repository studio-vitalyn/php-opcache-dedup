/*
   +----------------------------------------------------------------------+
   | Zend OPcache                                                         |
   +----------------------------------------------------------------------+
   | Copyright © The PHP Group and Contributors.                          |
   +----------------------------------------------------------------------+
   | This source file is subject to the Modified BSD License that is      |
   | bundled with this package in the file LICENSE, and is available      |
   | through the World Wide Web at <https://www.php.net/license/>.        |
   |                                                                      |
   | SPDX-License-Identifier: BSD-3-Clause                                |
   +----------------------------------------------------------------------+
*/

#ifndef ZEND_ACCELERATOR_DEDUP_H
#define ZEND_ACCELERATOR_DEDUP_H

#include "zend.h"
#include "zend_compile.h"

/*
 * Content-addressed sharing of opcode arrays in shared memory.
 *
 * Identical files cached under different paths (e.g. many copies of the same
 * CMS on a shared host) compile to identical opcodes for most of their
 * functions. When opcache.enable_dedup is on, the opcodes and literals of an
 * op_array are not copied into SHM if a byte-for-byte equivalent block has
 * already been persisted; the new op_array points to the existing block.
 *
 * Only the opcodes and literals are shared. Every op_array keeps its own
 * filename, scope, variable names, arg_info, live ranges and try/catch
 * table, so __FILE__, __DIR__, stack traces and error messages are not
 * affected: path-dependent literals (__FILE__, __DIR__, runtime definition
 * keys) simply make the block differ and prevent sharing.
 *
 * Lookups happen at persist time only, under the SHM write lock. Scripts are
 * still looked up by path, so the existing permission checks
 * (opcache.validate_permission, opcache.validate_root) are unchanged and a
 * shared block can never be reached through its hash.
 *
 * Sharing requires opline-relative constant and jump operands, so it is
 * only available on 64-bit builds.
 *
 * What makes a function path-dependent, and thus not shared:
 * - __FILE__ and __DIR__, which are folded into literals at compile time,
 *   including in default parameter values (RECV_INIT);
 * - self::CONST when the class constant is built from __DIR__ or __FILE__,
 *   because the optimizer inlines its value into the method.
 * User constants are not: OPcache compiles with
 * ZEND_COMPILE_NO_CONSTANT_SUBSTITUTION, so `const ROOT = __DIR__ . '/x';`
 * or define() only make the file body that declares them path-dependent,
 * and every function using ROOT fetches it by name at run time. Magic
 * constants that do not depend on the path (__LINE__, __CLASS__,
 * __FUNCTION__, __METHOD__, __NAMESPACE__) are identical in identical files.
 * On a WordPress site with common plugins, path-dependent code is about 6.5%
 * of the opcodes and literals, mostly file bodies (require __DIR__ . '...')
 * and runtime definition keys of delayed class declarations.
 */
#if !ZEND_USE_ABS_CONST_ADDR && !ZEND_USE_ABS_JMP_ADDR
# define ZEND_ACCEL_DEDUP_SUPPORTED 1
#else
# define ZEND_ACCEL_DEDUP_SUPPORTED 0
#endif

typedef struct _zend_accel_dedup_entry zend_accel_dedup_entry;
typedef struct _zend_accel_dedup_table zend_accel_dedup_table;

void zend_accel_dedup_init_shm(void);
void zend_accel_dedup_reset(void);

void zend_accel_dedup_calc_begin(bool for_shm);
void zend_accel_dedup_calc_end(void);
bool zend_accel_dedup_calc_op_array(const zend_op_array *op_array);

void zend_accel_dedup_persist_begin(bool for_shm);
void zend_accel_dedup_persist_end(void);
zend_accel_dedup_entry *zend_accel_dedup_persist_find(const zend_op_array *op_array);
void zend_accel_dedup_share(zend_op_array *op_array, const zend_accel_dedup_entry *entry);
void zend_accel_dedup_register_op_array(const zend_op_array *op_array);

void zend_accel_dedup_add_status(zval *status);

#endif /* ZEND_ACCELERATOR_DEDUP_H */
