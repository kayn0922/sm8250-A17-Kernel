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

This module replaces those methods with a wrapper that:

1. calls the **original** method (so a successful bind still performs normal
   keyboard authentication), and
2. catches **only** `SecurityException` and returns a type-correct default.

It does not touch the kernel, `/system`, `/data`, or any APK. Disabling the
module in LSPosed restores stock behaviour.

## Install

1. Install `KBAuthFix.apk`.
2. LSPosed -> Modules -> enable **KB Auth Fix**.
3. Set its scope to **System Framework / `android`** only (the manifest
   already declares `xposedscope=android` as the recommendation).
4. Reboot, then attach the keyboard.

## Verify

```
adb shell logcat -d | grep KBAuthFix
adb shell logcat -d | grep "Auth check is start"
adb shell dumpsys dropbox --print system_server_crash | tail
```

## Rollback

Disable the module in LSPosed and reboot. If you cannot boot, use KernelSU
safe mode (hold volume-down during boot) to disable all modules, or delete
`/data/adb/modules/zygisk_lsposed` from recovery. This module itself is not a
KernelSU module and cannot cause a boot loop on its own.
