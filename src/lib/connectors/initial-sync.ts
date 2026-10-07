/** Initial discovery only; established cursors keep their existing range. */
export function initialSyncLookbackDays(): number {
  const value = process.env.INITIAL_SYNC_LOOKBACK_DAYS;
  if (!value || !/^[1-9]\d*$/.test(value)) return 3;
  const days = Number(value);
  return days <= 30 ? days : 3;
}
