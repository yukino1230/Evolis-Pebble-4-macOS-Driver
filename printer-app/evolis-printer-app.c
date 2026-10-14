/* Evolis Printer Application: Evolis Pebble 4 を IPP Everywhere のプリンタとして見せる。
 *
 * PPD を使うドライバ(driver/rastertoevolis.c)の後継。PAPPL が IPP のサーバ、Web の設定画面、
 * DNS-SD の広告、ジョブの管理を受け持ち、macOS からはドライバ無しのプリンタ(AirPrint と同じ)に見える。
 * 届いたラスタ(Apple ラスタ / PWG ラスタ)をページごとに集め、CUPS フィルタと同じコア
 * (driver/evolis_card.c)でプリンタへのコマンドにして、USB(usb-device.m)で送る。
 *
 * リボンや濃さは IPP の独自属性(evolis-ribbon など)で、Web の設定画面の「印刷の既定値」で選ぶ。
 * 値と意味は PPD のオプションと同じ。
 *
 *   evolis-printer-app server [-o log-level=info] [-o server-port=8000]
 *   evolis-printer-app --help
 */
#include <pappl/pappl.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../driver/evolis_card.h"
#include "usb-device.h"

#ifndef EVOLIS_VERSION
#  define EVOLIS_VERSION "2.0"
#endif

#define DRIVER_NAME "evolis_pebble4"
#define CR80        "om_cr80_85.6x54mm"     /* 横長。PPD と同じ向き(縦長だと横長の PDF が回されずに切れる) */


/* 独自属性と、PPD のオプションのキーの対応。値は PPD と同じ */
static const struct vendor_option {
    const char *attr;           /* IPP の属性名 (xxx-default / xxx-supported) */
    const char *key;            /* evolis_set_option のキー */
    const char *def;            /* 既定値 */
    const char *values;         /* キーワードの候補(空白区切り)。NULL なら 0..20 の整数 */
} VENDOR[] = {
    { "evolis-ribbon",           "EvolisRibbon",          "k",    NULL /* evolis_ribbon_name で埋める */ },
    { "evolis-overlay",          "EvolisOverlay",         "full", "full none chipiso magstripe" },
    { "evolis-black-mode",       "EvolisKMode",           "gray", "gray line" },
    { "evolis-black-density",    "EvolisContrastK",       "10",   NULL },
    { "evolis-color-density",    "EvolisContrastColor",   "10",   NULL },
    { "evolis-color-brightness", "EvolisBrightness",      "10",   NULL },
    { "evolis-overlay-density",  "EvolisContrastOverlay", "10",   NULL },
};
#define NVENDOR (int)(sizeof VENDOR / sizeof *VENDOR)


/* ジョブの途中の状態 */
typedef struct {
    evolis_options opt;
    FILE          *out;         /* papplDeviceWrite に書く FILE */
    unsigned char *ras;         /* 今のページのラスタ */
    unsigned       w, h, stride, bpp, cspace;
    int            cards, pages;
} evolis_job_t;

static evolis_canvas canvas;    /* ジョブは 1 つずつ処理されるので共有でよい */


static int devwrite(void *device, const char *buf, int len) {
    return (int)papplDeviceWrite((pappl_device_t *)device, buf, (size_t)len);
}

static bool is_card(pappl_job_t *job, unsigned w, unsigned h, unsigned dpi) {
    /* カードの大きさでないページは刷らずに止める(CUPS フィルタと同じ ±2mm) */
    double wmm = dpi ? w * 25.4 / dpi : 0, hmm = dpi ? h * 25.4 / dpi : 0;
    double lo = wmm < hmm ? wmm : hmm, hi = wmm < hmm ? hmm : wmm;
    if (lo < 54.0 - 2 || lo > 54.0 + 2 || hi < 85.6 - 2 || hi > 85.6 + 2) {
        papplLogJob(job, PAPPL_LOGLEVEL_ERROR,
                    "The paper size is not a card (%.0f x %.0f mm). Set the paper size to CR80 (85.6 x 54 mm).", wmm, hmm);
        return false;
    }
    return true;
}

static bool rstartjob(pappl_job_t *job, pappl_pr_options_t *options, pappl_device_t *device) {
    evolis_job_t *ej = calloc(1, sizeof *ej);
    if (!ej) return false;
    evolis_default_options(&ej->opt);
    /* ジョブの値が無い属性には、PAPPL がプリンタの既定値(xxx-default)を入れて渡してくる */
    for (int i = 0; i < NVENDOR; i++) {
        const char *v = cupsGetOption(VENDOR[i].attr, options->num_vendor, options->vendor);
        evolis_set_option(&ej->opt, VENDOR[i].key, v ? v : VENDOR[i].def);
    }
    ej->out = funopen(device, NULL, devwrite, NULL, NULL);
    if (!ej->out) { free(ej); return false; }
    papplJobSetData(job, ej);
    papplLogJob(job, PAPPL_LOGLEVEL_INFO, "Ribbon %s, overlay %s, black %s, density black %d color %d overlay %d, brightness %d",
                evolis_ribbon_name(ej->opt.ribbon), evolis_overlay_name(ej->opt.overlay),
                ej->opt.k_line ? "line" : "gray", ej->opt.contrast_k, ej->opt.contrast_color,
                ej->opt.contrast_o, ej->opt.brightness);
    return true;
}

static bool rstartpage(pappl_job_t *job, pappl_pr_options_t *options, pappl_device_t *device, unsigned page) {
    evolis_job_t *ej = papplJobGetData(job);
    (void)device;
    ej->w = options->header.cupsWidth;
    ej->h = options->header.cupsHeight;
    ej->stride = options->header.cupsBytesPerLine;
    ej->bpp = options->header.cupsBitsPerPixel;
    ej->cspace = options->header.cupsColorSpace;
    if (ej->bpp != 1 && ej->bpp != 8 && ej->bpp != 24) {
        papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Unsupported raster (%u bits per pixel).", ej->bpp);
        return false;
    }
    papplLogJob(job, PAPPL_LOGLEVEL_DEBUG, "Page %u: %ux%u, %u bits, color space %u, %u bytes per line",
                page + 1, ej->w, ej->h, ej->bpp, ej->cspace, ej->stride);
    if (!is_card(job, ej->w, ej->h, options->header.HWResolution[0])) return false;
    free(ej->ras);
    ej->ras = malloc((size_t)ej->stride * ej->h);
    if (!ej->ras) return false;
    memset(ej->ras, 0xff, (size_t)ej->stride * ej->h);
    return true;
}

static bool rwriteline(pappl_job_t *job, pappl_pr_options_t *options, pappl_device_t *device, unsigned y,
                       const unsigned char *line) {
    evolis_job_t *ej = papplJobGetData(job);
    (void)options; (void)device;
    if (y < ej->h) memcpy(ej->ras + (size_t)y * ej->stride, line, ej->stride);
    return true;
}

static bool rendpage(pappl_job_t *job, pappl_pr_options_t *options, pappl_device_t *device, unsigned page) {
    evolis_job_t *ej = papplJobGetData(job);
    (void)options; (void)device;
    ej->pages++;
    evolis_place(canvas, ej->ras, ej->w, ej->h, ej->stride, ej->bpp, ej->cspace);
    /* 真っ白なページは刷らない(白紙のカードを出さない) */
    if (evolis_canvas_blank(canvas)) {
        papplLogJob(job, PAPPL_LOGLEVEL_WARN, "Page %u is blank and is not printed.", page + 1);
        return true;
    }
    if (ej->cards == 0) evolis_job_start(ej->out, &ej->opt);
    evolis_print_card(ej->out, &ej->opt, canvas);
    fflush(ej->out);
    ej->cards++;
    papplLogJob(job, PAPPL_LOGLEVEL_INFO, "Card %d: %ux%u dots, %u bits", ej->cards, ej->w, ej->h, ej->bpp);
    return !ferror(ej->out);
}

static bool rendjob(pappl_job_t *job, pappl_pr_options_t *options, pappl_device_t *device) {
    evolis_job_t *ej = papplJobGetData(job);
    bool ok = true;
    (void)options; (void)device;
    if (ej->cards) evolis_job_end(ej->out);
    else if (ej->pages) {
        papplLogJob(job, PAPPL_LOGLEVEL_ERROR, "Nothing to print (all pages are blank).");
        ok = false;
    }
    ok = ok && !ferror(ej->out);
    fclose(ej->out);
    free(ej->ras);
    free(ej);
    papplJobSetData(job, NULL);
    return ok;
}

/* 変換済みのデータ(application/vnd.evolis、rastertoevolis の出力など)はそのまま送る */
static bool printfile(pappl_job_t *job, pappl_pr_options_t *options, pappl_device_t *device) {
    char buf[65536];
    ssize_t n;
    int fd = open(papplJobGetFilename(job), O_RDONLY);
    (void)options;
    if (fd < 0) return false;
    while ((n = read(fd, buf, sizeof buf)) > 0)
        if (papplDeviceWrite(device, buf, (size_t)n) < 0) { close(fd); return false; }
    close(fd);
    return n == 0;
}


static bool driver_cb(pappl_system_t *system, const char *driver_name, const char *device_uri,
                      const char *device_id, pappl_pr_driver_data_t *d, ipp_t **attrs, void *data) {
    (void)device_uri; (void)device_id; (void)data;
    if (strcmp(driver_name, DRIVER_NAME)) {
        papplLog(system, PAPPL_LOGLEVEL_ERROR, "Unknown driver '%s'.", driver_name);
        return false;
    }
    d->printfile_cb  = printfile;
    d->rstartjob_cb  = rstartjob;
    d->rstartpage_cb = rstartpage;
    d->rwriteline_cb = rwriteline;
    d->rendpage_cb   = rendpage;
    d->rendjob_cb    = rendjob;
    d->format        = "application/vnd.evolis";
    papplCopyString(d->make_and_model, "Evolis Pebble 4", sizeof d->make_and_model);
    d->ppm = d->ppm_color = 1;
    d->kind = PAPPL_KIND_DOCUMENT;
    d->orient_default = IPP_ORIENT_NONE;
    d->quality_default = IPP_QUALITY_NORMAL;
    d->color_supported = PAPPL_COLOR_MODE_AUTO | PAPPL_COLOR_MODE_COLOR | PAPPL_COLOR_MODE_MONOCHROME;
    d->color_default = PAPPL_COLOR_MODE_COLOR;
    /* 1bit (black_1) は受けない。受けると PAPPL が sRGB に変換して渡してくるだけなので、グレーかカラーで送ってもらう */
    d->raster_types = PAPPL_PWG_RASTER_TYPE_SGRAY_8 | PAPPL_PWG_RASTER_TYPE_SRGB_8;
    d->duplex = PAPPL_DUPLEX_NONE;
    d->sides_supported = d->sides_default = PAPPL_SIDES_ONE_SIDED;
    d->num_resolution = 1;
    d->x_resolution[0] = d->y_resolution[0] = 300;
    d->x_default = d->y_default = 300;
    d->borderless = true;
    d->left_right = d->bottom_top = 0;

    /* 用紙は CR80 カードだけ(横長、縁なし) */
    d->num_media = 1;
    d->media[0] = CR80;
    d->num_source = 1;
    d->source[0] = "main";
    d->num_type = 1;
    d->type[0] = "cardstock";
    papplCopyString(d->media_default.size_name, CR80, sizeof d->media_default.size_name);
    d->media_default.size_width = 8560;
    d->media_default.size_length = 5400;
    papplCopyString(d->media_default.source, "main", sizeof d->media_default.source);
    papplCopyString(d->media_default.type, "cardstock", sizeof d->media_default.type);
    d->media_ready[0] = d->media_default;

    /* リボンや濃さ(独自属性)。PAPPL が Web の設定画面に出し、ジョブに既定値を入れてくれる */
    *attrs = ippNew();
    for (int i = 0; i < NVENDOR; i++) {
        char name[128];
        d->vendor[d->num_vendor++] = VENDOR[i].attr;
        snprintf(name, sizeof name, "%s-default", VENDOR[i].attr);
        if (VENDOR[i].values || i == 0) {
            const char *vals[32];
            int n = 0;
            char *tok, *sp = NULL;
            if (i == 0) {
                for (int r = 0; r < evolis_ribbon_count() && n < 32; r++) vals[n++] = evolis_ribbon_name(r);
            } else {
                static char store[NVENDOR][256];
                papplCopyString(store[i], VENDOR[i].values, sizeof store[i]);
                for (tok = strtok_r(store[i], " ", &sp); tok && n < 32; tok = strtok_r(NULL, " ", &sp)) vals[n++] = tok;
            }
            ippAddString(*attrs, IPP_TAG_PRINTER, IPP_TAG_KEYWORD, name, NULL, VENDOR[i].def);
            snprintf(name, sizeof name, "%s-supported", VENDOR[i].attr);
            ippAddStrings(*attrs, IPP_TAG_PRINTER, IPP_TAG_KEYWORD, name, n, NULL, vals);
        } else {
            ippAddInteger(*attrs, IPP_TAG_PRINTER, IPP_TAG_INTEGER, name, atoi(VENDOR[i].def));
            snprintf(name, sizeof name, "%s-supported", VENDOR[i].attr);
            ippAddRange(*attrs, IPP_TAG_PRINTER, name, 0, 20);
        }
    }
    return true;
}

/* USB でつながっている Evolis のプリンタを自動で追加する */
static const char *autoadd_cb(const char *device_info, const char *device_uri, const char *device_id, void *data) {
    (void)device_info; (void)device_uri; (void)data;
    return device_id && strcasestr(device_id, "MFG:Evolis") ? DRIVER_NAME : NULL;
}

int main(int argc, char *argv[]) {
    static pappl_pr_driver_t drivers[] = {
        { DRIVER_NAME, "Evolis Pebble 4", EVOLIS_DEVICE_ID, NULL },
    };
    evolis_usb_register();
    return papplMainloop(argc, argv, EVOLIS_VERSION,
                         "Evolis Printer Application (unofficial) &middot; "
                         "<a href=\"https://github.com/yukino1230/Evolis-Pebble-4-macOS-Driver\">GitHub</a>",
                         1, drivers, autoadd_cb, driver_cb, NULL, NULL, NULL, NULL, NULL);
}
