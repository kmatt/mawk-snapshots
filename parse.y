/********************************************
parse.y
copyright 2008-2023,2024, Thomas E. Dickey
copyright 1991-1994,1995, Michael D. Brennan

This is a source file for mawk, an implementation of
the AWK programming language.

Mawk is distributed without warranty under the terms of
the GNU General Public License, version 2, 1991.
********************************************/

/*
 * $MawkId: parse.y,v 1.42 2024/12/14 12:55:59 tom Exp $
 */

%{

#define Visible_ARG2_REC
#define Visible_ARRAY
#define Visible_BI_REC
#define Visible_CA_REC
#define Visible_CELL
#define Visible_CODEBLOCK
#define Visible_DEFER_LEN
#define Visible_FCALL_REC
#define Visible_FBLOCK
#define Visible_SYMTAB

#include <mawk.h>
#include <symtype.h>
#include <code.h>
#include <memory.h>
#include <bi_funct.h>
#include <bi_vars.h>
#include <jmp.h>
#include <field.h>
#include <files.h>

#define YYMAXDEPTH 200

#if defined(YYBYACC) && (YYBYACC < 2)
extern int yylex(void);
#endif

extern void eat_nl(void);

static SYMTAB *save_arglist(const char *);
static int init_arglist(void);
static void RE_as_arg(void);
static void check_array(SYMTAB *);
static void check_var(SYMTAB *);
static void code_array(SYMTAB *);
static void code_call_id(CA_REC *, SYMTAB *);
static void field_A2I(void);
static void free_arglist(void);
static void improve_arglist(const char *);
static void resize_fblock(FBLOCK *);
static void switch_code_to_main(void);

static int scope;
static FBLOCK *active_funct;
static CA_REC *active_arglist;
      /* when scope is SCOPE_FUNCT  */

#define  code_address(x)  if( is_local(x) ) \
                             code2op(L_PUSHA, (x)->offset) ;\
                          else  code2(_PUSHA, (x)->stval.cp)

#define  CDP(x)  (code_base+(x))
/* WARNING: These CDP() calculations become invalid after calls
   that might change code_base.  Which are:  code2(), code2op(),
   code_jmp() and code_pop().
*/

/* this nonsense caters to MSDOS large model */
#define  CODE_FE_PUSHA()  code_ptr->ptr = (PTR) 0 ; code1(FE_PUSHA)

%}

%union{
  CELL     *cp ;
  SYMTAB   *stp ;
  int      start ;   /* code starting address as offset from code_base */
  PF_CP    fp ;      /* ptr to a (print/printf) or (sub/gsub) function */
  const BI_REC *bip ; /* ptr to info about a builtin */
  FBLOCK   *fbp  ;   /* ptr to a function block */
  ARG2_REC *arg2p ;
  CA_REC   *ca_p  ;
  int      ival ;
  PTR      ptr ;
}

/*  two tokens to help with errors */
%token   UNEXPECTED   /* unexpected character */
%token   BAD_DECIMAL

%token   NL
%token   SEMI_COLON
%token   LBRACE  RBRACE
%token   LBOX     RBOX
%token   COMMA
%token   <ival> IO_OUT    /* > or output pipe */

%right  ASSIGN  ADD_ASG SUB_ASG MUL_ASG DIV_ASG MOD_ASG POW_ASG
%right  QMARK COLON
%left   OR
%left   AND
%left   IN
%left   <ival> MATCH   /* ~  or !~ */
%left   EQ  NEQ  LT LTE  GT  GTE
%left   CAT
%left   GETLINE
%left   PLUS      MINUS
%left   MUL      DIV    MOD
%left   NOT   UMINUS
%nonassoc   IO_IN PIPE
%right  POW
%left   <ival>   INC_or_DEC
%left   DOLLAR    FIELD  /* last to remove a SR conflict
                                with getline */
%right  LPAREN   RPAREN     /* removes some SR conflicts */

%token  <ptr> DOUBLE STRING_ RE
%token  <stp> ID   D_ID
%token  <fbp> FUNCT_ID
%token  <bip> BUILTIN  LENGTH
%token  <cp>  FIELD

%token  PRINT PRINTF SPLIT MATCH_FUNC SUB GSUB
/* keywords */
%token  DO WHILE FOR BREAK CONTINUE IF ELSE  IN
%token  DELETE  BEGIN  END  EXIT NEXT NEXTFILE RETURN  FUNCTION

%type <start>  block  block_or_separator
%type <start>  statement_list statement mark
%type <ival>   pr_args
%type <arg2p>  arg2
%type <start>  builtin
%type <start>  getline_file
%type <start>  lvalue field  fvalue
%type <start>  expr cat_expr p_expr
%type <start>  while_front  if_front
%type <start>  for1 for2
%type <start>  array_loop_front
%type <start>  return_statement
%type <start>  split_front  re_arg sub_back
%type <ival>   arglist args
%type <fp>     print   sub_or_gsub
%type <fbp>    funct_start funct_head
%type <ca_p>   call_args ca_front ca_back
%type <ival>   f_arglist f_args

%%
/*  productions  */

program :       program_block
        |       program  program_block
        ;

program_block :  PA_block   /* pattern-action */
              |  function_def
              |  outside_error block
              ;

PA_block  :  block
             { /* this do nothing action removes a vacuous warning
                  from Bison */
             }

          |  BEGIN
                { scope = SCOPE_BEGIN ; be_setup(scope) ; }

             block
                { switch_code_to_main() ; }

          |  END
                { scope = SCOPE_END ; be_setup(scope) ; }

             block
                { switch_code_to_main() ; }

          |  expr  /* this works just like an if statement */
             { code_jmp(_JZ, (INST*)0) ; }

             block_or_separator
             { patch_jmp( code_ptr ) ; }

    /* range pattern, see comment in execute.c near _RANGE */
          |  expr COMMA
             {
               INST *p1 = CDP($1) ;
             int len ;

               code_push(p1, (unsigned) CodeOffset(p1), scope, active_funct) ;
               code_ptr = p1 ;

               code2op(_RANGE, 1) ;
               code_ptr += 3 ;
               len = (int) code_pop(code_ptr) ;
             code_ptr += len ;
               code1(_STOP) ;
             p1 = CDP($1) ;
               p1[2].op = CodeOffset(p1 + 1) ;
             }
             expr
             { code1(_STOP) ; }

             block_or_separator
             {
               INST *p1 = CDP($1) ;

               p1[3].op = (int) (CDP($6) - (p1 + 1)) ;
               p1[4].op = CodeOffset(p1 + 1) ;
             }
          ;



block   :  LBRACE   statement_list  RBRACE
            { $$ = $2 ; }
        |  LBRACE   error  RBRACE
            { $$ = code_offset ; /* does nothing won't be executed */
              print_flag = getline_flag = paren_cnt = 0 ;
              yyerrok ; }
        ;

block_or_separator  :  block
                  |  separator     /* default print action */
                     { $$ = code_offset ;
                       code1(_PUSHINT) ; code1(0) ;
                       func2(_PRINT, bi_print) ;
                     }
        ;

statement_list :  statement
        |  statement_list   statement
        ;


statement :  block
          |  expr   separator
             { code1(_POP) ; }
          |  /* empty */  separator
             { $$ = code_offset ; }
          |  error  separator
              { $$ = code_offset ;
                print_flag = getline_flag = 0 ;
                paren_cnt = 0 ;
                yyerrok ;
              }
          |  BREAK  separator
             { $$ = code_offset ; BC_insert('B', code_ptr+1) ;
               code2(_JMP, 0) /* don't use code_jmp ! */ ; }
          |  CONTINUE  separator
             { $$ = code_offset ; BC_insert('C', code_ptr+1) ;
               code2(_JMP, 0) ; }
          |  return_statement
             { if ( scope != SCOPE_FUNCT )
                     compile_error("return outside function body") ;
             }
          |  NEXT  separator
              { if ( scope != SCOPE_MAIN )
                   compile_error( "improper use of next" ) ;
                $$ = code_offset ;
                code1(_NEXT) ;
              }
          |  NEXTFILE  separator
              { if ( scope != SCOPE_MAIN )
                   compile_error( "improper use of nextfile" ) ;
                $$ = code_offset ;
                code1(_NEXTFILE) ;
              }
          ;

separator  :  NL | SEMI_COLON
           ;

expr  :   cat_expr
      |   lvalue   ASSIGN   expr { code1(_ASSIGN) ; }
      |   lvalue   ADD_ASG  expr { code1(_ADD_ASG) ; }
      |   lvalue   SUB_ASG  expr { code1(_SUB_ASG) ; }
      |   lvalue   MUL_ASG  expr { code1(_MUL_ASG) ; }
      |   lvalue   DIV_ASG  expr { code1(_DIV_ASG) ; }
      |   lvalue   MOD_ASG  expr { code1(_MOD_ASG) ; }
      |   lvalue   POW_ASG  expr { code1(_POW_ASG) ; }
      |   expr EQ expr  { code1(_EQ) ; }
      |   expr NEQ expr { code1(_NEQ) ; }
      |   expr LT expr { code1(_LT) ; }
      |   expr LTE expr { code1(_LTE) ; }
      |   expr GT expr { code1(_GT) ; }
      |   expr GTE expr { code1(_GTE) ; }

      |   expr MATCH expr
          {
            INST *p3 = CDP($3) ;

            if ( p3 == code_ptr - 2 )
            {
               if ( p3->op == _MATCH0 )  p3->op = _MATCH1 ;

               else /* check for string */
               if ( p3->op == _PUSHS )
               { CELL *cp = ZMALLOC(CELL) ;

                 cp->type = C_STRING ;
                 cp->ptr = p3[1].ptr ;
                 cast_to_RE(cp) ;
                 no_leaks_re_ptr(cp->ptr) ;
                 code_ptr -= 2 ;
                 code2(_MATCH1, cp->ptr) ;
                 ZFREE(cp) ;
               }
               else  code1(_MATCH2) ;
            }
            else code1(_MATCH2) ;

            if ( !$2 ) code1(_NOT) ;
          }

/* short circuit boolean evaluation */
      |   expr  OR
              { code1(_TEST) ;
                code_jmp(_LJNZ, (INST*)0) ;
              }
          expr
          { code1(_TEST) ; patch_jmp(code_ptr) ; }

      |   expr AND
              { code1(_TEST) ;
                code_jmp(_LJZ, (INST*)0) ;
              }
          expr
              { code1(_TEST) ; patch_jmp(code_ptr) ; }

      |  expr QMARK  { code_jmp(_JZ, (INST*)0) ; }
         expr COLON  { code_jmp(_JMP, (INST*)0) ; }
         expr
         { patch_jmp(code_ptr) ; patch_jmp(CDP($7)) ; }
      ;

cat_expr :  p_expr             %prec CAT
         |  cat_expr  p_expr   %prec CAT
            { code1(_CAT) ; }
         ;

p_expr  :   DOUBLE
          {  $$ = code_offset ; code2(_PUSHD, $1) ; }
      |   STRING_
          { $$ = code_offset ; code2(_PUSHS, $1) ; }
      |   ID   %prec AND /* anything less than IN */
          { check_var($1) ;
            $$ = code_offset ;
            if ( is_local($1) )
            { code2op(L_PUSHI, $1->offset) ; }
            else code2(_PUSHI, $1->stval.cp) ;
          }

      |   LPAREN   expr  RPAREN
          { $$ = $2 ; }
      ;

p_expr  :   RE
            { $$ = code_offset ;
              code2(_MATCH0, $1) ;
              no_leaks_re_ptr($1);
            }
        ;

p_expr  :   p_expr  PLUS   p_expr { code1(_ADD) ; }
      |   p_expr MINUS  p_expr { code1(_SUB) ; }
      |   p_expr  MUL   p_expr { code1(_MUL) ; }
      |   p_expr  DIV  p_expr { code1(_DIV) ; }
      |   p_expr  MOD  p_expr { code1(_MOD) ; }
      |   p_expr  POW  p_expr { code1(_POW) ; }
      |   NOT  p_expr
                { $$ = $2 ; code1(_NOT) ; }
      |   PLUS p_expr  %prec  UMINUS
                { $$ = $2 ; code1(_UPLUS) ; }
      |   MINUS p_expr %prec  UMINUS
                { $$ = $2 ; code1(_UMINUS) ; }
      |   builtin
      ;

p_expr  :  ID  INC_or_DEC
           { check_var($1) ;
             $$ = code_offset ;
             code_address($1) ;

             if ( $2 == '+' )  code1(_POST_INC) ;
             else  code1(_POST_DEC) ;
           }
        |  INC_or_DEC  lvalue
            { $$ = $2 ;
              if ( $1 == '+' ) code1(_PRE_INC) ;
              else  code1(_PRE_DEC) ;
            }
        ;

p_expr  :  field  INC_or_DEC
           { if ($2 == '+' ) code1(F_POST_INC ) ;
             else  code1(F_POST_DEC) ;
           }
        |  INC_or_DEC  field
           { $$ = $2 ;
             if ( $1 == '+' ) code1(F_PRE_INC) ;
             else  code1( F_PRE_DEC) ;
           }
        ;

lvalue :  ID
        { $$ = code_offset ;
          check_var($1) ;
          code_address($1) ;
        }
       ;


arglist :  /* empty */
            { $$ = 0 ; }
        |  args
        ;

args    :  expr        %prec  LPAREN
            { $$ = 1 ; }
        |  args  COMMA  expr
            { $$ = $1 + 1 ; }
        ;

builtin :
        BUILTIN mark  LPAREN  arglist RPAREN
        { const BI_REC *p = $1 ;
          $$ = $2 ;
          if ( (int)p->min_args > $4 )
              compile_error(
                  "not enough arguments in call to %s: %d (need %d)" ,
                  p->name, $4, (int)p->min_args ) ;
          if ( (int)p->max_args < $4 )
              compile_error(
                  "too many arguments in call to %s: %d (maximum %d)" ,
                  p->name, $4, (int)p->max_args ) ;
          if ( p->min_args != p->max_args ) /* variable args */
              { code1(_PUSHINT) ;  code1($4) ; }
          func2(_BUILTIN , p->fp) ;
        }
        ;

/* an empty production to store the code_ptr */
mark : /* empty */
         { $$ = code_offset ; }
        ;

/* print_statement */
statement :  print mark pr_args pr_direction separator
            { func2(_PRINT, $1) ;
              if ( $3 > MAX_ARGS )
                  compile_error("too many arguments in call to %s: %d (maximum %d)",
                      ( $1 == bi_printf ) ? "printf" : "print",
                      $3, MAX_ARGS) ;
              if ( $1 == bi_printf && $3 == 0 )
                  compile_error("no arguments in call to printf") ;
              print_flag = 0 ;
              $$ = $2 ;
            }
            ;

print   :  PRINT  { $$ = bi_print ; print_flag = 1 ;}
        |  PRINTF { $$ = bi_printf ; print_flag = 1 ; }
        ;

pr_args :  arglist { code2op(_PUSHINT, $1) ; }
        |  LPAREN  arg2 RPAREN
           { $$ = $2->cnt ; zfree($2,sizeof(ARG2_REC)) ;
             code2op(_PUSHINT, $$) ;
           }
        |  LPAREN  RPAREN
           { $$=0 ; code2op(_PUSHINT, 0) ; }
        ;

arg2   :   expr  COMMA  expr
           { $$ = ZMALLOC(ARG2_REC) ;
             $$->start = $1 ;
             $$->cnt = 2 ;
           }
        |   arg2 COMMA  expr
            { $$ = $1 ; $$->cnt++ ; }
        ;

pr_direction : /* empty */
             |  IO_OUT  expr
                { code2op(_PUSHINT, $1) ; }
             ;


/*  IF and IF-ELSE */

if_front :  IF LPAREN expr RPAREN
            {  $$ = $3 ; eat_nl() ; code_jmp(_JZ, (INST*)0) ; }
         ;

/* if_statement */
statement : if_front statement
                { patch_jmp( code_ptr ) ;  }
              ;

else_back    :  ELSE { eat_nl() ; code_jmp(_JMP, (INST*)0) ; }
        ;

/* if_else_statement */
statement :  if_front statement else_back statement
                { patch_jmp(code_ptr) ;
                  patch_jmp(CDP($4)) ;
                }
        ;


/*  LOOPS   */

do      :  DO
        { eat_nl() ; BC_new() ; }
        ;

/* do_statement */
statement : do statement WHILE LPAREN expr RPAREN separator
        { $$ = $2 ;
          code_jmp(_JNZ, CDP($2)) ;
          BC_clear(code_ptr, CDP($5)) ; }
        ;

while_front :  WHILE LPAREN expr RPAREN
                { eat_nl() ; BC_new() ;
                  $$ = $3 ;

                  /* check if const expression */
                  if ( code_ptr - 2 == CDP($3) &&
                       code_ptr[-2].op == _PUSHD &&
                       *(double*)code_ptr[-1].ptr != 0.0
                     )
                     code_ptr -= 2 ;
                  else
                  { INST *p3 = CDP($3) ;
                    code_push(p3, (unsigned) CodeOffset(p3), scope, active_funct) ;
                    code_ptr = p3 ;
                    code2(_JMP, (INST*)0) ; /* code2() not code_jmp() */
                  }
                }
            ;

/* while_statement */
statement  :    while_front  statement
                {
                  INST *p1 = CDP($1) ;
                  INST *p2 = CDP($2) ;

                  if ( p1 != p2 )  /* real test in loop */
                  {
                    int  saved_offset ;
                    int len ;

                    p1[1].op = CodeOffset(p1 + 1) ;
                    saved_offset = code_offset ;
                    len = (int) code_pop(code_ptr) ;
                    code_ptr += len ;
                    code_jmp(_JNZ, CDP($2)) ;
                    BC_clear(code_ptr, CDP(saved_offset)) ;
                  }
                  else /* while(1) */
                  {
                    code_jmp(_JMP, p1) ;
                    BC_clear(code_ptr, CDP($2)) ;
                  }
                }
                ;


/* for_statement */
statement   :   for1 for2 for3 statement
                {
                  int cont_offset = code_offset ;
                  unsigned len = code_pop(code_ptr) ;
                  INST *p2 = CDP($2) ;
                  INST *p4 = CDP($4) ;

                  code_ptr += len ;

                  if ( p2 != p4 )  /* real test in for2 */
                  {
                    p4[-1].op = CodeOffset(p4 - 1) ;
                    len = code_pop(code_ptr) ;
                    code_ptr += len ;
                    code_jmp(_JNZ, CDP($4)) ;
                  }
                  else /*  for(;;) */
                  code_jmp(_JMP, p4) ;

                  BC_clear(code_ptr, CDP(cont_offset)) ;

                }
              ;

for1    :  FOR LPAREN  SEMI_COLON   { $$ = code_offset ; }
        |  FOR LPAREN  expr SEMI_COLON
           { $$ = $3 ; code1(_POP) ; }
        ;

for2    :  SEMI_COLON   { $$ = code_offset ; }
        |  expr  SEMI_COLON
           {
             if ( code_ptr - 2 == CDP($1) &&
                  code_ptr[-2].op == _PUSHD &&
                  * (double*) code_ptr[-1].ptr != 0.0
                )
                    code_ptr -= 2 ;
             else
             {
               INST *p1 = CDP($1) ;
               code_push(p1, (unsigned) CodeOffset(p1), scope, active_funct) ;
               code_ptr = p1 ;
               code2(_JMP, (INST*)0) ;
             }
           }
        ;

for3    :  RPAREN
           { eat_nl() ; BC_new() ;
             code_push((INST*)0,0, scope, active_funct) ;
           }
        |  expr RPAREN
           { INST *p1 = CDP($1) ;

             eat_nl() ; BC_new() ;
             code1(_POP) ;
             code_push(p1, (unsigned) CodeOffset(p1), scope, active_funct) ;
             code_ptr -= code_ptr - p1 ;
           }
        ;


/* arrays  */

expr    :  expr IN  ID
           { check_array($3) ;
             code_array($3) ;
             code1(A_TEST) ;
            }
        |  LPAREN arg2 RPAREN IN ID
           { $$ = $2->start ;
             code2op(A_CAT, $2->cnt) ;
             zfree($2, sizeof(ARG2_REC)) ;

             check_array($5) ;
             code_array($5) ;
             code1(A_TEST) ;
           }
        ;

lvalue  :  ID mark LBOX  args  RBOX
           {
             if ( $4 > 1 )
             { code2op(A_CAT, $4) ; }

             check_array($1) ;
             if( is_local($1) )
             { code2op(LAE_PUSHA, $1->offset) ; }
             else code2(AE_PUSHA, $1->stval.array) ;
             $$ = $2 ;
           }
        ;

p_expr  :  ID mark LBOX  args  RBOX   %prec  AND
           {
             if ( $4 > 1 )
             { code2op(A_CAT, $4) ; }

             check_array($1) ;
             if( is_local($1) )
             { code2op(LAE_PUSHI, $1->offset) ; }
             else code2(AE_PUSHI, $1->stval.array) ;
             $$ = $2 ;
           }

        |  ID mark LBOX  args  RBOX  INC_or_DEC
           {
             if ( $4 > 1 )
             { code2op(A_CAT,$4) ; }

             check_array($1) ;
             if( is_local($1) )
             { code2op(LAE_PUSHA, $1->offset) ; }
             else code2(AE_PUSHA, $1->stval.array) ;
             if ( $6 == '+' )  code1(_POST_INC) ;
             else  code1(_POST_DEC) ;

             $$ = $2 ;
           }
        ;

/* delete A[i] or delete A */
statement :  DELETE  ID mark LBOX args RBOX separator
             {
               $$ = $3 ;
               if ( $5 > 1 ) { code2op(A_CAT, $5) ; }
               check_array($2) ;
               code_array($2) ;
               code1(A_DEL) ;
             }
          |  DELETE ID separator
             {
                $$ = code_offset ;
                check_array($2) ;
                code_array($2) ;
                code1(DEL_A) ;
             }
          ;

/*  for ( i in A )  statement */

array_loop_front :  FOR LPAREN ID IN ID RPAREN
                    { eat_nl() ; BC_new() ;
                      $$ = code_offset ;

                      check_var($3) ;
                      code_address($3) ;
                      check_array($5) ;
                      code_array($5) ;

                      code2(SET_ALOOP, (INST*)0) ;
                    }
                 ;

/* array_loop */
statement  :  array_loop_front  statement
              {
                INST *p2 = CDP($2) ;

                p2[-1].op = CodeOffset(p2 - 1) ;
                BC_clear( code_ptr+2 , code_ptr) ;
                code_jmp(ALOOP, p2) ;
                code1(POP_AL) ;
              }
           ;

/*  fields
    D_ID is a special token , same as an ID, but yylex()
    only returns it after a '$'.  In essence,
    DOLLAR D_ID is really one token.
*/

field   :  FIELD
           { $$ = code_offset ; code2(F_PUSHA, $1) ; }
        |  DOLLAR  D_ID
           { check_var($2) ;
             $$ = code_offset ;
             if ( is_local($2) )
             { code2op(L_PUSHI, $2->offset) ; }
             else code2(_PUSHI, $2->stval.cp) ;

             CODE_FE_PUSHA() ;
           }
        |  DOLLAR  D_ID mark LBOX  args RBOX
           {
             if ( $5 > 1 )
             { code2op(A_CAT, $5) ; }

             check_array($2) ;
             if( is_local($2) )
             { code2op(LAE_PUSHI, $2->offset) ; }
             else code2(AE_PUSHI, $2->stval.array) ;

             CODE_FE_PUSHA()  ;

             $$ = $3 ;
           }
        |  DOLLAR p_expr
           { $$ = $2 ;  CODE_FE_PUSHA() ; }
        |  LPAREN field RPAREN
           { $$ = $2 ; }
        ;

p_expr   :  field   %prec CAT /* removes field (++|--) sr conflict */
            { field_A2I() ; }
        ;

expr    :  field   ASSIGN   expr { code1(F_ASSIGN) ; }
        |  field   ADD_ASG  expr { code1(F_ADD_ASG) ; }
        |  field   SUB_ASG  expr { code1(F_SUB_ASG) ; }
        |  field   MUL_ASG  expr { code1(F_MUL_ASG) ; }
        |  field   DIV_ASG  expr { code1(F_DIV_ASG) ; }
        |  field   MOD_ASG  expr { code1(F_MOD_ASG) ; }
        |  field   POW_ASG  expr { code1(F_POW_ASG) ; }
        ;

/* split is handled different than a builtin because
   it takes an array and optionally a regular expression as args */

p_expr  :   split_front  split_back
            { func2(_BUILTIN, bi_split) ; }
        ;

split_front : SPLIT LPAREN expr COMMA ID
            { $$ = $3 ;
              check_array($5) ;
              code_array($5)  ;
            }
            ;

split_back  :   RPAREN
                { code2(_PUSHI, &fs_shadow) ; }
            |   COMMA expr  RPAREN
                {
                  if ( CDP($2) == code_ptr - 2 )
                  {
                    if ( code_ptr[-2].op == _MATCH0 ) {
                        RE_as_arg() ;
                    }
                    else
                    if ( code_ptr[-2].op == _PUSHS )
                    { CELL *cp = ZMALLOC(CELL) ;

                      cp->type = C_STRING ;
                      cp->ptr = code_ptr[-1].ptr ;
                      cast_for_split(cp) ;
                      code_ptr[-2].op = _PUSHC ;
                      code_ptr[-1].ptr = (PTR) cp ;
                      no_leaks_cell(cp);
                    }
                  }
                }
            ;

/* distinguish length vs length(string) vs length(array) */
p_expr :  LENGTH LPAREN  RPAREN
          { $$ = code_offset ;
            code2(_PUSHI,field) ;
            func2(_BUILTIN,bi_length) ;
          }
       |  LENGTH LPAREN expr RPAREN
          { $$ = $3 ;
            func2(_BUILTIN,bi_length) ;
          }
       |  LENGTH LPAREN ID RPAREN
          {
              SYMTAB* stp = $3;
              $$ = code_offset;
              switch (stp->type) {
              case ST_VAR:
                  code2(_PUSHI, stp->stval.cp);
                  func2(_BUILTIN, bi_length);
                  break;

              case ST_ARRAY:
                  code2(A_PUSHA, stp->stval.array);
                  func2(_BUILTIN, bi_alength);
                  break;

              case ST_LOCAL_VAR:
                  code2op(L_PUSHI, stp->offset);
                  func2(_BUILTIN, bi_length);
                  break;

              case ST_LOCAL_ARRAY:
                  code2op(LA_PUSHA, stp->offset);
                  func2(_BUILTIN, bi_alength);
                  break;

              case ST_NONE:
                  /* defer_alen */
                  code2(A_LENGTH, stp);
                  func2(_BUILTIN, bi_length);
                  break;

              case ST_LOCAL_NONE:
                  /* defer_len */
                  {
                      DEFER_LEN* pi = ZMALLOC(DEFER_LEN);
                      pi->fbp = active_funct;
                      pi->offset = stp->offset;
                      code2(_LENGTH, pi);
                      func2(_BUILTIN, bi_length);
                  }
                  break;

              default:
                  type_error(stp);
                  break;
              }
          }
       ;
p_expr :  LENGTH %prec CAT /* fixes s/r conflict length vs length() */
          { $$ = code_offset ;
            code2(_PUSHI,field) ;
            func2(_BUILTIN,bi_length) ;
          }
       ;

/*  match(expr, RE) */

p_expr : MATCH_FUNC LPAREN expr COMMA re_arg RPAREN
        { $$ = $3 ;
          func2(_BUILTIN, bi_match) ;
        }
     ;


re_arg   :   expr
             {
               INST *p1 = CDP($1) ;

               if ( p1 == code_ptr - 2 )
               {
                 if ( p1->op == _MATCH0 ) RE_as_arg() ;
                 else
                 if ( p1->op == _PUSHS )
                 { CELL *cp = ZMALLOC(CELL) ;

                   cp->type = C_STRING ;
                   cp->ptr = p1[1].ptr ;
                   cast_to_RE(cp) ;
                   p1->op = _PUSHC ;
                   p1[1].ptr = (PTR) cp ;
                   no_leaks_cell(cp);
                 }
               }
             }
        ;


/* exit_statement */
statement      :  EXIT   separator
                    { $$ = code_offset ;
                      code1(_EXIT0) ; }
               |  EXIT   expr  separator
                    { $$ = $2 ; code1(_EXIT) ; }
        ;

return_statement :  RETURN   separator
                    { $$ = code_offset ;
                      code1(_RET0) ; }
               |  RETURN   expr  separator
                    { $$ = $2 ; code1(_RET) ; }
        ;

/* getline */

p_expr :  getline      %prec  GETLINE
          { $$ = code_offset ;
            code2(F_PUSHA, &field[0]) ;
            code1(_PUSHINT) ; code1(0) ;
            func2(_BUILTIN, bi_getline) ;
            getline_flag = 0 ;
          }
       |  getline  fvalue     %prec  GETLINE
          { $$ = $2 ;
            code1(_PUSHINT) ; code1(0) ;
            func2(_BUILTIN, bi_getline) ;
            getline_flag = 0 ;
          }
       |  getline_file  p_expr    %prec IO_IN
          { code1(_PUSHINT) ; code1(F_IN) ;
            func2(_BUILTIN, bi_getline) ;
            /* getline_flag already off in yylex() */
          }
       |  p_expr PIPE GETLINE
          { code2(F_PUSHA, &field[0]) ;
            code1(_PUSHINT) ; code1(PIPE_IN) ;
            func2(_BUILTIN, bi_getline) ;
          }
       |  p_expr PIPE GETLINE   fvalue
          {
            code1(_PUSHINT) ; code1(PIPE_IN) ;
            func2(_BUILTIN, bi_getline) ;
          }
       ;

getline :   GETLINE  { getline_flag = 1 ; } ;

fvalue  :   lvalue  |  field  ;

getline_file  :  getline  IO_IN
                 { $$ = code_offset ;
                   code2(F_PUSHA, field+0) ;
                 }
              |  getline fvalue IO_IN
                 { $$ = $2 ; }
              ;

/*==========================================
    sub and gsub
  ==========================================*/

p_expr  :  sub_or_gsub LPAREN re_arg COMMA  expr  sub_back
           {
             INST *p5 = CDP($5) ;
             INST *p6 = CDP($6) ;

             if ( p6 - p5 == 2 && p5->op == _PUSHS  )
             { /* cast from STRING to REPL at compile time */
               CELL *cp = ZMALLOC(CELL) ;
               cp->type = C_STRING ;
               cp->ptr = p5[1].ptr ;
               cast_to_REPL(cp) ;
               p5->op = _PUSHC ;
               p5[1].ptr = (PTR) cp ;
               no_leaks_cell(cp);
             }
             func2(_BUILTIN, $1) ;
             $$ = $3 ;
           }
        ;

sub_or_gsub :  SUB  { $$ = bi_sub ; }
            |  GSUB { $$ = bi_gsub ; }
            ;


sub_back    :   RPAREN    /* substitute into $0  */
                { $$ = code_offset ;
                  code2(F_PUSHA, &field[0]) ;
                }

            |   COMMA fvalue  RPAREN
                { $$ = $2 ; }
            ;

/*================================================
    user defined functions
 *=================================*/

function_def  :  funct_start  block
                 {
                   resize_fblock($1) ;
                   restore_ids() ;
                   switch_code_to_main() ;
                 }
              ;


funct_start   :  funct_head  LPAREN  f_arglist  RPAREN
                 { eat_nl() ;
                   scope = SCOPE_FUNCT ;
                   active_funct = $1 ;
                   *main_code_p = active_code ;

                   $1->nargs = (NUM_ARGS) $3 ;
                   if ( $3 )
                        $1->typev = (SYM_TYPE *)
                        memset( zmalloc((size_t) $3), ST_LOCAL_NONE, (size_t) $3) ;
                   else $1->typev = (SYM_TYPE *) 0 ;

                   code_ptr = code_base =
                       (INST *) zmalloc(INST_BYTES(PAGESZ));
                   code_limit = code_base + PAGESZ ;
                   code_warn = code_limit - CODEWARN ;
                   improve_arglist($1->name);
                   free_arglist();
                 }
              ;

funct_head    :  FUNCTION  ID
                 { FBLOCK  *fbp ;

                   if ( $2 == NULL )
                   {
                         compile_error("function definition") ;
                         mawk_exit(3);
                   }
                   if ( $2->type == ST_NONE )
                   {
                         $2->type = ST_FUNCT ;
                         fbp = $2->stval.fbp = ZMALLOC(FBLOCK) ;
                         fbp->name = $2->name ;
                         fbp->code = (INST*) 0 ;
                   }
                   else
                   {
                         type_error( $2 ) ;

                         /* this FBLOCK will not be put in
                            the symbol table */
                         fbp = ZMALLOC(FBLOCK) ;
                         fbp->name = "" ;
                   }
                   $$ = fbp ;
                 }

              |  FUNCTION  FUNCT_ID
                 { $$ = $2 ;
                   if ( $2->code )
                       compile_error("redefinition of %s" , $2->name) ;
                 }
              ;

f_arglist  :  /* empty */ { $$ = init_arglist() ; }
           |  f_args
           ;

f_args     :  ID
              { init_arglist();
                $1 = save_arglist($1->name) ;
                $1->offset = 0 ;
                $$ = 1 ;
              }
           |  f_args  COMMA  ID
              { if ( is_local($3) )
                  compile_error("%s is duplicated in argument list",
                    $3->name) ;
                else
                { $3 = save_arglist($3->name) ;
                  $3->offset = (unsigned char) $1 ;
                  $$ = $1 + 1 ;
                }
              }
           ;

outside_error :  error
                 {  /* we may have to recover from a bungled function
                       definition */
                   /* can have local ids, before code scope
                      changes  */
                    restore_ids() ;

                    switch_code_to_main() ;
                 }
             ;

/* a call to a user defined function */

p_expr  :  FUNCT_ID mark  call_args
           { $$ = $2 ;
             code2(_CALL, $1) ;

             if ( $3 )  code1($3->arg_num+1) ;
             else  code1(0) ;

             check_fcall($1, scope, code_move_level, active_funct, $3) ;
           }
        ;

call_args  :   LPAREN   RPAREN
               { $$ = (CA_REC *) 0 ; }
           |   ca_front  ca_back
               { $$ = $2 ;
                 $$->link = $1 ;
                 $$->arg_num = (NUM_ARGS) ($1 ? $1->arg_num+1 : 0) ;
                 $$->call_lineno = token_lineno;
               }
           ;

/* The funny definition of ca_front with the COMMA bound to the ID is to
   force a shift to avoid a reduce/reduce conflict
   ID->id or ID->array

   Or to avoid a decision, if the type of the ID has not yet been
   determined
*/

ca_front   :  LPAREN
              { $$ = (CA_REC *) 0 ; }
           |  ca_front  expr   COMMA
              { $$ = ZMALLOC(CA_REC) ;
                $$->link = $1 ;
                $$->type = CA_EXPR  ;
                $$->arg_num = (NUM_ARGS) ($1 ? $1->arg_num+1 : 0) ;
                $$->call_offset = code_offset ;
                $$->call_lineno = token_lineno;
              }
           |  ca_front  ID   COMMA
              { $$ = ZMALLOC(CA_REC) ;
                $$->type = ST_NONE ;
                $$->link = $1 ;
                $$->arg_num = (NUM_ARGS) ($1 ? $1->arg_num+1 : 0) ;
                $$->call_lineno = token_lineno;

                code_call_id($$, $2) ;
              }
           ;

ca_back    :  expr   RPAREN
              { $$ = ZMALLOC(CA_REC) ;
                $$->type = CA_EXPR ;
                $$->call_offset = code_offset ;
              }

           |  ID    RPAREN
              { $$ = ZMALLOC(CA_REC) ;
                $$->type = ST_NONE ;
                code_call_id($$, $1) ;
              }
           ;

%%

/*
 * Check for special case where there is a forward reference to a newly
 * declared function using an array parameter.  Because the parameter
 * mechanism for arrays uses a different byte code, we would like to know
 * if this is the case so that the function's contents can handle the array
 * type.
 */
static void
improve_arglist(const char *name)
{
    CA_REC *p, *p2;
    FCALL_REC *q;

    TRACE(("improve_arglist(%s)\n", name));
    for (p = active_arglist; p != NULL; p = p->link) {
	if (p->type == ST_LOCAL_NONE) {
	    for (q = resolve_list; q != NULL; q = q->link) {
		if (!strcmp(q->callee->name, name)) {
		    for (p2 = q->arg_list; p2 != NULL; p2 = p2->link) {
			if (p2->arg_num == p->arg_num) {
			    switch (p2->type) {
			    case ST_NONE:
			    case ST_LOCAL_NONE:
				break;
			    default:
				p->type = p2->type;
				p->sym_p->type = p2->type;
				TRACE(("...set arg %d of %s to %s\n",
				       p->arg_num + 1,
				       name,
				       type_to_str(p->type)));
				break;
			    }
			}
		    }
		    if (p->type != ST_LOCAL_NONE)
			break;
		}
	    }
	    if (p->type != ST_LOCAL_NONE)
		break;
	}
    }
}

/* maintain data for f_arglist to make it visible in funct_start */
static int
init_arglist(void)
{
    free_arglist();
    return 0;
}

static SYMTAB *
save_arglist(const char *s)
{
    SYMTAB *result = save_id(s);
    CA_REC *saveit = ZMALLOC(CA_REC);

    if (saveit != NULL) {
	CA_REC *p, *q;
	int arg_num = 0;

	for (p = active_arglist, q = NULL; p != NULL; q = p, p = p->link) {
	    ++arg_num;
	}

	saveit->link = NULL;
	saveit->type = ST_LOCAL_NONE;
	saveit->arg_num = (NUM_ARGS) arg_num;
	saveit->call_lineno = token_lineno;
	saveit->sym_p = result;

	if (q != NULL) {
	    q->link = saveit;
	} else {
	    active_arglist = saveit;
	}
    }

    return result;
}

static void
free_arglist(void)
{
    while (active_arglist != NULL) {
	CA_REC *next = active_arglist->link;
	ZFREE(active_arglist);
	active_arglist = next;
    }
}

/* resize the code for a user function */

static void
resize_fblock(FBLOCK * fbp)
{
    CODEBLOCK *p = ZMALLOC(CODEBLOCK);

    code2op(_RET0, _HALT);
    /* make sure there is always a return */

    *p = active_code;
    fbp->code = code_shrink(p, &fbp->size);
    /* code_shrink() zfrees p */

    if (dump_code_flag)
	add_to_fdump_list(fbp);
}

/* convert FE_PUSHA  to  FE_PUSHI
   or F_PUSH to F_PUSHI
*/

static void
field_A2I(void)
{
    if (code_ptr[-1].op == FE_PUSHA &&
	code_ptr[-1].ptr == (PTR) 0) {
	/* On most architectures, the two tests are the same; a good
	   compiler might eliminate one.  On LM_DOS, and possibly other
	   segmented architectures, they are not */
	code_ptr[-1].op = FE_PUSHI;
    } else {
	CELL *cp = (CELL *) code_ptr[-1].ptr;

	if ((cp == field) || ((cp > NF) && (cp <= LAST_PFIELD))) {
	    code_ptr[-2].op = _PUSHI;
	} else if (cp == NF) {
	    code_ptr[-2].op = NF_PUSHI;
	    code_ptr--;
	} else {
	    code_ptr[-2].op = F_PUSHI;
	    code_ptr->op = field_addr_to_index(code_ptr[-1].ptr);
	    code_ptr++;
	}
    }
}

/* we've seen an ID in a context where it should be a VAR,
   check that's consistent with previous usage */

static void
check_var(SYMTAB * p)
{
    switch (p ? p->type : -1) {
    case ST_NONE:		/* new id */
	p->type = ST_VAR;
	p->stval.cp = ZMALLOC(CELL);
	p->stval.cp->type = C_NOINIT;
	break;

    case ST_LOCAL_NONE:
	p->type = ST_LOCAL_VAR;
	active_funct->typev[p->offset] = ST_LOCAL_VAR;
	break;

    case ST_VAR:
    case ST_LOCAL_VAR:
	break;

    default:
	type_error(p);
	break;
    }
}

/* we've seen an ID in a context where it should be an ARRAY,
   check that's consistent with previous usage */
static void
check_array(SYMTAB * p)
{
    switch (p ? p->type : -1) {
    case ST_NONE:		/* a new array */
	p->type = ST_ARRAY;
	p->stval.array = new_ARRAY();
	no_leaks_array(p->stval.array);
	break;

    case ST_ARRAY:
    case ST_LOCAL_ARRAY:
	break;

    case ST_LOCAL_NONE:
	p->type = ST_LOCAL_ARRAY;
	active_funct->typev[p->offset] = ST_LOCAL_ARRAY;
	break;

    default:
	type_error(p);
	break;
    }
}

static void
code_array(SYMTAB * p)
{
    if (is_local(p))
	code2op(LA_PUSHA, p->offset);
    else
	code2(A_PUSHA, p->stval.array);
}

/* we've seen an ID as an argument to a user defined function */

static void
code_call_id(CA_REC * p, SYMTAB * ip)
{
    static CELL dummy;

    p->call_offset = code_offset;
    /* This always gets set now.  So that fcall:relocate_arglist
       works. */

    switch (ip->type) {
    case ST_VAR:
	p->type = CA_EXPR;
	code2(_PUSHI, ip->stval.cp);
	break;

    case ST_LOCAL_VAR:
	p->type = CA_EXPR;
	code2op(L_PUSHI, ip->offset);
	break;

    case ST_ARRAY:
	p->type = CA_ARRAY;
	code2(A_PUSHA, ip->stval.array);
	break;

    case ST_LOCAL_ARRAY:
	p->type = CA_ARRAY;
	code2op(LA_PUSHA, ip->offset);
	break;

	/* not enough info to code it now; it will have to
	   be patched later */

    case ST_NONE:
	p->type = ST_NONE;
	p->sym_p = ip;
	code2(_PUSHI, &dummy);
	break;

    case ST_LOCAL_NONE:
	p->type = ST_LOCAL_NONE;
	p->type_p = &active_funct->typev[ip->offset];
	code2op(L_PUSHI, ip->offset);
	break;

#ifdef DEBUG
    default:
	bozo("code_call_id");
#endif

    }
}

/* an RE by itself was coded as _MATCH0 , change to
   push as an expression */

static void
RE_as_arg(void)
{
    CELL *cp = ZMALLOC(CELL);

    code_ptr -= 2;
    cp->type = C_RE;
    cp->ptr = code_ptr[1].ptr;
    code2(_PUSHC, cp);
    no_leaks_cell_ptr(cp);
}

/* reset the active_code back to the MAIN block */
static void
switch_code_to_main(void)
{
    switch (scope) {
    case SCOPE_BEGIN:
	*begin_code_p = active_code;
	active_code = *main_code_p;
	break;

    case SCOPE_END:
	*end_code_p = active_code;
	active_code = *main_code_p;
	break;

    case SCOPE_FUNCT:
	active_code = *main_code_p;
	break;

    case SCOPE_MAIN:
	break;
    }
    active_funct = (FBLOCK *) 0;
    scope = SCOPE_MAIN;
}

void
parse(void)
{
    if (yyparse() || compile_error_count != 0)
	mawk_exit(2);

    scan_cleanup();
    set_code();
    /* code must be set before call to resolve_fcalls() */
    if (resolve_list)
	resolve_fcalls();

    if (compile_error_count != 0)
	mawk_exit(2);
    if (dump_code_flag) {
	dump_code();
	mawk_exit(0);
    }
}
