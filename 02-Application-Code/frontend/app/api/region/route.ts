// =============================================================================
// GET /api/region — DR visibility endpoint
// =============================================================================
// Returns which AWS region is currently serving this request. During a DR
// failover demo, hit this endpoint (or watch it) to SEE traffic move from
// us-east-1 to us-west-2 — the value comes from the AWS_REGION env var that
// the Kubernetes deployment injects from the ecommerce-config ConfigMap
// (key: aws_region), so each region's pods report their own region.
//
// Usage:
//   curl https://pip-ecommerce.com/api/region
//   { "region": "us-east-1", "role": "primary", "time": "..." }
//
// force-dynamic so it is never cached — always reflects the live pod's region.
export const dynamic = "force-dynamic";

export async function GET() {
  const region = process.env.AWS_REGION || "unknown";

  // Label the region as primary/DR for an at-a-glance demo readout.
  const role =
    region === "us-east-1" ? "primary"
    : region === "us-west-2" ? "dr"
    : "unknown";

  return Response.json(
    {
      region,
      role,
      time: new Date().toISOString(),
    },
    {
      headers: {
        // Also surface it as a response header so you can see it in curl -I
        // or browser DevTools without parsing the body.
        "x-served-region": region,
        "cache-control": "no-store",
      },
    }
  );
}
