-- Contacts: centralized Customer/Supplier master, tenant-isolated.

CREATE TYPE public.contact_status AS ENUM ('Active', 'Inactive');

CREATE TABLE public.contacts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    id_no integer NOT NULL,
    name text NOT NULL,
    phone text,
    email extensions.citext,
    address text,
    status public.contact_status NOT NULL DEFAULT 'Active',
    created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT contacts_id_no_six_digits_chk CHECK (id_no BETWEEN 100000 AND 999999),
    CONSTRAINT contacts_name_not_blank_chk CHECK (btrim(name) <> ''),
    CONSTRAINT contacts_organization_id_no_unique UNIQUE (organization_id, id_no),
    CONSTRAINT contacts_id_organization_unique UNIQUE (id, organization_id),
    CONSTRAINT contacts_organization_created_by_fk
        FOREIGN KEY (organization_id, created_by)
        REFERENCES public.organization_users(organization_id, user_id)
        ON DELETE RESTRICT
);

CREATE INDEX contacts_organization_id_idx ON public.contacts (organization_id);
CREATE INDEX contacts_created_by_idx ON public.contacts (created_by);
CREATE INDEX contacts_organization_status_idx ON public.contacts (organization_id, status);
CREATE INDEX contacts_organization_name_idx ON public.contacts (organization_id, name);
CREATE INDEX contacts_organization_phone_idx ON public.contacts (organization_id, phone);

CREATE TABLE public.contact_id_counters (
    organization_id uuid PRIMARY KEY REFERENCES public.organizations(id) ON DELETE CASCADE,
    last_id_no integer NOT NULL DEFAULT 99999,
    CONSTRAINT contact_id_counters_range_chk CHECK (last_id_no BETWEEN 99999 AND 999999)
);

CREATE OR REPLACE FUNCTION public.next_contact_id_no(p_organization_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id_no integer;
BEGIN
    IF (SELECT auth.uid()) IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.organization_users ou
        WHERE ou.organization_id = p_organization_id
          AND ou.user_id = (SELECT auth.uid())
    ) THEN
        RAISE EXCEPTION 'User is not a member of this organization';
    END IF;

    INSERT INTO public.contact_id_counters (organization_id, last_id_no)
    VALUES (p_organization_id, 100000)
    ON CONFLICT (organization_id)
    DO UPDATE SET last_id_no = public.contact_id_counters.last_id_no + 1
    RETURNING last_id_no INTO v_id_no;

    IF v_id_no > 999999 THEN
        RAISE EXCEPTION 'Contact ID limit reached for organization %', p_organization_id;
    END IF;

    RETURN v_id_no;
END;
$$;

REVOKE ALL ON FUNCTION public.next_contact_id_no(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.next_contact_id_no(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_contact_id_no()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.id_no IS NULL THEN
        NEW.id_no := public.next_contact_id_no(NEW.organization_id);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER contacts_generate_id_no
    BEFORE INSERT ON public.contacts
    FOR EACH ROW
    EXECUTE FUNCTION public.set_contact_id_no();

CREATE OR REPLACE FUNCTION public.prevent_contact_ownership_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.organization_id <> OLD.organization_id THEN
        RAISE EXCEPTION 'Contact organization cannot be changed';
    END IF;
    IF NEW.created_by <> OLD.created_by THEN
        RAISE EXCEPTION 'Contact creator cannot be changed';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER contacts_prevent_ownership_change
    BEFORE UPDATE ON public.contacts
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_contact_ownership_change();

CREATE TRIGGER contacts_set_updated_at
    BEFORE UPDATE ON public.contacts
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.contacts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "contacts_select_organization_members"
ON public.contacts FOR SELECT TO authenticated
USING (EXISTS (
    SELECT 1 FROM public.organization_users ou
    WHERE ou.organization_id = contacts.organization_id
      AND ou.user_id = (SELECT auth.uid())
));

CREATE POLICY "contacts_insert_organization_members"
ON public.contacts FOR INSERT TO authenticated
WITH CHECK (
    created_by = (SELECT auth.uid())
    AND EXISTS (
        SELECT 1 FROM public.organization_users ou
        WHERE ou.organization_id = contacts.organization_id
          AND ou.user_id = (SELECT auth.uid())
    )
);

CREATE POLICY "contacts_update_organization_members"
ON public.contacts FOR UPDATE TO authenticated
USING (EXISTS (
    SELECT 1 FROM public.organization_users ou
    WHERE ou.organization_id = contacts.organization_id
      AND ou.user_id = (SELECT auth.uid())
))
WITH CHECK (EXISTS (
    SELECT 1 FROM public.organization_users ou
    WHERE ou.organization_id = contacts.organization_id
      AND ou.user_id = (SELECT auth.uid())
));

CREATE POLICY "contacts_delete_organization_members"
ON public.contacts FOR DELETE TO authenticated
USING (EXISTS (
    SELECT 1 FROM public.organization_users ou
    WHERE ou.organization_id = contacts.organization_id
      AND ou.user_id = (SELECT auth.uid())
));

REVOKE ALL ON public.contacts FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.contacts TO authenticated;
REVOKE ALL ON public.contact_id_counters FROM anon, authenticated;