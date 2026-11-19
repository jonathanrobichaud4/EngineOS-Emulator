/* EngineOS Emulator shim, preloaded into Engine under qemu-user.
 *
 * 1. Thread affinity, real-time locking: the PC has a different CPU layout and
 *    qemu passes masks to the host, so pinning to a deck core can fail and
 *    Engine treats that as fatal. Report success; the host schedules threads.
 * 2. Screen: Engine renders with OpenGL through Qt's eglfs on Mesa's surfaceless EGL,
 *    with virgl over vtest (a host virgl_test_server does the drawing). Window surfaces
 *    become pbuffers and each eglSwapBuffers reads the frame back into a shared file the
 *    viewer reads (EMU_FB, default /tmp/emu/fb): 32-byte header then the pixels. See
 *    "OpenGL" below.
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

/* EMU_GL=1: Engine is running as the deck, on eglfs (see "OpenGL" at the end). emu.sh dump-qml
 * starts it without, on Qt's offscreen platform, only to read its resources. */
static int gl_mode(void) {
    static int m = -1;
    if (m < 0) { const char *e = getenv("EMU_GL"); m = e && *e == '1'; }
    return m;
}

/* The deck's network name (what Engine announces to other devices and Engine DJ): EMU_HOSTNAME,
 * set by emu.sh from the model or the deck's own setting. Without it Engine would announce the
 * PC's (or the VM's) host name. */
#include <sys/utsname.h>
int uname(struct utsname *u) {
    static int (*real)(struct utsname *);
    if (!real) real = dlsym(RTLD_NEXT, "uname");
    int r = real(u);
    const char *h = getenv("EMU_HOSTNAME");
    if (r == 0 && h && *h) { strncpy(u->nodename, h, sizeof u->nodename - 1); u->nodename[sizeof u->nodename - 1] = 0; }
    return r;
}
int gethostname(char *name, size_t len) {
    static int (*real)(char *, size_t);
    const char *h = getenv("EMU_HOSTNAME");
    if (h && *h) {
        if (strlen(h) + 1 > len) { errno = ENAMETOOLONG; return -1; }
        strcpy(name, h);
        return 0;
    }
    if (!real) real = dlsym(RTLD_NEXT, "gethostname");
    return real(name, len);
}

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
typedef int (*mouse_fn)(void *window, unsigned long ts, const QPointF *local, const QPointF *global,
                        int state, int button, int type, int mods, int source);
typedef int (*wheel_fn)(void *window, unsigned long ts, const QPointF *local, const QPointF *global,
                        QPoint pixel_delta, QPoint angle_delta, int mods, int phase, int source, int inverted);

static mouse_fn qt_mouse;
static wheel_fn qt_wheel;
static touch_fn qt_touch;
static void *touch_device;

static void *volatile main_window;
static int screen_w, screen_h;
static unsigned char *fb;
static size_t fb_size;
#define FB_HEADER 32
#define FB_MAX (32u << 20)

static void resolve(void) {
    if (qt_mouse) return;
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

/* ---- QML dump --------------------------------------------------------------------------
 * emu.sh dump-qml runs Engine with EMU_QML_FIND=<path filter>: every compiled-in resource whose
 * path contains it is written to /tmp/emu/dump_<path with _ for />, as stored (often zstd or
 * zlib compressed; engine/tools/dump_qml.py unpacks them). */
#define RCC_DIR 0x02
typedef unsigned char uchar;
struct rcc { const uchar *tree, *names, *data; int node_size; };
static uint32_t rd32(const uchar *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static uint16_t rd16(const uchar *p) { return (uint16_t)(p[0] << 8 | p[1]); }

static int rcc_name(const struct rcc *w, uint32_t off, char *out, size_t n) {
    const uchar *p = w->names + off; size_t len = rd16(p);
    if (!len || len + 1 > n) return 0;
    for (size_t i = 0; i < len; i++) {
        if (p[6 + i * 2] || p[7 + i * 2] < 0x20 || p[7 + i * 2] > 0x7e || p[7 + i * 2] == '/') return 0;
        out[i] = p[7 + i * 2];
    }
    out[len] = 0; return 1;
}
static void rcc_dump(const struct rcc *w, uint32_t node, const char *prefix, int depth, const char *find) {
    const uchar *e = w->tree + node * w->node_size; uint16_t flags = rd16(e + 4);
    char name[128], path[512];
    if (node == 0) path[0] = 0;
    else if (!rcc_name(w, rd32(e), name, sizeof name) || snprintf(path, sizeof path, "%s/%s", prefix, name) >= (int)sizeof path) return;
    if (flags & RCC_DIR) {
        if (depth > 32) return;
        for (uint32_t i = 0, c = rd32(e + 6), f = rd32(e + 10); i < c; i++) rcc_dump(w, f + i, path, depth + 1, find);
        return;
    }
    if (!strstr(path, find)) return;
    fprintf(stderr, "emushim: resource %s flags %x\n", path, flags);
    char out[700]; snprintf(out, sizeof out, "/tmp/emu/dump%s", path);
    for (char *q = out + 10; *q; q++) if (*q == '/') *q = '_';
    FILE *fp = fopen(out, "wb");
    if (fp) { const uchar *d = w->data + rd32(e + 10); fwrite(d, 1, rd32(d) + 4, fp); fclose(fp); }
}
int _Z21qRegisterResourceDataiPKhS0_S0_(int version, const uchar *tree, const uchar *names, const uchar *data) {
    static int (*real)(int, const uchar *, const uchar *, const uchar *);
    if (!real) real = dlsym(RTLD_NEXT, "_Z21qRegisterResourceDataiPKhS0_S0_");
    if (!real) return 0;
    const char *find = getenv("EMU_QML_FIND");
    if (find && *find && version >= 1 && version <= 3) {
        struct rcc w = {tree, names, data, version >= 2 ? 22 : 14};
        rcc_dump(&w, 0, "", 0, find);
    }
    return real(version, tree, names, data);
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

/* ---- OpenGL ----------------------------------------------------------------------------
 * Engine runs on Qt's eglfs with EGL_PLATFORM=surfaceless and Mesa's virgl driver talking to
 * a virgl_test_server on the host over a socket (GALLIUM_DRIVER=virpipe), so its GL, shaders
 * and waveforms included, is drawn natively on the PC instead of rasterized under qemu.
 * Surfaceless EGL has no windows, so the window eglfs asks for becomes a pbuffer of the screen
 * size, and every buffer swap reads the frame back into the viewer's file. */
typedef void *EGLDisplay, *EGLConfig, *EGLSurface;
typedef int32_t EGLint;
typedef unsigned EGLBoolean;
#define EGL_SURFACE_TYPE 0x3033
#define EGL_WINDOW_BIT 0x0004
#define EGL_PBUFFER_BIT 0x0001
#define EGL_WIDTH 0x3057
#define EGL_HEIGHT 0x3056
#define EGL_NONE 0x3038
#define GL_RGBA 0x1908
#define GL_BGRA_EXT 0x80E1
#define GL_UNSIGNED_BYTE 0x1401
#define GL_NO_ERROR 0
static EGLSurface gl_surface;
static int gl_w = 1280, gl_h = 800;

static void gl_screen_size(void) {
    const char *w = getenv("QT_QPA_EGLFS_WIDTH"), *h = getenv("QT_QPA_EGLFS_HEIGHT");
    if (w && atoi(w) > 0) gl_w = atoi(w);
    if (h && atoi(h) > 0) gl_h = atoi(h);
}

EGLBoolean eglChooseConfig(EGLDisplay dpy, const EGLint *attrs, EGLConfig *configs, EGLint size, EGLint *num) {
    static EGLBoolean (*real)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
    if (!real) real = dlsym(RTLD_NEXT, "eglChooseConfig");
    if (!gl_mode() || !attrs) return real(dpy, attrs, configs, size, num);
    EGLint copy[128];
    int n = 0;
    for (; attrs[n] != EGL_NONE && n < 126; n += 2) {
        copy[n] = attrs[n];
        copy[n + 1] = attrs[n] == EGL_SURFACE_TYPE ? ((attrs[n + 1] & ~EGL_WINDOW_BIT) | EGL_PBUFFER_BIT) : attrs[n + 1];
    }
    copy[n] = EGL_NONE;
    return real(dpy, copy, configs, size, num);
}

static EGLSurface gl_pbuffer(EGLDisplay dpy, EGLConfig cfg) {
    static EGLSurface (*pb)(EGLDisplay, EGLConfig, const EGLint *);
    if (!pb) pb = dlsym(RTLD_NEXT, "eglCreatePbufferSurface");
    gl_screen_size();
    EGLint a[] = {EGL_WIDTH, gl_w, EGL_HEIGHT, gl_h, EGL_NONE};
    gl_surface = pb(dpy, cfg, a);
    fprintf(stderr, "emushim: OpenGL screen %dx%d through virgl (pbuffer %p)\n", gl_w, gl_h, gl_surface);
    return gl_surface;
}
EGLSurface eglCreateWindowSurface(EGLDisplay dpy, EGLConfig cfg, uintptr_t win, const EGLint *attrs) {
    static EGLSurface (*real)(EGLDisplay, EGLConfig, uintptr_t, const EGLint *);
    if (!gl_mode()) { if (!real) real = dlsym(RTLD_NEXT, "eglCreateWindowSurface"); return real(dpy, cfg, win, attrs); }
    return gl_pbuffer(dpy, cfg);
}
EGLSurface eglCreatePlatformWindowSurface(EGLDisplay dpy, EGLConfig cfg, void *win, const intptr_t *attrs) {
    static EGLSurface (*real)(EGLDisplay, EGLConfig, void *, const intptr_t *);
    if (!gl_mode()) { if (!real) real = dlsym(RTLD_NEXT, "eglCreatePlatformWindowSurface"); return real(dpy, cfg, win, attrs); }
    return gl_pbuffer(dpy, cfg);
}

/* The window touches go to: eglfs has one full-screen window. */
static void gl_find_window(void) {
    static void *(*top_at)(const QPoint *);
    if (main_window) return;
    if (!top_at) top_at = dlsym(RTLD_DEFAULT, "_ZN15QGuiApplication10topLevelAtERK6QPoint");
    QPoint p = {gl_w / 2, gl_h / 2};
    if (top_at) main_window = top_at(&p);
}

EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface surf) {
    static EGLBoolean (*real)(EGLDisplay, EGLSurface);
    static void (*read_px)(int, int, int, int, unsigned, unsigned, void *);
    static unsigned (*get_err)(void);
    static int bgra = -1;
    static unsigned char *tmp;
    if (!real) real = dlsym(RTLD_NEXT, "eglSwapBuffers");
    if (!gl_mode() || surf != gl_surface) return real(dpy, surf);
    if (!read_px) { read_px = dlsym(RTLD_DEFAULT, "glReadPixels"); get_err = dlsym(RTLD_DEFAULT, "glGetError"); }
    resolve();
    gl_find_window();
    if (!fb) open_fb();
    size_t bpl = (size_t)gl_w * 4;
    if (read_px && fb && bpl * gl_h + FB_HEADER <= fb_size) {
        if (!tmp) tmp = malloc(bpl * gl_h);
        if (bgra != 0) {
            while (get_err && get_err() != GL_NO_ERROR) {}
            read_px(0, 0, gl_w, gl_h, GL_BGRA_EXT, GL_UNSIGNED_BYTE, tmp);
            if (bgra < 0) bgra = !(get_err && get_err() != GL_NO_ERROR);
        }
        if (bgra == 0) {
            read_px(0, 0, gl_w, gl_h, GL_RGBA, GL_UNSIGNED_BYTE, tmp);
            for (size_t i = 0; i < bpl * gl_h; i += 4) { unsigned char t = tmp[i]; tmp[i] = tmp[i + 2]; tmp[i + 2] = t; }
        }
        /* GL rows run bottom-up */
        for (int y = 0; y < gl_h; y++) memcpy(fb + FB_HEADER + (size_t)y * bpl, tmp + (size_t)(gl_h - 1 - y) * bpl, bpl);
        uint32_t *hdr = (uint32_t *)fb;
        screen_w = gl_w; screen_h = gl_h;
        hdr[1] = (uint32_t)gl_w; hdr[2] = (uint32_t)gl_h; hdr[3] = (uint32_t)bpl; hdr[4] = 5; /* QImage::Format_RGB32 */
        __atomic_store_n(&hdr[5], hdr[5] + 1, __ATOMIC_RELEASE);
        memcpy(fb, "EMUF", 4);
    }
    return real(dpy, surf);
}
