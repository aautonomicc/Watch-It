// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "include/media_kit_video/video_output.h"
#include "include/media_kit_video/texture_gl.h"
#include "include/media_kit_video/texture_sw.h"

#include <epoxy/egl.h>
#include <epoxy/glx.h>
#include <gdk/gdkwayland.h>
#include <gdk/gdkx.h>

struct _VideoOutput {
  GObject parent_instance;
  TextureGL* texture_gl;
  EGLDisplay egl_display; /* EGL display for mpv rendering (shared with flutter). */
  EGLContext egl_context; /* Isolated EGL context (non-shared). */
  EGLSurface egl_surface; /* Place holder surface for activating egl context */
  guint8* pixel_buffer;
  TextureSW* texture_sw;
  GMutex mutex; /* Only used in S/W rendering. */
  mpv_handle* handle;
  mpv_render_context* render_context;
  gint64 width;
  gint64 height;
  VideoOutputConfiguration configuration;
  TextureUpdateCallback texture_update_callback;
  gpointer texture_update_callback_context;
  FlTextureRegistrar* texture_registrar;
  gboolean destroyed;
  int block_for_target_time; /* W@tch pacing knob, see header. */
  /* W@tch render-pipeline counters (see video_output.h). Updated from the
   * mpv thread (update_count), Flutter's raster thread (populate/render)
   * and the GTK thread (ticks/draws) — plain 64-bit atomics. */
  gint64 stat_update_count;
  gint64 stat_populate_count;
  gint64 stat_render_us_total;
  gint64 stat_render_us_max;
  gint64 stat_populate_us_total;
  gint64 stat_populate_us_max;
  gint64 stat_gtk_tick_count;
  gint64 stat_gtk_draw_count;
  gint64 stat_gdk_refresh_us;
  gchar* gl_vendor;
  gchar* gl_renderer;
  gchar* gl_version;
  gchar* egl_vendor;
  gchar* egl_version;
  FlView* view;            /* observed for GTK ticks/draws; not owned */
  guint tick_callback_id;  /* gtk_widget_add_tick_callback, 0 = none */
  gulong draw_handler_id;  /* "draw" signal on the view, 0 = none */
  gboolean update_via_main; /* WATCHIT_MPV_UPDATE_VIA_MAIN=1 */
  gint update_pending;      /* coalesces main-thread update posts */
  gboolean sw_forced;       /* WATCHIT_MPV_SW_RENDER=1 */
};

static inline void stat_add(gint64* slot, gint64 v) {
  __atomic_fetch_add(slot, v, __ATOMIC_RELAXED);
}
static inline void stat_max(gint64* slot, gint64 v) {
  gint64 cur = __atomic_load_n(slot, __ATOMIC_RELAXED);
  while (v > cur &&
         !__atomic_compare_exchange_n(slot, &cur, v, TRUE, __ATOMIC_RELAXED,
                                      __ATOMIC_RELAXED)) {
  }
}
static inline gint64 stat_get(gint64* slot) {
  return __atomic_load_n(slot, __ATOMIC_RELAXED);
}

void video_output_note_populate(VideoOutput* self,
                                gint64 render_us,
                                gint64 populate_us) {
  stat_add(&self->stat_populate_count, 1);
  stat_add(&self->stat_render_us_total, render_us);
  stat_max(&self->stat_render_us_max, render_us);
  stat_add(&self->stat_populate_us_total, populate_us);
  stat_max(&self->stat_populate_us_max, populate_us);
}

// GdkFrameClock tick on the FlView: GTK's own frame cadence. Under a
// compositor GDK freezes this clock until _NET_WM_FRAME_DRAWN comes back,
// so a low tick rate here means the compositor is pacing the window.
static gboolean video_output_tick_cb(GtkWidget* widget,
                                     GdkFrameClock* clock,
                                     gpointer data) {
  VideoOutput* self = (VideoOutput*)data;
  if (self->destroyed) {
    return G_SOURCE_REMOVE;
  }
  stat_add(&self->stat_gtk_tick_count, 1);
  gint64 refresh = 0;
  gdk_frame_clock_get_refresh_info(clock, gdk_frame_clock_get_frame_time(clock),
                                   &refresh, NULL);
  if (refresh > 0) {
    __atomic_store_n(&self->stat_gdk_refresh_us, refresh, __ATOMIC_RELAXED);
  }
  return G_SOURCE_CONTINUE;
}

// FlView "draw": GTK painting the window (the embedder blits Flutter's
// framebuffer inside this). Counts paints; never consumes the signal.
static gboolean video_output_draw_cb(GtkWidget* widget,
                                     cairo_t* cr,
                                     gpointer data) {
  VideoOutput* self = (VideoOutput*)data;
  if (!self->destroyed) {
    stat_add(&self->stat_gtk_draw_count, 1);
  }
  return FALSE;
}

static void video_output_observe_view(VideoOutput* self, FlView* view) {
  if (view == NULL || !GTK_IS_WIDGET(view)) {
    return;
  }
  self->view = view;
  self->tick_callback_id = gtk_widget_add_tick_callback(
      GTK_WIDGET(view), video_output_tick_cb, self, NULL);
  self->draw_handler_id = g_signal_connect(
      view, "draw", G_CALLBACK(video_output_draw_cb), self);
}

static void video_output_unobserve_view(VideoOutput* self) {
  if (self->view != NULL && GTK_IS_WIDGET(self->view)) {
    if (self->tick_callback_id != 0) {
      gtk_widget_remove_tick_callback(GTK_WIDGET(self->view),
                                      self->tick_callback_id);
    }
    if (self->draw_handler_id != 0) {
      g_signal_handler_disconnect(self->view, self->draw_handler_id);
    }
  }
  self->tick_callback_id = 0;
  self->draw_handler_id = 0;
  self->view = NULL;
}

void video_output_get_render_stats(VideoOutput* self,
                                   VideoOutputRenderStats* out) {
  out->update_count = stat_get(&self->stat_update_count);
  out->populate_count = stat_get(&self->stat_populate_count);
  out->render_us_total = stat_get(&self->stat_render_us_total);
  out->render_us_max = stat_get(&self->stat_render_us_max);
  out->populate_us_total = stat_get(&self->stat_populate_us_total);
  out->populate_us_max = stat_get(&self->stat_populate_us_max);
  out->gtk_tick_count = stat_get(&self->stat_gtk_tick_count);
  out->gtk_draw_count = stat_get(&self->stat_gtk_draw_count);
  out->gdk_refresh_us = stat_get(&self->stat_gdk_refresh_us);
  GdkDisplay* display = gdk_display_get_default();
  GdkScreen* screen = gdk_screen_get_default();
  out->composited = screen != NULL && gdk_screen_is_composited(screen);
  out->scale_factor =
      (self->view != NULL && GTK_IS_WIDGET(self->view))
          ? gtk_widget_get_scale_factor(GTK_WIDGET(self->view))
          : 0;
  out->backend = GDK_IS_WAYLAND_DISPLAY(display) ? "wayland"
                 : GDK_IS_X11_DISPLAY(display)   ? "x11"
                                                 : "other";
  out->gl_vendor = self->gl_vendor;
  out->gl_renderer = self->gl_renderer;
  out->gl_version = self->gl_version;
  out->egl_vendor = self->egl_vendor;
  out->egl_version = self->egl_version;
  out->update_via_main = self->update_via_main;
  out->sw_forced = self->sw_forced;
}

G_DEFINE_TYPE(VideoOutput, video_output, G_TYPE_OBJECT)

static void video_output_release_foreign_gl_binding();

static void video_output_dispose(GObject* object) {
  VideoOutput* self = VIDEO_OUTPUT(object);
  self->destroyed = TRUE;
  
  // Make sure that no more callbacks are invoked from mpv.
  if (self->render_context) {
    mpv_render_context_set_update_callback(self->render_context, NULL, NULL);
  }
  video_output_unobserve_view(self);
  g_clear_pointer(&self->gl_vendor, g_free);
  g_clear_pointer(&self->gl_renderer, g_free);
  g_clear_pointer(&self->gl_version, g_free);
  g_clear_pointer(&self->egl_vendor, g_free);
  g_clear_pointer(&self->egl_version, g_free);

  // H/W
  if (self->texture_gl) {
    fl_texture_registrar_unregister_texture(self->texture_registrar,
                                            FL_TEXTURE(self->texture_gl));

    // GDK's GLX binding would make the eglMakeCurrent below fail silently
    // and mpv_render_context_free would run without our context current.
    video_output_release_foreign_gl_binding();
    // Save Flutter's current context before cleanup
    EGLDisplay current_display = eglGetCurrentDisplay();
    EGLContext flutter_context = eglGetCurrentContext();
    EGLSurface flutter_draw_surface = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface flutter_read_surface = eglGetCurrentSurface(EGL_READ);
    
    // Free mpv_render_context with our own isolated EGL context
    if (self->render_context != NULL) {
      if (self->egl_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, self->egl_context);
      }
      mpv_render_context_free(self->render_context);
      self->render_context = NULL;
      
      // Restore Flutter's context (or release ours if nothing was current —
      // the platform thread normally has no EGL context bound)
      if (flutter_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(current_display, flutter_draw_surface, flutter_read_surface, flutter_context);
      } else if (self->egl_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      }
    }
    
    // Clean up EGL resources
    if (self->egl_context != EGL_NO_CONTEXT) {
      eglDestroyContext(self->egl_display, self->egl_context);
      self->egl_context = EGL_NO_CONTEXT;
    }
    
    g_object_unref(self->texture_gl);
  }
  // S/W
  if (self->texture_sw) {
    fl_texture_registrar_unregister_texture(self->texture_registrar,
                                            FL_TEXTURE(self->texture_sw));
    g_free(self->pixel_buffer);
    g_object_unref(self->texture_sw);
    if (self->render_context != NULL) {
      mpv_render_context_free(self->render_context);
      self->render_context = NULL;
    }
  }
  
  g_mutex_clear(&self->mutex);
  G_OBJECT_CLASS(video_output_parent_class)->dispose(object);
}

static void video_output_class_init(VideoOutputClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = video_output_dispose;
}

static void video_output_init(VideoOutput* self) {
  self->texture_gl = NULL;
  self->egl_display = EGL_NO_DISPLAY;
  self->egl_context = EGL_NO_CONTEXT;
  self->egl_surface = EGL_NO_SURFACE;
  self->texture_sw = NULL;
  self->pixel_buffer = NULL;
  self->handle = NULL;
  self->render_context = NULL;
  self->width = 0;
  self->height = 0;
  self->configuration = VideoOutputConfiguration{};
  self->texture_update_callback = NULL;
  self->texture_update_callback_context = NULL;
  self->texture_registrar = NULL;
  self->destroyed = FALSE;
  self->stat_update_count = 0;
  self->stat_populate_count = 0;
  self->stat_render_us_total = 0;
  self->stat_render_us_max = 0;
  self->stat_populate_us_total = 0;
  self->stat_populate_us_max = 0;
  self->stat_gtk_tick_count = 0;
  self->stat_gtk_draw_count = 0;
  self->stat_gdk_refresh_us = 0;
  self->gl_vendor = NULL;
  self->gl_renderer = NULL;
  self->gl_version = NULL;
  self->egl_vendor = NULL;
  self->egl_version = NULL;
  self->view = NULL;
  self->tick_callback_id = 0;
  self->draw_handler_id = 0;
  self->update_via_main = FALSE;
  self->update_pending = 0;
  self->sw_forced = FALSE;
  g_mutex_init(&self->mutex);
}

// WATCH-IT PATCH (media-kit/media-kit#1404): since Flutter 3.38 no EGL
// context is current on the platform thread, so upstream's
// eglGetCurrentDisplay() returned EGL_NO_DISPLAY and every Linux box silently
// fell back to CPU mpv rendering. Flutter's context is not actually needed —
// the mpv render context lives in an isolated (unshared) EGL context — but
// Flutter's DISPLAY is: the EGLImage that shares mpv's frames with Flutter's
// raster context is display-scoped. Derive that display the same way the
// embedder itself does (fl_opengl_manager.cc): eglGetPlatformDisplayEXT on
// the default GDK display returns the identical EGLDisplay handle for the
// same (platform, native display) pair. Init stays eager on the platform
// thread, like upstream: deferring it to the first FlTextureGL populate
// deadlocks, because the Video widget only mounts the Texture once mpv
// reports video dimensions, which mpv cannot do before the render context
// exists.
static EGLDisplay video_output_get_flutter_egl_display() {
  EGLDisplay display = eglGetCurrentDisplay();
  if (display != EGL_NO_DISPLAY) {
    // Pre-3.38 embedders: Flutter's context is current right here.
    return display;
  }
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
    return eglGetPlatformDisplayEXT(
        EGL_PLATFORM_WAYLAND_EXT,
        gdk_wayland_display_get_wl_display(gdk_display), NULL);
  }
  if (GDK_IS_X11_DISPLAY(gdk_display)) {
    return eglGetPlatformDisplayEXT(
        EGL_PLATFORM_X11_EXT, gdk_x11_display_get_xdisplay(gdk_display), NULL);
  }
  return EGL_NO_DISPLAY;
}

// The platform thread may hold a GL binding EGL cannot see: FlView presents
// through a GDK GL context, which on X11 is GLX, and GDK leaves it current
// after painting. eglGetCurrentContext() returns EGL_NO_CONTEXT then, but
// Mesa refuses to bind an EGL context on a thread that already holds a GLX
// binding — eglMakeCurrent fails with EGL_BAD_ACCESS (0x3002) and we'd fall
// back to S/W rendering (the Mint alpha.19 report; xvfb never hit it because
// GDK-GL is unavailable without DRI3). Release GDK's binding first; GDK
// re-binds lazily on its next paint, so this is safe outside a paint cycle.
static void video_output_release_foreign_gl_binding() {
  if (eglGetCurrentContext() == EGL_NO_CONTEXT &&
      gdk_gl_context_get_current() != NULL) {
    gdk_gl_context_clear_current();
  }
}

static gboolean video_output_init_hw(VideoOutput* self) {
  gboolean success = FALSE;
  video_output_release_foreign_gl_binding();
  // Save the caller's EGL binding: Flutter's context on pre-3.38 embedders,
  // nothing (EGL_NO_CONTEXT) on the platform thread since 3.38.
  EGLDisplay prev_display = eglGetCurrentDisplay();
  EGLContext prev_context = eglGetCurrentContext();
  EGLSurface prev_draw = eglGetCurrentSurface(EGL_DRAW);
  EGLSurface prev_read = eglGetCurrentSurface(EGL_READ);

  self->egl_display = video_output_get_flutter_egl_display();
  if (self->egl_display == EGL_NO_DISPLAY) {
    g_printerr("media_kit: VideoOutput: Could not obtain the EGL display.\n");
    return FALSE;
  }
  // No-op when Flutter already initialized this display (it did, unless the
  // embedder is running its software renderer).
  eglInitialize(self->egl_display, NULL, NULL);

  // Bind OpenGL ES API (Flutter uses OpenGL ES on Linux)
  eglBindAPI(EGL_OPENGL_ES_API);

  // Reuse Flutter's EGL config when its context is current (pre-3.38); fall
  // back to a plain GLES2 RGBA8888 config.
  EGLConfig config = NULL;
  EGLint config_id = 0;
  EGLint num_configs = 0;
  if (prev_context != EGL_NO_CONTEXT &&
      eglQueryContext(self->egl_display, prev_context, EGL_CONFIG_ID,
                      &config_id)) {
    EGLint config_attribs[] = {EGL_CONFIG_ID, config_id, EGL_NONE};
    if (!(eglChooseConfig(self->egl_display, config_attribs, &config, 1,
                          &num_configs) &&
          num_configs > 0)) {
      config = NULL;
    }
  }
  if (config == NULL) {
    EGLint config_attribs[] = {
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE,        8,
        EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,
        EGL_ALPHA_SIZE,      8,
        EGL_NONE,
    };
    if (!(eglChooseConfig(self->egl_display, config_attribs, &config, 1,
                          &num_configs) &&
          num_configs > 0)) {
      config = NULL;
    }
  }

  if (config != NULL) {
    // Create an isolated EGL context (NOT shared with Flutter)
    // This prevents OpenGL state pollution and resource contention
    EGLint context_attribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE,
    };

    self->egl_context = eglCreateContext(self->egl_display, config,
                                         EGL_NO_CONTEXT, context_attribs);

    if (self->egl_context != EGL_NO_CONTEXT) {
      // Make our isolated context current for initialization (surfaceless)
      if (eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                         self->egl_context)) {
        // W@tch: record which driver this display really runs on. The
        // isolated context shares Flutter's EGLDisplay, so these name the
        // GL stack Flutter composites with too (NVIDIA / Mesa / llvmpipe).
        const char* gl_vendor = (const char*)glGetString(GL_VENDOR);
        const char* gl_renderer = (const char*)glGetString(GL_RENDERER);
        const char* gl_version = (const char*)glGetString(GL_VERSION);
        self->gl_vendor = gl_vendor ? g_strdup(gl_vendor) : NULL;
        self->gl_renderer = gl_renderer ? g_strdup(gl_renderer) : NULL;
        self->gl_version = gl_version ? g_strdup(gl_version) : NULL;
        const char* egl_vendor = eglQueryString(self->egl_display, EGL_VENDOR);
        const char* egl_version =
            eglQueryString(self->egl_display, EGL_VERSION);
        self->egl_vendor = egl_vendor ? g_strdup(egl_vendor) : NULL;
        self->egl_version = egl_version ? g_strdup(egl_version) : NULL;
        g_print("media_kit: VideoOutput: GL %s | %s | %s; EGL %s %s\n",
                gl_vendor ? gl_vendor : "?", gl_renderer ? gl_renderer : "?",
                gl_version ? gl_version : "?", egl_vendor ? egl_vendor : "?",
                egl_version ? egl_version : "?");
        // Initialize mpv with our isolated EGL context
        mpv_opengl_init_params gl_init_params{
            [](auto, auto name) { return (void*)eglGetProcAddress(name); },
            NULL,
        };

        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_OPENGL},
            {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, (void*)&gl_init_params},
            {MPV_RENDER_PARAM_INVALID, (void*)0},
            {MPV_RENDER_PARAM_INVALID, (void*)0},
        };

        // VAAPI acceleration requires passing X11/Wayland display
        GdkDisplay* display = gdk_display_get_default();
        if (GDK_IS_WAYLAND_DISPLAY(display)) {
          params[2].type = MPV_RENDER_PARAM_WL_DISPLAY;
          params[2].data = gdk_wayland_display_get_wl_display(display);
        } else if (GDK_IS_X11_DISPLAY(display)) {
          params[2].type = MPV_RENDER_PARAM_X11_DISPLAY;
          params[2].data = gdk_x11_display_get_xdisplay(display);
        }

        if (mpv_render_context_create(&self->render_context, self->handle,
                                      params) == 0) {
          mpv_render_context_set_update_callback(
              self->render_context,
              [](void* data) {
                VideoOutput* self = (VideoOutput*)data;
                if (self->destroyed) {
                  return;
                }
                stat_add(&self->stat_update_count, 1);
                if (self->update_via_main) {
                  // A/B knob: the embedder API documents
                  // MarkExternalTextureFrameAvailable as a platform-thread
                  // call; upstream media_kit calls it straight from mpv's
                  // thread. Route through the GTK main loop (coalesced).
                  if (g_atomic_int_compare_and_exchange(&self->update_pending,
                                                        0, 1)) {
                    gdk_threads_add_idle_full(
                        G_PRIORITY_HIGH,
                        [](gpointer data) -> gboolean {
                          VideoOutput* self = (VideoOutput*)data;
                          g_atomic_int_set(&self->update_pending, 0);
                          if (!self->destroyed && self->texture_gl != NULL) {
                            fl_texture_registrar_mark_texture_frame_available(
                                self->texture_registrar,
                                FL_TEXTURE(self->texture_gl));
                          }
                          return G_SOURCE_REMOVE;
                        },
                        self, NULL);
                  }
                  return;
                }
                fl_texture_registrar_mark_texture_frame_available(
                    self->texture_registrar, FL_TEXTURE(self->texture_gl));
              },
              self);
          success = TRUE;
          g_print(
              "media_kit: VideoOutput: H/W rendering with isolated EGL "
              "context.\n");
        } else {
          g_printerr(
              "media_kit: VideoOutput: Failed to create "
              "mpv_render_context.\n");
        }
      } else {
        g_printerr(
            "media_kit: VideoOutput: Failed to make isolated EGL context "
            "current. Error: 0x%x\n",
            eglGetError());
      }
      // Restore the caller's EGL binding. When nothing was bound (the
      // platform thread on Flutter >= 3.38), RELEASE our context instead —
      // eglMakeCurrent(EGL_NO_DISPLAY, ...) is an error and would leave the
      // isolated context current on this thread, making every later
      // eglMakeCurrent from the raster thread fail with EGL_BAD_ACCESS.
      if (prev_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(prev_display, prev_draw, prev_read, prev_context);
      } else {
        eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                       EGL_NO_CONTEXT);
      }
      if (!success) {
        eglDestroyContext(self->egl_display, self->egl_context);
        self->egl_context = EGL_NO_CONTEXT;
      }
    } else {
      g_printerr(
          "media_kit: VideoOutput: Failed to create isolated EGL context. "
          "Error: 0x%x\n",
          eglGetError());
    }
  } else {
    g_printerr("media_kit: VideoOutput: Could not obtain an EGL config.\n");
  }

  if (!success) {
    self->egl_display = EGL_NO_DISPLAY;
  }
  return success;
}

VideoOutput* video_output_new(FlTextureRegistrar* texture_registrar,
                              FlView* view,
                              gint64 handle,
                              VideoOutputConfiguration configuration) {
  VideoOutput* self = VIDEO_OUTPUT(g_object_new(video_output_get_type(), NULL));
  self->texture_registrar = texture_registrar;
  self->handle = (mpv_handle*)handle;
  self->width = configuration.width;
  self->height = configuration.height;
  self->configuration = configuration;
#ifndef MPV_RENDER_API_TYPE_SW
  // MPV_RENDER_API_TYPE_SW must be available for S/W rendering.
  if (!self->configuration.enable_hardware_acceleration) {
    g_printerr("media_kit: VideoOutput: S/W rendering is not supported.\n");
  }
  self->configuration.enable_hardware_acceleration = TRUE;
#endif
  // W@tch frame-pacing knobs (2026-11-08). Defaults are the shipped
  // behaviour; the WATCHIT_MPV_* environment variables let a tester A/B
  // the pacing on their own machine without a new build:
  //   WATCHIT_MPV_VIDEO_SYNC            mpv `video-sync` (default "audio")
  //   WATCHIT_MPV_TIMING_OFFSET         mpv `video-timing-offset` seconds
  //                                     (default "0.025", stock mpv 0.05)
  //   WATCHIT_MPV_BLOCK_FOR_TARGET_TIME 1 = stock blocking render call
  //                                     (default 0 = non-blocking)
  const gchar* video_sync = g_getenv("WATCHIT_MPV_VIDEO_SYNC");
  mpv_set_option_string(self->handle, "video-sync",
                        (video_sync && *video_sync) ? video_sync : "audio");
  // Causes frame drops with `pulse` audio output. (SlotSun/dart_simple_live#42)
  // mpv_set_option_string(self->handle, "video-timing-offset", "0");
  //
  // W@tch (2026-11-08): the render calls below pass
  // MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME=0, so a frame is composited at
  // Flutter's next vsync after mpv signals it instead of mpv blocking the
  // raster thread until the target time. mpv signals a frame
  // `video-timing-offset` early; Flutter then needs one vsync to pick it up
  // and one more to scan it out (≈17–33 ms on a 60 Hz display), so an offset
  // of ~25 ms lands the frame centred on its target (±8 ms) with zero
  // blocking. The stock 50 ms would show video ~25 ms early.
  const gchar* timing_offset = g_getenv("WATCHIT_MPV_TIMING_OFFSET");
  mpv_set_option_string(
      self->handle, "video-timing-offset",
      (timing_offset && *timing_offset) ? timing_offset : "0.025");
  const gchar* block = g_getenv("WATCHIT_MPV_BLOCK_FOR_TARGET_TIME");
  self->block_for_target_time = (block && g_strcmp0(block, "1") == 0) ? 1 : 0;
  //   WATCHIT_MPV_UPDATE_VIA_MAIN=1  deliver mpv's new-frame signal to
  //                                  Flutter from the GTK main thread
  //                                  (coalesced) instead of mpv's thread
  //   WATCHIT_MPV_SW_RENDER=1        skip the GL texture path: mpv renders
  //                                  to a pixel buffer on the GTK thread
  //                                  (the S/W fallback) — isolates the
  //                                  EGL-texture path in an A/B
  const gchar* via_main = g_getenv("WATCHIT_MPV_UPDATE_VIA_MAIN");
  self->update_via_main = via_main && g_strcmp0(via_main, "1") == 0;
  const gchar* sw_render = g_getenv("WATCHIT_MPV_SW_RENDER");
  self->sw_forced = sw_render && g_strcmp0(sw_render, "1") == 0;
  if (self->sw_forced) {
    self->configuration.enable_hardware_acceleration = FALSE;
  }
  g_print("media_kit: VideoOutput: pacing video-sync=%s timing-offset=%s "
          "block-for-target-time=%d update-via-main=%d sw-render=%d\n",
          (video_sync && *video_sync) ? video_sync : "audio",
          (timing_offset && *timing_offset) ? timing_offset : "0.025",
          self->block_for_target_time, self->update_via_main,
          self->sw_forced);
  video_output_observe_view(self, view);
  gboolean hardware_acceleration_supported = FALSE;
  if (self->configuration.enable_hardware_acceleration) {
    self->texture_gl = texture_gl_new(self);
    if (fl_texture_registrar_register_texture(texture_registrar,
                                              FL_TEXTURE(self->texture_gl))) {
      if (video_output_init_hw(self)) {
        hardware_acceleration_supported = TRUE;
      } else {
        fl_texture_registrar_unregister_texture(texture_registrar,
                                                FL_TEXTURE(self->texture_gl));
        g_object_unref(self->texture_gl);
        self->texture_gl = NULL;
      }
    } else {
      g_printerr("media_kit: VideoOutput: Failed to register texture.\n");
      g_object_unref(self->texture_gl);
      self->texture_gl = NULL;
    }
  }
#ifdef MPV_RENDER_API_TYPE_SW
  if (!hardware_acceleration_supported) {
    g_printerr("media_kit: VideoOutput: S/W rendering.\n");
    // H/W rendering failed. Fallback to S/W rendering.
    self->pixel_buffer = g_new0(guint8, SW_RENDERING_PIXEL_BUFFER_SIZE);
    self->texture_gl = NULL;
    self->texture_sw = texture_sw_new(self);
    if (fl_texture_registrar_register_texture(texture_registrar,
                                              FL_TEXTURE(self->texture_sw))) {
      mpv_render_param params[] = {
          {MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_SW},
          {MPV_RENDER_PARAM_INVALID, (void*)0},
      };
      if (mpv_render_context_create(&self->render_context, self->handle,
                                    params) == 0) {
        mpv_render_context_set_update_callback(
            self->render_context,
            [](void* data) {
              stat_add(&((VideoOutput*)data)->stat_update_count, 1);
              gdk_threads_add_idle(
                  [](gpointer data) -> gboolean {
                    VideoOutput* self = (VideoOutput*)data;
                    if (self->destroyed) {
                      return FALSE;
                    }
                    g_mutex_lock(&self->mutex);
                    gint64 width = video_output_get_width(self);
                    gint64 height = video_output_get_height(self);
                    if (width > 0 && height > 0) {
                      gint32 size[]{(gint32)width, (gint32)height};
                      gint32 pitch = 4 * (gint32)width;
                      // Same non-blocking render as the H/W path — this
                      // one runs on the GTK MAIN thread, where a 50 ms
                      // block per frame would also stall the UI.
                      int block_for_target_time = self->block_for_target_time;
                      mpv_render_param params[]{
                          {MPV_RENDER_PARAM_SW_SIZE, size},
                          {MPV_RENDER_PARAM_SW_FORMAT, (void*)"rgb0"},
                          {MPV_RENDER_PARAM_SW_STRIDE, &pitch},
                          {MPV_RENDER_PARAM_SW_POINTER, self->pixel_buffer},
                          {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,
                           &block_for_target_time},
                          {MPV_RENDER_PARAM_INVALID, (void*)0},
                      };
                      gint64 t0 = g_get_monotonic_time();
                      mpv_render_context_render(self->render_context, params);
                      gint64 t1 = g_get_monotonic_time();
                      fl_texture_registrar_mark_texture_frame_available(
                          self->texture_registrar,
                          FL_TEXTURE(self->texture_sw));
                      video_output_note_populate(self, t1 - t0, t1 - t0);
                    }
                    g_mutex_unlock(&self->mutex);
                    return FALSE;
                  },
                  data);
            },
            self);
      }
    }
  }
#endif
  return self;
}

gboolean video_output_get_hardware_acceleration(VideoOutput* self) {
  return self->texture_gl != NULL;
}

int video_output_get_block_for_target_time(VideoOutput* self) {
  return self->block_for_target_time;
}

void video_output_set_texture_update_callback(
    VideoOutput* self,
    TextureUpdateCallback texture_update_callback,
    gpointer texture_update_callback_context) {
  self->texture_update_callback = texture_update_callback;
  self->texture_update_callback_context = texture_update_callback_context;
  // Notify initial dimensions as (1, 1) if |width| & |height| are 0 i.e.
  // texture & video frame size is based on playing file's resolution. This
  // will make sure that `Texture` widget on Flutter's widget tree is actually
  // mounted & |fl_texture_registrar_mark_texture_frame_available| actually
  // invokes the |TextureGL| or |TextureSW| callbacks. Otherwise it will be a
  // never ending deadlock where no video frames are ever rendered.
  gint64 texture_id = video_output_get_texture_id(self);
  if (self->width == 0 || self->height == 0) {
    self->texture_update_callback(texture_id, 1, 1,
                                  self->texture_update_callback_context);
  } else {
    self->texture_update_callback(texture_id, self->width, self->height,
                                  self->texture_update_callback_context);
  }
}

void video_output_set_size(VideoOutput* self, gint64 width, gint64 height) {
  // Ideally, a mutex should be used here & |video_output_get_width| +
  // |video_output_get_height|. However, that is throwing everything into a
  // deadlock. Flutter itself seems to have some synchronization mechanism in
  // rendering & platform channels AFAIK.

  // H/W
  if (self->texture_gl) {
    self->width = width;
    self->height = height;
  }
  // S/W
  if (self->texture_sw) {
    self->width = CLAMP(width, 0, SW_RENDERING_MAX_WIDTH);
    self->height = CLAMP(height, 0, SW_RENDERING_MAX_HEIGHT);
  }
}

mpv_render_context* video_output_get_render_context(VideoOutput* self) {
  return self->render_context;
}

EGLDisplay video_output_get_egl_display(VideoOutput* self) {
  return self->egl_display;
}

EGLContext video_output_get_egl_context(VideoOutput* self) {
  return self->egl_context;
}

EGLSurface video_output_get_egl_surface(VideoOutput* self) {
  return self->egl_surface;
}

guint8* video_output_get_pixel_buffer(VideoOutput* self) {
  return self->pixel_buffer;
}

gint64 video_output_get_width(VideoOutput* self) {
  // Fixed width.
  if (self->width) {
    return self->width;
  }

  // Video resolution dependent width.
  gint64 width = 0;
  gint64 height = 0;

  mpv_node params;
  mpv_get_property(self->handle, "video-out-params", MPV_FORMAT_NODE, &params);

  int64_t dw = 0, dh = 0, rotate = 0;
  if (params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
    mpv_free_node_contents(&params);
  }

  width = rotate == 0 || rotate == 180 ? dw : dh;
  height = rotate == 0 || rotate == 180 ? dh : dw;

  if (self->texture_sw != NULL) {
    // Make sure |width| & |height| fit between |SW_RENDERING_MAX_WIDTH| &
    // |SW_RENDERING_MAX_HEIGHT| while maintaining aspect ratio.
    if (width >= SW_RENDERING_MAX_WIDTH) {
      return SW_RENDERING_MAX_WIDTH;
    }
    if (height >= SW_RENDERING_MAX_HEIGHT) {
      return width / height * SW_RENDERING_MAX_HEIGHT;
    }
  }

  return width;
}

gint64 video_output_get_height(VideoOutput* self) {
  // Fixed height.
  if (self->width) {
    return self->height;
  }

  // Video resolution dependent height.
  gint64 width = 0;
  gint64 height = 0;

  mpv_node params;
  mpv_get_property(self->handle, "video-out-params", MPV_FORMAT_NODE, &params);

  int64_t dw = 0, dh = 0, rotate = 0;
  if (params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
    mpv_free_node_contents(&params);
  }

  width = rotate == 0 || rotate == 180 ? dw : dh;
  height = rotate == 0 || rotate == 180 ? dh : dw;

  if (self->texture_sw != NULL) {
    // Make sure |width| & |height| fit between |SW_RENDERING_MAX_WIDTH| &
    // |SW_RENDERING_MAX_HEIGHT| while maintaining aspect ratio.
    if (height >= SW_RENDERING_MAX_HEIGHT) {
      return SW_RENDERING_MAX_HEIGHT;
    }
    if (width >= SW_RENDERING_MAX_WIDTH) {
      return height / width * SW_RENDERING_MAX_WIDTH;
    }
  }

  return height;
}

gint64 video_output_get_texture_id(VideoOutput* self) {
  // H/W
  if (self->texture_gl) {
    return (gint64)self->texture_gl;
  }
  // S/W
  if (self->texture_sw) {
    return (gint64)self->texture_sw;
  }
  g_assert_not_reached();
  return -1;
}

void video_output_notify_texture_update(VideoOutput* self) {
  gint64 id = video_output_get_texture_id(self);
  gint64 width = video_output_get_width(self);
  gint64 height = video_output_get_height(self);
  gpointer context = self->texture_update_callback_context;
  if (self->texture_update_callback != NULL) {
    self->texture_update_callback(id, width, height, context);
  }
}
