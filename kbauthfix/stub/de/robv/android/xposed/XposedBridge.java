package de.robv.android.xposed;
import java.lang.reflect.Member;
public final class XposedBridge {
    public static void log(String text) { }
    public static void log(Throwable t) { }
    public static Object invokeOriginalMethod(Member method, Object thisObject, Object[] args)
            throws Throwable { return null; }
    public static XC_MethodHook.Unhook hookMethod(Member hookMethod, XC_MethodHook callback) {
        return null;
    }
}
