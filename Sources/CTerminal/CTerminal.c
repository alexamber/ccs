#define _XOPEN_SOURCE_EXTENDED 1
#include "CTerminal.h"
#include <curses.h>
#include <locale.h>
#include <stdlib.h>
#include <wchar.h>

int ccs_terminal_start(void) {
    setlocale(LC_ALL, "");
    if (!initscr()) return -1;
    raw(); noecho(); keypad(stdscr, TRUE); curs_set(0);
    if (has_colors()) {
        start_color(); use_default_colors();
        init_pair(1, COLOR_GREEN, -1); init_pair(2, COLOR_YELLOW, -1);
        init_pair(3, COLOR_MAGENTA, -1); init_pair(4, COLOR_CYAN, -1);
    }
    return 0;
}
void ccs_terminal_end(void) { endwin(); }
void ccs_terminal_size(int *height, int *width) { getmaxyx(stdscr, *height, *width); }
void ccs_terminal_clear(void) { erase(); }
void ccs_terminal_refresh(void) { refresh(); }
void ccs_terminal_row(int y, int selected) {
    if (y < 0 || y >= LINES) return;
    attrset(selected ? A_REVERSE : A_NORMAL); mvhline(y, 0, ' ', COLS - 1);
}
void ccs_terminal_put(int y, int x, const char *text, int limit, int style) {
    if (!text || y < 0 || y >= LINES || x < 0 || x >= COLS || limit <= 0) return;
    if (limit > COLS - x - 1) limit = COLS - x - 1;
    if (limit <= 0) return;
    size_t length = mbstowcs(NULL, text, 0);
    if (length == (size_t)-1) return;
    wchar_t *wide = malloc((length + 1) * sizeof(wchar_t));
    if (!wide) return;
    mbstowcs(wide, text, length + 1);
    int columns = 0, count = 0;
    while (wide[count]) {
        int width = wcwidth(wide[count]);
        if (width < 0) width = 0;
        if (columns + width > limit) break;
        columns += width; count++;
    }
    int attrs = (style & 1 ? A_BOLD : 0) | (style & 2 ? A_DIM : 0) | (style & 4 ? A_REVERSE : 0);
    if (has_colors()) {
        if (style & 8) attrs |= COLOR_PAIR(1);
        else if (style & 16) attrs |= COLOR_PAIR(2);
        else if (style & 32) attrs |= COLOR_PAIR(3);
        else if (style & 64) attrs |= COLOR_PAIR(4);
    }
    attrset(attrs); mvaddnwstr(y, x, wide, count); free(wide);
}
int32_t ccs_terminal_key(int milliseconds) {
    timeout(milliseconds); wint_t key = 0;
    int type = get_wch(&key);
    if (type == ERR) return CCS_TIMEOUT;
    if (type != KEY_CODE_YES) return (int32_t)key;
    switch (key) {
        case KEY_UP: return CCS_UP; case KEY_DOWN: return CCS_DOWN;
        case KEY_LEFT: return CCS_LEFT; case KEY_RIGHT: return CCS_RIGHT;
        case KEY_PPAGE: return CCS_PAGE_UP; case KEY_NPAGE: return CCS_PAGE_DOWN;
        case KEY_HOME: return CCS_HOME; case KEY_END: return CCS_END;
        case KEY_ENTER: return 10; case KEY_BACKSPACE: return 127;
        case KEY_RESIZE: return CCS_RESIZE; default: return CCS_TIMEOUT;
    }
}
