import { authenticateRequest } from "@/lib/api/auth";
import { handleGetProfile, handlePutProfile } from "@/lib/api/profile";
import { loadProfile, saveProfile } from "@/lib/api/profile-store";

const deps = { authenticate: authenticateRequest, load: loadProfile, save: saveProfile };

export async function GET(request: Request) {
  return handleGetProfile(request, deps);
}

export async function PUT(request: Request) {
  return handlePutProfile(request, deps);
}
