// How a hook gets in. Metal's real classes only exist at runtime, so the mod swaps a method the first
// time it sees an object of that class: mark_class answers whether the class is new, swz does the swap
// and returns the original implementation to forward to. Every hook_* function uses both.

// the classes already hooked
static pthread_mutex_t g_hookMtx = PTHREAD_MUTEX_INITIALIZER;
static Class g_hooked[32];
static int g_hookedN = 0;

// True if this concrete class hasn't been hooked yet (then marks it hooked).
// The hooked-class list is append-only: readers scan up to the published count without a lock (this runs
// for every encoder and command buffer BG3 creates), and only the writer takes the mutex and publishes the new
// count with a release store after writing the entry.
static std::atomic<int> g_hookedPublished{0};
static bool mark_class(Class c) {
    int n = g_hookedPublished.load(std::memory_order_acquire);
    for (int i = 0; i < n; i++)
        if (g_hooked[i] == c) return false;

    pthread_mutex_lock(&g_hookMtx);
    bool isNew = true;
    for (int i = 0; i < g_hookedN; i++)
        if (g_hooked[i] == c) {
            isNew = false;
            break;
        }

    if (isNew) {
        if (g_hookedN < 32) {
            g_hooked[g_hookedN] = c;
            g_hookedN++;
            g_hookedPublished.store(g_hookedN, std::memory_order_release);
        } else {
            isNew = false;   // a full table refuses: hooking an unrecorded class would re-hook it on every sighting
            static bool once = false;
            if (!once) {
                once = true;
                log_line_always("HOOK: class table full, %s not hooked", class_getName(c));
            }
        }
    }

    pthread_mutex_unlock(&g_hookMtx);
    return isNew;
}

// swizzle helper
// One original implementation per hook. class_getInstanceMethod returns the inherited Method when the
// class does not implement the selector itself, so a second concrete class that inherits an already
// hooked method finds our implementation in place and is left alone, while a second class with an
// implementation of its own is not hooked either, because the single slot cannot forward to two originals.
static void swz(IMP* slot, Class cls, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        log_line("  (method %s absent on %s)", sel_getName(sel), class_getName(cls));
        return;
    }

    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;
    if (*slot) {
        log_line_always(
            "HOOK: %s on %s has its own implementation while the hook already forwards to another class; left alone",
            sel_getName(sel), class_getName(cls));
        return;
    }

    *slot = method_setImplementation(m, newImp);
}
