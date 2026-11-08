package com.mojang.text2speech;

// CocoLauncher: text2speech 1.17.x API (ModernFix's narrator mixin switches on it). The narrator never runs
// on iOS, so get() always reports UNSUPPORTED.
public enum OperatingSystem {
    LINUX("linux"),
    WINDOWS("windows"),
    MAC_OS("mac"),
    UNSUPPORTED("");

    private final String detectWith;

    OperatingSystem(String detectWith) {
        this.detectWith = detectWith;
    }

    public static OperatingSystem get() {
        return UNSUPPORTED;
    }
}
