# KBAuthFix

A minimal LSPosed module that works around a ROM-side framework defect which
kills `system_server` whenever the original Xiaomi keyboard is attached.

## What it does

`miui-services.jar` -> `KeyboardAuthHelper.initService()` binds
`com.xiaomi.devauth/.MiDevAuthService` via `Context.bindServiceAsUser()`. On the
affected HyperOS 4 / Android 17 build, `ActiveServices.bindServiceLocked()`
throws `SecurityException: Unable to find app for caller ...`. The ROM only
handles the boolean-false failure ("cannot bind service"), so the exception
escapes `miui_input_thread` and `RuntimeInit$KillApplicationHandler` kills
`system_server` (framework soft reboot).

The chain is: `onKeyboardAttach` -> `KeyboardAuthFeature.startCheckAuth` ->
`doCheckKeyboardIdentity` -> `KeyboardAuthHelper.getInstance` -> `initService`
-> `ContextImpl.bindServiceAsUser` -> `ActiveServices.bindServiceLocked:4379`
-> `SecurityException`.

### v1.1 (current)

1. Hooks `startCheckAuth` / `doCheckKeyboardIdentity` / `onReAuthCheck` and
   **skips the original method** (`param.setResult(...)` -> `returnEarly`), so
   the broken binding is never attempted. This also avoids the NPE that a
   half-initialised `KeyboardAuthHelper` could raise afterwards.
2. Keeps a guard on `initService`: if any other path reaches it, the
   `SecurityException` is cleared in `afterHookedMethod`. Because LSPosed now
   invokes the original method itself (no reflection), the throwable is the
   original `SecurityException`. The cause chain is still walked as a safety
   net for reflection-wrapped variants.

**Why v1.0 failed:** `XposedBridge.invokeOriginalMethod()` goes through
`Method.invoke()`, which wraps the thrown `SecurityException` in
`InvocationTargetException` once per hooked frame. v1.0 caught only
`SecurityException`, so the wrapped exception escaped and still killed
`system_server`. See the 2026-11-11 13:30:36 crash dump.

It does not touch the kernel, `/system`, `/data`, or any APK. Disabling the
module in LSPosed restores stock behaviour. Keyboard input itself is handled by
the kernel driver + InputManager and does not depend on MiDevAuth.

## Install

1. Install `KBAuthFix.apk`.
2. LSPosed -> Modules -> enable **KB Auth Fix**.
3. Set its scope to **System Framework / `android`** only (the manifest
   already declares `xposedscope=android` as the recommendation).
4. Reboot, then attach the keyboard.

## Verify

```
adb shell logcat -d | grep KBAuthFix
# expect: KBAuthFix: v1.1 loaded in system_server
#         KBAuthFix: hooked KeyboardAuthFeature.startCheckAuth [skip]
#         KBAuthFix: skipped KeyboardAuthFeature.startCheckAuth   (on attach)
adb shell logcat -d | grep "Auth check is start"
adb shell dumpsys dropbox --print system_server_crash | tail
# expect: no NEW system_server_crash entry after attaching the keyboard
```

## Rollback

Disable the module in LSPosed and reboot. If you cannot boot, use KernelSU
safe mode (hold volume-down during boot) to disable all modules, or delete
`/data/adb/modules/zygisk_lsposed` from recovery. This module itself is not a
KernelSU module and cannot cause a boot loop on its own.
