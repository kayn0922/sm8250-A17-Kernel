#!/usr/bin/env python3
"""
Rewrite ONLY the root-solution section of the upstream build.sh to use
SukiSU-Nova instead of ReSukiSU/BakaSU.

Everything else (MIUI DTS panel edits, MAKE_ARGS, toolchain, AnyKernel3
packing, Baseband-guard, unplug-guard kernel patches applied earlier by
apply_patches.sh) is left byte-for-byte identical to the 7119 baseline.

Invoked from apply_patches.sh only when USG_ROOT_NOVA=1 (i.e. ksu=nova).

Why a separate root stack instead of a URL swap:
  * ReSukiSU (BakaSU) uses syscall-hook (KSU_NONE_HOOK/KSU_MANUAL_HOOK) and
    needs JackA1ltman's syscall_hook_patches.sh to inject ksu_handle_* calls
    into kernel source, plus an EXTERNAL KPM binary patch on the built Image.
  * SukiSU-Nova uses kprobes-based hooks built into its own kernel/ source.
    It has NO KSU_MULTI_MANAGER_SUPPORT / KSU_SUSFS / KSU_NONE_HOOK /
    KSU_MANUAL_HOOK symbols; KSU depends on KPROBES && EXT4_FS; KPM is
    compiled into kernelsu.ko (NOT an external patch_linux on the Image).
  Feeding Nova the ReSukiSU hook patches would fail to compile (missing
  ksu_handle_* symbols) and the external KPM patch would corrupt the Image.

To avoid the flaky self-hosted git server in Nova's setup.sh
(git.zako.shirkneko.top:20004), we clone the GitHub mirror directly and
replicate the official kernel/setup.sh symlink/Kconfig wiring inline.
"""
import sys

p = sys.argv[1]
s = open(p, encoding="utf-8").read()
changes = []


def sub(old, new, tag, count=1):
    """Exact, uniqueness-checked replacement; abort loudly on anchor drift."""
    global s
    n = s.count(old)
    if n != count:
        print("[nova][FATAL] %s: anchor count %d (expected %d)" % (tag, n, count))
        sys.exit(1)
    s = s.replace(old, new, count)
    changes.append(tag)


# ---------------------------------------------------------------------------
# 1) KSU_ENABLE: count "nova" as a KSU build
# ---------------------------------------------------------------------------
sub(
    'KSU_ENABLE=$([[ "$KSU_VERSION" == "ksu" || "$KSU_VERSION" == "rksu" ]] && echo 1 || echo 0)',
    'KSU_ENABLE=$([[ "$KSU_VERSION" == "ksu" || "$KSU_VERSION" == "rksu" || "$KSU_VERSION" == "nova" ]] && echo 1 || echo 0)',
    "KSU_ENABLE includes nova",
)

# ---------------------------------------------------------------------------
# 2) case "$KSU_VERSION" -> add a nova branch before the default (*) branch.
#    clone the GitHub mirror, symlink kernel/ -> drivers/kernelsu, wire
#    drivers/Makefile + drivers/Kconfig exactly like Nova's official setup.sh.
# ---------------------------------------------------------------------------
nova_branch = '''    nova)
        KSU_ZIP_STR=SukiSU_Nova
        echo "SukiSU-Nova is enabled"
        # Clone the GitHub mirror of SukiSU-Nova (its kernel/ dir is the
        # ready-to-integrate KernelSU driver source). We deliberately do NOT
        # use Nova's kernel/setup.sh: it clones a self-hosted git server
        # (git.zako.shirkneko.top:20004) that is unreliable from GitHub Actions.
        if [ ! -d "KernelSU" ]; then
            git clone https://github.com/SukiSU-Nova/SukiSU-Nova.git -b main --depth=1 KernelSU
        fi
        # Replicate Nova kernel/setup.sh wiring: symlink kernel/ -> drivers/kernelsu.
        # Use a plain relative path from drivers/ (../KernelSU/kernel). Do NOT cd
        # into drivers before resolving it: in v1 realpath then looked for
        # drivers/KernelSU/kernel (nonexistent) and ln failed -> build aborted.
        if [ ! -d KernelSU/kernel ]; then
            echo "[nova][FATAL] KernelSU/kernel missing after clone"; ls -la KernelSU | head; exit 1
        fi
        ln -sfn ../KernelSU/kernel drivers/kernelsu
        grep -q 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile || printf '\\nobj-$(CONFIG_KSU) += kernelsu/\\n' >> drivers/Makefile
        grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig || sed -i '/endmenu/i\\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
        # 4.19 compat: Nova core/init.c calls MODULE_IMPORT_NS() (a 5.3+ macro)
        # in its #else branch. This 4.19 kernel has no such macro, so clang 22
        # reads it as an implicit-int function and dies on -Werror. The 6.13+
        # branch is the quoted string form; delete ONLY the unquoted token-form
        # line so the #else branch becomes empty on 4.19 (no VFS namespace need).
        sed -i '/MODULE_IMPORT_NS(VFS_internal/d' KernelSU/kernel/core/init.c
        if grep -q 'MODULE_IMPORT_NS(VFS_internal' KernelSU/kernel/core/init.c; then
            echo "[nova][FATAL] MODULE_IMPORT_NS compat strip failed"; exit 1
        fi
        # Nova's Kbuild queries its self-hosted server for version strings.
        # Those calls are cosmetic only; bound them so GitHub Actions cannot
        # hang for minutes on an unreachable host.
        sed -i 's#$(CURL_BIN) -s "#$(CURL_BIN) -s --connect-timeout 5 --max-time 8 "#g; s#$(CURL_BIN) -s -D#$(CURL_BIN) -s --connect-timeout 5 --max-time 8 -D#g' KernelSU/kernel/Kbuild
        ;;
'''
sub(
    '    *)\n        KSU_ZIP_STR=NoKernelSU\n',
    nova_branch + '    *)\n        KSU_ZIP_STR=NoKernelSU\n',
    "add nova case branch",
)

# ---------------------------------------------------------------------------
# 3) Skip JackA1ltman syscall-hook/backport patches for Nova. Those inject
#    ksu_handle_* calls into kernel source for BakaSU's manual-hook model;
#    Nova's kprobes hooks don't use them and would fail to compile.
#    Anchor the bare CALL line (with surrounding newlines) so the function
#    definition "execute_ksu_patch_scripts() {" is not matched.
# ---------------------------------------------------------------------------
sub(
    '\nexecute_ksu_patch_scripts\n',
    '\nif [ "$KSU_VERSION" = "nova" ]; then\n'
    '    echo "[nova] skip JackA1ltman syscall-hook/backport patches (Nova uses built-in kprobes hooks)"\n'
    'else\n'
    '    execute_ksu_patch_scripts\n'
    'fi\n',
    "skip legacy hook patches for nova",
)

# ---------------------------------------------------------------------------
# 4) SET_CONFIG(): Nova Kconfig options.
#    KSU depends on KPROBES && EXT4_FS; KSU_MANUAL_SU (default y); KPM is
#    built into kernelsu.ko and auto-selects KALLSYMS/KALLSYMS_ALL.
#    Do NOT set ReSukiSU-only symbols (KSU_MULTI_MANAGER_SUPPORT etc.).
# ---------------------------------------------------------------------------
old_cfg = '''    if [ "$KSU_ENABLE" -eq 1 ]; then
        scripts/config --file out/.config -e KSU
        scripts/config --file out/.config -e KSU_MULTI_MANAGER_SUPPORT
    else
        scripts/config --file out/.config -d KSU
    fi
'''
new_cfg = '''    if [ "$KSU_VERSION" = "nova" ]; then
        # Nova: KSU depends on KPROBES && EXT4_FS; KPM compiles into kernelsu.ko.
        scripts/config --file out/.config -e KPROBES
        scripts/config --file out/.config -e EXT4_FS
        scripts/config --file out/.config -e KSU
        scripts/config --file out/.config -e KSU_MANUAL_SU
        scripts/config --file out/.config -e KPM
        scripts/config --file out/.config -e KALLSYMS
        scripts/config --file out/.config -e KALLSYMS_ALL
    elif [ "$KSU_ENABLE" -eq 1 ]; then
        scripts/config --file out/.config -e KSU
        scripts/config --file out/.config -e KSU_MULTI_MANAGER_SUPPORT
    else
        scripts/config --file out/.config -d KSU
    fi
'''
sub(old_cfg, new_cfg, "SET_CONFIG nova Kconfig branch")

# ---------------------------------------------------------------------------
# 5) Image_Repack(): the external KPM patch is already gated on
#    KSU_VERSION == "ksu" upstream, so nova skips it automatically. Assert
#    that gate still exists (if upstream changes it, abort rather than risk
#    corrupting the Nova Image with ReSukiSU's patch_linux).
# ---------------------------------------------------------------------------
if 'if [[ "$KPM_ENABLE" -eq 1 && "$KSU_VERSION" == "ksu" ]]; then' not in s:
    print("[nova][FATAL] external KPM patch gate changed upstream; refusing to build")
    sys.exit(1)
changes.append("external KPM patch gate verified (nova skips it)")

open(p, "w", encoding="utf-8").write(s)
print("[nova] build.sh root section rewritten: " + "; ".join(changes))
