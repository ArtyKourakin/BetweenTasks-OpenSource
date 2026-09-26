-- Karma Rewards: automatic payouts (additive only). All switches default OFF.

ALTER TABLE public.reward_settings
  ADD COLUMN IF NOT EXISTS auto_approve_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS auto_payout_enabled  boolean NOT NULL DEFAULT false;

CREATE TABLE public.reward_auto_broadcasts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.reward_payout_batches(id),
  payout_ids uuid[] NOT NULL,
  transfer_indexes text[] NOT NULL,
  signature text NOT NULL UNIQUE,
  signed_tx_base64 text NOT NULL,
  recent_blockhash text NOT NULL,
  last_valid_block_height bigint NOT NULL,
  total_lamports bigint NOT NULL CHECK (total_lamports > 0),
  state text NOT NULL DEFAULT 'prepared'
    CHECK (state IN ('prepared','broadcast','finalized','failed','expired')),
  attempt_count integer NOT NULL DEFAULT 0,
  error_code text,
  created_at timestamptz NOT NULL DEFAULT now(),
  broadcast_at timestamptz,
  finalized_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (cardinality(payout_ids) = cardinality(transfer_indexes) AND cardinality(payout_ids) > 0)
);
GRANT ALL ON public.reward_auto_broadcasts TO service_role;
ALTER TABLE public.reward_auto_broadcasts ENABLE ROW LEVEL SECURITY;
CREATE INDEX reward_auto_broadcasts_open_idx ON public.reward_auto_broadcasts (state)
  WHERE state IN ('prepared','broadcast');
CREATE TRIGGER reward_auto_broadcasts_updated_at BEFORE UPDATE ON public.reward_auto_broadcasts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- A payout may appear in at most one open (prepared/broadcast) transaction.
CREATE TABLE public.reward_auto_broadcast_payouts (
  broadcast_id uuid NOT NULL REFERENCES public.reward_auto_broadcasts(id),
  payout_id uuid NOT NULL REFERENCES public.reward_payouts(id),
  transfer_index text NOT NULL,
  is_open boolean NOT NULL DEFAULT true,
  PRIMARY KEY (broadcast_id, payout_id)
);
CREATE UNIQUE INDEX reward_auto_broadcast_payouts_one_open
  ON public.reward_auto_broadcast_payouts (payout_id) WHERE is_open;
GRANT ALL ON public.reward_auto_broadcast_payouts TO service_role;
ALTER TABLE public.reward_auto_broadcast_payouts ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.reward_worker_leases (
  name text PRIMARY KEY,
  holder text NOT NULL,
  expires_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.reward_worker_leases TO service_role;
ALTER TABLE public.reward_worker_leases ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.reward_try_lease(p_name text, p_holder text, p_seconds integer)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ok boolean;
BEGIN
  INSERT INTO public.reward_worker_leases (name, holder, expires_at)
  VALUES (p_name, p_holder, now() + make_interval(secs => p_seconds))
  ON CONFLICT (name) DO UPDATE
    SET holder = EXCLUDED.holder, expires_at = EXCLUDED.expires_at, updated_at = now()
    WHERE reward_worker_leases.expires_at < now() OR reward_worker_leases.holder = p_holder
  RETURNING true INTO v_ok;
  RETURN COALESCE(v_ok, false);
END; $$;

CREATE OR REPLACE FUNCTION public.reward_release_lease(p_name text, p_holder text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE public.reward_worker_leases SET expires_at = now() - interval '1 second', updated_at = now()
  WHERE name = p_name AND holder = p_holder;
$$;

-- Atomic save BEFORE broadcast: broadcast row + payout mapping + payouts -> submitted.
CREATE OR REPLACE FUNCTION public.reward_record_broadcast(
  p_batch_id uuid, p_payout_ids uuid[], p_transfer_indexes text[], p_signature text,
  p_signed_tx text, p_blockhash text, p_last_valid bigint, p_total bigint)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_n integer; i integer;
BEGIN
  SELECT count(*) INTO v_n FROM public.reward_payouts
   WHERE id = ANY(p_payout_ids) AND batch_id = p_batch_id AND status = 'pending'
   FOR UPDATE;
  IF v_n <> cardinality(p_payout_ids) THEN RAISE EXCEPTION 'payouts_not_pending'; END IF;
  IF p_total <> (SELECT sum(lamports) FROM public.reward_payouts WHERE id = ANY(p_payout_ids)) THEN
    RAISE EXCEPTION 'total_mismatch';
  END IF;
  INSERT INTO public.reward_auto_broadcasts
    (batch_id, payout_ids, transfer_indexes, signature, signed_tx_base64,
     recent_blockhash, last_valid_block_height, total_lamports)
  VALUES (p_batch_id, p_payout_ids, p_transfer_indexes, p_signature, p_signed_tx,
          p_blockhash, p_last_valid, p_total)
  RETURNING id INTO v_id;
  FOR i IN 1..cardinality(p_payout_ids) LOOP
    INSERT INTO public.reward_auto_broadcast_payouts (broadcast_id, payout_id, transfer_index)
    VALUES (v_id, p_payout_ids[i], p_transfer_indexes[i]);
  END LOOP;
  UPDATE public.reward_payouts
     SET status = 'submitted', tx_signature = p_signature, submitted_at = now()
   WHERE id = ANY(p_payout_ids);
  RETURN v_id;
END; $$;

-- Close a broadcast (finalized / failed / expired). Failed or expired releases payouts to pending.
CREATE OR REPLACE FUNCTION public.reward_close_broadcast(p_id uuid, p_state text, p_error text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v public.reward_auto_broadcasts%ROWTYPE;
BEGIN
  IF p_state NOT IN ('finalized','failed','expired') THEN RAISE EXCEPTION 'bad_state'; END IF;
  SELECT * INTO v FROM public.reward_auto_broadcasts WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'broadcast_not_found'; END IF;
  IF v.state NOT IN ('prepared','broadcast') THEN RETURN; END IF;
  UPDATE public.reward_auto_broadcasts
     SET state = p_state, error_code = p_error,
         finalized_at = CASE WHEN p_state = 'finalized' THEN now() END
   WHERE id = p_id;
  UPDATE public.reward_auto_broadcast_payouts SET is_open = false WHERE broadcast_id = p_id;
  IF p_state <> 'finalized' THEN
    UPDATE public.reward_payouts
       SET status = 'pending', tx_signature = NULL, submitted_at = NULL, last_failure_code = p_error
     WHERE id = ANY(v.payout_ids) AND status = 'submitted' AND tx_signature = v.signature;
  END IF;
END; $$;

REVOKE ALL ON FUNCTION public.reward_try_lease(text,text,integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reward_release_lease(text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reward_record_broadcast(uuid,uuid[],text[],text,text,text,bigint,bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reward_close_broadcast(uuid,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reward_try_lease(text,text,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.reward_release_lease(text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.reward_record_broadcast(uuid,uuid[],text[],text,text,text,bigint,bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.reward_close_broadcast(uuid,text,text) TO service_role;
