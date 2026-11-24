-- Migration: Promo-code discount support (E7GEZLY) & per-doctor discount_pct (0–50)
-- Safe to run multiple times (idempotent). Preserves all existing preview_slot & book_slot logic.

-- 1. Add discount_pct (0–50) to public.doctors
ALTER TABLE public.doctors
  ADD COLUMN IF NOT EXISTS discount_pct integer NOT NULL DEFAULT 0;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'doctors_discount_pct_check'
      AND conrelid = 'public.doctors'::regclass
  ) THEN
    ALTER TABLE public.doctors
      ADD CONSTRAINT doctors_discount_pct_check
      CHECK (discount_pct BETWEEN 0 AND 50);
  END IF;
END
$$;

-- 2. Add promo_code, discount_pct, final_fee to public.bookings
ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS promo_code text,
  ADD COLUMN IF NOT EXISTS discount_pct integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS final_fee numeric;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'bookings_discount_pct_check'
      AND conrelid = 'public.bookings'::regclass
  ) THEN
    ALTER TABLE public.bookings
      ADD CONSTRAINT bookings_discount_pct_check
      CHECK (discount_pct BETWEEN 0 AND 50);
  END IF;
END
$$;

-- 3. Helper: normalize promo codes (case-insensitive, Arabic/Persian digits tolerant)
CREATE OR REPLACE FUNCTION public.normalize_promo_code(p_raw text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(
    UPPER(
      REGEXP_REPLACE(
        TRANSLATE(
          COALESCE(p_raw, ''),
          '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹',
          '01234567890123456789'
        ),
        '\s+',
        '',
        'g'
      )
    ),
    ''
  );
$$;

-- 4. Update public.preview_slot to include the assigned doctor's discount_pct
--    Renames the existing implementation to _preview_slot_base once, then wraps it
--    while keeping the exact same parameter signature and defaults.
DO $$
DECLARE
  v_base_oid    oid;
  v_cur_oid     oid;
  v_id_args     text;
  v_full_args   text;
  v_call_args   text;
  v_doc_id_type text;
BEGIN
  SELECT format_type(a.atttypid, a.atttypmod)
    INTO v_doc_id_type
  FROM pg_attribute a
  WHERE a.attrelid = 'public.doctors'::regclass
    AND a.attname = 'id'
    AND a.attnum > 0
    AND NOT a.attisdropped;

  SELECT p.oid INTO v_base_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = '_preview_slot_base'
  ORDER BY p.pronargs DESC
  LIMIT 1;

  IF v_base_oid IS NULL THEN
    SELECT p.oid INTO v_cur_oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'preview_slot'
    ORDER BY p.pronargs DESC
    LIMIT 1;

    IF v_cur_oid IS NULL THEN
      RAISE EXCEPTION 'public.preview_slot was not found';
    END IF;

    v_id_args := pg_get_function_identity_arguments(v_cur_oid);
    EXECUTE format('ALTER FUNCTION public.preview_slot(%s) RENAME TO _preview_slot_base', v_id_args);
    v_base_oid := v_cur_oid;
  END IF;

  v_id_args   := pg_get_function_identity_arguments(v_base_oid);
  v_full_args := pg_get_function_arguments(v_base_oid);

  SELECT string_agg(
    CASE
      WHEN p.proargnames IS NOT NULL AND p.proargnames[i] IS NOT NULL AND p.proargnames[i] <> ''
        THEN quote_ident(p.proargnames[i])
      ELSE '$' || i::text
    END,
    ', ' ORDER BY i
  )
    INTO v_call_args
  FROM pg_proc p
  CROSS JOIN LATERAL generate_series(1, p.pronargs) AS i
  WHERE p.oid = v_base_oid;

  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION public.preview_slot(%s)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public
    AS $body$
    DECLARE
      v_res          jsonb;
      v_discount_pct integer := 0;
    BEGIN
      v_res := (public._preview_slot_base(%s))::jsonb;

      IF v_res IS NOT NULL AND COALESCE(v_res->>'doctor_id', '') <> '' THEN
        SELECT LEAST(50, GREATEST(0, COALESCE(d.discount_pct, 0)))
          INTO v_discount_pct
        FROM public.doctors d
        WHERE d.id = (v_res->>'doctor_id')::%s;

        v_res := v_res || jsonb_build_object('discount_pct', COALESCE(v_discount_pct, 0));
      END IF;

      RETURN v_res;
    END;
    $body$;
  $fn$, v_full_args, COALESCE(v_call_args, ''), v_doc_id_type);

  EXECUTE format('GRANT EXECUTE ON FUNCTION public.preview_slot(%s) TO anon, authenticated', v_id_args);
END
$$;

-- 5. Update public.book_slot to accept optional p_promo_code text DEFAULT NULL,
--    validate server-side (only E7GEZLY), and persist promo_code, discount_pct, final_fee.
--    Old callers omitting p_promo_code continue working unchanged.
DO $$
DECLARE
  v_base_oid        oid;
  v_cur_oid         oid;
  v_old_oid         oid;
  v_id_args         text;
  v_full_args       text;
  v_call_args       text;
  v_new_full_args   text;
  v_new_id_args     text;
  v_booking_id_type text;
BEGIN
  SELECT format_type(a.atttypid, a.atttypmod)
    INTO v_booking_id_type
  FROM pg_attribute a
  WHERE a.attrelid = 'public.bookings'::regclass
    AND a.attname = 'id'
    AND a.attnum > 0
    AND NOT a.attisdropped;

  SELECT p.oid INTO v_base_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = '_book_slot_base'
  ORDER BY p.pronargs DESC
  LIMIT 1;

  IF v_base_oid IS NULL THEN
    SELECT p.oid INTO v_cur_oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'book_slot'
      AND NOT ('p_promo_code' = ANY(COALESCE(p.proargnames, ARRAY[]::text[])))
    ORDER BY p.pronargs DESC
    LIMIT 1;

    IF v_cur_oid IS NULL THEN
      RAISE EXCEPTION 'public.book_slot was not found';
    END IF;

    v_id_args := pg_get_function_identity_arguments(v_cur_oid);
    EXECUTE format('ALTER FUNCTION public.book_slot(%s) RENAME TO _book_slot_base', v_id_args);
    v_base_oid := v_cur_oid;
  END IF;

  -- Remove any leftover overload without p_promo_code so PostgREST resolves unambiguously
  FOR v_old_oid IN
    SELECT p.oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'book_slot'
      AND NOT ('p_promo_code' = ANY(COALESCE(p.proargnames, ARRAY[]::text[])))
  LOOP
    EXECUTE format('DROP FUNCTION public.book_slot(%s)', pg_get_function_identity_arguments(v_old_oid));
  END LOOP;

  v_id_args   := pg_get_function_identity_arguments(v_base_oid);
  v_full_args := pg_get_function_arguments(v_base_oid);

  SELECT string_agg(
    CASE
      WHEN p.proargnames IS NOT NULL AND p.proargnames[i] IS NOT NULL AND p.proargnames[i] <> ''
        THEN quote_ident(p.proargnames[i])
      ELSE '$' || i::text
    END,
    ', ' ORDER BY i
  )
    INTO v_call_args
  FROM pg_proc p
  CROSS JOIN LATERAL generate_series(1, p.pronargs) AS i
  WHERE p.oid = v_base_oid;

  v_new_full_args := CASE
    WHEN COALESCE(v_full_args, '') = '' THEN 'p_promo_code text DEFAULT NULL'
    ELSE v_full_args || ', p_promo_code text DEFAULT NULL'
  END;

  v_new_id_args := CASE
    WHEN COALESCE(v_id_args, '') = '' THEN 'text'
    ELSE v_id_args || ', text'
  END;

  EXECUTE format($fn$
    CREATE OR REPLACE FUNCTION public.book_slot(%s)
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public
    AS $body$
    DECLARE
      v_res          jsonb;
      v_norm_code    text;
      v_applied_code text := NULL;
      v_doc_discount integer := 0;
      v_discount_pct integer := 0;
      v_base_fee     numeric;
      v_final_fee    numeric;
      v_booking_id   %s;
    BEGIN
      v_res := (public._book_slot_base(%s))::jsonb;

      IF v_res IS NOT NULL
         AND COALESCE((v_res->>'ok')::boolean, false)
         AND COALESCE(v_res->>'booking_id', '') <> '' THEN

        v_booking_id := (v_res->>'booking_id')::%s;
        v_norm_code  := public.normalize_promo_code(p_promo_code);

        SELECT b.fee, LEAST(50, GREATEST(0, COALESCE(d.discount_pct, 0)))
          INTO v_base_fee, v_doc_discount
        FROM public.bookings b
        LEFT JOIN public.doctors d ON d.id = b.doctor_id
        WHERE b.id = v_booking_id;

        IF v_base_fee IS NULL AND COALESCE(v_res->>'fee', '') <> '' THEN
          v_base_fee := (v_res->>'fee')::numeric;
        END IF;

        IF v_norm_code = 'E7GEZLY' THEN
          v_applied_code := 'E7GEZLY';
          v_discount_pct := COALESCE(v_doc_discount, 0);
          v_final_fee := CASE
            WHEN v_base_fee IS NOT NULL THEN ROUND(v_base_fee * (100 - v_discount_pct) / 100.0)
            ELSE NULL
          END;
        ELSE
          v_applied_code := NULL;
          v_discount_pct := 0;
          v_final_fee := v_base_fee;
        END IF;

        UPDATE public.bookings
        SET promo_code   = v_applied_code,
            discount_pct = v_discount_pct,
            final_fee    = v_final_fee
        WHERE id = v_booking_id;

        v_res := v_res || jsonb_build_object(
          'promo_code',   v_applied_code,
          'discount_pct', v_discount_pct,
          'final_fee',    v_final_fee
        );
      END IF;

      RETURN v_res;
    END;
    $body$;
  $fn$, v_new_full_args, v_booking_id_type, COALESCE(v_call_args, ''), v_booking_id_type);

  EXECUTE format('GRANT EXECUTE ON FUNCTION public.book_slot(%s) TO anon, authenticated', v_new_id_args);
END
$$;

-- 6. Reload PostgREST schema cache so the new columns & p_promo_code parameter are active immediately
NOTIFY pgrst, 'reload schema';
