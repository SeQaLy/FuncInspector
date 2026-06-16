/*
 * FuncInspector (C)
 * =================
 * C ソースから「関数定義」の関数名を抽出する CUI ツール。
 *
 * 出力フォーマット:  file.c,line,funcname,steps
 *
 *  - WINAMS などの呼び出し規約マクロが関数名の前に付いていても対応
 *  - コメント / 文字列リテラルを除去してから解析
 *  - プロトタイプ宣言 (末尾 ;) や関数呼び出しは除外
 *  - コンパイルスイッチ (#ifdef/#ifndef/#if/#elif) の一覧表示 (--list-switches)
 *  - スイッチを -D/-U で ON/OFF し条件コンパイルを評価 (未指定は OFF=未定義)
 *  - 各関数のステップ数 (本体の実行行数。空行・コメント・波括弧のみの行は除く)
 *  - フォルダ指定時は再帰的に走査 (Win32 / POSIX 両対応)
 *
 * ビルド:
 *   gcc -O2 -o func_inspector func_inspector.c      (Linux / macOS / MinGW)
 *   cl  /O2 func_inspector.c                          (MSVC)
 *
 * 使い方:
 *   func_inspector path... [--list-switches] [-D NAME[=VAL]] [-U NAME]
 *                          [--ignore-switches] [--ext .c,.h] [--header] [--out f]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#ifdef _WIN32
#  include <windows.h>
#  define PATH_SEP '\\'
#else
#  include <dirent.h>
#  include <sys/stat.h>
#  define PATH_SEP '/'
#endif

/* ---- 除外キーワード ------------------------------------------------------ */
static const char *KEYWORDS[] = {
    "if", "for", "while", "switch", "return", "sizeof", "do", "else",
    "goto", "case", "default", "typedef", "struct", "union", "enum",
    "static", "extern", "const", "volatile", "register", "auto",
    "signed", "unsigned", "void", "char", "short", "int", "long",
    "float", "double", "_Bool", "inline", "__inline", "__attribute__",
    "_Static_assert", "_Generic", "_Alignas", "defined", "asm", "__asm",
    NULL
};

static int is_keyword(const char *s, size_t len) {
    for (int i = 0; KEYWORDS[i]; ++i)
        if (strlen(KEYWORDS[i]) == len && memcmp(KEYWORDS[i], s, len) == 0)
            return 1;
    return 0;
}
static int ident_start(int c) { return isalpha(c) || c == '_'; }
static int ident_char(int c)  { return isalnum(c) || c == '_'; }

/* ---- defines (name -> value) 辞書 --------------------------------------- */
static char *_strdup_(const char *s); /* 前方宣言 (定義は下部) */

typedef struct { char **names; char **vals; int count, cap; } Defs;

static void defs_init(Defs *d) { d->names = NULL; d->vals = NULL; d->count = 0; d->cap = 0; }
static int  defs_find(const Defs *d, const char *name) {
    for (int i = 0; i < d->count; ++i) if (strcmp(d->names[i], name) == 0) return i;
    return -1;
}
static int  defs_has(const Defs *d, const char *name) { return defs_find(d, name) >= 0; }
static void defs_set(Defs *d, const char *name, const char *val) {
    int i = defs_find(d, name);
    if (i >= 0) { free(d->vals[i]); d->vals[i] = _strdup_(val); return; }
    if (d->count == d->cap) {
        d->cap = d->cap ? d->cap * 2 : 16;
        d->names = (char **)realloc(d->names, d->cap * sizeof(char *));
        d->vals  = (char **)realloc(d->vals,  d->cap * sizeof(char *));
    }
    d->names[d->count] = _strdup_(name);
    d->vals[d->count]  = _strdup_(val);
    d->count++;
}
static void defs_remove(Defs *d, const char *name) {
    int i = defs_find(d, name);
    if (i < 0) return;
    free(d->names[i]); free(d->vals[i]);
    for (int k = i; k < d->count - 1; ++k) { d->names[k] = d->names[k + 1]; d->vals[k] = d->vals[k + 1]; }
    d->count--;
}
static void defs_free(Defs *d) {
    for (int i = 0; i < d->count; ++i) { free(d->names[i]); free(d->vals[i]); }
    free(d->names); free(d->vals); defs_init(d);
}
static void defs_clone(const Defs *src, Defs *dst) {
    defs_init(dst);
    for (int i = 0; i < src->count; ++i) defs_set(dst, src->names[i], src->vals[i]);
}

/* strdup は標準C ではないので簡易版 */
static char *_strdup_(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

/* ---- 設定 (グローバル) --------------------------------------------------- */
static char  g_exts[16][16];
static int   g_ext_count = 0;
static int   g_header = 0;
static int   g_list_switches = 0;
static int   g_ignore_switches = 0;
static FILE *g_out = NULL;
static long  g_func_total = 0;
static long  g_step_total = 0;
static Defs  g_defines;
static long  g_file_total = 0;   /* 進捗表示用: 対象ファイル総数 */
static long  g_file_idx = 0;     /* 進捗表示用: 処理済み数 */

/* 進捗を stderr に上書き表示 (stdout の出力は汚さない) */
static void progress_tick(const char *path) {
    g_file_idx++;
    const char *base = strrchr(path, '/');
    const char *bsl = strrchr(path, '\\');
    if (bsl && (!base || bsl > base)) base = bsl;
    base = base ? base + 1 : path;
    fprintf(stderr, "\r処理中 %ld/%ld %-48.48s", g_file_idx, g_file_total, base);
    fflush(stderr);
}

/* ---- コメント/文字列の除去 (in-place) ----------------------------------- */
static void strip_comments_strings(char *buf, size_t n) {
    char *src = (char *)malloc(n + 1);
    if (!src) return;
    memcpy(src, buf, n);
    size_t i = 0, o = 0;
    while (i < n) {
        char c = src[i];
        if (c == '/' && i + 1 < n && src[i + 1] == '/') {
            while (i < n && src[i] != '\n') { buf[o++] = ' '; i++; }
        } else if (c == '/' && i + 1 < n && src[i + 1] == '*') {
            buf[o++] = ' '; buf[o++] = ' '; i += 2;
            while (i < n && !(src[i] == '*' && i + 1 < n && src[i + 1] == '/')) {
                buf[o++] = (src[i] == '\n') ? '\n' : ' '; i++;
            }
            if (i < n) { buf[o++] = ' '; buf[o++] = ' '; i += 2; }
        } else if (c == '"' || c == '\'') {
            char q = c; buf[o++] = ' '; i++;
            while (i < n && src[i] != q) {
                if (src[i] == '\\' && i + 1 < n) { buf[o++] = ' '; buf[o++] = ' '; i += 2; }
                else { buf[o++] = (src[i] == '\n') ? '\n' : ' '; i++; }
            }
            if (i < n) { buf[o++] = ' '; i++; }
        } else {
            buf[o++] = c; i++;
        }
    }
    free(src);
}

/* ---- ディレクティブ解析 -------------------------------------------------- */
enum { D_NONE, D_IFDEF, D_IFNDEF, D_IF, D_ELIF, D_ELSE, D_ENDIF, D_DEFINE, D_UNDEF };

static int parse_directive(const char *buf, size_t ls, size_t le, size_t *rest) {
    size_t p = ls;
    while (p < le && (buf[p] == ' ' || buf[p] == '\t')) p++;
    if (p >= le || buf[p] != '#') return D_NONE;
    p++;
    while (p < le && (buf[p] == ' ' || buf[p] == '\t')) p++;
    size_t k = p;
    while (p < le && isalpha((unsigned char)buf[p])) p++;
    size_t klen = p - k;
    *rest = p;
    if (klen == 5 && memcmp(buf + k, "ifdef", 5) == 0)  return D_IFDEF;
    if (klen == 6 && memcmp(buf + k, "ifndef", 6) == 0) return D_IFNDEF;
    if (klen == 2 && memcmp(buf + k, "if", 2) == 0)     return D_IF;
    if (klen == 4 && memcmp(buf + k, "elif", 4) == 0)   return D_ELIF;
    if (klen == 4 && memcmp(buf + k, "else", 4) == 0)   return D_ELSE;
    if (klen == 5 && memcmp(buf + k, "endif", 5) == 0)  return D_ENDIF;
    if (klen == 6 && memcmp(buf + k, "define", 6) == 0) return D_DEFINE;
    if (klen == 5 && memcmp(buf + k, "undef", 5) == 0)  return D_UNDEF;
    return D_NONE;
}

/* [s,e) から最初の識別子を out へ。afterposに識別子末尾を返す。成功で1 */
static int first_ident(const char *buf, size_t s, size_t e, char *out, size_t outsz, size_t *afterpos) {
    size_t p = s;
    while (p < e && !ident_start((unsigned char)buf[p])) p++;
    if (p >= e) return 0;
    size_t st = p;
    while (p < e && ident_char((unsigned char)buf[p])) p++;
    size_t len = p - st;
    if (len >= outsz) len = outsz - 1;
    memcpy(out, buf + st, len); out[len] = '\0';
    if (afterpos) *afterpos = p;
    return 1;
}

/* ---- #if 式の評価 -------------------------------------------------------- */
typedef struct { int kind; long num; char id[64]; } Tok; /* kind: 0=num 1=id 2=op */

typedef struct { Tok *t; int count; int pos; const Defs *d; } Parser;

static long pp_or(Parser *P);

static long macro_int(const Defs *d, const char *name, int depth) {
    if (depth > 16) return 0;
    int i = defs_find(d, name);
    if (i < 0) return 0;
    const char *v = d->vals[i];
    if (!v || !*v) return 1;
    while (*v == ' ' || *v == '\t') v++;
    char *end = NULL;
    long val = strtol(v, &end, 0);
    if (end && end != v) {
        while (*end == ' ' || *end == '\t' || *end == 'u' || *end == 'U' || *end == 'l' || *end == 'L') end++;
        if (*end == '\0') return val;
    }
    /* 値が別マクロ名なら一段展開 */
    if (ident_start((unsigned char)*v)) {
        char nm[64]; size_t j = 0;
        while (v[j] && ident_char((unsigned char)v[j]) && j < sizeof(nm) - 1) { nm[j] = v[j]; j++; }
        nm[j] = '\0';
        if (v[j] == '\0') return macro_int(d, nm, depth + 1);
    }
    return 0;
}

static Tok *peek(Parser *P) { return P->pos < P->count ? &P->t[P->pos] : NULL; }
static Tok *adv(Parser *P)  { return &P->t[P->pos++]; }
static int is_op(Tok *t, const char *o) { return t && t->kind == 2 && strcmp(t->id, o) == 0; }

static long pp_primary(Parser *P) {
    Tok *t = peek(P);
    if (!t) return 0;
    if (is_op(t, "(")) { adv(P); long v = pp_or(P); if (is_op(peek(P), ")")) adv(P); return v; }
    if (t->kind == 1 && strcmp(t->id, "defined") == 0) {
        adv(P);
        char nm[64]; nm[0] = '\0';
        if (is_op(peek(P), "(")) {
            adv(P);
            if (peek(P) && peek(P)->kind == 1) { strncpy(nm, adv(P)->id, sizeof(nm) - 1); nm[sizeof(nm)-1]='\0'; }
            if (is_op(peek(P), ")")) adv(P);
        } else if (peek(P) && peek(P)->kind == 1) {
            strncpy(nm, adv(P)->id, sizeof(nm) - 1); nm[sizeof(nm)-1]='\0';
        }
        return defs_has(P->d, nm) ? 1 : 0;
    }
    if (t->kind == 1) { adv(P); return macro_int(P->d, t->id, 0); }
    if (t->kind == 0) { adv(P); return t->num; }
    adv(P); return 0;
}
static long pp_unary(Parser *P) {
    Tok *t = peek(P);
    if (t && t->kind == 2 && (strcmp(t->id, "!") == 0 || strcmp(t->id, "-") == 0 || strcmp(t->id, "+") == 0)) {
        char op = t->id[0]; adv(P); long v = pp_unary(P);
        if (op == '!') return v ? 0 : 1;
        if (op == '-') return -v;
        return v;
    }
    return pp_primary(P);
}
static long pp_mul(Parser *P) {
    long v = pp_unary(P);
    for (;;) { Tok *t = peek(P);
        if (is_op(t, "*")) { adv(P); v = v * pp_unary(P); }
        else if (is_op(t, "/")) { adv(P); long r = pp_unary(P); v = r ? v / r : 0; }
        else if (is_op(t, "%")) { adv(P); long r = pp_unary(P); v = r ? v % r : 0; }
        else break;
    } return v;
}
static long pp_add(Parser *P) {
    long v = pp_mul(P);
    for (;;) { Tok *t = peek(P);
        if (is_op(t, "+")) { adv(P); v = v + pp_mul(P); }
        else if (is_op(t, "-")) { adv(P); v = v - pp_mul(P); }
        else break;
    } return v;
}
static long pp_rel(Parser *P) {
    long v = pp_add(P);
    for (;;) { Tok *t = peek(P);
        if (is_op(t, "<")) { adv(P); v = (v < pp_add(P)) ? 1 : 0; }
        else if (is_op(t, ">")) { adv(P); v = (v > pp_add(P)) ? 1 : 0; }
        else if (is_op(t, "<=")) { adv(P); v = (v <= pp_add(P)) ? 1 : 0; }
        else if (is_op(t, ">=")) { adv(P); v = (v >= pp_add(P)) ? 1 : 0; }
        else break;
    } return v;
}
static long pp_eq(Parser *P) {
    long v = pp_rel(P);
    for (;;) { Tok *t = peek(P);
        if (is_op(t, "==")) { adv(P); v = (v == pp_rel(P)) ? 1 : 0; }
        else if (is_op(t, "!=")) { adv(P); v = (v != pp_rel(P)) ? 1 : 0; }
        else break;
    } return v;
}
static long pp_and(Parser *P) {
    long v = pp_eq(P);
    for (;;) { Tok *t = peek(P);
        if (is_op(t, "&&")) { adv(P); long r = pp_eq(P); v = (v && r) ? 1 : 0; }
        else break;
    } return v;
}
static long pp_or(Parser *P) {
    long v = pp_and(P);
    for (;;) { Tok *t = peek(P);
        if (is_op(t, "||")) { adv(P); long r = pp_and(P); v = (v || r) ? 1 : 0; }
        else break;
    } return v;
}

static int tokenize_expr(const char *buf, size_t s, size_t e, Tok *out, int maxt) {
    int n = 0; size_t i = s;
    while (i < e && n < maxt) {
        char c = buf[i];
        if (isspace((unsigned char)c)) { i++; continue; }
        if (isdigit((unsigned char)c)) {
            long val;
            if (c == '0' && i + 1 < e && (buf[i+1] == 'x' || buf[i+1] == 'X')) {
                size_t j = i + 2;
                while (j < e && isxdigit((unsigned char)buf[j])) j++;
                val = strtol(buf + i, NULL, 16); i = j;
            } else {
                size_t j = i;
                while (j < e && isdigit((unsigned char)buf[j])) j++;
                char tmp[32]; size_t len = j - i; if (len >= sizeof(tmp)) len = sizeof(tmp)-1;
                memcpy(tmp, buf + i, len); tmp[len] = '\0'; val = strtol(tmp, NULL, 10);
                while (j < e && (buf[j]=='u'||buf[j]=='U'||buf[j]=='l'||buf[j]=='L')) j++;
                i = j;
            }
            out[n].kind = 0; out[n].num = val; out[n].id[0] = '\0'; n++;
            continue;
        }
        if (ident_start((unsigned char)c)) {
            size_t j = i;
            while (j < e && ident_char((unsigned char)buf[j])) j++;
            size_t len = j - i; if (len >= sizeof(out[n].id)) len = sizeof(out[n].id) - 1;
            out[n].kind = 1; memcpy(out[n].id, buf + i, len); out[n].id[len] = '\0'; out[n].num = 0;
            n++; i = j; continue;
        }
        /* 2文字演算子 */
        if (i + 1 < e) {
            char two[3] = { c, buf[i+1], 0 };
            if (!strcmp(two,"&&")||!strcmp(two,"||")||!strcmp(two,"==")||
                !strcmp(two,"!=")||!strcmp(two,"<=")||!strcmp(two,">=")) {
                out[n].kind = 2; strcpy(out[n].id, two); out[n].num = 0; n++; i += 2; continue;
            }
        }
        if (strchr("!()<>+-*/%", c)) {
            out[n].kind = 2; out[n].id[0] = c; out[n].id[1] = '\0'; out[n].num = 0; n++; i++; continue;
        }
        i++;
    }
    return n;
}

static int eval_if(const char *buf, size_t s, size_t e, const Defs *d) {
    Tok toks[256];
    int n = tokenize_expr(buf, s, e, toks, 256);
    Parser P; P.t = toks; P.count = n; P.pos = 0; P.d = d;
    return pp_or(&P) ? 1 : 0;
}

/* ---- プリプロセス (条件コンパイル) : 無効/ディレクティブ行を空白化 ------ */
#define MAX_PP_DEPTH 256
static void preprocess(char *buf, size_t n, Defs *d) {
    int par[MAX_PP_DEPTH], tak[MAX_PP_DEPTH], act[MAX_PP_DEPTH];
    int sp = 0;
    size_t ls = 0;
    while (ls <= n) {
        size_t le = ls;
        while (le < n && buf[le] != '\n') le++;
        /* emitting 判定 */
        int emit = 1;
        for (int i = 0; i < sp; ++i) if (!act[i]) { emit = 0; break; }

        size_t rest;
        int kind = parse_directive(buf, ls, le, &rest);
        int blank = 0;

        if (kind != D_NONE) {
            blank = 1;
            char nm[64]; size_t after;
            switch (kind) {
                case D_IFDEF: {
                    int parent = emit;
                    int cond = first_ident(buf, rest, le, nm, sizeof(nm), &after) && defs_has(d, nm);
                    if (sp < MAX_PP_DEPTH) { par[sp]=parent; tak[sp]=(parent&&cond); act[sp]=(parent&&cond); sp++; }
                    break; }
                case D_IFNDEF: {
                    int parent = emit;
                    int cond = !(first_ident(buf, rest, le, nm, sizeof(nm), &after) && defs_has(d, nm));
                    if (sp < MAX_PP_DEPTH) { par[sp]=parent; tak[sp]=(parent&&cond); act[sp]=(parent&&cond); sp++; }
                    break; }
                case D_IF: {
                    int parent = emit;
                    int cond = parent ? eval_if(buf, rest, le, d) : 0;
                    if (sp < MAX_PP_DEPTH) { par[sp]=parent; tak[sp]=(parent&&cond); act[sp]=(parent&&cond); sp++; }
                    break; }
                case D_ELIF: {
                    if (sp > 0) {
                        int i = sp - 1;
                        if (par[i] && !tak[i]) { int cond = eval_if(buf, rest, le, d); act[i] = cond; if (cond) tak[i] = 1; }
                        else act[i] = 0;
                    }
                    break; }
                case D_ELSE: {
                    if (sp > 0) { int i = sp - 1; if (par[i] && !tak[i]) { act[i]=1; tak[i]=1; } else act[i]=0; }
                    break; }
                case D_ENDIF: { if (sp > 0) sp--; break; }
                case D_DEFINE: {
                    if (emit && first_ident(buf, rest, le, nm, sizeof(nm), &after)) {
                        size_t vs = after; while (vs < le && (buf[vs]==' '||buf[vs]=='\t')) vs++;
                        size_t ve = le; while (ve > vs && (buf[ve-1]==' '||buf[ve-1]=='\t'||buf[ve-1]=='\r')) ve--;
                        char val[256]; size_t vlen = ve - vs; if (vlen >= sizeof(val)) vlen = sizeof(val)-1;
                        memcpy(val, buf + vs, vlen); val[vlen] = '\0';
                        defs_set(d, nm, vlen ? val : "1");
                    }
                    break; }
                case D_UNDEF: {
                    if (emit && first_ident(buf, rest, le, nm, sizeof(nm), &after)) defs_remove(d, nm);
                    break; }
            }
        } else {
            if (!emit) blank = 1;
        }

        if (blank) for (size_t p = ls; p < le; ++p) buf[p] = ' ';

        if (le >= n) break;
        ls = le + 1;
    }
}

/* ---- 行頭オフセット表 / ステップ数 -------------------------------------- */
static size_t *build_line_starts(const char *buf, size_t n, size_t *out_cnt) {
    size_t cap = 64, cnt = 0;
    size_t *st = (size_t *)malloc(cap * sizeof(size_t));
    st[cnt++] = 0;
    for (size_t i = 0; i < n; ++i) {
        if (buf[i] == '\n') {
            if (cnt == cap) { cap *= 2; st = (size_t *)realloc(st, cap * sizeof(size_t)); }
            st[cnt++] = i + 1;
        }
    }
    *out_cnt = cnt;
    return st;
}
static long line_of(const size_t *st, size_t cnt, size_t idx) {
    /* 最大の k で st[k] <= idx → 行番号 k+1 (二分探索) */
    size_t lo = 0, hi = cnt; /* [lo,hi) */
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (st[mid] <= idx) lo = mid + 1; else hi = mid; }
    return (long)lo; /* lo = 要素数(<=idx) = 行番号 */
}
static int count_steps(const char *buf, size_t n, const size_t *st, size_t cnt, long l1, long l2) {
    int steps = 0;
    for (long k = l1; k <= l2; ++k) {
        if (k < 1 || (size_t)k > cnt) continue;
        size_t a = st[k - 1];
        size_t b = ((size_t)k < cnt) ? st[k] - 1 : n; /* '\n' を除く */
        int nonbrace = 0;
        for (size_t p = a; p < b; ++p) {
            char ch = buf[p];
            if (isspace((unsigned char)ch)) continue;
            if (ch != '{' && ch != '}') { nonbrace = 1; break; }
        }
        if (nonbrace) steps++;
    }
    return steps;
}

static int member_access(const char *s, size_t idx) {
    long j = (long)idx - 1;
    while (j >= 0 && (s[j]==' '||s[j]=='\t'||s[j]=='\r'||s[j]=='\n')) j--;
    if (j < 0) return 0;
    if (s[j] == '.') return 1;
    if (s[j] == '>' && j - 1 >= 0 && s[j-1] == '-') return 1;
    return 0;
}

/* ---- 関数検出 + ステップ数 ---------------------------------------------- */
static void scan_functions(const char *path, const char *buf, size_t n) {
    size_t cnt;
    size_t *st = build_line_starts(buf, n, &cnt);
    size_t i = 0;
    while (i < n) {
        char c = buf[i];
        if (ident_start((unsigned char)c)) {
            size_t j = i;
            while (j < n && ident_char((unsigned char)buf[j])) j++;
            size_t len = j - i;
            size_t k = j;
            while (k < n && (buf[k]==' '||buf[k]=='\t'||buf[k]=='\r'||buf[k]=='\n')) k++;
            if (k < n && buf[k] == '(' && !is_keyword(buf + i, len)) {
                int depth = 0; size_t p = k;
                while (p < n) {
                    if (buf[p] == '(') depth++;
                    else if (buf[p] == ')') { depth--; if (depth == 0) { p++; break; } }
                    p++;
                }
                size_t q = p;
                while (q < n && (buf[q]==' '||buf[q]=='\t'||buf[q]=='\r'||buf[q]=='\n')) q++;
                if (q < n && buf[q] == '{' && !member_access(buf, i)) {
                    int d2 = 0; size_t r = q, close = n - 1;
                    while (r < n) {
                        if (buf[r] == '{') d2++;
                        else if (buf[r] == '}') { d2--; if (d2 == 0) { close = r; break; } }
                        r++;
                    }
                    long l1 = line_of(st, cnt, q);
                    long l2 = line_of(st, cnt, close);
                    int steps = count_steps(buf, n, st, cnt, l1, l2);
                    char name[256];
                    size_t nl = len < sizeof(name) - 1 ? len : sizeof(name) - 1;
                    memcpy(name, buf + i, nl); name[nl] = '\0';
                    fprintf(g_out, "%s,%ld,%s,%d\n", path, line_of(st, cnt, i), name, steps);
                    g_func_total++; g_step_total += steps;
                    i = close + 1; continue;   /* 本体は再走査しない */
                }
                i = p; continue;
            } else { i = j; continue; }
        } else i++;
    }
    free(st);
}

/* ---- スイッチ収集 -------------------------------------------------------- */
typedef struct { char name[128]; int count; char file[1024]; long line; } SwEntry;
typedef struct { SwEntry *items; int count, cap; } SwSet;
static void sw_init(SwSet *s) { s->items = NULL; s->count = 0; s->cap = 0; }
static void sw_add(SwSet *s, const char *name, const char *file, long line) {
    for (int i = 0; i < s->count; ++i)
        if (strcmp(s->items[i].name, name) == 0) { s->items[i].count++; return; }
    if (s->count == s->cap) {
        s->cap = s->cap ? s->cap * 2 : 32;
        s->items = realloc(s->items, s->cap * sizeof(SwEntry));
    }
    SwEntry *e = &s->items[s->count];
    strncpy(e->name, name, 127); e->name[127] = '\0';
    strncpy(e->file, file, sizeof(e->file) - 1); e->file[sizeof(e->file) - 1] = '\0';
    e->line = line; e->count = 1; s->count++;
}
static void sw_free(SwSet *s) { free(s->items); sw_init(s); }
static int sw_cmp(const void *a, const void *b) {
    return strcmp(((const SwEntry *)a)->name, ((const SwEntry *)b)->name);
}

static void collect_switches(const char *buf, size_t n, SwSet *sw, const char *path) {
    size_t ls = 0; long lineno = 0;
    while (ls <= n) {
        lineno++;
        size_t le = ls; while (le < n && buf[le] != '\n') le++;
        size_t rest; int kind = parse_directive(buf, ls, le, &rest);
        if (kind == D_IFDEF || kind == D_IFNDEF) {
            char nm[64]; size_t after;
            if (first_ident(buf, rest, le, nm, sizeof(nm), &after)) sw_add(sw, nm, path, lineno);
        } else if (kind == D_IF || kind == D_ELIF) {
            size_t p = rest;
            while (p < le) {
                if (ident_start((unsigned char)buf[p])) {
                    size_t s2 = p; while (p < le && ident_char((unsigned char)buf[p])) p++;
                    size_t l2 = p - s2; char nm[64]; if (l2 >= sizeof(nm)) l2 = sizeof(nm)-1;
                    memcpy(nm, buf + s2, l2); nm[l2] = '\0';
                    if (strcmp(nm, "defined") != 0) sw_add(sw, nm, path, lineno);
                } else p++;
            }
        }
        if (le >= n) break;
        ls = le + 1;
    }
}

/* ---- ファイル処理 -------------------------------------------------------- */
static char *read_file(const char *path, size_t *out_n) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "warning: cannot open %s\n", path); return NULL; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return NULL; }
    char *buf = (char *)malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t rd = fread(buf, 1, (size_t)sz, f); fclose(f);
    buf[rd] = '\0'; *out_n = rd; return buf;
}

static void analyze_file(const char *path) {
    size_t n; char *buf = read_file(path, &n);
    if (!buf) return;
    strip_comments_strings(buf, n);
    if (!g_ignore_switches) {
        Defs d; defs_clone(&g_defines, &d);
        preprocess(buf, n, &d);
        defs_free(&d);
    }
    scan_functions(path, buf, n);
    free(buf);
}

static void list_switches_file(const char *path, SwSet *sw) {
    size_t n; char *buf = read_file(path, &n);
    if (!buf) return;
    strip_comments_strings(buf, n);
    collect_switches(buf, n, sw, path);
    free(buf);
}

static int has_target_ext(const char *name) {
    const char *dot = strrchr(name, '.');
    if (!dot) return 0;
    for (int i = 0; i < g_ext_count; ++i) {
#ifdef _WIN32
        if (_stricmp(dot, g_exts[i]) == 0) return 1;
#else
        if (strcasecmp(dot, g_exts[i]) == 0) return 1;
#endif
    }
    return 0;
}

static int is_directory(const char *path) {
#ifdef _WIN32
    DWORD a = GetFileAttributesA(path);
    return (a != INVALID_FILE_ATTRIBUTES) && (a & FILE_ATTRIBUTE_DIRECTORY);
#else
    struct stat sbuf; if (stat(path, &sbuf) != 0) return 0; return S_ISDIR(sbuf.st_mode);
#endif
}

/* path を走査し、ファイルごとに cb を呼ぶ */
static void walk(const char *path, void (*cb)(const char *, void *), void *ctx) {
    if (is_directory(path)) {
#ifdef _WIN32
        char pattern[4096];
        snprintf(pattern, sizeof(pattern), "%s%c*", path, PATH_SEP);
        WIN32_FIND_DATAA fd; HANDLE h = FindFirstFileA(pattern, &fd);
        if (h == INVALID_HANDLE_VALUE) return;
        do {
            if (!strcmp(fd.cFileName, ".") || !strcmp(fd.cFileName, "..")) continue;
            char child[4096]; snprintf(child, sizeof(child), "%s%c%s", path, PATH_SEP, fd.cFileName);
            walk(child, cb, ctx);
        } while (FindNextFileA(h, &fd));
        FindClose(h);
#else
        DIR *dd = opendir(path); if (!dd) return; struct dirent *e;
        while ((e = readdir(dd)) != NULL) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
            char child[4096]; snprintf(child, sizeof(child), "%s%c%s", path, PATH_SEP, e->d_name);
            walk(child, cb, ctx);
        }
        closedir(dd);
#endif
    } else {
        if (has_target_ext(path)) cb(path, ctx);
    }
}

static void cb_count(const char *path, void *ctx) { (void)path; (*(long *)ctx)++; }
static void cb_analyze(const char *path, void *ctx) { (void)ctx; progress_tick(path); analyze_file(path); }
static void cb_switches(const char *path, void *ctx) { progress_tick(path); list_switches_file(path, (SwSet *)ctx); }

/* ---- 引数 / main -------------------------------------------------------- */
static void add_exts(const char *csv) {
    g_ext_count = 0; const char *p = csv;
    while (*p && g_ext_count < 16) {
        char tmp[16]; int t = 0;
        while (*p == ' ') p++;
        if (*p != '.') tmp[t++] = '.';
        while (*p && *p != ',' && t < (int)sizeof(tmp) - 1) tmp[t++] = *p++;
        tmp[t] = '\0';
        if (t > 0) strcpy(g_exts[g_ext_count++], tmp);
        if (*p == ',') p++;
    }
}

static void add_define(const char *arg) {
    const char *eq = strchr(arg, '=');
    if (eq) {
        char name[128]; size_t len = eq - arg; if (len >= sizeof(name)) len = sizeof(name)-1;
        memcpy(name, arg, len); name[len] = '\0';
        defs_set(&g_defines, name, eq + 1);
    } else {
        defs_set(&g_defines, arg, "1");
    }
}

static void usage(const char *prog) {
    fprintf(stderr,
        "FuncInspector (C) - C ソースから関数名を抽出\n"
        "使い方: %s path... [options]\n"
        "  --list-switches     コンパイルスイッチ一覧を出力 (switch,occurrences,state)\n"
        "  -D NAME[=VAL]       スイッチを ON (定義)\n"
        "  -U NAME             スイッチを OFF (未定義)\n"
        "  --ignore-switches   条件コンパイルを無視して全コードを対象\n"
        "  --ext .c,.h         対象拡張子 (既定 .c,.h)\n"
        "  --header            ヘッダ行を付ける\n"
        "  --out FILE          出力先 (既定 標準出力)\n"
        "出力: file,line,funcname,steps\n", prog);
}

int main(int argc, char **argv) {
    const char *paths[256]; int npaths = 0;
    const char *outfile = NULL; const char *extarg = ".c,.h";
    defs_init(&g_defines);

    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--ext") && i + 1 < argc) extarg = argv[++i];
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) outfile = argv[++i];
        else if (!strcmp(argv[i], "--header")) g_header = 1;
        else if (!strcmp(argv[i], "--list-switches")) g_list_switches = 1;
        else if (!strcmp(argv[i], "--ignore-switches")) g_ignore_switches = 1;
        else if (!strcmp(argv[i], "-D") && i + 1 < argc) add_define(argv[++i]);
        else if (!strncmp(argv[i], "-D", 2) && argv[i][2]) add_define(argv[i] + 2);
        else if (!strcmp(argv[i], "-U") && i + 1 < argc) defs_remove(&g_defines, argv[++i]);
        else if (!strncmp(argv[i], "-U", 2) && argv[i][2]) defs_remove(&g_defines, argv[i] + 2);
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) { usage(argv[0]); return 0; }
        else if (npaths < 256) paths[npaths++] = argv[i];
    }

    if (npaths == 0) { usage(argv[0]); return 1; }
    add_exts(extarg);

    g_out = stdout;
    if (outfile) { g_out = fopen(outfile, "w"); if (!g_out) { fprintf(stderr, "error: cannot open %s\n", outfile); return 1; } }

    /* 進捗表示用に対象ファイル総数を先に数える */
    g_file_total = 0; g_file_idx = 0;
    for (int i = 0; i < npaths; ++i) walk(paths[i], cb_count, &g_file_total);

    if (g_list_switches) {
        SwSet sw; sw_init(&sw);
        for (int i = 0; i < npaths; ++i) walk(paths[i], cb_switches, &sw);
        fprintf(stderr, "\r%-70s\r", "");   /* 進捗行をクリア */
        qsort(sw.items, sw.count, sizeof(SwEntry), sw_cmp);
        if (g_header) fprintf(g_out, "switch,occurrences,state,file,line\n");
        for (int i = 0; i < sw.count; ++i) {
            fprintf(g_out, "%s,%d,%s,%s,%ld\n", sw.items[i].name, sw.items[i].count,
                    defs_has(&g_defines, sw.items[i].name) ? "ON" : "OFF",
                    sw.items[i].file, sw.items[i].line);
        }
        fprintf(stderr, "%d 個のスイッチ\n", sw.count);
        sw_free(&sw);
    } else {
        if (g_header) fprintf(g_out, "file,line,function,steps\n");
        for (int i = 0; i < npaths; ++i) walk(paths[i], cb_analyze, NULL);
        fprintf(stderr, "\r%-70s\r", "");   /* 進捗行をクリア */
    }

    if (outfile) fclose(g_out);
    if (!g_list_switches)
        fprintf(stderr, "%ld 関数 / 合計 %ld ステップ\n", g_func_total, g_step_total);
    defs_free(&g_defines);
    return 0;
}
