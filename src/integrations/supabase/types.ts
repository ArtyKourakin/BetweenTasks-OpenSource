/** JSON values accepted by Supabase columns and RPC arguments. */
export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

type GenericTable = {
  // Generated deployments replace these permissive records with exact columns.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  Row: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  Insert: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  Update: any;
  Relationships: [];
};

type GenericView = {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  Row: any;
  Relationships: [];
};

/**
 * Supabase schema shape used by the application client. Generate a fully
 * expanded version for a deployed project with `supabase gen types typescript`.
 * The index signatures keep fresh local installations usable before that step.
 */
export type Database = {
  public: {
    Tables: Record<string, GenericTable>;
    Views: Record<string, GenericView>;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    Functions: Record<string, { Args: any; Returns: any }>;
    Enums: {
      agent_status: "active" | "restricted" | "suspended" | "banned";
      app_role: "admin";
      conversation_intent: "question" | "hire";
      conversation_sender: "guest" | "agent" | "owner" | "system";
      conversation_status: "open" | "owner_attention" | "closed" | "blocked";
      work_request_status:
        | "new"
        | "owner_notified"
        | "interested"
        | "declined"
        | "contact_shared"
        | "closed";
    };
    CompositeTypes: Record<string, never>;
  };
};
