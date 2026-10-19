#ifndef NEOBRIDGE_CSQLITE_SHIM_H
#define NEOBRIDGE_CSQLITE_SHIM_H

// The shim exists so the module map names one header rather than the system
// header directly, which keeps the include path resolution identical on macOS
// (SDK header) and Linux (libsqlite3-dev).
#include <sqlite3.h>

#endif
