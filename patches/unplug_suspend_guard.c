// SPDX-License-Identifier: GPL-2.0-only
/*
 * unplug_suspend_guard.c
 *
 * Kernel-space workaround for the sm8250 (Xiaomi Pad 5 Pro, elish/enuma)
 * reboot that happens when the USB cable is unplugged AND the device enters
 * deep sleep at the same time.
 *
 * Root cause (observed in dmesg on this device): after unplug, the
 * charger / fuel-gauge state machine (bq2597x charging pump, pm8150b smblib
 * charger, dual_fuel_gauge) is left in an inconsistent state -- the fuel
 * gauge still reports ~1661 mA of charging current several seconds after
 * unplug, and smblib_suspend_on_debug_battery returns -EINVAL. When the
 * device then suspends, the suspend/resume path races (WiFi is spuriously
 * woken by hif_wake_interrupt_handler, etc.) and the SoC silently resets.
 *
 * Workaround (identical in effect to the proven userspace wakelock daemon):
 * hold a suspend wakelock (kernel wakeup_source) for as long as USB is
 * unplugged. This keeps the device out of deep sleep while unplugged, so the
 * inconsistent charger/FG state never has to survive a suspend -> no reboot.
 * On plug-in the wakelock is released and normal deep sleep resumes.
 *
 * This is a self-contained, additive driver: it does NOT touch any charger,
 * PD or fuel-gauge logic, so it cannot break charging or other features.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/notifier.h>
#include <linux/power_supply.h>
#include <linux/pm_wakeup.h>
#include <linux/workqueue.h>
#include <linux/slab.h>
#include <linux/mutex.h>

#define DRV_NAME "unplug_suspend_guard"
#define USB_PSY_NAME "usb"

static bool hold_while_unplugged = true;
module_param(hold_while_unplugged, bool, 0644);
MODULE_PARM_DESC(hold_while_unplugged,
	"Hold a suspend wakelock while USB is unplugged to avoid the unplug+deep-sleep reboot");

static struct wakeup_source *usg_ws;
static struct notifier_block psy_nb;
static struct work_struct eval_work;
static DEFINE_MUTEX(state_lock);
static bool held;
static int last_online = -1;

static void usg_evaluate(void)
{
	struct power_supply *psy;
	union power_supply_propval val;
	int online = 0;

	if (!hold_while_unplugged)
		return;

	psy = power_supply_get_by_name(USB_PSY_NAME);
	if (psy) {
		if (power_supply_get_property(psy, POWER_SUPPLY_PROP_ONLINE,
					      &val) == 0)
			online = val.intval ? 1 : 0;
		power_supply_put(psy);
	}

	mutex_lock(&state_lock);
	if (online != last_online) {
		last_online = online;
		if (online == 0 && !held) {
			__pm_stay_awake(usg_ws);
			held = true;
			pr_info("%s: USB unplugged -> holding suspend wakelock (no deep sleep while unplugged)\n",
				DRV_NAME);
		} else if (online != 0 && held) {
			__pm_relax(usg_ws);
			held = false;
			pr_info("%s: USB plugged -> releasing suspend wakelock\n",
				DRV_NAME);
		}
	}
	mutex_unlock(&state_lock);
}

static void usg_eval_work(struct work_struct *work)
{
	usg_evaluate();
}

static int usg_psy_notify(struct notifier_block *nb, unsigned long action,
			  void *data)
{
	schedule_work(&eval_work);
	return NOTIFY_OK;
}

static int __init usg_init(void)
{
	usg_ws = wakeup_source_create(DRV_NAME);
	if (!usg_ws)
		return -ENOMEM;
	wakeup_source_add(usg_ws);

	INIT_WORK(&eval_work, usg_eval_work);
	psy_nb.notifier_call = usg_psy_notify;

	power_supply_reg_notifier(&psy_nb);
	usg_evaluate();	/* handle the boot-time state (already unplugged?) */

	pr_info("%s: loaded (guard against unplug+deep-sleep reboot; hold_while_unplugged=%d)\n",
		DRV_NAME, hold_while_unplugged);
	return 0;
}

static void __exit usg_exit(void)
{
	power_supply_unreg_notifier(&psy_nb);
	cancel_work_sync(&eval_work);
	mutex_lock(&state_lock);
	if (held) {
		__pm_relax(usg_ws);
		held = false;
	}
	mutex_unlock(&state_lock);
	wakeup_source_remove(usg_ws);
	wakeup_source_destroy(usg_ws);
	pr_info("%s: unloaded\n", DRV_NAME);
}

module_init(usg_init);
module_exit(usg_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("kayn0922");
MODULE_DESCRIPTION("Hold a suspend wakelock while USB is unplugged to avoid the unplug+deep-sleep reboot on sm8250");
