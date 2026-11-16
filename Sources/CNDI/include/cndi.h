// The part of NDI's public C API Understudy uses (NDI SDK v5/v6 ABI). The library itself is
// loaded at run time (libndi.dylib, bundled in the app or installed), so nothing links to it.
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct cndi_source_t {
    const char *p_ndi_name;
    const char *p_url_address;
} cndi_source_t;

typedef struct cndi_send_create_t {
    const char *p_ndi_name;
    const char *p_groups;
    bool clock_video;
    bool clock_audio;
} cndi_send_create_t;

typedef struct cndi_video_frame_v2_t {
    int xres, yres;
    uint32_t FourCC;
    int frame_rate_N, frame_rate_D;
    float picture_aspect_ratio;
    int frame_format_type;
    int64_t timecode;
    uint8_t *p_data;
    union {
        int line_stride_in_bytes;
        int data_size_in_bytes;
    };
    const char *p_metadata;
    int64_t timestamp;
} cndi_video_frame_v2_t;

typedef struct cndi_find_create_t {
    bool show_local_sources;
    const char *p_groups;
    const char *p_extra_ips;
} cndi_find_create_t;

typedef struct cndi_recv_create_v3_t {
    cndi_source_t source_to_connect_to;
    int color_format;
    int bandwidth;
    bool allow_video_fields;
    const char *p_ndi_recv_name;
} cndi_recv_create_v3_t;

#define CNDI_FOURCC_BGRA ((uint32_t)'B' | ((uint32_t)'G' << 8) | ((uint32_t)'R' << 16) | ((uint32_t)'A' << 24))
#define CNDI_FRAME_FORMAT_PROGRESSIVE 1
#define CNDI_TIMECODE_SYNTHESIZE INT64_MAX
#define CNDI_FRAME_TYPE_VIDEO 1
#define CNDI_RECV_COLOR_BGRX_BGRA 0
#define CNDI_RECV_BANDWIDTH_HIGHEST 100
