#include "base.h"
#include "value.h"

/* Implemented by the `tclib` system library the translation links. */
int tclib_value(void);

/* Defined only when the translation defines `TCPKG_ENABLED`. */
#ifdef TCPKG_ENABLED
#define TCPKG_READY TCPKG_BASE
#endif
