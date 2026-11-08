package com.mojang.text2speech;

public interface Narrator {
    // CocoLauncher: text2speech 1.17.x API (Minecraft 1.21.1 catches Narrator.InitializeException and
    // uses Narrator.EMPTY); without these the game crashes with NoClassDefFoundError while starting.
    Narrator EMPTY = new NarratorDummy();

    class InitializeException extends Exception {
        public InitializeException(String message, Throwable cause) {
            super(message, cause);
        }

        public InitializeException(String message) {
            super(message);
        }
    }

    void say(final String msg, final boolean interrupt);

    void clear();

    boolean active();

    void destroy();

    static Narrator getNarrator() {
        return new NarratorDummy();
    }

    static void setJNAPath(String sep) {
        System.setProperty("jna.library.path", System.getProperty("jna.library.path") + sep + "./src/natives/resources/");
        System.setProperty("jna.library.path", System.getProperty("jna.library.path") + sep + System.getProperty("java.library.path"));
    }
}
