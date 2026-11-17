#include "include/SQLiteConfig.h"
#include <sqlite3.h>

int sqlite_memory_statistics_off(void) {
    return sqlite3_config(SQLITE_CONFIG_MEMSTATUS, 0);
}
