#ifndef YUME_RENPY_ENTRY
#error YUME_RENPY_ENTRY must name the exported runtime entry point.
#endif

extern int launcher_main(int argc, char **argv);

__attribute__((visibility("default")))
int YUME_RENPY_ENTRY(int argc, char **argv) {
    return launcher_main(argc, argv);
}
