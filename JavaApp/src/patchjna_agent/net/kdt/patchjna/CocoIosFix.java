package net.kdt.patchjna;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.instrument.ClassDefinition;
import java.lang.instrument.Instrumentation;
import java.nio.charset.StandardCharsets;

/**
 * CocoLauncher: iOS data volumes are case-sensitive, but this JDK (macOS port) reports
 * MacOSXFileSystem as "case-insensitive and preserving". Path.toRealPath() then lists every
 * parent directory from "/" to find the stored spelling, and the iOS sandbox refuses to list
 * /private/var/mobile/Containers/Data/Application -> AccessDeniedException.
 *
 * Cobblemon's Showdown file system checks every access with toRealPath(), so GraalJS reports
 * "Invalid CommonJS root folder: showdown", Showdown never starts and Minecraft waits forever
 * on Cobblemon's start latch while loading. Making isCaseInsensitiveAndPreserving() return false
 * gives the plain Linux behaviour (resolve "." and "..", check that the file exists).
 *
 * Written for Java 8 (the agent is built with javac 8), runs on the bundled Java 21.
 */
final class CocoIosFix {
    private static final String FS_CLASS = "sun.nio.fs.MacOSXFileSystem";

    private CocoIosFix() {
    }

    static void apply(Instrumentation instrumentation) {
        try {
            Class<?> fsClass = Class.forName(FS_CLASS);
            InputStream in = Object.class.getResourceAsStream("/" + FS_CLASS.replace('.', '/') + ".class");
            if (in == null) {
                log("class file not found, skipped");
                return;
            }
            byte[] patched = patchBooleanMethod(read(in), "isCaseInsensitiveAndPreserving", "()Z");
            if (patched == null) {
                log("isCaseInsensitiveAndPreserving() is not 'return true', skipped");
                return;
            }
            if (!instrumentation.isRedefineClassesSupported() || !instrumentation.isModifiableClass(fsClass)) {
                log("class redefinition not available, skipped");
                return;
            }
            instrumentation.redefineClasses(new ClassDefinition(fsClass, patched));
            log("MacOSXFileSystem.isCaseInsensitiveAndPreserving() now returns false (Path.toRealPath works in the iOS sandbox)");
        } catch (ClassNotFoundException e) {
            log("not running on the macOS file system, skipped");
        } catch (Throwable t) {
            log("failed: " + t);
        }
    }

    private static void log(String message) {
        System.out.println("CocoIosFix: " + message);
    }

    private static byte[] read(InputStream in) throws IOException {
        try {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            int n;
            while ((n = in.read(buffer)) > 0) {
                out.write(buffer, 0, n);
            }
            return out.toByteArray();
        } finally {
            in.close();
        }
    }

    private static int u2(byte[] b, int p) {
        return ((b[p] & 0xFF) << 8) | (b[p + 1] & 0xFF);
    }

    private static int u4(byte[] b, int p) {
        return ((b[p] & 0xFF) << 24) | ((b[p + 1] & 0xFF) << 16) | ((b[p + 2] & 0xFF) << 8) | (b[p + 3] & 0xFF);
    }

    /**
     * Returns a copy of the class file where the method {@code name desc}, whose whole body is
     * "iconst_1; ireturn", becomes "iconst_0; ireturn". Null if that method is not found as such.
     * Same length and constant pool, so it is a valid body-only redefinition.
     */
    static byte[] patchBooleanMethod(byte[] b, String name, String desc) {
        if (b.length < 10 || u4(b, 0) != 0xCAFEBABE) {
            return null;
        }
        int p = 8;
        int cpCount = u2(b, p);
        p += 2;
        String[] utf8 = new String[cpCount];
        for (int i = 1; i < cpCount; i++) {
            int tag = b[p++] & 0xFF;
            switch (tag) {
                case 1: {
                    int len = u2(b, p);
                    p += 2;
                    utf8[i] = new String(b, p, len, StandardCharsets.UTF_8);
                    p += len;
                    break;
                }
                case 3:
                case 4:
                    p += 4;
                    break;
                case 5:
                case 6:
                    p += 8;
                    i++;
                    break;
                case 7:
                case 8:
                case 16:
                case 19:
                case 20:
                    p += 2;
                    break;
                case 9:
                case 10:
                case 11:
                case 12:
                case 17:
                case 18:
                    p += 4;
                    break;
                case 15:
                    p += 3;
                    break;
                default:
                    return null;
            }
        }
        p += 6; // access_flags, this_class, super_class
        int interfaces = u2(b, p);
        p += 2 + 2 * interfaces;
        int fields = u2(b, p);
        p += 2;
        for (int f = 0; f < fields; f++) {
            p += 6;
            int attributes = u2(b, p);
            p += 2;
            for (int a = 0; a < attributes; a++) {
                p += 2;
                int len = u4(b, p);
                p += 4 + len;
            }
        }
        int methods = u2(b, p);
        p += 2;
        for (int m = 0; m < methods; m++) {
            p += 2; // access_flags
            String methodName = utf8[u2(b, p)];
            p += 2;
            String methodDesc = utf8[u2(b, p)];
            p += 2;
            int attributes = u2(b, p);
            p += 2;
            for (int a = 0; a < attributes; a++) {
                String attributeName = utf8[u2(b, p)];
                p += 2;
                int len = u4(b, p);
                p += 4;
                if (name.equals(methodName) && desc.equals(methodDesc) && "Code".equals(attributeName)) {
                    // Code: max_stack u2, max_locals u2, code_length u4, code[]
                    int codeLength = u4(b, p + 4);
                    int code = p + 8;
                    if (codeLength == 2 && (b[code] & 0xFF) == 0x04 && (b[code + 1] & 0xFF) == 0xAC) {
                        byte[] out = b.clone();
                        out[code] = 0x03; // iconst_0
                        return out;
                    }
                    return null;
                }
                p += len;
            }
        }
        return null;
    }
}
