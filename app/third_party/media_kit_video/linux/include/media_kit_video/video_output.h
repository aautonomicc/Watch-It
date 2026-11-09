// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#ifndef VIDEO_OUTPUT_H_
#define VIDEO_OUTPUT_H_

#include <flutter_linux/flutter_linux.h>
#include <epoxy/egl.h>

#include "mpv/client.h"
#include "mpv/render.h"
#include "mpv/render_gl.h"

typedef struct _VideoOutputConfiguration {
  gint64 width;
  gint64 height;
  bool enable_hardware_acceleration;

  _VideoOutputConfiguration(gint64 width = NULL,
                            gint64 height = NULL,
                            bool enable_hardware_acceleration = true)
      : width(width),
        height(height),
        enable_hardware_acceleration(enable_hardware_acceleration) {}
} VideoOutputConfiguration;

// Callback invoked when the texture ID updates i.e. video dimensions changes.
typedef void (*TextureUpdateCallback)(gint64 id,
                                      gint64 width,
                                      gint64 height,
                                      gpointer context);

#define VIDEO_OUTPUT_TYPE (video_output_get_type())

G_DECLARE_FINAL_TYPE(VideoOutput,
                     video_output,
                     VIDEO_OUTPUT,
                     VIDEO_OUTPUT,
                     GObject)

#define VIDEO_OUTPUT(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), video_output_get_type(), VideoOutput))

/**
 * @brief Creates a new |VideoOutput| instance for given |handle|.
 *
 * @param texture_registrar |FlTextureRegistrar| reference.
 * @param handle |mpv_handle| reference casted to gint64.
 * @param width Preferred width of the video. Pass `NULL` for using texture
 * dimensions based on video's resolution.
 * @param height Preferred height of the video. Pass `NULL` for using texture
 * dimensions based on video's resolution.
 * @param enable_hardware_acceleration Whether to enable hardware acceleration.
 * @return VideoOutput*
 */
VideoOutput* video_output_new(FlTextureRegistrar* texture_registrar,
                              FlView* view,
                              gint64 handle,
                              VideoOutputConfiguration configuration);

/**
 * @brief Sets the callback invoked when the texture ID updates i.e. video
 * dimensions changes.
 *
 * @param self |VideoOutput| reference.
 * @param texture_update_callback Callback.
 * @param texture_update_callback_context Callback context.
 */
void video_output_set_texture_update_callback(
    VideoOutput* self,
    TextureUpdateCallback texture_update_callback,
    gpointer texture_update_callback_context);

/**
 * @brief W@tch: whether this output renders through the H/W path (mpv draws
 * into an OpenGL texture in an isolated EGL context) or fell back to S/W
 * rendering (mpv writes a pixel buffer that is uploaded every frame). Read
 * by the playback-stats report so a field report names the path.
 */
gboolean video_output_get_hardware_acceleration(VideoOutput* self);

/**
 * @brief W@tch: the MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME value the render
 * calls pass (0 = non-blocking, the default; 1 = stock mpv behaviour), from
 * the WATCHIT_MPV_BLOCK_FOR_TARGET_TIME environment variable — an A/B knob
 * for frame-pacing field tests.
 */
int video_output_get_block_for_target_time(VideoOutput* self);

/**
 * @brief W@tch: render-pipeline counters and host facts for the playback-
 * stats report (2026-11-08 judder triage). Every count is monotonic since
 * the output was created; the Dart side differences two snapshots to get
 * rates. Strings are owned by the |VideoOutput| (valid until it is
 * disposed) and may be NULL when unknown.
 *
 *  - update_count:    mpv render-update callbacks (mpv asking for a frame)
 *  - populate_count:  FlTextureGL populate calls (Flutter actually rendering
 *                     the texture on its raster thread)
 *  - render_us_*:     time inside mpv_render_context_render()
 *  - populate_us_*:   whole populate incl. the two eglMakeCurrent switches
 *  - gtk_tick_count:  GdkFrameClock ticks seen by the FlView (GTK's own
 *                     frame cadence — frozen while a compositor has not yet
 *                     acknowledged the previous frame)
 *  - gtk_draw_count:  FlView "draw" signals (GTK actually painting the
 *                     window, i.e. blitting Flutter's framebuffer)
 *  - gtk_paint_*:     GdkFrameClock paint phases ("before-paint" to
 *                     "after-paint": the FlView draw/blit plus GDK's GL
 *                     swap) — count and time; a long paint is the GTK
 *                     thread blocked per frame by the driver/compositor
 *  - gdk_refresh_us:  the frame clock's refresh interval, 0 when unknown
 */
typedef struct _VideoOutputRenderStats {
  gint64 update_count;
  gint64 populate_count;
  gint64 render_us_total;
  gint64 render_us_max;
  gint64 populate_us_total;
  gint64 populate_us_max;
  gint64 gtk_tick_count;
  gint64 gtk_draw_count;
  gint64 gtk_paint_count;
  gint64 gtk_paint_us_total;
  gint64 gtk_paint_us_max;
  /* The paint phase split three ways around the FlView draw: before it
   * (GDK allocating the paint surface, GTK drawing the window background),
   * the draw itself (the embedder's frame upload + GDK's blit), and after
   * it (GDK's end-of-frame compositing + GL swap). */
  gint64 gtk_pre_us_total;
  gint64 gtk_draw_us_total;
  gint64 gtk_post_us_total;
  gint64 gdk_refresh_us;
  gboolean composited;
  gint scale_factor;
  const gchar* backend;
  const gchar* gl_vendor;
  const gchar* gl_renderer;
  const gchar* gl_version;
  const gchar* egl_vendor;
  const gchar* egl_version;
  gboolean update_via_main;
  gboolean sw_forced;
} VideoOutputRenderStats;

void video_output_get_render_stats(VideoOutput* self,
                                   VideoOutputRenderStats* out);

/* W@tch: called by the texture populate paths with the time spent inside
 * mpv_render_context_render() and in the whole populate (microseconds). */
void video_output_note_populate(VideoOutput* self,
                                gint64 render_us,
                                gint64 populate_us);

/**
 * @brief Sets the required video output size. This forces |VideoOutput| to
 * resize the internal OpenGL surface / texture.
 *
 * @param texture_registrar |FlTextureRegistrar| reference.
 * @param width Preferred width of the video. Pass `NULL` for using texture
 * dimensions based on video's resolution.
 * @param height Preferred height of the video. Pass `NULL` for using texture
 * dimensions based on video's resolution.
 */
void video_output_set_size(VideoOutput* self, gint64 width, gint64 height);

mpv_render_context* video_output_get_render_context(VideoOutput* self);

GdkGLContext* video_output_get_gdk_gl_context(VideoOutput* self);

EGLDisplay video_output_get_egl_display(VideoOutput* self);

EGLContext video_output_get_egl_context(VideoOutput* self);

EGLSurface video_output_get_egl_surface(VideoOutput* self);

guint8* video_output_get_pixel_buffer(VideoOutput* self);

gint64 video_output_get_width(VideoOutput* self);

gint64 video_output_get_height(VideoOutput* self);

gint64 video_output_get_texture_id(VideoOutput* self);

void video_output_notify_texture_update(VideoOutput* self);

#endif  // VIDEO_OUTPUT_H_