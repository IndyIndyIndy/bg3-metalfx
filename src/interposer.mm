// BG3 MetalFX: the Metal interposer.
//
// Injected via DYLD_INSERT_LIBRARIES at launch. It swizzles Metal classes at runtime,
// replaces BG3's FSR 1.0 upscale with MetalFX Temporal (the scaler output is written into FSR's output
// texture, so BG3 tonemaps and grades it natively), replicates BG3's colour grading through a harvested
// 3D LUT, and optionally owns the presentation (virtual swapchain) to add MetalFX frame interpolation.
// Log: ~/Library/Logs/BG3MetalFX.log. With logging = false a run writes a handful of lines: the banner,
// the presenter's setup, the STATUS verdict and anything that went wrong.
//
// One translation unit: the .inc.mm files are included in the order listed, so a file may use whatever the
// earlier ones defined, and a forward declaration at its top names the few things it needs from a later one.
//
// Not compiled with ARC on purpose: the swizzled methods replace `new...` methods that return an owned
// (+1) object, and a plain C IMP that forwards the original's return value passes that ownership straight
// through. Temporary NSString work is wrapped in @autoreleasepool.

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CABase.h>               // CACurrentMediaTime
#import <QuartzCore/CAMetalDisplayLink.h>   // the display-link presenter (macOS 14+)
#import <CoreGraphics/CGEvent.h>            // CGEventSourceKeyState, the capture hotkey
#import <objc/runtime.h>
#include <pthread.h>
#include <cstdio>
#include <cstdarg>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <unistd.h>
#include <mach/mach_time.h>
#include <cmath>
#include <execinfo.h>
#include <objc/objc-exception.h>
#include "config.h"
#include "grading.h"
#ifndef BG3MFX_VERSION
#define BG3MFX_VERSION "dev"   // pack.sh passes the VERSION file
#endif


#include "logging.inc.mm"            // writes the log
#include "swizzle.inc.mm"            // swaps a Metal method for ours, and remembers which class is done
#include "scaler.inc.mm"             // builds the MetalFX scaler and holds the textures it works on
#include "state.inc.mm"              // the variables the whole mod shares
#include "diagnostics.inc.mm"        // the clock, the stall watchdogs, the periodic reports, GPU capture
#include "config_apply.inc.mm"       // puts config.toml into effect and keeps re-reading it while you play
#include "snapshot.inc.mm"           // texture helpers, and the copies we take out of each frame
#include "metalfx_encode.inc.mm"     // encodes the frame for MetalFX, on the separate or the event path
#include "grading_pipeline.inc.mm"   // learns BG3's colour grading and puts it on our upscaled image
#include "resize_lifetime.inc.mm"    // rebuilds after a resolution change, frees textures only when safe
#include "presenter.inc.mm"          // takes over the display: interpolates, composes, paces the frames
#include "present_hooks.inc.mm"      // the frame boundary, and which pass or pipeline is which
#include "camera_probe.inc.mm"       // reads the camera's jitter and projection as BG3 binds them
#include "vt_mipbias.inc.mm"         // sharpens the streamed world textures (Granite mip bias)
#include "encoder_hooks.inc.mm"      // hooks Metal, from the device down to every draw and dispatch

// interpose Metal device creation
// dyld does not re-interpose calls the replacement makes to the replacee, so calling the real
// function by name here is safe (no recursion).
static id my_MTLCreateSystemDefaultDevice(void) {
    id dev = MTLCreateSystemDefaultDevice();
    hook_device(dev);
    return dev;
}

static NSArray* my_MTLCopyAllDevices(void) {
    NSArray* a = MTLCopyAllDevices();
    for (id<MTLDevice> d in a) hook_device(d);
    return a;
}

// replaces a plain C function, where there is no Objective-C method to swizzle. The pointer
// pair below is dyld's contract: it sits in the __interpose section, replacement first, and at load time
// dyld sends every call to `_real` in the process to `_ours`. `used` keeps the compiler from dropping a
// variable nothing reads, and the integer cast is the detour C++ needs for a function pointer.
#define DYLD_INTERPOSE(_ours, _real)                                                                                   \
    __attribute__((used)) static struct {                                                                              \
        const void* ours;                                                                                              \
        const void* real;                                                                                              \
    } _interpose_##_real __attribute__((section("__DATA,__interpose"))) = {(const void*)(unsigned long)&_ours,         \
                                                                           (const void*)(unsigned long)&_real};
DYLD_INTERPOSE(my_MTLCreateSystemDefaultDevice, MTLCreateSystemDefaultDevice)
DYLD_INTERPOSE(my_MTLCopyAllDevices, MTLCopyAllDevices)

// Every Objective-C exception thrown in the process passes through here before it unwinds. BG3's own
// uncaught-exception handler aborts without recording the reason, so the the first few are written to our
// log with the throwing thread and a backtrace, while the exception itself continues unchanged.
static std::atomic<int> g_excThrown{0};
__attribute__((noreturn)) static void my_objc_exception_throw(id exc) {
    int n = ++g_excThrown;
    if (n <= 5) {
        @autoreleasepool {
            NSException* e = [exc isKindOfClass:[NSException class]] ? (NSException*)exc : nil;
            char name[64] = "";
            pthread_getname_np(pthread_self(), name, sizeof name);
            log_line_always("EXCEPTION THROWN #%d: %s: %s  (thread '%s', main=%d)", n,
                            e ? e.name.UTF8String : object_getClassName(exc), e ? e.reason.UTF8String : "?", name,
                            pthread_main_np() ? 1 : 0);
            void* bt[48];
            int k = backtrace(bt, 48);
            if (char** syms = backtrace_symbols(bt, k)) {
                for (int i = 1; i < k; i++) log_line_always("    %s", syms[i]);
                free(syms);
            }
        }
    }

    objc_exception_throw(exc);
}

DYLD_INTERPOSE(my_objc_exception_throw, objc_exception_throw)

// dyld runs this the moment the library is loaded, before BG3's main, and the timing matters, because the
// HUD and capture switches are environment variables the Metal libraries read at process start, and BG3's
// own graphics settings file can still be rewritten before the game reads it. Then the poll thread starts,
// and nothing else happens until BG3 creates its Metal device, which is where the hooks go in.
__attribute__((constructor)) static void bg3metalfx_init(void) {
    g_seen = [[NSMutableSet alloc] init];   // singleton, intentionally never released
    Config boot = load_config();
    apply_config(boot);   // every global starts with the file's value, not a compile-time guess

    // Run banner, written even with logging = false: every run has a boundary in the log, named by build,
    // game version and the settings that change what a measurement means.
    char gameVersion[64] = "?";
    @autoreleasepool {   // no pool exists before main
        NSString* v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
        if ([v isKindOfClass:[NSString class]]) snprintf(gameVersion, sizeof(gameVersion), "%s", v.UTF8String);
    }

    static const char* const kModeNames[] = {"metalfx", "fsr", "none"};
    static const char* const kScaleNames[] = {"auto", "ultra_quality", "quality", "balanced", "performance"};
    log_line_always("=== BG3MetalFX v%s RUN START (built %s %s) ===  game=%s mode=%s render_scale=%s encode_path=%s "
                    "frame_interp=%d frame_cap=%d grading_bloom=%d vt_mip_bias_auto=%d sharpness=%.2f "
                    "chroma_saturation=%.2f logging=%d",
                    BG3MFX_VERSION, __DATE__, __TIME__, gameVersion, kModeNames[boot.mode], kScaleNames[boot.render_scale + 1],
                    boot.encode_path == ENC_EVENT ? "event" : "separate", boot.frame_interp ? 1 : 0, boot.frame_cap,
                    boot.grading_bloom ? 1 : 0, boot.vt_mip_bias_auto ? 1 : 0, boot.sharpness, boot.chroma_saturation,
                    boot.logging ? 1 : 0);

    if (boot.metal_hud) {
        setenv("MTL_HUD_ENABLED", "1", 1);

        // Layout/content knobs, read by /usr/lib/libMTLHud.dylib at startup. Only variables the user
        // actually configured are set, so anything they exported in their own environment survives.
        char num[32];
        if (boot.hud_position[0]) setenv("MTL_HUD_ALIGNMENT", boot.hud_position, 1);
        if (boot.hud_elements[0]) setenv("MTL_HUD_ELEMENTS", boot.hud_elements, 1);
        if (boot.hud_scale > 0.0f) {
            snprintf(num, sizeof(num), "%g", boot.hud_scale);
            setenv("MTL_HUD_SCALE", num, 1);
        }
        if (boot.hud_opacity > 0.0f) {
            snprintf(num, sizeof(num), "%g", boot.hud_opacity);
            setenv("MTL_HUD_OPACITY", num, 1);
        }
        if (boot.hud_target_fps > 0) {
            snprintf(num, sizeof(num), "%d", boot.hud_target_fps);
            setenv("MTL_HUD_TARGET_FPS", num, 1);
        }
        if (boot.hud_encoder_timing) setenv("MTL_HUD_ENCODER_TIMING_ENABLED", "1", 1);
        if (boot.hud_energy) setenv("MTL_HUD_ENERGY_REPORT_ENABLED", "1", 1);

        log_line("Metal Performance HUD enabled (position=%s scale=%g opacity=%g elements=%s "
                 "encoderTiming=%d energy=%d targetFps=%d).",
                 boot.hud_position[0] ? boot.hud_position : "default", boot.hud_scale, boot.hud_opacity,
                 boot.hud_elements[0] ? boot.hud_elements : "default", boot.hud_encoder_timing ? 1 : 0,
                 boot.hud_energy ? 1 : 0, boot.hud_target_fps);
    }

    // Only enable Metal's capture layer when a GPU capture is actually requested, otherwise it wraps ALL
    // Metal objects in CaptureMTL* proxies (perf cost + changes residency-set behaviour).
    if (boot.gpu_capture) {
        setenv("MTL_CAPTURE_ENABLED", "1", 1);
        log_line("MTL_CAPTURE_ENABLED=1 (gpu_capture)");
    }

    // BG3's render resolution follows its own FSR1Mode setting, and the constructor runs before main, so the
    // setting can still be written before the game reads it.
    if (boot.render_scale >= 0) {
        char detail[512];
        int r = bg3_force_fsr1_mode(boot.render_scale, detail, sizeof(detail));
        log_line("render_scale=%s: %s, %s", kScaleNames[boot.render_scale + 1],
                 r == 1 ? "applied" : (r == 0 ? "no change needed" : "FAILED"), detail);
    }

    // Apple's exposure overlay: a grid that reads as constant mid-grey when MetalFX's exposure is right.
    if (boot.mfx_exposure_tool) {
        setenv("MTLFX_EXPOSURE_TOOL_ENABLED", "1", 1);
        log_line("MTLFX_EXPOSURE_TOOL_ENABLED=1, grid should read as constant mid-grey if exposure is right");
    }

    run_config_poll();   // the background thread: re-reads config.toml, runs the watchdogs and the capture hotkey
    log_line("BG3 MetalFX loaded (pid %d). Waiting for Metal device.", getpid());
}
