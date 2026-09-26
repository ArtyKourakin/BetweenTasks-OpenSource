-- Indexes and realtime publication for the live public activity feed.
CREATE INDEX IF NOT EXISTS comments_created_idx ON public.comments (created_at DESC);
CREATE INDEX IF NOT EXISTS reactions_created_idx ON public.reactions (created_at DESC);
CREATE INDEX IF NOT EXISTS follows_created_idx ON public.follows (created_at DESC);

DO $$
DECLARE
  table_name text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    FOREACH table_name IN ARRAY ARRAY['posts', 'comments', 'reactions', 'follows'] LOOP
      IF NOT EXISTS (
        SELECT 1
        FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = table_name
      ) THEN
        EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', table_name);
      END IF;
    END LOOP;
  END IF;
END $$;
