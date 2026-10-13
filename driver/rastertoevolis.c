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
#define WHITE_MIN 230      /* これより明るいものは白(網点の白抜きを守る) */
#define SOLID_FROM 60      /* 黒パネルで、この濃さ(%)以上の色は網点にせず黒ベタで刷る */

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

/* 黒パネルの網点(黒リボンとハーフパネルの右側)。
 * 樹脂の黒は1ドットがにじむので、誤差拡散のように点を散らすと 60% 前後で真っ黒に潰れる。
 * 点を中心から太らせる 6x6 の網点(300dpi で 50 線)にし、さらに実測の補正をかける。 */
static const unsigned char CLUSTER6[6][6] = {
    {32, 25, 17, 18, 26, 33},
    {24, 12,  5,  6, 13, 27},
    {16,  4,  0,  1,  7, 19},
    {23, 11,  3,  2,  8, 20},
    {31, 15, 10,  9, 14, 28},
    {35, 30, 22, 21, 29, 34},
};
/* 欲しい濃さ -> 網点に指定する濃さ (%)。目盛りカード(tools/make_halftone_cal.py)の
 * G 行をカラーリボン R3013 の黒パネルで刷って測った値を逆に引いたもの */
static const float TONE_WANT[] = { 0, 10, 17, 30, 47, 63, 76, 92, 100 };
static const float TONE_SEND[] = { 0, 7.6f, 14.6f, 23.1f, 33.0f, 44.1f, 56.5f, 70.0f, 100 };

static float tone(float want) {
    for (unsigned i = 1; i < sizeof TONE_WANT / sizeof *TONE_WANT; i++)
        if (want <= TONE_WANT[i])
            return TONE_SEND[i-1] + (want - TONE_WANT[i-1]) * (TONE_SEND[i] - TONE_SEND[i-1])
                                    / (TONE_WANT[i] - TONE_WANT[i-1]);
    return 100;
}

static void halftone(unsigned char k[CARD_H][CARD_W]) {
    /* 明るさ -> 網点のしきい値と比べる値 (0..36)。濃い色は網点だと薄く見えて
       締まらないので、SOLID_FROM 以上は黒ベタ(255 = 網点にしない印) */
    unsigned char lut[256];
    static unsigned char white[CARD_H][CARD_W];
    for (int v = 0; v < 256; v++) {
        float want = (255 - v) * 100.0f / 255;
        lut[v] = want >= SOLID_FROM ? 255 : (unsigned char)(tone(want) * 36 / 100 + 0.5f);
    }
    for (int y = 0; y < CARD_H; y++)
        for (int x = 0; x < CARD_W; x++) {
            const unsigned char *p = canvas[y][x];
            int v = (299 * p[0] + 587 * p[1] + 114 * p[2] + 500) / 1000;
            k[y][x] = lut[v] > CLUSTER6[y % 6][x % 6];
            white[y][x] = p[0] >= WHITE_MIN && p[1] >= WHITE_MIN && p[2] >= WHITE_MIN;
        }
    /* 網点の部分では、白のすぐ隣(上下左右と斜め1ドット)に点を打たない。網点は粗く、
       樹脂の黒は1ドットぶんにじむので、そのままだと網点の上の白抜き文字が埋まる。
       黒ベタの部分は黒い文字と同じく削らない */
    for (int y = 0; y < CARD_H; y++)
        for (int x = 0; x < CARD_W; x++) {
            const unsigned char *p = canvas[y][x];
            int v = (299 * p[0] + 587 * p[1] + 114 * p[2] + 500) / 1000;
            if (!k[y][x] || lut[v] == 255) continue;
            for (int dy = -1; dy <= 1; dy++)
                for (int dx = -1; dx <= 1; dx++) {
                    int yy = y + dy, xx = x + dx;
                    if (yy >= 0 && yy < CARD_H && xx >= 0 && xx < CARD_W && white[yy][xx])
                        k[y][x] = 0;
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

    halftone(k);
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
    /* ジョブに指定がなければ、キューの PPD の既定値を使う。CUPS はダイアログで既定のまま
       にしたオプションを argv[5] に入れないので、これを読まないと黒リボン扱いになり、
       カラーリボンでも黒の1パスだけ刷って排出してしまう */
    if (getenv("PPD")) {
        FILE *ppd = fopen(getenv("PPD"), "r");
        char line[256], val[32];
        while (ppd && fgets(line, sizeof line, ppd))
            if (sscanf(line, "*DefaultEvolisRibbon: %31s", val) == 1)
                for (int i = 0; i < 3; i++)
                    if (!strcmp(val, ribbon_name[i])) ribbon = i;
        if (ppd) fclose(ppd);
    }
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
        logmsg("INFO", "カード%d: %ux%u ドット %ubit リボン %s", pages + 1, w, h, bpp, ribbon_name[ribbon]);
        pages++;
    }
    if (!pages) { logmsg("ERROR", "ページがありません"); return 1; }
    for (int i = 0; i < 64; i++) fputc(0, stdout);   /* 参考実装に合わせた末尾の詰め物 */
    fflush(stdout);
    return 0;
}
