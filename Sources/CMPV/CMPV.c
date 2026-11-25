#include "CMPV.h"
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
int seatsix_mpv_available(void) { return 1; }
typedef struct { const char *name; mpv_format format; int valid; double number; int flag; char *string; } cached_property;
#define PROPERTY_COUNT 26
#define AUDIO_LEVEL_REPLY UINT64_MAX
#define RENDERER_MUTE_PROPERTY_ID 24
#define TRACK_PROPERTY_ID 1001
#define CHAPTER_PROPERTY_ID 1002
#define TRACK_COMMAND_SLOTS 64
typedef struct { uint64_t id; int done, error; } track_command_result;
enum level_action { LEVEL_IDLE, LEVEL_GAIN, LEVEL_RENDERER_MUTE };
typedef struct {
    int enabled, muted, renderer_mute, renderer_unavailable;
    uint64_t output_generation, sent_generation;
    double gain, applied_gain, sent_value;
    enum level_action pending;
} audio_level;

struct seatsix_mpv { audio_level level; mpv_handle *handle; mpv_render_context *render; void *render_callback_context; seatsix_mpv_callback release_render_callback; uint64_t rendered_frames; int frame_pending; uint64_t command_sequence; uint64_t stop_command; int audio_pts_pending, renderer_mute_read_pending; cached_property properties[PROPERTY_COUNT]; seatsix_mpv_track *tracks; int track_count; seatsix_mpv_chapter *chapters; int chapter_count; track_command_result track_commands[TRACK_COMMAND_SLOTS]; };
static cached_property *find_property(seatsix_mpv *e, const char *name) {
    for (int i=0;i<PROPERTY_COUNT;i++) if(e->properties[i].name && strcmp(e->properties[i].name,name)==0) return &e->properties[i];
    return NULL;
}
seatsix_mpv *seatsix_mpv_create(int *error) {
    seatsix_mpv *e = calloc(1, sizeof(*e));
    if (!e) { *error = MPV_ERROR_NOMEM; return NULL; }
    e->handle = mpv_create();
    if (!e->handle) { free(e); *error = MPV_ERROR_NOMEM; return NULL; }
    e->level.applied_gain = 100;
    *error = 0; return e;
}
int seatsix_mpv_initialize(seatsix_mpv *e) {
    int result=mpv_initialize(e->handle);
    if(result<0) return result;
    const char *names[PROPERTY_COUNT]={"time-pos","duration","pause","paused-for-cache","seeking","eof-reached","video-params/w","video-params/h","video-format","audio-codec-name","hwdec-current","audio-out-params/samplerate","audio-out-params/channel-count","audio-pts","volume","idle-active","current-ao","aid","sid","sub-text","speed","audio-pitch-correction","cache-speed","ao-mute",
                                      "video-out-params/aspect","video-out-params/rotate"};
    mpv_format formats[PROPERTY_COUNT]={MPV_FORMAT_DOUBLE,MPV_FORMAT_DOUBLE,MPV_FORMAT_FLAG,MPV_FORMAT_FLAG,MPV_FORMAT_FLAG,MPV_FORMAT_FLAG,MPV_FORMAT_DOUBLE,MPV_FORMAT_DOUBLE,MPV_FORMAT_STRING,MPV_FORMAT_STRING,MPV_FORMAT_STRING,MPV_FORMAT_DOUBLE,MPV_FORMAT_DOUBLE,MPV_FORMAT_DOUBLE,MPV_FORMAT_DOUBLE,MPV_FORMAT_FLAG,MPV_FORMAT_STRING,MPV_FORMAT_STRING,MPV_FORMAT_STRING,MPV_FORMAT_STRING,MPV_FORMAT_DOUBLE,MPV_FORMAT_FLAG,MPV_FORMAT_DOUBLE,MPV_FORMAT_FLAG,
                                        MPV_FORMAT_DOUBLE,MPV_FORMAT_DOUBLE};
    for(int i=0;i<PROPERTY_COUNT;i++) {
        e->properties[i].name=names[i]; e->properties[i].format=formats[i];
        result=mpv_observe_property(e->handle,(uint64_t)i+1,names[i],formats[i]);
        if(result<0) return result;
    }
    result = mpv_observe_property(e->handle, CHAPTER_PROPERTY_ID, "chapter-list", MPV_FORMAT_NODE);
    if (result < 0) return result;
    return mpv_observe_property(e->handle,TRACK_PROPERTY_ID,"track-list",MPV_FORMAT_NODE);
}
// AVFoundation queues already-scaled PCM ahead of playback. Its ao-mute
// controls this engine’s AVSampleBufferAudioRenderer after that queue. Other
// output drivers retain their software-volume behavior and device settings.
static void reconcile_audio_level(seatsix_mpv *e) {
    audio_level *l = &e->level;
    if (!l->enabled || l->pending != LEVEL_IDLE) return;
    cached_property *output = find_property(e, "current-ao");
    int native = !l->renderer_unavailable && output->valid && output->string &&
                 strcmp(output->string, "avfoundation") == 0;
    double gain = l->muted && !native ? 0 : l->gain;
    int mute = l->muted;
    int result;
    if (native && l->renderer_mute != mute && (mute || gain == l->applied_gain)) {
        // Close the renderer before feeding audible PCM. Restore the requested
        // gain before opening it. Only one operation is in flight since libmpv
        // may otherwise reorder asynchronous property writes.
        l->pending = LEVEL_RENDERER_MUTE;
        l->sent_value = mute;
        l->sent_generation = l->output_generation;
        result = mpv_set_property_async(e->handle, AUDIO_LEVEL_REPLY, "ao-mute", MPV_FORMAT_FLAG, &mute);
    } else if (gain != l->applied_gain) {
        l->pending = LEVEL_GAIN;
        l->sent_value = gain;
        result = mpv_set_property_async(e->handle, AUDIO_LEVEL_REPLY, "volume", MPV_FORMAT_DOUBLE, &gain);
    } else {
        return;
    }
    if (result < 0) {
        enum level_action failed = l->pending;
        l->pending = LEVEL_IDLE;
        if (failed == LEVEL_RENDERER_MUTE) {
            l->renderer_unavailable = 1;
            reconcile_audio_level(e);
        }
    }
}
void seatsix_mpv_set_audio_level(seatsix_mpv *e, double gain, int muted) {
    e->level.enabled = 1;
    // Legacy callers express mute as zero. Retain their last audible gain so
    // their buffered samples are immediately available when they unmute.
    if (gain > 0 || !muted) e->level.gain = gain;
    e->level.muted = muted;
    reconcile_audio_level(e);
}
static void audio_output_changed(seatsix_mpv *e) {
    e->level.output_generation++;
    e->level.renderer_unavailable = 0;
    // Reapply mute when a track or output creates a new sample renderer.
    e->level.renderer_mute = -1;
    reconcile_audio_level(e);
}

int seatsix_mpv_option(seatsix_mpv *e, const char *n, const char *v) { return mpv_set_option_string(e->handle, n, v); }
int seatsix_mpv_command(seatsix_mpv *e, const char *a, const char *b, const char *c, const char *d) {
    const char *args[] = {a,b,c,d,NULL};
    uint64_t identifier=++e->command_sequence;
    if(strcmp(a,"stop")==0) e->stop_command=identifier;
    return mpv_command_async(e->handle,identifier,args);
}
int seatsix_mpv_set_double(seatsix_mpv *e, const char *n, double v) {
    int r=mpv_set_property_async(e->handle,0,n,MPV_FORMAT_DOUBLE,&v);
    cached_property *p=find_property(e,n); if(r>=0 && p) { p->number=v; p->valid=1; }
    return r;
}
int seatsix_mpv_set_flag(seatsix_mpv *e, const char *n, int v) {
    int r=mpv_set_property_async(e->handle,0,n,MPV_FORMAT_FLAG,&v);
    cached_property *p=find_property(e,n); if(r>=0 && p) { p->flag=v; p->valid=1; }
    return r;
}
int seatsix_mpv_double(seatsix_mpv *e, const char *n, double *v) {
    cached_property *p=find_property(e,n);
    // audio-pts is not continuously observable on all mpv builds. Keep one
    // asynchronous read in flight so rendering never waits on the playback core.
    if(strcmp(n,"audio-pts")==0 && !e->audio_pts_pending) {
        if(mpv_get_property_async(e->handle,14,n,MPV_FORMAT_DOUBLE)>=0) e->audio_pts_pending=1;
    }
    if(!p || !p->valid) return MPV_ERROR_PROPERTY_UNAVAILABLE;
    *v=p->number; return 0;
}
int seatsix_mpv_flag(seatsix_mpv *e, const char *n, int *v) {
    cached_property *p = find_property(e, n);
    // Not all output drivers notify ao-mute observers. A requested diagnostic
    // read refreshes the cache asynchronously without blocking video rendering.
    if (strcmp(n, "ao-mute") == 0 && !e->renderer_mute_read_pending) {
        if (mpv_get_property_async(e->handle, RENDERER_MUTE_PROPERTY_ID, n, MPV_FORMAT_FLAG) >= 0)
            e->renderer_mute_read_pending = 1;
    }
    if (!p || !p->valid) return MPV_ERROR_PROPERTY_UNAVAILABLE;
    *v = p->flag;
    return 0;
}
char *seatsix_mpv_string(seatsix_mpv *e, const char *n) { cached_property *p=find_property(e,n); return p && p->valid && p->string ? strdup(p->string) : NULL; }
void seatsix_mpv_free_string(char *v) { free(v); }
static mpv_node *map_value(mpv_node *map, const char *key) {
    if(!map || map->format!=MPV_FORMAT_NODE_MAP) return NULL;
    for(int i=0;i<map->u.list->num;i++) if(strcmp(map->u.list->keys[i],key)==0) return &map->u.list->values[i];
    return NULL;
}
static char *map_string(mpv_node *map, const char *key) {
    mpv_node *n=map_value(map,key); return n && n->format==MPV_FORMAT_STRING ? strndup(n->u.string,4096) : NULL;
}
static int64_t map_int(mpv_node *map, const char *key) {
    mpv_node *n=map_value(map,key); return n && n->format==MPV_FORMAT_INT64 ? n->u.int64 : 0;
}
static int map_flag(mpv_node *map, const char *key) {
    mpv_node *n=map_value(map,key); return n && n->format==MPV_FORMAT_FLAG ? n->u.flag : 0;
}
static void clear_tracks(seatsix_mpv *e) {
    for(int i=0;i<e->track_count;i++) {
        free((void *)e->tracks[i].type); free((void *)e->tracks[i].title);
        free((void *)e->tracks[i].language); free((void *)e->tracks[i].codec);
    }
    free(e->tracks); e->tracks=NULL; e->track_count=0;
}
static void cache_tracks(seatsix_mpv *e, mpv_node *node) {
    clear_tracks(e);
    if(!node || node->format!=MPV_FORMAT_NODE_ARRAY) return;
    int count=node->u.list->num;
    if(count<1 || count>4096) return;
    e->tracks=calloc((size_t)count,sizeof(*e->tracks));
    if(!e->tracks) return;
    e->track_count=count;
    for(int i=0;i<count;i++) {
        mpv_node *n=&node->u.list->values[i]; seatsix_mpv_track *t=&e->tracks[i];
        t->id=map_int(n,"id"); t->type=map_string(n,"type"); t->title=map_string(n,"title");
        t->language=map_string(n,"lang"); t->codec=map_string(n,"codec");
        t->selected=map_flag(n,"selected"); t->is_default=map_flag(n,"default");
        t->forced=map_flag(n,"forced"); t->external=map_flag(n,"external");
        int64_t channels=map_int(n,"demux-channel-count"); t->channels=channels>0 && channels<=256 ? (int)channels : 0;
    }
}
static void clear_chapters(seatsix_mpv *e) {
    for (int i = 0; i < e->chapter_count; ++i) free((void *)e->chapters[i].title);
    free(e->chapters);
    e->chapters = NULL;
    e->chapter_count = 0;
}
static void cache_chapters(seatsix_mpv *e, mpv_node *node) {
    clear_chapters(e);
    if (!node || node->format != MPV_FORMAT_NODE_ARRAY) return;
    const int count = node->u.list->num;
    if (count <= 0 || count > 10000) return;
    e->chapters = calloc((size_t)count, sizeof(*e->chapters));
    if (!e->chapters) return;
    for (int i = 0; i < count; ++i) {
        mpv_node *item = &node->u.list->values[i];
        mpv_node *time = map_value(item, "time");
        if (!time || time->format != MPV_FORMAT_DOUBLE) continue;
        seatsix_mpv_chapter *chapter = &e->chapters[e->chapter_count++];
        chapter->start = time->u.double_;
        chapter->title = map_string(item, "title");
    }
}
int seatsix_mpv_chapter_count(seatsix_mpv *e) { return e->chapter_count; }
int seatsix_mpv_chapter_at(seatsix_mpv *e, int index, seatsix_mpv_chapter *chapter) {
    if (index < 0 || index >= e->chapter_count) return 0;
    *chapter = e->chapters[index];
    return 1;
}
int seatsix_mpv_track_count(seatsix_mpv *e) { return e->track_count; }
int seatsix_mpv_track_at(seatsix_mpv *e, int index, seatsix_mpv_track *track) {
    if(index<0 || index>=e->track_count) return 0;
    *track=e->tracks[index]; return 1;
}
uint64_t seatsix_mpv_track_command(seatsix_mpv *e, const char *a, const char *b, const char *c, const char *d) {
    uint64_t identifier=++e->command_sequence;
    track_command_result *slot=&e->track_commands[identifier%TRACK_COMMAND_SLOTS];
    *slot=(track_command_result){.id=identifier};
    const char *args[]={a,b,c,d,NULL};
    int result=mpv_command_async(e->handle,identifier,args);
    if(result<0) { slot->done=1; slot->error=result; }
    return identifier;
}
int seatsix_mpv_track_command_result(seatsix_mpv *e, uint64_t identifier, int *error) {
    track_command_result *slot=&e->track_commands[identifier%TRACK_COMMAND_SLOTS];
    if(slot->id!=identifier) { *error=MPV_ERROR_COMMAND; return 1; }
    *error=slot->error; return slot->done;
}
void seatsix_mpv_abort_track_command(seatsix_mpv *e, uint64_t identifier) {
    track_command_result *slot=&e->track_commands[identifier%TRACK_COMMAND_SLOTS];
    if(slot->id==identifier && !slot->done) mpv_abort_async_command(e->handle,identifier);
}
void seatsix_mpv_abort_track_commands(seatsix_mpv *e) {
    for(int i=0;i<TRACK_COMMAND_SLOTS;i++) {
        track_command_result *slot=&e->track_commands[i];
        if(slot->id && !slot->done) mpv_abort_async_command(e->handle,slot->id);
    }
}
int seatsix_mpv_pending_track_commands(seatsix_mpv *e) {
    int pending=0;
    for(int i=0;i<TRACK_COMMAND_SLOTS;i++) if(e->track_commands[i].id && !e->track_commands[i].done) pending++;
    return pending;
}
seatsix_mpv_event seatsix_mpv_poll(seatsix_mpv *e) {
    mpv_event *v = mpv_wait_event(e->handle,0);
    seatsix_mpv_event r = {0,0};
    switch(v->event_id) {
        case MPV_EVENT_NONE: return r;
        case MPV_EVENT_GET_PROPERTY_REPLY:
        case MPV_EVENT_PROPERTY_CHANGE: {
            if(v->event_id==MPV_EVENT_GET_PROPERTY_REPLY && v->reply_userdata==14) e->audio_pts_pending=0;
            if(v->event_id==MPV_EVENT_GET_PROPERTY_REPLY && v->reply_userdata==RENDERER_MUTE_PROPERTY_ID) e->renderer_mute_read_pending=0;
            mpv_event_property *property=v->data;
            if(!property) { r.kind=7; break; }
            if (v->reply_userdata == CHAPTER_PROPERTY_ID) {
                cache_chapters(e, property->format == MPV_FORMAT_NODE ? property->data : NULL);
                r.kind = 9; break;
            }
            if(v->reply_userdata==TRACK_PROPERTY_ID) {
                cache_tracks(e,property->format==MPV_FORMAT_NODE ? property->data : NULL);
                r.kind=7; break;
            }
            if(v->reply_userdata>0 && v->reply_userdata<=PROPERTY_COUNT) {
                cached_property *p=&e->properties[v->reply_userdata-1];
                p->valid=property->data && property->format==p->format;
                if(p->valid) {
                    if(p->format==MPV_FORMAT_DOUBLE) p->number=*(double *)property->data;
                    if(p->format==MPV_FORMAT_FLAG) p->flag=*(int *)property->data;
                    if(p->format==MPV_FORMAT_STRING) { free(p->string); p->string=strdup(*(char **)property->data); }
                }
            }
            if (property->name && strcmp(property->name, "current-ao") == 0)
                audio_output_changed(e);
            r.kind=7; break;
        }
        case MPV_EVENT_AUDIO_RECONFIG: audio_output_changed(e); r.kind=7; break;
        case MPV_EVENT_COMMAND_REPLY:
        case MPV_EVENT_SET_PROPERTY_REPLY: {
            if (v->reply_userdata == AUDIO_LEVEL_REPLY) {
                audio_level *l = &e->level;
                enum level_action sent = l->pending;
                l->pending = LEVEL_IDLE;
                if (sent == LEVEL_RENDERER_MUTE && l->sent_generation == l->output_generation) {
                    if (v->error >= 0) l->renderer_mute = (int)l->sent_value;
                    else l->renderer_unavailable = 1;
                } else if (sent == LEVEL_GAIN) {
                    if (v->error < 0) { r.kind = 3; r.error = v->error; break; }
                    l->applied_gain = l->sent_value;
                }
                reconcile_audio_level(e);
                r.kind = 7; break;
            }
            track_command_result *slot=&e->track_commands[v->reply_userdata%TRACK_COMMAND_SLOTS];
            if(v->reply_userdata && slot->id==v->reply_userdata) { slot->done=1; slot->error=v->error; r.kind=7; break; }
            if(v->error<0) { r.kind=3; r.error=v->error; }
            else if(v->event_id==MPV_EVENT_COMMAND_REPLY && v->reply_userdata==e->stop_command) { r.kind=8; }
            else { r.kind=7; }
            break;
        }
        case MPV_EVENT_FILE_LOADED: r.kind=1; break;
        case MPV_EVENT_END_FILE: {
            mpv_event_end_file *end = v->data;
            r.kind = end->reason == MPV_END_FILE_REASON_EOF ? 2 : end->reason == MPV_END_FILE_REASON_ERROR ? 3 : 4;
            r.error = end->error; break;
        }
        case MPV_EVENT_PLAYBACK_RESTART: r.kind=5; break;
        case MPV_EVENT_SHUTDOWN: r.kind=6; break;
        default: r.kind=7; break;
    }
    return r;
}
static void *get_proc(void *unused, const char *name) { return dlsym(RTLD_DEFAULT,name); }
int seatsix_mpv_render_create(seatsix_mpv *e) {
    if(e->render) return 0;
    mpv_opengl_init_params gl={.get_proc_address=get_proc};
    mpv_render_param args[] = {{MPV_RENDER_PARAM_API_TYPE,MPV_RENDER_API_TYPE_OPENGL},{MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,&gl},{MPV_RENDER_PARAM_INVALID,NULL}};
    return mpv_render_context_create(&e->render,e->handle,args);
}
void seatsix_mpv_render_set_callback(seatsix_mpv *e, seatsix_mpv_callback callback, void *context, seatsix_mpv_callback release_context) {
    e->render_callback_context=context;
    e->release_render_callback=release_context;
    mpv_render_context_set_update_callback(e->render,callback,context);
}
uint64_t seatsix_mpv_rendered_frame_count(seatsix_mpv *e) { return e->rendered_frames; }
int seatsix_mpv_render_update(seatsix_mpv *e) {
    if(e->render && (mpv_render_context_update(e->render)&MPV_RENDER_UPDATE_FRAME)) e->frame_pending=1;
    return e->frame_pending;
}
int seatsix_mpv_render(seatsix_mpv *e, int fbo, int width, int height, int flip) {
    if(!e->render) return MPV_ERROR_UNINITIALIZED;
    mpv_opengl_fbo target={.fbo=fbo,.w=width,.h=height,.internal_format=0};
    int block=0;
    mpv_render_param args[]={{MPV_RENDER_PARAM_OPENGL_FBO,&target},{MPV_RENDER_PARAM_FLIP_Y,&flip},{MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,&block},{MPV_RENDER_PARAM_INVALID,NULL}};
    int result=mpv_render_context_render(e->render,args);
    if(result>=0 && e->frame_pending) { e->rendered_frames++; e->frame_pending=0; }
    return result;
}
void seatsix_mpv_render_destroy(seatsix_mpv *e) {
    if(e && e->render) {
        mpv_render_context_set_update_callback(e->render,NULL,NULL);
        mpv_render_context_free(e->render);
        e->render=NULL;
        // All renderer activity has ended before the retained Swift callback
        // context is released. Queued main-queue deliveries hold only weak refs.
        if(e->release_render_callback) e->release_render_callback(e->render_callback_context);
        e->release_render_callback=NULL; e->render_callback_context=NULL;
    }
}
void seatsix_mpv_destroy(seatsix_mpv *e) { if(e) { seatsix_mpv_render_destroy(e); mpv_terminate_destroy(e->handle); clear_tracks(e); clear_chapters(e); for(int i=0;i<PROPERTY_COUNT;i++) free(e->properties[i].string); free(e); } }
