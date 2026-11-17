/* EngineX emulator shim, preloaded into Engine under qemu-user.
 *
 * 1. Thread affinity, real-time locking: the PC has a different CPU layout and
 *    qemu passes masks to the host, so pinning to a deck core can fail and
 *    Engine treats that as fatal. Report success; the host schedules threads.
 * 2. Screen: Engine runs on Qt's offscreen platform with the software Qt Quick
 *    renderer. Every QBackingStore::flush (one per rendered frame) copies the
 *    window image into a shared file the viewer reads (EMU_FB, default
 *    /tmp/emu/fb): 32-byte header then the pixels.
 * 3. Input: a thread reads text commands from a FIFO (EMU_INPUT, default
 *    /tmp/emu/input) and hands them to Qt as mouse/wheel events:
 *      down X Y | move X Y | up X Y | wheel X Y DELTA
 *    Qt's QWindowSystemInterface queues them for the GUI thread itself.
 * Plain C against Qt's exported C++ symbols, so it needs no Qt headers. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/syscall.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

int pthread_setaffinity_np(pthread_t t, size_t n, const cpu_set_t *s) { (void)t; (void)n; (void)s; return 0; }
int sched_setaffinity(pid_t p, size_t n, const cpu_set_t *s) { (void)p; (void)n; (void)s; return 0; }
int mlockall(int flags) { (void)flags; return 0; }

/* ---- Qt ABI bits (32-bit ARM) ---- */
typedef struct { double x, y; } QPointF;
typedef struct { int x, y; } QPoint;
typedef struct { void *d; void *ptr; int size; } QListRaw;      /* Qt 6 QList, 32-bit */
typedef struct { void *d; void *ptr; int size; } QStringRaw;    /* null QString */
typedef struct { long long id; } QPointingDeviceUniqueId;
/* QWindowSystemInterface::TouchPoint, Qt 6.7 (qwindowsysteminterface.h), 32-bit ARM */
typedef struct {
    int id;
    long long uniqueId;
    double nx, ny;              /* normalPosition */
    double ax, ay, aw, ah;      /* area, screen coordinates, centred on the touch */
    double pressure, rotation;
    unsigned char state;        /* QEventPoint::State: 1 pressed, 2 moved, 4 stationary, 8 released */
    float vx, vy;               /* velocity */
    QListRaw rawPositions;
} TouchPoint;
_Static_assert(sizeof(TouchPoint) == 104, "TouchPoint layout");
typedef void (*pdev_ctor_fn)(void *self, const QStringRaw *name, long long systemId, int devType, int ptrType,
                             int caps, int maxPoints, int buttons, const QStringRaw *seat,
                             QPointingDeviceUniqueId uid, void *parent);
typedef void (*register_fn)(const void *device);
typedef int (*touch_fn)(void *window, unsigned long ts, const void *device, const QListRaw *points, int mods);
typedef void (*flush_fn)(void *self, const void *region, void *window, const void *offset);
typedef void *(*paint_device_fn)(void *self);
typedef int (*img_int_fn)(const void *img);
typedef const unsigned char *(*img_bits_fn)(const void *img);
typedef int (*mouse_fn)(void *window, unsigned long ts, const QPointF *local, const QPointF *global,
                        int state, int button, int type, int mods, int source);
typedef int (*wheel_fn)(void *window, unsigned long ts, const QPointF *local, const QPointF *global,
                        QPoint pixel_delta, QPoint angle_delta, int mods, int phase, int source, int inverted);

static flush_fn real_flush;
static paint_device_fn bs_paint_device, bs_window;
static img_int_fn img_width, img_height, img_bpl, img_format;
static img_bits_fn img_bits;
static mouse_fn qt_mouse;
static wheel_fn qt_wheel;
static touch_fn qt_touch;
static void *touch_device;

static void *volatile main_window;
static int screen_w, screen_h;
static int main_area;
static unsigned char *fb;
static size_t fb_size;
static struct timespec last_copy;
#define FB_HEADER 32
#define FB_MAX (32u << 20)

static void resolve(void) {
    if (real_flush) return;
    real_flush = (flush_fn)dlsym(RTLD_NEXT, "_ZN13QBackingStore5flushERK7QRegionP7QWindowRK6QPoint");
    bs_paint_device = (paint_device_fn)dlsym(RTLD_DEFAULT, "_ZN13QBackingStore11paintDeviceEv");
    bs_window = (paint_device_fn)dlsym(RTLD_DEFAULT, "_ZNK13QBackingStore6windowEv");
    img_width = (img_int_fn)dlsym(RTLD_DEFAULT, "_ZNK6QImage5widthEv");
    img_height = (img_int_fn)dlsym(RTLD_DEFAULT, "_ZNK6QImage6heightEv");
    img_bpl = (img_int_fn)dlsym(RTLD_DEFAULT, "_ZNK6QImage12bytesPerLineEv");
    img_format = (img_int_fn)dlsym(RTLD_DEFAULT, "_ZNK6QImage6formatEv");
    img_bits = (img_bits_fn)dlsym(RTLD_DEFAULT, "_ZNK6QImage9constBitsEv");
    qt_mouse = (mouse_fn)dlsym(RTLD_DEFAULT,
        "_ZN22QWindowSystemInterface16handleMouseEventINS_20AsynchronousDeliveryEEEbP7QWindowmRK7QPointFS6_6QFlagsIN2Qt11MouseButtonEES9_N6QEvent4TypeES7_INS8_16KeyboardModifierEENS8_16MouseEventSourceE");
    qt_touch = (touch_fn)dlsym(RTLD_DEFAULT,
        "_ZN22QWindowSystemInterface16handleTouchEventINS_20AsynchronousDeliveryEEEbP7QWindowmPK15QPointingDeviceRK5QListINS_10TouchPointEE6QFlagsIN2Qt16KeyboardModifierEE");
    qt_wheel = (wheel_fn)dlsym(RTLD_DEFAULT,
        "_ZN22QWindowSystemInterface16handleWheelEventEP7QWindowmRK7QPointFS4_6QPointS5_6QFlagsIN2Qt16KeyboardModifierEENS7_11ScrollPhaseENS7_16MouseEventSourceEb");
}

static void open_fb(void) {
    const char *path = getenv("EMU_FB");
    if (!path) path = "/tmp/emu/fb";
    mkdir("/tmp/emu", 0755);
    int fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0) return;
    if (ftruncate(fd, FB_MAX) == 0) {
        void *p = mmap(NULL, FB_MAX, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (p != MAP_FAILED) { fb = p; fb_size = FB_MAX; }
    }
    close(fd);
}

static void copy_frame(void *window, void *image) {
    int w = img_width(image), h = img_height(image), bpl = img_bpl(image), fmt = img_format(image);
    const unsigned char *bits = img_bits(image);
    if (w <= 0 || h <= 0 || !bits) return;
    static void *seen[16];
    static int nseen;
    int known = 0;
    for (int i = 0; i < nseen; ++i) if (seen[i] == window) known = 1;
    if (!known && nseen < 16) {
        seen[nseen++] = window;
        if (getenv("EMU_DEBUG")) fprintf(stderr, "emushim: window %p flushes %dx%d format %d\n", window, w, h, fmt);
    }
    if (w * h >= main_area) { main_area = w * h; main_window = window; }
    if (window != main_window) return;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    long ms = (now.tv_sec - last_copy.tv_sec) * 1000 + (now.tv_nsec - last_copy.tv_nsec) / 1000000;
    if (ms < 40) return; /* about 25 frames a second is plenty for a viewer */
    last_copy = now;
    if (!fb) open_fb();
    if (!fb || (size_t)bpl * h + FB_HEADER > fb_size) return;
    uint32_t *hdr = (uint32_t *)fb;
    memcpy(fb + FB_HEADER, bits, (size_t)bpl * h);
    screen_w = w; screen_h = h;
    hdr[1] = (uint32_t)w; hdr[2] = (uint32_t)h; hdr[3] = (uint32_t)bpl; hdr[4] = (uint32_t)fmt;
    __atomic_store_n(&hdr[5], hdr[5] + 1, __ATOMIC_RELEASE); /* frame counter */
    memcpy(fb, "EMUF", 4);
}

void _ZN13QBackingStore5flushERK7QRegionP7QWindowRK6QPoint(void *self, const void *region, void *window, const void *offset) {
    resolve();
    if (real_flush) real_flush(self, region, window, offset);
    if (bs_paint_device && img_bits) {
        void *img = bs_paint_device(self);
        /* Qt Quick's software loop flushes with no window: it means the store's own. */
        if (!window && bs_window) window = bs_window(self);
        if (img && window) copy_frame(window, img);
    }
}

static unsigned long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (unsigned long)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
}

/* The deck's screen is a touchscreen and Engine only reacts to touch, so register a
 * touchscreen device like the deck's evdev one and send touch points to it. */
static void make_touch_device(void) {
    if (touch_device) return;
    pdev_ctor_fn ctor = (pdev_ctor_fn)dlsym(RTLD_DEFAULT,
        "_ZN15QPointingDeviceC2ERK7QStringxN12QInputDevice10DeviceTypeENS_11PointerTypeE6QFlagsINS3_10CapabilityEEiiS2_23QPointingDeviceUniqueIdP7QObject");
    register_fn reg = (register_fn)dlsym(RTLD_DEFAULT, "_ZN22QWindowSystemInterface19registerInputDeviceEPK12QInputDevice");
    if (!ctor || !reg) return;
    void *dev = calloc(1, 256); /* QObject-sized; kept for the life of the process */
    QStringRaw none = {0, 0, 0};
    QPointingDeviceUniqueId uid = {-1};
    ctor(dev, &none, 1, 0x2 /* TouchScreen */, 0x2 /* Finger */, 0x1 | 0x2 | 0x20 /* Position, Area, NormalizedPosition */,
         10, 0, &none, uid, NULL);
    reg(dev);
    touch_device = dev;
}

static int send_touch(void *win, double x, double y, int state) {
    if (!qt_touch) return -1;
    make_touch_device();
    if (!touch_device) return -1;
    TouchPoint p;
    memset(&p, 0, sizeof p);
    p.id = 0;
    p.uniqueId = -1;
    p.ax = x - 4; p.ay = y - 4; p.aw = 8; p.ah = 8;
    p.nx = screen_w > 0 ? x / screen_w : 0; p.ny = screen_h > 0 ? y / screen_h : 0;
    p.pressure = state == 8 ? 0.0 : 1.0;
    p.state = (unsigned char)state;
    QListRaw list = {NULL, &p, 1};
    return qt_touch(win, now_ms(), touch_device, &list, 0);
}

static void *input_thread(void *arg) {
    (void)arg;
    const char *path = getenv("EMU_INPUT");
    if (!path) path = "/tmp/emu/input";
    mkdir("/tmp/emu", 0755);
    unlink(path);
    if (mkfifo(path, 0666) && errno != EEXIST) return NULL;
    char line[128];
    int buttons = 0;
    for (;;) {
        FILE *f = fopen(path, "r");
        if (!f) { sleep(1); continue; }
        if (getenv("EMU_DEBUG")) fprintf(stderr, "emushim: input pipe opened\n");
        while (fgets(line, sizeof line, f)) {
            resolve();
            void *win = main_window;
            if (getenv("EMU_DEBUG")) fprintf(stderr, "emushim: %.*s window=%p\n", (int)strcspn(line, "\n"), line, win);
            if (!win || !qt_mouse) continue;
            char cmd[16]; double x = 0, y = 0; int d = 0;
            if (sscanf(line, "%15s %lf %lf %d", cmd, &x, &y, &d) < 3) continue;
            QPointF p = {x, y};
            int rc = -1;
            /* down/move/up: touch, like the deck's screen. mdown/mmove/mup: mouse. */
            if (!strcmp(cmd, "down")) rc = send_touch(win, x, y, 1);
            else if (!strcmp(cmd, "move")) rc = send_touch(win, x, y, 2);
            else if (!strcmp(cmd, "up")) rc = send_touch(win, x, y, 8);
            else if (!strcmp(cmd, "mdown")) { buttons = 1; rc = qt_mouse(win, now_ms(), &p, &p, buttons, 1, 2, 0, 0); }
            else if (!strcmp(cmd, "mup")) { buttons = 0; rc = qt_mouse(win, now_ms(), &p, &p, buttons, 1, 3, 0, 0); }
            else if (!strcmp(cmd, "mmove")) rc = qt_mouse(win, now_ms(), &p, &p, buttons, 0, 5, 0, 0);
            else if (!strcmp(cmd, "wheel") && qt_wheel) {
                QPoint none = {0, 0}, angle = {0, d}; /* 120 per wheel notch */
                rc = qt_wheel(win, now_ms(), &p, &p, none, angle, 0, 0, 0, 0);
            }
            if (getenv("EMU_DEBUG")) fprintf(stderr, "emushim: -> %d\n", rc);
        }
        fclose(f);
    }
    return NULL;
}

__attribute__((constructor)) static void emu_start(void) {
    const char *self = getenv("EMU_SHIM_PROCESS"); /* only the Engine process */
    char exe[256] = {0};
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (n <= 0) return;
    exe[n] = 0;
    if (!strstr(exe, self ? self : "/usr/Engine/Engine")) return;
    pthread_t t;
    pthread_create(&t, NULL, input_thread, NULL);
    pthread_detach(t);
}

/* ---- QML overlay ----------------------------------------------------------------------
 * Some built-in QML can't draw under the software renderer (UIKit/ColoredImage.qml is a
 * ShaderEffect, so every icon vanished). Any file under /etc/emu/qml/<resource path> replaces
 * the compiled-in resource of the same path, the same way EngineX's UI packs do. This runs
 * before the EngineX hook in LD_PRELOAD order, so a pack or mod file still wins. */
#define OVL_ROOT "/etc/emu/qml"
#define RCC_DIR 0x02
#define RCC_COMPRESSED 0x01
#define RCC_ZSTD 0x04
typedef unsigned char uchar;
struct ovl { uchar *tree; const uchar *names; const uchar *data; int node_size; int replaced; };
static uint32_t rd32(const uchar *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static uint16_t rd16(const uchar *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static void wr32(uchar *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

static uchar *ovl_blob(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat st; uchar *b = NULL;
    if (!fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_size > 0 && st.st_size < (16 << 20) &&
        (b = malloc(st.st_size + 4))) {
        wr32(b, st.st_size);
        if (read(fd, b + 4, st.st_size) != st.st_size) { free(b); b = NULL; }
    }
    close(fd);
    return b;
}
static int ovl_name(const struct ovl *w, uint32_t off, char *out, size_t n) {
    const uchar *p = w->names + off; size_t len = rd16(p);
    if (!len || len + 1 > n) return 0;
    for (size_t i = 0; i < len; i++) {
        if (p[6 + i * 2] || p[7 + i * 2] < 0x20 || p[7 + i * 2] > 0x7e || p[7 + i * 2] == '/') return 0;
        out[i] = p[7 + i * 2];
    }
    out[len] = 0; return 1;
}
static uint32_t ovl_max(const struct ovl *w, uint32_t node) {
    const uchar *e = w->tree + node * w->node_size; uint32_t top = node;
    if (rd16(e + 4) & RCC_DIR)
        for (uint32_t i = 0, c = rd32(e + 6), f = rd32(e + 10); i < c; i++) { uint32_t m = ovl_max(w, f + i); if (m > top) top = m; }
    return top;
}
static void ovl_apply(struct ovl *w, uint32_t node, const char *prefix, int depth) {
    uchar *e = w->tree + node * w->node_size; uint16_t flags = rd16(e + 4);
    char name[128], path[512];
    if (node == 0) path[0] = 0;
    else if (!ovl_name(w, rd32(e), name, sizeof name) || snprintf(path, sizeof path, "%s/%s", prefix, name) >= (int)sizeof path) return;
    if (flags & RCC_DIR) {
        if (depth > 32) return;
        for (uint32_t i = 0, c = rd32(e + 6), f = rd32(e + 10); i < c; i++) ovl_apply(w, f + i, path, depth + 1);
        return;
    }
    { const char *f = getenv("EMU_QML_FIND");
      if (f && *f && strstr(path, f)) {
        fprintf(stderr, "emushim: resource %s flags %x\n", path, flags);
        char out[700]; snprintf(out, sizeof out, "/tmp/emu/dump%s", path);
        for (char *q = out + 10; *q; q++) if (*q == '/') *q = '_';
        FILE *fp = fopen(out, "wb");
        if (fp) { const uchar *d = w->data + rd32(e + 10); fwrite(d, 1, rd32(d) + 4, fp); fclose(fp); }
      } }
    char file[700]; snprintf(file, sizeof file, OVL_ROOT "%s", path);
    uchar *b = ovl_blob(file);
    if (!b) return;
    wr32(e + 10, (uint32_t)((uintptr_t)b - (uintptr_t)w->data));
    flags &= ~(RCC_COMPRESSED | RCC_ZSTD); e[4] = flags >> 8; e[5] = flags;
    if (w->node_size >= 22) { /* content-based timestamp so Engine's forced .qmlc cache recompiles */
        uint64_t h = 0xcbf29ce484222325ULL; const uchar *p = b + 4;
        for (uint32_t n = rd32(b); n--;) h = (h ^ *p++) * 0x100000001b3ULL;
        uint64_t stamp = 1577836800000ULL + h % 2524608000000ULL;
        wr32(e + 14, stamp >> 32); wr32(e + 18, (uint32_t)stamp);
    }
    w->replaced++;
    fprintf(stderr, "emushim: qml overlay %s\n", path);
}
int _Z21qRegisterResourceDataiPKhS0_S0_(int version, const uchar *tree, const uchar *names, const uchar *data) {
    static int (*real)(int, const uchar *, const uchar *, const uchar *);
    if (!real) real = dlsym(RTLD_NEXT, "_Z21qRegisterResourceDataiPKhS0_S0_");
    if (!real) return 0;
    struct stat st;
    if (version < 1 || version > 3 || stat(OVL_ROOT, &st) || !S_ISDIR(st.st_mode)) return real(version, tree, names, data);
    struct ovl w = {.tree = (uchar *)tree, .names = names, .data = data, .node_size = version >= 2 ? 22 : 14};
    size_t bytes = (size_t)(ovl_max(&w, 0) + 1) * w.node_size;
    uchar *copy = malloc(bytes);
    if (!copy) return real(version, tree, names, data);
    memcpy(copy, tree, bytes); w.tree = copy;
    ovl_apply(&w, 0, "", 0);
    if (!w.replaced) { free(copy); return real(version, tree, names, data); }
    return real(version, copy, names, data);
}

/* ---- crash report ---------------------------------------------------------------------
 * qemu only says "uncaught target signal 11". Print where it happened (pc, lr, fault
 * address, which library) plus return-address candidates from the stack, then crash as before. */
#include <signal.h>
#include <ucontext.h>
static void crash_where(const char *tag, uintptr_t a) {
    Dl_info di;
    if (a && dladdr((void *)a, &di) && di.dli_fname)
        fprintf(stderr, "emushim crash: %s %#lx = %s+%#lx (%s)\n", tag, (unsigned long)a, di.dli_fname,
                (unsigned long)(a - (uintptr_t)di.dli_fbase), di.dli_sname ? di.dli_sname : "?");
    else
        fprintf(stderr, "emushim crash: %s %#lx\n", tag, (unsigned long)a);
}
static void crash_handler(int sig, siginfo_t *si, void *ctx) {
    ucontext_t *uc = ctx;
    fprintf(stderr, "emushim crash: signal %d, fault address %p, thread %ld\n", sig, si->si_addr, (long)syscall(SYS_gettid));
    crash_where("pc", uc->uc_mcontext.arm_pc);
    crash_where("lr", uc->uc_mcontext.arm_lr);
    uintptr_t *sp = (uintptr_t *)uc->uc_mcontext.arm_sp;
    int shown = 0;
    for (int i = 0; i < 512 && shown < 16; i++) {
        Dl_info di;
        uintptr_t v = sp[i];
        if ((v & 1) == 0 && v > 0x10000 && dladdr((void *)v, &di) && di.dli_fname && (v - (uintptr_t)di.dli_fbase) > 0x100) {
            crash_where("stack", v);
            shown++;
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}
__attribute__((constructor)) static void crash_init(void) {
    char exe[256] = {0};
    if (readlink("/proc/self/exe", exe, sizeof exe - 1) < 0 || !strstr(exe, "Engine")) return;
    static char altstack[65536];
    stack_t ss = {.ss_sp = altstack, .ss_size = sizeof altstack};
    sigaltstack(&ss, NULL);
    struct sigaction sa = {0};
    sa.sa_sigaction = crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
}

/* ---- GL without a GL context ------------------------------------------------------------
 * The emulator renders with Qt's software backend, so there is no OpenGL context. Some of
 * Engine's own scene-graph code (waveform and artwork textures) still does
 * QOpenGLContext::currentContext()->functions()->glXxx(...) and crashed on the null context
 * as soon as a track loaded. With no context, hand back a function table where every entry is
 * a no-op returning 0: those items just draw nothing. */
static int gl_nop(void) { return 0; }
static void *g_fake_gl_table[2048];
static struct { void **d_ptr; } g_fake_gl_funcs = {g_fake_gl_table};
static void fake_gl_init(void) {
    if (g_fake_gl_table[0]) return;
    for (unsigned i = 0; i < sizeof g_fake_gl_table / sizeof g_fake_gl_table[0]; i++) g_fake_gl_table[i] = (void *)gl_nop;
}
void *_ZNK14QOpenGLContext9functionsEv(const void *ctx) {
    static void *(*real)(const void *);
    if (ctx) {
        if (!real) real = dlsym(RTLD_NEXT, "_ZNK14QOpenGLContext9functionsEv");
        return real(ctx);
    }
    fake_gl_init();
    return &g_fake_gl_funcs;
}
void *_ZNK14QOpenGLContext14extraFunctionsEv(const void *ctx) {
    static void *(*real)(const void *);
    if (ctx) {
        if (!real) real = dlsym(RTLD_NEXT, "_ZNK14QOpenGLContext14extraFunctionsEv");
        return real(ctx);
    }
    fake_gl_init();
    return &g_fake_gl_funcs;
}

/* QQuickFramebufferObject (Engine's waveforms) needs OpenGL to create its renderer and FBO.
 * Under the software renderer, skip it: no node, nothing drawn, nothing created. Engine's
 * subclasses inherit updatePaintNode, so their vtables resolve to this one. */
void *_ZN22QQuickFramebufferObject15updatePaintNodeEP7QSGNodePN10QQuickItem19UpdatePaintNodeDataE(void *self, void *old, void *data) {
    static void *(*real)(void *, void *, void *);
    static void *(*current)(void);
    if (!current) current = dlsym(RTLD_DEFAULT, "_ZN14QOpenGLContext14currentContextEv");
    if (current && current()) {
        if (!real) real = dlsym(RTLD_NEXT, "_ZN22QQuickFramebufferObject15updatePaintNodeEP7QSGNodePN10QQuickItem19UpdatePaintNodeDataE");
        return real(self, old, data);
    }
    static int warned;
    if (!warned++) fprintf(stderr, "emushim: OpenGL items (waveforms) are not drawn under the software renderer\n");
    return old;
}

/* ---- switch off OpenGL-only items ------------------------------------------------------
 * /etc/emu/gl-items.txt (made at setup by tools/gl_items.py) lists Engine updatePaintNode
 * overrides that build OpenGL framebuffers: "<offset> <first 8 bytes hex> <class>". Each one
 * whose bytes match is patched to "return oldNode" (mov r0, r1; bx lr), so it draws nothing
 * instead of crashing without a GL context. Bytes that don't match (another Engine build) are
 * left alone. */
#include <link.h>
static int main_base_cb(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    *(uintptr_t *)data = info->dlpi_addr;
    return 1; /* first entry is the main program */
}
__attribute__((constructor)) static void gl_items_patch(void) {
    char exe[256] = {0};
    if (readlink("/proc/self/exe", exe, sizeof exe - 1) < 0 || !strstr(exe, "/usr/Engine/Engine")) return;
    FILE *f = fopen("/etc/emu/gl-items.txt", "r");
    if (!f) return;
    uintptr_t base = 0;
    dl_iterate_phdr(main_base_cb, &base);
    char line[256];
    while (fgets(line, sizeof line, f)) {
        unsigned long off; char hex[17], name[128] = "";
        if (line[0] == '#' || sscanf(line, "%lx %16s %127s", &off, hex, name) < 2) continue;
        unsigned char want[8];
        for (int i = 0; i < 8; i++) sscanf(hex + 2 * i, "%2hhx", &want[i]);
        unsigned char *p = (unsigned char *)(base + off);
        if (memcmp(p, want, 8)) { fprintf(stderr, "emushim: %s at %#lx doesn't match, not patched\n", name, off); continue; }
        uintptr_t pg = (uintptr_t)p & ~(uintptr_t)4095;
        if (mprotect((void *)pg, 8192, PROT_READ | PROT_WRITE | PROT_EXEC)) continue;
        static const uint32_t ret_old[2] = {0xE1A00001, 0xE12FFF1E}; /* mov r0, r1; bx lr */
        memcpy(p, ret_old, 8);
        __builtin___clear_cache((char *)p, (char *)p + 8);
        mprotect((void *)pg, 8192, PROT_READ | PROT_EXEC);
        fprintf(stderr, "emushim: %s drawn as empty (needs OpenGL)\n", name);
    }
    fclose(f);
}
