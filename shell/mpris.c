// See mpris.h. A D-Bus peer of its own over the session bus's socket,
// big enough for MPRIS's two interfaces and the standard ones a client asks
// for, so neither libdbus nor GLib is loaded, as src/os_services's portal
// client does. The socket is non-blocking and polled with the shell's other
// files: the authentication, Hello and RequestName go out together without
// waiting for an answer, and what can't be written at once waits for the
// socket to take it. The app sends Now Playing only when something changes;
// a client asks for Position when it needs it, which moves on from the last
// elapsed time sent while playing, and a jump in it goes out as Seeked.
//
// The cover goes to clients as a URL, so it's written as a PNG to
// $XDG_RUNTIME_DIR, a new file for each cover so that clients don't keep
// showing the one they cached, and the last one is deleted.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "mpris.h"
#include "png.h"

#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "messages are written little-endian"
#endif

#define OBJECT_PATH "/org/mpris/MediaPlayer2"
#define BUS_NAME "org.mpris.MediaPlayer2.tidalfast"
#define ROOT_INTERFACE "org.mpris.MediaPlayer2"
#define PLAYER_INTERFACE "org.mpris.MediaPlayer2.Player"
#define PROPERTIES_INTERFACE "org.freedesktop.DBus.Properties"
#define MAX_MESSAGE (1u << 20) // well above anything a client sends
#define MAX_OUTPUT (4u << 20) // a bus that takes nothing for this long is stuck

enum { MSG_CALL = 1, MSG_RETURN, MSG_ERROR, MSG_SIGNAL };
enum { F_PATH = 1, F_INTERFACE, F_MEMBER, F_ERROR_NAME, F_REPLY_SERIAL, F_DESTINATION, F_SENDER, F_SIGNATURE };
enum { NO_REPLY_EXPECTED = 1 };
enum { NAME_DO_NOT_QUEUE = 4 };
enum { NAME_PRIMARY_OWNER = 1, NAME_ALREADY_OWNER = 4 };

typedef struct {
  uint8_t *p;
  size_t len, cap;
} Buf;

static void (*g_command)(uint32_t command, double position);
static int g_fd = -1;
static double g_next_try; // when to try connecting again, on the clock below; INFINITY for never
static bool g_authed; // the bus said OK, and what follows is messages
static Buf g_in, g_out;
static size_t g_out_sent;
static uint32_t g_serial;
static uint32_t g_request_serial; // RequestName's
static bool g_tried_instance; // asked for the .instance name after the plain one was taken
static char g_request_name[128];
static char g_name[128]; // the name owned; "" before

static struct {
  bool has; // a track; false clears Now Playing
  char *title, *artist, *album;
  double duration;
  double elapsed, stamp; // the position sent, and the clock then
  uint32_t state;
  uint64_t track; // counts tracks, for mpris:trackid
  uint64_t art_key; // the artwork's, 0 for none; kept when its file couldn't be written
  char art_path[PATH_MAX]; // "" without a file
} g_np;

static double mono_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// Writing

static void put(Buf *b, const void *v, size_t n) {
  if (b->len + n > b->cap) {
    size_t cap = b->cap ? b->cap : 256;
    while (cap < b->len + n) cap *= 2;
    uint8_t *p = realloc(b->p, cap);
    if (!p) abort();
    b->p = p;
    b->cap = cap;
  }
  if (n) memcpy(b->p + b->len, v, n);
  b->len += n;
}

static void pad(Buf *b, size_t align) {
  static const uint8_t zero[8];
  put(b, zero, (align - b->len % align) % align);
}

static void put_u8(Buf *b, uint8_t v) { put(b, &v, 1); }

static void put_u32(Buf *b, uint32_t v) {
  pad(b, 4);
  put(b, &v, 4);
}

static void put_i64(Buf *b, int64_t v) {
  pad(b, 8);
  put(b, &v, 8);
}

static void put_f64(Buf *b, double v) {
  pad(b, 8);
  put(b, &v, 8);
}

static void put_str(Buf *b, const char *s) {
  uint32_t n = (uint32_t)strlen(s);
  put_u32(b, n);
  put(b, s, (size_t)n + 1);
}

static void put_sig(Buf *b, const char *s) {
  size_t n = strlen(s);
  put_u8(b, (uint8_t)n);
  put(b, s, n + 1);
}

typedef struct {
  size_t length_at, start;
} Array;

// An array's length leaves out the padding before its first element,
// which is there even when it has none.
static Array array_begin(Buf *b, size_t align) {
  put_u32(b, 0);
  Array a = {.length_at = b->len - 4};
  pad(b, align);
  a.start = b->len;
  return a;
}

static void array_end(Buf *b, Array a) {
  uint32_t n = (uint32_t)(b->len - a.start);
  memcpy(b->p + a.length_at, &n, 4);
}

static void header_field(Buf *m, uint8_t code, const char *sig, const char *value) {
  if (!value) return;
  pad(m, 8);
  put_u8(m, code);
  put_sig(m, sig);
  if (sig[0] == 'g') put_sig(m, value);
  else put_str(m, value);
}

typedef struct {
  uint8_t type, flags;
  const char *path, *interface, *member, *error_name, *destination, *signature;
  uint32_t reply_serial;
} Header;

static void flush(void);

static uint32_t send_message(const Header *h, const Buf *body) {
  if (g_fd < 0) return 0;
  uint32_t serial = ++g_serial;
  // Headers are aligned from the message's start, which g_out may not be at.
  Buf m = {0};
  put_u8(&m, 'l');
  put_u8(&m, h->type);
  put_u8(&m, h->flags);
  put_u8(&m, 1);
  put_u32(&m, body ? (uint32_t)body->len : 0);
  put_u32(&m, serial);
  Array fields = array_begin(&m, 8);
  header_field(&m, F_PATH, "o", h->path);
  header_field(&m, F_INTERFACE, "s", h->interface);
  header_field(&m, F_MEMBER, "s", h->member);
  header_field(&m, F_ERROR_NAME, "s", h->error_name);
  if (h->reply_serial) {
    pad(&m, 8);
    put_u8(&m, F_REPLY_SERIAL);
    put_sig(&m, "u");
    put_u32(&m, h->reply_serial);
  }
  header_field(&m, F_DESTINATION, "s", h->destination);
  if (body && body->len) header_field(&m, F_SIGNATURE, "g", h->signature);
  array_end(&m, fields);
  pad(&m, 8);
  if (body) put(&m, body->p, body->len);
  put(&g_out, m.p, m.len);
  free(m.p);
  flush();
  return serial;
}

static void call_bus(const char *member, const char *signature, const Buf *body, uint32_t *serial) {
  Header h = {.type = MSG_CALL,
              .path = "/org/freedesktop/DBus",
              .interface = "org.freedesktop.DBus",
              .member = member,
              .destination = "org.freedesktop.DBus",
              .signature = signature};
  uint32_t s = send_message(&h, body);
  if (serial) *serial = s;
}

static void request_name(const char *name) {
  snprintf(g_request_name, sizeof g_request_name, "%s", name);
  Buf body = {0};
  put_str(&body, name);
  put_u32(&body, NAME_DO_NOT_QUEUE);
  call_bus("RequestName", "su", &body, &g_request_serial);
  free(body.p);
}

// Reading

typedef struct {
  const uint8_t *p;
  size_t len, off;
  bool swap, bad;
} Reader;

static bool rd_align(Reader *r, size_t align) {
  size_t off = (r->off + align - 1) / align * align;
  if (off > r->len) {
    r->bad = true;
    return false;
  }
  r->off = off;
  return true;
}

static uint32_t rd_u32(Reader *r) {
  if (!rd_align(r, 4) || r->off + 4 > r->len) {
    r->bad = true;
    return 0;
  }
  uint32_t v;
  memcpy(&v, r->p + r->off, 4);
  r->off += 4;
  return r->swap ? __builtin_bswap32(v) : v;
}

static int64_t rd_i64(Reader *r) {
  if (!rd_align(r, 8) || r->off + 8 > r->len) {
    r->bad = true;
    return 0;
  }
  uint64_t v;
  memcpy(&v, r->p + r->off, 8);
  r->off += 8;
  return (int64_t)(r->swap ? __builtin_bswap64(v) : v);
}

static const char *rd_str(Reader *r) {
  uint32_t n = rd_u32(r);
  if (r->bad || r->off + n + 1 > r->len || r->p[r->off + n] != 0) {
    r->bad = true;
    return "";
  }
  const char *s = (const char *)r->p + r->off;
  r->off += (size_t)n + 1;
  return s;
}

static const char *rd_sig(Reader *r) {
  if (r->off >= r->len) {
    r->bad = true;
    return "";
  }
  size_t n = r->p[r->off];
  if (r->off + n + 2 > r->len || r->p[r->off + 1 + n] != 0) {
    r->bad = true;
    return "";
  }
  const char *s = (const char *)r->p + r->off + 1;
  r->off += n + 2;
  return s;
}

typedef struct {
  uint8_t type, flags;
  uint32_t serial, reply_serial;
  const char *path, *interface, *member, *sender, *signature;
  Reader body;
} Message;

// Now Playing's properties

static double position_now(void) {
  if (!g_np.has) return 0;
  double p = g_np.elapsed;
  if (g_np.state == NOW_PLAYING_PLAYING) p += mono_seconds() - g_np.stamp;
  if (g_np.duration > 0 && p > g_np.duration) p = g_np.duration;
  return p < 0 ? 0 : p;
}

static void track_path(char *out, size_t cap) {
  if (g_np.has) snprintf(out, cap, "/com/tidalfast/track/%llu", (unsigned long long)g_np.track);
  else snprintf(out, cap, "/org/mpris/MediaPlayer2/TrackList/NoTrack");
}

static void entry_begin(Buf *b, const char *key, const char *sig) {
  pad(b, 8);
  put_str(b, key);
  put_sig(b, sig);
}

static void entry_str(Buf *b, const char *key, const char *sig, const char *v) {
  entry_begin(b, key, sig);
  if (sig[0] == 'g') put_sig(b, v);
  else put_str(b, v);
}

// A file URL for path, its bytes outside the unreserved ones and / escaped.
static void file_url(char *out, size_t cap, const char *path) {
  size_t n = (size_t)snprintf(out, cap, "file://");
  for (const unsigned char *s = (const unsigned char *)path; *s && n + 4 < cap; s++) {
    bool plain = (*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') || (*s >= '0' && *s <= '9') || strchr("-._~/", *s);
    if (plain) out[n++] = (char)*s;
    else n += (size_t)snprintf(out + n, cap - n, "%%%02X", *s);
  }
  out[n] = 0;
}

static void put_metadata(Buf *b) {
  Array a = array_begin(b, 8);
  char path[64];
  track_path(path, sizeof path);
  entry_str(b, "mpris:trackid", "o", path);
  if (g_np.has) {
    if (g_np.duration > 0) {
      entry_begin(b, "mpris:length", "x");
      put_i64(b, (int64_t)(g_np.duration * 1e6));
    }
    entry_str(b, "xesam:title", "s", g_np.title);
    if (*g_np.artist) {
      entry_begin(b, "xesam:artist", "as");
      Array artists = array_begin(b, 4);
      put_str(b, g_np.artist);
      array_end(b, artists);
    }
    if (*g_np.album) entry_str(b, "xesam:album", "s", g_np.album);
    if (*g_np.art_path) {
      char url[PATH_MAX * 3 + 8];
      file_url(url, sizeof url, g_np.art_path);
      entry_str(b, "mpris:artUrl", "s", url);
    }
  }
  array_end(b, a);
}

static void put_bool_variant(Buf *b, bool v) {
  put_sig(b, "b");
  put_u32(b, v);
}

static void put_double_variant(Buf *b, double v) {
  put_sig(b, "d");
  put_f64(b, v);
}

static void put_empty_strings_variant(Buf *b) {
  put_sig(b, "as");
  array_end(b, array_begin(b, 4));
}

// put_property writes the property's value as a variant, false when the
// interface has no such property.
static bool put_property(Buf *b, const char *interface, const char *name) {
  if (!strcmp(interface, ROOT_INTERFACE)) {
    if (!strcmp(name, "CanQuit") || !strcmp(name, "CanRaise") || !strcmp(name, "HasTrackList")) put_bool_variant(b, false);
    else if (!strcmp(name, "Identity")) put_sig(b, "s"), put_str(b, "TIDALfast");
    else if (!strcmp(name, "DesktopEntry")) put_sig(b, "s"), put_str(b, "tidalfast");
    else if (!strcmp(name, "SupportedUriSchemes") || !strcmp(name, "SupportedMimeTypes")) put_empty_strings_variant(b);
    else return false;
    return true;
  }
  if (!strcmp(interface, PLAYER_INTERFACE)) {
    bool has = g_np.has;
    if (!strcmp(name, "PlaybackStatus")) {
      const char *status = !has || g_np.state == NOW_PLAYING_STOPPED ? "Stopped" : g_np.state == NOW_PLAYING_PLAYING ? "Playing" : "Paused";
      put_sig(b, "s"), put_str(b, status);
    } else if (!strcmp(name, "Metadata")) {
      put_sig(b, "a{sv}");
      put_metadata(b);
    } else if (!strcmp(name, "Position")) {
      put_sig(b, "x");
      put_i64(b, (int64_t)(position_now() * 1e6));
    } else if (!strcmp(name, "Rate") || !strcmp(name, "MinimumRate") || !strcmp(name, "MaximumRate") || !strcmp(name, "Volume")) {
      put_double_variant(b, 1);
    } else if (!strcmp(name, "CanPlay")) {
      put_bool_variant(b, true); // with nothing loaded, the selected row
    } else if (!strcmp(name, "CanGoNext") || !strcmp(name, "CanGoPrevious") || !strcmp(name, "CanPause")) {
      put_bool_variant(b, has);
    } else if (!strcmp(name, "CanSeek")) {
      put_bool_variant(b, has && g_np.duration > 0);
    } else if (!strcmp(name, "CanControl")) {
      put_bool_variant(b, true);
    } else {
      return false;
    }
    return true;
  }
  return false;
}

static const char *const g_root_properties[] = {"CanQuit", "CanRaise", "HasTrackList", "Identity", "DesktopEntry", "SupportedUriSchemes", "SupportedMimeTypes", NULL};
static const char *const g_player_properties[] = {"PlaybackStatus", "Rate", "Metadata", "Volume", "Position", "MinimumRate", "MaximumRate", "CanGoNext",
                                                  "CanGoPrevious", "CanPlay", "CanPause", "CanSeek", "CanControl", NULL};

static void put_properties(Buf *b, const char *interface, const char *const *names) {
  Array a = array_begin(b, 8);
  for (; names && *names; names++) {
    pad(b, 8);
    put_str(b, *names);
    put_property(b, interface, *names);
  }
  array_end(b, a);
}

static void properties_changed(const char *const *names) {
  Buf body = {0};
  put_str(&body, PLAYER_INTERFACE);
  put_properties(&body, PLAYER_INTERFACE, names);
  array_end(&body, array_begin(&body, 4)); // nothing invalidated
  Header h = {.type = MSG_SIGNAL, .path = OBJECT_PATH, .interface = PROPERTIES_INTERFACE, .member = "PropertiesChanged", .signature = "sa{sv}as"};
  send_message(&h, &body);
  free(body.p);
}

static void seeked(void) {
  Buf body = {0};
  put_i64(&body, (int64_t)(position_now() * 1e6));
  Header h = {.type = MSG_SIGNAL, .path = OBJECT_PATH, .interface = PLAYER_INTERFACE, .member = "Seeked", .signature = "x"};
  send_message(&h, &body);
  free(body.p);
}

// Calls

static const char g_introspection[] =
    "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\" "
    "\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n"
    "<node>\n"
    " <interface name=\"org.freedesktop.DBus.Introspectable\">\n"
    "  <method name=\"Introspect\"><arg name=\"xml\" type=\"s\" direction=\"out\"/></method>\n"
    " </interface>\n"
    " <interface name=\"org.freedesktop.DBus.Peer\">\n"
    "  <method name=\"Ping\"/>\n"
    "  <method name=\"GetMachineId\"><arg name=\"id\" type=\"s\" direction=\"out\"/></method>\n"
    " </interface>\n"
    " <interface name=\"org.freedesktop.DBus.Properties\">\n"
    "  <method name=\"Get\"><arg name=\"interface\" type=\"s\" direction=\"in\"/><arg name=\"name\" type=\"s\" direction=\"in\"/>"
    "<arg name=\"value\" type=\"v\" direction=\"out\"/></method>\n"
    "  <method name=\"GetAll\"><arg name=\"interface\" type=\"s\" direction=\"in\"/>"
    "<arg name=\"properties\" type=\"a{sv}\" direction=\"out\"/></method>\n"
    "  <method name=\"Set\"><arg name=\"interface\" type=\"s\" direction=\"in\"/><arg name=\"name\" type=\"s\" direction=\"in\"/>"
    "<arg name=\"value\" type=\"v\" direction=\"in\"/></method>\n"
    "  <signal name=\"PropertiesChanged\"><arg name=\"interface\" type=\"s\"/><arg name=\"changed\" type=\"a{sv}\"/>"
    "<arg name=\"invalidated\" type=\"as\"/></signal>\n"
    " </interface>\n"
    " <interface name=\"org.mpris.MediaPlayer2\">\n"
    "  <method name=\"Raise\"/>\n"
    "  <method name=\"Quit\"/>\n"
    "  <property name=\"CanQuit\" type=\"b\" access=\"read\"/>\n"
    "  <property name=\"CanRaise\" type=\"b\" access=\"read\"/>\n"
    "  <property name=\"HasTrackList\" type=\"b\" access=\"read\"/>\n"
    "  <property name=\"Identity\" type=\"s\" access=\"read\"/>\n"
    "  <property name=\"DesktopEntry\" type=\"s\" access=\"read\"/>\n"
    "  <property name=\"SupportedUriSchemes\" type=\"as\" access=\"read\"/>\n"
    "  <property name=\"SupportedMimeTypes\" type=\"as\" access=\"read\"/>\n"
    " </interface>\n"
    " <interface name=\"org.mpris.MediaPlayer2.Player\">\n"
    "  <method name=\"Next\"/>\n"
    "  <method name=\"Previous\"/>\n"
    "  <method name=\"Pause\"/>\n"
    "  <method name=\"PlayPause\"/>\n"
    "  <method name=\"Stop\"/>\n"
    "  <method name=\"Play\"/>\n"
    "  <method name=\"Seek\"><arg name=\"Offset\" type=\"x\" direction=\"in\"/></method>\n"
    "  <method name=\"SetPosition\"><arg name=\"TrackId\" type=\"o\" direction=\"in\"/>"
    "<arg name=\"Position\" type=\"x\" direction=\"in\"/></method>\n"
    "  <method name=\"OpenUri\"><arg name=\"Uri\" type=\"s\" direction=\"in\"/></method>\n"
    "  <signal name=\"Seeked\"><arg name=\"Position\" type=\"x\"/></signal>\n"
    "  <property name=\"PlaybackStatus\" type=\"s\" access=\"read\"/>\n"
    "  <property name=\"Rate\" type=\"d\" access=\"read\"/>\n"
    "  <property name=\"Metadata\" type=\"a{sv}\" access=\"read\"/>\n"
    "  <property name=\"Volume\" type=\"d\" access=\"read\"/>\n"
    "  <property name=\"Position\" type=\"x\" access=\"read\"/>\n"
    "  <property name=\"MinimumRate\" type=\"d\" access=\"read\"/>\n"
    "  <property name=\"MaximumRate\" type=\"d\" access=\"read\"/>\n"
    "  <property name=\"CanGoNext\" type=\"b\" access=\"read\"/>\n"
    "  <property name=\"CanGoPrevious\" type=\"b\" access=\"read\"/>\n"
    "  <property name=\"CanPlay\" type=\"b\" access=\"read\"/>\n"
    "  <property name=\"CanPause\" type=\"b\" access=\"read\"/>\n"
    "  <property name=\"CanSeek\" type=\"b\" access=\"read\"/>\n"
    "  <property name=\"CanControl\" type=\"b\" access=\"read\"/>\n"
    " </interface>\n"
    "</node>\n";

static void reply(const Message *m, const char *signature, const Buf *body) {
  if (m->flags & NO_REPLY_EXPECTED) return;
  Header h = {.type = MSG_RETURN, .reply_serial = m->serial, .destination = m->sender, .signature = signature};
  send_message(&h, body);
}

static void reply_error(const Message *m, const char *name, const char *text) {
  if (m->flags & NO_REPLY_EXPECTED) return;
  Buf body = {0};
  put_str(&body, text);
  Header h = {.type = MSG_ERROR, .reply_serial = m->serial, .destination = m->sender, .error_name = name, .signature = "s"};
  send_message(&h, &body);
  free(body.p);
}

static void reply_string(const Message *m, const char *s) {
  Buf body = {0};
  put_str(&body, s);
  reply(m, "s", &body);
  free(body.p);
}

static void seek_to(double seconds) {
  if (!g_np.has || g_np.duration <= 0) return;
  if (seconds < 0) seconds = 0;
  if (seconds > g_np.duration) {
    // MPRIS: seeking past the end goes to the next track.
    g_command(MEDIA_NEXT, 0);
    return;
  }
  g_command(MEDIA_SEEK, seconds);
}

static void handle_player(const Message *m) {
  static const struct {
    const char *name;
    uint32_t command;
  } simple[] = {{"Next", MEDIA_NEXT}, {"Previous", MEDIA_PREVIOUS}, {"Pause", MEDIA_PAUSE}, {"PlayPause", MEDIA_TOGGLE}, {"Stop", MEDIA_PAUSE}, {"Play", MEDIA_PLAY}};
  for (size_t i = 0; i < sizeof simple / sizeof simple[0]; i++) {
    if (!strcmp(m->member, simple[i].name)) {
      g_command(simple[i].command, 0);
      reply(m, NULL, NULL);
      return;
    }
  }
  Reader r = m->body;
  if (!strcmp(m->member, "Seek") && !strcmp(m->signature, "x")) {
    int64_t offset = rd_i64(&r);
    seek_to(position_now() + (double)offset * 1e-6);
    reply(m, NULL, NULL);
  } else if (!strcmp(m->member, "SetPosition") && !strcmp(m->signature, "ox")) {
    const char *track = rd_str(&r);
    int64_t position = rd_i64(&r);
    char path[64];
    track_path(path, sizeof path);
    // MPRIS: a position for another track, or out of range, is ignored.
    if (!r.bad && g_np.has && !strcmp(track, path) && position >= 0 && (double)position * 1e-6 <= g_np.duration) {
      g_command(MEDIA_SEEK, (double)position * 1e-6);
    }
    reply(m, NULL, NULL);
  } else if (!strcmp(m->member, "OpenUri")) {
    reply_error(m, "org.freedesktop.DBus.Error.NotSupported", "TIDALfast doesn't open URIs");
  } else {
    reply_error(m, "org.freedesktop.DBus.Error.UnknownMethod", "No such method");
  }
}

static void handle_properties(const Message *m) {
  Reader r = m->body;
  if (!strcmp(m->member, "Get") && !strcmp(m->signature, "ss")) {
    const char *interface = rd_str(&r), *name = rd_str(&r);
    Buf body = {0};
    if (!r.bad && put_property(&body, interface, name)) reply(m, "v", &body);
    else reply_error(m, "org.freedesktop.DBus.Error.UnknownProperty", "No such property");
    free(body.p);
  } else if (!strcmp(m->member, "GetAll") && !strcmp(m->signature, "s")) {
    const char *interface = rd_str(&r);
    const char *const *names = !strcmp(interface, ROOT_INTERFACE) ? g_root_properties : !strcmp(interface, PLAYER_INTERFACE) ? g_player_properties : NULL;
    Buf body = {0};
    put_properties(&body, interface, names);
    reply(m, "a{sv}", &body);
    free(body.p);
  } else if (!strcmp(m->member, "Set")) {
    reply_error(m, "org.freedesktop.DBus.Error.PropertyReadOnly", "The properties are read only");
  } else {
    reply_error(m, "org.freedesktop.DBus.Error.UnknownMethod", "No such method");
  }
}

static void handle_call(const Message *m) {
  const char *interface = m->interface ? m->interface : "";
  if (!strcmp(interface, "org.freedesktop.DBus.Peer")) {
    if (!strcmp(m->member, "Ping")) {
      reply(m, NULL, NULL);
    } else if (!strcmp(m->member, "GetMachineId")) {
      char id[64] = "";
      FILE *f = fopen("/etc/machine-id", "r");
      if (f) {
        if (!fgets(id, sizeof id, f)) id[0] = 0;
        fclose(f);
      }
      id[strcspn(id, "\n")] = 0;
      reply_string(m, id);
    } else {
      reply_error(m, "org.freedesktop.DBus.Error.UnknownMethod", "No such method");
    }
    return;
  }
  if (!m->path || strcmp(m->path, OBJECT_PATH)) {
    reply_error(m, "org.freedesktop.DBus.Error.UnknownObject", "No such object");
  } else if (!strcmp(interface, "org.freedesktop.DBus.Introspectable") && !strcmp(m->member, "Introspect")) {
    reply_string(m, g_introspection);
  } else if (!strcmp(interface, PROPERTIES_INTERFACE)) {
    handle_properties(m);
  } else if (!strcmp(interface, ROOT_INTERFACE) && (!strcmp(m->member, "Raise") || !strcmp(m->member, "Quit"))) {
    reply(m, NULL, NULL); // CanRaise and CanQuit say neither does anything
  } else if (!strcmp(interface, PLAYER_INTERFACE)) {
    handle_player(m);
  } else {
    reply_error(m, "org.freedesktop.DBus.Error.UnknownMethod", "No such method");
  }
}

static void handle_name_reply(const Message *m) {
  uint32_t result = 0;
  if (m->type == MSG_RETURN && !strcmp(m->signature, "u")) {
    Reader r = m->body;
    result = rd_u32(&r);
  }
  if (result == NAME_PRIMARY_OWNER || result == NAME_ALREADY_OWNER) {
    snprintf(g_name, sizeof g_name, "%s", g_request_name);
  } else if (!g_tried_instance) {
    // MPRIS: a second instance adds .instance<pid> to the name.
    g_tried_instance = true;
    char name[128];
    snprintf(name, sizeof name, "%s.instance%d", BUS_NAME, (int)getpid());
    request_name(name);
  } else {
    fprintf(stderr, "shell: mpris: couldn't take a bus name\n");
  }
}

// handle reads one whole message. False when it's malformed.
static bool handle(const uint8_t *p, size_t len) {
  Message m = {.type = p[1], .flags = p[2]};
  Reader r = {.p = p, .len = len, .off = 4, .swap = p[0] == 'B'};
  uint32_t body_len = rd_u32(&r);
  m.serial = rd_u32(&r);
  uint32_t fields_len = rd_u32(&r);
  size_t fields_end = 16 + (size_t)fields_len;
  while (r.off < fields_end && !r.bad) {
    rd_align(&r, 8);
    if (r.off >= fields_end) break;
    uint8_t code = p[r.off++];
    const char *sig = rd_sig(&r);
    if (!strcmp(sig, "u")) {
      uint32_t v = rd_u32(&r);
      if (code == F_REPLY_SERIAL) m.reply_serial = v;
    } else if (!strcmp(sig, "s") || !strcmp(sig, "o")) {
      const char *v = rd_str(&r);
      if (code == F_PATH) m.path = v;
      else if (code == F_INTERFACE) m.interface = v;
      else if (code == F_MEMBER) m.member = v;
      else if (code == F_SENDER) m.sender = v;
    } else if (!strcmp(sig, "g")) {
      const char *v = rd_sig(&r);
      if (code == F_SIGNATURE) m.signature = v;
    } else {
      return false;
    }
  }
  if (r.bad) return false;
  size_t body_start = (fields_end + 7) & ~(size_t)7;
  m.body = (Reader){.p = p + body_start, .len = body_len, .swap = r.swap};
  if (!m.signature) m.signature = "";
  if ((m.type == MSG_RETURN || m.type == MSG_ERROR) && m.reply_serial && m.reply_serial == g_request_serial) {
    handle_name_reply(&m);
  } else if (m.type == MSG_CALL && m.member) {
    handle_call(&m);
  }
  return true;
}

// The connection

static void disconnect(const char *why) {
  if (g_fd < 0) return;
  if (why) fprintf(stderr, "shell: mpris: %s\n", why);
  close(g_fd);
  g_fd = -1;
  g_authed = false;
  g_name[0] = 0;
  free(g_in.p);
  free(g_out.p);
  g_in = g_out = (Buf){0};
  g_out_sent = 0;
  g_next_try = mono_seconds() + 10;
}

static void flush(void) {
  while (g_fd >= 0 && g_out_sent < g_out.len) {
    ssize_t n = send(g_fd, g_out.p + g_out_sent, g_out.len - g_out_sent, MSG_NOSIGNAL | MSG_DONTWAIT);
    if (n < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) break;
      disconnect("lost the session bus");
      return;
    }
    g_out_sent += (size_t)n;
  }
  if (g_fd < 0) return;
  if (g_out_sent == g_out.len) {
    g_out.len = g_out_sent = 0;
  } else if (g_out.len - g_out_sent > MAX_OUTPUT) {
    disconnect("the session bus stopped reading");
  }
}

// bus_socket fills addr from the first unix address in a D-Bus address
// list, such as "unix:path=/run/user/1000/bus".
static bool bus_socket(const char *address, struct sockaddr_un *addr, socklen_t *len) {
  char copy[1024];
  snprintf(copy, sizeof copy, "%s", address);
  char *save, *save2;
  for (char *entry = strtok_r(copy, ";", &save); entry; entry = strtok_r(NULL, ";", &save)) {
    if (strncmp(entry, "unix:", 5)) continue;
    for (char *param = strtok_r(entry + 5, ",", &save2); param; param = strtok_r(NULL, ",", &save2)) {
      bool abstract = !strncmp(param, "abstract=", 9);
      if (!abstract && strncmp(param, "path=", 5)) continue;
      const char *v = param + (abstract ? 9 : 5);
      memset(addr, 0, sizeof *addr);
      addr->sun_family = AF_UNIX;
      size_t n = abstract ? 1 : 0;
      for (; *v && n + 1 < sizeof addr->sun_path; v++) {
        unsigned hex;
        if (*v == '%' && sscanf(v + 1, "%2x", &hex) == 1) {
          addr->sun_path[n++] = (char)hex;
          v += 2;
        } else {
          addr->sun_path[n++] = *v;
        }
      }
      if (*v) return false;
      *len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + n + (abstract ? 0 : 1));
      return true;
    }
  }
  return false;
}

// A failed connection is tried again 10 s later, at the next change, and
// one that can never work (no bus, or no unix socket in its address) isn't.
static void connect_bus(void) {
  g_next_try = INFINITY;
  const char *address = getenv("DBUS_SESSION_BUS_ADDRESS");
  char fallback[PATH_MAX + 16];
  if (!address || !*address) {
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (!runtime || !*runtime) {
      fprintf(stderr, "shell: mpris: no session bus\n");
      return;
    }
    snprintf(fallback, sizeof fallback, "unix:path=%s/bus", runtime);
    address = fallback;
  }
  struct sockaddr_un addr;
  socklen_t len;
  if (!bus_socket(address, &addr, &len)) {
    fprintf(stderr, "shell: mpris: no unix socket in the session bus's address\n");
    return;
  }
  int fd = -1;
  for (int attempt = 0; attempt < 3 && fd < 0; attempt++) {
    fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) break;
    if (connect(fd, (struct sockaddr *)&addr, len) == 0) break;
    int err = errno;
    close(fd);
    fd = -1;
    // Interrupted, or the bus's backlog was full: a new socket at once.
    if (err == EINTR || err == EAGAIN) continue;
    errno = err;
    break;
  }
  if (fd < 0) {
    fprintf(stderr, "shell: mpris: can't connect to the session bus: %s\n", strerror(errno));
    g_next_try = mono_seconds() + 10;
    return;
  }
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  g_fd = fd;
  g_tried_instance = false;
  // EXTERNAL: the uid in decimal, hex-encoded, which the bus checks
  // against the socket's credentials. BEGIN goes without waiting for OK.
  char uid[32], auth[128];
  snprintf(uid, sizeof uid, "%u", (unsigned)getuid());
  size_t n = (size_t)snprintf(auth, sizeof auth, "%cAUTH EXTERNAL ", 0);
  for (const char *c = uid; *c; c++) n += (size_t)snprintf(auth + n, sizeof auth - n, "%02x", *c);
  n += (size_t)snprintf(auth + n, sizeof auth - n, "\r\nBEGIN\r\n");
  put(&g_out, auth, n);
  call_bus("Hello", NULL, NULL, NULL);
  request_name(BUS_NAME);
}

// Reads the bus's answer to the authentication: one line, OK and its guid.
static bool read_auth(void) {
  for (size_t i = 0; i + 1 < g_in.len; i++) {
    if (g_in.p[i] != '\r' || g_in.p[i + 1] != '\n') continue;
    if (i < 3 || memcmp(g_in.p, "OK ", 3)) {
      disconnect("the session bus refused the login");
      return false;
    }
    g_authed = true;
    memmove(g_in.p, g_in.p + i + 2, g_in.len - i - 2);
    g_in.len -= i + 2;
    return true;
  }
  if (g_in.len > 512) disconnect("the session bus said something else than OK");
  return false;
}

static void read_messages(void) {
  if (!g_authed && !read_auth()) return;
  size_t at = 0;
  while (g_fd >= 0 && g_in.len - at >= 16) {
    const uint8_t *p = g_in.p + at;
    if ((p[0] != 'l' && p[0] != 'B') || p[3] != 1) {
      disconnect("a message the shell can't read");
      return;
    }
    Reader r = {.p = p, .len = 16, .off = 4, .swap = p[0] == 'B'};
    uint32_t body_len = rd_u32(&r);
    rd_u32(&r);
    uint32_t fields_len = rd_u32(&r);
    if (body_len > MAX_MESSAGE || fields_len > MAX_MESSAGE) {
      disconnect("a message too big");
      return;
    }
    size_t total = ((16 + (size_t)fields_len + 7) & ~(size_t)7) + body_len;
    if (g_in.len - at < total) break;
    if (!handle(p, total)) {
      disconnect("a malformed message");
      return;
    }
    at += total;
  }
  if (g_fd < 0) return;
  memmove(g_in.p, g_in.p + at, g_in.len - at);
  g_in.len -= at;
}

void mpris_dispatch(short revents) {
  if (g_fd < 0) return;
  if (revents & POLLIN) {
    uint8_t chunk[16384];
    while (g_fd >= 0) {
      ssize_t n = recv(g_fd, chunk, sizeof chunk, MSG_DONTWAIT);
      if (n > 0) {
        put(&g_in, chunk, (size_t)n);
        continue;
      }
      if (n < 0 && errno == EINTR) continue;
      if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
      disconnect("lost the session bus");
      return;
    }
    read_messages();
  } else if (revents & (POLLERR | POLLHUP)) {
    disconnect("lost the session bus");
    return;
  }
  flush();
}

int mpris_fd(short *events) {
  *events = POLLIN | (g_out_sent < g_out.len ? POLLOUT : 0);
  return g_fd;
}

const char *mpris_name(void) { return g_name[0] ? g_name : NULL; }

void mpris_init(void (*command)(uint32_t command, double position)) { g_command = command; }

void mpris_start(void) {
  if (g_fd < 0 && mono_seconds() >= g_next_try) connect_bus();
}

// Now Playing

static bool same(const char *a, const char *b) { return !strcmp(a ? a : "", b ? b : ""); }

static char *copy_string(const char *s) { return strdup(s ? s : ""); }

static void remove_art(void) {
  if (*g_np.art_path) unlink(g_np.art_path);
  g_np.art_path[0] = 0;
  g_np.art_key = 0;
}

static void write_art(const Now_Playing *np, uint64_t key) {
  remove_art();
  g_np.art_key = key;
  if (!key || !np->artwork_width || !np->artwork_height) return;
  const char *dir = getenv("XDG_RUNTIME_DIR");
  if (!dir || !*dir) dir = "/tmp";
  size_t size;
  uint8_t *png = png_encode(np->artwork, np->artwork_width, np->artwork_height, &size);
  if (!png) return;
  char path[PATH_MAX];
  snprintf(path, sizeof path, "%s/tidalfast-cover-%d-%llx.png", dir, (int)getpid(), (unsigned long long)np->artwork_key);
  // A new file, never one someone else put there: /tmp is shared.
  unlink(path);
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  bool ok = fd >= 0;
  for (size_t done = 0; ok && done < size;) {
    ssize_t n = write(fd, png + done, size - done);
    if (n < 0 && errno == EINTR) continue;
    ok = n > 0;
    if (ok) done += (size_t)n;
  }
  if (fd >= 0) close(fd);
  free(png);
  if (!ok) {
    unlink(path);
    return;
  }
  snprintf(g_np.art_path, sizeof g_np.art_path, "%s", path);
}

void mpris_set(const Now_Playing *np) {
  bool has = np && np->title;
  if (!has) {
    if (!g_np.has) return;
    g_np.has = false;
    free(g_np.title), free(g_np.artist), free(g_np.album);
    g_np.title = g_np.artist = g_np.album = NULL;
    remove_art();
    static const char *const changed[] = {"PlaybackStatus", "Metadata", "CanGoNext", "CanGoPrevious", "CanPause", "CanSeek", NULL};
    properties_changed(changed);
    return;
  }
  mpris_start();
  bool was = g_np.has;
  bool same_track = was && same(g_np.title, np->title) && same(g_np.artist, np->artist) && same(g_np.album, np->album);
  double predicted = position_now();
  bool status_changed = !was || g_np.state != np->state;
  bool seekable_changed = !was || (g_np.duration > 0) != (np->duration > 0);
  uint64_t art_key = np->artwork ? np->artwork_key : 0;
  bool art_changed = art_key != g_np.art_key;
  bool meta_changed = !same_track || g_np.duration != np->duration || art_changed;

  if (!same_track) {
    free(g_np.title), free(g_np.artist), free(g_np.album);
    g_np.title = copy_string(np->title);
    g_np.artist = copy_string(np->artist);
    g_np.album = copy_string(np->album);
    g_np.track++;
  }
  g_np.has = true;
  g_np.duration = np->duration;
  g_np.state = np->state;
  g_np.elapsed = np->elapsed;
  g_np.stamp = mono_seconds();
  if (art_changed) write_art(np, art_key);

  const char *changed[16];
  int n = 0;
  if (status_changed) changed[n++] = "PlaybackStatus";
  if (meta_changed) changed[n++] = "Metadata";
  if (!was) changed[n++] = "CanGoNext", changed[n++] = "CanGoPrevious", changed[n++] = "CanPause";
  if (seekable_changed) changed[n++] = "CanSeek";
  changed[n] = NULL;
  if (n) properties_changed(changed);
  // Position isn't sent on changes; a client follows it from the rate and
  // hears of a jump through Seeked.
  if (same_track && fabs(np->elapsed - predicted) > 1) seeked();
}

void mpris_close(void) {
  remove_art();
  disconnect(NULL);
  g_next_try = INFINITY;
}
