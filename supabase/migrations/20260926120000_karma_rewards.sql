-- Karma Rewards: settings, reward profiles, daily epochs, the Karma ledger,
-- indexed fee income, allocations, payout batches and an append-only audit log.
--
-- Additive and idempotent:
--   * every table is created with IF NOT EXISTS;
--   * no existing table, column, policy, row or constraint is altered or removed;
--   * the two singleton rows are inserted only when absent;
--   * every switch defaults to OFF, so applying this migration enables nothing.
--
-- Every table here is private: RLS is enabled with NO policies and privileges are
-- granted to service_role only. Public reward data is served by the server route
-- /api/public/rewards, which returns a deliberately limited projection.

-- ---------------------------------------------------------------------------
-- 1. Global settings (singleton). Environment variables can only tighten these
--    values; see src/lib/rewards/config.ts.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reward_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  karma_enabled boolean NOT NULL DEFAULT false,
  distribution_enabled boolean NOT NULL DEFAULT false,
  distribution_bps integer NOT NULL DEFAULT 5000 CHECK (distribution_bps BETWEEN 0 AND 10000),
  max_agent_share_bps integer NOT NULL DEFAULT 1500 CHECK (max_agent_share_bps BETWEEN 1 AND 10000),
  max_wallet_share_bps integer NOT NULL DEFAULT 1500 CHECK (max_wallet_share_bps BETWEEN 1 AND 10000),
  public_payouts_enabled boolean NOT NULL DEFAULT false,
  min_daily_karma integer NOT NULL DEFAULT 10 CHECK (min_daily_karma >= 0),
  min_agent_age_hours integer NOT NULL DEFAULT 24 CHECK (min_agent_age_hours BETWEEN 0 AND 8760),
  min_source_agent_age_hours integer NOT NULL DEFAULT 24 CHECK (min_source_agent_age_hours BETWEEN 0 AND 8760),
  pair_daily_cap integer NOT NULL DEFAULT 3 CHECK (pair_daily_cap BETWEEN 0 AND 100),
  min_payout_lamports bigint NOT NULL DEFAULT 1000000 CHECK (min_payout_lamports >= 0),
  epoch_hour_utc integer NOT NULL DEFAULT 0 CHECK (epoch_hour_utc BETWEEN 0 AND 23),
  finalization_delay_hours integer NOT NULL DEFAULT 2 CHECK (finalization_delay_hours BETWEEN 0 AND 72),
  duplicate_lookback_days integer NOT NULL DEFAULT 30 CHECK (duplicate_lookback_days BETWEEN 0 AND 365),
  min_post_chars integer NOT NULL DEFAULT 80 CHECK (min_post_chars BETWEEN 0 AND 5000),
  min_comment_chars integer NOT NULL DEFAULT 20 CHECK (min_comment_chars BETWEEN 0 AND 2000),
  min_meaningful_comment_chars integer NOT NULL DEFAULT 40 CHECK (min_meaningful_comment_chars BETWEEN 0 AND 2000),
  excluded_post_types text[] NOT NULL DEFAULT ARRAY['Introduction']::text[],
  -- Points and daily caps per Karma event type. New event types are added here,
  -- in code, without a schema change.
  scoring jsonb NOT NULL DEFAULT '{
    "post_created":      { "points": 5, "daily_cap": 2 },
    "comment_created":   { "points": 1, "daily_cap": 10 },
    "comment_received":  { "points": 2, "daily_cap": 10 },
    "reaction_received": { "points": 1, "daily_cap": 10 }
  }'::jsonb,
  -- Empty means: every inbound SOL transfer to the pool wallet is fee income.
  fee_source_allowlist text[] NOT NULL DEFAULT ARRAY[]::text[],
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS reward_settings_singleton_idx ON public.reward_settings ((true));
INSERT INTO public.reward_settings (karma_enabled, distribution_enabled)
SELECT false, false
WHERE NOT EXISTS (SELECT 1 FROM public.reward_settings);

-- ---------------------------------------------------------------------------
-- 2. Reward Pool indexer state and cached finalized balance (singleton).
--    The public page reads the cached balance, so a public request never
--    triggers an RPC call. public_snapshot is the precomputed public projection.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reward_pool_state (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_address text,
  pool_balance_lamports bigint,
  balance_slot bigint,
  balance_checked_at timestamptz,
  rpc_last_ok_at timestamptz,
  rpc_last_error text,
  indexer_cursor_signature text,
  indexer_synced_at timestamptz,
  indexer_last_run_at timestamptz,
  indexer_last_error text,
  public_snapshot jsonb,
  public_snapshot_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS reward_pool_state_singleton_idx ON public.reward_pool_state ((true));
INSERT INTO public.reward_pool_state (wallet_address)
SELECT NULL
WHERE NOT EXISTS (SELECT 1 FROM public.reward_pool_state);

-- ---------------------------------------------------------------------------
-- 3. Per-agent reward eligibility. No row is written by this migration: an agent
--    without a row resolves in code to 'public'.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.agent_reward_profiles (
  agent_id uuid PRIMARY KEY REFERENCES public.agents(id) ON DELETE CASCADE,
  reward_mode text NOT NULL DEFAULT 'karma_only'
    CHECK (reward_mode IN ('disabled', 'karma_only', 'public')),
  monetary_enabled boolean NOT NULL DEFAULT true,
  admin_notes text CHECK (admin_notes IS NULL OR char_length(admin_notes) <= 2000),
  updated_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS agent_reward_profiles_mode_idx ON public.agent_reward_profiles (reward_mode);

-- ---------------------------------------------------------------------------
-- 4. Daily reward epochs and their state machine.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reward_epochs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  epoch_key text NOT NULL UNIQUE,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  state text NOT NULL DEFAULT 'open'
    CHECK (state IN ('open', 'calculating', 'review', 'approved', 'paying', 'paid', 'failed', 'cancelled')),
  run_mode text NOT NULL DEFAULT 'dry_run' CHECK (run_mode IN ('live', 'dry_run')),
  fee_income_lamports bigint NOT NULL DEFAULT 0 CHECK (fee_income_lamports >= 0),
  distribution_bps integer CHECK (distribution_bps IS NULL OR distribution_bps BETWEEN 0 AND 10000),
  reward_pool_lamports bigint NOT NULL DEFAULT 0 CHECK (reward_pool_lamports >= 0),
  payable_lamports bigint NOT NULL DEFAULT 0 CHECK (payable_lamports >= 0),
  carried_forward_lamports bigint NOT NULL DEFAULT 0 CHECK (carried_forward_lamports >= 0),
  retained_lamports bigint NOT NULL DEFAULT 0 CHECK (retained_lamports >= 0),
  total_daily_karma bigint NOT NULL DEFAULT 0,
  eligible_daily_karma bigint NOT NULL DEFAULT 0,
  eligible_agent_count integer NOT NULL DEFAULT 0,
  settings_snapshot jsonb,
  calculation_version integer NOT NULL DEFAULT 0,
  calculated_at timestamptz,
  approved_at timestamptz,
  approved_by uuid,
  paid_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  failure_code text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at)
);
CREATE INDEX IF NOT EXISTS reward_epochs_state_idx ON public.reward_epochs (state, ends_at);
CREATE INDEX IF NOT EXISTS reward_epochs_starts_idx ON public.reward_epochs (starts_at DESC);

-- Only the documented transitions are accepted, whatever the caller.
CREATE OR REPLACE FUNCTION public.reward_epochs_transition_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.state IS DISTINCT FROM OLD.state AND NOT (
       (OLD.state = 'open'        AND NEW.state IN ('calculating', 'cancelled'))
    OR (OLD.state = 'calculating' AND NEW.state IN ('review', 'failed'))
    OR (OLD.state = 'review'      AND NEW.state IN ('calculating', 'approved', 'cancelled'))
    OR (OLD.state = 'approved'    AND NEW.state IN ('paying', 'cancelled'))
    OR (OLD.state = 'paying'      AND NEW.state IN ('paid', 'failed', 'approved'))
    OR (OLD.state = 'failed'      AND NEW.state IN ('calculating', 'paying', 'cancelled'))
  ) THEN
    RAISE EXCEPTION 'invalid reward epoch transition: % -> %', OLD.state, NEW.state;
  END IF;
  IF OLD.state IN ('paid', 'cancelled') AND (
       NEW.fee_income_lamports IS DISTINCT FROM OLD.fee_income_lamports
    OR NEW.reward_pool_lamports IS DISTINCT FROM OLD.reward_pool_lamports
    OR NEW.payable_lamports IS DISTINCT FROM OLD.payable_lamports
  ) THEN
    RAISE EXCEPTION 'a % reward epoch is immutable', OLD.state;
  END IF;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. The Karma ledger. One row per evaluated platform event; the idempotency key
--    makes double processing impossible. `status` is 'valid' (counts), 'rejected'
--    (evaluated, did not qualify; reason recorded) or 'invalidated' (removed by an
--    administrator with a reason; never overwritten by recalculation).
--    quality_multiplier_bps and rule_version leave room for later quality
--    scoring without rewriting the ledger.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.karma_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  idempotency_key text NOT NULL UNIQUE CHECK (char_length(idempotency_key) BETWEEN 3 AND 200),
  epoch_id uuid NOT NULL REFERENCES public.reward_epochs(id) ON DELETE RESTRICT,
  agent_id uuid NOT NULL REFERENCES public.agents(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type ~ '^[a-z][a-z0-9_]{1,63}$'),
  base_points integer NOT NULL CHECK (base_points >= 0),
  quality_multiplier_bps integer NOT NULL DEFAULT 10000 CHECK (quality_multiplier_bps BETWEEN 0 AND 100000),
  points integer NOT NULL CHECK (points >= 0),
  status text NOT NULL DEFAULT 'valid' CHECK (status IN ('valid', 'rejected', 'invalidated')),
  reject_reason text,
  source_type text NOT NULL CHECK (source_type ~ '^[a-z][a-z0-9_]{1,63}$'),
  source_id uuid NOT NULL,
  counterparty_agent_id uuid REFERENCES public.agents(id) ON DELETE SET NULL,
  content_fingerprint text,
  occurred_at timestamptz NOT NULL,
  rule_version integer NOT NULL DEFAULT 1,
  invalidated_by uuid,
  invalidated_at timestamptz,
  invalidation_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS karma_events_epoch_agent_idx ON public.karma_events (epoch_id, agent_id, status);
CREATE INDEX IF NOT EXISTS karma_events_agent_status_idx ON public.karma_events (agent_id, status);
CREATE INDEX IF NOT EXISTS karma_events_source_idx ON public.karma_events (source_type, source_id);
CREATE INDEX IF NOT EXISTS karma_events_epoch_type_idx ON public.karma_events (epoch_id, event_type);
CREATE INDEX IF NOT EXISTS karma_events_fingerprint_idx ON public.karma_events (content_fingerprint, occurred_at)
  WHERE content_fingerprint IS NOT NULL;

-- Karma of a finalized epoch can no longer change.
CREATE OR REPLACE FUNCTION public.karma_events_epoch_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  epoch_state text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'karma events are never deleted; set status instead';
  END IF;
  SELECT state INTO epoch_state FROM public.reward_epochs WHERE id = NEW.epoch_id;
  IF epoch_state IN ('approved', 'paying', 'paid', 'cancelled')
     OR (TG_OP = 'UPDATE' AND NEW.epoch_id IS DISTINCT FROM OLD.epoch_id) THEN
    RAISE EXCEPTION 'karma events of a % epoch are immutable', epoch_state;
  END IF;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Indexed inbound SOL transfers to the Reward Pool wallet.
--    (signature, transfer_index) identifies one transfer instruction, so replaying
--    the indexer can never count a transfer twice. Outgoing transfers are never
--    stored here.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reward_fee_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  signature text NOT NULL CHECK (char_length(signature) BETWEEN 32 AND 100),
  transfer_index text NOT NULL CHECK (transfer_index ~ '^[0-9]{1,4}(\.[0-9]{1,4})?$'),
  slot bigint NOT NULL,
  block_time timestamptz NOT NULL,
  source_address text NOT NULL,
  destination_address text NOT NULL,
  lamports bigint NOT NULL CHECK (lamports > 0),
  status text NOT NULL CHECK (status IN ('eligible', 'ignored_not_allowlisted', 'excluded')),
  epoch_id uuid REFERENCES public.reward_epochs(id) ON DELETE RESTRICT,
  commitment text NOT NULL DEFAULT 'finalized' CHECK (commitment = 'finalized'),
  excluded_by uuid,
  excluded_reason text,
  indexed_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (signature, transfer_index)
);
CREATE INDEX IF NOT EXISTS reward_fee_transactions_time_idx ON public.reward_fee_transactions (block_time);
CREATE INDEX IF NOT EXISTS reward_fee_transactions_epoch_idx ON public.reward_fee_transactions (epoch_id, status);
CREATE INDEX IF NOT EXISTS reward_fee_transactions_source_idx ON public.reward_fee_transactions (source_address);

-- ---------------------------------------------------------------------------
-- 7. Per-agent exclusion from one epoch (anti-manipulation, admin only).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reward_epoch_exclusions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  epoch_id uuid NOT NULL REFERENCES public.reward_epochs(id) ON DELETE RESTRICT,
  agent_id uuid NOT NULL REFERENCES public.agents(id) ON DELETE RESTRICT,
  reason text NOT NULL CHECK (char_length(reason) BETWEEN 1 AND 1000),
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  -- Lifting an exclusion keeps the row as history instead of deleting it.
  lifted_at timestamptz,
  lifted_by uuid,
  lift_reason text
);
CREATE UNIQUE INDEX IF NOT EXISTS reward_epoch_exclusions_active_idx
  ON public.reward_epoch_exclusions (epoch_id, agent_id) WHERE lifted_at IS NULL;

-- ---------------------------------------------------------------------------
-- 8. Allocations. One row per agent with Daily Karma in the epoch. The payout
--    wallet is SNAPSHOTTED here; once an allocation is finalized (the epoch was
--    approved) its amounts and wallet can never change, so a later wallet
--    replacement only affects future allocations.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reward_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  epoch_id uuid NOT NULL REFERENCES public.reward_epochs(id) ON DELETE RESTRICT,
  agent_id uuid NOT NULL REFERENCES public.agents(id) ON DELETE RESTRICT,
  daily_karma bigint NOT NULL CHECK (daily_karma >= 0),
  reward_mode text NOT NULL,
  status text NOT NULL
    CHECK (status IN ('ineligible', 'retained', 'carried_forward', 'payable', 'paid', 'void')),
  ineligibility_reason text,
  gross_lamports bigint NOT NULL DEFAULT 0 CHECK (gross_lamports >= 0),
  carry_in_lamports bigint NOT NULL DEFAULT 0 CHECK (carry_in_lamports >= 0),
  carry_source_allocation_id uuid REFERENCES public.reward_allocations(id) ON DELETE RESTRICT,
  payable_lamports bigint NOT NULL DEFAULT 0 CHECK (payable_lamports >= 0),
  carried_forward_lamports bigint NOT NULL DEFAULT 0 CHECK (carried_forward_lamports >= 0),
  retained_lamports bigint NOT NULL DEFAULT 0 CHECK (retained_lamports >= 0),
  capped_by text CHECK (capped_by IS NULL OR capped_by IN ('agent', 'wallet', 'safety')),
  wallet_address text,
  wallet_status text,
  wallet_method text,
  flags text[] NOT NULL DEFAULT ARRAY[]::text[],
  carried_into_allocation_id uuid REFERENCES public.reward_allocations(id) ON DELETE RESTRICT,
  calculation_version integer NOT NULL DEFAULT 1,
  finalized_at timestamptz,
  paid_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (epoch_id, agent_id)
);
CREATE INDEX IF NOT EXISTS reward_allocations_agent_idx ON public.reward_allocations (agent_id, created_at DESC);
CREATE INDEX IF NOT EXISTS reward_allocations_status_idx ON public.reward_allocations (epoch_id, status);
CREATE INDEX IF NOT EXISTS reward_allocations_wallet_idx ON public.reward_allocations (wallet_address)
  WHERE wallet_address IS NOT NULL;
CREATE INDEX IF NOT EXISTS reward_allocations_carry_idx ON public.reward_allocations (agent_id)
  WHERE status = 'carried_forward' AND carried_into_allocation_id IS NULL;

CREATE OR REPLACE FUNCTION public.reward_allocations_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'reward allocations are never deleted; mark them void instead';
  END IF;
  IF OLD.finalized_at IS NOT NULL AND (
       NEW.epoch_id IS DISTINCT FROM OLD.epoch_id
    OR NEW.agent_id IS DISTINCT FROM OLD.agent_id
    OR NEW.daily_karma IS DISTINCT FROM OLD.daily_karma
    OR NEW.gross_lamports IS DISTINCT FROM OLD.gross_lamports
    OR NEW.carry_in_lamports IS DISTINCT FROM OLD.carry_in_lamports
    OR NEW.carry_source_allocation_id IS DISTINCT FROM OLD.carry_source_allocation_id
    OR NEW.payable_lamports IS DISTINCT FROM OLD.payable_lamports
    OR NEW.carried_forward_lamports IS DISTINCT FROM OLD.carried_forward_lamports
    OR NEW.retained_lamports IS DISTINCT FROM OLD.retained_lamports
    OR NEW.wallet_address IS DISTINCT FROM OLD.wallet_address
    OR NEW.wallet_status IS DISTINCT FROM OLD.wallet_status
    OR NEW.finalized_at IS DISTINCT FROM OLD.finalized_at
    OR (NEW.status IS DISTINCT FROM OLD.status AND NOT (OLD.status = 'payable' AND NEW.status = 'paid'))
    OR (OLD.carried_into_allocation_id IS NOT NULL
        AND NEW.carried_into_allocation_id IS DISTINCT FROM OLD.carried_into_allocation_id)
  ) THEN
    RAISE EXCEPTION 'finalized reward allocation % is immutable', OLD.id;
  END IF;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 9. Payout batches and payouts. No private key is ever stored: an administrator
--    signs the transfers in their own wallet, then submits each transaction
--    signature, which the server verifies on-chain at `finalized` commitment.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reward_payout_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  epoch_id uuid NOT NULL REFERENCES public.reward_epochs(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'prepared'
    CHECK (status IN ('prepared', 'confirmed', 'failed', 'cancelled')),
  source_wallet_address text NOT NULL,
  network text NOT NULL,
  total_lamports bigint NOT NULL CHECK (total_lamports >= 0),
  payout_count integer NOT NULL CHECK (payout_count >= 0),
  plan_checksum text NOT NULL,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  confirmed_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
-- At most one open batch per epoch.
CREATE UNIQUE INDEX IF NOT EXISTS reward_payout_batches_open_idx
  ON public.reward_payout_batches (epoch_id) WHERE status = 'prepared';

CREATE TABLE IF NOT EXISTS public.reward_payouts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.reward_payout_batches(id) ON DELETE RESTRICT,
  allocation_id uuid NOT NULL REFERENCES public.reward_allocations(id) ON DELETE RESTRICT,
  agent_id uuid NOT NULL REFERENCES public.agents(id) ON DELETE RESTRICT,
  recipient_address text NOT NULL,
  lamports bigint NOT NULL CHECK (lamports > 0),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'submitted', 'confirmed', 'failed', 'cancelled')),
  tx_signature text,
  transfer_index text,
  submitted_by uuid,
  submitted_at timestamptz,
  confirmed_at timestamptz,
  confirmed_slot bigint,
  last_failure_code text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
-- One live payout per allocation: the same allocation can never be paid twice.
CREATE UNIQUE INDEX IF NOT EXISTS reward_payouts_allocation_live_idx
  ON public.reward_payouts (allocation_id) WHERE status IN ('pending', 'submitted', 'confirmed');
-- One on-chain transfer can settle exactly one payout.
CREATE UNIQUE INDEX IF NOT EXISTS reward_payouts_transfer_idx
  ON public.reward_payouts (tx_signature, transfer_index) WHERE tx_signature IS NOT NULL;
CREATE INDEX IF NOT EXISTS reward_payouts_batch_idx ON public.reward_payouts (batch_id, status);
CREATE INDEX IF NOT EXISTS reward_payouts_agent_idx ON public.reward_payouts (agent_id, created_at DESC);
CREATE INDEX IF NOT EXISTS reward_payouts_signature_idx ON public.reward_payouts (tx_signature)
  WHERE tx_signature IS NOT NULL;

CREATE OR REPLACE FUNCTION public.reward_payouts_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'reward payouts are never deleted';
  END IF;
  IF OLD.status = 'confirmed' AND (
       NEW.status IS DISTINCT FROM OLD.status
    OR NEW.recipient_address IS DISTINCT FROM OLD.recipient_address
    OR NEW.lamports IS DISTINCT FROM OLD.lamports
    OR NEW.tx_signature IS DISTINCT FROM OLD.tx_signature
    OR NEW.transfer_index IS DISTINCT FROM OLD.transfer_index
  ) THEN
    RAISE EXCEPTION 'confirmed reward payout % is immutable', OLD.id;
  END IF;
  IF NEW.recipient_address IS DISTINCT FROM OLD.recipient_address
     OR NEW.lamports IS DISTINCT FROM OLD.lamports
     OR NEW.allocation_id IS DISTINCT FROM OLD.allocation_id THEN
    RAISE EXCEPTION 'payout recipient and amount are fixed at creation';
  END IF;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 10. Append-only audit log for every reward, wallet and payout decision.
--     UPDATE, DELETE and TRUNCATE are refused by trigger. agent_id carries no
--     foreign key on purpose, so the log can never block or be altered by a
--     change to another table.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reward_audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_type text NOT NULL CHECK (actor_type IN ('admin', 'agent', 'owner', 'system')),
  actor_id text,
  agent_id uuid,
  epoch_id uuid,
  action text NOT NULL CHECK (char_length(action) BETWEEN 1 AND 100),
  reason text,
  previous_values jsonb,
  new_values jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS reward_audit_events_agent_idx ON public.reward_audit_events (agent_id, created_at DESC);
CREATE INDEX IF NOT EXISTS reward_audit_events_created_idx ON public.reward_audit_events (created_at DESC);
CREATE INDEX IF NOT EXISTS reward_audit_events_action_idx ON public.reward_audit_events (action, created_at DESC);

CREATE OR REPLACE FUNCTION public.reward_audit_events_append_only()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  RAISE EXCEPTION 'reward_audit_events is append-only';
END;
$$;

-- ---------------------------------------------------------------------------
-- 11. Atomic operations, callable by the service role only.
-- ---------------------------------------------------------------------------

-- Approve an epoch in review: finalize every allocation, link consumed
-- carry-forward balances, and move the epoch to 'approved'. The calculation
-- version must match what the administrator reviewed.
CREATE OR REPLACE FUNCTION public.reward_approve_epoch(
  p_epoch_id uuid,
  p_admin_id uuid,
  p_calculation_version integer
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_epoch public.reward_epochs%ROWTYPE;
  v_alloc record;
  v_linked integer;
BEGIN
  SELECT * INTO v_epoch FROM public.reward_epochs WHERE id = p_epoch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'epoch_not_found'; END IF;
  IF v_epoch.state <> 'review' THEN RAISE EXCEPTION 'epoch_not_in_review'; END IF;
  IF v_epoch.run_mode <> 'live' THEN RAISE EXCEPTION 'dry_run_epoch_cannot_be_approved'; END IF;
  IF v_epoch.calculation_version <> p_calculation_version THEN RAISE EXCEPTION 'stale_calculation'; END IF;

  FOR v_alloc IN
    SELECT id, carry_source_allocation_id FROM public.reward_allocations
    WHERE epoch_id = p_epoch_id AND carry_source_allocation_id IS NOT NULL AND status <> 'void'
  LOOP
    UPDATE public.reward_allocations
       SET carried_into_allocation_id = v_alloc.id
     WHERE id = v_alloc.carry_source_allocation_id
       AND status = 'carried_forward'
       AND carried_into_allocation_id IS NULL;
    GET DIAGNOSTICS v_linked = ROW_COUNT;
    IF v_linked <> 1 THEN RAISE EXCEPTION 'carry_forward_already_consumed'; END IF;
  END LOOP;

  UPDATE public.reward_allocations
     SET finalized_at = now()
   WHERE epoch_id = p_epoch_id AND finalized_at IS NULL AND status <> 'void';

  UPDATE public.reward_epochs
     SET state = 'approved', approved_at = now(), approved_by = p_admin_id
   WHERE id = p_epoch_id;
  RETURN true;
END;
$$;

-- Create a payout batch from an explicit, pre-validated plan. Every item is
-- re-validated against its finalized allocation inside this transaction.
CREATE OR REPLACE FUNCTION public.reward_create_payout_batch(
  p_epoch_id uuid,
  p_admin_id uuid,
  p_source_wallet text,
  p_network text,
  p_checksum text,
  p_items jsonb
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_epoch public.reward_epochs%ROWTYPE;
  v_batch_id uuid;
  v_item jsonb;
  v_alloc public.reward_allocations%ROWTYPE;
  v_total bigint := 0;
  v_count integer := 0;
BEGIN
  SELECT * INTO v_epoch FROM public.reward_epochs WHERE id = p_epoch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'epoch_not_found'; END IF;
  IF v_epoch.state NOT IN ('approved', 'failed') OR v_epoch.approved_at IS NULL THEN
    RAISE EXCEPTION 'epoch_not_approved';
  END IF;
  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'empty_plan';
  END IF;

  INSERT INTO public.reward_payout_batches
    (epoch_id, source_wallet_address, network, total_lamports, payout_count, plan_checksum, created_by)
  VALUES (p_epoch_id, p_source_wallet, p_network, 0, 0, p_checksum, p_admin_id)
  RETURNING id INTO v_batch_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT * INTO v_alloc FROM public.reward_allocations
     WHERE id = (v_item->>'allocation_id')::uuid FOR UPDATE;
    IF NOT FOUND
       OR v_alloc.epoch_id <> p_epoch_id
       OR v_alloc.finalized_at IS NULL
       OR v_alloc.status <> 'payable'
       OR v_alloc.wallet_address IS DISTINCT FROM (v_item->>'recipient_address')
       OR v_alloc.payable_lamports <> (v_item->>'lamports')::bigint
       OR v_alloc.payable_lamports <= 0 THEN
      RAISE EXCEPTION 'plan_item_mismatch';
    END IF;
    INSERT INTO public.reward_payouts (batch_id, allocation_id, agent_id, recipient_address, lamports)
    VALUES (v_batch_id, v_alloc.id, v_alloc.agent_id, v_alloc.wallet_address, v_alloc.payable_lamports);
    v_total := v_total + v_alloc.payable_lamports;
    v_count := v_count + 1;
  END LOOP;

  UPDATE public.reward_payout_batches SET total_lamports = v_total, payout_count = v_count
   WHERE id = v_batch_id;
  UPDATE public.reward_epochs SET state = 'paying', failure_code = NULL WHERE id = p_epoch_id;
  RETURN v_batch_id;
END;
$$;

-- Record a payout as confirmed after the server verified the transfer at
-- `finalized` commitment. Marks the allocation paid and settles the batch and
-- the epoch when nothing is left to pay.
CREATE OR REPLACE FUNCTION public.reward_confirm_payout(
  p_payout_id uuid,
  p_signature text,
  p_transfer_index text,
  p_slot bigint
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_payout public.reward_payouts%ROWTYPE;
  v_open integer;
  v_epoch_open integer;
  v_epoch_id uuid;
BEGIN
  SELECT * INTO v_payout FROM public.reward_payouts WHERE id = p_payout_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'payout_not_found'; END IF;
  IF v_payout.status = 'confirmed' THEN
    RETURN v_payout.tx_signature = p_signature AND v_payout.transfer_index = p_transfer_index;
  END IF;
  IF v_payout.status NOT IN ('pending', 'submitted') THEN RAISE EXCEPTION 'payout_not_open'; END IF;

  UPDATE public.reward_payouts
     SET status = 'confirmed', tx_signature = p_signature, transfer_index = p_transfer_index,
         confirmed_at = now(), confirmed_slot = p_slot, last_failure_code = NULL
   WHERE id = p_payout_id;
  UPDATE public.reward_allocations SET status = 'paid', paid_at = now()
   WHERE id = v_payout.allocation_id AND status = 'payable';

  SELECT count(*) INTO v_open FROM public.reward_payouts
   WHERE batch_id = v_payout.batch_id AND status IN ('pending', 'submitted');
  IF v_open = 0 THEN
    UPDATE public.reward_payout_batches SET status = 'confirmed', confirmed_at = now()
     WHERE id = v_payout.batch_id AND status = 'prepared';
    SELECT epoch_id INTO v_epoch_id FROM public.reward_payout_batches WHERE id = v_payout.batch_id;
    SELECT count(*) INTO v_epoch_open FROM public.reward_allocations
     WHERE epoch_id = v_epoch_id AND status = 'payable';
    IF v_epoch_open = 0 THEN
      UPDATE public.reward_epochs SET state = 'paid', paid_at = now()
       WHERE id = v_epoch_id AND state = 'paying';
    END IF;
  END IF;
  RETURN true;
END;
$$;

-- ---------------------------------------------------------------------------
-- 12. Triggers, RLS and grants.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS reward_settings_updated_at ON public.reward_settings;
CREATE TRIGGER reward_settings_updated_at BEFORE UPDATE ON public.reward_settings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS reward_pool_state_updated_at ON public.reward_pool_state;
CREATE TRIGGER reward_pool_state_updated_at BEFORE UPDATE ON public.reward_pool_state
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS agent_reward_profiles_updated_at ON public.agent_reward_profiles;
CREATE TRIGGER agent_reward_profiles_updated_at BEFORE UPDATE ON public.agent_reward_profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS reward_epochs_updated_at ON public.reward_epochs;
CREATE TRIGGER reward_epochs_updated_at BEFORE UPDATE ON public.reward_epochs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS reward_epochs_transition ON public.reward_epochs;
CREATE TRIGGER reward_epochs_transition BEFORE UPDATE ON public.reward_epochs
  FOR EACH ROW EXECUTE FUNCTION public.reward_epochs_transition_guard();
DROP TRIGGER IF EXISTS karma_events_updated_at ON public.karma_events;
CREATE TRIGGER karma_events_updated_at BEFORE UPDATE ON public.karma_events
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS karma_events_epoch_guard ON public.karma_events;
CREATE TRIGGER karma_events_epoch_guard BEFORE INSERT OR UPDATE OR DELETE ON public.karma_events
  FOR EACH ROW EXECUTE FUNCTION public.karma_events_epoch_guard();
DROP TRIGGER IF EXISTS reward_fee_transactions_updated_at ON public.reward_fee_transactions;
CREATE TRIGGER reward_fee_transactions_updated_at BEFORE UPDATE ON public.reward_fee_transactions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS reward_allocations_updated_at ON public.reward_allocations;
CREATE TRIGGER reward_allocations_updated_at BEFORE UPDATE ON public.reward_allocations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS reward_allocations_guard ON public.reward_allocations;
CREATE TRIGGER reward_allocations_guard BEFORE UPDATE OR DELETE ON public.reward_allocations
  FOR EACH ROW EXECUTE FUNCTION public.reward_allocations_guard();
DROP TRIGGER IF EXISTS reward_payout_batches_updated_at ON public.reward_payout_batches;
CREATE TRIGGER reward_payout_batches_updated_at BEFORE UPDATE ON public.reward_payout_batches
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS reward_payouts_updated_at ON public.reward_payouts;
CREATE TRIGGER reward_payouts_updated_at BEFORE UPDATE ON public.reward_payouts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS reward_payouts_guard ON public.reward_payouts;
CREATE TRIGGER reward_payouts_guard BEFORE UPDATE OR DELETE ON public.reward_payouts
  FOR EACH ROW EXECUTE FUNCTION public.reward_payouts_guard();
DROP TRIGGER IF EXISTS reward_audit_events_no_update ON public.reward_audit_events;
CREATE TRIGGER reward_audit_events_no_update BEFORE UPDATE OR DELETE ON public.reward_audit_events
  FOR EACH ROW EXECUTE FUNCTION public.reward_audit_events_append_only();
DROP TRIGGER IF EXISTS reward_audit_events_no_truncate ON public.reward_audit_events;
CREATE TRIGGER reward_audit_events_no_truncate BEFORE TRUNCATE ON public.reward_audit_events
  FOR EACH STATEMENT EXECUTE FUNCTION public.reward_audit_events_append_only();

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'reward_settings', 'reward_pool_state', 'agent_reward_profiles', 'reward_epochs',
    'karma_events', 'reward_fee_transactions', 'reward_epoch_exclusions', 'reward_allocations',
    'reward_payout_batches', 'reward_payouts', 'reward_audit_events'
  ] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION public.reward_approve_epoch(uuid, uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reward_approve_epoch(uuid, uuid, integer) TO service_role;
REVOKE ALL ON FUNCTION public.reward_create_payout_batch(uuid, uuid, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reward_create_payout_batch(uuid, uuid, text, text, text, jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.reward_confirm_payout(uuid, text, text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reward_confirm_payout(uuid, text, text, bigint) TO service_role;
