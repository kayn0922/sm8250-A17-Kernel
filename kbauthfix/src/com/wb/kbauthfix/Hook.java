package com.wb.kbauthfix;

import java.lang.reflect.Method;

import android.util.Log;
import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * v1.1 - work around a ROM-side framework defect that kills system_server
 * whenever the original Xiaomi keyboard is attached.
 *
 * Crash chain (confirmed from a real 2026-11-11 13:30:36 dump):
 *
 *   MiuiKeyboardManager.onKeyboardAttach
 *     -> KeyboardAuthFeature.startCheckAuth            (miui_input_thread)
 *       -> KeyboardAuthFeature.doCheckKeyboardIdentity
 *         -> KeyboardAuthHelper.getInstance
 *           -> KeyboardAuthHelper.initService
 *             -> ContextImpl.bindServiceAsUser
 *               -> ActiveServices.bindServiceLocked:4379
 *                  SecurityException: Unable to find app for caller ...
 *                  cmp=com.xiaomi.devauth/.MiDevAuthService
 *
 * v1.0 used XposedBridge.invokeOriginalMethod() and caught SecurityException.
 * That FAILED: invokeOriginalMethod goes through reflection and wraps the
 * thrown SecurityException in InvocationTargetException (once per hooked
 * frame), so the exception still escaped miui_input_thread.
 *
 * v1.1 strategy:
 *   1. Skip the auth chain at its entry points (startCheckAuth /
 *      doCheckKeyboardIdentity / onReAuthCheck) so the binding is never even
 *      attempted. This avoids both the SecurityException AND the NPE that a
 *      half-initialised KeyboardAuthHelper could raise afterwards.
 *   2. Keep a guard on initService: if any other path reaches it directly,
 *      clear the SecurityException in afterHookedMethod. Because the framework
 *      now invokes the original method itself (no reflection), the throwable
 *      is the ORIGINAL SecurityException, not an InvocationTargetException.
 *
 * Nothing is written to /system. Disabling the module restores stock behaviour.
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
        Log.i(TAG, "v1.1 loaded in " + lpparam.processName);

        // Primary: do not start the broken authentication chain at all.
        hookChain(lpparam.classLoader, FEATURE,
                new String[]{"startCheckAuth", "doCheckKeyboardIdentity", "onReAuthCheck"},
                true);
        // Safety net: guard initService in case another path reaches it.
        hookChain(lpparam.classLoader, HELPER,
                new String[]{"initService"},
                false);
    }

    private static void hookChain(ClassLoader cl, String className, String[] names,
                                  final boolean skipOriginal) {
        final Class<?> cls;
        try {
            cls = XposedHelpers.findClass(className, cl);
        } catch (Throwable t) {
            Log.e(TAG, "class unavailable " + className + " -> " + t);
            return;
        }
        int hooked = 0;
        for (final Method m : cls.getDeclaredMethods()) {
            boolean hit = false;
            for (String n : names) {
                if (m.getName().equals(n)) { hit = true; break; }
            }
            if (!hit) continue;

            final Object fallback = defaultValue(m.getReturnType());
            final String label = className.substring(className.lastIndexOf('.') + 1)
                    + "." + m.getName();
            try {
                XposedBridge.hookMethod(m, new XC_MethodHook() {
                    @Override
                    protected void beforeHookedMethod(MethodHookParam param) {
                        if (!skipOriginal) return;
                        try {
                            // Sets returnEarly: the original method is never invoked.
                            param.setResult(fallback);
                            Log.i(TAG, "skipped " + label);
                        } catch (Throwable t) {
                            Log.e(TAG, "skip failed " + label + " -> " + t);
                        }
                    }

                    @Override
                    protected void afterHookedMethod(MethodHookParam param) {
                        Throwable t;
                        try {
                            t = param.getThrowable();
                        } catch (Throwable e) {
                            return;
                        }
                        if (t == null || !hasSecurityException(t)) return;
                        try {
                            // setResult() clears the throwable and sets returnEarly.
                            param.setThrowable(null);
                            param.setResult(fallback);
                            Log.e(TAG, "swallowed " + t + " in " + label);
                        } catch (Throwable e) {
                            Log.e(TAG, "clear throwable failed " + label + " -> " + e);
                        }
                    }
                });
                hooked++;
                Log.i(TAG, "hooked " + label + (skipOriginal ? " [skip]" : " [guard]"));
            } catch (Throwable t) {
                Log.e(TAG, "hook failed " + label + " -> " + t);
            }
        }
        Log.i(TAG, className + ": " + hooked + " method(s) hooked");
    }

    /** Walk the cause chain so both plain and reflection-wrapped failures match. */
    private static boolean hasSecurityException(Throwable t) {
        int depth = 0;
        while (t != null && depth++ < 16) {
            if (t instanceof SecurityException) return true;
            Throwable cause = t.getCause();
            if (cause == t) break;
            t = cause;
        }
        return false;
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
