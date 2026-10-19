import { authenticateRequest } from '@/lib/api/auth';
import { unauthorized } from '@/lib/api/respond';
// v1 sold the retired $9.99 plan. The new plans are sold only through /api/v2/billing/checkout, so this route is closed
// for good: no body is read, no state is touched and no checkout is created. Old app builds show this message.
export async function POST(request: Request) {
    const context = await authenticateRequest(request);
    if (!context)
        return unauthorized();
    return Response.json({ error: { code: 'billing_unavailable', message: 'This version of Taskforce can no longer start checkout. Update the app to subscribe.' } }, { status: 409, headers: { 'Cache-Control': 'no-store' } });
}
