MODEL (
  name modelling.contact_lead_history_@business,
  kind SCD_TYPE_2_BY_COLUMN (
    unique_key surrogate_id,
    columns ARRAY[business_id, contact_id, lead_id, lead_type, contact_email, contact_phone, contact_mobile, contact_first_name, contact_last_name, contact_name, lead_email, lead_phone, lead_name, first_invoice_date, contact_lead_first_match, contact_email_match, contact_phone_match, contact_mobile_match, contact_name_match],
    invalidate_hard_deletes TRUE,
  disable_restatement FALSE,
  on_destructive_change warn,
  ),
  audits (
    detect_active_records(),
    detect_contact_matched_but_not_matched(),
    detect_more_than_one_first_match()
  ),
  blueprints (
    (business := "x"),
    (business := "y"),
  ),
  start "2020-01-01",
  cron "0 13 * * *",
  gateway trino_gateway,
  dialect trino,
  storage_format parquet
);

WITH first_invoice_dates AS (
  SELECT 
  b.id as business_id
  , i.contact_id
  , min(date) as first_invoice_date
  FROM postgres.public.invoices i
  LEFT JOIN postgres.public.businesses b 
  ON i.business_mongo_id = b.mongo_id
  WHERE i.updated_at <= now()
  AND (
  (integration = 'myob' and source = 'invoices')
  OR
  (i.status IN ('paid', 'authorised', 'delivered', 'completed', 'processing', 'open', 'closed'))
  OR (source = 'invoices' or source = 'orders')
  OR (integration = 'csv'))
  AND b.id = @business
  group by b.id, i.contact_id
)
, filtered_contacts AS ( --runs in under a second 5718 rows
  SELECT *
  , length(phone_trimmed) as phone_trimmed_length
  , length(mobile_trimmed) as mobile_trimmed_length
  FROM (
  SELECT
    id
    , contacts.business_id
    , lower(trim(email)) as email
    , trim(lower(name)) as contact_name
    , trim(lower(first_name)) as contact_first_name
    , trim(lower(last_name)) as contact_last_name
    , nullif(regexp_replace(trim(phone), '[^0-9]', ''), '') as phone_trimmed
    , nullif(regexp_replace(trim(mobile), '[^0-9]', ''), '') as mobile_trimmed
    , created_at as contact_created_at
    , inv.first_invoice_date
  FROM postgres.public.contacts
  LEFT JOIN first_invoice_dates inv
  on contacts.id = inv.contact_id
  AND contacts.business_id = inv.business_id
  WHERE
  -- only contacts where there is an email, phone, or mobile valid
    -- NOT email IS NULL OR NOT phone IS NULL OR NOT mobile IS NULL
  contacts.business_id = @business
  )t
)
, cleaned_leads AS (
  select *
  , length(phone) as phone_length
  FROM (
  SELECT
  business_id
  , id
  , lower(trim(email)) as email
  , trim(lower(name)) as lead_name
  , nullif(regexp_replace(trim(phone), '[^0-9]', ''), '') as phone
  , type as lead_type
  , created_at as lead_created_at
  FROM postgres.public.leads
  where leads.business_id = @business
  and deleted_at is null
  )t
)

, contacts_leads as (
SELECT
  cont.id as contact_id
 , leads.id as lead_id
  , cont.business_id
  , cont.email as contact_email
  , leads.email as lead_email
  , cont.phone_trimmed as contact_phone
  , leads.phone as lead_phone
  , cont.mobile_trimmed as contact_mobile
  , leads.lead_name
  , cont.contact_first_name
  , cont.contact_last_name
  , cont.contact_name
  , first_invoice_date
  , lead_created_at
  , leads.lead_type
  , CASE WHEN nullif(leads.email, '') IS NOT NULL AND leads.email = cont.email 
      THEN TRUE ELSE FALSE END AS contact_email_match
  , CASE WHEN nullif(leads.lead_name, '') IS NOT NULL AND (leads.lead_name = cont.contact_name OR leads.lead_name = concat(cont.contact_first_name, ' ', cont.contact_last_name))
      THEN TRUE ELSE FALSE END AS contact_name_match
  , CASE WHEN ( 
      NOT nullif(cont.phone_trimmed, '') IS NULL
      AND leads.phone_length>4 AND cont.phone_trimmed_length>4
      AND (
        (
          leads.phone like '%' || cont.phone_trimmed
          OR cont.phone_trimmed like '%' || leads.phone
          )
        OR (
          substr(cont.phone_trimmed, 1, 2) = '04'
          AND (
            leads.phone like '%' || substr(cont.phone_trimmed, 2)
            OR cont.phone_trimmed like '%' || substr(leads.phone, 2)
            )
        )
      )
    ) THEN TRUE ELSE FALSE END AS contact_phone_match
  , CASE WHEN (
      NOT nullif(cont.mobile_trimmed, '') IS NULL
      AND leads.phone_length>4 AND cont.mobile_trimmed_length>4
      AND (
         (
          leads.phone like '%' || cont.mobile_trimmed
        OR cont.mobile_trimmed like '%' || leads.phone
        )
      OR (
        substr(cont.mobile_trimmed, 1, 2) = '04'
        AND
        (
          leads.phone like '%' || substr(cont.mobile_trimmed, 2)
          OR cont.mobile_trimmed like '%' || substr(leads.phone, 2)
        )
      )
    )
  ) THEN TRUE ELSE FALSE END AS contact_mobile_match
FROM filtered_contacts AS cont
CROSS JOIN cleaned_leads leads
)

-- n_businesses x (n_contacts x n_leads) (for every contact we have every possible lead match for a business)
, contacts_leads_logic AS (
    select *
    -- find first contact match per lead -- final decision is using the first_invoice_date for the contact
    ,row_number() over (partition by contact_id ORDER BY (case when contact_lead_match then 1 else 2 end), lead_order ASC NULLS LAST) as match_order_contact
    ,max(contact_lead_match) over (partition by contact_id) as contact_any_match
    FROM (
SELECT
contacts_leads.business_id
, contacts_leads.contact_id
, lead_id
, lead_type
, contact_email
, contact_phone
, contact_mobile
, contact_first_name
, contact_last_name
, contact_name
, lead_phone
, lead_email
, lead_name
, first_invoice_date
-- row number so leads - contacts are always 1 to 1. Order by lead_created_at date.
, row_number() over (partition by contacts_leads.contact_id ORDER BY (CASE WHEN contact_mobile_match or contact_email_match or contact_phone_match or contact_name_match
      THEN lead_created_at ELSE NULL END) ASC NULLS LAST) as lead_order
-- if there are two matched contacts for a lead then order by the first invoice (sale) date and use that.
, row_number() over (partition by lead_id ORDER BY first_invoice_date ASC NULLS LAST) as contact_first_invoice_order
, contact_email_match
, contact_phone_match
, contact_mobile_match
, contact_name_match
, case when contact_mobile_match or contact_email_match or contact_phone_match or contact_name_match then true else false END AS contact_lead_match
from contacts_leads 
)t)


SELECT
business_id::TEXT as business_id
, contact_id::TEXT as contact_id
, lead_id::TEXT as lead_id
, lead_type::TEXT as lead_type
, surrogate_id::TEXT AS surrogate_id
, contact_email::TEXT as contact_email
, contact_phone::TEXT as contact_phone
, contact_mobile::TEXT as contact_mobile
, contact_first_name::TEXT as contact_first_name
, contact_last_name::TEXT as contact_last_name
, contact_name::TEXT as contact_name
, lead_email::TEXT as lead_email
, lead_phone::TEXT as lead_phone
, lead_name::TEXT as lead_name
, first_invoice_date::TEXT as first_invoice_date
, contact_lead_first_match::BOOLEAN as contact_lead_first_match
, contact_email_match::BOOLEAN as contact_email_match
, contact_phone_match::BOOLEAN as contact_phone_match
, contact_mobile_match::BOOLEAN as contact_mobile_match
, contact_name_match::BOOLEAN as contact_name_match
FROM (
select  
business_id::TEXT as business_id
, contact_id::TEXT as contact_id
, lead_id::TEXT as lead_id
, lead_type::TEXT as lead_type
, @GENERATE_SURROGATE_KEY(business_id, contact_id, lead_id) AS surrogate_id
, contact_email::TEXT as contact_email
, contact_phone::TEXT as contact_phone
, contact_mobile::TEXT as contact_mobile
, contact_first_name::TEXT as contact_first_name
, contact_last_name::TEXT as contact_last_name
, contact_name::TEXT as contact_name
, lead_email::TEXT as lead_email
, lead_phone::TEXT as lead_phone
, lead_name::TEXT as lead_name
, first_invoice_date::TEXT as first_invoice_date
, (case when match_order_contact = 1 and contact_lead_match then true else false end)::BOOLEAN as contact_lead_first_match
, contact_email_match::BOOLEAN as contact_email_match
, contact_phone_match::BOOLEAN as contact_phone_match
, contact_mobile_match::BOOLEAN as contact_mobile_match
, contact_name_match::BOOLEAN as contact_name_match
from contacts_leads_logic
where contact_lead_match
-- check that the lead mightve been matched in the past so we can update 
or lead_id in (select lead_id 
from @this_model 
where contact_mobile_match or contact_email_match or contact_phone_match or contact_name_match
)
union all
select  
distinct
business_id::TEXT as business_id
, contact_id::TEXT as contact_id
, NULL::TEXT as lead_id
, NULL::TEXT as lead_type
, @GENERATE_SURROGATE_KEY(business_id, contact_id, '') AS surrogate_id
, contact_email::TEXT as contact_email
, contact_phone::TEXT as contact_phone
, contact_mobile::TEXT as contact_mobile
, contact_first_name::TEXT as contact_first_name
, contact_last_name::TEXT as contact_last_name
, contact_name::TEXT as contact_name
, NULL::TEXT as lead_email
, NULL::TEXT as lead_phone
, NULL::TEXT as lead_name
, first_invoice_date::TEXT as first_invoice_date
, NULL::BOOLEAN as contact_lead_first_match
, NULL::BOOLEAN as contact_email_match
, NULL::BOOLEAN as contact_phone_match
, NULL::BOOLEAN as contact_mobile_match
, NULL::BOOLEAN as contact_name_match
from contacts_leads_logic
-- exclude contacts that have been matched. only want a row for unmatched.
where not contact_any_match
-- note that if a contact becomes matched in the future, the invalidate_hard_deletes will set the valid_to field to not null
-- when it becomes excluded.
-- exclude contacts that have been matched in the past; these are updated in the first query.
and contact_id not in (
  select contact_id 
  from (
  select contact_id, max(contact_lead_first_match) as contact_lead_ever_match
  from @this_model 
  group by contact_id)t
  where contact_lead_ever_match
)
)