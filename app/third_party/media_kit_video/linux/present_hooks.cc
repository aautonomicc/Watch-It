// W@tch: see include/media_kit_video/present_hooks.h.

#include "include/media_kit_video/present_hooks.h"

#include <epoxy/gl.h>
#include <gdk/gdk.h>
#include <gdk/gdkx.h>

#include <cstdlib>

namespace {

typedef void (*ReadPixelsFn)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum,
                             void*);
typedef void (*TexImage2DFn)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint,
                             GLenum, GLenum, const void*);

// What epoxy's pointers held when the wrappers went in: either its lazy
// resolver thunk or the already-resolved driver function.
ReadPixelsFn g_orig_read = nullptr;
TexImage2DFn g_orig_tex = nullptr;
// The driver functions, known after the first call through each wrapper.
ReadPixelsFn g_real_read = nullptr;
TexImage2DFn g_real_tex = nullptr;
GMutex g_resolve_mutex;

gboolean g_installed = FALSE;
gint g_downscale = 1;
gboolean g_opaque = TRUE;

// The compositor's CPU copy of the current frame. Written by the raster
// thread's readback, read by the GTK thread's upload; the embedder holds
// its frame mutex around both, |g_frame_mutex| only guards these fields.
GMutex g_frame_mutex;
const void* g_frame_ptr = nullptr;
gint g_frame_w = 0, g_frame_h = 0;  // as Flutter rendered it
gint g_copy_w = 0, g_copy_h = 0;    // as stored in |g_frame_ptr|

// Scratch target for the GPU downscale, owned by the raster thread's
// context (recreated if the size changes).
GLuint g_scratch_fbo = 0, g_scratch_rb = 0;
gint g_scratch_w = 0, g_scratch_h = 0;
gboolean g_scale_broken = FALSE;

gint64 g_readback_count, g_wait_us, g_copy_us;
gint64 g_upload_count, g_upload_us;
gint64 g_scaled_count, g_opaque_count;

inline void add(gint64* slot, gint64 v) {
  __atomic_fetch_add(slot, v, __ATOMIC_RELAXED);
}
inline gint64 get(gint64* slot) {
  return __atomic_load_n(slot, __ATOMIC_RELAXED);
}

void hook_read_pixels(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void*);
void hook_tex_image_2d(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum,
                       GLenum, const void*);

// epoxy's resolver thunk only resolves while the dispatch pointer still
// points at the thunk itself, and then calls *through the pointer* — so the
// thunk cannot be called with a wrapper installed (it would call the
// wrapper back). The first call therefore runs with epoxy's own value put
// back: the thunk resolves, rewrites the pointer to the driver function and
// makes the call; that function is kept and the wrapper goes back in.
void real_read_pixels(GLint x, GLint y, GLsizei w, GLsizei h, GLenum format,
                      GLenum type, void* pixels) {
  ReadPixelsFn real = __atomic_load_n(&g_real_read, __ATOMIC_ACQUIRE);
  if (real != nullptr) {
    real(x, y, w, h, format, type, pixels);
    return;
  }
  g_mutex_lock(&g_resolve_mutex);
  if (g_real_read == nullptr) {
    epoxy_glReadPixels = g_orig_read;
    epoxy_glReadPixels(x, y, w, h, format, type, pixels);
    ReadPixelsFn resolved = epoxy_glReadPixels;
    epoxy_glReadPixels = hook_read_pixels;
    if (resolved != hook_read_pixels) {
      __atomic_store_n(&g_real_read, resolved, __ATOMIC_RELEASE);
    }
    g_mutex_unlock(&g_resolve_mutex);
    return;
  }
  real = g_real_read;
  g_mutex_unlock(&g_resolve_mutex);
  real(x, y, w, h, format, type, pixels);
}

void real_tex_image_2d(GLenum target, GLint level, GLint internalformat,
                       GLsizei w, GLsizei h, GLint border, GLenum format,
                       GLenum type, const void* pixels) {
  TexImage2DFn real = __atomic_load_n(&g_real_tex, __ATOMIC_ACQUIRE);
  if (real != nullptr) {
    real(target, level, internalformat, w, h, border, format, type, pixels);
    return;
  }
  g_mutex_lock(&g_resolve_mutex);
  if (g_real_tex == nullptr) {
    epoxy_glTexImage2D = g_orig_tex;
    epoxy_glTexImage2D(target, level, internalformat, w, h, border, format,
                       type, pixels);
    TexImage2DFn resolved = epoxy_glTexImage2D;
    epoxy_glTexImage2D = hook_tex_image_2d;
    if (resolved != hook_tex_image_2d) {
      __atomic_store_n(&g_real_tex, resolved, __ATOMIC_RELEASE);
    }
    g_mutex_unlock(&g_resolve_mutex);
    return;
  }
  real = g_real_tex;
  g_mutex_unlock(&g_resolve_mutex);
  real(target, level, internalformat, w, h, border, format, type, pixels);
}

gboolean on_gtk_thread() {
  return g_main_context_is_owner(g_main_context_default());
}

// Blits the bound read framebuffer (the frame, |w|×|h|) into a |sw|×|sh|
// scratch buffer with linear filtering and reads that back instead. All
// touched GL state is restored. FALSE = nothing was read, do a plain read.
gboolean read_downscaled(GLsizei w, GLsizei h, gint sw, gint sh, void* pixels) {
  if (g_scale_broken) {
    return FALSE;
  }
  static gboolean blit_checked = FALSE;
  if (!blit_checked) {
    blit_checked = TRUE;
    if (!(epoxy_gl_version() >= 30 ||
          epoxy_has_gl_extension("GL_NV_framebuffer_blit") ||
          epoxy_has_gl_extension("GL_EXT_framebuffer_blit"))) {
      g_scale_broken = TRUE;
      g_printerr("watchit: present downscale off (no framebuffer blit)\n");
      return FALSE;
    }
  }
  GLint prev_read = 0, prev_draw = 0, prev_rb = 0;
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev_read);
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw);
  glGetIntegerv(GL_RENDERBUFFER_BINDING, &prev_rb);
  GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);

  if (g_scratch_fbo == 0 || !glIsFramebuffer(g_scratch_fbo) ||
      g_scratch_w != sw || g_scratch_h != sh) {
    if (g_scratch_fbo == 0 || !glIsFramebuffer(g_scratch_fbo)) {
      // First use, or the context the scratch lived in is gone.
      glGenFramebuffers(1, &g_scratch_fbo);
      glGenRenderbuffers(1, &g_scratch_rb);
    }
    glBindRenderbuffer(GL_RENDERBUFFER, g_scratch_rb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, sw, sh);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g_scratch_fbo);
    glFramebufferRenderbuffer(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                              GL_RENDERBUFFER, g_scratch_rb);
    g_scratch_w = sw;
    g_scratch_h = sh;
    if (glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) !=
        GL_FRAMEBUFFER_COMPLETE) {
      g_scale_broken = TRUE;
      g_printerr("watchit: present downscale off (scratch incomplete)\n");
      glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prev_draw);
      glBindRenderbuffer(GL_RENDERBUFFER, prev_rb);
      return FALSE;
    }
  } else {
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g_scratch_fbo);
  }

  if (scissor) {
    glDisable(GL_SCISSOR_TEST);
  }
  glBlitFramebuffer(0, 0, w, h, 0, 0, sw, sh, GL_COLOR_BUFFER_BIT, GL_LINEAR);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, g_scratch_fbo);
  real_read_pixels(0, 0, sw, sh, GL_RGBA, GL_UNSIGNED_BYTE, pixels);

  if (scissor) {
    glEnable(GL_SCISSOR_TEST);
  }
  glBindFramebuffer(GL_READ_FRAMEBUFFER, prev_read);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prev_draw);
  glBindRenderbuffer(GL_RENDERBUFFER, prev_rb);
  return TRUE;
}

// GTK-thread half of the downscale: the bound texture is the one GDK is
// about to draw, and GDK addresses it in frame pixels (a smaller texture
// would tile), so it is allocated at the full |w|×|h| without data, the
// |cw|×|ch| copy goes into a scratch texture and is stretched across on
// the GPU. Pixel-doubling (GL_NEAREST) keeps integer factors crisp.
// FALSE = nothing usable was produced.
GLuint g_up_tex = 0, g_up_read_fbo = 0, g_up_draw_fbo = 0;
gint g_up_w = 0, g_up_h = 0;

gboolean upload_upscaled(GLint ifmt, GLsizei w, GLsizei h, gint cw, gint ch,
                         const void* pixels) {
  GLint bound_tex = 0, prev_read = 0, prev_draw = 0;
  glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound_tex);
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev_read);
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw);
  GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);

  real_tex_image_2d(GL_TEXTURE_2D, 0, ifmt, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                    nullptr);

  if (g_up_tex == 0 || !glIsTexture(g_up_tex)) {
    glGenTextures(1, &g_up_tex);
    glGenFramebuffers(1, &g_up_read_fbo);
    glGenFramebuffers(1, &g_up_draw_fbo);
    g_up_w = g_up_h = 0;
  }
  glBindTexture(GL_TEXTURE_2D, g_up_tex);
  if (g_up_w != cw || g_up_h != ch) {
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    real_tex_image_2d(GL_TEXTURE_2D, 0, GL_RGBA, cw, ch, 0, GL_RGBA,
                      GL_UNSIGNED_BYTE, pixels);
    g_up_w = cw;
    g_up_h = ch;
  } else {
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, cw, ch, GL_RGBA, GL_UNSIGNED_BYTE,
                    pixels);
  }

  glBindFramebuffer(GL_READ_FRAMEBUFFER, g_up_read_fbo);
  glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                         GL_TEXTURE_2D, g_up_tex, 0);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g_up_draw_fbo);
  glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                         GL_TEXTURE_2D, bound_tex, 0);
  gboolean ok =
      glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) ==
          GL_FRAMEBUFFER_COMPLETE &&
      glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
  if (ok) {
    if (scissor) {
      glDisable(GL_SCISSOR_TEST);
    }
    glBlitFramebuffer(0, 0, cw, ch, 0, 0, w, h, GL_COLOR_BUFFER_BIT,
                      GL_NEAREST);
    if (scissor) {
      glEnable(GL_SCISSOR_TEST);
    }
  }
  // The embedder deletes its texture after the draw; do not keep it attached.
  glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                         GL_TEXTURE_2D, 0, 0);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, prev_read);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prev_draw);
  glBindTexture(GL_TEXTURE_2D, bound_tex);
  return ok;
}

void hook_read_pixels(GLint x, GLint y, GLsizei w, GLsizei h, GLenum format,
                      GLenum type, void* pixels) {
  // The compositor's whole-frame readback: off the GTK thread, from the
  // origin, RGBA bytes. (Impeller/Skia resolve GL themselves and never come
  // through epoxy; GDK's own software fallback reads on the GTK thread.)
  if (x != 0 || y != 0 || format != GL_RGBA || type != GL_UNSIGNED_BYTE ||
      pixels == nullptr || w < 16 || h < 16 || on_gtk_thread()) {
    real_read_pixels(x, y, w, h, format, type, pixels);
    return;
  }

  // glReadPixels waits for the frame's rendering before it can copy;
  // finishing first splits that wait from the copy in the stats.
  gint64 t0 = g_get_monotonic_time();
  glFinish();
  gint64 t1 = g_get_monotonic_time();

  gint cw = w, ch = h;
  gboolean scaled = FALSE;
  if (g_downscale > 1) {
    gint sw = MAX(w / g_downscale, 1), sh = MAX(h / g_downscale, 1);
    if (read_downscaled(w, h, sw, sh, pixels)) {
      cw = sw;
      ch = sh;
      scaled = TRUE;
    }
  }
  if (!scaled) {
    real_read_pixels(x, y, w, h, format, type, pixels);
  }
  gint64 t2 = g_get_monotonic_time();

  g_mutex_lock(&g_frame_mutex);
  g_frame_ptr = pixels;
  g_frame_w = w;
  g_frame_h = h;
  g_copy_w = cw;
  g_copy_h = ch;
  g_mutex_unlock(&g_frame_mutex);

  add(&g_readback_count, 1);
  add(&g_wait_us, t1 - t0);
  add(&g_copy_us, t2 - t1);
  if (scaled) {
    add(&g_scaled_count, 1);
  }
}

void hook_tex_image_2d(GLenum target, GLint level, GLint internalformat,
                       GLsizei w, GLsizei h, GLint border, GLenum format,
                       GLenum type, const void* pixels) {
  if (target == GL_TEXTURE_2D && level == 0 && pixels != nullptr &&
      format == GL_RGBA && type == GL_UNSIGNED_BYTE) {
    g_mutex_lock(&g_frame_mutex);
    gboolean is_frame = pixels == g_frame_ptr && w == g_frame_w &&
                        h == g_frame_h;
    gint cw = g_copy_w, ch = g_copy_h;
    g_mutex_unlock(&g_frame_mutex);
    if (is_frame) {
      // The embedder uploading the frame for GDK to draw. The buffer holds
      // |cw|×|ch| pixels (smaller than the frame under the downscale knob).
      GLint ifmt = internalformat;
      gboolean opaque = FALSE;
      if (g_opaque && epoxy_is_desktop_gl()) {
        // No alpha bits → GDK takes its "non-alpha texture" branch and
        // neither uploads its own window surface underneath nor blends.
        ifmt = GL_RGB;
        opaque = TRUE;
      }
      gint64 t0 = g_get_monotonic_time();
      if (cw == w && ch == h) {
        real_tex_image_2d(target, level, ifmt, w, h, border, format, type,
                          pixels);
      } else if (!upload_upscaled(ifmt, w, h, cw, ch, pixels)) {
        // Cannot stretch on this driver: stop shrinking readbacks. This one
        // frame goes up as it is (small, so GDK tiles it).
        g_scale_broken = TRUE;
        g_printerr("watchit: present downscale off (upscale incomplete)\n");
        real_tex_image_2d(target, level, ifmt, cw, ch, border, format, type,
                          pixels);
      }
      gint64 t1 = g_get_monotonic_time();
      add(&g_upload_count, 1);
      add(&g_upload_us, t1 - t0);
      if (opaque) {
        add(&g_opaque_count, 1);
      }
      return;
    }
  }
  real_tex_image_2d(target, level, internalformat, w, h, border, format, type,
                    pixels);
}

gboolean env_off(const gchar* name) {
  const gchar* v = g_getenv(name);
  return v != nullptr && (g_strcmp0(v, "0") == 0 ||
                          g_ascii_strcasecmp(v, "false") == 0 ||
                          g_ascii_strcasecmp(v, "off") == 0);
}

}  // namespace

void present_hooks_install(void) {
  static gsize once = 0;
  if (!g_once_init_enter(&once)) {
    return;
  }
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr || !GDK_IS_X11_DISPLAY(display)) {
    // Only X11 takes the CPU round trip this instruments.
    g_once_init_leave(&once, 1);
    return;
  }
  if (env_off("WATCHIT_PRESENT_HOOKS")) {
    g_printerr("watchit: present hooks off (WATCHIT_PRESENT_HOOKS)\n");
    g_once_init_leave(&once, 1);
    return;
  }
  const gchar* scale = g_getenv("WATCHIT_PRESENT_DOWNSCALE");
  if (scale != nullptr) {
    g_downscale = CLAMP(atoi(scale), 1, 4);
  }
  // On by default: measured on the Mint box at 3840×2016 it is the whole
  // judder (GTK thread ~80 ms per painted frame with GDK's alpha branch,
  // ~9 ms without), and the picture is identical.
  g_opaque = !env_off("WATCHIT_PRESENT_OPAQUE");

  g_mutex_lock(&g_resolve_mutex);
  g_orig_read = epoxy_glReadPixels;
  g_orig_tex = epoxy_glTexImage2D;
  epoxy_glReadPixels = hook_read_pixels;
  epoxy_glTexImage2D = hook_tex_image_2d;
  g_installed = TRUE;
  g_mutex_unlock(&g_resolve_mutex);
  g_printerr("watchit: present hooks on · downscale %d · opaque %d\n",
             g_downscale, g_opaque ? 1 : 0);
  g_once_init_leave(&once, 1);
}

void present_hooks_get_stats(PresentHookStats* out) {
  out->installed = g_installed;
  out->downscale = g_downscale;
  out->opaque = g_opaque;
  out->readback_count = get(&g_readback_count);
  out->wait_us_total = get(&g_wait_us);
  out->copy_us_total = get(&g_copy_us);
  out->upload_count = get(&g_upload_count);
  out->upload_us_total = get(&g_upload_us);
  out->scaled_count = get(&g_scaled_count);
  out->opaque_count = get(&g_opaque_count);
  g_mutex_lock(&g_frame_mutex);
  out->frame_width = g_frame_w;
  out->frame_height = g_frame_h;
  out->copy_width = g_copy_w;
  out->copy_height = g_copy_h;
  g_mutex_unlock(&g_frame_mutex);
}
