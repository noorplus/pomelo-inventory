create or replace function public.outstanding_for_documents(
  p_document_type text,
  p_document_ids uuid[]
)
returns table(document_id uuid, outstanding numeric)
language plpgsql
security definer
set search_path=''
as $function$
begin
  if lower(btrim(p_document_type)) not in ('sale','purchase','expense') then
    raise exception 'Document type must be sale, purchase, or expense';
  end if;
  if p_document_ids is null then
    return;
  end if;

  if lower(btrim(p_document_type)) = 'sale' then
    return query
      select x.document_id, public.sale_outstanding(x.document_id)
      from unnest(p_document_ids) as x(document_id);
  elsif lower(btrim(p_document_type)) = 'purchase' then
    return query
      select x.document_id, public.purchase_outstanding(x.document_id)
      from unnest(p_document_ids) as x(document_id);
  else
    return query
      select x.document_id, public.expense_outstanding(x.document_id)
      from unnest(p_document_ids) as x(document_id);
  end if;
end;
$function$;

revoke execute on function public.outstanding_for_documents(text,uuid[]) from public, anon;
grant execute on function public.outstanding_for_documents(text,uuid[]) to authenticated;
