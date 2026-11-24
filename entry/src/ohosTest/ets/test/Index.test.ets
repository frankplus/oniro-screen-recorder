import { UIAbility, Want } from '@kit.AbilityKit';
import { abilityDelegatorRegistry, Component, Driver, ON } from '@kit.TestKit';
import { beforeAll, describe, expect, it } from '@ohos/hypium';

const delegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
const bundleName: string = abilityDelegatorRegistry.getArguments().bundleName;

// UI tests for pages/Index: they start the app's EntryAbility, then drive the
// page through UiTest's Driver.
export default function indexTest() {
  describe('IndexTest', () => {
    beforeAll(async () => {
      const want: Want = { bundleName: bundleName, abilityName: 'EntryAbility' };
      await delegator.startAbility(want);
      await Driver.create().waitForComponent(ON.id('recordButton'), 5000);
    })

    it('showsEntryAbility', 0, async () => {
      const ability: UIAbility = await delegator.getCurrentTopAbility();
      expect(ability.context.abilityInfo.name).assertEqual('EntryAbility');
    })

    it('showsReadyState', 0, async () => {
      const driver: Driver = Driver.create();
      const timer: Component = await driver.findComponent(ON.id('timer'));
      expect(await timer.getText()).assertEqual('Ready');
      const button: Component = await driver.findComponent(ON.id('recordButton'));
      expect(button !== null).assertTrue();
    })
  })
}
