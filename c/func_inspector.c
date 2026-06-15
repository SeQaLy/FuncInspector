/*
 * FuncInspector (C)
 * =================
 * C ソースから「関数定義」の関数名を抽出する CUI ツール。
 *
 * 出力フォーマット:  file.c,line,funcname
 *
 *  - WINAMS などの呼び出し規約マクロが関数名の前に付いていても対応
 *    (関数名は「( の直前の識別子」として検出)
 *  - コメント / 文字列リテラルを除去してから解析
 *  - プロトタイプ宣言 (末尾 ;) や関数呼び出しは除外
 *  - フォルダ指定時は再帰的に走査 (Win32 / POSIX 両対応)
 *
 * ビルド:
 *   gcc  -O2 -o func_inspector func_inspector.c      (Linux / macOS / MinGW)
 *   cl   /O2 func_inspector.c                          (MSVC)
 *
 * 使い方:
 *   func_inspector path1 [path2 ...] [--ext .c,.h] [--header] [--out file]
 *   func_inspector ./src --out result.csv
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

/* ---- 設定 ---------------------------------------------------------------- */
static const char *KEYWORDS[] = {
    "if", "for", "while", "switch", "return", "sizeof", "do", "else",
    "goto", "case", "default", "typedef", "struct", "union", "enum",
    "static", "extern", "const", "volatile", "register", "auto",
    "signed", "unsigned", "void", "char", "short", "int", "long",
    "float", "double", "_Bool", "inline", "__inline", "__attribute__",
    "_Static_assert", "_Generic", "_Alignas", "defined", "asm", "__asm",
    NULL
};

static char  g_exts[16][16];      /* 対象拡張子 */
static int   g_ext_count = 0;
static int   g_header = 0;
static FILE *g_out = NULL;        /* 出力先 (既定 stdout) */
static long  g_total = 0;

static int is_keyword(const char *s, size_t len)
{
    for (int i = 0; KEYWORDS[i]; ++i)
        if (strlen(KEYWORDS[i]) == len && memcmp(KEYWORDS[i], s, len) == 0)
            return 1;
    return 0;
}

static int ident_start(int c) { return isalpha(c) || c == '_'; }
static int ident_char(int c)  { return isalnum(c) || c == '_'; }

/* コメント・文字列を空白へ。長さと改行位置は維持する。buf は破壊的に変更。 */
static void strip_comments_strings(char *buf, size_t n)
{
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

static int preceded_by_member(const char *s, size_t idx)
{
    long j = (long)idx - 1;
    while (j >= 0 && (s[j] == ' ' || s[j] == '\t' || s[j] == '\r' || s[j] == '\n')) j--;
    if (j < 0) return 0;
    if (s[j] == '.') return 1;
    if (s[j] == '>' && j - 1 >= 0 && s[j - 1] == '-') return 1;
    return 0;
}

static void analyze_buffer(const char *path, char *buf, size_t n)
{
    strip_comments_strings(buf, n);
    size_t i = 0;
    long line = 1;       /* i の位置の行番号を逐次追跡 */
    long mark_line = 1;  /* 識別子開始位置の行番号 */
    size_t mark = 0;

    while (i < n) {
        char c = buf[i];
        if (ident_start((unsigned char)c)) {
            mark = i; mark_line = line;
            size_t j = i;
            while (j < n && ident_char((unsigned char)buf[j])) j++;
            size_t len = j - i;

            /* 識別子内の改行は無いが、念のため line は据え置き (識別子に改行なし) */
            size_t k = j;
            while (k < n && (buf[k] == ' ' || buf[k] == '\t' || buf[k] == '\r' || buf[k] == '\n')) k++;

            if (k < n && buf[k] == '(' && !is_keyword(buf + i, len)) {
                int depth = 0; size_t p = k;
                while (p < n) {
                    if (buf[p] == '(') depth++;
                    else if (buf[p] == ')') { depth--; if (depth == 0) { p++; break; } }
                    p++;
                }
                size_t q = p;
                while (q < n && (buf[q] == ' ' || buf[q] == '\t' || buf[q] == '\r' || buf[q] == '\n')) q++;
                if (q < n && buf[q] == '{' && !preceded_by_member(buf, mark)) {
                    char name[256];
                    size_t nl = len < sizeof(name) - 1 ? len : sizeof(name) - 1;
                    memcpy(name, buf + mark, nl); name[nl] = '\0';
                    fprintf(g_out, "%s,%ld,%s\n", path, mark_line, name);
                    g_total++;
                    /* line を q+1 まで進める */
                    while (i < q + 1 && i < n) { if (buf[i] == '\n') line++; i++; }
                    continue;
                }
                /* 定義でなければ ) の後ろまで進める (改行カウント込み) */
                while (i < p && i < n) { if (buf[i] == '\n') line++; i++; }
                continue;
            } else {
                while (i < j && i < n) { if (buf[i] == '\n') line++; i++; }
                continue;
            }
        } else {
            if (c == '\n') line++;
            i++;
        }
    }
}

static void analyze_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "warning: cannot open %s\n", path); return; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return; }
    char *buf = (char *)malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return; }
    size_t rd = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    buf[rd] = '\0';
    analyze_buffer(path, buf, rd);
    free(buf);
}

static int has_target_ext(const char *name)
{
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

static void process_path(const char *path);  /* 前方宣言 */

static void process_dir(const char *path)
{
#ifdef _WIN32
    char pattern[4096];
    snprintf(pattern, sizeof(pattern), "%s%c*", path, PATH_SEP);
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        if (strcmp(fd.cFileName, ".") == 0 || strcmp(fd.cFileName, "..") == 0)
            continue;
        char child[4096];
        snprintf(child, sizeof(child), "%s%c%s", path, PATH_SEP, fd.cFileName);
        process_path(child);
    } while (FindNextFileA(h, &fd));
    FindClose(h);
#else
    DIR *d = opendir(path);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
            continue;
        char child[4096];
        snprintf(child, sizeof(child), "%s%c%s", path, PATH_SEP, e->d_name);
        process_path(child);
    }
    closedir(d);
#endif
}

static int is_directory(const char *path)
{
#ifdef _WIN32
    DWORD a = GetFileAttributesA(path);
    return (a != INVALID_FILE_ATTRIBUTES) && (a & FILE_ATTRIBUTE_DIRECTORY);
#else
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return S_ISDIR(st.st_mode);
#endif
}

static void process_path(const char *path)
{
    if (is_directory(path)) {
        process_dir(path);
    } else {
        if (has_target_ext(path))
            analyze_file(path);
    }
}

static void add_exts(const char *csv)
{
    g_ext_count = 0;
    const char *p = csv;
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

static void usage(const char *prog)
{
    fprintf(stderr,
        "FuncInspector (C) - C ソースから関数名を抽出\n"
        "使い方: %s path1 [path2 ...] [--ext .c,.h] [--header] [--out file]\n"
        "出力: file,line,funcname\n", prog);
}

int main(int argc, char **argv)
{
    const char *paths[256]; int npaths = 0;
    const char *outfile = NULL;
    const char *extarg = ".c,.h";

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--ext") == 0 && i + 1 < argc) {
            extarg = argv[++i];
        } else if (strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
            outfile = argv[++i];
        } else if (strcmp(argv[i], "--header") == 0) {
            g_header = 1;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]); return 0;
        } else {
            if (npaths < 256) paths[npaths++] = argv[i];
        }
    }

    if (npaths == 0) { usage(argv[0]); return 1; }

    add_exts(extarg);

    g_out = stdout;
    if (outfile) {
        g_out = fopen(outfile, "w");
        if (!g_out) { fprintf(stderr, "error: cannot open output %s\n", outfile); return 1; }
    }

    if (g_header) fprintf(g_out, "file,line,function\n");

    for (int i = 0; i < npaths; ++i) process_path(paths[i]);

    if (outfile) {
        fclose(g_out);
        fprintf(stderr, "%ld 件を %s に書き出しました\n", g_total, outfile);
    } else {
        fprintf(stderr, "%ld 件検出\n", g_total);
    }
    return 0;
}
