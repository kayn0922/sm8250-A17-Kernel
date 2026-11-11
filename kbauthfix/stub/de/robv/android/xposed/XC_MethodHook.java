package de.robv.android.xposed;
import java.lang.reflect.Member;
public abstract class XC_MethodHook {
    public static class Unhook { }
    public static class MethodHookParam {
        public Member method;
        public Object thisObject;
        public Object[] args;
        public Object getResult() { return null; }
        public void setResult(Object result) { }
        public Throwable getThrowable() { return null; }
        public void setThrowable(Throwable t) { }
    }
    protected void beforeHookedMethod(MethodHookParam param) throws Throwable { }
    protected void afterHookedMethod(MethodHookParam param) throws Throwable { }
}
