# Life GTM — owner setup

The app works **solo** out of the box. To switch on multiplayer (accounts, friends, XP gifting), do this once (~10 minutes):

## 1. Create the backend
1. Go to [supabase.com](https://supabase.com) → New project (free tier is plenty to start)
2. **SQL Editor** → paste the entire contents of `setup.sql` → **Run**
3. **Authentication → Providers → Email**: make sure Email is enabled. (OTP codes are on by default.)

## 2. Connect the app
1. **Project Settings → API** → copy the **Project URL** and the **anon public** key
2. Edit `config.js` in this repo (GitHub → open file → pencil icon) and paste both values
3. Commit. Done — the app now shows sign-in, friend codes go live.

## Security model (what protects your users)
- **Row Level Security on every table.** Users can only write their own rows. Full game saves (`saves`) are readable by their owner only.
- **Gifts move through one server function** (`send_gift`) — it checks balance, caps gifts at 50 points each and 100/day per sender, and moves points atomically. There is deliberately **no** insert policy on the gifts table, so the function is the only door.
- **Public profile = safe fields only**: handle, name, code, level, weekly XP, chain. Never email, never game details.
- The **anon key is public by design** — safety comes from RLS, not from hiding the key. Never expose the `service_role` key.
- Handles and friend codes are format-validated at the database level, not just in the app.

## Costs
Free tier: 50k monthly active users' worth of auth, 500MB database. You'll be fine for a long time.

## Roadmap ideas (not built yet)
- LLM-written quests (Supabase Edge Function + Anthropic API key)
- Push notifications (needs a server + user opt-in)
- Leaderboards & squads (a `squads` table + weekly XP snapshots)
- Season 2 auto-generation when week 12 ends
