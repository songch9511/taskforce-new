import 'server-only';
import { AsyncLocalStorage } from 'node:async_hooks';

// A failed first sync may retry its bounded $1 work after onboarding expires.
// This scope cannot be supplied by an HTTP caller and never covers standalone AI.
const syncAccount = new AsyncLocalStorage<string>();
export const inBillingSync = (userId: string) => syncAccount.getStore() === userId;
export function withBillingSync<T>(userId: string, run: () => Promise<T>): Promise<T> {
  return syncAccount.run(userId, run);
}
