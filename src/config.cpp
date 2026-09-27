#include "config.h"
#include "config_template.inc"
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

Config config_defaults() {
    Config c{};
    c.mode = 0;

    c.logging = false;
    c.log_passes = false;

    c.metal_hud = false;
    c.hud_position[0] = 0;
    c.hud_scale = 0.0f;
    c.hud_opacity = 0.0f;
    c.hud_elements[0] = 0;
    c.hud_encoder_timing = false;
    c.hud_energy = false;
    c.hud_target_fps = 0;

    c.mv_scale_x = -1.0f;
    c.mv_scale_y = -1.0f;
    c.sharpness = 0.15f;

    // separate: 1.25 ms per frame faster than event, one frame of world latency. MetalFX reads the previous snapshot there, so the jitter lags with it.
    c.encode_path = ENC_SEPARATE;
    c.gpu_capture = false;
    c.gpu_capture_frames = 5;

    c.mfx_input = 0;
    c.bypass_composite = false;
    c.mfx_exposure_tool = false;
    c.mfx_reset_period = 0;
    c.mip_bias = 0.0f;
    c.vt_mip_bias = 0.0f;
    c.vt_mip_bias_auto = true;
    c.mfx_exposure_value = 0.0f;

    c.chroma_saturation = 1.0f;
    c.chroma_gain_r = 1.0f;
    c.chroma_gain_g = 1.0f;
    c.chroma_gain_b = 1.0f;

    c.fi_ui = true;
    c.virtual_swapchain = false;
    c.frame_cap = 0;
    c.frame_interp = false;
    c.fi_motion_key = 2;
    c.render_scale = -1;

    c.grading_harvest = true;
    c.grading_apply = true;
    c.grading_bloom = true;
    c.skip_fsr_tonemap = true;

    return c;
}

static void trim(char*& s, char*& end) {
    while (s < end && (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n')) ++s;
    while (end > s && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n')) --end;
}

static void parse_bool(const char* v, bool& out) {
    if (!strcasecmp(v, "true") || !strcmp(v, "1")) out = true;
    else if (!strcasecmp(v, "false") || !strcmp(v, "0")) out = false;
}

static void parse_float(const char* v, float& out) {
    char* end = nullptr;
    float f = strtof(v, &end);
    if (end != v) out = f;
}

// Upscaler mode: metalfx (0), fsr (1), none (2). Anything but metalfx = mod stays out of the way.
static void parse_mode(const char* v, int& out) {
    if (!strcasecmp(v, "metalfx")) out = 0;
    else if (!strcasecmp(v, "fsr")) out = 1;
    else if (!strcasecmp(v, "none")) out = 2;
}

static void parse_int(const char* v, int& out) {
    char* e = nullptr;
    long n = strtol(v, &e, 10);
    if (e != v) out = (int)n;
}

static void parse_str(const char* v, char* out, size_t cap) {
    if (!v || !out || cap == 0) return;
    size_t n = strlen(v);
    if (n >= cap) n = cap - 1;
    memcpy(out, v, n);
    out[n] = 0;
}

// Encode path: separate (default) or event.
static void parse_encode_path(const char* v, int& out) {
    if (!strcasecmp(v, "separate")) out = ENC_SEPARATE;
    else if (!strcasecmp(v, "event")) out = ENC_EVENT;
}

// BG3's FSR1Mode quality step, by name. "auto" leaves the game's setting alone.
static void parse_render_scale(const char* v, int& out) {
    if (!strcasecmp(v, "auto")) out = -1;
    else if (!strcasecmp(v, "ultra_quality")) out = 0;
    else if (!strcasecmp(v, "quality")) out = 1;
    else if (!strcasecmp(v, "balanced")) out = 2;
    else if (!strcasecmp(v, "performance")) out = 3;
}

// Unknown keys the last parse saw, comma-separated. The interposer logs them once per distinct set.
char g_cfgUnknown[512] = {0};
void config_parse_string(const char* text, Config& cfg) {
    if (!text) return;
    char unknown[512];
    size_t unknownLen = 0;
    unknown[0] = 0;

    // Unknown keys are collected as "key", out-of-range values as "key=value", and named once by the
    // caller: a silent typo would be indistinguishable from a default.
    auto unknown_add = [&](const char* key, const char* val) {
        size_t kl = strlen(key), ve = val ? strlen(val) + 1 : 0;
        if (unknownLen + kl + ve + 3 > sizeof(unknown)) return;
        if (unknownLen) {
            unknown[unknownLen++] = ',';
            unknown[unknownLen++] = ' ';
        }
        memcpy(unknown + unknownLen, key, kl);
        unknownLen += kl;
        if (val) {
            unknown[unknownLen++] = '=';
            memcpy(unknown + unknownLen, val, ve - 1);
            unknownLen += ve - 1;
        }
        unknown[unknownLen] = 0;
    };

    // Numbers with a valid range: anything else is reported, otherwise a typo silently runs the default.
    auto parse_range = [&](const char* key, const char* val, float lo, float hi, float& out) {
        char* e = nullptr;
        float f = strtof(val, &e);
        if (e != val && f >= lo && f <= hi) out = f;
        else unknown_add(key, val);
    };

    auto parse_int_range = [&](const char* key, const char* val, long lo, long hi, int& out) {
        char* e = nullptr;
        long n = strtol(val, &e, 10);
        if (e != val && n >= lo && n <= hi) out = (int)n;
        else unknown_add(key, val);
    };

    const char* p = text;
    while (*p) {
        const char* nl = strchr(p, '\n');
        const char* line_end = nl ? nl : p + strlen(p);
        char buf[512];   // longer than any value the struct can hold (metal_hud_elements takes 255 characters)
        size_t lineLen = (size_t)(line_end - p);
        if (lineLen > sizeof(buf) - 1) lineLen = sizeof(buf) - 1;
        memcpy(buf, p, lineLen);
        buf[lineLen] = 0;

        if (char* hash = strchr(buf, '#')) *hash = 0;

        if (char* eq = strchr(buf, '=')) {
            *eq = 0;
            char* k = buf;
            char* k_end = k + strlen(k);
            char* v = eq + 1;
            char* v_end = v + strlen(v);
            trim(k, k_end);
            *k_end = 0;
            trim(v, v_end);
            *v_end = 0;

            // strip surrounding quotes on the value
            if (v_end - v >= 2 && ((v[0] == '"' && v_end[-1] == '"') || (v[0] == '\'' && v_end[-1] == '\''))) {
                v[strlen(v) - 1] = 0;
                ++v;
            }

            if (*k && *v) {
                if (!strcmp(k, "mode")) parse_mode(v, cfg.mode);
                else if (!strcmp(k, "logging")) parse_bool(v, cfg.logging);
                else if (!strcmp(k, "log_passes")) parse_bool(v, cfg.log_passes);
                else if (!strcmp(k, "render_scale")) parse_render_scale(v, cfg.render_scale);
                else if (!strcmp(k, "sharpness")) parse_float(v, cfg.sharpness);
                else if (!strcmp(k, "grading_harvest")) parse_bool(v, cfg.grading_harvest);
                else if (!strcmp(k, "grading_apply")) parse_bool(v, cfg.grading_apply);
                else if (!strcmp(k, "grading_bloom")) parse_bool(v, cfg.grading_bloom);
                else if (!strcmp(k, "chroma_saturation")) parse_range(k, v, 0.5f, 2.0f, cfg.chroma_saturation);
                else if (!strcmp(k, "chroma_gain_r")) parse_range(k, v, 0.2f, 5.0f, cfg.chroma_gain_r);
                else if (!strcmp(k, "chroma_gain_g")) parse_range(k, v, 0.2f, 5.0f, cfg.chroma_gain_g);
                else if (!strcmp(k, "chroma_gain_b")) parse_range(k, v, 0.2f, 5.0f, cfg.chroma_gain_b);
                else if (!strcmp(k, "mfx_exposure_value")) parse_range(k, v, 0.0f, 1000.0f, cfg.mfx_exposure_value);
                else if (!strcmp(k, "frame_interp")) parse_bool(v, cfg.frame_interp);
                else if (!strcmp(k, "frame_cap")) parse_int_range(k, v, 0, 240, cfg.frame_cap);
                else if (!strcmp(k, "fi_ui")) parse_bool(v, cfg.fi_ui);
                else if (!strcmp(k, "virtual_swapchain")) parse_bool(v, cfg.virtual_swapchain);
                else if (!strcmp(k, "fi_motion_key")) {
                    if (!strcasecmp(v, "previous")) cfg.fi_motion_key = 0;
                    else if (!strcasecmp(v, "current")) cfg.fi_motion_key = 1;
                    else if (!strcasecmp(v, "auto")) cfg.fi_motion_key = 2;
                } else if (!strcmp(k, "metal_hud")) parse_bool(v, cfg.metal_hud);
                else if (!strcmp(k, "metal_hud_position"))
                    parse_str(v, cfg.hud_position, sizeof(cfg.hud_position));   // an MTL_HUD_ALIGNMENT token
                else if (!strcmp(k, "metal_hud_scale")) parse_float(v, cfg.hud_scale);
                else if (!strcmp(k, "metal_hud_opacity")) parse_float(v, cfg.hud_opacity);
                else if (!strcmp(k, "metal_hud_elements")) parse_str(v, cfg.hud_elements, sizeof(cfg.hud_elements));
                else if (!strcmp(k, "metal_hud_encoder_timing")) parse_bool(v, cfg.hud_encoder_timing);
                else if (!strcmp(k, "metal_hud_energy")) parse_bool(v, cfg.hud_energy);
                else if (!strcmp(k, "metal_hud_target_fps")) parse_int(v, cfg.hud_target_fps);
                else if (!strcmp(k, "encode_path")) parse_encode_path(v, cfg.encode_path);
                else if (!strcmp(k, "skip_fsr_tonemap")) parse_bool(v, cfg.skip_fsr_tonemap);
                else if (!strcmp(k, "mfx_reset_period")) parse_int_range(k, v, 0, 600, cfg.mfx_reset_period);
                else if (!strcmp(k, "vt_mip_bias_auto")) parse_bool(v, cfg.vt_mip_bias_auto);
                else if (!strcmp(k, "vt_mip_bias")) parse_range(k, v, -3.0f, 3.0f, cfg.vt_mip_bias);
                else if (!strcmp(k, "mip_bias")) parse_range(k, v, -4.0f, 4.0f, cfg.mip_bias);
                else if (!strcmp(k, "gpu_capture")) parse_bool(v, cfg.gpu_capture);
                else if (!strcmp(k, "gpu_capture_frames")) parse_int_range(k, v, 1, 60, cfg.gpu_capture_frames);
                else if (!strcmp(k, "mfx_input")) {
                    if (!strcasecmp(v, "post_taa")) cfg.mfx_input = 1;
                    else if (!strcasecmp(v, "pre_taa")) cfg.mfx_input = 0;
                } else if (!strcmp(k, "mfx_exposure_tool")) parse_bool(v, cfg.mfx_exposure_tool);
                else if (!strcmp(k, "mv_scale_x")) parse_float(v, cfg.mv_scale_x);
                else if (!strcmp(k, "mv_scale_y")) parse_float(v, cfg.mv_scale_y);
                else if (!strcmp(k, "bypass_composite")) parse_bool(v, cfg.bypass_composite);
                else unknown_add(k, nullptr);
            }
        }

        if (!nl) break;
        p = nl + 1;
    }

    memcpy(g_cfgUnknown, unknown, unknownLen + 1);
}

// BG3's graphicSettings.lsx
// The LSX layout for one setting is:
//   <attribute id="MapKey" type="FixedString" value="FSR1Mode"/>
//   <attribute id="Type"   type="int32"       value="0"/>
//   <attribute id="Value"  type="int32"       value="2"/>
// So: find the MapKey whose value is `key`, then the FIRST id="Value" after it, and rewrite just the
// number inside its value="...". Nothing else in the file is touched.
bool lsx_set_int_setting(std::string& xml, const char* key, int value, int* oldValue) {
    if (!key) return false;

    std::string needle = std::string("value=\"") + key + "\"";
    size_t k = xml.find(needle);
    if (k == std::string::npos) return false;

    size_t nodeEnd = xml.find("</node>", k);   // the Value attribute belongs to the same node as the MapKey
    size_t v = xml.find("id=\"Value\"", k);
    if (v == std::string::npos || (nodeEnd != std::string::npos && v > nodeEnd)) return false;
    size_t q = xml.find("value=\"", v);
    if (q == std::string::npos || (nodeEnd != std::string::npos && q > nodeEnd)) return false;
    q += 7;   // past value="
    size_t end = xml.find('"', q);
    if (end == std::string::npos || q > k + 4096) return false;

    if (oldValue) *oldValue = atoi(xml.substr(q, end - q).c_str());
    xml.replace(q, end - q, std::to_string(value));
    return true;
}

static bool read_whole_file(const char* path, std::string& out) {
    FILE* f = fopen(path, "rb");
    if (!f) return false;

    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    rewind(f);
    bool ok = false;
    if (n > 0 && n < 16 * 1024 * 1024) {
        out.resize((size_t)n);
        ok = fread(&out[0], 1, (size_t)n, f) == (size_t)n;
    }

    fclose(f);
    return ok;
}

// Write to a sibling temp file and rename it over the target, so a crash mid-write leaves the old file intact.
static bool write_whole_file(const char* path, const std::string& s) {
    std::string tmp = std::string(path) + ".bg3metalfx-tmp";
    FILE* f = fopen(tmp.c_str(), "wb");
    if (!f) return false;

    bool ok = fwrite(s.data(), 1, s.size(), f) == s.size();
    ok = (fclose(f) == 0) && ok;
    if (ok) ok = rename(tmp.c_str(), path) == 0;
    if (!ok) remove(tmp.c_str());
    return ok;
}

int bg3_force_fsr1_mode(int mode, char* detail, size_t detailLen) {
    if (detail && detailLen) detail[0] = 0;
    if (mode < 0 || mode > 3) return 0;

    const char* home = getenv("HOME");
    if (!home) return -1;
    char path[1280], backup[1400];
    snprintf(path, sizeof(path), "%s/Documents/Larian Studios/Baldur's Gate 3/graphicSettings.lsx", home);
    snprintf(backup, sizeof(backup), "%s.bg3metalfx-backup", path);

    std::string xml;
    if (!read_whole_file(path, xml)) {
        if (detail) snprintf(detail, detailLen, "graphicSettings.lsx not readable at %s", path);
        return -1;
    }

    int oldMode = -1;
    std::string patched = xml;
    if (!lsx_set_int_setting(patched, "FSR1Mode", mode, &oldMode)) {
        if (detail) snprintf(detail, detailLen, "FSR1Mode not found in graphicSettings.lsx");
        return -1;
    }

    // Upscaling has to be on at all for the quality step to mean anything, report, don't force.
    int upscaleType = -1;
    {
        std::string probe = xml;
        lsx_set_int_setting(probe, "ResolutionUpscaleType", 0, &upscaleType);
    }

    if (oldMode == mode) {
        if (detail)
            snprintf(detail, detailLen, "FSR1Mode already %d%s", mode,
                     upscaleType == 1 ? "" : " (WARNING: ResolutionUpscaleType != 1, no upscaling active)");
        return 0;
    }

    if (access(backup, F_OK) != 0 && !write_whole_file(backup, xml)) {   // one-time safety copy; no copy, no edit
        if (detail) snprintf(detail, detailLen, "could not write the backup %s", backup);
        return -1;
    }

    if (!write_whole_file(path, patched)) {
        if (detail) snprintf(detail, detailLen, "could not write graphicSettings.lsx");
        return -1;
    }

    if (detail)
        snprintf(detail, detailLen, "FSR1Mode %d -> %d%s (backup at %s)", oldMode, mode,
                 upscaleType == 1 ? "" : " (WARNING: ResolutionUpscaleType != 1, no upscaling active)", backup);
    return 1;
}

static void ensure_dir(const char* path) { mkdir(path, 0755); }

static bool config_file_path(char* file, size_t n) {
    const char* home = getenv("HOME");
    if (!home) return false;

    const char* mods_home = getenv("BG3MODS_HOME");
    char base[1024], dir[1152];
    if (mods_home && *mods_home) snprintf(base, sizeof(base), "%s", mods_home);
    else snprintf(base, sizeof(base), "%s/Library/Application Support/BG3Mods", home);
    ensure_dir(base);
    snprintf(dir, sizeof(dir), "%s/BG3MetalFX", base);
    ensure_dir(dir);
    snprintf(file, n, "%s/config.toml", dir);

    return true;
}

// True when config.toml's modification time differs from the last call (or the file is new/missing).
bool config_file_changed() {
    // Two saves within one second have the same st_mtime, so nanoseconds, size and inode tell them apart
    // (an atomic rename can swap a new inode into place).
    static struct {
        time_t sec;
        long nsec;
        off_t size;
        ino_t ino;
        bool valid;
    } last = {0, 0, 0, 0, false};

    char file[1280];
    if (!config_file_path(file, sizeof(file))) return false;
    struct stat st;
    if (stat(file, &st) != 0) { memset(&st, 0, sizeof st); }

    bool same = last.valid && st.st_mtimespec.tv_sec == last.sec && st.st_mtimespec.tv_nsec == last.nsec &&
                st.st_size == last.size && st.st_ino == last.ino;
    if (same) return false;

    last.sec = st.st_mtimespec.tv_sec;
    last.nsec = st.st_mtimespec.tv_nsec;
    last.size = st.st_size;
    last.ino = st.st_ino;
    last.valid = true;
    return true;
}

Config load_config() {
    Config cfg = config_defaults();
    char file[1280];
    if (!config_file_path(file, sizeof(file))) return cfg;

    // Create the annotated template if it isn't there yet, then ALWAYS parse the file, including
    // the run that just created it, so the very first launch already honours what the file says.
    if (access(file, R_OK) != 0) {
        FILE* w = fopen(file, "w");
        if (w) {
            fputs(kConfigTemplate, w);
            fclose(w);
        }
    }

    std::string text;
    if (read_whole_file(file, text)) config_parse_string(text.c_str(), cfg);
    return cfg;
}
