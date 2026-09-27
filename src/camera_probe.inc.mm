// Camera-constant probe: camera-view geometry passes bind _PerCamera (view at floats 0..15, projection at
// 16..31) as vertex buffer 11, and the live jitter and the projection are read out of it as it is bound.

// Live jitter for the encoder: proj m[2][0]/m[2][1] -> pixels, and the projection for the interpolator.

// No lock: the camera passes and the snapshot that reads these values run on BG3's render thread. Were a second thread
// ever to bind a camera pass, a torn read would give one interpolated frame a wrong field of view, nothing worse.
static void probe_percamera(const float* f) {
    float m20 = f[24], m21 = f[25];
    if (m20 != 0.0f || m21 != 0.0f) {
        g_jx = m20 * (float)g_inW * 0.5f;
        g_jy = m21 * (float)g_inH * 0.5f;
    }

    memcpy(g_lastProj, f + 16, sizeof(g_lastProj));
}

static bool is_camera_pass(MTLRenderPassDescriptor* d) {
    id<MTLTexture> dt = d.depthAttachment.texture;
    if (!dt || !d.colorAttachments[0].texture) return false;

    NSUInteger w = dt.width, h = dt.height;
    return w != h && w >= 500 && h >= 400;   // excludes square shadow maps and small mips
}

// Hot path (every vertex-buffer bind BG3 issues): the index compare comes first so only _PerCamera binds
// pay for the associated-object lookup. Nothing here autoreleases.
static IMP o_vbuf = nullptr;
static void s_vbuf(id self, SEL _cmd, id<MTLBuffer> buf, NSUInteger offset, NSUInteger index) {
    if (index == 11 && buf && !mod_idle() && objc_getAssociatedObject(self, &kCamPassKey)) {
        const char* pc = (const char*)buf.contents;
        if (pc && buf.length >= offset + 32 * sizeof(float)) probe_percamera((const float*)(pc + offset));
    }

    ((void (*)(id, SEL, id, NSUInteger, NSUInteger))o_vbuf)(self, _cmd, buf, offset, index);
}
