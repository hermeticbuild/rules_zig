#ifndef BOX_H
#define BOX_H

/* `box_value` is declared only when the translate step defines `BOX_ENABLED`
   (`defineCMacro`) and `BOX_SCALE` (`addCFlags`), so a working import proves
   both reach `translate-c`. */
#if defined(BOX_ENABLED) && BOX_SCALE == 2
int box_value(void);
#endif

/* Implemented by the `boxlib` system library the translation links. */
int boxlib_value(void);

#endif
