#pragma once
#include <stdint.h>
enum { CCS_UP=-1, CCS_DOWN=-2, CCS_LEFT=-3, CCS_RIGHT=-4, CCS_PAGE_UP=-5,
       CCS_PAGE_DOWN=-6, CCS_HOME=-7, CCS_END=-8, CCS_RESIZE=-9, CCS_TIMEOUT=-99 };
int ccs_terminal_start(void);
void ccs_terminal_end(void);
void ccs_terminal_size(int *height, int *width);
void ccs_terminal_clear(void);
void ccs_terminal_refresh(void);
void ccs_terminal_row(int y, int selected);
void ccs_terminal_put(int y, int x, const char *text, int limit, int style);
int32_t ccs_terminal_key(int milliseconds);
