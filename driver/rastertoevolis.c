/* CUPS フィルタ: CUPS ラスタ -> Evolis Pebble 4（片面）
 *
 * PDF のラスタライズは macOS 標準の cgpdftoraster が行うため外部依存はない。
 * 依存を作らないため libcups は使わず、ラスタを自前で解析する。
 *
 * コマンド (Evolis Programming Guide A5013 / 実機で確認):
 *   ESC Pr;<ribbon> CR      リボンの種類 k / ymcko / ymckos(ハーフパネル)。本体に保存される。
 *                           実際のリボンと違うとカードが詰まる
 *   ESC Ss CR               シーケンス開始（カード1枚）
 *   ESC Sr CR               表面
 *   ESC Db;<p>;<n>;<data> CR パネル p (y/m/c/k/o) のビットマップ。1016x648 ドットのカードを
 *                           時計回りに90°回し、1行 648 ドット x 1016 行。
 *                           n=32 は 1 ドット 5bit (インク量, 0 = 塗らない)、n=2 は 1bit (1 = 塗る)。
 *                           どちらもビット単位で隙間なく詰め、MSB が先
 *   ESC Se CR               シーケンス終了（印刷して排出）
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#define HDRSIZE  1796      /* cups_page_header2_t */
#define CARD_W   1016      /* プリンタが受け取るカード全面（横長, 300dpi） */
#define CARD_H    648

static FILE *in;
static int   little, compressed;

static void logmsg(const char *lv, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "%s: [rastertoevolis] ", lv);
    vfprintf(stderr, fmt, ap); fputc('\n', stderr);
    va_end(ap);
}

static unsigned rd32(const unsigned char *p) {
    return little ? (unsigned)p[0] | p[1]<<8 | p[2]<<16 | (unsigned)p[3]<<24
                  : (unsigned)p[3] | p[2]<<8 | p[1]<<16 | (unsigned)p[0]<<24;
}

static size_t readn(void *buf, size_t n) {
    size_t got = 0, r;
    while (got < n && (r = fread((char*)buf + got, 1, n - got, in)) > 0) got += r;
    return got;
}

/* CUPS ラスタ v2 の RLE 展開 (v3 は無圧縮なので通常は通らない) */
static int unrle(unsigned char *out, unsigned stride, unsigned height, unsigned bpp) {
    unsigned px = (bpp + 7) / 8; if (!px) px = 1;
    unsigned char *line = malloc(stride);
    unsigned y = 0;
    if (!line) return -1;
    while (y < height) {
        int c = fgetc(in);
        if (c == EOF) break;
        unsigned rep = (unsigned)c + 1, len = 0;
        while (len < stride) {
            int n = fgetc(in);
            if (n == EOF) break;
            if (n < 128) {
                unsigned char pix[8];
                if (readn(pix, px) != px) break;
                for (int i = 0; i <= n && len < stride; i++)
                    for (unsigned k = 0; k < px && len < stride; k++) line[len++] = pix[k];
            } else {
                unsigned cnt = (257 - (unsigned)n) * px;
                for (unsigned k = 0; k < cnt && len < stride; k++) {
                    int b = fgetc(in); if (b == EOF) break;
                    line[len++] = (unsigned char)b;
                }
            }
        }
        while (len < stride) line[len++] = 0;
        for (unsigned r = 0; r < rep && y < height; r++, y++)
            memcpy(out + (size_t)y * stride, line, stride);
    }
    free(line);
    return 0;
}

static void esc(const char *cmd) { printf("\033%s\r", cmd); }

#define LEVELS     32      /* Y/M/C の階調 (5bit) */
#define HALF_W    430      /* ハーフパネル(R3013)で色が乗る幅。左端から。実機で約435 */
#define K_MAX      24      /* これより暗い無彩色は黒パネルで刷る(文字をくっきりさせる) */
#define K_CHROMA   24

enum { RIB_K, RIB_YMCKO, RIB_YMCKOS };

/* カード(横長 1016x648)の RGB。ラスタを中央に置き、縦長なら時計回りに90°回す */
static unsigned char canvas[CARD_H][CARD_W][3];

static void place(const unsigned char *ras, unsigned w, unsigned h, unsigned stride,
                  unsigned bpp, unsigned cspace) {
    int portrait = h > w;
    unsigned lw = portrait ? h : w, lh = portrait ? w : h;
    int ox = ((int)CARD_W - (int)lw) / 2, oy = ((int)CARD_H - (int)lh) / 2;
    /* 1bit: K(3) は 1 = 黒、W(0)/sW(18) は 1 = 白。8bit グレーは W 系なら 255 = 白 */
    int black_is_one = !(cspace == 0 || cspace == 18);

    memset(canvas, 255, sizeof canvas);
    for (unsigned ly = 0; ly < lh; ly++) {
        int cy = (int)ly + oy;
        if (cy < 0 || cy >= CARD_H) continue;
        for (unsigned lx = 0; lx < lw; lx++) {
            int cx = (int)lx + ox;
            unsigned x = portrait ? ly : lx, y = portrait ? h - 1 - lx : ly;
            const unsigned char *row = ras + (size_t)y * stride;
            unsigned char *px;
            if (cx < 0 || cx >= CARD_W) continue;
            px = canvas[cy][cx];
            if (bpp == 1) {
                int bit = (row[x >> 3] & (0x80u >> (x & 7))) != 0;
                px[0] = px[1] = px[2] = (bit == black_is_one) ? 0 : 255;
            } else if (bpp == 8) {
                unsigned v = row[x];
                px[0] = px[1] = px[2] = (unsigned char)(cspace == 3 ? 255 - v : v);
            } else {                                     /* 24bit RGB */
                memcpy(px, row + x * 3, 3);
            }
        }
    }
}

/* 明るさを Floyd-Steinberg で 1bit にする(黒リボンとハーフパネルの右側) */
static void dither(unsigned char k[CARD_H][CARD_W]) {
    static float err[2][CARD_W + 2];
    memset(err, 0, sizeof err);
    for (int y = 0; y < CARD_H; y++) {
        float *cur = err[y & 1] + 1, *nxt = err[(y + 1) & 1] + 1;
        memset(nxt - 1, 0, sizeof err[0]);
        for (int x = 0; x < CARD_W; x++) {
            const unsigned char *p = canvas[y][x];
            float v = 0.299f * p[0] + 0.587f * p[1] + 0.114f * p[2] + cur[x];
            float e;
            k[y][x] = v < 128;
            e = v - (k[y][x] ? 0 : 255);
            cur[x + 1] += e * 7 / 16;
            nxt[x - 1] += e * 3 / 16;
            nxt[x]     += e * 5 / 16;
            nxt[x + 1] += e * 1 / 16;
        }
    }
}

/* カードの座標 (x, y) の値を、Db の並び(1行 = x、列 = 下からの y)で bits ずつ詰める */
static void put_panel(const char *name, int levels, unsigned bits,
                      const unsigned char plane[CARD_H][CARD_W]) {
    unsigned acc = 0, n = 0;
    printf("\033Db;%s;%d;", name, levels);
    for (int x = 0; x < CARD_W; x++)
        for (int c = 0; c < CARD_H; c++) {
            acc = (acc << bits) | plane[CARD_H - 1 - c][x];
            n += bits;
            while (n >= 8) { n -= 8; fputc((acc >> n) & 0xff, stdout); }
        }
    if (n) fputc((acc << (8 - n)) & 0xff, stdout);
    fputc('\r', stdout);
}

static void print_card(int ribbon) {
    static unsigned char y[CARD_H][CARD_W], m[CARD_H][CARD_W], c[CARD_H][CARD_W],
                         k[CARD_H][CARD_W], o[CARD_H][CARD_W];

    dither(k);
    if (ribbon != RIB_K) {
        int color_w = ribbon == RIB_YMCKOS ? HALF_W : CARD_W;
        for (int py = 0; py < CARD_H; py++)
            for (int px = 0; px < CARD_W; px++) {
                const unsigned char *p = canvas[py][px];
                int hi = p[0], lo = p[0];
                y[py][px] = m[py][px] = c[py][px] = 0;
                o[py][px] = 1;                            /* 保護層は全面 */
                if (px >= color_w) continue;              /* 色が乗らない範囲は黒のディザ */
                for (int i = 1; i < 3; i++) { if (p[i] > hi) hi = p[i]; if (p[i] < lo) lo = p[i]; }
                k[py][px] = hi < K_MAX && hi - lo < K_CHROMA;
                if (k[py][px]) continue;
                c[py][px] = (unsigned char)(((255 - p[0]) * (LEVELS - 1) + 127) / 255);
                m[py][px] = (unsigned char)(((255 - p[1]) * (LEVELS - 1) + 127) / 255);
                y[py][px] = (unsigned char)(((255 - p[2]) * (LEVELS - 1) + 127) / 255);
            }
    }
    esc("Ss");
    esc("Sr");
    if (ribbon != RIB_K) {
        put_panel("y", LEVELS, 5, y);
        put_panel("m", LEVELS, 5, m);
        put_panel("c", LEVELS, 5, c);
    }
    put_panel("k", 2, 1, k);
    if (ribbon != RIB_K) put_panel("o", 2, 1, o);
    esc("Se");
}

int main(int argc, char **argv) {
    static const char *ribbon_name[] = { "k", "ymcko", "ymckos" };
    unsigned char magic[4];
    int pages = 0, ribbon = RIB_K;

    if (argc < 6) { logmsg("ERROR", "引数が足りません"); return 1; }
    /* argv[5] は "key=value key=value ..." */
    {
        char *o = strdup(argv[5]), *tok, *sp = NULL;
        for (tok = strtok_r(o, " \t", &sp); tok; tok = strtok_r(NULL, " \t", &sp)) {
            char *eq = strchr(tok, '='); if (!eq) continue; *eq = 0;
            if (!strcmp(tok, "EvolisRibbon"))
                for (int i = 0; i < 3; i++)
                    if (!strcmp(eq + 1, ribbon_name[i])) ribbon = i;
        }
    }
    in = (argc > 6) ? fopen(argv[6], "rb") : stdin;
    if (!in) { logmsg("ERROR", "入力を開けません"); return 1; }
    if (readn(magic, 4) != 4) { logmsg("ERROR", "入力が空です"); return 1; }
    if      (!memcmp(magic, "RaS2", 4)) { little = 0; compressed = 1; }
    else if (!memcmp(magic, "2SaR", 4)) { little = 1; compressed = 1; }
    else if (!memcmp(magic, "RaS3", 4)) { little = 0; compressed = 0; }
    else if (!memcmp(magic, "3SaR", 4)) { little = 1; compressed = 0; }
    else { logmsg("ERROR", "CUPS ラスタではありません"); return 1; }

    for (;;) {
        unsigned char hdr[HDRSIZE];
        unsigned hdpi, vdpi, w, h, bpp, stride, cspace;
        unsigned char *ras;
        if (readn(hdr, HDRSIZE) != HDRSIZE) break;
        hdpi   = rd32(hdr + 276);
        vdpi   = rd32(hdr + 280);
        w      = rd32(hdr + 372);
        h      = rd32(hdr + 376);
        bpp    = rd32(hdr + 388);
        stride = rd32(hdr + 392);
        cspace = rd32(hdr + 400);
        if (bpp != 1 && bpp != 8 && bpp != 24) {
            logmsg("ERROR", "1/8/24bit 以外は非対応です (bpp=%u)", bpp); return 1;
        }
        if (!w || !h || !stride) { logmsg("ERROR", "ラスタヘッダが不正です"); return 1; }
        if (hdpi != 300 || vdpi != 300)
            logmsg("WARNING", "解像度が 300dpi ではありません (%ux%u)", hdpi, vdpi);
        ras = calloc((size_t)stride * h, 1);
        if (!ras) { logmsg("ERROR", "メモリ不足"); return 1; }
        if (compressed) unrle(ras, stride, h, bpp);
        else            readn(ras, (size_t)stride * h);

        place(ras, w, h, stride, bpp, cspace);
        free(ras);

        if (pages == 0) {
            char cmd[16];
            snprintf(cmd, sizeof cmd, "Pr;%s", ribbon_name[ribbon]);
            esc(cmd);
        }
        print_card(ribbon);
        logmsg("DEBUG", "カード%d: %ux%u ドット %ubit リボン %s", pages + 1, w, h, bpp, ribbon_name[ribbon]);
        pages++;
    }
    if (!pages) { logmsg("ERROR", "ページがありません"); return 1; }
    for (int i = 0; i < 64; i++) fputc(0, stdout);   /* 参考実装に合わせた末尾の詰め物 */
    fflush(stdout);
    return 0;
}
