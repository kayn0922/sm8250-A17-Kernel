package com.wb.kbauthfix;

import java.lang.reflect.Method;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XC_MethodReplacement;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * Workaround for a ROM-side framework defect:
 *
 *   KeyboardAuthHelper.initService() calls Context.bindServiceAsUser() to bind
 *   com.xiaomi.devauth/.MiDevAuthService. On this Android 17 / HyperOS 4 build
 *   ActiveServices.bindServiceLocked() throws
 *   "SecurityException: Unable to find app for caller ...". miui-services.jar
 *   only handles the boolean-false failure path ("cannot bind service"), so the
 *   exception escapes miui_input_thread and kills system_server.
 *
 * This module calls the ORIGINAL method (so a successful bind still performs
 * normal keyboard authentication) and only swallows that one exception type.
 * No system partition is modified. Disabling the module restores stock behaviour.
 */
public final class Hook implements IXposedHookLoadPackage {

    private static final String TAG = "KBAuthFix";
    private static final String HELPER =
            "com.android.server.input.padkeyboard.KeyboardAuthHelper";
    private static final String FEATURE =
            "com.android.server.input.padkeyboard.feature.KeyboardAuthFeature";

    @Override
    public void handleLoadPackage(final XC_LoadPackage.LoadPackageParam lpparam) {
        if (!"android".equals(lpparam.packageName)) {
            return;
        }
        // Primary: the call site that throws.
        hookNamed(lpparam.classLoader, HELPER,
                new String[]{"initService"});
        // Belt and braces: the callers on the same chain, in case the exception
        // is raised from a different overload on some ROM variant.
        hookNamed(lpparam.classLoader, FEATURE,
                new String[]{"startCheckAuth", "doCheckKeyboardIdentity", "onReAuthCheck"});
    }

    private static void hookNamed(ClassLoader cl, String className, String[] names) {
        final Class<?> cls;
        try {
            cls = XposedHelpers.findClass(className, cl);
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": class unavailable " + className + " -> " + t);
            return;
        }
        for (final Method m : cls.getDeclaredMethods()) {
            boolean hit = false;
            for (String n : names) {
                if (m.getName().equals(n)) { hit = true; break; }
            }
            if (!hit) continue;
            final Object fallback = defaultValue(m.getReturnType());
            try {
                XposedBridge.hookMethod(m, new XC_MethodReplacement() {
                    @Override
                    protected Object replaceHookedMethod(MethodHookParam param) throws Throwable {
                        try {
                            return XposedBridge.invokeOriginalMethod(
                                    param.method, param.thisObject, param.args);
                        } catch (SecurityException e) {
                            XposedBridge.log(TAG + ": swallowed " + e
                                    + " in " + param.method.getName());
                            return fallback;
                        } catch (LinkageError e) {
                            // Some LSPosed builds may not expose invokeOriginalMethod.
                            // Skipping the auth call entirely is still safe: it is the
                            // very call that throws on this ROM.
                            XposedBridge.log(TAG + ": original-method API unavailable"
                                    + ", skipping " + param.method.getName());
                            return fallback;
                        }
                    }
                });
                XposedBridge.log(TAG + ": hooked " + className + "." + m.getName());
            } catch (Throwable t) {
                XposedBridge.log(TAG + ": hook failed " + m.getName() + " -> " + t);
            }
        }
    }

    private static Object defaultValue(Class<?> r) {
        if (!r.isPrimitive()) return null;
        if (r == boolean.class) return Boolean.FALSE;
        if (r == int.class) return Integer.valueOf(0);
        if (r == long.class) return Long.valueOf(0L);
        if (r == short.class) return Short.valueOf((short) 0);
        if (r == byte.class) return Byte.valueOf((byte) 0);
        if (r == float.class) return Float.valueOf(0f);
        if (r == double.class) return Double.valueOf(0d);
        if (r == char.class) return Character.valueOf('\0');
        return null;
    }
}
