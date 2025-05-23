/*
regexp_system.c
copyright 2009-2020,2024, Thomas E. Dickey
copyright 2005, Aleksey Cheusov

This is a source file for mawk, an implementation of
the AWK programming language.

Mawk is distributed without warranty under the terms of
the GNU General Public License, version 2, 1991.
 */

/* $MawkId: regexp.c,v 1.17 2024/12/31 15:13:35 tom Exp $ */

#include <config.h>

#define Visible_CELL

#ifdef LOCAL_REGEXP
#define REGEXP_INTERNALS
#define Visible_MACHINE
#define Visible_RE_DATA
#define Visible_RT_POS_ENTRY
#define Visible_RT_STATE
#define Visible_STATE
#		include <mawk.h>

#define RE_FILL() do { TRACE2((rt_form "refill...\n", rt_args)); goto refill; } while (0)
#define RE_CASE() do { goto reswitch; } while (0)

#define rt_form "[%s@%d] %d:%03d "
#define rt_args __FILE__, __LINE__, \
		(int)(run_entry - RE_run_stack_base), \
		(int)(m - machine)

#define TR_AT(what) \
	TRACE2((rt_form "%s\n", rt_args, what))

#		include <rexp.c>
#		include <rexpdb.c>
#		include <rexp0.c>
#		include <rexp1.c>
#		include <rexp2.c>
#		include <rexp3.c>
#else
#define Visible_RE_DATA
#define Visible_RE_NODE
#define Visible_STRING
#		include <regexp_system.c>
#		include <rexp4.c>
#endif

#ifdef NO_LEAKS
void
rexp_leaks(void)
{
    TRACE(("rexp_leaks\n"));
#ifdef LOCAL_REGEXP
    lookup_cclass(0);
    if (bv_base) {
	BV **p = bv_base;
	while (p != bv_next) {
	    RE_free(*p);
	    ++p;
	}
	RE_free(bv_base);
	bv_base = 0;
	bv_limit = 0;
	bv_next = 0;
    }
    if (RE_run_stack_base) {
	RE_free(RE_run_stack_base);
	RE_run_stack_base = 0;
    }
    if (RE_pos_stack_base) {
	RE_free(RE_pos_stack_base);
	RE_pos_stack_base = 0;
    }
#endif
}
#endif
