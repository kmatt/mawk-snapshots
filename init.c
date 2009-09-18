/********************************************
init.c
copyright 1991, Michael D. Brennan

This is a source file for mawk, an implementation of
the AWK programming language.

Mawk is distributed without warranty under the terms of
the GNU General Public License, version 2, 1991.
********************************************/

/*
 * $MawkId: init.c,v 1.12 2009/09/16 22:32:17 tom Exp $
 * @Log: init.c,v @
 * Revision 1.11  1995/08/20  17:35:21  mike
 * include <stdlib.h> for MSC, needed for environ decl
 *
 * Revision 1.10  1995/06/09  22:51:50  mike
 * silently exit(0) if no program
 *
 * Revision 1.9  1995/06/06  00:18:30  mike
 * change mawk_exit(1) to mawk_exit(2)
 *
 * Revision 1.8  1994/12/14  14:40:34  mike
 * -Wi option
 *
 * Revision 1.7  1994/12/11  22:43:20  mike
 * don't assume **environ is writable
 *
 * Revision 1.6  1994/12/11  22:14:16  mike
 * remove THINK_C #defines.  Not a political statement, just no indication
 * that anyone ever used it.
 *
 * Revision 1.5  1994/10/08  19:15:45  mike
 * remove SM_DOS
 *
 * Revision 1.4  1994/03/11  02:23:49  mike
 * -We option
 *
 * Revision 1.3  1993/07/17  00:45:14  mike
 * indent
 *
 * Revision 1.2	 1993/07/04  12:52:00  mike
 * start on autoconfig changes
 *
 * Revision 5.5	 1993/01/07  02:50:33  mike
 * relative vs absolute code
 *
 * Revision 5.4	 1992/12/24  01:58:19  mike
 * 1.1.2d changes for MsDOS
 *
 * Revision 5.3	 1992/07/10  16:17:10  brennan
 * MsDOS: remove NO_BINMODE macro
 *
 * Revision 5.2	 1992/01/09  08:46:14  brennan
 * small change for MSC
 *
 * Revision 5.1	 91/12/05  07:56:07  brennan
 * 1.1 pre-release
 *
*/

/* init.c */
#include "mawk.h"
#include "code.h"
#include "memory.h"
#include "symtype.h"
#include "init.h"
#include "bi_vars.h"
#include "field.h"
#include <stdlib.h>

#include <ctype.h>

#ifdef MSDOS
#include <fcntl.h>
#ifdef MSDOS_MSC
#include <stdlib.h>
#endif
#endif

static void process_cmdline(int, char **);
static void set_ARGV(int, char **, int);
static void bad_option(char *);
static void no_program(void);

#ifdef  MSDOS
void stdout_init(void);
#if  HAVE_REARGV
void reargv(int *, char ***);
#endif
#endif

char *progname;
short interactive_flag = 0;

#ifndef	 SET_PROGNAME
#define	 SET_PROGNAME() \
   {char *p = strrchr(argv[0],'/') ;\
    progname = p ? p+1 : argv[0] ; }
#endif

void
initialize(int argc, char **argv)
{

    SET_PROGNAME();

    bi_vars_init();		/* load the builtin variables */
    bi_funct_init();		/* load the builtin functions */
    kw_init();			/* load the keywords */
    field_init();

#ifdef   MSDOS
    {
	char *p = getenv("MAWKBINMODE");

	if (p)
	    set_binmode(atoi(p));
    }
#endif

    process_cmdline(argc, argv);

    code_init();
    fpe_init();
    set_stderr();

#ifdef  MSDOS
    stdout_init();
#endif
}

int dump_code_flag;		/* if on dump internal code */
short posix_space_flag;

#ifdef	 DEBUG
int dump_RE = 1;		/* if on dump compiled REs  */
#endif

static void
bad_option(char *s)
{
    errmsg(0, "not an option: %s", s);
    mawk_exit(2);
}

static void
no_program(void)
{
    mawk_exit(0);
}

static void
process_cmdline(int argc, char **argv)
{
    int i, nextarg;
    char *optArg;
    PFILE dummy;		/* starts linked list of filenames */
    PFILE *tail = &dummy;
    unsigned length;

    for (i = 1; i < argc && argv[i][0] == '-'; i = nextarg) {
	if (argv[i][1] == 0)	/* -  alone */
	{
	    if (!pfile_name)
		no_program();
	    break;		/* the for loop */
	}
	/* safe to look at argv[i][2] */

	/*
	 * Check for "long" options and decide how to handle them.
	 */
	if (strlen(argv[i]) > 2 && !strncmp(argv[i], "--", 2)) {
	    char *env = getenv("MAWK_LONG_OPTIONS");
	    if (env != 0) {
		switch (*env) {
		default:
		case 'e':	/* error */
		    bad_option(argv[i]);
		    break;
		case 'w':	/* warn */
		    errmsg(0, "ignored option: %s", argv[i]);
		    break;
		case 'i':	/* ignore */
		    break;
		}
	    } else {
		bad_option(argv[i]);
	    }
	    nextarg = i + 1;
	    continue;
	}

	if (argv[i][2] == 0) {
	    if (i == argc - 1 && argv[i][1] != '-') {
		if (strchr("WFvf", argv[i][1])) {
		    errmsg(0, "option %s lacks argument", argv[i]);
		    mawk_exit(2);
		}
		bad_option(argv[i]);
	    }

	    optArg = argv[i + 1];
	    nextarg = i + 2;
	} else {		/* argument glued to option */
	    optArg = &argv[i][2];
	    nextarg = i + 1;
	}

	switch (argv[i][1]) {
	case 'W':

	    if (isalpha((UChar) optArg[0]))
		optArg[0] = (char) toupper((UChar) optArg[0]);
	    if (optArg[0] == 'V')
		print_version();
	    else if (optArg[0] == 'D') {
		dump_code_flag = 1;
	    } else if (optArg[0] == 'S') {
		char *p = strchr(optArg, '=');
		int x = p ? atoi(p + 1) : 0;

		if (x > (int) SPRINTF_SZ) {
		    sprintf_buff = (char *) zmalloc((unsigned) x);
		    sprintf_limit = sprintf_buff + x;
		}
	    }
#ifdef  MSDOS
	    else if (optArg[0] == 'B') {
		char *p = strchr(optArg, '=');
		int x = p ? atoi(p + 1) : 0;

		set_binmode(x);
	    }
#endif
	    else if (optArg[0] == 'P') {
		posix_space_flag = 1;
	    } else if (optArg[0] == 'E') {
		if (pfile_name) {
		    errmsg(0, "-W exec is incompatible with -f");
		    mawk_exit(2);
		} else if (nextarg == argc)
		    no_program();

		pfile_name = argv[nextarg];
		i = nextarg + 1;
		goto no_more_opts;
	    } else if (optArg[0] == 'I') {
		interactive_flag = 1;
		setbuf(stdout, (char *) 0);
	    } else
		errmsg(0, "vacuous option: -W %s", optArg);

	    break;

	case 'v':
	    if (!is_cmdline_assign(optArg)) {
		errmsg(0, "improper assignment: -v %s", optArg);
		mawk_exit(2);
	    }
	    break;

	case 'F':

	    rm_escape(optArg, &length);		/* recognize escape sequences */
	    cell_destroy(FS);
	    FS->type = C_STRING;
	    FS->ptr = (PTR) new_STRING1(optArg, length);
	    cast_for_split(cellcpy(&fs_shadow, FS));
	    break;

	case '-':
	    if (argv[i][2] != 0)
		bad_option(argv[i]);
	    i++;
	    goto no_more_opts;

	case 'f':
	    /* first file goes in pfile_name ; any more go
	       on a list */
	    if (!pfile_name)
		pfile_name = optArg;
	    else {
		tail = tail->link = ZMALLOC(PFILE);
		tail->fname = optArg;
	    }
	    break;

	default:
	    bad_option(argv[i]);
	}
    }

  no_more_opts:

    tail->link = (PFILE *) 0;
    pfile_list = dummy.link;

    if (pfile_name) {
	set_ARGV(argc, argv, i);
	scan_init((char *) 0);
    } else {			/* program on command line */
	if (i == argc)
	    no_program();
	set_ARGV(argc, argv, i + 1);

#if  defined(MSDOS) && ! HAVE_REARGV	/* reversed quotes */
	{
	    char *p;

	    for (p = argv[i]; *p; p++)
		if (*p == '\'')
		    *p = '\"';
	}
#endif
	scan_init(argv[i]);
/* #endif  */
    }
}

   /* argv[i] = ARGV[i] */
static void
set_ARGV(int argc, char **argv, int i)
{
    SYMTAB *st_p;
    CELL argi;
    register CELL *cp;

    st_p = insert("ARGV");
    st_p->type = ST_ARRAY;
    Argv = st_p->stval.array = new_ARRAY();
    argi.type = C_DOUBLE;
    argi.dval = 0.0;
    cp = array_find(st_p->stval.array, &argi, CREATE);
    cp->type = C_STRING;
    cp->ptr = (PTR) new_STRING(progname);

    /* ARGV[0] is set, do the rest
       The type of ARGV[1] ... should be C_MBSTRN
       because the user might enter numbers from the command line */

    for (argi.dval = 1.0; i < argc; i++, argi.dval += 1.0) {
	cp = array_find(st_p->stval.array, &argi, CREATE);
	cp->type = C_MBSTRN;
	cp->ptr = (PTR) new_STRING(argv[i]);
    }
    ARGC->type = C_DOUBLE;
    ARGC->dval = argi.dval;
}

/*----- ENVIRON ----------*/

#ifndef	 MSDOS_MSC		/* MSC declares it near */
extern char **environ;
#endif

void
load_environ(ARRAY ENV)
{
    CELL c;
    register char **p = environ;	/* walks environ */
    char *s;			/* looks for the '=' */
    CELL *cp;			/* pts at ENV[&c] */

    c.type = C_STRING;

    while (*p) {
	if ((s = strchr(*p, '='))) {	/* shouldn't fail */
	    unsigned len = (unsigned) (s - *p);
	    c.ptr = (PTR) new_STRING0(len);
	    memcpy(string(&c)->str, *p, len);
	    s++;

	    cp = array_find(ENV, &c, CREATE);
	    cp->type = C_MBSTRN;
	    cp->ptr = (PTR) new_STRING(s);

	    free_STRING(string(&c));
	}
	p++;
    }
}
