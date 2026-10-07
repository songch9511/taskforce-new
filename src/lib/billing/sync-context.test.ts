import { expect,it,vi } from 'vitest';
import { inBillingSync,withBillingSync } from './sync-context';
vi.mock('server-only',()=>({}));
it('sync admission is scoped to the current async account and never survives callback completion',async()=>{
 expect(inBillingSync('alice')).toBe(false);
 await Promise.all(['alice','bob'].map(user=>withBillingSync(user,async()=>{
  await Promise.resolve();expect(inBillingSync(user)).toBe(true);expect(inBillingSync(user==='alice'?'bob':'alice')).toBe(false);
 })));
 expect(inBillingSync('alice')).toBe(false);
 await expect(withBillingSync('alice',async()=>{throw new Error('failed sync');})).rejects.toThrow('failed sync');
 expect(inBillingSync('alice')).toBe(false);
});
