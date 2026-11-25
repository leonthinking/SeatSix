#ifndef SEATSIX_MPV_H
#define SEATSIX_MPV_H
#include <stdint.h>
#include <stddef.h>
typedef struct seatsix_mpv seatsix_mpv;
int seatsix_mpv_available(void);
typedef struct { int kind; int error; } seatsix_mpv_event;
typedef struct {
    int64_t id;
    const char *type, *title, *language, *codec;
    int selected, is_default, forced, external, channels;
} seatsix_mpv_track;
typedef struct { double start; const char *title; } seatsix_mpv_chapter;
int seatsix_mpv_chapter_count(seatsix_mpv *engine);
int seatsix_mpv_chapter_at(seatsix_mpv *engine, int index, seatsix_mpv_chapter *chapter);
int seatsix_mpv_track_count(seatsix_mpv *engine);
int seatsix_mpv_track_at(seatsix_mpv *engine, int index, seatsix_mpv_track *track);
uint64_t seatsix_mpv_track_command(seatsix_mpv *engine, const char *a, const char *b, const char *c, const char *d);
int seatsix_mpv_track_command_result(seatsix_mpv *engine, uint64_t identifier, int *error);
void seatsix_mpv_abort_track_command(seatsix_mpv *engine, uint64_t identifier);
void seatsix_mpv_abort_track_commands(seatsix_mpv *engine);
int seatsix_mpv_pending_track_commands(seatsix_mpv *engine);
seatsix_mpv *seatsix_mpv_create(int *error);
int seatsix_mpv_initialize(seatsix_mpv *engine);
int seatsix_mpv_option(seatsix_mpv *engine, const char *name, const char *value);
int seatsix_mpv_command(seatsix_mpv *engine, const char *a, const char *b, const char *c, const char *d);
void seatsix_mpv_set_audio_level(seatsix_mpv *engine, double gain, int muted);
int seatsix_mpv_set_double(seatsix_mpv *engine, const char *name, double value);
int seatsix_mpv_set_flag(seatsix_mpv *engine, const char *name, int value);
int seatsix_mpv_double(seatsix_mpv *engine, const char *name, double *value);
int seatsix_mpv_flag(seatsix_mpv *engine, const char *name, int *value);
char *seatsix_mpv_string(seatsix_mpv *engine, const char *name);
void seatsix_mpv_free_string(char *value);
seatsix_mpv_event seatsix_mpv_poll(seatsix_mpv *engine);
int seatsix_mpv_render_create(seatsix_mpv *engine);
typedef void (*seatsix_mpv_callback)(void *context);
void seatsix_mpv_render_set_callback(seatsix_mpv *engine, seatsix_mpv_callback callback, void *context, seatsix_mpv_callback release_context);
uint64_t seatsix_mpv_rendered_frame_count(seatsix_mpv *engine);
int seatsix_mpv_render_update(seatsix_mpv *engine);
int seatsix_mpv_render(seatsix_mpv *engine, int framebuffer, int width, int height, int flip);
void seatsix_mpv_render_destroy(seatsix_mpv *engine);
void seatsix_mpv_destroy(seatsix_mpv *engine);
#endif
