/* Evolis Pebble 4（片面）でカードを刷るためのコマンドを作る。使い方は evolis_card.h
 *
 * コマンド (Evolis Card Printers Programming Guide A5013 Rev.E / 実機で確認):
 *   ESC Pr;<ribbon> CR      リボンの種類 (RIBBONS の表)。本体に保存される。
 *                           実際のリボンと違うとカードが詰まる
 *   ESC Ss CR               シーケンス開始（カード1枚）
 *   ESC Sr CR               表面
 *   ESC Db;<p>;<n>;<data> CR パネル p (y/m/c/k/o) のビットマップ。1016x648 ドットのカードを
 *                           時計回りに90°回し、1行 648 ドット x 1016 行。
 *                           n=32/64/128 は 1 ドット 5/6/7bit (インク量, 0 = 塗らない)、n=2 は 1bit (1 = 塗る)。
 *                           どちらもビット単位で隙間なく詰め、MSB が先
 *   ESC Se CR               シーケンス終了（印刷して排出）
 */
#include "evolis_card.h"
#include <stdlib.h>
#include <string.h>

#define CARD_W EVOLIS_CARD_W
#define CARD_H EVOLIS_CARD_H

static void esc(FILE *out, const char *cmd) { fprintf(out, "\033%s\r", cmd); }

/* Y/M/C の階調。Db の段階数 32 / 64 / 128 は 1 ドット 5 / 6 / 7bit。
   128 の方がグラデーションの段差が小さい(実機で確認)。EvolisColorLevels で変えられる */
#define HALF_W    430      /* ハーフパネル(R3013)で色が乗る幅。左端から。実機で約435 */
#define K_MAX      24      /* これより暗い無彩色は黒パネルで刷る(文字をくっきりさせる) */
#define K_CHROMA   24

/* リボンの種類。color_w は Y/M/C が乗る幅(0 = 単色リボン)、overlay は全面に保護層を乗せるか。
   単色リボンはどれも k パネル 1 枚で、画像の暗いところにリボンの色が乗る */
static const struct ribbon {
    const char *name;       /* Pr に送る値 = PPD の EvolisRibbon の値 */
    int color_w, overlay;
} RIBBONS[] = {
    { "k",      0,      0 },   /* 黒 */
    { "ymcko",  CARD_W, 1 },   /* YMCKO 全面パネル */
    { "ymckos", HALF_W, 1 },   /* YMCKO ハーフパネル (R3013 など) */
    { "ko",     0,      1 },   /* 黒 + オーバーレイ */
    { "kw",     0,      0 },   /* 白 */
    { "kr",     0,      0 },   /* 赤 */
    { "kbl",    0,      0 },   /* 青 */
    { "kgr",    0,      0 },   /* 緑 */
    { "kgo",    0,      0 },   /* 金 */
    { "ksi",    0,      0 },   /* 銀 */
    { "ksc",    0,      0 },   /* スクラッチ */
    { "ka",     0,      0 },   /* 黒ワックス */
};
#define NRIBBONS (int)(sizeof RIBBONS / sizeof *RIBBONS)

static const char *OVERLAY_NAME[] = { "full", "none", "chipiso", "magstripe" };

void evolis_default_options(evolis_options *o) {
    memset(o, 0, sizeof *o);
    o->ribbon = 0;
    o->overlay = EVOLIS_OV_FULL;
    o->levels = 128; o->level_bits = 7;
    o->contrast_k = o->contrast_color = o->contrast_o = 10;
    o->brightness = 10;
}

void evolis_set_option(evolis_options *o, const char *key, const char *val) {
    if (!strcmp(key, "EvolisRibbon")) {
        for (int i = 0; i < NRIBBONS; i++)
            if (!strcmp(val, RIBBONS[i].name)) o->ribbon = i;
    } else if (!strcmp(key, "EvolisOverlay")) {
        for (int i = 0; i < 4; i++)
            if (!strcmp(val, OVERLAY_NAME[i])) o->overlay = i;
    } else if (!strcmp(key, "EvolisColorLevels")) {
        int v = atoi(val);
        if (v == 32 || v == 64 || v == 128) { o->levels = v; o->level_bits = v == 32 ? 5 : v == 64 ? 6 : 7; }
    } else if (!strcmp(key, "EvolisKMode")) {
        o->k_line = !strcmp(val, "line");
    } else if (!strcmp(key, "EvolisContrastK") || !strcmp(key, "EvolisContrastColor") ||
               !strcmp(key, "EvolisContrastOverlay") || !strcmp(key, "EvolisBrightness")) {
        int v = atoi(val);
        if (v < 0 || v > 20) return;
        if      (!strcmp(key, "EvolisContrastK"))       o->contrast_k = v;
        else if (!strcmp(key, "EvolisContrastColor"))   o->contrast_color = v;
        else if (!strcmp(key, "EvolisContrastOverlay")) o->contrast_o = v;
        else                                            o->brightness = v;
    }
}

const char *evolis_ribbon_name(int ribbon) { return RIBBONS[ribbon].name; }
const char *evolis_overlay_name(int overlay) { return OVERLAY_NAME[overlay]; }
int evolis_ribbon_has_overlay(int ribbon) { return RIBBONS[ribbon].overlay; }

void evolis_place(evolis_canvas canvas, const unsigned char *ras, unsigned w, unsigned h,
                  unsigned stride, unsigned bpp, unsigned cspace) {
    int portrait = h > w;
    unsigned lw = portrait ? h : w, lh = portrait ? w : h;
    int ox = ((int)CARD_W - (int)lw) / 2, oy = ((int)CARD_H - (int)lh) / 2;
    /* 1bit: K(3) は 1 = 黒、W(0)/sW(18) は 1 = 白。8bit グレーは W 系なら 255 = 白 */
    int black_is_one = !(cspace == 0 || cspace == 18);

    memset(canvas, 255, sizeof(evolis_canvas));
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

int evolis_canvas_blank(evolis_canvas canvas) {
    const unsigned char *c = &canvas[0][0][0];
    size_t n = sizeof(evolis_canvas), i = 0;
    while (i < n && c[i] == 255) i++;
    return i == n;
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
/* 欲しい濃さ -> 網点に指定する濃さ (%)。目盛りカード(tools/make_halftone_cal.py)を刷り、
 * グレースケールでスキャンして測った値を逆に引いたもの。にじみ方がリボンで違うので2つある */
struct tone { const float *want, *send; unsigned n; };
/* カラーリボン R3013 の黒パネル (--set methods の G 行、指定^1.6 で測定) */
static const float COLOR_WANT[] = { 0, 10, 17, 30, 47, 63, 76, 92, 100 };
static const float COLOR_SEND[] = { 0, 7.6f, 14.6f, 23.1f, 33.0f, 44.1f, 56.5f, 70.0f, 100 };
/* 黒の単色リボン (--set linear、5% 刻みを4回ずつ測った平均)。単色リボンと KO もこれを使う */
static const float MONO_WANT[] = { 0, 1.2f, 11.4f, 13.6f, 24.0f, 29.9f, 35.7f, 41.6f, 45.9f, 51.2f, 59.8f,
                                   65.6f, 74.7f, 77.3f, 81.1f, 87.7f, 91.1f, 95.9f, 96.3f, 99.1f, 100 };
static const float MONO_SEND[] = { 0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50,
                                   55, 60, 65, 70, 75, 80, 85, 90, 95, 100 };
static const struct tone TONE_COLOR = { COLOR_WANT, COLOR_SEND, sizeof COLOR_WANT / sizeof *COLOR_WANT };
static const struct tone TONE_MONO  = { MONO_WANT,  MONO_SEND,  sizeof MONO_WANT / sizeof *MONO_WANT };

static float tone(const struct tone *t, float want) {
    for (unsigned i = 1; i < t->n; i++)
        if (want <= t->want[i])
            return t->send[i-1] + (want - t->want[i-1]) * (t->send[i] - t->send[i-1])
                                  / (t->want[i] - t->want[i-1]);
    return 100;
}

static void halftone(unsigned char k[CARD_H][CARD_W], evolis_canvas canvas, const struct tone *t, int k_line) {
    /* 色は明るさだけのグレーにして網点で刷る。明るさ -> しきい値と比べる値 (0..36)。
       36 は全部の点を打つ = 黒ベタ(真っ黒な文字など)。線画は明るさの半分を境に黒ベタか白か
       (公式ドライバの Line Mode) */
    unsigned char lut[256];
    for (int v = 0; v < 256; v++)
        lut[v] = (unsigned char)(tone(t, (255 - v) * 100.0f / 255) * 36 / 100 + 0.5f);
    for (int y = 0; y < CARD_H; y++)
        for (int x = 0; x < CARD_W; x++) {
            const unsigned char *p = canvas[y][x];
            int v = (299 * p[0] + 587 * p[1] + 114 * p[2] + 500) / 1000;
            k[y][x] = k_line ? v < 128 : lut[v] > CLUSTER6[y % 6][x % 6];
        }
}

/* カードの座標 (x, y) の値を、Db の並び(1行 = x、列 = 下からの y)で bits ずつ詰める */
static void put_panel(FILE *out, const char *name, int levels, unsigned bits,
                      const unsigned char plane[CARD_H][CARD_W]) {
    unsigned acc = 0, n = 0;
    fprintf(out, "\033Db;%s;%d;", name, levels);
    for (int x = 0; x < CARD_W; x++)
        for (int c = 0; c < CARD_H; c++) {
            acc = (acc << bits) | plane[CARD_H - 1 - c][x];
            n += bits;
            while (n >= 8) { n -= 8; fputc((acc >> n) & 0xff, out); }
        }
    if (n) fputc((acc << (8 - n)) & 0xff, out);
    fputc('\r', out);
}

/* オーバーレイ(保護層)を乗せる範囲。避ける範囲はカードの表の左上からの mm (カードの規格による)。
   キャンバスはカード(1011x638)を 1016x648 の中央に置いているので、そのずれを足す */
static int mm_x(double mm) { return (int)(mm * 300 / 25.4 + 0.5) + (CARD_W - 1011) / 2; }
static int mm_y(double mm) { return (int)(mm * 300 / 25.4 + 0.5) + (CARD_H - 638) / 2; }

static int overlay_at(int mode, int px, int py) {
    switch (mode) {
    case EVOLIS_OV_NONE: return 0;
    case EVOLIS_OV_CHIP:  /* ISO 7816-2 の接点(横 10.25-19.87、縦 19.23-28.55)にモジュールの大きさ分を足す */
        return !(px >= mm_x(8.5) && px < mm_x(21.5) && py >= mm_y(17.5) && py < mm_y(30.5));
    case EVOLIS_OV_MAG:   /* ISO 7811 の磁気ストライプ(縦 5.54-15.82)に余裕を足す。裏面に刷るとき用 */
        return !(py >= mm_y(5.0) && py < mm_y(17.6));
    default: return 1;
    }
}

void evolis_job_start(FILE *out, const evolis_options *o) {
    const struct ribbon *r = &RIBBONS[o->ribbon];
    char cmd[16];
    snprintf(cmd, sizeof cmd, "Pr;%s", r->name);
    esc(out, cmd);
    snprintf(cmd, sizeof cmd, "Pc;k;=;%d", o->contrast_k);
    esc(out, cmd);
    if (r->color_w) {
        for (const char *p = "ymc"; *p; p++) {
            snprintf(cmd, sizeof cmd, "Pc;%c;=;%d", *p, o->contrast_color);
            esc(out, cmd);
        }
        /* 本体の Pl (Luminosity) は値を上げるほど色が暗く(濃く)なる(実機で確認)。
           ダイアログの「明るさ」は名前どおり上げると明るくなるように、逆にして送る */
        snprintf(cmd, sizeof cmd, "Pl;a;=;%d", 20 - o->brightness);
        esc(out, cmd);
    }
    if (r->overlay) {
        snprintf(cmd, sizeof cmd, "Pc;o;=;%d", o->contrast_o);   /* オーバーレイの濃さ */
        esc(out, cmd);
    }
}

void evolis_print_card(FILE *out, const evolis_options *o, evolis_canvas canvas) {
    static unsigned char y[CARD_H][CARD_W], m[CARD_H][CARD_W], c[CARD_H][CARD_W],
                         k[CARD_H][CARD_W], ov[CARD_H][CARD_W];
    const struct ribbon *r = &RIBBONS[o->ribbon];
    int levels = o->levels;

    halftone(k, canvas, r->color_w ? &TONE_COLOR : &TONE_MONO, o->k_line);   /* カラーリボンの黒パネルか単色リボンか */
    for (int py = 0; py < CARD_H; py++)
        for (int px = 0; px < CARD_W; px++) {
            const unsigned char *p = canvas[py][px];
            int hi = p[0], lo = p[0];
            y[py][px] = m[py][px] = c[py][px] = 0;
            ov[py][px] = (unsigned char)overlay_at(o->overlay, px, py);  /* 保護層 */
            if (px >= r->color_w) continue;               /* 色が乗らない範囲は黒の網点 */
            for (int i = 1; i < 3; i++) { if (p[i] > hi) hi = p[i]; if (p[i] < lo) lo = p[i]; }
            k[py][px] = hi < K_MAX && hi - lo < K_CHROMA;
            if (k[py][px]) continue;
            c[py][px] = (unsigned char)(((255 - p[0]) * (levels - 1) + 127) / 255);
            m[py][px] = (unsigned char)(((255 - p[1]) * (levels - 1) + 127) / 255);
            y[py][px] = (unsigned char)(((255 - p[2]) * (levels - 1) + 127) / 255);
        }
    esc(out, "Ss");
    esc(out, "Sr");
    if (r->color_w) {
        put_panel(out, "y", levels, o->level_bits, y);
        put_panel(out, "m", levels, o->level_bits, m);
        put_panel(out, "c", levels, o->level_bits, c);
    }
    put_panel(out, "k", 2, 1, k);
    if (r->overlay) put_panel(out, "o", 2, 1, ov);
    esc(out, "Se");
}

void evolis_job_end(FILE *out) {
    for (int i = 0; i < 64; i++) fputc(0, out);   /* 参考実装に合わせた末尾の詰め物 */
    fflush(out);
}
