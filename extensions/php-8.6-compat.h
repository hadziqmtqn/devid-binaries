/* Aliases that PHP 8.6 removed, with the definitions PHP 8.5 had (Devid D-062). build-ext.sh
 * includes this file in every extension it builds for PHP 8.6, because the newest releases of
 * some recipes (apcu 5.1.28, imagick 3.8.1) still use them. static-php-cli's v3 branch restores
 * the same list (crazywhalecc/static-php-cli#1226). Each one only renames an API that 8.6 still
 * has; drop an alias once no recipe's release needs it. */
#ifndef DEVID_PHP86_COMPAT_H
#define DEVID_PHP86_COMPAT_H

#ifndef XtOffsetOf
# define XtOffsetOf(s_type, field) offsetof(s_type, field)
#endif
#ifndef ZVAL_IS_NULL
# define ZVAL_IS_NULL(z) (Z_TYPE_P(z) == IS_NULL)
#endif
#ifndef zval_dtor
# define zval_dtor(zvalue) zval_ptr_dtor_nogc(zvalue)
#endif
#ifndef zval_is_true
# define zval_is_true(op) zend_is_true(op)
#endif
#ifndef INI_INT
# define INI_INT(name) zend_ini_long((name), strlen(name), 0)
#endif
#ifndef INI_FLT
# define INI_FLT(name) zend_ini_double((name), strlen(name), 0)
#endif
#ifndef INI_STR
# define INI_STR(name) zend_ini_string_ex((name), strlen(name), 0, NULL)
#endif
#ifndef INI_BOOL
# define INI_BOOL(name) ((bool) INI_INT(name))
#endif
#ifndef EMPTY_SWITCH_DEFAULT_CASE
# define EMPTY_SWITCH_DEFAULT_CASE() default: ZEND_UNREACHABLE(); break;
#endif
#ifndef ZEND_WRONG_PARAM_COUNT
# define ZEND_WRONG_PARAM_COUNT() { zend_wrong_param_count(); return; }
#endif
#ifndef WRONG_PARAM_COUNT
# define WRONG_PARAM_COUNT ZEND_WRONG_PARAM_COUNT()
#endif
#ifndef ZEND_PARSE_PARAMS_THROW
# define ZEND_PARSE_PARAMS_THROW 0
#endif
#ifndef zend_parse_parameters_throw
# define zend_parse_parameters_throw(num_args, ...) zend_parse_parameters(num_args, __VA_ARGS__)
#endif
#ifndef OPENBASEDIR_CHECKPATH
# define OPENBASEDIR_CHECKPATH(filename) php_check_open_basedir(filename)
#endif

#endif
