-- Generated from crates/cadaclysm-view-capi/include/cadaclysm_view.h by gen_cdef.py. Do not edit; rerun the script.
return [[

static const uint32_t CADACLYSM_VIEW_ABI_MAJOR = 1;

static const uint32_t CADACLYSM_VIEW_ABI_MINOR = 19;

static const uint32_t CADACLYSM_VIEW_WINDOW_WIN32 = 1;

static const uint32_t CADACLYSM_VIEW_WINDOW_XLIB = 2;

static const uint32_t CADACLYSM_VIEW_WINDOW_XCB = 3;

static const uint32_t CADACLYSM_VIEW_WINDOW_WAYLAND = 4;

static const uint32_t CADACLYSM_VIEW_WINDOW_APPKIT = 5;

static const uint32_t CADACLYSM_VIEW_WINDOW_KMS = 6;

static const uint32_t CADACLYSM_VIEW_KMS_GBM = 1;

static const uint32_t CADACLYSM_VIEW_KMS_GPU = 2;

static const uint32_t CADACLYSM_VIEW_KMS_COPY = 3;

static const uint32_t CADACLYSM_VIEW_SURFACES_EXACT = 0;

static const uint32_t CADACLYSM_VIEW_SURFACES_TRIANGLES = 1;

static const uint32_t CADACLYSM_VIEW_LIGHTING_HEADLIGHT = 0;

static const uint32_t CADACLYSM_VIEW_LIGHTING_STUDIO = 1;

static const uint32_t CADACLYSM_VIEW_LIGHTING_SHOWROOM = 2;

static const uint32_t CADACLYSM_VIEW_FINISH_GLOSS = 0;

static const uint32_t CADACLYSM_VIEW_FINISH_SATIN = 1;

static const uint32_t CADACLYSM_VIEW_FINISH_MATTE = 2;

static const uint32_t CADACLYSM_VIEW_ANALYSIS_NONE = 0;

static const uint32_t CADACLYSM_VIEW_ANALYSIS_ZEBRA = 1;

static const uint32_t CADACLYSM_VIEW_ANALYSIS_ISOPHOTES = 2;

static const uint32_t CADACLYSM_VIEW_ANALYSIS_GAUSSIAN = 3;

static const uint32_t CADACLYSM_VIEW_ANALYSIS_MEAN = 4;

static const uint32_t CADACLYSM_VIEW_ANALYSIS_MIN = 5;

static const uint32_t CADACLYSM_VIEW_ANALYSIS_MAX = 6;

static const uint32_t CADACLYSM_VIEW_BACKEND_ANY = 0;

static const uint32_t CADACLYSM_VIEW_BACKEND_VULKAN = 1;

static const uint32_t CADACLYSM_VIEW_BACKEND_D3D12 = 2;

static const uint32_t CADACLYSM_VIEW_BACKEND_METAL = 3;

static const uint32_t CADACLYSM_VIEW_STANDARD_TOP = 0;

static const uint32_t CADACLYSM_VIEW_STANDARD_FRONT = 1;

static const uint32_t CADACLYSM_VIEW_STANDARD_RIGHT = 2;

static const uint32_t CADACLYSM_VIEW_STANDARD_ISO = 3;

static const uint32_t CADACLYSM_VIEW_LAYER_SURFACES = 0;

static const uint32_t CADACLYSM_VIEW_LAYER_EDGES = 1;

static const uint32_t CADACLYSM_VIEW_LAYER_CURVES = 2;

static const uint32_t CADACLYSM_VIEW_LAYER_ISOCURVES = 3;

static const uint32_t CADACLYSM_VIEW_LAYER_GRID = 4;

static const uint32_t CADACLYSM_VIEW_LAYER_TEXT = 5;

static const uint32_t CADACLYSM_VIEW_TEXT_LABEL = 0;

static const uint32_t CADACLYSM_VIEW_TEXT_WORLD = 1;

static const uint32_t CADACLYSM_VIEW_OCCLUDED_OFF = 0;

static const uint32_t CADACLYSM_VIEW_OCCLUDED_SOLID = 1;

static const uint32_t CADACLYSM_VIEW_OCCLUDED_DASHED = 2;

static const uint32_t CADACLYSM_VIEW_ALIGN_TOP_LEFT = 0;

static const uint32_t CADACLYSM_VIEW_ALIGN_TOP = 1;

static const uint32_t CADACLYSM_VIEW_ALIGN_TOP_RIGHT = 2;

static const uint32_t CADACLYSM_VIEW_ALIGN_LEFT = 3;

static const uint32_t CADACLYSM_VIEW_ALIGN_CENTRE = 4;

static const uint32_t CADACLYSM_VIEW_ALIGN_RIGHT = 5;

static const uint32_t CADACLYSM_VIEW_ALIGN_BOTTOM_LEFT = 6;

static const uint32_t CADACLYSM_VIEW_ALIGN_BOTTOM = 7;

static const uint32_t CADACLYSM_VIEW_ALIGN_BOTTOM_RIGHT = 8;

static const uint32_t CADACLYSM_VIEW_CAMERA_ORBIT = 0;

static const uint32_t CADACLYSM_VIEW_CAMERA_FLY = 1;

static const uint32_t CADACLYSM_VIEW_CAMERA_ORTHO = 2;

static const uint32_t CADACLYSM_VIEW_CAMERA_FIXED = 3;

static const uint32_t CADACLYSM_VIEW_GRID_NONE = 0;

static const uint32_t CADACLYSM_VIEW_GRID_TOP = 1;

static const uint32_t CADACLYSM_VIEW_GRID_FRONT = 2;

static const uint32_t CADACLYSM_VIEW_GRID_RIGHT = 3;

static const uint32_t CADACLYSM_VIEW_EVENT_DOWN = 1;

static const uint32_t CADACLYSM_VIEW_EVENT_MOVE = 2;

static const uint32_t CADACLYSM_VIEW_EVENT_UP = 3;

static const uint32_t CADACLYSM_VIEW_EVENT_CANCEL = 4;

static const uint32_t CADACLYSM_VIEW_EVENT_WHEEL = 5;

static const uint32_t CADACLYSM_VIEW_EVENT_KEY = 6;

static const uint32_t CADACLYSM_VIEW_POINTER_MOUSE = 0;

static const uint32_t CADACLYSM_VIEW_POINTER_TOUCH = 1;

static const uint32_t CADACLYSM_VIEW_POINTER_PEN = 2;

static const uint32_t CADACLYSM_VIEW_BUTTON_LEFT = 0;

static const uint32_t CADACLYSM_VIEW_BUTTON_MIDDLE = 1;

static const uint32_t CADACLYSM_VIEW_BUTTON_RIGHT = 2;

static const uint32_t CADACLYSM_VIEW_INPUT_CLOSE = 1;

static const uint32_t CADACLYSM_VIEW_INPUT_PICKED = 2;

static const uint32_t CADACLYSM_VIEW_NAVIGATION_ORBIT = 0;

static const uint32_t CADACLYSM_VIEW_NAVIGATION_FLY = 1;

static const uint32_t CADACLYSM_VIEW_OPEN = 1;

static const uint32_t CADACLYSM_VIEW_CLOSED = 2;

static const uint32_t CADACLYSM_VIEW_LOD_DETAILED = 0;

static const uint32_t CADACLYSM_VIEW_LOD_SMOOTH = 1;

static const uint32_t CADACLYSM_VIEW_TOOL_FLAT = 0;

static const uint32_t CADACLYSM_VIEW_TOOL_BALL = 1;

static const uint32_t CADACLYSM_VIEW_TOOL_DRILL = 2;

static const uint32_t CADACLYSM_VIEW_TOOL_VBIT = 3;

static const uint32_t CADACLYSM_VIEW_TOOL_BULLNOSE = 4;

static const uint32_t CADACLYSM_VIEW_COLOUR_BY_HEIGHT = 0;

static const uint32_t CADACLYSM_VIEW_COLOUR_BY_TOOL = 1;

static const uint32_t CADACLYSM_VIEW_COLOUR_BY_DEVIATION = 2;

static const uint32_t CADACLYSM_VIEW_USER_LAYERS = 32;

static const uint32_t CADACLYSM_VIEW_API_D3D12 = 1;

static const uint32_t CADACLYSM_VIEW_API_VULKAN = 2;

static const uint32_t CADACLYSM_VIEW_API_METAL = 3;

static const uint32_t CADACLYSM_VIEW_API_D3D11 = 4;

static const uint32_t CADACLYSM_VIEW_DEVICE_WGPU = 1;

static const uint32_t CADACLYSM_VIEW_SHARED_HOST_SEMAPHORES = 1;

static const uint32_t CADACLYSM_VIEW_TEXTURE_VULKAN_IMAGE = 1;

static const uint32_t CADACLYSM_VIEW_TEXTURE_METAL_TEXTURE = 2;

static const uint32_t CADACLYSM_VIEW_TEXTURE_WIN32_HANDLE = 3;

static const uint32_t CADACLYSM_VIEW_TEXTURE_POSIX_FD = 4;

static const uint32_t CADACLYSM_VIEW_TEXTURE_IOSURFACE = 5;

static const uint32_t CADACLYSM_VIEW_TEXTURE_METAL_SHARED = 6;

static const uint32_t CADACLYSM_VIEW_TEXTURE_D3D12_RESOURCE = 7;

typedef struct CadaclysmView CadaclysmView;

typedef struct CadaclysmViewWindow {

  uint32_t size;

  uint32_t kind;

  void *window;

  uint64_t window_id;

  void *display;

  uint32_t width;
  uint32_t height;
} CadaclysmViewWindow;

typedef struct CadaclysmViewOptions {

  uint32_t size;

  uint32_t surfaces;

  uint32_t backend;

  uint32_t y_up;

  const char *title;

  uint32_t width;
  uint32_t height;

  uint32_t offscreen;
} CadaclysmViewOptions;

typedef struct CadaclysmViewCamera {

  uint32_t size;
  float eye[3];
  float target[3];
  float up[3];

  uint32_t orthographic;
} CadaclysmViewCamera;

typedef struct CadaclysmViewPick {

  uint32_t size;

  uint32_t item;

  uint32_t node;

  uint32_t face;

  uint32_t clicks;

  uint32_t has_point;

  float point[3];
} CadaclysmViewPick;

typedef struct CadaclysmViewAnalysis {

  uint32_t size;

  uint32_t mode;

  uint32_t count;

  float angle;

  float width;

  float light[3];

  double range;
} CadaclysmViewAnalysis;

typedef struct CadaclysmViewLod {

  uint32_t size;

  uint32_t min_triangles;

  uint32_t motion;
} CadaclysmViewLod;

typedef struct CadaclysmViewViewport {

  uint32_t size;

  uint32_t rect[4];

  float view[16];

  float projection[16];
  float eye[3];

  uint32_t grid;

  uint32_t layer_mask;
} CadaclysmViewViewport;

typedef struct CadaclysmViewEvent {

  uint32_t size;

  uint32_t kind;
  uint32_t pointer_id;

  uint32_t pointer;

  uint32_t button;

  uint32_t shift;

  float x;
  float y;

  float wheel_y;

  const char *key;

  uint32_t key_down;

  double time_ms;

  uint32_t alt;
} CadaclysmViewEvent;

typedef struct CadaclysmViewMesh {

  uint32_t size;

  const float *positions;
  uint32_t vertex_count;

  const float *normals;

  const uint32_t *indices;
  uint32_t index_count;

  const float *edges;
  uint32_t edge_count;

  const float *rgb;
} CadaclysmViewMesh;

typedef struct CadaclysmViewImage {

  uint32_t size;

  float corners[12];

  const uint8_t *rgba;
  uint32_t width;
  uint32_t height;

  float opacity;
  uint32_t flip_x;
  uint32_t flip_y;
} CadaclysmViewImage;

typedef struct CadaclysmViewProgram {

  uint32_t size;

  uint32_t tool_number;

  uint32_t tool_shape;

  double tool_diameter;

  double tool_flute_length;

  double tool_angle;

  double tool_corner_radius;

  const char *gcode;
} CadaclysmViewProgram;

typedef struct CadaclysmViewMachining {

  uint32_t size;

  uint32_t program_count;

  const struct CadaclysmViewProgram *programs;

  double stock_min[3];

  double stock_max[3];

  const float *part_positions;

  const uint32_t *part_indices;
  uint32_t part_vertex_count;
  uint32_t part_index_count;

  double cell;

  double tolerance;

  double skin;

  double rapid_rate;

  uint32_t skin_set;
} CadaclysmViewMachining;

typedef struct CadaclysmViewMachiningInfo {

  uint32_t size;

  uint32_t moves;

  uint32_t move;

  uint32_t nx;
  uint32_t ny;

  float cell;

  float min[2];

  double cycle_time;
} CadaclysmViewMachiningInfo;

typedef struct CadaclysmViewText {

  uint32_t size;

  const char *text;

  uint32_t mode;

  float at[3];

  float right[3];

  float up[3];

  float height;

  float rgb[3];

  uint32_t align;

  float offset[2];

  float box_rgba[4];

  float box_padding;

  uint32_t on_top;

  uint32_t font;
} CadaclysmViewText;

typedef struct CadaclysmViewViewportCamera {

  uint32_t size;

  uint32_t kind;

  uint32_t rect[4];

  float view[16];

  float projection[16];

  float eye[3];

  float target[3];

  float distance;

  float yaw;

  float pitch;

  uint32_t orthographic;

  float speed;

  float radius;

  float height;

  float axis_view[3];

  float axis_right[3];

  float axis_up[3];
} CadaclysmViewViewportCamera;

typedef struct CadaclysmViewDevice {

  uint32_t size;

  uint32_t api;

  uint32_t flags;

  void *device;

  void *queue;

  void *instance;

  void *physical_device;

  uint32_t queue_family;

  uint32_t queue_index;

  uint32_t api_version;

  const char *const *instance_extensions;
  uint32_t instance_extension_count;

  const char *const *extensions;
  uint32_t extension_count;

  const void *enabled_features;

  uint32_t width;
  uint32_t height;
} CadaclysmViewDevice;

typedef struct CadaclysmViewShared {

  uint32_t size;

  uint32_t api;

  uint8_t adapter_luid[8];

  uint8_t device_uuid[16];

  uint8_t driver_uuid[16];

  uint64_t registry_id;

  uint32_t flags;

  uint32_t width;
  uint32_t height;
} CadaclysmViewShared;

typedef struct CadaclysmViewTexture {

  uint32_t size;

  uint32_t kind;

  void *texture;

  int32_t fd;

  uint64_t memory_size;

  uint32_t width;
  uint32_t height;

  uint32_t state;

  uint32_t slot;

  uint32_t slot_count;

  uint32_t drawn;

  uint64_t generation;

  void *ready_fence;

  void *release_fence;

  int32_t ready_fence_fd;

  int32_t release_fence_fd;

  uint64_t ready_value;

  uint64_t release_value;
} CadaclysmViewTexture;

typedef struct CadaclysmViewKmsInfo {

  uint32_t size;

  uint32_t path;

  uint64_t modifier;

  uint32_t connector;

  uint32_t width;
  uint32_t height;
  uint32_t refresh;

  uint32_t fourcc;

  char connector_name[32];

  char card[64];

  char adapter[128];
} CadaclysmViewKmsInfo;

uint32_t cadaclysm_view_abi_version(void);

const char *cadaclysm_view_last_error(void);

const char *cadaclysm_view_name(void);

bool cadaclysm_view_parse_colour(const char *text, float *out);

struct CadaclysmView *cadaclysm_view_create(const struct CadaclysmViewWindow *window,
                                            const struct CadaclysmViewOptions *options);

void cadaclysm_view_destroy(struct CadaclysmView *view);

uint32_t cadaclysm_view_pump(struct CadaclysmView *view, uint32_t timeout_ms);

bool cadaclysm_view_run(struct CadaclysmView *view,
                        struct CadaclysmViewCamera *camera_out,
                        struct CadaclysmViewPick *pick_out);

bool cadaclysm_view_resize(struct CadaclysmView *view, uint32_t width, uint32_t height);

bool cadaclysm_view_needs_draw(const struct CadaclysmView *view);

bool cadaclysm_view_draw(struct CadaclysmView *view);

bool cadaclysm_view_size(struct CadaclysmView *view, uint32_t *width, uint32_t *height);

bool cadaclysm_view_image(struct CadaclysmView *view, uint8_t *rgba, size_t capacity);

uint32_t cadaclysm_view_show(struct CadaclysmView *view, const void *scene);

bool cadaclysm_view_remove(struct CadaclysmView *view, uint32_t item);

bool cadaclysm_view_set_surfaces(struct CadaclysmView *view, uint32_t surfaces);

uint32_t cadaclysm_view_surfaces(const struct CadaclysmView *view);

void cadaclysm_view_orbit(struct CadaclysmView *view, float dx, float dy);

void cadaclysm_view_pan(struct CadaclysmView *view, float dx, float dy);

void cadaclysm_view_zoom(struct CadaclysmView *view, float steps);

bool cadaclysm_view_frame(struct CadaclysmView *view, uint32_t item);

bool cadaclysm_view_standard(struct CadaclysmView *view, uint32_t which);

void cadaclysm_view_set_orthographic(struct CadaclysmView *view, bool on);

bool cadaclysm_view_set_layer(struct CadaclysmView *view, uint32_t layer, bool on);

bool cadaclysm_view_set_item_layer(struct CadaclysmView *view, uint32_t item, uint32_t layer);

bool cadaclysm_view_set_user_layer(struct CadaclysmView *view, uint32_t layer, bool on);

void cadaclysm_view_set_background(struct CadaclysmView *view, const float *rgb);

bool cadaclysm_view_set_lighting(struct CadaclysmView *view, uint32_t lighting);

uint32_t cadaclysm_view_lighting(const struct CadaclysmView *view);

bool cadaclysm_view_set_analysis(struct CadaclysmView *view,
                                 const struct CadaclysmViewAnalysis *analysis);

bool cadaclysm_view_analysis(const struct CadaclysmView *view, struct CadaclysmViewAnalysis *out);

bool cadaclysm_view_set_lod(struct CadaclysmView *view, const struct CadaclysmViewLod *lod);

uint32_t cadaclysm_view_wake_ms(const struct CadaclysmView *view);

bool cadaclysm_view_set_node_visible(struct CadaclysmView *view,
                                     uint32_t item,
                                     uint32_t node,
                                     bool visible);

bool cadaclysm_view_set_node_color(struct CadaclysmView *view,
                                   uint32_t item,
                                   uint32_t node,
                                   const float *rgba);

bool cadaclysm_view_set_node_highlight(struct CadaclysmView *view,
                                       uint32_t item,
                                       uint32_t node,
                                       const float *rgba);

bool cadaclysm_view_set_viewports(struct CadaclysmView *view,
                                  const struct CadaclysmViewViewport *viewports,
                                  uint32_t count);

void cadaclysm_view_request_pick(struct CadaclysmView *view,
                                 uint32_t x,
                                 uint32_t y);

void cadaclysm_view_request_pick_in(struct CadaclysmView *view,
                                    uint32_t viewport,
                                    uint32_t x,
                                    uint32_t y);

bool cadaclysm_view_pick_result(struct CadaclysmView *view, struct CadaclysmViewPick *out);

bool cadaclysm_view_frame_node(struct CadaclysmView *view, uint32_t item, uint32_t node);

void cadaclysm_view_set_double_click_frames(struct CadaclysmView *view, bool on);

bool cadaclysm_view_focus(struct CadaclysmView *view, const float *point);

uint32_t cadaclysm_view_navigation(struct CadaclysmView *view);

void cadaclysm_view_look(struct CadaclysmView *view, float dx, float dy);

void cadaclysm_view_dolly(struct CadaclysmView *view, float ratio);

uint32_t cadaclysm_view_input(struct CadaclysmView *view, const struct CadaclysmViewEvent *event);

uint32_t cadaclysm_view_show_mesh(struct CadaclysmView *view, const struct CadaclysmViewMesh *mesh);

uint32_t cadaclysm_view_show_lines(struct CadaclysmView *view,
                                   const float *segments,
                                   uint32_t segment_count,
                                   const float *rgb);

uint32_t cadaclysm_view_show_points(struct CadaclysmView *view,
                                    const float *positions,
                                    uint32_t point_count,
                                    const float *rgb,
                                    float size_px);

uint32_t cadaclysm_view_show_curves(struct CadaclysmView *view,
                                    const float *beziers,
                                    uint32_t curve_count,
                                    const float *rgb);

uint32_t cadaclysm_view_show_image(struct CadaclysmView *view,
                                   const struct CadaclysmViewImage *image);

bool cadaclysm_view_set_colour(struct CadaclysmView *view, uint32_t item, const float *rgb);

bool cadaclysm_view_set_xray(struct CadaclysmView *view, uint32_t item, bool on);

bool cadaclysm_view_set_occluded(struct CadaclysmView *view, uint32_t item, uint32_t mode);

bool cadaclysm_view_set_finish(struct CadaclysmView *view, uint32_t item, uint32_t finish);

bool cadaclysm_view_set_face_colours(struct CadaclysmView *view,
                                     uint32_t item,
                                     const uint32_t *faces,
                                     const float *rgba,
                                     uint32_t count);

bool cadaclysm_view_set_placement(struct CadaclysmView *view, uint32_t item, const double *matrix);

bool cadaclysm_view_set_node_transforms(struct CadaclysmView *view,
                                        uint32_t item,
                                        const double *transforms,
                                        uint32_t count);

uint32_t cadaclysm_view_show_machining(struct CadaclysmView *view,
                                       const struct CadaclysmViewMachining *machining);

bool cadaclysm_view_machining_seek(struct CadaclysmView *view, uint32_t item, uint32_t to);

bool cadaclysm_view_machining_colour_by(struct CadaclysmView *view, uint32_t item, uint32_t mode);

bool cadaclysm_view_machining_overlays(struct CadaclysmView *view,
                                       uint32_t item,
                                       bool path,
                                       bool tool);

bool cadaclysm_view_machining_info(struct CadaclysmView *view,
                                   uint32_t item,
                                   struct CadaclysmViewMachiningInfo *out);

bool cadaclysm_view_machining_heights(struct CadaclysmView *view,
                                      uint32_t item,
                                      float *heights,
                                      size_t capacity);

bool cadaclysm_view_timeline_play(struct CadaclysmView *view, double speed);

bool cadaclysm_view_timeline_pause(struct CadaclysmView *view);

bool cadaclysm_view_timeline_seek(struct CadaclysmView *view, double seconds);

bool cadaclysm_view_timeline_set_loop(struct CadaclysmView *view, bool on);

double cadaclysm_view_timeline_time(const struct CadaclysmView *view);

double cadaclysm_view_timeline_duration(const struct CadaclysmView *view);

bool cadaclysm_view_timeline_playing(const struct CadaclysmView *view);

size_t cadaclysm_view_timeline_status(const struct CadaclysmView *view,
                                      char *text,
                                      size_t capacity);

uint32_t cadaclysm_view_show_solid(struct CadaclysmView *view,
                                   const void *solid,
                                   double tolerance,
                                   const float *rgb);

uint32_t cadaclysm_view_load_font(const uint8_t *bytes, size_t length);

uint32_t cadaclysm_view_show_text(struct CadaclysmView *view, const struct CadaclysmViewText *text);

bool cadaclysm_view_set_text(struct CadaclysmView *view, uint32_t item, const char *text);

bool cadaclysm_view_viewport_camera(const struct CadaclysmView *view,
                                    uint32_t viewport,
                                    struct CadaclysmViewViewportCamera *out);

bool cadaclysm_view_set_viewport_camera(struct CadaclysmView *view,
                                        uint32_t viewport,
                                        const struct CadaclysmViewViewportCamera *camera);

bool cadaclysm_view_set_viewport_rects(struct CadaclysmView *view,
                                       const uint32_t *rects,
                                       uint32_t count);

bool cadaclysm_view_aim(struct CadaclysmView *view,
                        uint32_t viewport,
                        const float *direction,
                        const float *up);

bool cadaclysm_view_set_pivot(struct CadaclysmView *view, uint32_t viewport, const float *point);

bool cadaclysm_view_set_tap(struct CadaclysmView *view, float px, double ms);

void cadaclysm_view_orbit_in(struct CadaclysmView *view, uint32_t viewport, float dx, float dy);

void cadaclysm_view_pan_in(struct CadaclysmView *view, uint32_t viewport, float dx, float dy);

void cadaclysm_view_zoom_in(struct CadaclysmView *view, uint32_t viewport, float steps);

void cadaclysm_view_look_in(struct CadaclysmView *view, uint32_t viewport, float dx, float dy);

void cadaclysm_view_dolly_in(struct CadaclysmView *view, uint32_t viewport, float ratio);

bool cadaclysm_view_frame_in(struct CadaclysmView *view, uint32_t viewport, uint32_t item);

bool cadaclysm_view_standard_in(struct CadaclysmView *view, uint32_t viewport, uint32_t which);

struct CadaclysmView *cadaclysm_view_create_on_device(const struct CadaclysmViewDevice *device,
                                                      const struct CadaclysmViewOptions *options);

struct CadaclysmView *cadaclysm_view_create_shared(const struct CadaclysmViewShared *shared,
                                                   const struct CadaclysmViewOptions *options);

bool cadaclysm_view_texture(struct CadaclysmView *view, struct CadaclysmViewTexture *out);

bool cadaclysm_view_release(struct CadaclysmView *view, uint64_t release_value);

bool cadaclysm_view_kms_info(const struct CadaclysmView *view, struct CadaclysmViewKmsInfo *out);

bool cadaclysm_view_kms_probe(const struct CadaclysmViewWindow *window,
                              struct CadaclysmViewKmsInfo *out);
]]
