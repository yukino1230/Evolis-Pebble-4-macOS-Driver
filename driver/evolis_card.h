/* Evolis Pebble 4（片面）でカードを刷るためのコマンドを作る。
 *
 * カードの RGB 画像とオプションから、プリンタに送るバイト列を作るところだけを持つ。
 * CUPS にも PPD にも頼らないので、CUPS フィルタ(rastertoevolis.c)のほかに、
 * PPD が使えなくなったときの Printer Application(IPP Everywhere)からもそのまま使える。
 *
 * 使い方:
 *   evolis_options o; evolis_default_options(&o);
 *   evolis_set_option(&o, "EvolisRibbon", "ymckos");     キーと値は PPD のオプションと同じ
 *   evolis_place(canvas, ...)                            ラスタをカードの大きさに置く
 *   evolis_job_start(out, &o);                           1 枚目の前に 1 回
 *   evolis_print_card(out, &o, canvas);                  カード 1 枚ごと
 *   evolis_job_end(out);
 */
#ifndef EVOLIS_CARD_INCLUDED
#define EVOLIS_CARD_INCLUDED
#include <stdio.h>

#define EVOLIS_CARD_W 1016      /* プリンタが受け取るカード全面（横長, 300dpi） */
#define EVOLIS_CARD_H  648

/* カード(横長)の RGB。白 = 255 */
typedef unsigned char evolis_canvas[EVOLIS_CARD_H][EVOLIS_CARD_W][3];

enum { EVOLIS_OV_FULL, EVOLIS_OV_NONE, EVOLIS_OV_CHIP, EVOLIS_OV_MAG };

typedef struct {
    int ribbon;             /* evolis_ribbon_name() の番号 */
    int overlay;            /* EVOLIS_OV_* */
    int levels, level_bits; /* Y/M/C の段階数(32/64/128)と 1 ドットのビット数 */
    int k_line;             /* 黒パネル 0 = グレー(網点)、1 = 線画 */
    int contrast_k, contrast_color, contrast_o;   /* Pc の値 0..20、工場出荷時 10 */
    int brightness;         /* 印刷ダイアログの明るさ 0..20 (標準 10)。大きいほど明るい */
} evolis_options;

void evolis_default_options(evolis_options *o);
/* PPD のキーと値(EvolisRibbon=ymckos など)で設定する。知らないキーや範囲外の値は無視する */
void evolis_set_option(evolis_options *o, const char *key, const char *val);

/* 名前(ログ用)。リボンは Pr に送る値 = PPD の EvolisRibbon の値 */
const char *evolis_ribbon_name(int ribbon);
int evolis_ribbon_count(void);
const char *evolis_overlay_name(int overlay);
int evolis_ribbon_has_overlay(int ribbon);

/* ラスタ 1 ページをカードの中央に置く。縦長なら時計回りに 90° 回す。
   bpp は 1 / 8 / 24、cspace は CUPS / PWG の色空間の番号(3 = K、18 = sW、1 = RGB など) */
void evolis_place(evolis_canvas canvas, const unsigned char *ras, unsigned w, unsigned h,
                  unsigned stride, unsigned bpp, unsigned cspace);
int evolis_canvas_blank(evolis_canvas canvas);

/* リボンの種類と濃さを本体に設定する(本体に残るので、標準の値でも毎回送る) */
void evolis_job_start(FILE *out, const evolis_options *o);
/* カード 1 枚分のコマンドを書く。メモリが足りないときは -1 */
int evolis_print_card(FILE *out, const evolis_options *o, evolis_canvas canvas);
void evolis_job_end(FILE *out);

#endif
