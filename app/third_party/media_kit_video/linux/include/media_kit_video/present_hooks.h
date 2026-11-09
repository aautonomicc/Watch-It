// W@tch: instrumentation + cost knobs for the Flutter Linux embedder's X11
// present path. Not part of upstream media_kit.
//
// On X11 the embedder renders with EGL while GDK presents with GLX, and the
// two cannot share a texture — so every Flutter frame is copied through the
// CPU: the raster thread reads the whole window back with glReadPixels
// (fl_compositor_opengl.cc, "then we have to copy the texture via the CPU"),
// and the GTK thread uploads it again with glTexImage2D on every paint. At
// 3840×2016 that is 31 MB each way per frame (6–8 ms each on the Mint
// test box). The far larger cost sits right behind the upload: the uploaded
// texture has alpha, so gdk_cairo_draw_from_gl first textures GDK's own
// window paint surface underneath (a full-window X pixmap + glXWaitX) and
// blends — ~75 ms per painted frame at that size, the Mint video judder.
//
// The embedder calls both functions through libepoxy's public dispatch
// pointers (epoxy_glReadPixels / epoxy_glTexImage2D), so this file swaps
// those two pointers for wrappers that
//   - time the readback (split into "wait for the GPU" and "copy") and the
//     upload, for the playback-stats card;
//   - WATCHIT_PRESENT_DOWNSCALE=N (2..4): shrink the frame N× on the GPU
//     before reading it back, upload the small copy and stretch it back to
//     frame size on the GPU for GDK to draw. Cuts both copies by N²;
//   - upload the frame without an alpha channel (GL_RGB, desktop GL only),
//     which makes GDK skip compositing its own window surface underneath.
//     ON by default — Flutter's frame is opaque, the picture is identical;
//     WATCHIT_PRESENT_OPAQUE=0 restores the embedder's RGBA upload.
// WATCHIT_PRESENT_HOOKS=0 leaves the embedder untouched.

#ifndef PRESENT_HOOKS_H_
#define PRESENT_HOOKS_H_

#include <glib.h>

G_BEGIN_DECLS

typedef struct _PresentHookStats {
  gboolean installed;       /* wrappers are in place */
  gint downscale;           /* WATCHIT_PRESENT_DOWNSCALE, 1 = off */
  gboolean opaque;          /* opaque upload on (default) */
  gint64 readback_count;    /* compositor readbacks seen */
  gint64 wait_us_total;     /* glFinish before the readback (GPU render) */
  gint64 copy_us_total;     /* the glReadPixels itself */
  gint64 upload_count;      /* frame uploads on the GTK thread */
  gint64 upload_us_total;   /* glTexImage2D of the frame */
  gint64 scaled_count;      /* readbacks that were downscaled */
  gint64 opaque_count;      /* uploads that went up without alpha */
  gint frame_width;         /* last frame as Flutter rendered it */
  gint frame_height;
  gint copy_width;          /* last frame as it crossed the CPU */
  gint copy_height;
} PresentHookStats;

/* Installs the wrappers once per process (X11 only, idempotent). */
void present_hooks_install(void);

void present_hooks_get_stats(PresentHookStats* out);

G_END_DECLS

#endif  // PRESENT_HOOKS_H_
