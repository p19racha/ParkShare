import { createClient } from "npm:@supabase/supabase-js@2.119.2";
import Stripe from "npm:stripe@18.5.0";

function setting(name: string) {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing server setting ${name}`);
  return value;
}

const db = createClient(
  setting("SUPABASE_URL"),
  setting("SUPABASE_SERVICE_ROLE_KEY"),
  {
    auth: { persistSession: false },
  },
);
const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
const stripeClient = stripeKey?.startsWith("sk_test_")
  ? new Stripe(stripeKey, { httpClient: Stripe.createFetchHttpClient() })
  : null;

function payments() {
  if (!stripeClient) {
    throw new ClientError(
      "Reservations and payouts are unavailable in this pilot.",
    );
  }
  return stripeClient;
}

const cryptoProvider = Stripe.createSubtleCryptoProvider();

type Booking = {
  id: string;
  space: string;
  driver: string;
  owner: string;
  rate: number;
  minutes: number;
  stage: string;
  payment: string;
  amount: number;
  intent: string | null;
  destination: string | null;
  hourly_paise?: number | null;
};
class ClientError extends Error {}

async function read<T>(
  query: PromiseLike<{ data: unknown; error: { message: string } | null }>,
) {
  const { data, error } = await query;
  if (error) throw new Error(error.message);
  return data as T;
}

function booking(id: string) {
  return read<Booking>(db.from("bookings").select("*").eq("id", id).single());
}

function advance(id: string, action: string, actor?: string) {
  return read<Booking>(
    db.rpc("advance_booking", { bid: id, action, ...(actor && { actor }) })
      .single(),
  );
}

async function createIntent(b: Booking) {
  const intent = await payments().paymentIntents.create({
    amount: b.rate * b.minutes,
    currency: "usd",
    capture_method: "manual",
    payment_method_types: ["card"],
    transfer_data: { destination: b.destination! },
    metadata: { booking: b.id },
  }, { idempotencyKey: `reserve-${b.id}` });
  await read(db.from("bookings").update({ intent: intent.id }).eq("id", b.id));
  return intent;
}

async function reconcile(b: Booking, initialize = false) {
  b = await advance(b.id, "tick");
  if (!b.intent && b.stage !== "hold") {
    if (b.payment === "release_pending") {
      await read(
        db.from("bookings").update({ payment: "released" }).eq("id", b.id)
          .is("intent", null).eq("payment", "release_pending"),
      );
    }
    b = await booking(b.id);
    if (!b.intent) return b;
  }
  if (!b.intent && !initialize) return b;
  let intent = b.intent
    ? await payments().paymentIntents.retrieve(b.intent)
    : await createIntent(b);
  if (intent.livemode || intent.metadata.booking !== b.id) {
    throw new Error("Payment mismatch");
  }
  if (intent.status === "requires_capture" && b.stage === "hold") {
    await advance(b.id, "authorize");
    b = await advance(b.id, "tick");
  } else {
    b = await booking(b.id);
  }
  if (b.stage === "reserved" && intent.status === "canceled") {
    b = await advance(b.id, "cancel", b.driver);
  }
  switch (b.payment) {
    case "capture_pending":
      if (intent.status === "requires_capture") {
        intent = await payments().paymentIntents.capture(intent.id, {
          amount_to_capture: b.amount,
        }, { idempotencyKey: `capture-${b.id}` });
      }
      if (
        intent.status === "succeeded" && intent.amount_received === b.amount
      ) {
        await read(
          db.from("bookings").update({ payment: "paid" }).eq("id", b.id)
            .eq("payment", "capture_pending"),
        );
      } else if (intent.status === "canceled") {
        await read(
          db.from("bookings").update({ payment: "capture_failed" }).eq(
            "id",
            b.id,
          )
            .eq("payment", "capture_pending"),
        );
      }
      break;
    case "release_pending":
    case "released":
      if (intent.status !== "canceled" && intent.status !== "succeeded") {
        intent = await payments().paymentIntents.cancel(intent.id, {}, {
          idempotencyKey: `release-${b.id}`,
        });
      }
      if (intent.status === "canceled") {
        await read(
          db.from("bookings").update({ payment: "released" }).eq("id", b.id)
            .eq("payment", "release_pending"),
        );
      }
      break;
  }
  return await booking(b.id);
}

function publicBooking(b: Booking) {
  const { intent: _intent, destination: _destination, ...safe } = b;
  return safe;
}

function validateSpace(data: Record<string, unknown>, instructions: unknown) {
  for (const field of ["title", "area", "fit"]) {
    const value = data[field];
    if (typeof value !== "string" || !value.trim() || value.length > 100) {
      throw new ClientError(
        "Enter a title, neighborhood and vehicle size (100 characters each).",
      );
    }
  }
  if (
    typeof instructions !== "string" || !instructions.trim() ||
    instructions.length > 2000
  ) {
    throw new ClientError(
      "Enter private arrival instructions (up to 2,000 characters).",
    );
  }
  const hours = data.hours as Record<string, unknown>;
  if (
    !hours || typeof hours !== "object" || Array.isArray(hours) ||
    Object.keys(hours).some((day) => !/^[1-7]$/.test(day))
  ) {
    throw new ClientError("Set valid weekly opening hours.");
  }
  for (const window of Object.values(hours)) {
    if (
      !Array.isArray(window) || window.length !== 2 ||
      !window.every(Number.isInteger) ||
      window[0] < 0 || window[1] > 1440 || window[1] <= window[0]
    ) {
      throw new ClientError(
        "Each open day must have a start and end time on the same day.",
      );
    }
  }
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: String(data.zone) });
  } catch {
    throw new ClientError("Enter a valid IANA time zone.");
  }
}

async function connectedAccount(
  user: { id: string; email?: string },
  create: boolean,
) {
  let entry = await read<{ stripe_id: string } | null>(
    db.from("host_accounts").select("stripe_id").eq("owner", user.id)
      .maybeSingle(),
  );
  if (!entry && create) {
    const account = await payments().accounts.create({
      type: "express",
      country: "US",
      capabilities: { transfers: { requested: true } },
      metadata: { owner: user.id },
    }, { idempotencyKey: `owner-${user.id}` });
    entry = { stripe_id: account.id };
    await read(db.from("host_accounts").upsert({ owner: user.id, ...entry }));
  }
  return entry?.stripe_id;
}

async function webhook(req: Request) {
  let event: Stripe.Event;
  try {
    event = await payments().webhooks.constructEventAsync(
      await req.text(),
      req.headers.get("stripe-signature") ?? "",
      setting("STRIPE_WEBHOOK_SECRET"),
      undefined,
      cryptoProvider,
    );
  } catch (error) {
    if (
      error instanceof Stripe.errors.StripeSignatureVerificationError ||
      error instanceof SyntaxError
    ) {
      return Response.json({ error: "Invalid webhook signature or body." }, {
        status: 400,
      });
    }
    throw error;
  }
  if (!event.livemode && event.type.startsWith("payment_intent.")) {
    const intent = event.data.object as Stripe.PaymentIntent;
    const id = intent.metadata.booking;
    if (id) {
      const b = await booking(id);
      if (b.intent === intent.id) await reconcile(b);
    }
  }
  return Response.json({ received: true });
}

async function sweep() {
  const now = new Date().toISOString();
  const rows = await read<Booking[]>(
    db.from("bookings").select("*")
      .or(
        `and(stage.in.(hold,reserved,active),expires.lte.${now}),and(stage.eq.hold,intent.not.is.null),payment.eq.capture_pending,payment.eq.release_pending`,
      )
      .order("expires").limit(100),
  );
  const results = await Promise.allSettled(rows.map((b) => reconcile(b)));
  const failures = results.filter((item) => item.status === "rejected");
  for (const failure of failures) {
    const reason = failure.reason;
    console.error(
      "Booking reconciliation failed",
      reason instanceof Error ? reason.name : "Unknown error",
    );
  }
  return { processed: rows.length, failures: failures.length };
}

Deno.serve(async (req) => {
  try {
    const query = new URL(req.url).searchParams;
    if (req.method === "GET" && query.get("auth") === "return") {
      return new Response(
        "Return to ParkShare and sign in after confirming your email.",
        {
          headers: {
            "Content-Type": "text/plain; charset=utf-8",
            "Cache-Control": "no-store",
          },
        },
      );
    }
    const connect = query.get("connect");
    if (
      req.method === "GET" && (connect === "return" || connect === "refresh")
    ) {
      const message = connect === "return"
        ? "Go back to ParkShare and refresh your payout status in Host."
        : "Go back to ParkShare and reopen Stripe onboarding in Host to continue.";
      return new Response(message, {
        headers: {
          "Content-Type": "text/plain; charset=utf-8",
          "Cache-Control": "no-store",
        },
      });
    }
    if (req.method !== "POST") return new Response(null, { status: 405 });
    if (req.headers.has("stripe-signature")) {
      return await webhook(req);
    }
    const body = await req.json();
    if (
      body.action === "sweep" &&
      req.headers.has("x-job-secret") &&
      req.headers.get("x-job-secret") === Deno.env.get("JOB_SECRET")
    ) {
      payments();
      return Response.json(await sweep());
    }
    const token = req.headers.get("Authorization")?.replace(/^Bearer /i, "");
    if (!token) {
      return Response.json({ error: "Sign in first." }, { status: 401 });
    }
    const { data: { user } } = await db.auth.getUser(token);
    if (!user) {
      return Response.json({ error: "Sign in first." }, { status: 401 });
    }

    switch (body.action) {
      case "trips":
      case "host_bookings": {
        await read(db.rpc("expire_inr_bookings"));
        const rows = await read<Booking[]>(
          db.from("bookings").select("*")
            .eq(body.action === "trips" ? "driver" : "owner", user.id)
            .order("created", { ascending: false }).limit(50),
        );
        return Response.json({
          bookings: rows.map(publicBooking),
          now: new Date().toISOString(),
        });
      }
      case "discover": {
        await read(db.rpc("expire_inr_bookings"));
        const spaces = await read(db.rpc("discover_spaces", {
          south: body.south,
          west: body.west,
          north: body.north,
          east: body.east,
        }));
        return Response.json({ spaces });
      }
      case "save": {
        validateSpace(body.space, body.instructions);
        const id = await read(db.rpc("save_space", {
          uid: user.id,
          sid: body.id ?? null,
          data: body.space,
          private_instructions: body.instructions,
        }));
        return Response.json({ id });
      }
      case "onboard": {
        payments();
        const account = await connectedAccount(user, true);
        const returnUrl = Deno.env.get("CONNECT_RETURN_URL") ??
          `${setting("SUPABASE_URL")}/functions/v1/market?connect=return`;
        const refreshUrl = Deno.env.get("CONNECT_REFRESH_URL") ??
          `${setting("SUPABASE_URL")}/functions/v1/market?connect=refresh`;
        const link = await payments().accountLinks.create({
          account: account!,
          type: "account_onboarding",
          return_url: returnUrl,
          refresh_url: refreshUrl,
        });
        return Response.json({ url: link.url });
      }
      case "payouts": {
        payments();
        const id = await connectedAccount(user, false);
        if (!id) {
          return Response.json({ status: "Setup required", payouts: [] });
        }
        const account = await payments().accounts.retrieve(id);
        const payouts = account.payouts_enabled
          ? await payments().payouts.list({ limit: 10 }, { stripeAccount: id })
          : { data: [] };
        return Response.json({
          status: account.payouts_enabled ? "Enabled" : "Onboarding pending",
          payouts: payouts.data.map(({ id, amount, status }) => ({
            id,
            amount,
            status,
          })),
        });
      }
      case "reserve_inr": {
        const b = await read<Booking>(
          db.rpc("reserve_inr_space", {
            sid: body.space,
            uid: user.id,
            duration: body.minutes,
            quoted_paise: body.hourly_paise,
          }).single(),
        );
        return Response.json({ booking: publicBooking(b) });
      }
      case "navigation": {
        const entrance = await read(
          db.rpc("booking_entrance", { bid: body.id, uid: user.id }),
        );
        if (!entrance) {
          throw new ClientError(
            "Arrival details are unavailable for this booking.",
          );
        }
        return Response.json(entrance, {
          headers: { "Cache-Control": "no-store" },
        });
      }
      case "reserve": {
        payments();
        const b = await read<Booking>(
          db.rpc("reserve_space", {
            sid: body.space,
            uid: user.id,
            duration: body.minutes,
            quoted_rate: body.rate,
          }).single(),
        );
        try {
          const intent = await createIntent(b);
          const confirmed = await advance(b.id, "tick");
          if (confirmed.stage !== "hold") {
            await reconcile(confirmed);
            return Response.json({
              booking: publicBooking(confirmed),
              client_secret: null,
            });
          }
          return Response.json({
            booking: publicBooking(confirmed),
            client_secret: intent.client_secret,
          }, { headers: { "Cache-Control": "no-store" } });
        } catch (error) {
          console.error(
            "Payment initialization failed",
            error instanceof Error ? error.name : "Unknown error",
          );
          return Response.json({
            booking: publicBooking(b),
            client_secret: null,
          });
        }
      }
      case "owner_access": {
        const s = await read<{ owner: string }>(
          db.from("spaces").select("owner").eq("id", body.space).single(),
        );
        if (s.owner !== user.id) {
          throw new ClientError("Listing is unavailable.");
        }
        return Response.json(
          await read(
            db.from("space_access").select(
              "instructions,entrance_lat,entrance_lng",
            ).eq(
              "space",
              body.space,
            ).single(),
          ),
        );
      }
      case "sync":
      case "retry_checkout":
      case "start":
      case "end":
      case "cancel":
      case "access": {
        let b = await booking(body.id);
        const isDriver = b.driver === user.id;
        if (!isDriver && b.owner !== user.id) {
          throw new ClientError("Booking is unavailable.");
        }
        if (body.action === "access") {
          const instructions = await read<string | null>(
            db.rpc("booking_access", { bid: b.id, uid: user.id }),
          );
          if (instructions === null) {
            throw new ClientError(
              "Access is available after payment authorization.",
            );
          }
          return Response.json({ instructions }, {
            headers: { "Cache-Control": "no-store" },
          });
        }
        if (body.action === "retry_checkout") {
          payments();
          if (!isDriver || b.stage !== "hold") {
            throw new ClientError("Checkout is unavailable.");
          }
          b = await reconcile(b, true);
          const intent = b.stage === "hold" && b.intent
            ? await payments().paymentIntents.retrieve(b.intent)
            : null;
          return Response.json({
            booking: publicBooking(b),
            client_secret: intent?.client_secret,
          }, { headers: { "Cache-Control": "no-store" } });
        }
        if (body.action === "start") {
          b = await reconcile(b);
        }
        if (body.action !== "sync") {
          b = await advance(b.id, body.action, user.id);
        }
        return Response.json({ booking: publicBooking(await reconcile(b)) });
      }
      default:
        throw new ClientError("Unknown action.");
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "";
    const expected = error instanceof ClientError ||
      /^(This space|This reservation|The selected duration|The price changed|Enter a valid IANA|Listing is occupied|This booking action)/
        .test(message);
    if (!expected) {
      console.error(
        error instanceof Error ? error.name : "Unknown request failure",
      );
    }
    return Response.json({
      error: expected
        ? message
        : "ParkShare could not complete the request. Refresh and try again.",
    }, { status: expected ? 409 : 500 });
  }
});
