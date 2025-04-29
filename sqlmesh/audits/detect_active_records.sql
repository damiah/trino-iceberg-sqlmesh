AUDIT (
  name detect_active_records,
  blocking TRUE
);


SELECT contact_id
, lead_id
, COUNT(*) AS active_count
FROM @this_model
WHERE valid_to is null
GROUP BY contact_id, lead_id
HAVING COUNT(*) > 1

