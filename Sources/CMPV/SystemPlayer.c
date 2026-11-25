// The system-player build uses AVFoundation. Keep the Swift bridge linkable
// without importing mpv headers, loading libraries or constructing an engine.
#include "CMPV.h"

int seatsix_mpv_available(void) { return 0; }
seatsix_mpv *seatsix_mpv_create(int *error) {
    if (error) *error = -1;
    return NULL;
}
int seatsix_mpv_initialize(seatsix_mpv *engine) { return -1; }
int seatsix_mpv_option(seatsix_mpv *engine, const char *name, const char *value) { return -1; }
int seatsix_mpv_command(seatsix_mpv *engine, const char *a, const char *b, const char *c, const char *d) { return -1; }
int seatsix_mpv_set_double(seatsix_mpv *engine, const char *name, double value) { return -1; }
int seatsix_mpv_set_flag(seatsix_mpv *engine, const char *name, int value) { return -1; }
int seatsix_mpv_double(seatsix_mpv *engine, const char *name, double *value) { return -1; }
int seatsix_mpv_flag(seatsix_mpv *engine, const char *name, int *value) { return -1; }
char *seatsix_mpv_string(seatsix_mpv *engine, const char *name) { return NULL; }
void seatsix_mpv_free_string(char *value) {}
void seatsix_mpv_set_audio_level(seatsix_mpv *engine, double gain, int muted) {}
seatsix_mpv_event seatsix_mpv_poll(seatsix_mpv *engine) { return (seatsix_mpv_event){0}; }
int seatsix_mpv_chapter_count(seatsix_mpv *engine) { return 0; }
int seatsix_mpv_chapter_at(seatsix_mpv *engine, int index, seatsix_mpv_chapter *chapter) { return 0; }
int seatsix_mpv_track_count(seatsix_mpv *engine) { return 0; }
int seatsix_mpv_track_at(seatsix_mpv *engine, int index, seatsix_mpv_track *track) { return 0; }
uint64_t seatsix_mpv_track_command(seatsix_mpv *engine, const char *a, const char *b, const char *c, const char *d) { return 0; }
int seatsix_mpv_track_command_result(seatsix_mpv *engine, uint64_t identifier, int *error) { return 0; }
void seatsix_mpv_abort_track_command(seatsix_mpv *engine, uint64_t identifier) {}
void seatsix_mpv_abort_track_commands(seatsix_mpv *engine) {}
int seatsix_mpv_pending_track_commands(seatsix_mpv *engine) { return 0; }
int seatsix_mpv_render_create(seatsix_mpv *engine) { return -1; }
void seatsix_mpv_render_set_callback(seatsix_mpv *engine, seatsix_mpv_callback callback, void *context, seatsix_mpv_callback release_context) {
    if (release_context) release_context(context);
}
uint64_t seatsix_mpv_rendered_frame_count(seatsix_mpv *engine) { return 0; }
int seatsix_mpv_render_update(seatsix_mpv *engine) { return 0; }
int seatsix_mpv_render(seatsix_mpv *engine, int framebuffer, int width, int height, int flip) { return -1; }
void seatsix_mpv_render_destroy(seatsix_mpv *engine) {}
void seatsix_mpv_destroy(seatsix_mpv *engine) {}
