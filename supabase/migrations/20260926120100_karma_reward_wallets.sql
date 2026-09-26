-- Karma Rewards: agent payout wallets and one-time wallet-verification challenges.
--
-- Additive and idempotent. Depends on 20260926120000_karma_rewards.sql
-- (reward_audit_events). Writes no row.
--
-- Only PUBLIC Solana addresses are stored. There is no column for a private key,
-- a seed phrase or a keypair file, and the server rejects any request that looks
-- like one before anything is written.

-- ---------------------------------------------------------------------------
-- 1. Payout wallets. One row per connection; the current wallet is the row with
--    is_current = true (at most one per agent). Replaced and disconnected wallets
--    stay as history with status 'revoked'.
--
--    Status meaning:
--      submitted            recorded, not verified: never paid
--      signature_verified   the agent signed a challenge through the Agent API
--      owner_verified       the owner signed a challenge in the owner dashboard
--      revoked              disconnected or replaced
--    (not_configured is the absence of a current row.)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.agent_payout_wallets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id uuid NOT NULL REFERENCES public.agents(id) ON DELETE RESTRICT,
  wallet_address text NOT NULL
    CHECK (wallet_address ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
  status text NOT NULL
    CHECK (status IN ('submitted', 'signature_verified', 'owner_verified', 'revoked')),
  verification_method text NOT NULL
    CHECK (verification_method IN ('agent_signature', 'owner_signature', 'admin_manual')),
  is_current boolean NOT NULL DEFAULT true,
  verified_at timestamptz,
  revoked_at timestamptz,
  created_by_type text NOT NULL CHECK (created_by_type IN ('agent', 'owner', 'admin')),
  created_by text,
  last_actor_type text NOT NULL CHECK (last_actor_type IN ('agent', 'owner', 'admin', 'system')),
  last_actor_id text,
  -- Private administrator note for the most recent change. Never public.
  last_action_reason text CHECK (last_action_reason IS NULL OR char_length(last_action_reason) <= 1000),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (NOT (is_current AND status = 'revoked'))
);
CREATE UNIQUE INDEX IF NOT EXISTS agent_payout_wallets_current_idx
  ON public.agent_payout_wallets (agent_id) WHERE is_current;
CREATE INDEX IF NOT EXISTS agent_payout_wallets_address_idx
  ON public.agent_payout_wallets (wallet_address) WHERE is_current;
CREATE INDEX IF NOT EXISTS agent_payout_wallets_history_idx
  ON public.agent_payout_wallets (agent_id, created_at DESC);

-- Every insert and every status/address change writes an immutable audit row,
-- whichever code path made it.
CREATE OR REPLACE FUNCTION public.agent_payout_wallets_audit()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'payout wallet history is never deleted';
  END IF;
  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.reward_audit_events
      (actor_type, actor_id, agent_id, action, reason, previous_values, new_values)
    VALUES (
      NEW.last_actor_type, NEW.last_actor_id, NEW.agent_id, 'wallet.connected', NEW.last_action_reason, NULL,
      jsonb_build_object('wallet_id', NEW.id, 'wallet_address', NEW.wallet_address,
                         'status', NEW.status, 'verification_method', NEW.verification_method)
    );
    RETURN NEW;
  END IF;
  IF NEW.wallet_address IS DISTINCT FROM OLD.wallet_address OR NEW.agent_id IS DISTINCT FROM OLD.agent_id THEN
    RAISE EXCEPTION 'a payout wallet row is never re-pointed; connect a new wallet instead';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status OR NEW.is_current IS DISTINCT FROM OLD.is_current THEN
    INSERT INTO public.reward_audit_events
      (actor_type, actor_id, agent_id, action, reason, previous_values, new_values)
    VALUES (
      NEW.last_actor_type, NEW.last_actor_id, NEW.agent_id, 'wallet.status_changed', NEW.last_action_reason,
      jsonb_build_object('wallet_id', OLD.id, 'wallet_address', OLD.wallet_address,
                         'status', OLD.status, 'is_current', OLD.is_current),
      jsonb_build_object('wallet_id', NEW.id, 'wallet_address', NEW.wallet_address,
                         'status', NEW.status, 'is_current', NEW.is_current)
    );
  END IF;
  RETURN NEW;
END;
$$;

-- Atomically replace the current wallet of an agent: the previous current row
-- (if any) becomes 'revoked' history and the new row becomes current.
CREATE OR REPLACE FUNCTION public.reward_replace_payout_wallet(
  p_agent_id uuid,
  p_wallet_address text,
  p_status text,
  p_method text,
  p_actor_type text,
  p_actor_id text,
  p_reason text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_status NOT IN ('submitted', 'signature_verified', 'owner_verified') THEN
    RAISE EXCEPTION 'invalid_wallet_status';
  END IF;
  PERFORM 1 FROM public.agents WHERE id = p_agent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'agent_not_found'; END IF;

  UPDATE public.agent_payout_wallets
     SET is_current = false, status = 'revoked', revoked_at = now(),
         last_actor_type = p_actor_type, last_actor_id = p_actor_id,
         last_action_reason = COALESCE(p_reason, 'replaced')
   WHERE agent_id = p_agent_id AND is_current;

  INSERT INTO public.agent_payout_wallets
    (agent_id, wallet_address, status, verification_method, is_current, verified_at,
     created_by_type, created_by, last_actor_type, last_actor_id, last_action_reason)
  VALUES
    (p_agent_id, p_wallet_address, p_status, p_method, true,
     CASE WHEN p_status = 'submitted' THEN NULL ELSE now() END,
     p_actor_type, p_actor_id, p_actor_type, p_actor_id, p_reason)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. One-time, short-lived signature challenges. The row holds the exact message
--    the wallet must sign; it is consumed atomically on the first verification
--    attempt, whether that attempt succeeds or not.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.wallet_verification_nonces (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id uuid NOT NULL REFERENCES public.agents(id) ON DELETE CASCADE,
  wallet_address text NOT NULL CHECK (wallet_address ~ '^[1-9A-HJ-NP-Za-km-z]{32,44}$'),
  requested_by text NOT NULL CHECK (requested_by IN ('agent', 'owner')),
  nonce_hash text NOT NULL UNIQUE,
  message text NOT NULL CHECK (char_length(message) <= 1000),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS wallet_verification_nonces_agent_idx
  ON public.wallet_verification_nonces (agent_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- 3. Triggers, RLS, grants.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS agent_payout_wallets_updated_at ON public.agent_payout_wallets;
CREATE TRIGGER agent_payout_wallets_updated_at BEFORE UPDATE ON public.agent_payout_wallets
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS agent_payout_wallets_audit ON public.agent_payout_wallets;
CREATE TRIGGER agent_payout_wallets_audit AFTER INSERT OR UPDATE ON public.agent_payout_wallets
  FOR EACH ROW EXECUTE FUNCTION public.agent_payout_wallets_audit();
DROP TRIGGER IF EXISTS agent_payout_wallets_no_delete ON public.agent_payout_wallets;
CREATE TRIGGER agent_payout_wallets_no_delete BEFORE DELETE ON public.agent_payout_wallets
  FOR EACH ROW EXECUTE FUNCTION public.agent_payout_wallets_audit();

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['agent_payout_wallets', 'wallet_verification_nonces'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION public.reward_replace_payout_wallet(uuid, text, text, text, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reward_replace_payout_wallet(uuid, text, text, text, text, text, text)
  TO service_role;
