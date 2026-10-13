/* CUPS フィルタ: CUPS ラスタ -> Evolis Pebble 4（黒リボン・片面）
 *
 * PDF のラスタライズは macOS 標準の cgpdftoraster が行うため外部依存はない。
 * 依存を作らないため libcups は使わず、ラスタを自前で解析する。
 *
 * コマンド (Evolis Programming Guide A5013 / 実機で確認):
 *   ESC Pr;k CR          リボン: 黒
 *   ESC Ss CR            シーケンス開始（カード1枚）
 *   ESC Sr CR            表面
 *   ESC Db;k;2;<data> CR ビットマップ。1016x648 ドットのカードを時計回りに90°回し、
 *                        1行 648 ドット(81バイト) x 1016 行。MSB が先、1 = 黒
 *   ESC Se CR            シーケンス終了（印刷して排出）
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

static int pixel(const unsigned char *ras, unsigned stride, unsigned x, unsigned y) {
    return (ras[(size_t)y * stride + (x >> 3)] & (0x80u >> (x & 7))) != 0;
}

/* ラスタをカード(横長 1016x648)の中央に置き、時計回りに90°回して Db 用に詰める。
   縦長のラスタ(縦向きのカード)は先に時計回りに90°回して横長にする */
static void encode_card(unsigned char *out, const unsigned char *ras,
                        unsigned w, unsigned h, unsigned stride, int invert) {
    int portrait = h > w;
    unsigned lw = portrait ? h : w, lh = portrait ? w : h;   /* 横長にした寸法 */
    int ox = ((int)CARD_W - (int)lw) / 2, oy = ((int)CARD_H - (int)lh) / 2;

    memset(out, 0, CARD_W * CARD_H / 8);
    for (unsigned r = 0; r < CARD_W; r++) {           /* 出力の行 = カードの x */
        int lx = (int)r - ox;
        if (lx < 0 || lx >= (int)lw) continue;
        for (unsigned c = 0; c < CARD_H; c++) {       /* 出力の列 = 下からの y */
            int ly = (int)(CARD_H - 1 - c) - oy;
            int bit;
            if (ly < 0 || ly >= (int)lh) continue;
            bit = portrait ? pixel(ras, stride, (unsigned)ly, h - 1 - (unsigned)lx)
                           : pixel(ras, stride, (unsigned)lx, (unsigned)ly);
            if (invert) bit = !bit;
            if (bit) out[r * (CARD_H / 8) + (c >> 3)] |= 0x80u >> (c & 7);
        }
    }
}

static void esc(const char *cmd) { printf("\033%s\r", cmd); }

int main(int argc, char **argv) {
    unsigned char magic[4];
    static unsigned char card[CARD_W * CARD_H / 8];
    int pages = 0;

    if (argc < 6) { logmsg("ERROR", "引数が足りません"); return 1; }
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
        if (bpp != 1) { logmsg("ERROR", "1bit 以外は非対応です (bpp=%u)", bpp); return 1; }
        if (!w || !h || !stride) { logmsg("ERROR", "ラスタヘッダが不正です"); return 1; }
        if (hdpi != 300 || vdpi != 300)
            logmsg("WARNING", "解像度が 300dpi ではありません (%ux%u)", hdpi, vdpi);
        ras = calloc((size_t)stride * h, 1);
        if (!ras) { logmsg("ERROR", "メモリ不足"); return 1; }
        if (compressed) unrle(ras, stride, h, bpp);
        else            readn(ras, (size_t)stride * h);

        /* cupsColorSpace 3 (K) は 1 = 黒。0 (W) / 18 (sW) は 1 = 白 */
        encode_card(card, ras, w, h, stride, cspace == 0 || cspace == 18);
        free(ras);

        if (pages == 0) esc("Pr;k");
        esc("Ss");
        esc("Sr");
        fputs("\033Db;k;2;", stdout);
        fwrite(card, 1, sizeof card, stdout);
        fputc('\r', stdout);
        esc("Se");
        logmsg("DEBUG", "カード%d: %ux%u ドット", pages + 1, w, h);
        pages++;
    }
    if (!pages) { logmsg("ERROR", "ページがありません"); return 1; }
    for (int i = 0; i < 64; i++) fputc(0, stdout);   /* 参考実装に合わせた末尾の詰め物 */
    fflush(stdout);
    return 0;
}
