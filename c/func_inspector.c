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
static int   g_header = 1;   /* 既定でヘッダ行を出力 */
static int   g_list_switches = 0;
static int   g_ignore_switches = 0;
static int   g_external = 0;     /* ソース内 #define/#undef を無視 (スイッチは -D のみ) */
static FILE *g_out = NULL;
static long  g_func_total = 0;
static long  g_step_total = 0;
static Defs  g_defines;
static Defs  g_pinned;           /* -D/-U で固定する名前 (値は未使用) */
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
static void preprocess(char *buf, size_t n, Defs *d, Defs *vc) {
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
                    if (emit && first_ident(buf, rest, le, nm, sizeof(nm), &after)
                        && !defs_has(&g_pinned, nm)
                        && (!g_external || (vc && defs_has(vc, nm)))) {
                        size_t vs = after; while (vs < le && (buf[vs]==' '||buf[vs]=='\t')) vs++;
                        size_t ve = le; while (ve > vs && (buf[ve-1]==' '||buf[ve-1]=='\t'||buf[ve-1]=='\r')) ve--;
                        char val[256]; size_t vlen = ve - vs; if (vlen >= sizeof(val)) vlen = sizeof(val)-1;
                        memcpy(val, buf + vs, vlen); val[vlen] = '\0';
                        defs_set(d, nm, vlen ? val : "1");
                    }
                    break; }
                case D_UNDEF: {
                    if (emit && first_ident(buf, rest, le, nm, sizeof(nm), &after)
                        && !defs_has(&g_pinned, nm)
                        && (!g_external || (vc && defs_has(vc, nm)))) defs_remove(d, nm);
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
#define SW_MAXVALS 32
typedef struct {
    char name[128]; int count; char file[1024]; long line;
    char vals[SW_MAXVALS][40]; int nvals;
    int sw_role, val_role;   /* スイッチ役割 / 値の側 役割 */
} SwEntry;
typedef struct { SwEntry *items; int count, cap; } SwSet;
static void sw_init(SwSet *s) { s->items = NULL; s->count = 0; s->cap = 0; }

/* 名前で find-or-add し index を返す */
static int sw_find_or_add(SwSet *s, const char *name, const char *file, long line) {
    for (int i = 0; i < s->count; ++i)
        if (strcmp(s->items[i].name, name) == 0) { s->items[i].count++; return i; }
    if (s->count == s->cap) {
        s->cap = s->cap ? s->cap * 2 : 32;
        s->items = realloc(s->items, s->cap * sizeof(SwEntry));
    }
    SwEntry *e = &s->items[s->count];
    strncpy(e->name, name, 127); e->name[127] = '\0';
    strncpy(e->file, file, sizeof(e->file) - 1); e->file[sizeof(e->file) - 1] = '\0';
    e->line = line; e->count = 1; e->nvals = 0; e->sw_role = 0; e->val_role = 0;
    return s->count++;
}
static void sw_add_value(SwSet *s, int idx, const char *val) {
    if (!val || !*val) return;
    SwEntry *e = &s->items[idx];
    for (int i = 0; i < e->nvals; ++i) if (strcmp(e->vals[i], val) == 0) return;
    if (e->nvals < SW_MAXVALS) { strncpy(e->vals[e->nvals], val, 39); e->vals[e->nvals][39] = '\0'; e->nvals++; }
}
static void sw_free(SwSet *s) { free(s->items); sw_init(s); }
static int sw_cmp(const void *a, const void *b) {
    return strcmp(((const SwEntry *)a)->name, ((const SwEntry *)b)->name);
}
static int str_is_num(const char *s) {
    if (!*s) return 0;
    if (*s == '-') s++;
    if (!*s) return 0;
    for (; *s; ++s) if (!isdigit((unsigned char)*s)) return 0;
    return 1;
}
static int valcmp(const void *a, const void *b) {
    const char *x = *(const char *const *)a, *y = *(const char *const *)b;
    int xn = str_is_num(x), yn = str_is_num(y);
    if (xn && yn) { long lx = atol(x), ly = atol(y); return (lx > ly) - (lx < ly); }
    if (xn != yn) return xn ? -1 : 1;   /* 数値を先に */
    return strcmp(x, y);
}
/* 値候補を「数値→名前」順に ; 連結 */
static void sw_values_string(const SwEntry *e, char *out, size_t outsz) {
    const char *ptr[SW_MAXVALS];
    int m = e->nvals; if (m > SW_MAXVALS) m = SW_MAXVALS;
    for (int i = 0; i < m; ++i) ptr[i] = e->vals[i];
    qsort(ptr, m, sizeof(ptr[0]), valcmp);
    size_t o = 0; out[0] = '\0';
    for (int i = 0; i < m; ++i) {
        size_t need = strlen(ptr[i]) + (i ? 1 : 0);
        if (o + need + 1 >= outsz) break;
        if (i) out[o++] = ';';
        strcpy(out + o, ptr[i]); o += strlen(ptr[i]);
    }
}

/* 比較相手トークンを値文字列へ。num→数値, id(≠defined)→名前, それ以外 NULL */
static const char *tokval(const Tok *t, char *buf, size_t bufsz) {
    if (t->kind == 0) { snprintf(buf, bufsz, "%ld", t->num); return buf; }
    if (t->kind == 1 && strcmp(t->id, "defined") != 0) return t->id;
    return NULL;
}
static int is_cmp_op(const Tok *t) {
    return t->kind == 2 && (!strcmp(t->id, "==") || !strcmp(t->id, "!=") ||
        !strcmp(t->id, "<") || !strcmp(t->id, ">") || !strcmp(t->id, "<=") || !strcmp(t->id, ">="));
}

static int tok_is_id(const Tok *t) { return t && t->kind == 1 && strcmp(t->id, "defined") != 0; }

/* 役割付きでスイッチを分類 (sw_role/val_role を設定し、値候補を集める) */
static void classify_switches(const char *buf, size_t n, SwSet *sw, const char *path) {
    size_t ls = 0; long lineno = 0;
    while (ls <= n) {
        lineno++;
        size_t le = ls; while (le < n && buf[le] != '\n') le++;
        size_t rest; int kind = parse_directive(buf, ls, le, &rest);
        if (kind == D_IFDEF || kind == D_IFNDEF) {
            char nm[64]; size_t after;
            if (first_ident(buf, rest, le, nm, sizeof(nm), &after)) {
                int idx = sw_find_or_add(sw, nm, path, lineno);
                sw->items[idx].sw_role = 1; sw_add_value(sw, idx, "1");
            }
        } else if (kind == D_IF || kind == D_ELIF) {
            Tok toks[256];
            int nt = tokenize_expr(buf, rest, le, toks, 256);
            char vb[40];
            int handled[256]; for (int i = 0; i < nt; ++i) handled[i] = 0;
            for (int i = 0; i < nt; ++i) {
                if (!is_cmp_op(&toks[i])) continue;
                Tok *L = (i - 1 >= 0) ? &toks[i - 1] : NULL;
                Tok *R = (i + 1 < nt) ? &toks[i + 1] : NULL;
                int Lid = tok_is_id(L), Rid = tok_is_id(R);
                if (Lid && R && R->kind == 0) {              /* id == num */
                    int idx = sw_find_or_add(sw, L->id, path, lineno);
                    sw->items[idx].sw_role = 1; sw_add_value(sw, idx, tokval(R, vb, sizeof(vb)));
                    handled[i - 1] = 1;
                } else if (Rid && L && L->kind == 0) {       /* num == id */
                    int idx = sw_find_or_add(sw, R->id, path, lineno);
                    sw->items[idx].sw_role = 1; sw_add_value(sw, idx, tokval(L, vb, sizeof(vb)));
                    handled[i + 1] = 1;
                } else if (Lid && Rid) {                      /* id == id: 左=スイッチ 右=値 */
                    int idx = sw_find_or_add(sw, L->id, path, lineno);
                    sw->items[idx].sw_role = 1; sw_add_value(sw, idx, R->id);
                    int vidx = sw_find_or_add(sw, R->id, path, lineno);
                    sw->items[vidx].val_role = 1;
                    handled[i - 1] = 1; handled[i + 1] = 1;
                }
            }
            for (int i = 0; i < nt; ++i) {  /* defined(NAME) -> 1 */
                if (toks[i].kind == 1 && strcmp(toks[i].id, "defined") == 0) {
                    for (int j = i + 1; j < nt && j < i + 3; ++j)
                        if (toks[j].kind == 1) {
                            int idx = sw_find_or_add(sw, toks[j].id, path, lineno);
                            sw->items[idx].sw_role = 1; sw_add_value(sw, idx, "1");
                            handled[j] = 1; break;
                        }
                }
            }
            for (int i = 0; i < nt; ++i) {  /* 素の識別子使用 (#if FOO) -> 1 */
                if (toks[i].kind == 1 && strcmp(toks[i].id, "defined") != 0 && !handled[i]) {
                    int idx = sw_find_or_add(sw, toks[i].id, path, lineno);
                    sw->items[idx].sw_role = 1; sw_add_value(sw, idx, "1");
                }
            }
        }
        if (le >= n) break;
        ls = le + 1;
    }
}

/* 一覧用: 値定数 (val_role かつ !sw_role) を除外したスイッチ集合を作る */
static void collect_switches(const char *buf, size_t n, SwSet *sw, const char *path) {
    classify_switches(buf, n, sw, path);
}

/* external 時に #define を尊重すべき値定数名を vc(名前集合) に集める */
static void collect_value_constants(const char *buf, size_t n, Defs *vc) {
    SwSet tmp; sw_init(&tmp);
    classify_switches(buf, n, &tmp, "");
    for (int i = 0; i < tmp.count; ++i)
        if (tmp.items[i].val_role && !tmp.items[i].sw_role)
            defs_set(vc, tmp.items[i].name, "");
    sw_free(&tmp);
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
        Defs vc; defs_init(&vc);
        if (g_external) collect_value_constants(buf, n, &vc);  /* 値定数の #define は尊重 */
        preprocess(buf, n, &d, &vc);
        defs_free(&vc);
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
        defs_set(&g_pinned, name, "");      /* コマンドライン優先で固定 */
    } else {
        defs_set(&g_defines, arg, "1");
        defs_set(&g_pinned, arg, "");
    }
}

static void add_undef(const char *name) {
    defs_remove(&g_defines, name);
    defs_set(&g_pinned, name, "");          /* 未定義のまま固定 */
}

static void usage(const char *prog) {
    fprintf(stderr,
        "FuncInspector (C) - C ソースから関数名を抽出\n"
        "使い方: %s path... [options]\n"
        "  --list-switches     コンパイルスイッチ一覧を出力 (switch,occurrences,state)\n"
        "  -D NAME[=VAL]       スイッチを ON (定義)\n"
        "  -U NAME             スイッチを OFF (未定義)\n"
        "  --ignore-switches   条件コンパイルを無視して全コードを対象\n"
        "  --external-switches ソース内 #define/#undef を無視 (スイッチは -D 選択のみ)\n"
        "  --ext .c,.h         対象拡張子 (既定 .c,.h)\n"
        "  --no-header         先頭のヘッダ行を付けない (既定は付ける)\n"
        "  --out FILE          出力先 (既定 標準出力)\n"
        "出力: filepath,line,funcname,steps\n", prog);
}

int main(int argc, char **argv) {
    const char *paths[256]; int npaths = 0;
    const char *outfile = NULL; const char *extarg = ".c,.h";
    defs_init(&g_defines);
    defs_init(&g_pinned);

    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--ext") && i + 1 < argc) extarg = argv[++i];
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) outfile = argv[++i];
        else if (!strcmp(argv[i], "--header")) g_header = 1;
        else if (!strcmp(argv[i], "--no-header")) g_header = 0;
        else if (!strcmp(argv[i], "--list-switches")) g_list_switches = 1;
        else if (!strcmp(argv[i], "--ignore-switches")) g_ignore_switches = 1;
        else if (!strcmp(argv[i], "--external-switches")) g_external = 1;
        else if (!strcmp(argv[i], "-D") && i + 1 < argc) add_define(argv[++i]);
        else if (!strncmp(argv[i], "-D", 2) && argv[i][2]) add_define(argv[i] + 2);
        else if (!strcmp(argv[i], "-U") && i + 1 < argc) add_undef(argv[++i]);
        else if (!strncmp(argv[i], "-U", 2) && argv[i][2]) add_undef(argv[i] + 2);
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
        if (g_header) fprintf(g_out, "switch,occurrences,state,filepath,line,values\n");
        for (int i = 0; i < sw.count; ++i) {
            if (sw.items[i].val_role && !sw.items[i].sw_role) continue;  /* 値定数は除外 */
            char vals[512]; sw_values_string(&sw.items[i], vals, sizeof(vals));
            fprintf(g_out, "%s,%d,%s,%s,%ld,%s\n", sw.items[i].name, sw.items[i].count,
                    defs_has(&g_defines, sw.items[i].name) ? "ON" : "OFF",
                    sw.items[i].file, sw.items[i].line, vals);
        }
        fprintf(stderr, "%d 個のスイッチ\n", sw.count);
        sw_free(&sw);
    } else {
        if (g_header) fprintf(g_out, "filepath,line,funcname,steps\n");
        for (int i = 0; i < npaths; ++i) walk(paths[i], cb_analyze, NULL);
        fprintf(stderr, "\r%-70s\r", "");   /* 進捗行をクリア */
    }

    if (outfile) fclose(g_out);
    if (!g_list_switches)
        fprintf(stderr, "%ld 関数 / 合計 %ld ステップ\n", g_func_total, g_step_total);
    defs_free(&g_defines);
    defs_free(&g_pinned);
    return 0;
}
