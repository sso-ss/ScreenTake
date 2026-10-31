// MediaPipe 1.1.1 C ABI subset, transcribed from the release's ctypes bindings.
// MediaPipe Authors, Apache-2.0; see models/mediapipe/LICENSE.
// Layouts are checked against the installed official package by
// scripts/check_mediapipe_bridge.py. No model or graph operations are reimplemented.
#pragma once
#include <stdint.h>
#include <stdbool.h>
typedef struct {
    const char *model_asset_buffer; unsigned int model_asset_buffer_count;
    const char *model_asset_path; int file_descriptor, delegate, host_environment, host_system;
    const char *host_version, *ca_bundle_path, *app_id, *app_version;
} MpBaseOptions;
typedef struct {
    float x,y,z; bool has_visibility; float visibility; bool has_presence;
    float presence; const char *name;
} MpNormalizedLandmark;
typedef struct { MpNormalizedLandmark *landmarks; uint32_t landmarks_count; } MpNormalizedLandmarks;
typedef struct { uint32_t rows,cols; float *data; } MpMatrix;
typedef struct {
    MpNormalizedLandmarks *face_landmarks; uint32_t face_landmarks_count;
    void *face_blendshapes; uint32_t face_blendshapes_count;
    MpMatrix *facial_transformation_matrixes; uint32_t facial_transformation_matrixes_count;
} MpFaceLandmarkerResult;
typedef struct {
    MpBaseOptions base_options; int running_mode,num_faces;
    float min_face_detection_confidence,min_face_presence_confidence,min_tracking_confidence;
    bool output_face_blendshapes,output_facial_transformation_matrixes;
    void (*result_callback)(int32_t,MpFaceLandmarkerResult *,void *,int64_t);
} MpFaceLandmarkerOptions;
int MpFaceLandmarkerCreate(const MpFaceLandmarkerOptions *,void **,char **);
int MpFaceLandmarkerDetectImage(void *,void *,const void *,MpFaceLandmarkerResult *,char **);
int MpFaceLandmarkerDetectForVideo(void *,void *,const void *,int64_t,MpFaceLandmarkerResult *,char **);
void MpFaceLandmarkerCloseResult(MpFaceLandmarkerResult *);
int MpFaceLandmarkerClose(void *,char **);
int MpImageCreateFromUint8Data(int format,int width,int height,const uint8_t *data,int data_size,void **,char **);
void MpImageFree(void *);
void MpErrorFree(char *);
