// Two functions write to the log file, log_line respecting the config switch and log_line_always not,
// and log_first_time lets a hook that runs thousands of times a second still get its message in
// exactly once. pfName turns a pixel format back into the name a person can read.

static volatile bool g_logging = true;
static pthread_mutex_t g_log_mtx = PTHREAD_MUTEX_INITIALIZER;
static FILE* g_log = nullptr;
static void log_write(const char* fmt, va_list ap) {
    pthread_mutex_lock(&g_log_mtx);
    if (!g_log) {
        const char* home = getenv("HOME");
        char path[1024];
        snprintf(path, sizeof(path), "%s/Library/Logs/BG3MetalFX.log", home ? home : "/tmp");
        g_log = fopen(path, "a");
    }

    if (g_log) {
        vfprintf(g_log, fmt, ap);
        fputc('\n', g_log);
        fflush(g_log);
    }

    pthread_mutex_unlock(&g_log_mtx);
}

static void log_line(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static void log_line(const char* fmt, ...) {
    if (!g_logging) return;

    va_list ap;
    va_start(ap, fmt);
    log_write(fmt, ap);
    va_end(ap);
}

// Writes REGARDLESS of the `logging` config option
static void log_line_always(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static void log_line_always(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    log_write(fmt, ap);
    va_end(ap);
}

// saying a thing only once
static pthread_mutex_t g_seenMtx = PTHREAD_MUTEX_INITIALIZER;
static NSMutableSet* g_seen = nil;

// True the first time this text is seen, false ever after. It only answers, it does not write: a hook
// that runs thousands of times a second asks first and then logs. Caller should hold no lock.
static bool log_first_time(NSString* sig) {
    bool isNew = false;
    pthread_mutex_lock(&g_seenMtx);
    if (g_seen && ![g_seen containsObject:sig]) {
        [g_seen addObject:sig];
        isNew = true;
    }
    pthread_mutex_unlock(&g_seenMtx);
    return isNew;
}

// pixel-format name (symbolic -> compiler resolves the enum values)
static const char* pfName(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatInvalid: return "-";
        case MTLPixelFormatR8Unorm: return "R8Unorm";
        case MTLPixelFormatR16Float: return "R16Float";
        case MTLPixelFormatR32Float: return "R32Float";
        case MTLPixelFormatRG8Unorm: return "RG8Unorm";
        case MTLPixelFormatRG16Float: return "RG16Float";
        case MTLPixelFormatRG16Snorm: return "RG16Snorm";
        case MTLPixelFormatRG16Unorm: return "RG16Unorm";
        case MTLPixelFormatRG32Float: return "RG32Float";
        case MTLPixelFormatRGBA8Unorm: return "RGBA8Unorm";
        case MTLPixelFormatRGBA8Unorm_sRGB: return "RGBA8Unorm_sRGB";
        case MTLPixelFormatBGRA8Unorm: return "BGRA8Unorm";
        case MTLPixelFormatBGRA8Unorm_sRGB: return "BGRA8Unorm_sRGB";
        case MTLPixelFormatRGB10A2Unorm: return "RGB10A2Unorm";
        case MTLPixelFormatRG11B10Float: return "RG11B10Float";
        case MTLPixelFormatRGBA16Float: return "RGBA16Float";
        case MTLPixelFormatRGBA32Float: return "RGBA32Float";
        case MTLPixelFormatDepth16Unorm: return "Depth16Unorm";
        case MTLPixelFormatDepth32Float: return "Depth32Float";
        case MTLPixelFormatDepth32Float_Stencil8: return "Depth32Float_Stencil8";
        default: return nullptr;   // caller prints the number
    }
}
