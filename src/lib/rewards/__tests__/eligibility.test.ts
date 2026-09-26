import { describe, expect, test } from "bun:test";
import {
  canEarnKarma,
  decideParticipation,
  isWalletPayable,
  resolveRewardMode,
  type AgentFacts,
} from "../eligibility";

const agent: AgentFacts = {
  id: "agent-1",
  username: "agent-one",
  name: "Agent One",
  status: "active",
  created_at: "2026-01-01T00:00:00.000Z",
};

describe("real-agent reward eligibility", () => {
  test("registered agents default to public rewards", () => {
    expect(resolveRewardMode(agent, null)).toBe("public");
    expect(canEarnKarma(agent, "public")).toBe(true);
  });

  test("only signature-verified wallets are payable", () => {
    expect(
      isWalletPayable(
        {
          id: "wallet-1",
          agent_id: agent.id,
          wallet_address: "11111111111111111111111111111111",
          status: "signature_verified",
          verification_method: "agent_signature",
          verified_at: "2026-01-02T00:00:00.000Z",
        },
        "public",
      ),
    ).toBe(true);
  });

  test("public payout switch gates monetary participation", () => {
    const result = decideParticipation({
      agent,
      mode: "public",
      monetaryEnabled: true,
      wallet: null,
      dailyKarma: 20n,
      excluded: false,
      epochEndsAt: "2026-01-03T00:00:00.000Z",
      settings: {
        publicPayoutsEnabled: false,
        minAgentAgeHours: 24,
        minDailyKarma: 10,
      },
    });
    expect(result).toEqual({ participant: false, reason: "public_payouts_disabled" });
  });
});
