/* CUPS フィルタ: CUPS ラスタ -> Evolis Pebble 4（片面）
 *
 * PDF のラスタライズは macOS 標準の cgpdftoraster が行うため外部依存はない。
 * 依存を作らないため libcups は使わず、ラスタを自前で解析する。CUPS ラスタ v2/v3 のほか、
 * IPP Everywhere / AirPrint で届く PWG ラスタ(CUPS ラスタ v2 と同じ形式)と Apple ラスタ(URF)も読める。
 *
 * ここは CUPS の入口(ラスタの読み取り、PPD と印刷ダイアログのオプション、エラーの表示)だけで、
 * カードを刷るコマンドを作るところは evolis_card.c にある。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include "evolis_card.h"

#define HDRSIZE  1796      /* cups_page_header2_t */

static FILE *in;
static int   little, compressed, apple;   /* apple = Apple ラスタ (URF) */

/* メッセージの言語。CUPS はジョブの言語を LANG(ja_JP.UTF-8 など)でフィルタに渡す */
static int lang_ja;
#define T(en, ja) (lang_ja ? (ja) : (en))

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

/* CUPS ラスタ v2 / PWG ラスタ / Apple ラスタの RLE 展開 (v3 は無圧縮なので通らない)。
   行ごとに「繰り返し数 - 1」、続けて n < 128 なら同じ画素を n + 1 個、n > 128 なら 257 - n 個の画素がそのまま並ぶ。
   Apple ラスタだけは n = 128 が「行の残りを白で埋める」 */
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
            if (apple && n == 128) {
                while (len < stride) line[len++] = 0xff;
            } else if (n < 128) {
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

static evolis_options opt;
static evolis_canvas canvas;

int main(int argc, char **argv) {
    unsigned char magic[4];
    int pages = 0, npages = 0;    /* 刷ったカードの数 / 受け取ったページの数 */

    lang_ja = getenv("LANG") && !strncmp(getenv("LANG"), "ja", 2);
    evolis_default_options(&opt);
    if (argc < 6) { logmsg("ERROR", T("Not enough arguments", "引数が足りません")); return 1; }
    /* ジョブに指定がなければ、キューの PPD の既定値を使う。CUPS はダイアログで既定のまま
       にしたオプションを argv[5] に入れないので、これを読まないと黒リボン扱いになり、
       カラーリボンでも黒の1パスだけ刷って排出してしまう */
    if (getenv("PPD")) {
        FILE *ppd = fopen(getenv("PPD"), "r");
        char line[256], key[64], val[32];
        while (ppd && fgets(line, sizeof line, ppd))
            if (sscanf(line, "*Default%63[A-Za-z]: %31s", key, val) == 2)
                evolis_set_option(&opt, key, val);
        if (ppd) fclose(ppd);
    }
    /* argv[5] は "key=value key=value ..." */
    {
        char *o = strdup(argv[5]), *tok, *sp = NULL;
        for (tok = strtok_r(o, " \t", &sp); tok; tok = strtok_r(NULL, " \t", &sp)) {
            char *eq = strchr(tok, '='); if (!eq) continue; *eq = 0;
            evolis_set_option(&opt, tok, eq + 1);
        }
    }
    in = (argc > 6) ? fopen(argv[6], "rb") : stdin;
    if (!in) { logmsg("ERROR", T("Cannot open the input", "入力を開けません")); return 1; }
    if (readn(magic, 4) != 4) { logmsg("ERROR", T("The input is empty", "入力が空です")); return 1; }
    if (!memcmp(magic, "UNIR", 4)) {                  /* "UNIRAST\0" + ページ数 (4 バイト) */
        unsigned char rest[8];
        if (readn(rest, 8) != 8 || memcmp(rest, "AST", 4)) {
            logmsg("ERROR", T("Not a CUPS, PWG or Apple raster", "CUPS / PWG / Apple ラスタではありません")); return 1;
        }
        apple = 1; little = 0; compressed = 1;
    }
    else if (!memcmp(magic, "RaS2", 4)) { little = 0; compressed = 1; }
    else if (!memcmp(magic, "2SaR", 4)) { little = 1; compressed = 1; }
    else if (!memcmp(magic, "RaS3", 4)) { little = 0; compressed = 0; }
    else if (!memcmp(magic, "3SaR", 4)) { little = 1; compressed = 0; }
    else { logmsg("ERROR", T("Not a CUPS, PWG or Apple raster", "CUPS / PWG / Apple ラスタではありません")); return 1; }

    for (;;) {
        unsigned char hdr[HDRSIZE];
        unsigned hdpi, vdpi, w, h, bpp, stride, cspace;
        unsigned char *ras;
        if (apple) {
            /* Apple ラスタのページヘッダ (32 バイト): 0 = 1 画素のビット数、1 = 色空間、
               12 = 幅、16 = 高さ、20 = 解像度 (dpi)。8bit はグレー、24bit は sRGB として読む */
            if (readn(hdr, 32) != 32) break;
            bpp    = hdr[0];
            w      = rd32(hdr + 12);
            h      = rd32(hdr + 16);
            hdpi   = vdpi = rd32(hdr + 20);
            stride = w * bpp / 8;
            cspace = bpp == 8 ? 18 : 19;
        } else {
            if (readn(hdr, HDRSIZE) != HDRSIZE) break;
            hdpi   = rd32(hdr + 276);
            vdpi   = rd32(hdr + 280);
            w      = rd32(hdr + 372);
            h      = rd32(hdr + 376);
            bpp    = rd32(hdr + 388);
            stride = rd32(hdr + 392);
            cspace = rd32(hdr + 400);
        }
        if (bpp != 1 && bpp != 8 && bpp != 24) {
            logmsg("ERROR", T("Only 1, 8 and 24 bits per pixel are supported (bpp=%u)",
                                "1/8/24bit 以外は非対応です (bpp=%u)"), bpp); return 1;
        }
        if (!w || !h || !stride) { logmsg("ERROR", T("Invalid raster header", "ラスタヘッダが不正です")); return 1; }
        if (hdpi != 300 || vdpi != 300)
            logmsg("WARNING", T("Resolution is not 300 dpi (%ux%u)", "解像度が 300dpi ではありません (%ux%u)"), hdpi, vdpi);
        /* カードの大きさでないページは刷らずに止める。印刷ダイアログの用紙サイズは macOS の
           既定(A4 など)で開くので、CR80 を選び忘れると A4 のラスタが届き、そのまま刷ると
           切り抜かれた無意味なカードが1枚出てしまう */
        {
            double wmm = hdpi ? w * 25.4 / hdpi : 0, hmm = vdpi ? h * 25.4 / vdpi : 0;
            double lo = wmm < hmm ? wmm : hmm, hi = wmm < hmm ? hmm : wmm;
            if (lo < 54.0 - 2 || lo > 54.0 + 2 || hi < 85.6 - 2 || hi > 85.6 + 2) {
                logmsg("ERROR", T("The paper size is not a card (%.0f x %.0f mm). "
                                  "Set the paper size to \"CR80 card\" in the print dialog",
                                  "用紙サイズがカードではありません (%.0f x %.0f mm)。"
                                  "印刷ダイアログで用紙サイズを「カード CR80」にしてください"), wmm, hmm);
                return 1;
            }
        }
        ras = calloc((size_t)stride * h, 1);
        if (!ras) { logmsg("ERROR", T("Out of memory", "メモリ不足")); return 1; }
        if (compressed) unrle(ras, stride, h, bpp);
        else            readn(ras, (size_t)stride * h);

        evolis_place(canvas, ras, w, h, stride, bpp, cspace);
        free(ras);
        npages++;

        /* 真っ白なページは刷らない。印刷ダイアログで用紙サイズを CR80 にし忘れると、アプリは
           A4 のページを作り、macOS は用紙だけ CR80 に置き換えて送ってくる。ラスタには A4 の
           左下のカード1枚分が切り出されて真っ白になり、白紙のカードが1枚出てしまう */
        if (evolis_canvas_blank(canvas)) {
            logmsg("WARNING", T("Page %d is blank and is not printed", "ページ%d は真っ白なので刷りません"), npages);
            continue;
        }

        if (pages == 0) evolis_job_start(stdout, &opt);
        evolis_print_card(stdout, &opt, canvas);
        logmsg("INFO", T("Card %d: %ux%u dots %ubit ribbon %s density black %d color %d brightness %d black panel %s",
                         "カード%d: %ux%u ドット %ubit リボン %s コントラスト 黒%d カラー%d 明るさ%d 黒の処理 %s"),
               pages + 1, w, h, bpp, evolis_ribbon_name(opt.ribbon), opt.contrast_k, opt.contrast_color,
               opt.brightness, opt.k_line ? T("line art", "線画") : T("gray", "グレー"));
        if (evolis_ribbon_has_overlay(opt.ribbon))
            logmsg("INFO", T("Overlay %s density %d", "オーバーレイ %s 濃さ%d"),
                   evolis_overlay_name(opt.overlay), opt.contrast_o);
        pages++;
    }
    if (!pages) {
        if (npages)
            logmsg("ERROR", T("Nothing to print. Set the paper size to \"CR80 card\" in the print dialog",
                              "印刷する内容がありません。"
                              "印刷ダイアログで用紙サイズを「カード CR80」にしてください"));
        else
            logmsg("ERROR", T("No pages", "ページがありません"));
        return 1;
    }
    evolis_job_end(stdout);
    return 0;
}
