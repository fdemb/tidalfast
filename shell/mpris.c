// See mpris.h. The D-Bus side is sd-bus, from libsystemd (or elogind's or
// basu's copy of it), opened with dlopen so that the app runs without it,
// only without MPRIS, and a launch doesn't load it before the first frame.
// Only its header is needed to build: the vtables below are its macros.
// sd-bus answers Get, GetAll, Introspect and Peer from them, and its socket
// is polled with the shell's other files. Connecting, the login and the
// name don't wait for the bus.
//
// The app sends Now Playing only when something changes. Position isn't
// sent with the changes, as MPRIS says: a client asks for it when it needs
// it, and gets the last elapsed time moved on by the clock while playing. A
// jump in it goes out as Seeked.
//
// The cover goes to clients as a URL, so it's written as a PNG to
// $XDG_RUNTIME_DIR, a new file for each cover so that clients don't keep
// showing the one they cached, and the last one is deleted.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
// SD_BUS_VTABLE_START points at this, which libsystemd has, as the mark of
// the vtable format the header writes; sd-bus only checks that it's set.
// It can't be linked from a library that's opened later, so it's ours.
#define sd_bus_object_vtable_format g_vtable_format
#include <systemd/sd-bus.h>
#include <time.h>
#include <unistd.h>

#include "mpris.h"
#include "png.h"

#define OBJECT_PATH "/org/mpris/MediaPlayer2"
#define BUS_NAME "org.mpris.MediaPlayer2.tidalfast"
#define PLAYER_INTERFACE "org.mpris.MediaPlayer2.Player"

// RequestName's answers.
enum { NAME_PRIMARY_OWNER = 1, NAME_ALREADY_OWNER = 4 };

const unsigned g_vtable_format = 242;

// The sd-bus calls, from dlopen.
static struct {
  int (*open_user)(sd_bus **);
  int (*add_object_vtable)(sd_bus *, sd_bus_slot **, const char *, const char *, const sd_bus_vtable *, void *);
  int (*request_name_async)(sd_bus *, sd_bus_slot **, const char *, uint64_t, sd_bus_message_handler_t, void *);
  int (*get_fd)(sd_bus *);
  int (*get_events)(sd_bus *);
  int (*process)(sd_bus *, sd_bus_message **);
  sd_bus *(*flush_close_unref)(sd_bus *);
  int (*emit_properties_changed_strv)(sd_bus *, const char *, const char *, char **);
  int (*emit_signal)(sd_bus *, const char *, const char *, const char *, const char *, ...);
  int (*message_append)(sd_bus_message *, const char *, ...);
  int (*message_open_container)(sd_bus_message *, char, const char *);
  int (*message_close_container)(sd_bus_message *);
  int (*message_read)(sd_bus_message *, const char *, ...);
  int (*message_is_method_error)(sd_bus_message *, const char *);
  int (*reply_method_return)(sd_bus_message *, const char *, ...);
  int (*error_set_const)(sd_bus_error *, const char *, const char *);
} g_sd;

static void (*g_command)(uint32_t command, double position);
static sd_bus *g_bus;
static double g_next_try; // when to try connecting again, on the clock below; INFINITY for never
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

// The player bar's controls as the app last sent them, or as a client set
// them since.
static Player_Controls g_controls = {.volume = 1};

static const char *const g_loop_names[] = {[PLAYER_REPEAT_OFF] = "None", [PLAYER_REPEAT_ALL] = "Playlist", [PLAYER_REPEAT_ONE] = "Track"};

static double mono_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

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

// Properties

static int get_root(sd_bus *bus, const char *path, const char *interface, const char *property, sd_bus_message *reply, void *userdata,
                    sd_bus_error *error) {
  if (!strcmp(property, "Identity")) return g_sd.message_append(reply, "s", "TIDALfast");
  if (!strcmp(property, "DesktopEntry")) return g_sd.message_append(reply, "s", "tidalfast");
  if (!strcmp(property, "SupportedUriSchemes") || !strcmp(property, "SupportedMimeTypes")) return g_sd.message_append(reply, "as", 0);
  return g_sd.message_append(reply, "b", 0); // CanQuit, CanRaise, HasTrackList
}

static int put_metadata(sd_bus_message *m) {
  int r = g_sd.message_open_container(m, 'a', "{sv}");
  if (r < 0) return r;
  char path[64];
  track_path(path, sizeof path);
  r = g_sd.message_append(m, "{sv}", "mpris:trackid", "o", path);
  if (g_np.has) {
    if (r >= 0 && g_np.duration > 0) r = g_sd.message_append(m, "{sv}", "mpris:length", "x", (int64_t)(g_np.duration * 1e6));
    if (r >= 0) r = g_sd.message_append(m, "{sv}", "xesam:title", "s", g_np.title);
    if (r >= 0 && *g_np.artist) r = g_sd.message_append(m, "{sv}", "xesam:artist", "as", 1, g_np.artist);
    if (r >= 0 && *g_np.album) r = g_sd.message_append(m, "{sv}", "xesam:album", "s", g_np.album);
    if (r >= 0 && *g_np.art_path) {
      char url[PATH_MAX * 3 + 8];
      file_url(url, sizeof url, g_np.art_path);
      r = g_sd.message_append(m, "{sv}", "mpris:artUrl", "s", url);
    }
  }
  return r < 0 ? r : g_sd.message_close_container(m);
}

static int get_player(sd_bus *bus, const char *path, const char *interface, const char *property, sd_bus_message *reply, void *userdata,
                      sd_bus_error *error) {
  bool has = g_np.has;
  if (!strcmp(property, "PlaybackStatus")) {
    const char *status = !has || g_np.state == NOW_PLAYING_STOPPED ? "Stopped" : g_np.state == NOW_PLAYING_PLAYING ? "Playing" : "Paused";
    return g_sd.message_append(reply, "s", status);
  }
  if (!strcmp(property, "Metadata")) return put_metadata(reply);
  if (!strcmp(property, "Position")) return g_sd.message_append(reply, "x", (int64_t)(position_now() * 1e6));
  if (!strcmp(property, "CanSeek")) return g_sd.message_append(reply, "b", has && g_np.duration > 0);
  // CanPlay: with nothing loaded, play starts the selected row.
  if (!strcmp(property, "CanPlay") || !strcmp(property, "CanControl")) return g_sd.message_append(reply, "b", 1);
  if (property[0] == 'C') return g_sd.message_append(reply, "b", has); // CanGoNext, CanGoPrevious, CanPause
  if (!strcmp(property, "Volume")) return g_sd.message_append(reply, "d", g_controls.volume);
  if (!strcmp(property, "Shuffle")) return g_sd.message_append(reply, "b", g_controls.shuffle != 0);
  if (!strcmp(property, "LoopStatus")) return g_sd.message_append(reply, "s", g_loop_names[g_controls.repeat <= PLAYER_REPEAT_ONE ? g_controls.repeat : 0]);
  return g_sd.message_append(reply, "d", 1.0); // Rate, MinimumRate, MaximumRate
}

static void properties_changed(char **names);

static void control_changed(const char *name) {
  char *names[] = {(char *)name, NULL};
  properties_changed(names);
}

// A client's write takes effect here at once, so a read right after it
// gets the new value, and goes to the app as a command. The app's next
// controls then match it, unless the app changed them again meanwhile.
static int set_player(sd_bus *bus, const char *path, const char *interface, const char *property, sd_bus_message *value, void *userdata,
                      sd_bus_error *error) {
  if (!strcmp(property, "Volume")) {
    double v;
    int r = g_sd.message_read(value, "d", &v);
    if (r < 0) return r;
    if (isnan(v)) return g_sd.error_set_const(error, SD_BUS_ERROR_INVALID_ARGS, "Volume is not a number");
    // MPRIS: below 0 is 0. The app's slider stops at 1. Kept as a float, as
    // the app keeps it, so its answer doesn't change it again.
    v = (float)(v < 0 ? 0 : v > 1 ? 1 : v);
    if (v != g_controls.volume) g_controls.volume = v, control_changed("Volume");
    g_command(MEDIA_VOLUME, v);
    return 0;
  }
  if (!strcmp(property, "Shuffle")) {
    int on;
    int r = g_sd.message_read(value, "b", &on);
    if (r < 0) return r;
    if ((uint32_t)(on != 0) != g_controls.shuffle) g_controls.shuffle = on != 0, control_changed("Shuffle");
    g_command(MEDIA_SHUFFLE, on != 0);
    return 0;
  }
  const char *loop;
  int r = g_sd.message_read(value, "s", &loop);
  if (r < 0) return r;
  uint32_t repeat = 0;
  while (repeat <= PLAYER_REPEAT_ONE && strcmp(loop, g_loop_names[repeat])) repeat++;
  if (repeat > PLAYER_REPEAT_ONE) return g_sd.error_set_const(error, SD_BUS_ERROR_INVALID_ARGS, "LoopStatus is None, Track or Playlist");
  if (repeat != g_controls.repeat) g_controls.repeat = repeat, control_changed("LoopStatus");
  g_command(MEDIA_REPEAT, repeat);
  return 0;
}

// Methods

static int reply_empty(sd_bus_message *m) { return g_sd.reply_method_return(m, ""); }

#define COMMAND_METHOD(name, command)                                    \
  static int name(sd_bus_message *m, void *userdata, sd_bus_error *e) { \
    g_command(command, 0);                                              \
    return reply_empty(m);                                              \
  }
COMMAND_METHOD(method_next, MEDIA_NEXT)
COMMAND_METHOD(method_previous, MEDIA_PREVIOUS)
COMMAND_METHOD(method_pause, MEDIA_PAUSE)
COMMAND_METHOD(method_play_pause, MEDIA_TOGGLE)
COMMAND_METHOD(method_stop, MEDIA_PAUSE) // there's no stop, only pause
COMMAND_METHOD(method_play, MEDIA_PLAY)

static int method_nothing(sd_bus_message *m, void *userdata, sd_bus_error *e) { return reply_empty(m); }

static int method_seek(sd_bus_message *m, void *userdata, sd_bus_error *e) {
  int64_t offset;
  int r = g_sd.message_read(m, "x", &offset);
  if (r < 0) return r;
  double to = position_now() + (double)offset * 1e-6;
  if (g_np.has && g_np.duration > 0) {
    // MPRIS: seeking past the end goes to the next track.
    if (to > g_np.duration) g_command(MEDIA_NEXT, 0);
    else g_command(MEDIA_SEEK, to < 0 ? 0 : to);
  }
  return reply_empty(m);
}

static int method_set_position(sd_bus_message *m, void *userdata, sd_bus_error *e) {
  const char *track;
  int64_t position;
  int r = g_sd.message_read(m, "ox", &track, &position);
  if (r < 0) return r;
  char path[64];
  track_path(path, sizeof path);
  // MPRIS: a position for another track, or out of range, is ignored.
  if (g_np.has && !strcmp(track, path) && position >= 0 && (double)position * 1e-6 <= g_np.duration) g_command(MEDIA_SEEK, (double)position * 1e-6);
  return reply_empty(m);
}

static int method_open_uri(sd_bus_message *m, void *userdata, sd_bus_error *e) {
  return g_sd.error_set_const(e, SD_BUS_ERROR_NOT_SUPPORTED, "TIDALfast doesn't open URIs");
}

#define CONST_PROPERTY(name, sig, get) SD_BUS_PROPERTY(name, sig, get, 0, SD_BUS_VTABLE_PROPERTY_CONST)
#define CHANGING_PROPERTY(name, sig) SD_BUS_PROPERTY(name, sig, get_player, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE)
#define WRITABLE_PROPERTY(name, sig) SD_BUS_WRITABLE_PROPERTY(name, sig, get_player, set_player, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE)

static const sd_bus_vtable g_root_vtable[] = {
    SD_BUS_VTABLE_START(0),
    // CanRaise and CanQuit say neither does anything.
    SD_BUS_METHOD("Raise", "", "", method_nothing, 0),
    SD_BUS_METHOD("Quit", "", "", method_nothing, 0),
    CONST_PROPERTY("CanQuit", "b", get_root),
    CONST_PROPERTY("CanRaise", "b", get_root),
    CONST_PROPERTY("HasTrackList", "b", get_root),
    CONST_PROPERTY("Identity", "s", get_root),
    CONST_PROPERTY("DesktopEntry", "s", get_root),
    CONST_PROPERTY("SupportedUriSchemes", "as", get_root),
    CONST_PROPERTY("SupportedMimeTypes", "as", get_root),
    SD_BUS_VTABLE_END,
};

static const sd_bus_vtable g_player_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("Next", "", "", method_next, 0),
    SD_BUS_METHOD("Previous", "", "", method_previous, 0),
    SD_BUS_METHOD("Pause", "", "", method_pause, 0),
    SD_BUS_METHOD("PlayPause", "", "", method_play_pause, 0),
    SD_BUS_METHOD("Stop", "", "", method_stop, 0),
    SD_BUS_METHOD("Play", "", "", method_play, 0),
    SD_BUS_METHOD("Seek", "x", "", method_seek, 0),
    SD_BUS_METHOD("SetPosition", "ox", "", method_set_position, 0),
    SD_BUS_METHOD("OpenUri", "s", "", method_open_uri, 0),
    SD_BUS_SIGNAL("Seeked", "x", 0),
    CHANGING_PROPERTY("PlaybackStatus", "s"),
    CHANGING_PROPERTY("Metadata", "a{sv}"),
    CHANGING_PROPERTY("CanGoNext", "b"),
    CHANGING_PROPERTY("CanGoPrevious", "b"),
    CHANGING_PROPERTY("CanPause", "b"),
    CHANGING_PROPERTY("CanSeek", "b"),
    WRITABLE_PROPERTY("Volume", "d"),
    WRITABLE_PROPERTY("Shuffle", "b"),
    WRITABLE_PROPERTY("LoopStatus", "s"),
    // MPRIS: Position never sends PropertiesChanged.
    SD_BUS_PROPERTY("Position", "x", get_player, 0, 0),
    CONST_PROPERTY("CanPlay", "b", get_player),
    CONST_PROPERTY("CanControl", "b", get_player),
    CONST_PROPERTY("Rate", "d", get_player),
    CONST_PROPERTY("MinimumRate", "d", get_player),
    CONST_PROPERTY("MaximumRate", "d", get_player),
    SD_BUS_VTABLE_END,
};

// The connection

static bool load_sd_bus(void) {
  static int loaded; // 1 when it's there, -1 when it isn't
  if (loaded) return loaded > 0;
  loaded = -1;
  static const char *const libraries[] = {"libsystemd.so.0", "libelogind.so.0", "libbasu.so.0"};
  void *lib = NULL;
  for (size_t i = 0; i < sizeof libraries / sizeof libraries[0] && !lib; i++) lib = dlopen(libraries[i], RTLD_NOW | RTLD_LOCAL);
  if (!lib) {
    fprintf(stderr, "shell: mpris: no libsystemd, so no media controls\n");
    return false;
  }
  static const struct {
    const char *name;
    void **slot;
  } calls[] = {
      {"sd_bus_open_user", (void **)&g_sd.open_user},
      {"sd_bus_add_object_vtable", (void **)&g_sd.add_object_vtable},
      {"sd_bus_request_name_async", (void **)&g_sd.request_name_async},
      {"sd_bus_get_fd", (void **)&g_sd.get_fd},
      {"sd_bus_get_events", (void **)&g_sd.get_events},
      {"sd_bus_process", (void **)&g_sd.process},
      {"sd_bus_flush_close_unref", (void **)&g_sd.flush_close_unref},
      {"sd_bus_emit_properties_changed_strv", (void **)&g_sd.emit_properties_changed_strv},
      {"sd_bus_emit_signal", (void **)&g_sd.emit_signal},
      {"sd_bus_message_append", (void **)&g_sd.message_append},
      {"sd_bus_message_open_container", (void **)&g_sd.message_open_container},
      {"sd_bus_message_close_container", (void **)&g_sd.message_close_container},
      {"sd_bus_message_read", (void **)&g_sd.message_read},
      {"sd_bus_message_is_method_error", (void **)&g_sd.message_is_method_error},
      {"sd_bus_reply_method_return", (void **)&g_sd.reply_method_return},
      {"sd_bus_error_set_const", (void **)&g_sd.error_set_const},
  };
  for (size_t i = 0; i < sizeof calls / sizeof calls[0]; i++) {
    if (!(*calls[i].slot = dlsym(lib, calls[i].name))) {
      fprintf(stderr, "shell: mpris: libsystemd has no %s\n", calls[i].name);
      return false;
    }
  }
  loaded = 1;
  return true;
}

static int name_reply(sd_bus_message *m, void *userdata, sd_bus_error *e);

static void request_name(const char *name) {
  snprintf(g_request_name, sizeof g_request_name, "%s", name);
  // Without SD_BUS_NAME_QUEUE, the bus says the name is taken rather than queue us.
  int r = g_sd.request_name_async(g_bus, NULL, g_request_name, 0, name_reply, NULL);
  if (r < 0) fprintf(stderr, "shell: mpris: couldn't ask for a bus name: %s\n", strerror(-r));
}

static int name_reply(sd_bus_message *m, void *userdata, sd_bus_error *e) {
  uint32_t result = 0;
  bool refused = g_sd.message_is_method_error(m, NULL);
  if (!refused) g_sd.message_read(m, "u", &result);
  if (result == NAME_PRIMARY_OWNER || result == NAME_ALREADY_OWNER) {
    snprintf(g_name, sizeof g_name, "%s", g_request_name);
    fprintf(stderr, "shell: mpris: took %s\n", g_name);
  } else if (!g_tried_instance) {
    fprintf(stderr, "shell: mpris: %s %s\n", refused ? "the bus refused" : "someone else has", g_request_name);
    // MPRIS: a second instance adds .instance<pid> to the name.
    g_tried_instance = true;
    char name[128];
    snprintf(name, sizeof name, "%s.instance%d", BUS_NAME, (int)getpid());
    request_name(name);
  } else {
    fprintf(stderr, "shell: mpris: couldn't take a bus name\n");
  }
  return 0;
}

static void close_bus(void) {
  if (!g_bus) return;
  g_sd.flush_close_unref(g_bus);
  g_bus = NULL;
  g_name[0] = 0;
}

// A failed or lost connection is tried again 10 s later, at the next
// change; without libsystemd it never is.
static void connect_bus(void) {
  g_next_try = INFINITY;
  if (!load_sd_bus()) return;
  const char *step = "connect to the session bus";
  int r = g_sd.open_user(&g_bus);
  if (r >= 0) step = "add the root interface", r = g_sd.add_object_vtable(g_bus, NULL, OBJECT_PATH, "org.mpris.MediaPlayer2", g_root_vtable, NULL);
  if (r >= 0) step = "add the player interface", r = g_sd.add_object_vtable(g_bus, NULL, OBJECT_PATH, PLAYER_INTERFACE, g_player_vtable, NULL);
  if (r < 0) {
    fprintf(stderr, "shell: mpris: can't %s: %s\n", step, strerror(-r));
    close_bus();
    g_next_try = mono_seconds() + 10;
    return;
  }
  g_tried_instance = false;
  request_name(BUS_NAME);
}

void mpris_dispatch(short revents) {
  if (!g_bus) return;
  int r;
  while ((r = g_sd.process(g_bus, NULL)) > 0) {
  }
  if (r < 0) {
    fprintf(stderr, "shell: mpris: lost the session bus: %s\n", strerror(-r));
    close_bus();
    g_next_try = mono_seconds() + 10;
  }
}

int mpris_fd(short *events) {
  if (!g_bus) return -1;
  int e = g_sd.get_events(g_bus);
  *events = e < 0 ? POLLIN : (short)e;
  return g_sd.get_fd(g_bus);
}

const char *mpris_name(void) { return g_name[0] ? g_name : NULL; }

void mpris_init(void (*command)(uint32_t command, double position)) { g_command = command; }

void mpris_start(void) {
  if (!g_bus && mono_seconds() >= g_next_try) connect_bus();
}

// Now Playing

static void properties_changed(char **names) {
  if (g_bus) g_sd.emit_properties_changed_strv(g_bus, OBJECT_PATH, PLAYER_INTERFACE, names);
}

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
    static char *changed[] = {"PlaybackStatus", "Metadata", "CanGoNext", "CanGoPrevious", "CanPause", "CanSeek", NULL};
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

  char *changed[8];
  int n = 0;
  if (status_changed) changed[n++] = "PlaybackStatus";
  if (meta_changed) changed[n++] = "Metadata";
  if (!was) changed[n++] = "CanGoNext", changed[n++] = "CanGoPrevious", changed[n++] = "CanPause";
  if (seekable_changed) changed[n++] = "CanSeek";
  changed[n] = NULL;
  if (n) properties_changed(changed);
  if (same_track && fabs(np->elapsed - predicted) > 1 && g_bus) {
    g_sd.emit_signal(g_bus, OBJECT_PATH, PLAYER_INTERFACE, "Seeked", "x", (int64_t)(position_now() * 1e6));
  }
}

void mpris_set_controls(const Player_Controls *c) {
  char *changed[4];
  int n = 0;
  if (c->volume != g_controls.volume) changed[n++] = "Volume";
  if (c->shuffle != g_controls.shuffle) changed[n++] = "Shuffle";
  if (c->repeat != g_controls.repeat) changed[n++] = "LoopStatus";
  changed[n] = NULL;
  g_controls = *c;
  if (n) properties_changed(changed);
}

void mpris_close(void) {
  remove_art();
  close_bus();
  g_next_try = INFINITY;
}
