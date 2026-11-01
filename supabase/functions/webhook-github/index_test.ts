import { assertEquals } from "jsr:@std/assert@1.0.8";

Deno.test("webhook signature: accepts GitHub's HMAC, rejects tampering", async () => {
  // Importing index.ts would start Deno.serve; re-declare the same check here.
  const { verifySignature } = await import("./signature.ts");
  const secret = "It's a Secret to Everybody";
  const body = "Hello, World!";
  // Example from GitHub docs ("Validating webhook deliveries").
  const header =
    "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17";
  assertEquals(await verifySignature(secret, body, header), true);
  assertEquals(await verifySignature(secret, body + " ", header), false);
  assertEquals(await verifySignature(secret, body, null), false);
});
