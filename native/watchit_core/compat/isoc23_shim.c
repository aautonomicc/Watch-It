/* glibc 2.38+ headers rewrite strtol/sscanf calls in some C/C++ deps to
 * __isoc23_* symbols, which don't exist on older distros (Mint 21 = glibc
 * 2.35). Defining them here makes the cdylib link resolve them internally,
 * so the shipped .so never references GLIBC_2.38. Must compile as gnu17 or
 * these wrappers would themselves redirect to __isoc23_* and recurse. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

long __isoc23_strtol(const char *nptr, char **endptr, int base) {
  return strtol(nptr, endptr, base);
}

unsigned long __isoc23_strtoul(const char *nptr, char **endptr, int base) {
  return strtoul(nptr, endptr, base);
}

long long __isoc23_strtoll(const char *nptr, char **endptr, int base) {
  return strtoll(nptr, endptr, base);
}

unsigned long long __isoc23_strtoull(const char *nptr, char **endptr,
                                     int base) {
  return strtoull(nptr, endptr, base);
}

int __isoc23_sscanf(const char *str, const char *format, ...) {
  va_list ap;
  va_start(ap, format);
  int rc = vsscanf(str, format, ap);
  va_end(ap);
  return rc;
}

int __isoc23_vsscanf(const char *str, const char *format, va_list ap) {
  return vsscanf(str, format, ap);
}
