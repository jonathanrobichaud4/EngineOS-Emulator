/* alsa_emu.c - ALSA stand-in for the EngineX emulator (part of libemushim.so).
 *
 * WSL2 has no sound drivers, and qemu-user couldn't translate ALSA ioctls anyway, so the
 * libasound calls Engine makes are answered here instead:
 *
 *  - Sequencer: a "Control Surface" client (16:0), like the SC LIVE 4's internal serial MIDI.
 *    It answers the MIDI identity request as a JP21 controller, so Engine loads the real
 *    "JP21 Controller" assignment. MIDI to the device is appended as hex lines to
 *    /tmp/emu/midi-out (LEDs, displays); hex lines written to the FIFO /tmp/emu/midi-in are
 *    delivered to Engine as if the hardware sent them (buttons, knobs, faders, jogs).
 *  - PCM: any device opens. Writes are paced in real time and one stereo pair of one playback
 *    device is copied, as 16-bit stereo, to the ring /tmp/emu/audio for the browser.
 *    Capture devices deliver silence at the right pace.
 *  - Cards and mixer controls: a fixed set of cards; control reads/writes succeed and are logged.
 *
 * Opaque libasound types (snd_seq_t, snd_pcm_hw_params_t, ...) are our own structs here;
 * every accessor Engine imports is defined below, so it never sees the real layouts.
 * snd_seq_event_t is public, so that one uses the real ABI layout from the ALSA headers.
 */
#define _GNU_SOURCE
#include <alsa/asoundlib.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define EXPORT __attribute__((visibility("default")))

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_debug = -1;

static void alog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("emushim alsa: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}
#define DBG(...) do { if (g_debug < 0) g_debug = getenv("EMU_DEBUG") && atoi(getenv("EMU_DEBUG")); if (g_debug) alog(__VA_ARGS__); } while (0)

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ===================================================================== cards ============ */

struct fcard { const char *id, *name, *components; int midi; int pcm_play, pcm_cap; };
/* The deck's built-in codec, its serial control surface and its USB audio gadget.
 * Names follow the deck where known; EMU_CARDS can't change them yet. */
static const struct fcard g_cards[] = {
    {"Surface", "Control Surface", "", 1, 0, 0},
    {"JP21", "JP21", "", 0, 1, 1},
    {"UAC2Gadget", "UAC2_Gadget", "", 0, 1, 0},
};
#define NCARDS (int)(sizeof g_cards / sizeof g_cards[0])
#define MIDI_CARD 0

EXPORT int snd_card_next(int *card) {
    if (!card) return -EINVAL;
    *card = (*card < 0) ? 0 : *card + 1;
    if (*card >= NCARDS) *card = -1;
    return 0;
}

struct fctl { int card; char name[64]; int pcm_dev_iter; };
struct fcard_info { int card; const struct fcard *c; };
struct felem_id { int iface; char name[64]; unsigned index; };
struct felem_info { struct felem_id id; int type; unsigned count; };
struct felem_value { struct felem_id id; long ints[128]; unsigned char bytes[512]; };
struct fpcm_info { int card, device, subdevice, stream; char name[64]; };

static int card_from_name(const char *name) {
    if (!name) return 0;
    const char *p = strchr(name, ':');
    if (!p) return 0;
    p++;
    if (*p >= '0' && *p <= '9') return atoi(p);
    for (int i = 0; i < NCARDS; i++)
        if (!strncmp(p, g_cards[i].id, strlen(g_cards[i].id)) || !strncmp(p, g_cards[i].name, strlen(g_cards[i].name)))
            return i;
    return -1;
}

EXPORT int snd_ctl_open(snd_ctl_t **ctl, const char *name, int mode) {
    (void)mode;
    int c = card_from_name(name);
    DBG("ctl_open %s -> card %d", name, c);
    if (c < 0 || c >= NCARDS) return -ENOENT;
    struct fctl *f = calloc(1, sizeof *f);
    f->card = c; f->pcm_dev_iter = -1;
    snprintf(f->name, sizeof f->name, "%s", name ? name : "");
    *ctl = (snd_ctl_t *)f;
    return 0;
}
EXPORT int snd_ctl_close(snd_ctl_t *ctl) { free(ctl); return 0; }
EXPORT size_t snd_ctl_card_info_sizeof(void) { return sizeof(struct fcard_info); }
EXPORT int snd_ctl_card_info(snd_ctl_t *ctl, snd_ctl_card_info_t *info) {
    struct fctl *f = (struct fctl *)ctl; struct fcard_info *i = (struct fcard_info *)info;
    i->card = f->card; i->c = &g_cards[f->card];
    return 0;
}
EXPORT const char *snd_ctl_card_info_get_name(const snd_ctl_card_info_t *info) { return ((const struct fcard_info *)info)->c->name; }
EXPORT const char *snd_ctl_card_info_get_components(const snd_ctl_card_info_t *info) { return ((const struct fcard_info *)info)->c->components; }

EXPORT int snd_ctl_pcm_next_device(snd_ctl_t *ctl, int *device) {
    struct fctl *f = (struct fctl *)ctl; const struct fcard *c = &g_cards[f->card];
    int next = *device < 0 ? 0 : *device + 1;
    *device = (next == 0 && (c->pcm_play || c->pcm_cap)) ? 0 : -1;
    return 0;
}
EXPORT size_t snd_pcm_info_sizeof(void) { return sizeof(struct fpcm_info); }
EXPORT void snd_pcm_info_set_device(snd_pcm_info_t *o, unsigned v) { ((struct fpcm_info *)o)->device = v; }
EXPORT void snd_pcm_info_set_subdevice(snd_pcm_info_t *o, unsigned v) { ((struct fpcm_info *)o)->subdevice = v; }
EXPORT void snd_pcm_info_set_stream(snd_pcm_info_t *o, snd_pcm_stream_t v) { ((struct fpcm_info *)o)->stream = v; }
EXPORT const char *snd_pcm_info_get_name(const snd_pcm_info_t *o) { return ((const struct fpcm_info *)o)->name; }
EXPORT int snd_ctl_pcm_info(snd_ctl_t *ctl, snd_pcm_info_t *info) {
    struct fctl *f = (struct fctl *)ctl; struct fpcm_info *i = (struct fpcm_info *)info;
    const struct fcard *c = &g_cards[f->card];
    if (i->device != 0) return -ENOENT;
    if (i->stream == SND_PCM_STREAM_PLAYBACK && !c->pcm_play) return -ENOENT;
    if (i->stream == SND_PCM_STREAM_CAPTURE && !c->pcm_cap) return -ENOENT;
    i->card = f->card;
    if (f->card == 1) snprintf(i->name, sizeof i->name, "JP21 PCM inmusic,jp21-audio-codec-0");
    else snprintf(i->name, sizeof i->name, "UAC2 PCM");
    return 0;
}

EXPORT size_t snd_ctl_elem_id_sizeof(void) { return sizeof(struct felem_id); }
EXPORT void snd_ctl_elem_id_set_interface(snd_ctl_elem_id_t *o, snd_ctl_elem_iface_t v) { ((struct felem_id *)o)->iface = v; }
EXPORT void snd_ctl_elem_id_set_name(snd_ctl_elem_id_t *o, const char *v) { snprintf(((struct felem_id *)o)->name, 64, "%s", v ? v : ""); }
EXPORT size_t snd_ctl_elem_info_sizeof(void) { return sizeof(struct felem_info); }
EXPORT void snd_ctl_elem_info_set_id(snd_ctl_elem_info_t *o, const snd_ctl_elem_id_t *id) { ((struct felem_info *)o)->id = *(const struct felem_id *)id; }
EXPORT int snd_ctl_elem_info(snd_ctl_t *ctl, snd_ctl_elem_info_t *info) {
    struct felem_info *i = (struct felem_info *)info;
    DBG("ctl %s elem_info '%s'", ((struct fctl *)ctl)->name, i->id.name);
    i->type = SND_CTL_ELEM_TYPE_INTEGER; i->count = 1;
    return 0;
}
EXPORT snd_ctl_elem_type_t snd_ctl_elem_info_get_type(const snd_ctl_elem_info_t *o) { return ((const struct felem_info *)o)->type; }
EXPORT unsigned int snd_ctl_elem_info_get_count(const snd_ctl_elem_info_t *o) { return ((const struct felem_info *)o)->count; }
EXPORT int snd_ctl_elem_value_malloc(snd_ctl_elem_value_t **p) { *p = calloc(1, sizeof(struct felem_value)); return *p ? 0 : -ENOMEM; }
EXPORT void snd_ctl_elem_value_free(snd_ctl_elem_value_t *p) { free(p); }
EXPORT void snd_ctl_elem_value_set_id(snd_ctl_elem_value_t *o, const snd_ctl_elem_id_t *id) { ((struct felem_value *)o)->id = *(const struct felem_id *)id; }
EXPORT void snd_ctl_elem_value_set_integer(snd_ctl_elem_value_t *o, unsigned idx, long v) { if (idx < 128) ((struct felem_value *)o)->ints[idx] = v; }
EXPORT void snd_ctl_elem_set_bytes(snd_ctl_elem_value_t *o, void *data, size_t size) {
    struct felem_value *v = (struct felem_value *)o;
    memcpy(v->bytes, data, size < sizeof v->bytes ? size : sizeof v->bytes);
}
EXPORT int snd_ctl_elem_read(snd_ctl_t *ctl, snd_ctl_elem_value_t *val) {
    DBG("ctl %s elem_read '%s'", ((struct fctl *)ctl)->name, ((struct felem_value *)val)->id.name);
    return 0;
}
EXPORT int snd_ctl_elem_write(snd_ctl_t *ctl, snd_ctl_elem_value_t *val) {
    struct felem_value *v = (struct felem_value *)val;
    DBG("ctl %s elem_write '%s' = %ld", ((struct fctl *)ctl)->name, v->id.name, v->ints[0]);
    return 0;
}

/* ===================================================================== sequencer ======== */

#define DEV_CLIENT 16
#define DEV_PORT 0
#define THRU_CLIENT 14

struct fport { int client, port; char name[64]; unsigned caps, type; int used; };
struct fsub { snd_seq_addr_t sender, dest; int used; };
struct fevq { snd_seq_event_t ev; unsigned char *ext; struct fevq *next; };
struct fseq {
    int client; char name[64]; int nonblock; int pipe[2];
    struct fevq *head, *tail; struct fevq *last; int pending;
};
struct fclient_info { int client; char name[64]; int type, card; };
struct fport_info { int client, port; char name[64]; unsigned caps, type; int port_set; };
struct fsubscribe { snd_seq_addr_t sender, dest; };

#define MAXPORTS 64
#define MAXSUBS 128
#define MAXSEQ 16
static struct fport g_ports[MAXPORTS];
static struct fsub g_subs[MAXSUBS];
static struct fseq *g_seqs[MAXSEQ];
static int g_next_client = 128;
static int g_midi_out_fd = -1;

static void seq_world_init(void) {
    static int done;
    if (done) return;
    done = 1;
    struct fport p0 = {0, 0, "Timer", SND_SEQ_PORT_CAP_READ | SND_SEQ_PORT_CAP_SUBS_READ | SND_SEQ_PORT_CAP_WRITE, 0, 1};
    struct fport p1 = {0, 1, "Announce", SND_SEQ_PORT_CAP_READ | SND_SEQ_PORT_CAP_SUBS_READ, 0, 1};
    unsigned rw = SND_SEQ_PORT_CAP_READ | SND_SEQ_PORT_CAP_WRITE | SND_SEQ_PORT_CAP_SUBS_READ |
                  SND_SEQ_PORT_CAP_SUBS_WRITE;
    struct fport p2 = {THRU_CLIENT, 0, "Midi Through Port-0", rw, SND_SEQ_PORT_TYPE_MIDI_GENERIC | SND_SEQ_PORT_TYPE_SOFTWARE, 1};
    struct fport p3 = {DEV_CLIENT, DEV_PORT, "Control Surface", rw | SND_SEQ_PORT_CAP_DUPLEX,
                       SND_SEQ_PORT_TYPE_MIDI_GENERIC | SND_SEQ_PORT_TYPE_HARDWARE | SND_SEQ_PORT_TYPE_PORT, 1};
    (void)p2; /* the deck has no Midi Through client */
    g_ports[0] = p0; g_ports[1] = p1; g_ports[2] = p3;
}

static const char *client_name(int c) {
    if (c == 0) return "System";
    if (c == DEV_CLIENT) return "Control Surface";
    for (int i = 0; i < MAXSEQ; i++) if (g_seqs[i] && g_seqs[i]->client == c) return g_seqs[i]->name;
    return NULL;
}

static struct fseq *seq_by_client(int c) {
    for (int i = 0; i < MAXSEQ; i++) if (g_seqs[i] && g_seqs[i]->client == c) return g_seqs[i];
    return NULL;
}

static void enqueue(struct fseq *s, const snd_seq_event_t *ev, const unsigned char *ext, unsigned extlen) {
    struct fevq *q = calloc(1, sizeof *q);
    q->ev = *ev;
    if (ext) {
        q->ext = malloc(extlen ? extlen : 1);
        memcpy(q->ext, ext, extlen);
        q->ev.data.ext.len = extlen; q->ev.data.ext.ptr = q->ext;
        q->ev.flags = (q->ev.flags & ~SND_SEQ_EVENT_LENGTH_MASK) | SND_SEQ_EVENT_LENGTH_VARIABLE;
    }
    if (s->tail) s->tail->next = q; else s->head = q;
    s->tail = q; s->pending++;
    char b = 1;
    if (write(s->pipe[1], &b, 1) < 0) {}
}

/* Deliver an event from the controller (16:0) to everyone subscribed to it. */
static void device_send(const snd_seq_event_t *tmpl, const unsigned char *ext, unsigned extlen) {
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < MAXSUBS; i++) {
        if (!g_subs[i].used || g_subs[i].sender.client != DEV_CLIENT || g_subs[i].sender.port != DEV_PORT) continue;
        struct fseq *s = seq_by_client(g_subs[i].dest.client);
        if (!s) continue;
        snd_seq_event_t ev = *tmpl;
        ev.source.client = DEV_CLIENT; ev.source.port = DEV_PORT;
        ev.dest = g_subs[i].dest;
        ev.queue = SND_SEQ_QUEUE_DIRECT;
        enqueue(s, &ev, ext, extlen);
    }
    pthread_mutex_unlock(&g_lock);
}

/* Raw MIDI bytes -> sequencer events (from the panel), with running status and SysEx. */
static void device_bytes(const unsigned char *b, int n) {
    static unsigned char run, sx[4096];
    static int sxlen = -1;
    for (int i = 0; i < n; i++) {
        unsigned char c = b[i];
        if (c == 0xF0) { sxlen = 0; sx[sxlen++] = c; continue; }
        if (sxlen >= 0) {
            if (sxlen < (int)sizeof sx) sx[sxlen++] = c;
            if (c == 0xF7) {
                snd_seq_event_t ev = {0};
                ev.type = SND_SEQ_EVENT_SYSEX;
                device_send(&ev, sx, sxlen);
                sxlen = -1;
            }
            continue;
        }
        if (c & 0x80) { run = c; if (c >= 0xF8) run = 0; continue; }
        if (!run) continue;
        unsigned char st = run & 0xF0, ch = run & 0x0F;
        int need = (st == 0xC0 || st == 0xD0) ? 1 : 2;
        static unsigned char d[2]; static int dn;
        d[dn++] = c;
        if (dn < need) continue;
        dn = 0;
        snd_seq_event_t ev = {0};
        switch (st) {
        case 0x80: ev.type = SND_SEQ_EVENT_NOTEOFF; ev.data.note.channel = ch; ev.data.note.note = d[0]; ev.data.note.velocity = d[1]; break;
        case 0x90: ev.type = SND_SEQ_EVENT_NOTEON; ev.data.note.channel = ch; ev.data.note.note = d[0]; ev.data.note.velocity = d[1]; break;
        case 0xA0: ev.type = SND_SEQ_EVENT_KEYPRESS; ev.data.note.channel = ch; ev.data.note.note = d[0]; ev.data.note.velocity = d[1]; break;
        case 0xB0: ev.type = SND_SEQ_EVENT_CONTROLLER; ev.data.control.channel = ch; ev.data.control.param = d[0]; ev.data.control.value = d[1]; break;
        case 0xC0: ev.type = SND_SEQ_EVENT_PGMCHANGE; ev.data.control.channel = ch; ev.data.control.value = d[0]; break;
        case 0xD0: ev.type = SND_SEQ_EVENT_CHANPRESS; ev.data.control.channel = ch; ev.data.control.value = d[0]; break;
        case 0xE0: ev.type = SND_SEQ_EVENT_PITCHBEND; ev.data.control.channel = ch; ev.data.control.value = ((d[1] << 7) | d[0]) - 8192; break;
        default: continue;
        }
        device_send(&ev, NULL, 0);
    }
}

static void device_out_line(const unsigned char *b, int n) {
    if (g_midi_out_fd < 0) {
        g_midi_out_fd = open("/tmp/emu/midi-out", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
        if (g_midi_out_fd < 0) return;
    }
    struct stat st;
    if (!fstat(g_midi_out_fd, &st) && st.st_size > (8 << 20)) { if (ftruncate(g_midi_out_fd, 0)) {} }
    char line[3 * 4096 + 2]; int o = 0;
    for (int i = 0; i < n && o < (int)sizeof line - 4; i++) o += sprintf(line + o, i ? " %02x" : "%02x", b[i]);
    line[o++] = '\n';
    if (write(g_midi_out_fd, line, o) < 0) {}
}

/* What the real controller firmware answers by itself. */
static void device_receive(const unsigned char *b, int n) {
    device_out_line(b, n);
    if (n >= 6 && b[0] == 0xF0 && b[1] == 0x7E && b[3] == 0x06 && b[4] == 0x01) {
        /* identity reply in the JP21 controller's format: inMusic (00 02 0B), family 12,
         * firmware 1.3.0.2 (matches the bundled controller firmware, so no update prompt),
         * then a 15-character serial. The serial is a placeholder, never a real unit's. */
        static const unsigned char id[] = {0xF0, 0x7E, 0x00, 0x06, 0x02, 0x00, 0x02, 0x0B, 0x12, 0x00,
                                           0x19, 0x01, 0x03, 0x00, 0x02, 0x7F, 0x00, 0x00, 0x00, 0x00,
                                           'E', 'M', 'U', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '0', '1',
                                           0x00, 0xF7};
        DBG("identity request -> JP21 reply");
        snd_seq_event_t ev = {0}; ev.type = SND_SEQ_EVENT_SYSEX;
        device_send(&ev, id, sizeof id);
    } else if (n >= 10 && b[0] == 0xF0 && b[1] == 0x00 && b[2] == 0x02 && b[3] == 0x0B && b[6] == 0x42) {
        /* power-on button state: nothing held (holding Shift+Pad 1 would ask for test mode) */
        static const unsigned char r[] = {0xF0, 0x00, 0x02, 0x0B, 0x7F, 0x12, 0x42, 0x00, 0x01, 0x00, 0xF7};
        snd_seq_event_t ev = {0}; ev.type = SND_SEQ_EVENT_SYSEX;
        device_send(&ev, r, sizeof r);
    }
}

static int event_to_bytes(const snd_seq_event_t *ev, unsigned char *out, int max) {
    const snd_seq_ev_note_t *nt = &ev->data.note; const snd_seq_ev_ctrl_t *ct = &ev->data.control;
    switch (ev->type) {
    case SND_SEQ_EVENT_NOTEON: out[0] = 0x90 | (nt->channel & 15); out[1] = nt->note & 127; out[2] = nt->velocity & 127; return 3;
    case SND_SEQ_EVENT_NOTEOFF: out[0] = 0x80 | (nt->channel & 15); out[1] = nt->note & 127; out[2] = nt->velocity & 127; return 3;
    case SND_SEQ_EVENT_KEYPRESS: out[0] = 0xA0 | (nt->channel & 15); out[1] = nt->note & 127; out[2] = nt->velocity & 127; return 3;
    case SND_SEQ_EVENT_CONTROLLER: out[0] = 0xB0 | (ct->channel & 15); out[1] = ct->param & 127; out[2] = ct->value & 127; return 3;
    case SND_SEQ_EVENT_PGMCHANGE: out[0] = 0xC0 | (ct->channel & 15); out[1] = ct->value & 127; return 2;
    case SND_SEQ_EVENT_CHANPRESS: out[0] = 0xD0 | (ct->channel & 15); out[1] = ct->value & 127; return 2;
    case SND_SEQ_EVENT_PITCHBEND: { int v = ct->value + 8192; out[0] = 0xE0 | (ct->channel & 15); out[1] = v & 127; out[2] = (v >> 7) & 127; return 3; }
    case SND_SEQ_EVENT_SYSEX: {
        int n = ev->data.ext.len < (unsigned)max ? (int)ev->data.ext.len : max;
        memcpy(out, ev->data.ext.ptr, n);
        return n;
    }
    }
    return 0;
}

static void *midi_in_thread(void *arg) {
    (void)arg;
    for (;;) {
        FILE *f = fopen("/tmp/emu/midi-in", "r");
        if (!f) { sleep(1); continue; }
        char line[16384];
        while (fgets(line, sizeof line, f)) {
            unsigned char b[4096]; int n = 0; char *p = line, *e;
            for (;;) {
                long v = strtol(p, &e, 16);
                if (e == p || n >= (int)sizeof b) break;
                b[n++] = (unsigned char)v; p = e;
            }
            if (n) device_bytes(b, n);
        }
        fclose(f);
    }
    return NULL;
}

static void seq_start_device(void) {
    static int started;
    if (started) return;
    started = 1;
    mkfifo("/tmp/emu/midi-in", 0666);
    pthread_t t;
    pthread_create(&t, NULL, midi_in_thread, NULL);
}

EXPORT int snd_seq_open(snd_seq_t **handle, const char *name, int streams, int mode) {
    (void)streams;
    pthread_mutex_lock(&g_lock);
    seq_world_init();
    int slot = -1;
    for (int i = 0; i < MAXSEQ; i++) if (!g_seqs[i]) { slot = i; break; }
    if (slot < 0) { pthread_mutex_unlock(&g_lock); return -ENOMEM; }
    struct fseq *s = calloc(1, sizeof *s);
    s->client = g_next_client++;
    s->nonblock = (mode & SND_SEQ_NONBLOCK) != 0;
    snprintf(s->name, sizeof s->name, "Client-%d", s->client);
    if (pipe2(s->pipe, O_CLOEXEC | O_NONBLOCK)) { free(s); pthread_mutex_unlock(&g_lock); return -errno; }
    g_seqs[slot] = s;
    pthread_mutex_unlock(&g_lock);
    seq_start_device();
    DBG("seq_open %s -> client %d%s", name, s->client, s->nonblock ? " (nonblock)" : "");
    *handle = (snd_seq_t *)s;
    return 0;
}
EXPORT int snd_seq_close(snd_seq_t *h) {
    struct fseq *s = (struct fseq *)h;
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < MAXSEQ; i++) if (g_seqs[i] == s) g_seqs[i] = NULL;
    for (int i = 0; i < MAXPORTS; i++) if (g_ports[i].used && g_ports[i].client == s->client) g_ports[i].used = 0;
    for (int i = 0; i < MAXSUBS; i++)
        if (g_subs[i].used && (g_subs[i].sender.client == s->client || g_subs[i].dest.client == s->client)) g_subs[i].used = 0;
    pthread_mutex_unlock(&g_lock);
    close(s->pipe[0]); close(s->pipe[1]);
    free(s);
    return 0;
}
EXPORT int snd_seq_client_id(snd_seq_t *h) { return ((struct fseq *)h)->client; }
EXPORT int snd_seq_set_client_name(snd_seq_t *h, const char *name) {
    snprintf(((struct fseq *)h)->name, 64, "%s", name ? name : "");
    DBG("client %d name '%s'", ((struct fseq *)h)->client, name);
    return 0;
}
EXPORT int snd_seq_poll_descriptors_count(snd_seq_t *h, short events) { (void)h; (void)events; return 1; }
EXPORT int snd_seq_poll_descriptors(snd_seq_t *h, struct pollfd *pfds, unsigned space, short events) {
    if (!space) return 0;
    pfds[0].fd = ((struct fseq *)h)->pipe[0]; pfds[0].events = events & POLLIN ? POLLIN : events; pfds[0].revents = 0;
    return 1;
}
EXPORT int snd_seq_poll_descriptors_revents(snd_seq_t *h, struct pollfd *pfds, unsigned nfds, unsigned short *revents) {
    (void)h;
    *revents = nfds ? pfds[0].revents : 0;
    return 0;
}

EXPORT int snd_seq_event_input(snd_seq_t *h, snd_seq_event_t **ev) {
    struct fseq *s = (struct fseq *)h;
    for (;;) {
        pthread_mutex_lock(&g_lock);
        if (s->last) { free(s->last->ext); free(s->last); s->last = NULL; }
        struct fevq *q = s->head;
        if (q) {
            s->head = q->next; if (!s->head) s->tail = NULL;
            s->pending--;
            char b; if (read(s->pipe[0], &b, 1) < 0) {}
            s->last = q;
            int left = s->pending;
            pthread_mutex_unlock(&g_lock);
            *ev = &q->ev;
            return left + 1;
        }
        pthread_mutex_unlock(&g_lock);
        if (s->nonblock) return -EAGAIN;
        struct pollfd p = {s->pipe[0], POLLIN, 0};
        poll(&p, 1, -1);
    }
}
EXPORT int snd_seq_free_event(snd_seq_event_t *ev) { (void)ev; return 0; }

static void route_from_engine(struct fseq *s, const snd_seq_event_t *ev) {
    unsigned char b[4096];
    int n = event_to_bytes(ev, b, sizeof b);
    int to_dev = 0, to_thru = 0;
    if (ev->dest.client == DEV_CLIENT) to_dev = 1;
    else if (ev->dest.client == THRU_CLIENT) to_thru = 1;
    else if (ev->dest.client == SND_SEQ_ADDRESS_SUBSCRIBERS) {
        pthread_mutex_lock(&g_lock);
        for (int i = 0; i < MAXSUBS; i++) {
            if (!g_subs[i].used || g_subs[i].sender.client != s->client || g_subs[i].sender.port != ev->source.port) continue;
            if (g_subs[i].dest.client == DEV_CLIENT) to_dev = 1;
            if (g_subs[i].dest.client == THRU_CLIENT) to_thru = 1;
        }
        pthread_mutex_unlock(&g_lock);
    }
    if (to_dev && n) device_receive(b, n);
    if (to_thru) { /* Midi Through just echoes */
        pthread_mutex_lock(&g_lock);
        for (int i = 0; i < MAXSUBS; i++) {
            if (!g_subs[i].used || g_subs[i].sender.client != THRU_CLIENT) continue;
            struct fseq *d = seq_by_client(g_subs[i].dest.client);
            if (!d) continue;
            snd_seq_event_t e = *ev; e.source.client = THRU_CLIENT; e.source.port = 0; e.dest = g_subs[i].dest;
            enqueue(d, &e, ev->type == SND_SEQ_EVENT_SYSEX ? ev->data.ext.ptr : NULL, ev->type == SND_SEQ_EVENT_SYSEX ? ev->data.ext.len : 0);
        }
        pthread_mutex_unlock(&g_lock);
    }
}
EXPORT int snd_seq_event_output_direct(snd_seq_t *h, snd_seq_event_t *ev) {
    route_from_engine((struct fseq *)h, ev);
    return sizeof *ev + (ev->type == SND_SEQ_EVENT_SYSEX ? ev->data.ext.len : 0);
}
EXPORT int snd_seq_drain_output(snd_seq_t *h) { (void)h; return 0; }
EXPORT int snd_seq_set_output_buffer_size(snd_seq_t *h, size_t size) { (void)h; (void)size; return 0; }
EXPORT int snd_seq_set_input_buffer_size(snd_seq_t *h, size_t size) { (void)h; (void)size; return 0; }

/* client pool */
EXPORT size_t snd_seq_client_pool_sizeof(void) { return 64; }
EXPORT int snd_seq_get_client_pool(snd_seq_t *h, snd_seq_client_pool_t *p) { (void)h; memset(p, 0, 64); return 0; }
EXPORT int snd_seq_set_client_pool(snd_seq_t *h, snd_seq_client_pool_t *p) { (void)h; (void)p; return 0; }
EXPORT void snd_seq_client_pool_set_input_pool(snd_seq_client_pool_t *p, size_t s) { (void)p; (void)s; }

/* queues */
EXPORT int snd_seq_alloc_named_queue(snd_seq_t *h, const char *name) { (void)h; (void)name; return 0; }
EXPORT int snd_seq_free_queue(snd_seq_t *h, int q) { (void)h; (void)q; return 0; }
EXPORT size_t snd_seq_queue_tempo_sizeof(void) { return 64; }
EXPORT void snd_seq_queue_tempo_set_tempo(snd_seq_queue_tempo_t *t, unsigned v) { (void)t; (void)v; }
EXPORT void snd_seq_queue_tempo_set_ppq(snd_seq_queue_tempo_t *t, int v) { (void)t; (void)v; }
EXPORT int snd_seq_set_queue_tempo(snd_seq_t *h, int q, snd_seq_queue_tempo_t *t) { (void)h; (void)q; (void)t; return 0; }
EXPORT int snd_seq_control_queue(snd_seq_t *h, int q, int type, int value, snd_seq_event_t *ev) { (void)h; (void)q; (void)type; (void)value; (void)ev; return 0; }

/* client info */
EXPORT size_t snd_seq_client_info_sizeof(void) { return sizeof(struct fclient_info); }
static void fill_client(struct fclient_info *i, int c) {
    const char *n = client_name(c);
    i->client = c;
    snprintf(i->name, sizeof i->name, "%s", n ? n : "");
    i->type = c < 128 ? SND_SEQ_KERNEL_CLIENT : SND_SEQ_USER_CLIENT;
    i->card = c == DEV_CLIENT ? MIDI_CARD : -1;
}
EXPORT int snd_seq_get_any_client_info(snd_seq_t *h, int client, snd_seq_client_info_t *info) {
    (void)h;
    pthread_mutex_lock(&g_lock);
    const char *n = client_name(client);
    if (n) fill_client((struct fclient_info *)info, client);
    pthread_mutex_unlock(&g_lock);
    return n ? 0 : -ENOENT;
}
EXPORT void snd_seq_client_info_set_client(snd_seq_client_info_t *i, int c) { ((struct fclient_info *)i)->client = c; }
EXPORT int snd_seq_client_info_get_client(const snd_seq_client_info_t *i) { return ((const struct fclient_info *)i)->client; }
EXPORT const char *snd_seq_client_info_get_name(snd_seq_client_info_t *i) { return ((struct fclient_info *)i)->name; }
EXPORT int snd_seq_client_info_get_card(const snd_seq_client_info_t *i) { return ((const struct fclient_info *)i)->card; }
EXPORT int snd_seq_query_next_client(snd_seq_t *h, snd_seq_client_info_t *info) {
    (void)h;
    struct fclient_info *i = (struct fclient_info *)info;
    pthread_mutex_lock(&g_lock);
    int best = -1;
    for (int c = i->client + 1; c < 256 && best < 0; c++) if (client_name(c)) best = c;
    if (best >= 0) fill_client(i, best);
    pthread_mutex_unlock(&g_lock);
    return best >= 0 ? 0 : -ENOENT;
}

/* port info */
EXPORT size_t snd_seq_port_info_sizeof(void) { return sizeof(struct fport_info); }
static void fill_port(struct fport_info *i, const struct fport *p) {
    i->client = p->client; i->port = p->port; i->caps = p->caps; i->type = p->type;
    snprintf(i->name, sizeof i->name, "%s", p->name);
}
EXPORT int snd_seq_get_any_port_info(snd_seq_t *h, int client, int port, snd_seq_port_info_t *info) {
    (void)h;
    pthread_mutex_lock(&g_lock);
    int found = 0;
    for (int k = 0; k < MAXPORTS; k++)
        if (g_ports[k].used && g_ports[k].client == client && g_ports[k].port == port) { fill_port((struct fport_info *)info, &g_ports[k]); found = 1; break; }
    pthread_mutex_unlock(&g_lock);
    return found ? 0 : -ENOENT;
}
EXPORT int snd_seq_query_next_port(snd_seq_t *h, snd_seq_port_info_t *info) {
    (void)h;
    struct fport_info *i = (struct fport_info *)info;
    pthread_mutex_lock(&g_lock);
    int best = -1;
    for (int k = 0; k < MAXPORTS; k++)
        if (g_ports[k].used && g_ports[k].client == i->client && g_ports[k].port > i->port &&
            (best < 0 || g_ports[k].port < g_ports[best].port)) best = k;
    if (best >= 0) fill_port(i, &g_ports[best]);
    pthread_mutex_unlock(&g_lock);
    return best >= 0 ? 0 : -ENOENT;
}
EXPORT void snd_seq_port_info_set_client(snd_seq_port_info_t *i, int c) { ((struct fport_info *)i)->client = c; }
EXPORT void snd_seq_port_info_set_port(snd_seq_port_info_t *i, int p) { ((struct fport_info *)i)->port = p; ((struct fport_info *)i)->port_set = 1; }
EXPORT void snd_seq_port_info_set_name(snd_seq_port_info_t *i, const char *n) { snprintf(((struct fport_info *)i)->name, 64, "%s", n ? n : ""); }
EXPORT void snd_seq_port_info_set_capability(snd_seq_port_info_t *i, unsigned c) { ((struct fport_info *)i)->caps = c; }
EXPORT void snd_seq_port_info_set_type(snd_seq_port_info_t *i, unsigned t) { ((struct fport_info *)i)->type = t; }
EXPORT void snd_seq_port_info_set_midi_channels(snd_seq_port_info_t *i, int c) { (void)i; (void)c; }
EXPORT void snd_seq_port_info_set_timestamping(snd_seq_port_info_t *i, int e) { (void)i; (void)e; }
EXPORT void snd_seq_port_info_set_timestamp_real(snd_seq_port_info_t *i, int e) { (void)i; (void)e; }
EXPORT void snd_seq_port_info_set_timestamp_queue(snd_seq_port_info_t *i, int q) { (void)i; (void)q; }
EXPORT int snd_seq_port_info_get_client(const snd_seq_port_info_t *i) { return ((const struct fport_info *)i)->client; }
EXPORT int snd_seq_port_info_get_port(const snd_seq_port_info_t *i) { return ((const struct fport_info *)i)->port; }
EXPORT const char *snd_seq_port_info_get_name(const snd_seq_port_info_t *i) { return ((const struct fport_info *)i)->name; }
EXPORT unsigned int snd_seq_port_info_get_capability(const snd_seq_port_info_t *i) { return ((const struct fport_info *)i)->caps; }
EXPORT unsigned int snd_seq_port_info_get_type(const snd_seq_port_info_t *i) { return ((const struct fport_info *)i)->type; }

static int add_port(struct fseq *s, int want, const char *name, unsigned caps, unsigned type) {
    pthread_mutex_lock(&g_lock);
    int port = want;
    if (port < 0) {
        port = 0;
        for (int again = 1; again;) {
            again = 0;
            for (int k = 0; k < MAXPORTS; k++)
                if (g_ports[k].used && g_ports[k].client == s->client && g_ports[k].port == port) { port++; again = 1; }
        }
    }
    int slot = -1;
    for (int k = 0; k < MAXPORTS; k++) if (!g_ports[k].used) { slot = k; break; }
    if (slot >= 0) {
        struct fport p = {s->client, port, "", caps, type, 1};
        snprintf(p.name, sizeof p.name, "%s", name ? name : "");
        g_ports[slot] = p;
    }
    pthread_mutex_unlock(&g_lock);
    DBG("client %d port %d '%s' caps %x", s->client, port, name, caps);
    return slot >= 0 ? port : -ENOMEM;
}
EXPORT int snd_seq_create_simple_port(snd_seq_t *h, const char *name, unsigned caps, unsigned type) {
    return add_port((struct fseq *)h, -1, name, caps, type);
}
EXPORT int snd_seq_create_port(snd_seq_t *h, snd_seq_port_info_t *info) {
    struct fport_info *i = (struct fport_info *)info;
    int p = add_port((struct fseq *)h, i->port_set ? i->port : -1, i->name, i->caps, i->type);
    if (p < 0) return p;
    i->client = ((struct fseq *)h)->client; i->port = p;
    return 0;
}
static int del_port(struct fseq *s, int port) {
    pthread_mutex_lock(&g_lock);
    for (int k = 0; k < MAXPORTS; k++) if (g_ports[k].used && g_ports[k].client == s->client && g_ports[k].port == port) g_ports[k].used = 0;
    for (int k = 0; k < MAXSUBS; k++)
        if (g_subs[k].used && ((g_subs[k].sender.client == s->client && g_subs[k].sender.port == port) ||
                               (g_subs[k].dest.client == s->client && g_subs[k].dest.port == port))) g_subs[k].used = 0;
    pthread_mutex_unlock(&g_lock);
    return 0;
}
EXPORT int snd_seq_delete_port(snd_seq_t *h, int port) { return del_port((struct fseq *)h, port); }
EXPORT int snd_seq_delete_simple_port(snd_seq_t *h, int port) { return del_port((struct fseq *)h, port); }

static int add_sub(int sc, int sp, int dc, int dp) {
    pthread_mutex_lock(&g_lock);
    int r = -ENOMEM;
    for (int k = 0; k < MAXSUBS; k++) {
        if (g_subs[k].used && g_subs[k].sender.client == sc && g_subs[k].sender.port == sp &&
            g_subs[k].dest.client == dc && g_subs[k].dest.port == dp) { r = -EBUSY; break; }
    }
    if (r != -EBUSY)
        for (int k = 0; k < MAXSUBS; k++)
            if (!g_subs[k].used) {
                g_subs[k].used = 1;
                g_subs[k].sender.client = sc; g_subs[k].sender.port = sp;
                g_subs[k].dest.client = dc; g_subs[k].dest.port = dp;
                r = 0; break;
            }
    pthread_mutex_unlock(&g_lock);
    DBG("subscribe %d:%d -> %d:%d = %d", sc, sp, dc, dp, r);
    return r;
}
static int del_sub(int sc, int sp, int dc, int dp) {
    pthread_mutex_lock(&g_lock);
    for (int k = 0; k < MAXSUBS; k++)
        if (g_subs[k].used && g_subs[k].sender.client == sc && g_subs[k].sender.port == sp &&
            g_subs[k].dest.client == dc && g_subs[k].dest.port == dp) g_subs[k].used = 0;
    pthread_mutex_unlock(&g_lock);
    return 0;
}
EXPORT int snd_seq_connect_from(snd_seq_t *h, int myport, int sc, int sp) { return add_sub(sc, sp, ((struct fseq *)h)->client, myport); }
EXPORT int snd_seq_connect_to(snd_seq_t *h, int myport, int dc, int dp) { return add_sub(((struct fseq *)h)->client, myport, dc, dp); }
EXPORT int snd_seq_port_subscribe_malloc(snd_seq_port_subscribe_t **p) { *p = calloc(1, sizeof(struct fsubscribe)); return *p ? 0 : -ENOMEM; }
EXPORT void snd_seq_port_subscribe_free(snd_seq_port_subscribe_t *p) { free(p); }
EXPORT void snd_seq_port_subscribe_set_sender(snd_seq_port_subscribe_t *p, const snd_seq_addr_t *a) { ((struct fsubscribe *)p)->sender = *a; }
EXPORT void snd_seq_port_subscribe_set_dest(snd_seq_port_subscribe_t *p, const snd_seq_addr_t *a) { ((struct fsubscribe *)p)->dest = *a; }
EXPORT void snd_seq_port_subscribe_set_time_update(snd_seq_port_subscribe_t *p, int v) { (void)p; (void)v; }
EXPORT void snd_seq_port_subscribe_set_time_real(snd_seq_port_subscribe_t *p, int v) { (void)p; (void)v; }
EXPORT int snd_seq_subscribe_port(snd_seq_t *h, snd_seq_port_subscribe_t *p) {
    (void)h; struct fsubscribe *s = (struct fsubscribe *)p;
    int r = add_sub(s->sender.client, s->sender.port, s->dest.client, s->dest.port);
    return r == -EBUSY ? 0 : r;
}
EXPORT int snd_seq_unsubscribe_port(snd_seq_t *h, snd_seq_port_subscribe_t *p) {
    (void)h; struct fsubscribe *s = (struct fsubscribe *)p;
    return del_sub(s->sender.client, s->sender.port, s->dest.client, s->dest.port);
}

/* ===================================================================== PCM ============== */

struct fhw {
    int access, format;
    unsigned ch_min, ch_max, rate_min, rate_max;
    snd_pcm_uframes_t per_min, per_max, buf_min, buf_max;
};
struct fsw { snd_pcm_uframes_t avail_min, start_thr, stop_thr, silence_thr; };
struct fpcm {
    char name[96]; int stream, mode, state;
    struct fhw hw; struct fsw sw;
    unsigned ch, rate; int format; snd_pcm_uframes_t period, buffer;
    double t0; int64_t appl, hw_base; /* frames */
    int index; unsigned long xruns;
};

static int fmt_bytes(int f) {
    switch (f) {
    case SND_PCM_FORMAT_S16_LE: return 2;
    case SND_PCM_FORMAT_S24_3LE: return 3;
    case SND_PCM_FORMAT_S24_LE: case SND_PCM_FORMAT_S32_LE: case SND_PCM_FORMAT_FLOAT_LE: return 4;
    }
    return 0;
}
static int16_t sample16(const unsigned char *p, int f) {
    switch (f) {
    case SND_PCM_FORMAT_S16_LE: return (int16_t)(p[0] | p[1] << 8);
    case SND_PCM_FORMAT_S24_3LE: return (int16_t)(p[1] | p[2] << 8);
    case SND_PCM_FORMAT_S24_LE: { int32_t v = p[0] | p[1] << 8 | p[2] << 16; return (int16_t)(v >> 8); }
    case SND_PCM_FORMAT_S32_LE: return (int16_t)(p[2] | p[3] << 8);
    case SND_PCM_FORMAT_FLOAT_LE: { float v; memcpy(&v, p, 4); v = v > 1 ? 1 : v < -1 ? -1 : v; return (int16_t)(v * 32767); }
    }
    return 0;
}

/* ---- browser audio ring: 64-byte header + stereo s16 frames ---- */
#define RING_FRAMES (48000 * 4)
struct ring_hdr { char magic[4]; uint32_t rate, frames, pcm_index; uint64_t written; uint32_t left, right; char pcm[32]; };
static struct ring_hdr *g_ring;
static int16_t *g_ring_data;
static int g_sink = -1, g_pcm_count;

static void ring_open(void) {
    if (g_ring) return;
    int fd = open("/tmp/emu/audio", O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) return;
    size_t sz = 64 + (size_t)RING_FRAMES * 4;
    if (ftruncate(fd, sz) == 0) {
        void *m = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (m != MAP_FAILED) { g_ring = m; g_ring_data = (int16_t *)((char *)m + 64); memcpy(g_ring->magic, "EMUA", 4); g_ring->frames = RING_FRAMES; }
    }
    close(fd);
}

/* /tmp/emu/audio-select: "<pcm index> <left ch> <right ch>", written by the viewer */
static void sink_select(int *pcm, unsigned *l, unsigned *r) {
    static double last; static int sp = -1; static unsigned sl = 0, sr = 1;
    double t = now_s();
    if (t - last > 0.5) {
        last = t;
        FILE *f = fopen("/tmp/emu/audio-select", "r");
        if (f) { int a; unsigned b, c; if (fscanf(f, "%d %u %u", &a, &b, &c) == 3) { sp = a; sl = b; sr = c; } fclose(f); }
    }
    *pcm = sp; *l = sl; *r = sr;
}

static void sink_write(struct fpcm *p, const void *buf, snd_pcm_uframes_t frames) {
    int want; unsigned l, r;
    sink_select(&want, &l, &r);
    if (want < 0) { if (g_sink < 0) g_sink = p->index; want = g_sink; }
    if (want != p->index) return;
    ring_open();
    if (!g_ring) return;
    int bps = fmt_bytes(p->format);
    if (!bps) return;
    if (l >= p->ch) l = 0;
    if (r >= p->ch) r = p->ch > 1 ? 1 : 0;
    const unsigned char *b = buf;
    uint64_t w = g_ring->written;
    for (snd_pcm_uframes_t i = 0; i < frames; i++) {
        const unsigned char *fr = b + (size_t)i * p->ch * bps;
        size_t at = (size_t)((w + i) % RING_FRAMES) * 2;
        g_ring_data[at] = sample16(fr + l * bps, p->format);
        g_ring_data[at + 1] = sample16(fr + r * bps, p->format);
    }
    g_ring->rate = p->rate; g_ring->pcm_index = p->index; g_ring->left = l; g_ring->right = r;
    snprintf(g_ring->pcm, sizeof g_ring->pcm, "%.31s", p->name);
    __sync_synchronize();
    g_ring->written = w + frames;
}

static void pcm_list_write(void) {
    /* /tmp/emu/audio-pcms: one line per opened device, for the viewer's output picker */
    FILE *f = fopen("/tmp/emu/audio-pcms.tmp", "w");
    if (!f) return;
    extern struct fpcm *g_pcms[];
    for (int i = 0; i < g_pcm_count; i++) {
        struct fpcm *p = g_pcms[i];
        if (p) fprintf(f, "%d\t%s\t%s\t%u\t%u\n", i, p->stream == SND_PCM_STREAM_PLAYBACK ? "playback" : "capture", p->name, p->ch, p->rate);
    }
    fclose(f);
    rename("/tmp/emu/audio-pcms.tmp", "/tmp/emu/audio-pcms");
}
struct fpcm *g_pcms[64];

EXPORT int snd_pcm_open(snd_pcm_t **pcm, const char *name, snd_pcm_stream_t stream, int mode) {
    struct fpcm *p = calloc(1, sizeof *p);
    snprintf(p->name, sizeof p->name, "%s", name ? name : "default");
    p->stream = stream; p->mode = mode; p->state = SND_PCM_STATE_OPEN;
    pthread_mutex_lock(&g_lock);
    p->index = g_pcm_count < 64 ? g_pcm_count++ : 63;
    g_pcms[p->index] = p;
    pthread_mutex_unlock(&g_lock);
    alog("pcm_open '%s' %s%s", p->name, stream == SND_PCM_STREAM_PLAYBACK ? "playback" : "capture", mode & SND_PCM_NONBLOCK ? " nonblock" : "");
    *pcm = (snd_pcm_t *)p;
    return 0;
}
EXPORT int snd_pcm_close(snd_pcm_t *pcm) {
    struct fpcm *p = (struct fpcm *)pcm;
    pthread_mutex_lock(&g_lock);
    if (g_pcms[p->index] == p) g_pcms[p->index] = NULL;
    pthread_mutex_unlock(&g_lock);
    pcm_list_write();
    free(p);
    return 0;
}
EXPORT const char *snd_pcm_name(snd_pcm_t *pcm) { return ((struct fpcm *)pcm)->name; }
EXPORT snd_pcm_stream_t snd_pcm_stream(snd_pcm_t *pcm) { return ((struct fpcm *)pcm)->stream; }
EXPORT snd_pcm_state_t snd_pcm_state(snd_pcm_t *pcm) { return ((struct fpcm *)pcm)->state; }
EXPORT const char *snd_pcm_stream_name(snd_pcm_stream_t s) { return s == SND_PCM_STREAM_PLAYBACK ? "PLAYBACK" : "CAPTURE"; }
EXPORT const char *snd_pcm_state_name(snd_pcm_state_t s) {
    static const char *n[] = {"OPEN", "SETUP", "PREPARED", "RUNNING", "XRUN", "DRAINING", "PAUSED", "SUSPENDED", "DISCONNECTED"};
    return (unsigned)s < 9 ? n[s] : "UNKNOWN";
}
EXPORT const char *snd_strerror(int err) { return strerror(err < 0 ? -err : err); }

/* hw params */
EXPORT size_t snd_pcm_hw_params_sizeof(void) { return sizeof(struct fhw); }
EXPORT int snd_pcm_hw_params_malloc(snd_pcm_hw_params_t **p) { *p = calloc(1, sizeof(struct fhw)); return *p ? 0 : -ENOMEM; }
EXPORT void snd_pcm_hw_params_free(snd_pcm_hw_params_t *p) { free(p); }
EXPORT int snd_pcm_hw_params_any(snd_pcm_t *pcm, snd_pcm_hw_params_t *params) {
    struct fpcm *p = (struct fpcm *)pcm;
    struct fhw *h = (struct fhw *)params;
    h->access = -1; h->format = -1;
    h->ch_min = 1; h->ch_max = 32; h->rate_min = 44100; h->rate_max = 96000;
    /* What the deck's hardware offers: the JP21 codec does 8 out (main, booth, phones...)
     * and 2 in (mic/aux), the USB gadget 2 out. Engine sizes its streams from these. */
    int card = card_from_name(p->name);
    if (card == 1) { h->ch_min = h->ch_max = p->stream == SND_PCM_STREAM_PLAYBACK ? 8 : 2; }
    else if (card == 2) { h->ch_min = h->ch_max = 2; h->rate_min = h->rate_max = 48000; }
    h->per_min = 16; h->per_max = 8192; h->buf_min = 32; h->buf_max = 65536;
    return 0;
}
static int rate_ok(unsigned r) { return r == 44100 || r == 48000 || r == 88200 || r == 96000; }
static int card_from_name(const char *name);
EXPORT int snd_pcm_hw_params_set_access(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, snd_pcm_access_t a) {
    (void)pcm;
    if (a != SND_PCM_ACCESS_RW_INTERLEAVED) return -EINVAL;
    ((struct fhw *)params)->access = a; return 0;
}
EXPORT int snd_pcm_hw_params_test_format(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, snd_pcm_format_t f) { (void)pcm; (void)params; return fmt_bytes(f) ? 0 : -EINVAL; }
EXPORT int snd_pcm_hw_params_set_format(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, snd_pcm_format_t f) {
    (void)pcm;
    if (!fmt_bytes(f)) return -EINVAL;
    ((struct fhw *)params)->format = f; return 0;
}
EXPORT int snd_pcm_hw_params_test_rate(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned val, int dir) { (void)pcm; (void)params; (void)dir; return rate_ok(val) ? 0 : -EINVAL; }
EXPORT int snd_pcm_hw_params_set_rate(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned val, int dir) {
    (void)pcm; (void)dir;
    if (!rate_ok(val)) return -EINVAL;
    ((struct fhw *)params)->rate_min = ((struct fhw *)params)->rate_max = val; return 0;
}
EXPORT int snd_pcm_hw_params_set_rate_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned *val, int *dir) {
    (void)pcm;
    unsigned v = *val, best = 48000;
    static const unsigned rs[] = {44100, 48000, 88200, 96000};
    for (int i = 0; i < 4; i++) if ((rs[i] > v ? rs[i] - v : v - rs[i]) < (best > v ? best - v : v - best)) best = rs[i];
    *val = best; if (dir) *dir = 0;
    ((struct fhw *)params)->rate_min = ((struct fhw *)params)->rate_max = best; return 0;
}
EXPORT int snd_pcm_hw_params_set_channels(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned val) {
    (void)pcm;
    if (val < ((struct fhw *)params)->ch_min || val > ((struct fhw *)params)->ch_max) return -EINVAL;
    ((struct fhw *)params)->ch_min = ((struct fhw *)params)->ch_max = val; return 0;
}
EXPORT int snd_pcm_hw_params_set_channels_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned *val) {
    (void)pcm;
    struct fhw *h = (struct fhw *)params;
    if (*val < h->ch_min) *val = h->ch_min;
    if (*val > h->ch_max) *val = h->ch_max;
    ((struct fhw *)params)->ch_min = ((struct fhw *)params)->ch_max = *val; return 0;
}
EXPORT int snd_pcm_hw_params_set_period_size_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, snd_pcm_uframes_t *val, int *dir) {
    (void)pcm;
    struct fhw *h = (struct fhw *)params;
    if (*val < 16) *val = 16;
    if (*val > 8192) *val = 8192;
    h->per_min = h->per_max = *val; if (dir) *dir = 0; return 0;
}
EXPORT int snd_pcm_hw_params_set_buffer_size_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, snd_pcm_uframes_t *val) {
    (void)pcm;
    struct fhw *h = (struct fhw *)params;
    if (*val < 32) *val = 32;
    if (*val > 65536) *val = 65536;
    h->buf_min = h->buf_max = *val; return 0;
}
EXPORT int snd_pcm_hw_params_get_channels(const snd_pcm_hw_params_t *params, unsigned *val) { *val = ((const struct fhw *)params)->ch_min; return 0; }
EXPORT int snd_pcm_hw_params_get_channels_min(const snd_pcm_hw_params_t *params, unsigned *val) { *val = ((const struct fhw *)params)->ch_min; return 0; }
EXPORT int snd_pcm_hw_params_get_channels_max(const snd_pcm_hw_params_t *params, unsigned *val) { *val = ((const struct fhw *)params)->ch_max; return 0; }
EXPORT int snd_pcm_hw_params_get_rate(const snd_pcm_hw_params_t *params, unsigned *val, int *dir) { *val = ((const struct fhw *)params)->rate_min; if (dir) *dir = 0; return 0; }
EXPORT int snd_pcm_hw_params_get_rate_min(const snd_pcm_hw_params_t *params, unsigned *val, int *dir) { *val = ((const struct fhw *)params)->rate_min; if (dir) *dir = 0; return 0; }
EXPORT int snd_pcm_hw_params_get_period_size(const snd_pcm_hw_params_t *params, snd_pcm_uframes_t *val, int *dir) { *val = ((const struct fhw *)params)->per_min; if (dir) *dir = 0; return 0; }
EXPORT int snd_pcm_hw_params_get_period_size_min(const snd_pcm_hw_params_t *params, snd_pcm_uframes_t *val, int *dir) { *val = ((const struct fhw *)params)->per_min; if (dir) *dir = 0; return 0; }
EXPORT int snd_pcm_hw_params_get_period_size_max(const snd_pcm_hw_params_t *params, snd_pcm_uframes_t *val, int *dir) { *val = ((const struct fhw *)params)->per_max; if (dir) *dir = 0; return 0; }
EXPORT int snd_pcm_hw_params_get_buffer_size(const snd_pcm_hw_params_t *params, snd_pcm_uframes_t *val) { *val = ((const struct fhw *)params)->buf_min; return 0; }
EXPORT int snd_pcm_hw_params_get_buffer_size_min(const snd_pcm_hw_params_t *params, snd_pcm_uframes_t *val) { *val = ((const struct fhw *)params)->buf_min; return 0; }
EXPORT int snd_pcm_hw_params_get_buffer_size_max(const snd_pcm_hw_params_t *params, snd_pcm_uframes_t *val) { *val = ((const struct fhw *)params)->buf_max; return 0; }
EXPORT int snd_pcm_hw_params(snd_pcm_t *pcm, snd_pcm_hw_params_t *params) {
    struct fpcm *p = (struct fpcm *)pcm; struct fhw *h = (struct fhw *)params;
    if (h->format < 0) h->format = SND_PCM_FORMAT_S32_LE;
    if (h->per_min != h->per_max) h->per_min = h->per_max = 256;
    if (h->buf_min != h->buf_max) h->buf_min = h->buf_max = h->per_min * 4;
    if (h->buf_min < 2 * h->per_min) h->buf_min = h->buf_max = 2 * h->per_min;
    if (h->ch_min != h->ch_max) h->ch_max = h->ch_min = 2;
    if (h->rate_min != h->rate_max) h->rate_min = h->rate_max = 48000;
    p->hw = *h; p->ch = h->ch_min; p->rate = h->rate_min; p->format = h->format;
    p->period = h->per_min; p->buffer = h->buf_min;
    p->sw.avail_min = p->period; p->sw.start_thr = p->stream == SND_PCM_STREAM_PLAYBACK ? p->buffer : 1;
    p->sw.stop_thr = p->buffer;
    p->state = SND_PCM_STATE_PREPARED;
    alog("pcm '%s' %s: %u ch, %u Hz, %s, period %lu, buffer %lu", p->name, p->stream == SND_PCM_STREAM_PLAYBACK ? "playback" : "capture",
         p->ch, p->rate, snd_pcm_format_name(p->format), (unsigned long)p->period, (unsigned long)p->buffer);
    pcm_list_write();
    return 0;
}

/* sw params */
EXPORT size_t snd_pcm_sw_params_sizeof(void) { return sizeof(struct fsw); }
EXPORT int snd_pcm_sw_params_current(snd_pcm_t *pcm, snd_pcm_sw_params_t *params) { *(struct fsw *)params = ((struct fpcm *)pcm)->sw; return 0; }
EXPORT int snd_pcm_sw_params(snd_pcm_t *pcm, snd_pcm_sw_params_t *params) { ((struct fpcm *)pcm)->sw = *(struct fsw *)params; return 0; }
EXPORT int snd_pcm_sw_params_set_avail_min(snd_pcm_t *pcm, snd_pcm_sw_params_t *params, snd_pcm_uframes_t v) { (void)pcm; ((struct fsw *)params)->avail_min = v; return 0; }
EXPORT int snd_pcm_sw_params_set_start_threshold(snd_pcm_t *pcm, snd_pcm_sw_params_t *params, snd_pcm_uframes_t v) { (void)pcm; ((struct fsw *)params)->start_thr = v; return 0; }
EXPORT int snd_pcm_sw_params_set_stop_threshold(snd_pcm_t *pcm, snd_pcm_sw_params_t *params, snd_pcm_uframes_t v) { (void)pcm; ((struct fsw *)params)->stop_thr = v; return 0; }
EXPORT int snd_pcm_sw_params_set_silence_threshold(snd_pcm_t *pcm, snd_pcm_sw_params_t *params, snd_pcm_uframes_t v) { (void)pcm; ((struct fsw *)params)->silence_thr = v; return 0; }
EXPORT int snd_pcm_sw_params_get_boundary(const snd_pcm_sw_params_t *params, snd_pcm_uframes_t *v) { (void)params; *v = 0x40000000UL; return 0; }
EXPORT int snd_pcm_sw_params_set_tstamp_mode(snd_pcm_t *pcm, snd_pcm_sw_params_t *params, snd_pcm_tstamp_t v) { (void)pcm; (void)params; (void)v; return 0; }
EXPORT int snd_pcm_sw_params_set_tstamp_type(snd_pcm_t *pcm, snd_pcm_sw_params_t *params, snd_pcm_tstamp_type_t v) { (void)pcm; (void)params; (void)v; return 0; }

/* transfer: a free-running clock stands in for the DAC. If Engine falls behind (it runs
 * emulated, so it will), the stream just catches up instead of reporting an xrun. */
static int64_t hw_pos(struct fpcm *p) {
    if (p->state != SND_PCM_STATE_RUNNING) return p->hw_base;
    return p->hw_base + (int64_t)((now_s() - p->t0) * p->rate);
}
static void pcm_go(struct fpcm *p) {
    if (p->state == SND_PCM_STATE_RUNNING) return;
    p->t0 = now_s(); p->state = SND_PCM_STATE_RUNNING;
}
EXPORT int snd_pcm_prepare(snd_pcm_t *pcm) {
    struct fpcm *p = (struct fpcm *)pcm;
    p->state = SND_PCM_STATE_PREPARED; p->appl = 0; p->hw_base = 0;
    return 0;
}
EXPORT int snd_pcm_start(snd_pcm_t *pcm) { pcm_go((struct fpcm *)pcm); return 0; }
EXPORT int snd_pcm_drop(snd_pcm_t *pcm) {
    struct fpcm *p = (struct fpcm *)pcm;
    p->state = SND_PCM_STATE_SETUP; p->appl = 0; p->hw_base = 0;
    return 0;
}
EXPORT int snd_pcm_resume(snd_pcm_t *pcm) { (void)pcm; return 0; }

static void catch_up(struct fpcm *p, int64_t hw) {
    if (p->stream == SND_PCM_STREAM_PLAYBACK && p->appl < hw) { p->hw_base += p->appl - hw; p->xruns++; }
    if (p->stream == SND_PCM_STREAM_CAPTURE && hw - p->appl > (int64_t)p->buffer) { p->hw_base -= (hw - p->appl) - p->buffer; p->xruns++; }
}
EXPORT snd_pcm_sframes_t snd_pcm_avail(snd_pcm_t *pcm) {
    struct fpcm *p = (struct fpcm *)pcm;
    if (p->state == SND_PCM_STATE_OPEN || p->state == SND_PCM_STATE_SETUP) return -EBADFD;
    int64_t hw = hw_pos(p);
    catch_up(p, hw);
    hw = hw_pos(p);
    if (p->stream == SND_PCM_STREAM_PLAYBACK) return (snd_pcm_sframes_t)(p->buffer - (p->appl - hw));
    return (snd_pcm_sframes_t)(hw - p->appl);
}
static void wait_frames(struct fpcm *p, int64_t frames) {
    if (frames <= 0) return;
    double s = (double)frames / p->rate;
    struct timespec ts = {(time_t)s, (long)((s - (time_t)s) * 1e9)};
    nanosleep(&ts, NULL);
}
EXPORT snd_pcm_sframes_t snd_pcm_writei(snd_pcm_t *pcm, const void *buf, snd_pcm_uframes_t size) {
    struct fpcm *p = (struct fpcm *)pcm;
    if (p->stream != SND_PCM_STREAM_PLAYBACK) return -EINVAL;
    if (p->state == SND_PCM_STATE_OPEN || p->state == SND_PCM_STATE_SETUP) return -EBADFD;
    if (p->state != SND_PCM_STATE_RUNNING && p->appl + (int64_t)size >= (int64_t)p->sw.start_thr) pcm_go(p);
    for (;;) {
        int64_t hw = hw_pos(p);
        catch_up(p, hw);
        hw = hw_pos(p);
        int64_t space = (int64_t)p->buffer - (p->appl - hw);
        if (space >= (int64_t)size || p->state != SND_PCM_STATE_RUNNING) break;
        if (p->mode & SND_PCM_NONBLOCK) { if (space <= 0) return -EAGAIN; size = space; break; }
        wait_frames(p, (int64_t)size - space);
    }
    sink_write(p, buf, size);
    p->appl += size;
    return size;
}
EXPORT snd_pcm_sframes_t snd_pcm_readi(snd_pcm_t *pcm, void *buf, snd_pcm_uframes_t size) {
    struct fpcm *p = (struct fpcm *)pcm;
    if (p->stream != SND_PCM_STREAM_CAPTURE) return -EINVAL;
    if (p->state == SND_PCM_STATE_OPEN || p->state == SND_PCM_STATE_SETUP) return -EBADFD;
    pcm_go(p);
    for (;;) {
        int64_t hw = hw_pos(p);
        catch_up(p, hw);
        hw = hw_pos(p);
        int64_t have = hw - p->appl;
        if (have >= (int64_t)size) break;
        if (p->mode & SND_PCM_NONBLOCK) { if (have <= 0) return -EAGAIN; size = have; break; }
        wait_frames(p, (int64_t)size - have);
    }
    memset(buf, 0, (size_t)size * p->ch * fmt_bytes(p->format));
    p->appl += size;
    return size;
}
